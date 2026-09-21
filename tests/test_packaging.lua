------------------------------------------------------------
-- test_packaging.lua - what ships inside a consuming addon.
--
-- The library is never published on its own: addons embed it through their
-- .pkgmeta externals, and the packager applies THIS repository's .pkgmeta
-- ignore list while copying it into <addon>/Libs/LibGroupBuffs-1.0. Too
-- little ignored, and every addon carries this repo's tests and notes; too
-- much, and an addon ships without a file the XML loads, which is an addon
-- that does not start.
--
--   & 'C:\Program Files (x86)\Lua\5.1\lua.exe' tests\test_packaging.lua
------------------------------------------------------------

dofile("tests/wow_stubs.lua")
local H = dofile("tests/harness.lua")

local function ReadFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return (s:gsub("\r\n", "\n"))
end

local pkgmeta = ReadFile(".pkgmeta")
H.check(pkgmeta ~= nil, "the library has a .pkgmeta")
pkgmeta = pkgmeta or ""

-- The ignore list: the "- item" lines under `ignore:`, up to the next key.
local ignored, inIgnore = {}, false
for line in (pkgmeta .. "\n"):gmatch("([^\n]*)\n") do
    if line:match("^ignore:%s*$") then
        inIgnore = true
    elseif line:match("^%S") then
        inIgnore = false
    elseif inIgnore then
        local item = line:match("^%s+%-%s+(%S+)")
        if item then ignored[#ignored + 1] = item end
    end
end

local function isIgnored(path)
    for _, item in ipairs(ignored) do
        if path == item or path:sub(1, #item + 1) == item .. "/" then return true end
    end
    return false
end

------------------------------------------------------------
-- Nothing the client loads may be ignored
------------------------------------------------------------

local runtime = { "LibGroupBuffs-1.0.xml" }
for _, file in ipairs(H.xmlScripts()) do runtime[#runtime + 1] = file end
for _, file in ipairs(runtime) do
    H.check(not isIgnored(file), file .. " is loaded by the client, so it must ship")
end
H.check(not isIgnored("LICENSE"), "LICENSE ships: MIT requires the notice to travel with the code")

------------------------------------------------------------
-- Everything that is only for working on the library is left out
------------------------------------------------------------

for _, dev in ipairs({ "tests", ".github", ".claude", ".pkgmeta",
                       "AGENTS.md", "CLAUDE.md", "README.md" }) do
    H.check(isIgnored(dev), dev .. " is for working on the library, not for players' AddOns folders")
end

H.done("test_packaging")
