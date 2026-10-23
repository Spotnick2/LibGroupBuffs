-- A host material must never recolor another host, before or after a library upgrade.
dofile("tests/wow_stubs.lua")
local H = dofile("tests/harness.lua")
local lib = H.loadLibrary()
WoW.reset()
H.TeachSpells({ "FORT_SINGLE" })
H.Party3()
local original = H.PriestUI()
original.engine:RefreshSpells()
original.ui:Update()
local originalAlpha = original.ui.main.glass.tint._colorTexture[4]
local sharedStyle = lib.glass.STYLE
local custom = LibStub("LibGlass-1.0"):New({ preset = "clean", style = { gloss = 0.31, wash = 0.2 } })
local host = H.PriestUI({ owner = "CustomHost" })
host.engine:RefreshSpells()
host.ui.host.glass = custom
host.ui.host.bodyStyle = function()
    return { tint = { 0.1, 0.2, 0.3, 0.7 }, wash = 0.5, backing = { 0.04, 0.05, 0.07, 0.9 } }
end
host.ui:Update()
H.eq(host.ui.main.glass.tint._colorTexture[4], 0.7, "custom main tint")
H.eq(host.ui.pop.glass.tint._colorTexture[4], 0.7, "custom popup tint")
H.eq(host.ui.main.glass.bodyBacking._colorTexture[4], 0.9, "masked backing")
H.near(host.ui.main.glass.wash.glassPeak, 0.1, nil, "wash multiplies material wash")
H.eq(host.ui.main.hdr.gloss:GetAlpha(), 0.31, "header uses host material")
H.eq(host.ui.rows[1].fill.gloss:GetAlpha(), 0.31, "row uses host material")
H.eq(original.ui.main.glass.tint._colorTexture[4], originalAlpha, "original unaffected")
H.eq(lib.glass.STYLE, sharedStyle, "shared material identity preserved")
H.eq(original.ui.main.glass.bodyBacking, nil, "old contract retains no backing")
local f = assert(io.open("LibGroupBuffs.lua", "rb"))
local source = f:read("*a"); f:close()
local newer, count = source:gsub('"LibGroupBuffs%-1%.0", 32', '"LibGroupBuffs-1.0", 33', 1)
H.eq(count, 1, "synthetic upgrade changes only revision")
assert(loadstring(newer))()
host.ui:Update()
original.ui:Update()
H.eq(host.ui.host.glass, custom, "custom material identity survives upgrade")
H.eq(host.ui.main.glass.tint._colorTexture[4], 0.7, "custom tint survives upgrade")
H.eq(original.ui.main.glass.tint._colorTexture[4], originalAlpha, "original tint survives upgrade")
local ok = pcall(lib.UI.New, { owner = "Invalid", engine = host.engine, glass = {} })
H.eq(ok, false, "malformed instance rejected")
ok = pcall(lib.UI.New, { owner = "Invalid", engine = host.engine, bodyStyle = {} })
H.eq(ok, false, "bodyStyle must be callable")

-- Real r31 fixture, with an object constructed by the old version before r32 arrives.
LibStub = nil
H.loadLibrary()
LibStub.libs["LibGroupBuffs-1.0"], LibStub.minors["LibGroupBuffs-1.0"] = nil, nil
assert(loadfile("tests/fixtures/LibGroupBuffs-r31.lua"))()
local previous = H.PriestUI({ owner = "PreviousVersion" })
previous.engine:RefreshSpells()
previous.ui:Update()
local main = previous.ui.main
assert(loadfile("LibGroupBuffs.lua"))()
previous.ui:Update()
H.eq(previous.ui.main, main, "r31 window survives upgrade")
H.eq(previous.ui.main.glass.bodyBacking, nil, "upgrade preserves default body")
H.done("test_ui_material")
