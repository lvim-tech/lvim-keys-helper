-- lvim-keys-helper: :checkhealth lvim-keys-helper.
-- Diagnoses the things that make a which-key REPLACEMENT misbehave in ways the user
-- cannot see from the panel alone: a rival prefix-grabbing plugin still live (which-key /
-- mini.clue → double triggers), which stats backend actually opened (sqlite vs the JSON
-- fallback), a config that is internally inconsistent (bad style/delay/modes), and the
-- terminal keyboard-protocol dependency of <C-…>/<F…>/meta triggers. Everything here is
-- read-only reporting — it never mutates config or state.
--
---@module "lvim-keys-helper.health"

local config = require("lvim-keys-helper.config")
local stats = require("lvim-keys-helper.stats")

local M = {}

-- Neovim keymap mode short-names accepted in config.trigger_modes.
---@type table<string, boolean>
local VALID_MODES = {
    n = true,
    i = true,
    c = true,
    v = true,
    x = true,
    s = true,
    o = true,
    t = true,
    l = true,
}

-- Rival "hint on a prefix" plugins: if any is LIVE it also intercepts the same prefixes
-- and the user sees double popups / a swallowed second keystroke. Keyed by require name.
---@type table<string, string>
local RIVALS = {
    ["which-key"] = "which-key",
    ["mini.clue"] = "mini.clue",
}

--- Warn on any rival prefix-hint plugin that is loaded (or merely installed) alongside us.
---@param health table  the vim.health reporter
---@return nil
local function check_rivals(health)
    for mod, label in pairs(RIVALS) do
        if package.loaded[mod] then
            health.warn(
                ("%s is loaded — both grab mapping prefixes, so triggers can double-fire; disable one"):format(label)
            )
        elseif #vim.api.nvim_get_runtime_file("lua/" .. mod:gsub("%.", "/") .. "/", false) > 0 then
            health.info(("%s is installed but not loaded — keep it lazy/off to avoid prefix conflicts"):format(label))
        end
    end
end

--- Validate the live config table; error/warn on each violation, ok when clean.
---@param health table  the vim.health reporter
---@return nil
local function check_config(health)
    local problems = 0

    if config.style ~= "mini" and config.style ~= "full" then
        health.error(('style must be "mini" or "full" (got %s)'):format(vim.inspect(config.style)))
        problems = problems + 1
    end

    for _, field in ipairs({ "delay", "recompute_debounce" }) do
        local v = config[field]
        if type(v) ~= "number" or v < 0 then
            health.error(("%s must be a number >= 0 (got %s)"):format(field, vim.inspect(v)))
            problems = problems + 1
        end
    end

    local modes = config.trigger_modes
    if type(modes) ~= "table" or #modes == 0 then
        health.error("trigger_modes must be a non-empty list of mode strings")
        problems = problems + 1
    else
        for _, m in ipairs(modes) do
            if type(m) ~= "string" or not VALID_MODES[m] then
                health.error(("trigger_modes has an invalid mode %s"):format(vim.inspect(m)))
                problems = problems + 1
            end
        end
    end

    if type(config.palette) ~= "table" or #config.palette == 0 then
        health.error("palette must be a non-empty list of colour names")
        problems = problems + 1
    end

    if type(config.groups) ~= "table" then
        health.error(("groups must be a table (got %s)"):format(type(config.groups)))
        problems = problems + 1
    end

    if problems == 0 then
        health.ok("config valid")
    end
end

--- Run the health report.
---@return nil
function M.check()
    local health = vim.health
    health.start("lvim-keys-helper")

    if vim.fn.has("nvim-0.10") == 1 then
        health.ok("Neovim >= 0.10")
    else
        health.error("Neovim >= 0.10 is required (vim.uv, keytrans, extmark end_col)")
    end

    local ok_utils = pcall(require, "lvim-utils.utils")
    local ok_colors, colors = pcall(require, "lvim-utils.colors")
    if ok_utils and ok_colors and type(colors.blend) == "function" then
        health.ok("lvim-utils found (palette + merge)")
    else
        health.warn("lvim-utils not found — falling back to plain highlight links and tbl_deep_extend")
    end

    -- Conflicting prefix-hint plugins — the headline check for a which-key replacement.
    check_rivals(health)

    local ok_kh, kh = pcall(require, "lvim-keys-helper")
    if not ok_kh then
        health.error("lvim-keys-helper failed to load: " .. tostring(kh))
        return
    end

    if config.enabled then
        local n = kh.trigger_count()
        if n > 0 then
            health.ok(
                ("enabled — %d trigger(s) installed for modes { %s }"):format(
                    n,
                    table.concat(config.trigger_modes or {}, ", ")
                )
            )
        else
            health.warn("enabled but no triggers installed — was setup() called?")
        end
    else
        health.info("disabled (enable with :LvimKeysHelper enable)")
    end

    -- Per-buffer opt-out: a consumer (e.g. lvim-utils.dock) that fully owns a buffer's keys
    -- sets vim.b.lvim_keys_helper_disable, so the helper installs no triggers there. Report it
    -- when checkhealth runs from such a buffer — otherwise "no triggers here" looks like a bug.
    if vim.b.lvim_keys_helper_disable then
        health.info("current buffer opted out (vim.b.lvim_keys_helper_disable) — a consumer owns its keys")
    end

    health.info(
        ("delay=%dms  style=%s  presets=%s  groups=%d  ignore=%d"):format(
            config.delay,
            config.style,
            tostring(config.presets ~= false),
            vim.tbl_count(config.groups or {}),
            #(config.ignore or {})
        )
    )

    -- Config validation — internally inconsistent options fail here, not at runtime.
    check_config(health)

    -- Stats backend: report which persistence path the read/write side actually opened.
    if stats.backend() == "sqlite" then
        health.ok("stats backend: sqlite.lua")
    else
        health.info("stats backend: JSON fallback (install sqlite.lua for a shared DB)")
    end

    if not vim.o.timeout then
        health.warn("'notimeout' is set — triggers (and exact-match resolution) never fire on pause")
    end

    -- Terminal keyboard-protocol note. <C-…>, <F1>/<F…> and meta (<M-…>) triggers are only
    -- delivered to Neovim when the terminal speaks CSI-u (kitty keyboard protocol / modifyOtherKeys);
    -- a plain terminal silently drops some of them, so a configured trigger key simply never fires.
    local special = {}
    for _, key in pairs(config.keys or {}) do
        -- <C-…>/<M-…>/<A-…>/<D-…> modifiers or a function key <F1>..<F12>
        if type(key) == "string" and (key:match("<[cmadCMAD]%-") or key:match("<[fF]%d")) then
            special[#special + 1] = key
        end
    end
    if #special > 0 then
        health.info(
            ("control/function/meta keys in use (%s) depend on the terminal's CSI-u / kitty-keyboard support; "):format(
                table.concat(special, " ")
            )
                .. "if a configured trigger key never fires, verify the terminal delivers it (e.g. :lua print(vim.fn.getcharstr()))"
        )
    end
end

return M
