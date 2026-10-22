-- lvim-keys-helper: usage statistics.
-- Counts how many times each key sequence is executed through the helper. The HOT path
-- (panel sorting, counters) always reads an in-memory Lua table; persistence only touches
-- storage once at lazy load and debounced on write, so the backend makes no speed
-- difference. Storage: sqlite.lua when available (consistent with lvim-control-center),
-- otherwise a JSON file — both in stdpath("state"). Powers the optional usage-based
-- sorting (config.sort_by_usage) and the :LvimKeysHelper stats report.
--
---@module "lvim-keys-helper.stats"

local M = {}

local JSON_PATH = vim.fn.stdpath("state") .. "/lvim-keys-helper-stats.json"
local DB_PATH = vim.fn.stdpath("state") .. "/lvim-keys-helper.db"

local data = nil ---@type table<string, integer>|nil  "mode sequence" → count (nil = not loaded)
local dirty = {} ---@type table<string, boolean>  keys changed since the last save
local has_dirty = false
local save_timer = nil ---@type uv.uv_timer_t|nil
local hooked = false
local db = nil ---@type table|false|nil  sqlite handle, false = unavailable, nil = untried

--- The sqlite connection (lazy; false when sqlite.lua is not installed or fails).
---@return table|false
local function sqlite()
    if db ~= nil then
        return db
    end
    local ok, lib = pcall(require, "sqlite.db")
    if not ok then
        db = false
        return db
    end
    local ok2, handle = pcall(function()
        local h = lib:open(DB_PATH)
        h:eval("CREATE TABLE IF NOT EXISTS stats (key TEXT PRIMARY KEY, count INTEGER NOT NULL)")
        return h
    end)
    db = ok2 and handle or false
    return db
end

--- Which persistence backend is live: "sqlite" when sqlite.lua opened successfully,
--- else the "json" fallback (a plain file in stdpath("state")). Probes the same lazy
--- connection the read/write paths use, so :checkhealth reports the real backend.
---@return "sqlite"|"json"
function M.backend()
    return sqlite() and "sqlite" or "json"
end

--- Load the persisted counts (once) into the in-memory table.
---@return table<string, integer>
local function load()
    if data then
        return data
    end
    data = {}
    local d = sqlite()
    if d then
        local ok, rows = pcall(d.eval, d, "SELECT key, count FROM stats")
        if ok and type(rows) == "table" then
            for _, r in ipairs(rows) do
                data[r.key] = r.count
            end
        end
        return data
    end
    local f = io.open(JSON_PATH, "r")
    if f then
        local ok, decoded = pcall(vim.json.decode, f:read("*a"))
        f:close()
        if ok and type(decoded) == "table" then
            data = decoded
        end
    end
    return data
end

--- Flush the changed counters to storage.
---@return nil
function M.save()
    if not has_dirty or not data then
        return
    end
    local d = sqlite()
    if d then
        for key in pairs(dirty) do
            pcall(d.eval, d, "INSERT OR REPLACE INTO stats (key, count) VALUES (:key, :count)", {
                key = key,
                count = data[key],
            })
        end
    else
        local ok, encoded = pcall(vim.json.encode, data)
        if ok then
            -- Atomic replace: write a sibling temp file, then rename it over the target.
            -- io.open(path, "w") truncates first, so a crash (or a second instance flushing
            -- at VimLeavePre) mid-write would leave a corrupt file that load() silently reads
            -- as empty, making the loss permanent. os.rename is atomic on the same filesystem.
            local tmp = JSON_PATH .. ".tmp"
            local f = io.open(tmp, "w")
            if f then
                f:write(encoded)
                f:close()
                os.rename(tmp, JSON_PATH)
            end
        end
    end
    dirty = {}
    has_dirty = false
end

--- Stop and close the debounce timer, releasing its libuv handle. Idempotent.
---@return nil
local function close_timer()
    if save_timer then
        if not save_timer:is_closing() then
            save_timer:stop()
            save_timer:close()
        end
        save_timer = nil
    end
end

--- Record one execution of `seq` (display form) in `mode`.
---@param mode string
---@param seq string
---@return nil
function M.bump(mode, seq)
    local t = load()
    local key = mode .. " " .. seq
    t[key] = (t[key] or 0) + 1
    dirty[key] = true
    has_dirty = true
    if not hooked then
        hooked = true
        -- Final flush AND handle cleanup on exit: without close() the debounce timer would
        -- leak one libuv handle for the rest of the session (it is created once and reused).
        vim.api.nvim_create_autocmd("VimLeavePre", {
            -- Own group: the `hooked` flag keeps this to one handler per session, but a module
            -- reload resets the flag and would stack a second flush. The group makes the
            -- registration replace rather than add.
            group = vim.api.nvim_create_augroup("LvimKeysHelperStatsFlush", { clear = true }),
            callback = function()
                M.save()
                close_timer()
            end,
        })
    end
    -- Throttle: one flush per 5s of activity. Starting the timer only when it is NOT already
    -- pending makes it fire 5s after the FIRST bump of a burst (a leading-window throttle),
    -- so an actively-typed session still persists every 5s. A trailing debounce (restart on
    -- every bump) would defer the write indefinitely under steady use — only VimLeavePre would
    -- ever flush, and a crash would lose the whole session's counts.
    local timer = save_timer
    if not timer then
        timer = vim.uv.new_timer()
        if not timer then
            return -- libuv could not allocate a timer; the counts still flush on VimLeavePre
        end
        save_timer = timer
    end
    if not timer:is_active() then
        timer:start(5000, 0, vim.schedule_wrap(M.save))
    end
end

--- The recorded count for `seq` in `mode` (in-memory read).
---@param mode string
---@param seq string
---@return integer
function M.get(mode, seq)
    return load()[mode .. " " .. seq] or 0
end

--- The `n` most used sequences, as { mode, seq, count } rows (sorted descending).
---@param n? number
---@return table[]
function M.top(n)
    local rows = {}
    for key, count in pairs(load()) do
        local mode, seq = key:match("^(%S+) (.+)$")
        if mode then
            rows[#rows + 1] = { mode = mode, seq = seq, count = count }
        end
    end
    table.sort(rows, function(a, b)
        return a.count > b.count
    end)
    if n then
        for i = #rows, n + 1, -1 do
            rows[i] = nil
        end
    end
    return rows
end

--- Forget everything (memory and storage).
---@return nil
function M.reset()
    data = {}
    dirty = {}
    has_dirty = false
    -- Drop any pending debounced flush (and its handle); nothing left to write.
    close_timer()
    local d = sqlite()
    if d then
        pcall(d.eval, d, "DELETE FROM stats")
    end
    pcall(os.remove, JSON_PATH)
end

return M
