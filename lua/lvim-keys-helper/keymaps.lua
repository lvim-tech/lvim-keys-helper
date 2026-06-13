-- lvim-keys-helper: keymap inspection.
-- Given the raw keys typed so far ("pending"), returns the distinct next keystrokes
-- that would continue an existing mapping in the current mode — the data the panel
-- renders. Reads both buffer-local and global maps via nvim_get_keymap, matching on
-- the raw lhs bytes so special keys (<C-x>, <leader>, …) compare correctly. When
-- config.presets is on, Neovim's built-in sequences (g/z/[/]/<C-w>/text objects) are
-- merged in as well. Group rows get their label from config.groups (or "+N keys"),
-- and anything listed in config.ignore is left out entirely.
--
---@module "lvim-keys-helper.keymaps"

local config = require("lvim-keys-helper.config")
local presets = require("lvim-keys-helper.presets")
local stats = require("lvim-keys-helper.stats")

local M = {}

-- The desc carried by the trigger keymaps init.lua installs. Used to filter them out
-- of the map list, so a trigger is never reported as a real mapping (find() returning
-- a trigger would make resolve() feed it back and loop forever).
M.TRIGGER_DESC = "lvim-keys-helper trigger"

local PLUG = vim.api.nvim_replace_termcodes("<Plug>", true, true, true)
local SNR = vim.api.nvim_replace_termcodes("<SNR>", true, true, true)

--- The first whole keystroke (raw bytes) of `s`: a K_SPECIAL 3-byte sequence, a UTF-8
--- multibyte char, or a single byte. A KS_MODIFIER prefix (0x80 0xfc mod — how Neovim
--- encodes e.g. <C-Space>, <M-j>, <2-LeftMouse>) belongs to the key that FOLLOWS it, so
--- it recurses to include that key — truncating it would produce garbage triggers.
---@param s string
---@return string
local function first_keystroke(s)
    local b = s:byte(1)
    if not b then
        return s
    end
    if b == 0x80 then
        if s:byte(2) == 0xfc and #s > 3 then
            return s:sub(1, 3) .. first_keystroke(s:sub(4))
        end
        return s:sub(1, 3) -- K_SPECIAL: 0x80 KS KE
    elseif b >= 0xF0 then
        return s:sub(1, 4)
    elseif b >= 0xE0 then
        return s:sub(1, 3)
    elseif b >= 0xC0 then
        return s:sub(1, 2)
    end
    return s:sub(1, 1)
end

--- Canonical raw form of a key sequence. Neovim stores some keys in TWO encodings —
--- <C-c> is "\3" or K_SPECIAL KS_MODIFIER MOD_CTRL "c" depending on how the mapping was
--- created — and prefix matching needs ONE form. A keytrans → termcodes roundtrip
--- collapses both to the canonical bytes; sequences without K_SPECIAL are already
--- canonical and returned as-is.
---@param s string
---@return string
local function canon(s)
    if s:find("\128", 1, true) then
        local ok, disp = pcall(vim.fn.keytrans, s)
        if ok and disp ~= "" then
            local ok2, raw = pcall(vim.api.nvim_replace_termcodes, disp, true, true, true)
            if ok2 and raw ~= "" then
                return raw
            end
        end
    end
    return s
end

M.canon = canon

--- A human description for a mapping (its `desc`, else a trimmed rhs, else empty).
---@param map table
---@return string
local function describe(map)
    if map.desc and map.desc ~= "" then
        return map.desc
    end
    if type(map.rhs) == "string" and map.rhs ~= "" then
        return (map.rhs:gsub("[\r\n]+", " "))
    end
    return ""
end

--- Whether `lhs` (raw) is an internal, untypeable mapping (<Plug>/<SNR>). These must
--- never become triggers — a nowait map on the bare <Plug> key would intercept the
--- <Plug>(…) sequences other plugins feed with remapping.
---@param lhs string
---@return boolean
local function is_internal(lhs)
    local head = lhs:sub(1, 3)
    return head == PLUG or head == SNR
end

-- Cache of the merged map list per "mode:bufnr"; continuations() runs on every keystroke,
-- so the per-key cost must not include an nvim_get_keymap call. Invalidated by M.invalidate
-- (the host clears it on BufEnter / when mappings may have changed).
local cache = {}

--- All maps (buffer-local first, then global) for `mode`, cached per current buffer.
--- Internal (<Plug>/<SNR>) lhs and our own trigger maps are filtered out here once, so
--- continuations/prefixes/find all see a clean list.
---@param mode string
---@return table[]
local function maps_for(mode)
    local key = mode .. ":" .. vim.api.nvim_get_current_buf()
    local hit = cache[key]
    if hit then
        return hit
    end
    local maps = {}
    local function take(list)
        for _, map in ipairs(list) do
            local lhs = map.lhsraw or map.lhs
            if lhs and lhs ~= "" and not is_internal(lhs) and map.desc ~= M.TRIGGER_DESC then
                map.lhsraw = canon(lhs) -- one canonical encoding for all prefix matching
                maps[#maps + 1] = map
            end
        end
    end
    take(vim.api.nvim_buf_get_keymap(0, mode))
    take(vim.api.nvim_get_keymap(mode))
    cache[key] = maps
    return maps
end

-- Normalized (keytrans form) lookups built from config.groups / config.ignore. Rebuilt
-- lazily after every invalidate(), so live edits (setup / register_groups) are picked up.
-- desc_over holds per-child description overrides declared in a group's `keys` table,
-- keyed by the FULL child sequence (parent .. child, display form).
local groups_norm, ignore_norm, desc_over

--- Canonical display form of a lhs written in vim notation (<leader> is expanded).
---@param lhs string
---@return string
local function normalize(lhs)
    return vim.fn.keytrans(vim.api.nvim_replace_termcodes(lhs, true, true, true))
end

--- Whether a `keys` child table is a NESTED GROUP definition (label/colour/strict/keys
--- of its own) rather than a mapping definition ([1] = rhs / cmd / run / rhs fields).
---@param cv table
---@return boolean
function M.is_nested_group(cv)
    if cv.run or cv.cmd or cv.rhs then
        return false
    end
    return cv.keys ~= nil or cv.strict ~= nil or cv.color ~= nil or cv.group == true
end

--- Build (lazily) and query the normalized groups lookup. A group may be scoped to
--- specific MODES via a `mode` field ("n" or { "n", "x" }, vim.keymap.set style);
--- without one it applies everywhere (a nested group inherits its parent's scope).
--- `mode` filters every aspect: label, colour, strictness and the child desc overrides.
--- A child inside `keys` may itself be a nested group (own label/color/mode/strict/keys).
---@param disp string
---@param mode string
---@return table|nil
local function group_entry(disp, mode)
    if not groups_norm then
        groups_norm = {}
        desc_over = {}
        -- registers `v` (a group definition table) under the normalized sequence `base`;
        -- nested groups recurse with their parent's mode scope as the default
        local function register(base, v, inherited)
            local modes = inherited
            if v.mode then
                modes = {}
                for _, m in ipairs(type(v.mode) == "table" and v.mode or { v.mode }) do
                    modes[m] = true
                end
            end
            local declared
            if type(v.keys) == "table" then
                declared = {}
                for ck, cv in pairs(v.keys) do
                    local ck_norm = normalize(ck)
                    declared[#declared + 1] = ck_norm
                    if type(cv) == "table" and M.is_nested_group(cv) then
                        register(base .. ck_norm, cv, modes)
                    else
                        local cd
                        if type(cv) == "table" then
                            -- legacy form ([1] = desc) vs native keymap.set form ([1] = rhs)
                            cd = (cv.run or cv.cmd or cv.rhs) and (cv.desc or cv[1]) or cv.desc
                        else
                            cd = cv
                        end
                        if type(cd) == "string" then
                            desc_over[base .. ck_norm] = { desc = cd, modes = modes }
                        end
                    end
                end
            end
            groups_norm[base] = {
                label = v.label or v[1],
                color = v.color,
                strict = v.strict == true,
                sticky = v.sticky == true,
                delay = tonumber(v.delay),
                declared = declared,
                modes = modes,
            }
        end
        for lhs, v in pairs(config.groups or {}) do
            if type(v) == "table" then
                register(normalize(lhs), v, nil)
            else
                groups_norm[normalize(lhs)] = { label = v }
            end
        end
    end
    local e = groups_norm[disp]
    if e and e.modes and not e.modes[mode] then
        return nil -- registered, but not for this mode
    end
    return e
end

--- The description override declared for the full child sequence `disp` in its parent
--- group's `keys` table, if any (respecting the parent's mode scope).
---@param disp string
---@param mode string
---@return string|nil
local function desc_override(disp, mode)
    group_entry("", mode) -- ensure the lookups are built
    local o = desc_over[disp]
    if o and o.modes and not o.modes[mode] then
        return nil
    end
    return o and o.desc or nil
end

--- The registered group label for the display-form sequence `disp` in `mode`, if any.
---@param disp string
---@param mode string
---@return string|nil
local function group_label(disp, mode)
    local e = group_entry(disp, mode)
    return e and e.label or nil
end

--- The colour (palette name) registered for the group `disp` in `mode`, if any — it
--- overrides the nesting-level colour for the group's row and for its own panel.
---@param disp string
---@param mode string
---@return string|nil
function M.group_color(disp, mode)
    local e = group_entry(disp, mode or "n")
    return e and e.color or nil
end

--- Whether the group `disp` is strict in `mode`: its panel shows only the keys declared
--- in its config `keys` table, and opens INSTANTLY (a curated menu — no delay).
---@param disp string
---@param mode string
---@return boolean
function M.group_strict(disp, mode)
    local e = group_entry(disp, mode or "n")
    return (e and e.strict) == true
end

--- Whether the group `disp` is sticky in `mode`: after one of its direct children runs,
--- the panel re-opens at the group, hydra-style, until <Esc>/back.
---@param disp string
---@param mode string
---@return boolean
function M.group_sticky(disp, mode)
    local e = group_entry(disp, mode or "n")
    return (e and e.sticky) == true
end

--- The per-group popup delay (ms) registered for `disp` in `mode`, if any.
---@param disp string
---@param mode string
---@return integer|nil
function M.group_delay(disp, mode)
    local e = group_entry(disp, mode or "n")
    return e and e.delay or nil
end

--- Whether the display-form sequence `disp` is listed in config.ignore.
---@param disp string
---@return boolean
local function is_ignored(disp)
    if not ignore_norm then
        ignore_norm = {}
        for _, lhs in ipairs(config.ignore or {}) do
            ignore_norm[normalize(lhs)] = true
        end
    end
    return ignore_norm[disp] == true
end

--- Drop the cached map lists and normalized group/ignore lookups (call when mappings
--- or the config may have changed).
---@return nil
function M.invalidate()
    cache = {}
    groups_norm = nil
    ignore_norm = nil
    desc_over = nil
end

--- Distinct next keystrokes that continue a mapping (or, with presets on, a built-in
--- sequence) past `pending` (raw bytes), each as { key = <display>, raw = <bytes>,
--- desc = <string>, group = <boolean> }. `group` marks a keystroke that is itself a
--- prefix (more keys follow); its desc is the registered group label, the exact
--- mapping's desc, or "+N keys". Sorted by display label.
---@param mode string
---@param pending string  raw bytes typed so far
---@return table[]
function M.continuations(mode, pending)
    local plen = #pending
    if plen == 0 then
        return {}
    end
    local seen, out = {}, {}
    -- `rest` is the part of a matching lhs after `pending`; `desc` describes that lhs.
    -- `is_real` is true for an actual mapping, false for a built-in preset.
    local function add(rest, desc, is_real)
        local fk = first_keystroke(rest)
        local disp = vim.fn.keytrans(fk)
        local e = seen[disp]
        if not e then
            e = { key = disp, raw = fk, desc = "", group = false, children = 0, real_leaf = false }
            seen[disp] = e
            out[#out + 1] = e
        end
        if #rest > #fk then
            e.group = true
            e.children = e.children + 1
        elseif is_real then
            -- exact real mapping. Real maps are fed before presets and buffer-local
            -- before global, so the first (highest-priority) desc wins. Mark the leaf so
            -- a preset for the SAME sequence can't override it with stale built-in text —
            -- a remapped key with no desc shows nothing rather than the wrong description.
            e.real_leaf = true
            if e.desc == "" then
                e.desc = desc
            end
        elseif e.desc == "" and not e.real_leaf then
            -- preset leaf: describes the built-in only when no real mapping shadows it
            e.desc = desc
        end
    end
    for _, map in ipairs(maps_for(mode)) do
        local lhs = map.lhsraw or map.lhs
        if #lhs > plen and lhs:sub(1, plen) == pending then
            add(lhs:sub(plen + 1), describe(map), true)
        end
    end
    if config.presets ~= false then
        for _, p in ipairs(presets.for_mode(mode)) do
            if #p.raw > plen and p.raw:sub(1, plen) == pending and not (p.when and not p.when()) then
                add(p.raw:sub(plen + 1), p.desc, false)
            end
        end
        -- LIVE content panels: register contents after `"`, mark targets after `'` / ```
        if mode == "n" or mode == "x" then
            if pending == '"' then
                local regs = '"0123456789abcdefghijklmnopqrstuvwxyz-.:%/=+*#'
                for i = 1, #regs do
                    local r = regs:sub(i, i)
                    local ok, content = pcall(vim.fn.getreg, r)
                    if ok and type(content) == "string" and content ~= "" then
                        add(r, (content:gsub("%s+", " "):gsub("^%s", "")))
                    end
                end
            elseif pending == "'" or pending == "`" then
                for _, m in ipairs(vim.fn.getmarklist(vim.api.nvim_get_current_buf())) do
                    local mark = m.mark:sub(2)
                    if mark:match("^%l$") then
                        local line = (vim.api.nvim_buf_get_lines(0, m.pos[2] - 1, m.pos[2], false)[1] or "")
                        add(mark, ("%d: %s"):format(m.pos[2], (line:gsub("^%s+", ""))))
                    end
                end
                for _, m in ipairs(vim.fn.getmarklist()) do
                    local mark = m.mark:sub(2)
                    if mark:match("^[%u%d]$") then
                        add(mark, ("%s:%d"):format(vim.fn.fnamemodify(m.file or "", ":t"), m.pos[2]))
                    end
                end
            end
        end
    end
    -- Finalize: apply the ignore list (and the parent group's strict whitelist, when it
    -- declares one) and pick the desc for group rows. A strict group's panel shows ONLY
    -- the keys declared in its config `keys` table; everything else still WORKS when
    -- typed — it is merely not displayed.
    local parent = group_entry(vim.fn.keytrans(pending), mode)
    local whitelist = (parent and parent.strict and parent.declared) or nil
    local function whitelisted(key)
        for _, d in ipairs(whitelist or {}) do
            if d == key or d:sub(1, #key) == key then
                return true -- declared directly, or a declared deeper sequence starts here
            end
        end
        return false
    end
    local by_use = config.sort_by_usage == true
    local res = {}
    for _, e in ipairs(out) do
        local full = vim.fn.keytrans(pending .. e.raw)
        if not is_ignored(full) and (not whitelist or whitelisted(e.key)) then
            if by_use then
                e._use = stats.get(mode, full)
            end
            -- description precedence: own groups label > parent's `keys` override >
            -- the mapping's desc
            local override = desc_override(full, mode)
            if e.group then
                local label = group_label(full, mode) or override
                if label then
                    e.desc = label
                end
                if config.counts ~= false then
                    e.desc = (e.desc ~= "" and (e.desc .. " ") or "") .. "+" .. e.children
                end
                e.color = M.group_color(full, mode)
            elseif override then
                e.desc = override
            end
            res[#res + 1] = e
        end
    end
    -- groups (keys that open a submenu) first — unless turned off — then by usage when
    -- enabled, then alphabetically
    local groups_first = config.sort_groups_first ~= false
    table.sort(res, function(a, b)
        if groups_first and a.group ~= b.group then
            return a.group
        end
        if by_use and a._use ~= b._use then
            return a._use > b._use
        end
        return a.key:lower() < b.key:lower()
    end)
    return res
end

--- The distinct trigger prefixes for `mode`: the first keystroke (raw bytes) of every
--- multi-keystroke mapping (global + buffer-local) and, with presets on, of every
--- built-in preset sequence — like which-key's `<auto>`. A plain single-key mapping is
--- not a prefix; keys listed in config.ignore are excluded.
---@param mode string
---@return string[]  raw first-keystrokes
function M.prefixes(mode)
    local set = {}
    for _, map in ipairs(maps_for(mode)) do
        local lhs = map.lhsraw or map.lhs
        local fk = first_keystroke(lhs)
        if #lhs > #fk then
            set[fk] = true
        end
    end
    if config.presets ~= false then
        for _, p in ipairs(presets.for_mode(mode)) do
            local fk = first_keystroke(p.raw)
            if #p.raw > #fk then
                set[fk] = true
            end
        end
        -- live content panels: registers and marks
        if mode == "n" or mode == "x" then
            set['"'] = true
            set["'"] = true
            set["`"] = true
        end
    end
    local out = {}
    for fk in pairs(set) do
        if not is_ignored(vim.fn.keytrans(fk)) then
            out[#out + 1] = fk
        end
    end
    return out
end

--- The exact mapping whose lhs equals `pending` (raw bytes) in `mode`, or nil. Buffer-local
--- maps win over global (they are searched first). Trigger maps are never returned (they
--- are filtered out of the list).
---@param mode string
---@param pending string
---@return table|nil
function M.find(mode, pending)
    for _, map in ipairs(maps_for(mode)) do
        if (map.lhsraw or map.lhs) == pending then
            return map
        end
    end
    return nil
end

return M
