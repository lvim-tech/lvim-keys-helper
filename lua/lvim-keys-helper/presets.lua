-- lvim-keys-helper: descriptions for Neovim's BUILT-IN multi-key sequences (which-key's
-- "presets"). These are not mappings — nvim_get_keymap can't see them — so without this
-- table the panel would only ever show user/plugin mappings. When config.presets is on,
-- keymaps.continuations merges these into the panel (a real mapping's desc always wins)
-- and keymaps.prefixes adds their first keystrokes (g, z, [, ], <C-w>, i, a) as triggers.
--
---@module "lvim-keys-helper.presets"

local M = {}

--- Raw bytes for a lhs written in vim notation.
---@param lhs string
---@return string
local function k(lhs)
    return vim.api.nvim_replace_termcodes(lhs, true, true, true)
end

-- ── building blocks ────────────────────────────────────────────────────────────

-- g-prefixed motions, valid in n / x / o.
local g_motions = {
    ["gg"] = "Go to first line (or line N)",
    ["ge"] = "End of previous word",
    ["gE"] = "End of previous WORD",
    ["g_"] = "Last non-blank of line",
    ["g0"] = "Start of screen line",
    ["g^"] = "First non-blank of screen line",
    ["g$"] = "End of screen line",
    ["gm"] = "Middle of screen line",
    ["gM"] = "Middle of text line",
    ["gj"] = "Down (screen line)",
    ["gk"] = "Up (screen line)",
    ["gn"] = "Next search match (select)",
    ["gN"] = "Previous search match (select)",
}

-- g-prefixed operators / case commands, valid in n and x.
local g_operators = {
    ["gu"] = "Lowercase",
    ["gU"] = "Uppercase",
    ["g~"] = "Toggle case",
    ["gq"] = "Format",
    ["gw"] = "Format, keep cursor",
    ["g?"] = "ROT13 encode",
    ["gJ"] = "Join without spaces",
}

-- g-prefixed normal-mode-only commands.
local g_normal = {
    ["gf"] = "Open file under cursor",
    ["gF"] = "Open file under cursor at line",
    ["gx"] = "Open with system handler",
    ["gi"] = "Insert at last insert position",
    ["gv"] = "Reselect last visual selection",
    ["gt"] = "Next tab page",
    ["gT"] = "Previous tab page",
    ["gd"] = "Go to local declaration",
    ["gD"] = "Go to global declaration",
    ["g*"] = "Search word forward (partial)",
    ["g#"] = "Search word backward (partial)",
    ["g;"] = "Older change position",
    ["g,"] = "Newer change position",
    ["gp"] = "Paste after, cursor follows",
    ["gP"] = "Paste before, cursor follows",
    ["ga"] = "Character info",
    ["g<"] = "Last command output",
}

-- ── availability predicates ──────────────────────────────────────────────────────
-- Some built-ins only make sense in a particular window state. The panel hides them
-- when that state is off — folds need 'foldenable', spelling needs 'spell', diff motions
-- need 'diff' (all window-local, read against the current window at render time).
local function fold_on()
    return vim.wo.foldenable
end
local function spell_on()
    return vim.wo.spell
end
local function diff_on()
    return vim.wo.diff
end

-- z-prefixed scrolling + 'foldenable' toggle — always available (normal mode).
local z_scroll = {
    ["zz"] = "Center cursor line",
    ["zt"] = "Cursor line to top",
    ["zb"] = "Cursor line to bottom",
    ["zH"] = "Scroll half screen left",
    ["zL"] = "Scroll half screen right",
    ["zs"] = "Scroll cursor to left edge",
    ["ze"] = "Scroll cursor to right edge",
    ["zi"] = "Toggle 'foldenable'",
}

-- z-prefixed fold commands — only when folding is enabled.
local z_folds = {
    ["zv"] = "View cursor line (open folds)",
    ["za"] = "Toggle fold",
    ["zA"] = "Toggle fold recursively",
    ["zo"] = "Open fold",
    ["zO"] = "Open folds recursively",
    ["zc"] = "Close fold",
    ["zC"] = "Close folds recursively",
    ["zR"] = "Open all folds",
    ["zM"] = "Close all folds",
    ["zr"] = "Reduce folding",
    ["zm"] = "More folding",
    ["zf"] = "Create fold",
    ["zd"] = "Delete fold",
    ["zD"] = "Delete folds recursively",
    ["zE"] = "Eliminate all folds",
    ["zj"] = "Next fold start",
    ["zk"] = "Previous fold end",
}

-- z-prefixed spelling commands — only when 'spell' is on.
local z_spell = {
    ["zg"] = "Add word to spellfile",
    ["zw"] = "Mark word as wrong",
    ["zug"] = "Undo zg",
    ["zuw"] = "Undo zw",
    ["z="] = "Spelling suggestions",
}

-- [ / ] motions, valid in n / x / o — always available.
local brackets = {
    ["[["] = "Previous section start",
    ["]]"] = "Next section start",
    ["[]"] = "Previous section end",
    ["]["] = "Next section end",
    ["[("] = "Previous unmatched (",
    ["])"] = "Next unmatched )",
    ["[{"] = "Previous unmatched {",
    ["]}"] = "Next unmatched }",
    ["[m"] = "Previous method start",
    ["]m"] = "Next method start",
    ["[M"] = "Previous method end",
    ["]M"] = "Next method end",
}

-- [ / ] fold / spell / diff motions — gated on the matching window state.
local brackets_folds = {
    ["[z"] = "Start of open fold",
    ["]z"] = "End of open fold",
}
local brackets_spell = {
    ["[s"] = "Previous misspelled word",
    ["]s"] = "Next misspelled word",
}
local brackets_diff = {
    ["[c"] = "Previous diff change",
    ["]c"] = "Next diff change",
}

local brackets_normal = {
    ["[p"] = "Paste before, adjust indent",
    ["]p"] = "Paste after, adjust indent",
}

-- <C-w> window commands (normal mode).
local windows = {
    ["<C-w>s"] = "Split horizontally",
    ["<C-w>v"] = "Split vertically",
    ["<C-w>n"] = "New window",
    ["<C-w>w"] = "Next window",
    ["<C-w>W"] = "Previous window",
    ["<C-w>p"] = "Last accessed window",
    ["<C-w>t"] = "Top-left window",
    ["<C-w>b"] = "Bottom-right window",
    ["<C-w>h"] = "Window left",
    ["<C-w>j"] = "Window below",
    ["<C-w>k"] = "Window above",
    ["<C-w>l"] = "Window right",
    ["<C-w>H"] = "Move window far left",
    ["<C-w>J"] = "Move window to bottom",
    ["<C-w>K"] = "Move window to top",
    ["<C-w>L"] = "Move window far right",
    ["<C-w>q"] = "Quit window",
    ["<C-w>c"] = "Close window",
    ["<C-w>o"] = "Only window (close others)",
    ["<C-w>="] = "Equalize windows",
    ["<C-w>+"] = "Increase height",
    ["<C-w>-"] = "Decrease height",
    ["<C-w>>"] = "Increase width",
    ["<C-w><lt>"] = "Decrease width",
    ["<C-w>_"] = "Max height",
    ["<C-w>|"] = "Max width",
    ["<C-w>r"] = "Rotate windows",
    ["<C-w>R"] = "Rotate windows backward",
    ["<C-w>x"] = "Exchange windows",
    ["<C-w>T"] = "Move window to new tab",
}

-- i / a text objects, valid in x and o.
local textobjects = {
    ["iw"] = "inner word",
    ["aw"] = "a word",
    ["iW"] = "inner WORD",
    ["aW"] = "a WORD",
    ["is"] = "inner sentence",
    ["as"] = "a sentence",
    ["ip"] = "inner paragraph",
    ["ap"] = "a paragraph",
    ["i("] = "inner ()",
    ["a("] = "a ()",
    ["i)"] = "inner ()",
    ["a)"] = "a ()",
    ["ib"] = "inner ()",
    ["ab"] = "a ()",
    ["i{"] = "inner {}",
    ["a{"] = "a {}",
    ["i}"] = "inner {}",
    ["a}"] = "a {}",
    ["iB"] = "inner {}",
    ["aB"] = "a {}",
    ["i["] = "inner []",
    ["a["] = "a []",
    ["i]"] = "inner []",
    ["a]"] = "a []",
    ["i<lt>"] = "inner <>",
    ["a<lt>"] = "a <>",
    ["i>"] = "inner <>",
    ["a>"] = "a <>",
    ['i"'] = 'inner ""',
    ['a"'] = 'a ""',
    ["i'"] = "inner ''",
    ["a'"] = "a ''",
    ["i`"] = "inner ``",
    ["a`"] = "a ``",
    ["it"] = "inner tag",
    ["at"] = "a tag",
}

-- ── per-mode composition ───────────────────────────────────────────────────────

-- Each section is { tbl = <{lhs=desc}>, when = <predicate|nil> }. A nil predicate means
-- always available; otherwise the section's entries are shown only when it returns true.
local function S(tbl, when)
    return { tbl = tbl, when = when }
end

local SECTIONS = {
    n = {
        S(g_motions),
        S(g_operators),
        S(g_normal),
        S(z_scroll),
        S(z_folds, fold_on),
        S(z_spell, spell_on),
        S(brackets),
        S(brackets_folds, fold_on),
        S(brackets_spell, spell_on),
        S(brackets_diff, diff_on),
        S(brackets_normal),
        S(windows),
    },
    x = {
        S(g_motions),
        S(g_operators),
        S(brackets),
        S(brackets_spell, spell_on),
        S(brackets_diff, diff_on),
        S(textobjects),
    },
    o = {
        S(g_motions),
        S(brackets),
        S(brackets_spell, spell_on),
        S(brackets_diff, diff_on),
        S(textobjects),
    },
}

local cache = {} ---@type table<string, table[]>

--- The preset entries for `mode`, each as { raw = <bytes>, desc = <string>, when =
--- <predicate|nil> }. Cached per mode (the data is static; the predicates are evaluated
--- by the caller at render time).
---@param mode string
---@return table[]
function M.for_mode(mode)
    local hit = cache[mode]
    if hit then
        return hit
    end
    local out = {}
    for _, section in ipairs(SECTIONS[mode] or {}) do
        for lhs, desc in pairs(section.tbl) do
            out[#out + 1] = { raw = k(lhs), desc = desc, when = section.when }
        end
    end
    cache[mode] = out
    return out
end

return M
