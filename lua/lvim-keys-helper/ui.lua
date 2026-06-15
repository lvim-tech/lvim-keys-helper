-- lvim-keys-helper: the hint panel window.
-- Renders the continuation keystrokes from lvim-keys-helper.keymaps as a grid of badge
-- "buttons" — a coloured ` key ` badge followed by its ` description ` — mirroring the
-- :Messages pager chrome in lvim-utils. Badge colours cycle through the lvim-utils palette
-- (see init.set_highlights) so the panel is varied, not monochrome. Two runtime styles:
--   • mini — a compact window anchored to the bottom-right corner
--   • full — a full-width strip along the bottom of the editor
-- When the items don't fit, the grid is paged column-wise (the title shows "p/N") and the
-- host scrolls it with <C-d>/<C-u> via M.scroll(). The same buffer/window is reused and
-- resized so updates don't flicker.
--
---@module "lvim-keys-helper.ui"

local config = require("lvim-keys-helper.config")
local keymaps = require("lvim-keys-helper.keymaps")

local M = {}

local NS = vim.api.nvim_create_namespace("lvim_keys_helper")
local state = { buf = nil, win = nil, items = nil, title = nil, page = 1, pages = 1 }

--- Truncate `s` to `w` display cells, adding an ellipsis when it overflows.
---@param s string
---@param w integer
---@return string
local function fit(s, w)
    if vim.fn.strdisplaywidth(s) <= w then
        return s
    end
    return vim.fn.strcharpart(s, 0, math.max(0, w - 1)) .. "\xe2\x80\xa6"
end

--- The palette slot (1..#palette) for a colour name; `fallback` when unknown.
---@param color string|nil
---@param fallback integer
---@return integer
local function slot_of(color, fallback)
    for i, name in ipairs(config.palette or {}) do
        if name == color then
            return i
        end
    end
    return fallback
end

--- The palette slot for nesting level `depth` (cycled through the palette).
---@param depth integer
---@return integer
local function depth_slot(depth)
    local n = math.max(1, #(config.palette or {}))
    return ((math.max(1, depth) - 1) % n) + 1
end

--- Build the panel rows and per-segment highlights for `items`, targeting `avail`
--- display columns of inner width. Each cell is ` key `(badge) + ` desc `(text), laid out
--- column-major (read top→bottom, then right). Items that don't fit the height/width
--- budget are paged: only page `page` is rendered. Returns lines, highlight specs, the
--- content width, the total page count and the (clamped) current page.
---@param items table[]
---@param avail integer
---@param page integer
---@param fill boolean  stretch the columns so they span `avail` exactly (full style)
---@param panel_slot integer  palette slot of this panel (nesting level / group colour)
---@param group_slot integer  palette slot of the NEXT level — group rows wear it (they open that level)
---@return string[] lines, table[] hls, integer width, integer pages, integer page, table geom
local function layout(items, avail, page, fill, panel_slot, group_slot)
    local gap = config.columns.gap
    local group_icon = config.icons.group or ""

    -- Precompute each item's badge/desc text and the maximum widths (for aligned cells);
    -- widths are computed over ALL items so the panel doesn't resize between pages.
    local key_w, desc_w = 1, 1
    local cells = {}
    for i, it in ipairs(items) do
        local key = it.key .. (it.group and (" " .. group_icon) or "")
        local desc = (it.group and it.desc == "") and "+prefix" or it.desc
        -- plain keys carry the panel's level colour; group rows the NEXT level's colour
        -- (the level they open); a group with an assigned colour overrides either
        cells[i] = {
            key = key,
            desc = desc,
            group = it.group,
            slot = slot_of(it.color, it.group and group_slot or panel_slot),
        }
        key_w = math.max(key_w, vim.fn.strdisplaywidth(key))
        desc_w = math.max(desc_w, vim.fn.strdisplaywidth(desc))
    end
    key_w = math.min(key_w, config.columns.key_max or 14)
    desc_w = math.min(desc_w, config.columns.desc_max or 30)
    -- ` key ` badge + ` desc ` text → +2 padding cells each.
    local cell_w = math.max(config.columns.min_width, (key_w + 2) + (desc_w + 2))

    local ncols_fit = math.max(1, math.floor((avail + gap) / (cell_w + gap)))
    local max_rows = math.max(1, math.floor(vim.o.lines * config.win.max_height))
    local per_page = ncols_fit * max_rows
    local pages = math.max(1, math.ceil(#cells / per_page))
    page = math.min(math.max(1, page), pages)
    local slice = {}
    for i = (page - 1) * per_page + 1, math.min(#cells, page * per_page) do
        slice[#slice + 1] = cells[i]
    end

    local nrows = math.min(max_rows, math.ceil(#slice / ncols_fit))
    local ncols = math.max(1, math.ceil(#slice / nrows))
    -- geometry for mouse hit-testing (stored by render)
    local geom = { nrows = nrows, ncols = ncols, cell_w = cell_w, gap = gap, offset = (page - 1) * per_page }
    -- fill: hand the leftover width out to the ACTUAL columns (as extra desc padding),
    -- so the grid spans `avail` exactly instead of leaving a strip on the right
    local pad_extra = {}
    if fill then
        local leftover = math.max(0, avail - (ncols * (cell_w + gap) - gap))
        local base = math.floor(leftover / ncols)
        local rem = leftover % ncols
        for c = 0, ncols - 1 do
            pad_extra[c] = base + (c < rem and 1 or 0)
        end
    end
    geom.pad_extra = pad_extra

    local lines, hls = {}, {}
    for r = 1, nrows do
        lines[r] = ""
    end
    local width = 0
    for c = 0, ncols - 1 do
        for r = 1, nrows do
            local cell = slice[c * nrows + r]
            if cell then
                local line = lines[r]
                if c > 0 then
                    line = line .. string.rep(" ", gap)
                end
                -- badge: ` key ` padded to key_w
                local key = fit(cell.key, key_w)
                local kpad = string.rep(" ", key_w - vim.fn.strdisplaywidth(key))
                local badge = " " .. key .. kpad .. " "
                local b0 = #line
                line = line .. badge
                hls[#hls + 1] = { r - 1, b0, #line, "LvimKeysHelperBadge" .. cell.slot }
                -- desc: ` desc ` padded to desc_w (group rows use the italic Group accent)
                local desc = fit(cell.desc, desc_w)
                local dpad = string.rep(" ", desc_w - vim.fn.strdisplaywidth(desc) + (pad_extra[c] or 0))
                local text = " " .. desc .. dpad .. " "
                local d0 = #line
                line = line .. text
                local hl = (cell.group and "LvimKeysHelperGroup" or "LvimKeysHelperText") .. cell.slot
                hls[#hls + 1] = { r - 1, d0, #line, hl }
                lines[r] = line
                width = math.max(width, vim.fn.strdisplaywidth(line))
            end
        end
    end
    return lines, hls, width, pages, page, geom
end

--- Render state.items / state.title at state.page into the (reused) float.
---@return nil
local function render()
    local items = state.items or {}
    -- title: the pending keystrokes as tinted cells, joined by the breadcrumb icon.
    -- Each cell follows the nesting-level colour logic (key i = level i, a registered
    -- group colour overrides); the separator wears the light tint of the NEXT cell.
    local icon = (config.icons and config.icons.breadcrumb) or ""
    local tkeys = state.title_keys or {}
    local title, title_w = {}, 0
    local ranges = {} -- breadcrumb cell ranges (window columns) for mouse navigation
    -- captured count/register in front of the breadcrumb
    if state.count then
        local cell = " " .. state.count .. " "
        title[#title + 1] = { cell, "LvimKeysHelperFooterKey" }
        title[#title + 1] = { " ", "LvimKeysHelperBorder" }
        title_w = title_w + vim.fn.strdisplaywidth(cell) + 1
    end
    for i, k in ipairs(tkeys) do
        local cslot = slot_of(keymaps.group_color(table.concat(tkeys, "", 1, i), state.mode), depth_slot(i))
        if i > 1 then
            local sep = " " .. icon .. " "
            title[#title + 1] = { sep, "LvimKeysHelperText" .. cslot }
            title_w = title_w + vim.fn.strdisplaywidth(sep)
        end
        local cell_w = vim.fn.strdisplaywidth(k) + 2
        -- title text starts at window column 2 (after the left border cell)
        ranges[#ranges + 1] = { s = 2 + title_w, e = 2 + title_w + cell_w - 1, level = i }
        title[#title + 1] = { " " .. k .. " ", "LvimKeysHelperBadge" .. cslot }
        title_w = title_w + cell_w
    end
    state.title_ranges = ranges
    local ec, el = vim.o.columns, vim.o.lines
    local style = config.style == "full" and "full" or "mini"
    local win_cfg = config.win
    local avail = style == "full" and (ec - 2) or math.min(win_cfg.mini.max_width, ec - 4)

    -- panel colour: the group's assigned colour when set, else the nesting-level colour;
    -- group rows always advertise the next level's colour
    local depth = #(state.title_keys or {})
    local panel_slot = slot_of(state.color, depth_slot(depth))
    local group_slot = depth_slot(depth + 1)
    local lines, hls, content_w, pages, page, geom =
        layout(items, avail, state.page, style == "full", panel_slot, group_slot)
    state.pages, state.page, state.geom = pages, page, geom
    -- Footer legend rendered IN the bottom border (like the title in the top one):
    -- paging keys (only when there is something to page) + step-back key, as
    -- highlighted {text, group} chunks.
    local ckeys, labels = config.keys or {}, config.labels or {}
    local function keydisp(lhs)
        return vim.fn.keytrans(vim.api.nvim_replace_termcodes(lhs, true, true, true))
    end
    local parts = {}
    if state.exact then
        -- this prefix is ALSO a complete mapping: the run key executes it
        parts[#parts + 1] = { keydisp(ckeys.run or "<CR>"), fit(state.exact, 18) }
    end
    if pages > 1 then
        parts[#parts + 1] = { keydisp(ckeys.scroll_down or "<C-d>"), labels.next or "next" }
        parts[#parts + 1] = { keydisp(ckeys.scroll_up or "<C-u>"), labels.prev or "prev" }
    end
    if state.back then
        -- only one level or deeper in: at the root the back key has nowhere to go.
        -- The back cell wears the colour of the panel it RETURNS TO: the previous
        -- level's colour, or that group's registered colour override.
        local target = table.concat(tkeys, "", 1, math.max(0, depth - 1))
        local bslot = slot_of(keymaps.group_color(target, state.mode), depth_slot(math.max(1, depth - 1)))
        parts[#parts + 1] = { keydisp(ckeys.back or "<BS>"), labels.back or "back", bslot }
    end
    -- Each legend entry renders as a tinted cell (` key ` + ` label `, like the grid
    -- cells), the entries separated by plain border background; centered via footer_pos.
    local footer, footer_w = nil, 0
    if #parts > 0 then
        footer = {}
        for i, p in ipairs(parts) do
            if i > 1 then
                footer[#footer + 1] = { "  ", "LvimKeysHelperBorder" }
                footer_w = footer_w + 2
            end
            -- a part with a palette slot (back) wears that colour; the rest the accent
            local khl = p[3] and ("LvimKeysHelperBadge" .. p[3]) or "LvimKeysHelperFooterKey"
            local thl = p[3] and ("LvimKeysHelperText" .. p[3]) or "LvimKeysHelperFooter"
            footer[#footer + 1] = { " " .. p[1] .. " ", khl }
            footer[#footer + 1] = { " " .. p[2] .. " ", thl }
            footer_w = footer_w + #p[1] + #p[2] + 4
        end
        if pages > 1 then
            local ind = " " .. page .. "/" .. pages .. " "
            footer[#footer + 1] = { "  ", "LvimKeysHelperBorder" }
            footer[#footer + 1] = { ind, "LvimKeysHelperFooter" }
            footer_w = footer_w + 2 + #ind
        end
    end
    content_w = math.max(content_w, footer_w)
    -- blank padding rows above the grid (below the title), and below it — the latter
    -- only when a legend follows, otherwise the grid would end with pointless empty
    -- rows above the (empty) border
    local pad_top = win_cfg.padding_top or 1
    for _, h in ipairs(hls) do
        h[1] = h[1] + pad_top
    end
    for _ = 1, pad_top do
        table.insert(lines, 1, "")
    end
    if footer then
        for _ = 1, win_cfg.padding_bottom or 1 do
            lines[#lines + 1] = ""
        end
    end
    local height = #lines
    local width = style == "full" and (ec - 2) or math.min(avail, content_w)
    width = math.max(width, title_w + 2)

    local margin = style == "full" and win_cfg.full.margin or win_cfg.mini.margin
    -- above the command line (border = 2 rows; extra cmdheight beyond 1 pushes it up)
    local row = el - height - 2 - margin - math.max(0, vim.o.cmdheight - 1)
    local col = style == "full" and 0 or (ec - width - 2 - margin)
    row, col = math.max(0, row), math.max(0, col)

    if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then
        state.buf = vim.api.nvim_create_buf(false, true)
        vim.bo[state.buf].bufhidden = "wipe"
    end
    vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
    vim.api.nvim_buf_clear_namespace(state.buf, NS, 0, -1)
    for _, h in ipairs(hls) do
        pcall(vim.api.nvim_buf_set_extmark, state.buf, NS, h[1], h[2], {
            end_col = h[3],
            hl_group = h[4],
        })
    end

    local opts = {
        relative = "editor",
        row = row,
        col = col,
        width = width,
        height = height,
        style = "minimal",
        border = win_cfg.border,
        focusable = false,
        noautocmd = true,
        zindex = win_cfg.zindex,
        title = #title > 0 and title or nil,
        title_pos = #title > 0 and (win_cfg.title_pos or "left") or nil,
        -- always pass a footer: nvim_win_set_config leaves omitted fields UNCHANGED, so a
        -- nil here would keep the previous legend on screen (e.g. "<BS> back" after
        -- stepping back to the root). The empty legend is an invisible border-bg space.
        footer = footer or { { " ", "LvimKeysHelperBorder" } },
        footer_pos = win_cfg.footer_pos or "center",
    }
    if state.win and vim.api.nvim_win_is_valid(state.win) then
        vim.api.nvim_win_set_config(state.win, opts)
    else
        state.win = vim.api.nvim_open_win(state.buf, false, opts)
        vim.wo[state.win].winhighlight =
            "Normal:LvimKeysHelperNormal,FloatBorder:LvimKeysHelperBorder,FloatTitle:LvimKeysHelperTitle"
        vim.wo[state.win].winblend = win_cfg.winblend
        vim.wo[state.win].wrap = false -- never wrap a cell onto a 2nd line under the key
    end
    -- The host blocks in getcharstr right after showing/updating the panel, and getcharstr
    -- does NOT redraw — without an explicit redraw the float exists but is never painted.
    vim.cmd("redraw")
end

--- Show (or update) the panel for `items`, titled with the pending sequence. `title` is
--- the list of its keystrokes (display form) — they render as tinted cells joined by the
--- breadcrumb icon; a plain string is treated as a single keystroke. Recognised `opts`:
---   back   panel is one level or deeper into a sequence (the <BS> legend makes sense)
---   exact  label of the complete mapping behind this prefix (<CR> legend)
---   color  palette-name colour of this panel (a group's colour; default: nesting level)
---@param items table[]
---@param title string|string[]
---@param opts? { back?: boolean, exact?: string, color?: string, mode?: string, count?: integer }
---@return nil
function M.show(items, title, opts)
    if #items == 0 then
        return M.hide()
    end
    opts = opts or {}
    local tkeys = type(title) == "table" and title or { title }
    local tid = table.concat(tkeys, "\1")
    if tid ~= state.title then
        state.page = 1 -- a new (or narrowed) sequence starts back at the first page
    end
    state.items, state.title, state.title_keys = items, tid, tkeys
    state.back, state.exact, state.color, state.mode = opts.back == true, opts.exact, opts.color, opts.mode
    state.count = opts.count
    -- Re-lay-out on resize: row/col and the column budget all derive from `vim.o.lines`/`columns`,
    -- so a re-render re-fits and repositions the panel. Installed while shown, torn down in hide().
    if not state.resize_au then
        state.resize_au = vim.api.nvim_create_augroup("LvimKeysHelperResize", { clear = true })
        vim.api.nvim_create_autocmd("VimResized", {
            group = state.resize_au,
            callback = function()
                if M.visible() then
                    render()
                end
            end,
        })
    end
    render()
end

--- Move `delta` pages (±1) and re-render. No-op when there is nothing to scroll.
---@param delta integer
---@return nil
function M.scroll(delta)
    if not (state.items and M.visible()) then
        return
    end
    local page = math.min(math.max(1, state.page + delta), state.pages)
    if page ~= state.page then
        state.page = page
        render()
    end
end

--- Whether the panel is visible and has more than one page (so <C-d>/<C-u> scroll it).
---@return boolean
function M.can_scroll()
    return state.pages > 1 and M.visible()
end

--- Hide the panel (the buffer is kept for reuse).
---@return nil
function M.hide()
    if state.win and vim.api.nvim_win_is_valid(state.win) then
        pcall(vim.api.nvim_win_close, state.win, true)
        -- paint the close immediately too — the host may block again before any natural
        -- redraw, which would leave a stale panel image on screen
        vim.cmd("redraw")
    end
    state.win = nil
    state.items, state.title, state.title_keys, state.back, state.exact, state.color = nil, nil, nil, false, nil, nil
    state.count, state.geom, state.title_ranges = nil, nil, nil
    state.page, state.pages = 1, 1
    if state.resize_au then
        pcall(vim.api.nvim_del_augroup_by_id, state.resize_au)
        state.resize_au = nil
    end
end

--- Whether the panel is currently visible.
---@return boolean
function M.visible()
    return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

--- The panel's window handle while visible, else nil.
---@return integer|nil
function M.win()
    return M.visible() and state.win or nil
end

--- The item under a mouse position (winrow/wincol as reported by getmousepos, i.e.
--- 1-based including the border), or nil when the click is not on a cell.
---@param winrow integer
---@param wincol integer
---@return table|nil
function M.hit(winrow, wincol)
    local g = state.geom
    if not (g and state.items) then
        return nil
    end
    -- past the top border and the padding rows, into the grid
    local pad_top = (config.win.padding_top or 1)
    local r = winrow - 1 - pad_top
    if r < 1 or r > g.nrows then
        return nil
    end
    local x = wincol - 1 -- text column (1-based) after the left border
    local cum = 0
    for c = 0, g.ncols - 1 do
        local w = g.cell_w + ((g.pad_extra or {})[c] or 0)
        if x > cum and x <= cum + w then
            return state.items[g.offset + c * g.nrows + r]
        end
        cum = cum + w + g.gap
    end
    return nil
end

--- The breadcrumb level under window column `wincol` of the title border row, or nil.
--- (Reliable for win.title_pos = "left".)
---@param wincol integer
---@return integer|nil
function M.title_level(wincol)
    for _, r in ipairs(state.title_ranges or {}) do
        if wincol >= r.s and wincol <= r.e then
            return r.level
        end
    end
    return nil
end

return M
