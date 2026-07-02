-- lvim-keys-helper: the live configuration table.
-- Holds the defaults; setup() merges user overrides into it in place, so every
-- require("lvim-keys-helper.config") reader sees the effective values. All of
-- `enabled`, `delay` and `style` are designed to be flipped at runtime (the panel
-- reads them live), so the control center can toggle them without a restart.
--
---@module "lvim-keys-helper.config"

---@class LvimKeysHelperConfig
---@field enabled            boolean              Whether the hint panel shows at all
---@field delay              integer              Milliseconds of inactivity before the panel opens
---@field style              "mini"|"full"        Panel layout: mini = compact bottom-right, full = full-width bottom
---@field debug              boolean              Write a trace log (see :LvimKeysHelper debug / log)
---@field trigger_modes      string[]             Vim modes the helper watches (n/x/o…)
---@field presets            boolean              Show Neovim's built-in sequences (g/z/[/]/<C-w>/text objects)
---@field groups             table<string,string|table> Group labels (string) or { label, color = <palette name> }
---@field ignore             string[]             Sequences (vim notation) the helper never handles
---@field sort_groups_first  boolean              Sort group rows before plain keys in the grid
---@field sort_by_usage      boolean              Sort rows by execution count (see :LvimKeysHelper stats)
---@field watch_mappings     boolean              Refresh triggers when maps are defined outside BufEnter
---@field counts             boolean              Append the "+N" child count to group rows
---@field keys               table                Panel control keys (vim notation)
---@field labels             table                Texts used in the footer legend
---@field tint               table                Blend factors for the strong/light background tints
---@field colors             table                Palette names for the panel background / accent
---@field win                table                Window geometry/appearance per style
---@field columns            table                Column layout (widths, gap)
---@field icons              table                Glyphs for group rows / the title breadcrumb
---@field palette            string[]             Accent colours cycled per nesting level
---@field recompute_debounce integer              Milliseconds the buffer-change trigger recompute is debounced

---@type LvimKeysHelperConfig
return {
    enabled = true,
    delay = 200,
    style = "mini",
    debug = false, -- write a trace log (see :LvimKeysHelper debug / log)
    -- Modes the helper watches. Trigger prefixes are auto-detected from the actual mappings
    -- in each mode (the first keystroke of every multi-key mapping), recomputed per buffer —
    -- exactly like which-key's `<auto>`. So a key is only intercepted when it really starts a
    -- mapping (e.g. `g` only when `gd`/`gr` exist), and never interferes otherwise.
    trigger_modes = { "n", "x", "o" },
    -- Built-in key descriptions (which-key's "presets"): native g/z/[/]/<C-w>/text-object
    -- sequences are shown in the panel alongside real mappings, and their first keystrokes
    -- become triggers too. A real mapping's desc always wins over a preset's.
    presets = true,
    -- Group labels, keyed by sequence in vim notation (<leader> works). A group row whose
    -- sequence is registered here shows the label instead of the "+N keys" placeholder.
    -- A table value may also assign a COLOR (palette name only — the tints are derived
    -- automatically; overrides the nesting level's colour for the group's row and panel),
    -- declare/define child KEYS, and be STRICT:
    --   groups = {
    --       ["<leader>f"] = "Find",
    --       ["<leader>g"] = {
    --           "Git", color = "red",
    --           mode = "n", -- scope the entry: "n" or { "n", "x" }; without it the
    --                       -- label/color/strict/keys apply in EVERY mode
    --           sticky = false, -- true: after a direct child runs, the panel re-opens
    --                           -- (hydra-style) until <Esc>/back — for repeatable actions
    --           delay = 50,     -- per-group popup delay override (ms)
    --           strict = false, -- true: the panel shows ONLY the keys declared below
    --                           -- (the rest still work, just hidden) and opens INSTANTLY
    --                           -- (a curated menu); others honour the default delay
    --           keys = {
    --               b = "Blame", -- description override
    --               -- a table DEFINES a mapping, vim.keymap.set syntax: [1] = rhs
    --               -- (keys / <Cmd> string / function), rest = native opts
    --               l = { "<Cmd>Telescope git_commits<CR>", desc = "Git Log" },
    --               o = { function() end, desc = "Open", mode = { "n", "x" } },
    --           },
    --       },
    --   },
    groups = {},
    -- Sequences (vim notation) the helper never handles: a single key listed here is not
    -- installed as a trigger at all; a longer sequence is hidden from the panel.
    ignore = {},
    -- Group rows (keys that open a submenu) are sorted before plain keys in the grid.
    sort_groups_first = true,
    -- Sort rows by how often they are executed (collected automatically; see
    -- :LvimKeysHelper stats). Off by default — rows keep a stable alphabetical order.
    sort_by_usage = false,
    -- Watch vim.keymap.set/del: mappings defined outside the BufEnter cycle (timers,
    -- lazy handlers) refresh the triggers immediately.
    watch_mappings = true,
    -- Group rows carry their child count ("Git +10", bare "+3" without a label).
    counts = true,
    -- The keys that control an OPEN panel (vim notation). `run` executes the complete
    -- mapping behind the current prefix when one exists (shown in the legend).
    keys = {
        back = "<BS>",
        scroll_down = "<C-d>",
        scroll_up = "<C-u>",
        run = "<CR>",
        help = "<F1>", -- then a key: shows the mapping behind it (desc, rhs, source)
    },
    -- Texts used in the footer legend; `run` is the fallback when the exact mapping
    -- behind a prefix has no desc of its own.
    labels = {
        next = "next",
        prev = "prev",
        back = "back",
        run = "run",
    },
    -- Background tint strengths (blend factor toward colors.bg): `strong` paints the key
    -- badges / title cells / legend keys, `light` the descriptions / separators / labels.
    tint = {
        strong = 0.2,
        light = 0.1,
    },
    -- Palette names (lvim-utils) for the panel chrome: `bg` is the uniform background of
    -- body + border + every tint blend; `accent` paints the border fg and the legend.
    colors = {
        bg = "bg_dark",
        accent = "blue",
    },
    win = {
        -- The cheatsheet's ring follows the SINGLE border source, `lvim-utils.config.ui.border` (resolved live
        -- by `ui.frame_border()`), so it re-borders in lockstep with every other lvim-tech panel — no per-plugin
        -- border literal here.
        max_height = 0.45, -- fraction of editor height
        mini = {
            max_width = 60, -- columns
            margin = 1, -- cells from the bottom-right corner
        },
        full = {
            margin = 0, -- full-width bottom strip
        },
        title_pos = "left", -- breadcrumb position in the top border: left/center/right
        footer_pos = "center", -- legend position in the bottom border: left/center/right
        padding_top = 1, -- blank rows between the title border and the grid
        padding_bottom = 1, -- blank rows between the grid and the legend (only when one shows)
        winblend = 0,
        zindex = 250,
    },
    columns = {
        min_width = 18, -- a key-badge + desc cell's minimum width
        gap = 1, -- cells between columns
        key_max = 14, -- a key badge is truncated past this many display cells
        desc_max = 30, -- a description is truncated past this many display cells
    },
    icons = {
        group = "", -- appended to a key that is itself a prefix (more keys follow)
        breadcrumb = "➤", -- between the keys of the pending sequence in the title
    },
    -- Accent colours (lvim-utils palette names) cycled per NESTING LEVEL: a 1st-level
    -- panel (e.g. <Space>) uses palette[1], its submenus palette[2], and so on. Every
    -- key badge carries its panel's level colour, group rows the NEXT level's colour
    -- (the one they open); a group registered with a `color` overrides either (tints
    -- are always derived automatically).
    palette = { "blue", "green", "red", "purple", "cyan", "orange", "yellow", "magenta", "teal" },
    -- The BufEnter/FileType/LspAttach burst is coalesced into one trigger recompute.
    recompute_debounce = 120,
}
