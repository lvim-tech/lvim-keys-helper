-- lvim-keys-helper: maintenance tools behind the :LvimKeysHelper subcommands —
--   doctor      audit the keymap landscape (conflicts, missing descs, orphan labels…)
--   cheatsheet  render the whole key tree into a scratch buffer
--   stats       show the most used sequences
--
---@module "lvim-keys-helper.tools"

local config = require("lvim-keys-helper.config")
local keymaps = require("lvim-keys-helper.keymaps")
local stats = require("lvim-keys-helper.stats")

local M = {}

--- Open `lines` in a new markdown scratch buffer (one per call).
---@param title string
---@param lines string[]
---@return nil
local function scratch(title, lines)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "markdown"
    vim.api.nvim_buf_set_name(buf, title)
    vim.cmd("botright split")
    vim.api.nvim_win_set_buf(0, buf)
end

--- All maps of `mode` (buffer-local + global), raw lhs canonicalized, triggers and
--- <Plug>/<SNR> excluded.
---@param mode string
---@return table[]
local function maps_of(mode)
    local out = {}
    local function take(list, buffer)
        for _, m in ipairs(list) do
            local lhs = m.lhsraw or m.lhs
            if lhs and lhs ~= "" and m.desc ~= keymaps.TRIGGER_DESC then
                local canon = keymaps.canon(lhs)
                local head = canon:sub(1, 3)
                local plug = vim.api.nvim_replace_termcodes("<Plug>", true, true, true)
                local snr = vim.api.nvim_replace_termcodes("<SNR>", true, true, true)
                if head ~= plug and head ~= snr then
                    out[#out + 1] = { raw = canon, map = m, buffer = buffer }
                end
            end
        end
    end
    take(vim.api.nvim_buf_get_keymap(0, mode), true)
    take(vim.api.nvim_get_keymap(mode), false)
    return out
end

--- Audit the mappings and the groups config; render the findings.
---@return nil
function M.doctor()
    local lines = { "# lvim-keys-helper doctor", "" }
    for _, mode in ipairs(config.trigger_modes or { "n" }) do
        local maps = maps_of(mode)
        local by_raw = {}
        for _, e in ipairs(maps) do
            by_raw[e.raw] = by_raw[e.raw] or e
        end
        local conflicts, no_desc, nops, shadowed = {}, {}, {}, {}
        for _, e in ipairs(maps) do
            -- exact mapping that is also a prefix of a longer one (ambiguity)
            for raw in pairs(by_raw) do
                if #raw > #e.raw and raw:sub(1, #e.raw) == e.raw then
                    conflicts[#conflicts + 1] = ("`%s` (%s) is also a prefix of `%s`"):format(
                        vim.fn.keytrans(e.raw),
                        e.map.desc or "no desc",
                        vim.fn.keytrans(raw)
                    )
                    break
                end
            end
            local m = e.map
            if (not m.desc or m.desc == "") and m.callback == nil and (m.rhs == nil or m.rhs == "") then
                nops[#nops + 1] = "`" .. vim.fn.keytrans(e.raw) .. "` (<Nop> placeholder)"
            elseif not m.desc or m.desc == "" then
                no_desc[#no_desc + 1] = ("`%s` → %s"):format(vim.fn.keytrans(e.raw), m.rhs or "<lua callback>")
            end
            -- a buffer-local lhs hiding an identical global one
            if e.buffer then
                for _, g in ipairs(maps) do
                    if not g.buffer and g.raw == e.raw then
                        shadowed[#shadowed + 1] = ("`%s` (global hidden by buffer-local)"):format(
                            vim.fn.keytrans(e.raw)
                        )
                        break
                    end
                end
            end
        end
        -- orphan group labels: registered sequences with no mapping behind/under them
        local orphans = {}
        for lhs in pairs(config.groups or {}) do
            local raw = vim.api.nvim_replace_termcodes(lhs, true, true, true)
            local found = false
            for _, e in ipairs(maps) do
                if e.raw:sub(1, #raw) == raw then
                    found = true
                    break
                end
            end
            if not found and mode == (config.trigger_modes or { "n" })[1] then
                orphans[#orphans + 1] = "`" .. vim.fn.keytrans(raw) .. "`"
            end
        end
        local function section(name, rows)
            if #rows > 0 then
                lines[#lines + 1] = ("## %s — mode %s (%d)"):format(name, mode, #rows)
                local seen = {}
                for _, r in ipairs(rows) do
                    if not seen[r] then
                        seen[r] = true
                        lines[#lines + 1] = "- " .. r
                    end
                end
                lines[#lines + 1] = ""
            end
        end
        section("Mapping + prefix conflicts", conflicts)
        section("Missing descriptions", no_desc)
        section("<Nop> placeholders", nops)
        section("Globals shadowed buffer-locally", shadowed)
        section("Orphan group labels (no mappings)", orphans)
    end
    if #lines == 2 then
        lines[#lines + 1] = "All clean."
    end
    scratch("keys-helper://doctor", lines)
end

--- Render the whole detected key tree into a scratch buffer.
---@return nil
function M.cheatsheet()
    local lines = { "# Keymap cheatsheet", "" }
    local function walk(mode, pending, depth)
        if depth > 4 then
            return
        end
        for _, e in ipairs(keymaps.continuations(mode, pending)) do
            lines[#lines + 1] = ("%s- **%s** — %s"):format(string.rep("  ", depth), e.key, e.desc)
            if e.group then
                walk(mode, pending .. e.raw, depth + 1)
            end
        end
    end
    for _, mode in ipairs(config.trigger_modes or { "n" }) do
        lines[#lines + 1] = "## Mode " .. mode
        lines[#lines + 1] = ""
        local roots = keymaps.prefixes(mode)
        table.sort(roots, function(a, b)
            return vim.fn.keytrans(a):lower() < vim.fn.keytrans(b):lower()
        end)
        for _, fk in ipairs(roots) do
            lines[#lines + 1] = "### " .. vim.fn.keytrans(fk)
            walk(mode, fk, 0)
            lines[#lines + 1] = ""
        end
    end
    scratch("keys-helper://cheatsheet", lines)
end

--- Show the most used sequences.
---@param n? number
---@return nil
function M.stats(n)
    local rows = stats.top(n or 30)
    local lines = { "# Most used sequences", "" }
    if #rows == 0 then
        lines[#lines + 1] = "No data yet."
    end
    for _, r in ipairs(rows) do
        lines[#lines + 1] = ("- %4d × [%s] `%s`"):format(r.count, r.mode, r.seq)
    end
    scratch("keys-helper://stats", lines)
end

return M
