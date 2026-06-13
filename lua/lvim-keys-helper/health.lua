-- lvim-keys-helper: :checkhealth lvim-keys-helper
--
---@module "lvim-keys-helper.health"

local config = require("lvim-keys-helper.config")

local M = {}

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

    health.info(
        ("delay=%dms  style=%s  presets=%s  groups=%d  ignore=%d"):format(
            config.delay,
            config.style,
            tostring(config.presets ~= false),
            vim.tbl_count(config.groups or {}),
            #(config.ignore or {})
        )
    )

    if not vim.o.timeout then
        health.warn("'notimeout' is set — triggers (and exact-match resolution) never fire on pause")
    end
end

return M
