------------------------------------------------------------
-- test_config_scan.lua - the scanner must see what it is meant to see.
--
-- Checked on synthetic source, so a broken scanner fails here rather than
-- silently passing every consumer's files.
--
--   & 'C:\Program Files (x86)\Lua\5.1\lua.exe' tests\test_config_scan.lua
------------------------------------------------------------

dofile("tests/wow_stubs.lua")
local H = dofile("tests/harness.lua")
local CS = dofile("tests/config_scan.lua")

local ONE = { "HostDB" }
local TWO = { "HostDB", "HostCheck" }

for _, c in ipairs({
    { 'if x then HostDB.lockFrame = true end', 1, "an inline write mid-line" },
    { 'HostDB.flag = (a == b)', 1, "a write whose value contains ==" },
    { 'HostDB.list[entry[1]] = true', 1, "a key indexed by entry[1]" },
    { 'HostDB.list[ name ] = true', 1, "a key with spaces" },
    { 'HostDB.list[self:GetName()] = true', 1, "a key from a method call" },
    { 'HostDB.list[GetInstanceInfo()] = true', 1, "a key from a call" },
    { 'HostDB[key .. "x"] = 1', 1, "a concatenated key" },
    { 'HostDB.list[i+1] = true', 1, "an arithmetic key" },
    { 'HostDB[dbKey] = v', 1, "a variable key" },
    { 'HostDB.a, x = 1, 2', 1, "multiple assignment" },
    { 'x, HostDB.b = 1, 2', 1, "multiple assignment, second target" },
    { 'HostDB.pos =\n    { point = p }', 1, "a value on the next line" },
    { 'x = 1; HostDB.y = 2', 1, "a second statement on the line" },
    { 'local function f() HostDB.x = 1 end', 1, "a write inside a one-line function" },
    { 'HostDB = {}', 1, "replacing the whole table" },
    { 'if HostDB.lockFrame == true then end', 0, "a comparison" },
    { 'if HostDB.frameAlpha ~= 1 then end', 0, "a ~= comparison" },
    { 'if HostDB.a then y = 2 end', 0, "a condition that reads it" },
    { 'local p = HostDB.pos', 0, "a read into a local" },
    { 'local t = { pos = HostDB.pos }', 0, "a read inside a table constructor" },
    { 'print("HostDB.x = 1")', 0, "text inside a string" },
    { '-- HostDB.pos = nil', 0, "a comment" },
    { 'HostDBX.a = 1', 0, "a longer name that merely starts the same" },
    { 'MyHostDB.a = 1', 0, "a longer name that merely ends the same" },
    { 'Other.HostDB = 1', 0, "a field of another table that shares the name" },
    { '-- see the config-owner: begin/end regions\nHostDB.x = 1', 1,
      "prose mentioning the marker, which opens nothing" },
    { '-- config-owner: begin\nHostDB.pos = nil\n-- config-owner: end', 0,
      "a write inside an owner region" },
    { '-- config-owner: begin\r\nHostDB.pos = nil\r\n-- config-owner: end\r\n', 0,
      "CRLF line endings, as on Windows checkouts" },
}) do
    H.eq(#CS.Scan("synthetic", c[1], ONE), c[2], "the scanner handles " .. c[3])
end

-- Every name given is guarded, not just the first.
H.eq(#CS.Scan("synthetic", 'HostCheck.svLoadCheck = {}', TWO), 1,
    "a write to the second saved table is caught")
H.eq(#CS.Scan("synthetic", 'HostCheck.svLoadCheck = {}', ONE), 0,
    "and only when it is named")

H.check(#CS.Scan("synthetic", "-- config-owner: begin\nx = 1", ONE) > 0,
    "an owner region that never closes is an error")
H.check(#CS.Scan("synthetic", "-- config-owner: end", ONE) > 0,
    "an end with no begin is an error")
H.check(#CS.Scan("synthetic", "-- config-owner: begin\n-- config-owner: begin\n-- config-owner: end", ONE) > 0,
    "a nested region is an error")
local _, regions = CS.Scan("synthetic",
    "-- config-owner: begin\n-- config-owner: end\n-- config-owner: begin\n-- config-owner: end", ONE)
H.eq(regions, 2, "regions are counted, so a consumer can pin how many it has")

H.check(not pcall(CS.Scan, "missing", nil, ONE), "a file that could not be read is an error, not a pass")
H.check(not pcall(CS.Scan, "synthetic", "x = 1", {}), "and so is naming no saved table")

H.done("test_config_scan")
