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

local scripts, xmls = H.xmlScripts()
local runtime = {}
for _, file in ipairs(xmls) do runtime[file] = true end
for _, file in ipairs(scripts) do runtime[file] = true end
for file in pairs(runtime) do
    H.check(not isIgnored(file), file .. " is loaded by the client, so it must ship")
end
H.check(not isIgnored("LICENSE"), "LICENSE ships: MIT requires the notice to travel with the code")

------------------------------------------------------------
-- Every tracked file either runs in game, is LICENSE, or is ignored
--
-- Checked against what git tracks rather than a list written here, so a new
-- file nobody thought about fails this test instead of landing in every
-- consuming addon's AddOns folder.
------------------------------------------------------------

local tracked = {}
local git = io.popen("git ls-files")
if git then
    for line in git:lines() do tracked[#tracked + 1] = line end
    git:close()
end
H.check(#tracked > 0, "git ls-files lists the repository (run the tests from a git checkout)")

-- No textures of our own since r26: the material is LibGlass-1.0, which every
-- consumer embeds beside this library and which ships its own Media/. A
-- texture tracked here again would be a second copy drifting from LibGlass's.
for _, file in ipairs(tracked) do
    H.check(file:sub(1, 6) ~= "Media/", file .. ": textures belong to LibGlass, not this library")
    if not runtime[file] and file ~= "LICENSE" then
        H.check(isIgnored(file), file .. " does not run in game, so .pkgmeta must ignore it")
    end
end

-- Side by side, never nested: LibGlass derives its media path from its own
-- embed folder, so a copy loaded from inside this one would draw blank.
for _, file in ipairs(xmls) do
    local fh = assert(io.open(file, "rb"))
    local xml = fh:read("*a"):gsub("<!%-%-.-%-%->", "")
    fh:close()
    H.check(not xml:find("LibGlass", 1, true), file .. " does not load LibGlass: consumers do")
end

-- Every texture the window names must be one LibGlass ships. A typo in a name
-- is a file the client silently fails to find, and a window with a hole in
-- it; nothing else in the suite compares the two lists.
local glassMedia = {}
-- io.popen runs cmd.exe on Windows and sh elsewhere: list with what each has.
local mediaDir = H.libGlassRoot() .. "/Media"
local listing = io.popen(package.config:sub(1, 1) == "\\"
    and ('dir /b "' .. mediaDir:gsub("/", "\\") .. '"')
    or ('ls "' .. mediaDir .. '"'))
if listing then
    for line in listing:lines() do
        local name = line:match("^([%w_]+)%.tga$")
        if name then glassMedia[name] = true end
    end
    listing:close()
end
H.check(next(glassMedia) ~= nil, "the LibGlass checkout's Media/ lists its textures")
local checked = 0
for _, file in ipairs(scripts) do
    if file ~= "LibStub/LibStub.lua" then
        local fh = assert(io.open(file, "r"), file .. " must be readable from the repository root")
        local src = fh:read("*a")
        fh:close()
        for _, pattern in ipairs({ '[Mm][Ee][Dd][Ii][Aa] %.%. "([%w_]+)"', 'Mask%([^,()]+, "([%w_]+)"' }) do
            for name in src:gmatch(pattern) do
                checked = checked + 1
                H.check(glassMedia[name], file .. " draws " .. name
                    .. ", so LibGlass's Media/" .. name .. ".tga must exist")
            end
        end
    end
end
-- bar_mask through Mask() and as a path, bar_edge three times, gloss twice.
H.check(checked >= 7, "and the scan found the textures rather than nothing: " .. checked)

-- The development files named explicitly as well, so the intent survives even
-- if one of them is ever untracked.
for _, dev in ipairs({ "tests", ".github", ".gitignore", ".claude", ".pkgmeta",
                       "AGENTS.md", "CLAUDE.md", "README.md" }) do
    H.check(isIgnored(dev), dev .. " is for working on the library, not for players' AddOns folders")
end

H.done("test_packaging")
