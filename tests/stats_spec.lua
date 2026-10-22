-- The key-use counters behind the "most used" list.
--
-- A count is kept per (mode, sequence) and the two are stored joined by a space, so the thing
-- worth checking is that they come back APART — including for a sequence that itself contains a
-- space, which is where a naive split would hand the list a mode of `n` and a sequence of half a
-- mapping.
--
-- The suite's XDG homes are a throwaway directory, so the counters written here never reach the
-- real ones.

local stats = require("lvim-keys-helper.stats")

stats.reset()

describe("lvim-keys-helper.stats")

it("counts a sequence per mode", function()
    stats.reset()
    stats.bump("n", "gd")
    stats.bump("n", "gd")
    stats.bump("i", "gd")
    eq(2, stats.get("n", "gd"))
    eq(1, stats.get("i", "gd"), "the same sequence in another mode is another counter")
end)

it("starts a sequence nobody pressed at nothing", function()
    stats.reset()
    local n = stats.get("n", "never-pressed")
    truthy(n == nil or n == 0, "got " .. vim.inspect(n))
end)

it("lists the most used first", function()
    stats.reset()
    stats.bump("n", "rare")
    for _ = 1, 5 do
        stats.bump("n", "common")
    end
    for _ = 1, 3 do
        stats.bump("n", "middling")
    end
    local top = stats.top()
    eq("common", top[1].seq)
    eq(5, top[1].count)
    eq("middling", top[2].seq)
    eq("rare", top[3].seq)
end)

it("takes a limit", function()
    stats.reset()
    for i = 1, 5 do
        stats.bump("n", "key" .. i)
    end
    eq(2, #stats.top(2))
    eq(5, #stats.top(), "no limit means all of them")
end)

it("keeps the mode and the sequence apart when the sequence holds a space", function()
    stats.reset()
    stats.bump("n", "<leader> f")
    local row
    for _, r in ipairs(stats.top()) do
        if r.seq == "<leader> f" then
            row = r
        end
    end
    truthy(row, "the sequence came back mangled: " .. vim.inspect(stats.top()))
    eq("n", row.mode)
    eq(1, row.count)
end)

it("forgets everything on reset", function()
    stats.bump("n", "gd")
    stats.reset()
    eq(0, #stats.top())
end)

it("flushes without a store rather than erroring", function()
    local ok, err = pcall(stats.save)
    truthy(ok, tostring(err))
end)

stats.reset()
