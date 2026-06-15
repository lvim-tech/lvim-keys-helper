-- lvim-keys-helper: a self-contained key-hint panel (a which-key replacement built on the
-- lvim-utils ecosystem). Each auto-detected prefix gets a BUFFER-LOCAL <nowait> trigger,
-- which fires IMMEDIATELY (that is what <nowait> does — 'timeoutlen' itself is never
-- touched, so keys the helper does not intercept keep Vim's native timeout). From that
-- point the helper manages the whole sequence itself: it reads keys with getcharstr, shows
-- the panel after config.delay, and finally replays the finished sequence so the real
-- mapping (or native command) runs (the longest complete match always beats the 1-key
-- nowait trigger, so the replay cannot be intercepted). This runs in a normal (non-fast)
-- context, so vim.fn, the panel and the delay all work.
--
-- A buffer-local trigger that lands on a key with an existing buffer-local single-key
-- mapping shadows it; the original is saved and restored when the trigger goes away, and
-- run when the sequence resolves on it. A GLOBAL single-key mapping is never touched (the
-- buffer-local trigger merely sits above it) and is found as the exact match through the
-- normal keymap tables. While reading a sequence: the typed count/register are captured and
-- replayed, <BS> steps back one level, <C-d>/<C-u> page an overflowing panel, <F1> then a
-- key describes that mapping, and the mouse clicks rows / breadcrumb cells. A prefix that is
-- ALSO a complete mapping never auto-runs while the panel is open — <CR> runs it (Vim-style
-- timeout resolution applies only before the panel shows, when 'timeoutlen' < delay).
--
-- Everything that matters is live-switchable (a settings UI flips them with no restart):
--   • enable / disable      → M.enable() / M.disable() / M.toggle()
--   • popup delay (ms)       → M.set_delay(ms)
--   • panel style mini/full  → M.set_style("mini"|"full") / M.toggle_style()
--   • group labels           → M.register_groups({ ["<leader>f"] = "Find" })
--
---@module "lvim-keys-helper"

local config = require("lvim-keys-helper.config")
local keymaps = require("lvim-keys-helper.keymaps")
local ui = require("lvim-keys-helper.ui")
local stats = require("lvim-keys-helper.stats")

local ok_utils, utils = pcall(require, "lvim-utils.utils")

local M = {}

local ESC = "\27"
local installed = {} ---@type table<integer, table[]>  bufnr → { mode, lhs, raw, saved } trigger entries
local registered = false ---@type boolean  one-time setup (autocmds, command) done
local active = false ---@type boolean  inside an enter() loop (suppresses trigger recompute)
local recompute_timer = nil ---@type uv.uv_timer_t|nil  debounce for buffer-change recompute
local mutating = false ---@type boolean  inside our own trigger (un)install — the keymap watcher ignores those
local relinquishing = false ---@type boolean  replaying a native operator+motion with triggers off (see resolve())

local LOG_PATH = vim.fn.stdpath("state") .. "/lvim-keys-helper.log"

--- Append a line to the trace log (with a millisecond timestamp) when config.debug is on.
---@param msg string
local function log(msg)
    if not config.debug then
        return
    end
    local f = io.open(LOG_PATH, "a")
    if f then
        f:write(("%10.1f  %s\n"):format(vim.uv.hrtime() / 1e6, msg))
        f:close()
    end
end

--- The BUFFER-LOCAL mapping currently occupying the raw keystroke `fk` in `mode` of
--- buffer `buf`, if any.
---@param buf integer
---@param mode string
---@param fk string  raw bytes
---@return table|nil
local function buflocal_map_at(buf, mode, fk)
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
        if (map.lhsraw or map.lhs) == fk then
            return map
        end
    end
    return nil
end

--- Re-create a buffer-local mapping from its nvim_buf_get_keymap dict (used to restore a
--- map a trigger shadowed).
---@param buf integer
---@param mode string
---@param map table
---@return nil
local function restore_map(buf, mode, map)
    local opts = {
        noremap = map.noremap == 1,
        silent = map.silent == 1,
        expr = map.expr == 1,
        nowait = map.nowait == 1,
        script = map.script == 1,
        desc = map.desc,
        callback = map.callback,
    }
    if map.expr == 1 and map.replace_keycodes == 1 then
        opts.replace_keycodes = true
    end
    pcall(vim.api.nvim_buf_set_keymap, buf, mode, map.lhs, map.rhs or "", opts)
end

--- Delete the trigger `t` from buffer `buf` and restore the buffer-local mapping it
--- shadowed — but only when the current occupant is still our trigger (a plugin may have
--- overwritten it since; never clobber).
---@param buf integer
---@param t table  an `installed[buf]` entry
---@return nil
local function remove_trigger(buf, t)
    if not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    local cur = buflocal_map_at(buf, t.mode, t.raw)
    if cur and cur.desc == keymaps.TRIGGER_DESC then
        pcall(vim.keymap.del, t.mode, t.lhs, { buffer = buf })
        if t.saved then
            restore_map(buf, t.mode, t.saved)
        end
    end
end

--- Remove all trigger keymaps the helper has installed, in every buffer (restoring
--- shadowed buffer-local maps).
---@return nil
local function remove_triggers()
    local prev = mutating
    mutating = true
    for buf, list in pairs(installed) do
        for _, t in ipairs(list) do
            remove_trigger(buf, t)
        end
    end
    installed = {}
    mutating = prev
end

--- The buffer-local mapping our trigger shadowed for the exact raw sequence `pending` in
--- the current buffer, if any. (Global single-key maps are not shadowed — the buffer-local
--- trigger sits above them — so keymaps.find sees those through the normal tables.)
---@param mode string
---@param pending string
---@return table|nil
local function shadowed_for(mode, pending)
    local list = installed[vim.api.nvim_get_current_buf()]
    for _, t in ipairs(list or {}) do
        if t.mode == mode and t.raw == pending and t.saved then
            return t.saved
        end
    end
    return nil
end

-- NOTE on timeoutlen: the helper does NOT touch it. The buffer-local <nowait> triggers
-- fire instantly regardless of timeoutlen, so the panel wait is `delay` alone — while
-- everything the helper does not intercept (config.ignore'd keys, other modes) keeps
-- Vim's native timeout behaviour. (An earlier design held vim.o.timeoutlen at 0; that
-- broke the multi-key sequences of ignored prefixes.)

-- forward declaration (enter ↔ install reference each other)
local enter

--- Map one trigger keystroke buffer-locally with <nowait> — that is what makes it fire
--- IMMEDIATELY instead of after timeoutlen: the helper takes over the waiting itself.
---@param buf integer
---@param mode string
---@param lhs string  human (keytrans) form
---@param fk string  raw bytes
---@return boolean ok
local function set_trigger(buf, mode, lhs, fk)
    return pcall(vim.keymap.set, mode, lhs, function()
        enter(mode, fk)
    end, { buffer = buf, nowait = true, silent = true, desc = keymaps.TRIGGER_DESC })
end

--- Reconcile the trigger keymaps of the CURRENT buffer with its auto-detected prefixes.
--- Idempotent and diff-based: only the keys that actually changed are unmapped/mapped, so
--- a burst of BufEnter/FileType/LspAttach events doesn't churn 30+ keymaps each time. A key
--- is a trigger only when it starts a real multi-key mapping (which-key's `<auto>`) or, with
--- presets on, a built-in sequence. An existing buffer-local single-key mapping on a trigger
--- key is saved before being shadowed and restored when the trigger goes away.
---@return nil
local function install_triggers()
    if relinquishing then
        return -- a native operator+motion replay is in flight with triggers deliberately off
    end
    mutating = true
    local ok, err = pcall(function()
        if not config.enabled then
            remove_triggers()
            return
        end
        -- prune registry entries of wiped buffers
        for b in pairs(installed) do
            if not vim.api.nvim_buf_is_valid(b) then
                installed[b] = nil
            end
        end
        local buf = vim.api.nvim_get_current_buf()
        local bt = vim.bo[buf].buftype
        -- Only intercept normal editing buffers. Special buffers drive their OWN keys:
        --   • prompt — insert-driven (pickers);
        --   • nofile — scratch / UI panels (the package manager, control-center, file trees,
        --     dashboards), whose rows bind single keys like r/u/d/b — a trigger would shadow them
        --     and pop the helper instead. (`nvim_create_buf(_, true)` makes these nofile, set at
        --     creation, before filetype/modifiable — so this is reliable and early.)
        if bt == "prompt" or bt == "nofile" then
            return
        end
        -- desired[mode][lhs_human] = raw_fk
        local desired = {}
        for _, mode in ipairs(config.trigger_modes or {}) do
            desired[mode] = {}
            for _, fk in ipairs(keymaps.prefixes(mode)) do
                desired[mode][vim.fn.keytrans(fk)] = fk
            end
        end
        local changed = false
        -- drop triggers that are no longer wanted
        local kept = {}
        for _, t in ipairs(installed[buf] or {}) do
            if desired[t.mode] and desired[t.mode][t.lhs] then
                kept[#kept + 1] = t
                desired[t.mode][t.lhs] = nil -- already mapped → don't re-add
            else
                remove_trigger(buf, t)
                changed = true
            end
        end
        -- add the newly wanted ones (saving whatever buffer-local map they shadow)
        for mode, lhss in pairs(desired) do
            for lhs, fk in pairs(lhss) do
                local saved = buflocal_map_at(buf, mode, fk)
                if saved and saved.desc == keymaps.TRIGGER_DESC then
                    saved = nil -- a stale trigger of ours, never "restore" it
                end
                if set_trigger(buf, mode, lhs, fk) then
                    kept[#kept + 1] = { mode = mode, lhs = lhs, raw = fk, saved = saved }
                    changed = true
                end
            end
        end
        installed[buf] = kept
        if changed then
            log("install: buf " .. buf .. " → " .. #kept .. " triggers (changed)")
        end
    end)
    mutating = false
    if not ok then
        log("install error: " .. tostring(err))
    end
end

--- Refresh the keymap cache and recompute the current buffer's triggers, debounced —
--- the BufEnter/FileType/LspAttach burst (or a watched vim.keymap.set call) coalesces
--- into one recompute, and never while a sequence is being read.
---@return nil
local function queue_recompute()
    keymaps.invalidate()
    if not config.enabled then
        return
    end
    if recompute_timer then
        recompute_timer:stop()
    end
    recompute_timer = vim.defer_fn(function()
        if not active then
            install_triggers()
        end
    end, config.recompute_debounce or 120)
end

--- Execute a mapping dict directly. Used when a sequence times out on an exact mapping
--- that is also a prefix of longer ones — replaying it with remapping would just make Vim
--- wait timeoutlen again. The typed count/register can't be injected here (limitation).
---@param map table|nil
---@return nil
local function run_map(map)
    if not map then
        return
    end
    if map.callback then
        local ok, res = pcall(map.callback)
        if ok and map.expr == 1 and type(res) == "string" and res ~= "" then
            local keys = res
            if map.replace_keycodes == 1 then
                keys = vim.api.nvim_replace_termcodes(res, true, true, true)
            end
            vim.api.nvim_feedkeys(keys, map.noremap == 1 and "n" or "m", false)
        end
        return
    end
    local rhs = map.rhs
    if type(rhs) ~= "string" or rhs == "" then
        return
    end
    if map.expr == 1 then
        local ok, res = pcall(vim.api.nvim_eval, rhs)
        if not ok or type(res) ~= "string" or res == "" then
            return
        end
        rhs = res
    end
    rhs = vim.api.nvim_replace_termcodes(rhs, true, true, true)
    vim.api.nvim_feedkeys(rhs, map.noremap == 1 and "n" or "m", false)
end

--- Run the resolved sequence `pending` in `mode`, with the captured count/register in
--- `prefix`. resolve() is only reached when no longer mapping continues past `pending`, so
--- it is the longest complete match. We replay it WITH remapping (so expr/callback/count/
--- register/dot-repeat behave exactly as if typed) but FIRST take THIS buffer's triggers off
--- — then reinstall them once the keys drain (SafeState, like arm_sticky()); `relinquishing`
--- keeps any recompute from reinstalling them mid-drain. Removing the triggers is essential
--- in two ways:
---   • a `<nowait>` 1-key trigger would otherwise re-fire on the replay and shadow the very
---     multi-key mapping we resolved — e.g. a GLOBAL `<C-c>.` behind the buffer-local
---     `<C-c>` trigger, an infinite re-feed loop that hangs Neovim;
---   • a NATIVE operator's motion can be a mapping (an operator-pending text object like
---     `af`) — with the triggers gone, Vim's own longest-match resolves the whole
---     operator+motion through the real mappings.
--- The `shadowed` case (the sequence ended exactly on a trigger key) is the one exception:
--- the real occupant is run directly.
---@param mode string
---@param pending string  raw bytes
---@param prefix string  count/register, raw typeable bytes
---@return nil
local function resolve(mode, pending, prefix)
    ui.hide()
    stats.bump(mode, vim.fn.keytrans(pending))
    -- the sequence ended exactly on a trigger key → the real occupant is the shadowed map
    local saved = shadowed_for(mode, pending)
    if saved then
        log("RESOLVE " .. vim.fn.keytrans(pending) .. " → shadowed")
        return run_map(saved)
    end
    log("RESOLVE " .. vim.fn.keytrans(pending) .. " → " .. (keymaps.find(mode, pending) and "mapped" or "native"))
    local buf = vim.api.nvim_get_current_buf()
    local prev = mutating
    mutating = true
    for _, t in ipairs(installed[buf] or {}) do
        remove_trigger(buf, t)
    end
    installed[buf] = nil
    mutating = prev
    relinquishing = true
    vim.api.nvim_feedkeys(prefix .. pending, "m", false)
    local function rearm()
        relinquishing = false
        install_triggers()
    end
    if not pcall(vim.api.nvim_create_autocmd, "SafeState", { once = true, callback = rearm }) then
        vim.defer_fn(rearm, 80)
    end
end

--- Re-open the panel at `parent` (raw prefix) once the just-resolved action has fully
--- drained — hydra-style sticky groups. SafeState fires when nothing is pending; the
--- re-entry is skipped when the helper got disabled or the action left `mode` (e.g.
--- opened a picker in insert mode).
---@param mode string
---@param parent string  raw bytes of the sticky group's prefix
---@return nil
local function arm_sticky(mode, parent)
    local function reenter()
        if config.enabled and vim.api.nvim_get_mode().mode:sub(1, 1) == mode then
            enter(mode, parent)
        end
    end
    local ok = pcall(vim.api.nvim_create_autocmd, "SafeState", { once = true, callback = reenter })
    if not ok then
        vim.defer_fn(reenter, 80)
    end
end

--- Whether `map` is a <Nop> placeholder (e.g. mapping <Space> to nothing so it can serve
--- as the leader). Such a map must never count as an exact match: "running" it on timeout
--- would just hide the panel and do nothing — the panel should stay open instead.
---@param map table
---@return boolean
local function is_nop(map)
    if map.callback then
        return false
    end
    local rhs = map.rhs
    return rhs == nil or rhs == "" or rhs:lower() == "<nop>"
end

--- Wait up to `ms` for a key to land in the typeahead (peeked, not consumed). Pumps the
--- event loop, so the deferred panel timer still fires while waiting. If polling is
--- impossible, reports "a key is available", degrading to a blocking getcharstr (the
--- pre-timeout behaviour).
---@param ms integer
---@return boolean
local function wait_for_key(ms)
    local ok, got = pcall(vim.wait, ms, function()
        return vim.fn.getchar(1) ~= 0
    end, 10, false)
    if not ok then
        return true
    end
    return got == true
end

--- The read loop for a sequence in `mode`, starting from the trigger keystroke. The
--- sequence is kept as a stack of keystrokes so <BS> can step back one level. Blocks on
--- getcharstr; the panel shows after the delay. Wrapped by enter() (manages `active`).
---@param mode string
---@param first string  raw bytes of the trigger keystroke
---@param prefix string  captured count/register (replayed by resolve)
local function run_loop(mode, first, prefix)
    local keys = { first }
    local replay -- bare key to replay after a cancel (ESC + fast key fused into <M-…>)
    -- panel control keys (display form), resolved once per sequence from the config
    local ckeys = config.keys or {}
    local function keydisp(lhs)
        return vim.fn.keytrans(vim.api.nvim_replace_termcodes(lhs, true, true, true))
    end
    local key_back = keydisp(ckeys.back or "<BS>")
    local key_down = keydisp(ckeys.scroll_down or "<C-d>")
    local key_up = keydisp(ckeys.scroll_up or "<C-u>")
    local key_run = keydisp(ckeys.run or "<CR>")
    local key_help = keydisp(ckeys.help or "<F1>")
    -- The sticky group whose direct child is about to resolve: its panel re-opens after
    -- the action (hydra-style), until <Esc> / back leaves it.
    local function sticky_parent()
        if #keys < 2 then
            return nil
        end
        local parent = table.concat(keys, "", 1, #keys - 1)
        if keymaps.group_sticky(vim.fn.keytrans(parent), mode) then
            return parent
        end
        return nil
    end
    while true do
        local pending = table.concat(keys)
        local conts = keymaps.continuations(mode, pending)
        log(
            "  loop pending="
                .. vim.fn.keytrans(pending)
                .. " conts="
                .. #conts
                .. " visible="
                .. tostring(ui.visible())
        )
        if #conts == 0 then
            -- a complete mapping (or native sequence) → run it
            local sticky = sticky_parent()
            resolve(mode, pending, prefix)
            if sticky then
                arm_sticky(mode, sticky)
            end
            return
        end
        local exact = keymaps.find(mode, pending) or shadowed_for(mode, pending)
        if exact and is_nop(exact) then
            exact = nil -- a <Nop> placeholder: keep the panel open instead of "running" it
        end
        -- Panel timing. getcharstr does NOT pump timers while it blocks, so the delay is
        -- implemented as typeahead-peek waits (wait_for_key pumps the event loop), never as
        -- a timer: the panel opens once `delay` ms pass without a key — and immediately when
        -- it is already up, so it updates live as the sequence narrows. A fast typist whose
        -- next key arrives first never sees it. Suppressed while a macro is executing (the
        -- keys are replayed, not typed).
        local title = vim.fn.keytrans(pending)
        local title_keys = {}
        for i, k in ipairs(keys) do
            title_keys[i] = vim.fn.keytrans(k)
        end
        -- `pending` being both a complete mapping and a prefix of longer ones is shown in
        -- the legend (<CR> runs it) — an OPEN panel never executes anything by timeout.
        -- Only when the ambiguity timeout is shorter than the panel delay does the exact
        -- mapping resolve Vim-style, before the panel would even show.
        local show_opts = {
            back = #keys > 1,
            exact = exact
                    and ((exact.desc and exact.desc ~= "") and exact.desc or ((config.labels or {}).run or "run"))
                or nil,
            color = keymaps.group_color(title, mode), -- a group's colour paints its own panel
            mode = mode,
            count = prefix ~= "" and prefix or nil, -- show the captured count/register
        }
        -- a strict group is a curated menu — it opens instantly; a group may carry its
        -- own delay; everyone else honours the configured one
        local delay = keymaps.group_strict(title, mode) and 0 or keymaps.group_delay(title, mode) or config.delay
        if vim.fn.reg_executing() == "" then
            if ui.visible() or delay <= 0 then
                ui.show(conts, title_keys, show_opts)
            else
                local tl = (exact and vim.o.timeout) and vim.o.timeoutlen or nil
                if tl and tl <= delay then
                    if not wait_for_key(tl) then
                        log("  timeout → exact " .. title)
                        stats.bump(mode, title)
                        return run_map(exact)
                    end
                elseif not wait_for_key(delay) then
                    ui.show(conts, title_keys, show_opts)
                end
            end
        end
        local ok, ch = pcall(vim.fn.getcharstr)
        log("  getchar ok=" .. tostring(ok) .. " ch=" .. (ok and vim.fn.keytrans(ch or "") or tostring(ch)))
        if not ok or ch == nil or ch == "" or ch == ESC then
            break -- cancelled
        end
        ch = keymaps.canon(ch) -- typed keys must match the canonical encoding of the maps
        local disp = vim.fn.keytrans(ch)
        if
            disp == key_run
            and exact
            and #keymaps.continuations(mode, pending .. ch) == 0
            and not keymaps.find(mode, pending .. ch)
        then
            -- run the exact mapping behind this prefix (a real continuation wins)
            ui.hide()
            log("  run → exact " .. title)
            local sticky = sticky_parent()
            stats.bump(mode, title)
            run_map(exact)
            if sticky then
                arm_sticky(mode, sticky)
            end
            return
        elseif disp == key_back then
            keys[#keys] = nil -- step back one level; at the root this cancels
            if #keys == 0 then
                break
            end
        elseif (disp == key_down or disp == key_up) and ui.can_scroll() then
            ui.scroll(disp == key_down and 1 or -1)
        elseif disp == key_help then
            -- describe the mapping behind the NEXT pressed key (and where it comes from)
            local ok2, hk = pcall(vim.fn.getcharstr)
            if ok2 and hk and hk ~= "" and hk ~= ESC then
                hk = keymaps.canon(hk)
                local target = pending .. hk
                local map = keymaps.find(mode, target)
                local lines = { vim.fn.keytrans(target) }
                if map then
                    if map.desc and map.desc ~= "" then
                        lines[#lines + 1] = "desc:   " .. map.desc
                    end
                    if map.callback then
                        local info = debug.getinfo(map.callback, "S")
                        lines[#lines + 1] = "lua:    " .. (info.short_src or "?") .. ":" .. (info.linedefined or "?")
                    elseif map.rhs and map.rhs ~= "" then
                        lines[#lines + 1] = "rhs:    " .. map.rhs
                    end
                    lines[#lines + 1] = ("noremap=%d silent=%d nowait=%d buffer-local=%s"):format(
                        map.noremap or 0,
                        map.silent or 0,
                        map.nowait or 0,
                        tostring(map.buffer == 1)
                    )
                else
                    lines[#lines + 1] = "no mapping (native command or preset)"
                end
                vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "keys-helper" })
            end
        elseif disp == "<LeftMouse>" then
            local pos = vim.fn.getmousepos()
            if pos.winid ~= 0 and pos.winid == ui.win() then
                if pos.winrow <= 1 then
                    -- click in the title border → jump back to that breadcrumb level
                    local level = ui.title_level(pos.wincol)
                    if level and level < #keys then
                        for i = #keys, level + 1, -1 do
                            keys[i] = nil
                        end
                    end
                else
                    local item = ui.hit(pos.winrow, pos.wincol)
                    if item then
                        keys[#keys + 1] = item.raw -- as if the key was pressed
                    end
                end
            else
                break -- a click outside the panel closes it
            end
        elseif disp:find("Mouse") or disp:find("Scroll") or disp:find("Drag") or disp:find("Release") then
            log("  ignore mouse " .. disp)
        else
            -- ESC followed within the terminal's escape-ambiguity window by another key
            -- arrives fused as <M-key>. When that alt-key is not a real continuation or
            -- mapping, treat it the way Neovim treats an unmapped meta key natively:
            -- ESC (cancel the panel) + the bare key, replayed as if typed afterwards.
            local alt = disp:match("^<M%-(.+)>$")
            if alt and #keymaps.continuations(mode, pending .. ch) == 0 and not keymaps.find(mode, pending .. ch) then
                replay = #alt == 1 and alt or vim.api.nvim_replace_termcodes("<" .. alt .. ">", true, true, true)
                log("  fused ESC+" .. alt .. " → cancel + replay")
                break
            end
            keys[#keys + 1] = ch
            -- loop: the panel re-renders for the narrowed prefix (or the sequence resolves)
        end
    end
    ui.hide()
    if mode == "o" then
        -- cancel the pending operator too, otherwise it would consume the next motion
        vim.api.nvim_feedkeys(ESC, "n", false)
    end
    if replay then
        vim.api.nvim_feedkeys(replay, "t", false)
    end
end

--- The trigger callback. Captures the count/register typed before the trigger, sets
--- `active` for the duration (so a buffer-change recompute can't churn the triggers
--- mid-sequence) and always clears it, even on error.
---@param mode string
---@param pending string  raw bytes of the pressed prefix
---@return nil
function enter(mode, pending)
    log("ENTER mode=" .. mode .. " lhs=" .. vim.fn.keytrans(pending) .. " enabled=" .. tostring(config.enabled))
    if not config.enabled then
        return vim.api.nvim_feedkeys(pending, "n", false)
    end
    -- capture the count / register so resolve() can replay them in front of the sequence
    local prefix = ""
    if mode == "n" or mode == "x" then
        local reg = vim.v.register
        local cb = vim.o.clipboard
        local defreg = (cb:find("unnamedplus") and "+") or (cb:find("unnamed") and "*") or '"'
        if reg ~= "" and reg ~= defreg then
            prefix = '"' .. reg
        end
    end
    if vim.v.count > 0 then
        prefix = prefix .. vim.v.count
    end
    active = true
    local ok_run, err = pcall(run_loop, mode, pending, prefix)
    active = false
    if not ok_run then
        log("ENTER error: " .. tostring(err))
        ui.hide()
    end
end

-- Default accent colours (lvim-utils palette names); config.palette overrides.
local DEFAULT_PALETTE = { "blue", "green", "red", "purple", "cyan", "orange", "yellow", "magenta", "teal" }

--- Build the panel highlight groups from the lvim-utils palette: each badge slot is a
--- ` key ` button (strong tint bg, bold) + a ` desc ` text area (light tint bg), exactly
--- like the :Messages pager's badge buttons — just cycled across colours for variety.
--- Group rows use an italic variant of the text area. Falls back to plain links when the
--- palette is unavailable.
---@return nil
local function set_highlights()
    local palette = (type(config.palette) == "table" and #config.palette > 0) and config.palette or DEFAULT_PALETTE
    local ok, colors = pcall(require, "lvim-utils.colors")
    if not ok or type(colors.blend) ~= "function" then
        local links = {
            LvimKeysHelperNormal = "NormalFloat",
            LvimKeysHelperBorder = "FloatBorder",
            LvimKeysHelperFooter = "Comment",
            LvimKeysHelperFooterKey = "Special",
        }
        for i = 1, #palette do
            links["LvimKeysHelperBadge" .. i] = "Identifier"
            links["LvimKeysHelperText" .. i] = "Normal"
            links["LvimKeysHelperGroup" .. i] = "Comment"
        end
        for name, target in pairs(links) do
            vim.api.nvim_set_hl(0, name, { link = target, default = true })
        end
        return
    end
    local c = colors
    -- One uniform background for the whole panel — config.colors.bg (default: the DARK
    -- variant of the palette bg, matching the colorscheme's float bg), used as the panel
    -- body, the border and the base every accent tint is blended toward. Never
    -- NormalFloat, whose bg differs per colorscheme and resolves at another time.
    local cc = config.colors or {}
    local blend, bg = c.blend, c[cc.bg or "bg_dark"] or c.bg_dark or c.bg
    local accent = c[cc.accent or "blue"] or c.blue
    local tint = config.tint or {}
    local strong, light = tint.strong or 0.2, tint.light or 0.1
    -- Each entry is one accent colour, forming a coloured table cell: the key a solid
    -- accent block (bold), the description a lighter tint of the SAME accent. Key left,
    -- description right.
    for i, name in ipairs(palette) do
        local col = c[name] or c.blue
        vim.api.nvim_set_hl(0, "LvimKeysHelperBadge" .. i, { fg = col, bg = blend(col, bg, strong), bold = true })
        vim.api.nvim_set_hl(0, "LvimKeysHelperText" .. i, { fg = col, bg = blend(col, bg, light) })
        vim.api.nvim_set_hl(0, "LvimKeysHelperGroup" .. i, { fg = col, bg = blend(col, bg, light), italic = true })
    end
    vim.api.nvim_set_hl(0, "LvimKeysHelperNormal", { fg = c.fg, bg = bg })
    vim.api.nvim_set_hl(0, "LvimKeysHelperBorder", { fg = accent, bg = bg })
    -- title cells reuse BadgeN/TextN per nesting level (see ui.render); footer: tinted
    -- accent cells (` key ` strong tint + ` label ` light tint)
    vim.api.nvim_set_hl(0, "LvimKeysHelperFooter", { fg = accent, bg = blend(accent, bg, light) })
    vim.api.nvim_set_hl(0, "LvimKeysHelperFooterKey", { fg = accent, bg = blend(accent, bg, strong), bold = true })
end

--- Register the :LvimKeysHelper command (once).
---@return nil
local function register_command()
    vim.api.nvim_create_user_command("LvimKeysHelper", function(cmd)
        local sub, arg = cmd.fargs[1], cmd.fargs[2]
        if sub == "toggle" then
            vim.notify("keys-helper: " .. (M.toggle() and "enabled" or "disabled"))
        elseif sub == "enable" then
            M.enable()
            vim.notify("keys-helper: enabled")
        elseif sub == "disable" then
            M.disable()
            vim.notify("keys-helper: disabled")
        elseif sub == "style" then
            if arg == "mini" or arg == "full" then
                M.set_style(arg)
            else
                M.toggle_style()
            end
            vim.notify("keys-helper style: " .. M.style())
        elseif sub == "delay" then
            if arg then
                M.set_delay(arg)
            end
            vim.notify("keys-helper delay: " .. M.get_delay() .. "ms")
        elseif sub == "test" then
            ui.show({
                { key = "f", desc = "Find", group = true },
                { key = "g", desc = "Git", group = true },
                { key = "w", desc = "Write", group = false },
                { key = "q", desc = "Quit", group = false },
            }, "TEST")
        elseif sub == "debug" then
            config.debug = not config.debug
            if config.debug then
                pcall(os.remove, LOG_PATH)
                log("=== debug on; triggers=" .. M.trigger_count() .. " enabled=" .. tostring(config.enabled) .. " ===")
            end
            vim.notify("keys-helper debug: " .. tostring(config.debug) .. "\nlog: " .. LOG_PATH)
        elseif sub == "log" then
            vim.cmd("edit " .. vim.fn.fnameescape(LOG_PATH))
        elseif sub == "doctor" then
            require("lvim-keys-helper.tools").doctor()
        elseif sub == "cheatsheet" then
            require("lvim-keys-helper.tools").cheatsheet()
        elseif sub == "stats" then
            if arg == "reset" then
                stats.reset()
                vim.notify("keys-helper: stats reset")
            else
                require("lvim-keys-helper.tools").stats(tonumber(arg))
            end
        else
            vim.notify(
                ("keys-helper: enabled=%s  delay=%dms  style=%s  presets=%s  triggers=%d  timeoutlen=%s"):format(
                    tostring(M.is_enabled()),
                    M.get_delay(),
                    M.style(),
                    tostring(config.presets ~= false),
                    M.trigger_count(),
                    tostring(vim.o.timeoutlen)
                )
            )
        end
    end, {
        nargs = "*",
        complete = function(arg, line)
            local words = vim.split(vim.trim(line), "%s+")
            local list
            if words[2] == "style" then
                list = { "mini", "full" }
            elseif words[2] == "stats" then
                list = { "reset" }
            else
                list = {
                    "toggle",
                    "enable",
                    "disable",
                    "status",
                    "style",
                    "delay",
                    "doctor",
                    "cheatsheet",
                    "stats",
                    "test",
                    "debug",
                    "log",
                }
            end
            return vim.tbl_filter(function(c)
                return arg == "" or c:find(arg, 1, true) == 1
            end, list)
        end,
        desc = "lvim-keys-helper: toggle / enable / disable / status / style / delay / test",
    })
end

-- The native vim.keymap.set options a `keys` child may carry — forwarded verbatim.
local MAP_OPTS = { "expr", "nowait", "remap", "script", "unique", "buffer", "replace_keycodes" }

--- Create the REAL mappings declared inside the groups config. A table child in a
--- group's `keys` follows vim.keymap.set's own syntax: [1] is the rhs (a string of keys,
--- a <Cmd>…<CR> string, or a Lua function), everything else is the native opts (desc,
--- mode, expr, nowait, remap, silent, buffer, …); silent defaults to true. The legacy
--- form ({ "Desc", cmd = "Ex" } / run = fn / rhs = "keys") keeps working — when one of
--- those fields is present, [1] is the description. A child may instead be a NESTED
--- GROUP (own label/color/mode/strict/keys) — its mappings are defined recursively and
--- default to the enclosing group's mode scope. Being ordinary mappings, they are
--- auto-detected, shown and replayed like everything else (count/dot-repeat included).
---@return nil
local function define_group_keys()
    local function walk(lhs, v, inherited_mode)
        local group_mode = v.mode or inherited_mode
        if type(v.keys) ~= "table" then
            return
        end
        for ck, cv in pairs(v.keys) do
            if type(cv) == "table" then
                if keymaps.is_nested_group(cv) then
                    walk(lhs .. ck, cv, group_mode)
                else
                    local legacy = cv.run or cv.cmd or cv.rhs
                    local rhs = legacy or cv[1]
                    if rhs then
                        local opts = {
                            desc = legacy and (cv.desc or cv[1]) or cv.desc,
                            silent = cv.silent ~= false,
                        }
                        for _, o in ipairs(MAP_OPTS) do
                            if cv[o] ~= nil then
                                opts[o] = cv[o]
                            end
                        end
                        if cv.cmd then
                            rhs = "<Cmd>" .. cv.cmd:gsub("^:", "") .. "<CR>"
                        end
                        pcall(vim.keymap.set, cv.mode or group_mode or "n", lhs .. ck, rhs, opts)
                    end
                end
            end
        end
    end
    for lhs, v in pairs(config.groups or {}) do
        if type(v) == "table" then
            walk(lhs, v, nil)
        end
    end
end

--- Configure and start the helper. Idempotent — calling again re-merges config, refreshes
--- highlights and re-installs the triggers (the autocmds / command are registered once).
---@param opts? LvimKeysHelperConfig
---@return nil
function M.setup(opts)
    if ok_utils and utils.merge then
        utils.merge(config, opts or {})
    elseif opts then
        config = vim.tbl_deep_extend("force", config, opts)
    end
    define_group_keys()
    keymaps.invalidate() -- config (groups/ignore/presets) may have changed
    set_highlights()
    install_triggers()
    if registered then
        return
    end
    registered = true
    pcall(function()
        require("lvim-utils.colors").on_change(set_highlights)
    end)
    local grp = vim.api.nvim_create_augroup("lvim_keys_helper", { clear = true })
    -- The buffer (and thus its mappings) changed → refresh the cache and recompute the
    -- auto-detected trigger prefixes for the new buffer. Scheduled so it never blocks.
    vim.api.nvim_create_autocmd({ "BufEnter", "LspAttach", "FileType" }, {
        group = grp,
        callback = queue_recompute,
    })
    vim.api.nvim_create_autocmd("ColorScheme", {
        group = grp,
        callback = set_highlights,
    })
    -- Watch mapping changes: plugins that define maps OUTSIDE the BufEnter cycle (timers,
    -- user commands, lazy handlers) become triggers/panel rows immediately instead of
    -- after the next buffer switch. Our own trigger churn is ignored via `mutating`.
    if config.watch_mappings ~= false then
        local orig_set, orig_del = vim.keymap.set, vim.keymap.del
        ---@diagnostic disable-next-line: duplicate-set-field
        vim.keymap.set = function(m, lhs, rhs, o)
            local r = orig_set(m, lhs, rhs, o)
            if not mutating and not (o and o.desc == keymaps.TRIGGER_DESC) then
                queue_recompute()
            end
            return r
        end
        ---@diagnostic disable-next-line: duplicate-set-field
        vim.keymap.del = function(m, lhs, o)
            orig_del(m, lhs, o)
            if not mutating then
                queue_recompute()
            end
        end
    end
    register_command()
end

-- ── runtime controls (live; no restart needed) ────────────────────────────────

--- Enable the panel (re-installs the triggers; they are <nowait>, so they fire
--- instantly without touching timeoutlen).
---@return nil
function M.enable()
    config.enabled = true
    install_triggers()
end

--- Disable the panel: remove the triggers (restoring any shadowed maps; keys behave
--- natively again) and hide it.
---@return nil
function M.disable()
    config.enabled = false
    remove_triggers()
    ui.hide()
end

--- Toggle enabled state; returns the new state.
---@return boolean
function M.toggle()
    if config.enabled then
        M.disable()
    else
        M.enable()
    end
    return config.enabled
end

--- Whether the panel is enabled.
---@return boolean
function M.is_enabled()
    return config.enabled == true
end

--- Set the popup delay in milliseconds (live).
---@param ms integer|string|nil
---@return nil
function M.set_delay(ms)
    local n = tonumber(ms)
    if n then
        config.delay = math.max(0, n)
    end
end

--- Current popup delay in milliseconds.
---@return integer
function M.get_delay()
    return config.delay
end

--- Set the panel style ("mini" or "full"); re-renders live if the panel is open.
---@param style "mini"|"full"
---@return nil
function M.set_style(style)
    if style == "mini" or style == "full" then
        config.style = style
    end
end

--- Toggle between mini and full; returns the new style.
---@return string
function M.toggle_style()
    M.set_style(config.style == "mini" and "full" or "mini")
    return config.style
end

--- Current panel style.
---@return string
function M.style()
    return config.style
end

--- Register (or extend) group labels at runtime: sequence in vim notation → label.
---   require("lvim-keys-helper").register_groups({ ["<leader>f"] = "Find" })
---@param groups table<string,string>
---@return nil
function M.register_groups(groups)
    config.groups = config.groups or {}
    for lhs, label in pairs(groups or {}) do
        config.groups[lhs] = label
    end
    define_group_keys()
    keymaps.invalidate()
end

--- Number of trigger keymaps currently installed across all buffers (for :checkhealth
--- / status).
---@return integer
function M.trigger_count()
    local n = 0
    for _, list in pairs(installed) do
        n = n + #list
    end
    return n
end

return M
