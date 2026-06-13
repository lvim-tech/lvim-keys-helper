# lvim-keys-helper

A self-contained key-hint panel for Neovim — a lightweight `which-key` replacement
built on the lvim-tech ecosystem (uses `lvim-utils` for its palette/merge).

Trigger keys are **auto-detected** per buffer: the first keystroke of every multi-key
mapping (like which-key's `<auto>`) and, with presets on, of the built-in `g` / `z` /
`[` / `]` / `<C-w>` / text-object sequences. Triggers are buffer-local `<nowait>`
mappings, so they fire **instantly** — the panel wait is `delay` alone — while
`timeoutlen` itself is never touched: everything the helper does not intercept
(`ignore`d keys, other modes) keeps Vim's native timeout behaviour. The finished
sequence is replayed so the real mapping (or native command) runs — the typed **count
and register are preserved**, and expr/callback mappings behave exactly as if typed.

- A trigger landing on a key with an existing buffer-local single-key mapping **saves**
  it and restores it when the trigger goes away; global single-key mappings are never
  touched (the trigger merely sits above them) and run via the ambiguity rule.
- `<Plug>` / `<SNR>` mappings never become triggers or panel rows.
- While reading a sequence: `<BS>` steps back one level, `<C-d>` / `<C-u>` page an
  overflowing panel, `<F1>` then a key describes that mapping, the mouse clicks rows /
  breadcrumb cells, and the panel is suppressed during macro replay. `<Esc>` cancels
  (aborting a pending operator in operator-pending mode). All control keys are
  configurable via `keys` (see "Panel extras").
- A prefix that is **also a complete mapping** never auto-runs while the panel is open:
  the legend shows it and `<CR>` runs it (Vim-style timeout resolution applies only
  before the panel shows, when `timeoutlen` < `delay`).

Everything that matters is switchable **live, without a restart**:

- **enable / disable** — `enable()` / `disable()` / `toggle()`
- **popup delay (ms)** — `set_delay(ms)`
- **panel style** — `set_style("mini" | "full")` / `toggle_style()`
- **group labels** — `register_groups({ ["<leader>f"] = "Find" })`

## Styles

- **mini** — a compact window anchored to the bottom-right corner
- **full** — a full-width strip along the bottom of the editor

The continuation keys render as coloured badge "buttons" (a `key` badge + its
`description`), with badge colours cycled through the `lvim-utils` palette — mirroring
the `:Messages` pager chrome. Group rows (keys that lead to more keys) show their
registered label, the exact mapping's description, or a `+N keys` placeholder, in an
italic accent.

## Setup

```lua
require("lvim-keys-helper").setup({
    enabled = true,
    delay = 200, -- ms of inactivity before the panel opens
    style = "mini", -- "mini" | "full"
    trigger_modes = { "n", "x", "o" },
    presets = true, -- built-in g/z/[/]/<C-w>/text-object descriptions + triggers
    groups = { -- labels for group rows (vim notation; <leader> works);
        ["<leader>f"] = "Find", -- a table value may assign a colour
        ["<leader>g"] = { -- (palette name; tints are automatic)
            "Git",
            color = "red",
            mode = { "n", "x" }, -- scope the entry per mode (default: all)
            sticky = false, -- true: panel re-opens after each child
            -- strict = true: the panel shows ONLY the keys declared below (everything
            -- else still works, just hidden) and opens INSTANTLY — a curated menu.
            -- Default false: all detected continuations show, default delay applies.
            strict = false,
            delay = 50, -- per-group popup delay override (ms)
            keys = {
                -- string: a description override (beats the mapping's own desc;
                -- a child's own groups label beats it)
                b = "Blame",
                -- table: DEFINES a real mapping, vim.keymap.set syntax — [1] is the
                -- rhs (keys / <Cmd> string / Lua function), the rest are the native
                -- opts (desc, mode, expr, nowait, remap, silent, buffer, …)
                l = { "<Cmd>Telescope git_commits<CR>", desc = "Git Log" },
                o = {
                    function()
                        require("mod").open()
                    end,
                    desc = "Open URL",
                    mode = { "n", "x" },
                },
                -- a child may be a NESTED GROUP with its own label/color/mode/
                -- strict/keys; mappings inside inherit the nested group's mode
                t = {
                    "Toggles",
                    color = "purple",
                    mode = "x",
                    strict = true,
                    keys = {
                        p = { "<Cmd>VGit buffer_blame_preview<CR>", desc = "Preview" },
                    },
                },
            },
        },
    },
    ignore = {}, -- sequences the helper never handles:
    -- a single key is not installed as a trigger,
    -- a longer sequence is hidden from the panel
    sort_groups_first = true, -- group rows before plain keys in the grid
    sort_by_usage = false, -- order rows by execution count (see :LvimKeysHelper stats)
    watch_mappings = true, -- refresh triggers when maps are defined outside BufEnter
    counts = true, -- "+N" child count on group rows
    keys = { -- panel control keys (vim notation)
        back = "<BS>",
        scroll_down = "<C-d>",
        scroll_up = "<C-u>",
        run = "<CR>", -- run the complete mapping behind the current prefix
        help = "<F1>", -- then a key: show the mapping behind it
    },
    labels = { -- legend texts
        next = "next",
        prev = "prev",
        back = "back",
        run = "run",
    },
    tint = { strong = 0.2, light = 0.1 }, -- bg blend factors (badges/cells vs texts)
    colors = { -- palette names (lvim-utils)
        bg = "bg_dark", -- uniform panel/border background + tint base
        accent = "blue", -- border fg + footer legend
    },
    palette = { "blue", "green", "red", "purple", "cyan", "orange", "yellow", "magenta", "teal" },
    -- accent colours cycled per nesting level
    win = {
        border = { " ", " ", " ", " ", " ", " ", " ", " " },
        max_height = 0.45, -- fraction of editor height
        mini = { max_width = 60, margin = 1 },
        full = { margin = 0 },
        title_pos = "left", -- breadcrumb position: left/center/right
        footer_pos = "center", -- legend position: left/center/right
        padding_top = 1, -- blank rows between title border and grid
        padding_bottom = 1, -- blank rows between grid and legend
        winblend = 0,
        zindex = 250,
    },
    columns = {
        min_width = 18, -- minimum cell width
        gap = 1, -- cells between columns
        key_max = 14, -- key badge truncation width
        desc_max = 30, -- description truncation width
    },
    icons = {
        group = "", -- appended to group keys
        breadcrumb = "", -- between the title cells
    },
    recompute_debounce = 120, -- ms the buffer-change trigger recompute is debounced
})
```

## API

| Function                                          | Description                                                     |
| ------------------------------------------------- | --------------------------------------------------------------- |
| `setup(opts)`                                     | Configure and start (idempotent).                               |
| `enable()` / `disable()` / `toggle()`             | Turn the panel on/off (live). `disable` restores shadowed maps. |
| `is_enabled()`                                    | Whether the panel is enabled.                                   |
| `set_delay(ms)` / `get_delay()`                   | Popup delay in milliseconds (live).                             |
| `set_style(style)` / `toggle_style()` / `style()` | Panel style `"mini"` / `"full"` (live).                         |
| `register_groups(tbl)`                            | Add group labels at runtime.                                    |
| `trigger_count()`                                 | Number of installed triggers (used by `:checkhealth`).          |

## Panel extras

- **Sticky groups** (`sticky = true`): after a direct child runs, the panel re-opens at
  the group hydra-style — repeatable actions (window resize, hunk hopping) without
  re-typing the prefix; `<Esc>`/back leaves.
- **Live content panels**: after `"` the registers show their CONTENT, after `'`/`` ` ``
  the marks show their target line — not just names.
- **Usage statistics**: every executed sequence is counted (sqlite.lua storage when
  available, JSON otherwise). `sort_by_usage = true` puts the hottest keys first;
  `:LvimKeysHelper stats` shows the report, `stats reset` clears it.
- **Help key** (`keys.help`, default `<F1>`): press it, then any key — shows the mapping
  behind it (desc, rhs / Lua source file:line, flags).
- **Mouse**: click a row to press its key, a breadcrumb cell to jump back to that
  level, outside the panel to close (needs 'mouse' enabled).
- **Per-group `delay`** override; `watch_mappings` keeps triggers fresh when plugins
  define maps outside the BufEnter cycle.

## Command

`:LvimKeysHelper [toggle|enable|disable|status|style|delay|doctor|cheatsheet|stats|test|debug|log]`
— plus `:checkhealth lvim-keys-helper`.

- `doctor` — audits the keymap landscape: mapping+prefix conflicts, missing
  descriptions, `<Nop>` placeholders, buffer-shadowed globals, orphan group labels.
- `cheatsheet` — renders the whole detected key tree into a markdown buffer.
- `stats [N|reset]` — the N most used sequences (default 30) / reset the counters.

## Highlights

Built from the `lvim-utils` palette (per `tint` / `colors` config) and rebuilt on
colorscheme change. Override any of: `LvimKeysHelperNormal`, `LvimKeysHelperBorder`,
`LvimKeysHelperFooter`, `LvimKeysHelperFooterKey`, `LvimKeysHelperBadge1..N`,
`LvimKeysHelperText1..N`, `LvimKeysHelperGroup1..N` (N = `#palette`). The title
breadcrumb cells reuse `Badge/Text` per nesting level.

A legend in the bottom border shows contextual keys: `run` when the prefix is also a
complete mapping, paging (with the current page) when the content overflows, and
`back` from the second level on.
