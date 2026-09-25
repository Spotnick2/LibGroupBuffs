------------------------------------------------------------
-- test_stub.lua - the parts of the stub that HOSTS depend on.
--
-- Priestly, Wildly and Magely load tests/wow_stubs.lua from their library
-- checkout rather than keeping a copy, so this file is a contract, not an
-- internal detail: the seam a host layers itself onto (player defaults, the
-- allow-list) and the returns a host reads that this library does not.
--
-- The copies are what made this necessary. Priestly's had already drifted -
-- no combat refusal model - so every refusal measured here had to be ported
-- by hand, and a host's tests could stay green against a client that refuses.
--
--   & 'C:\Program Files (x86)\Lua\5.1\lua.exe' tests\test_stub.lua
------------------------------------------------------------

dofile("tests/wow_stubs.lua")
local H = dofile("tests/harness.lua")

------------------------------------------------------------
-- Player defaults: the host is not a priest
------------------------------------------------------------

WoW.reset()
H.eq(select(1, UnitClass("player")), "PRIEST", "the library's own default player is a priest")

WoW.SetPlayerDefaults({ name = "Wildly Testcase", class = "DRUID", level = 60 })
H.eq(GetUnitName("player"), "Wildly Testcase", "setting defaults applies without a reset")
H.eq(select(1, UnitClass("player")), "DRUID", "including the class")

WoW.reset()
H.eq(select(1, UnitClass("player")), "DRUID", "and survives the reset every test does first")
H.eq(UnitLevel("player"), 60, "level too")

-- A unit the test did not describe gets the suite's defaults, not a priest
-- hardcoded in a shared file.
WoW.SetUnit("party1", { name = "Karuzo Elegia" })
H.eq(select(1, UnitClass("party1")), "DRUID", "an undescribed unit uses the suite's default class")
H.eq(UnitClass("party2"), nil, "a unit that does not exist has no class at all")
WoW.SetUnit("party2", { name = "Mage Person", class = "MAGE" })
H.eq(select(1, UnitClass("party2")), "MAGE", "and a test that says otherwise still wins")

WoW.SetPlayerDefaults({ name = "Priestly Testcase", class = "PRIEST", level = 20 })
WoW.reset()

------------------------------------------------------------
-- The build the stub models
------------------------------------------------------------

-- Hosts assert this against their own pinned build, so it is part of the
-- contract rather than a detail. It is the CLIENT's build: a host that has
-- not re-probed a new client yet keeps an older measuredOnBuild on purpose,
-- and the stub must not follow it there - every test file runs under this
-- default, and it should show them what a player sees.
WoW.reset()
H.eq(WoW.build, "70009", "the stub models the installed client build")
H.eq(select(2, GetBuildInfo()), "70009", "which is what GetBuildInfo reports")
H.eq(select(3, GetBuildInfo()), "Sep 23 2026", "with that build's date, not an older one")
WoW.build = "70000"
H.eq(select(2, GetBuildInfo()), "70000", "and a test can move it")

------------------------------------------------------------
-- The allow-list, after strictGlobals is already installed
------------------------------------------------------------

-- The file installs strictGlobals as its last act, so a host CANNOT call
-- allowGlobal first. Reading an unknown global must still be an error, and
-- allowing one must still work.
local ok = pcall(function() return _G.SomeHostTable end)
H.check(not ok, "an unstubbed global is still an error when a host loads the file")

WoW.allowGlobal("SomeHostTable", "AnotherHostTable")
H.eq(_G.SomeHostTable, nil, "an allowed global reads as nil rather than throwing")
H.eq(_G.AnotherHostTable, nil, "and allowGlobal takes more than one name")

------------------------------------------------------------
-- strsplit keeps empty fields
------------------------------------------------------------

-- The real one does, and a version that drops them turns a MISSING field into
-- a SHIFTED one: "Name--60" parsed for a level yields "60" either way here,
-- but "" in game. A host parsing anything with optional fields would pass
-- against the stub and fail in play.
local a, b, c = strsplit("-", "a--b")
H.eq(a, "a", "strsplit keeps the first field")
H.eq(b, "", "and the empty one between the separators")
H.eq(c, "b", "and the last")
H.eq(select("#", strsplit("-", "a-b-")), 3, "a trailing separator yields a trailing field")
H.eq(select(3, strsplit("-", "a-b-")), "", "which is empty")
H.eq(select("#", strsplit("-", "solo")), 1, "no separator is one field")
H.eq(select(1, strsplit("-", "solo")), "solo", "the whole string")
-- The separator is a set of characters, and one of them is magic in a Lua
-- pattern class.
local x, y = strsplit("-%", "left%right")
H.eq(x .. "|" .. y, "left|right", "a separator that is a pattern character still splits literally")

------------------------------------------------------------
-- Unit identity and role
------------------------------------------------------------

WoW.reset()
WoW.SetUnit("party1", { name = "Karuzo Elegia", guid = "GUID-K" })
WoW.SetUnit("raid3", { name = "Karuzo Elegia", guid = "GUID-K" })
WoW.SetUnit("raid4", { name = "Someone Else", guid = "GUID-S" })

H.check(UnitIsUnit("party1", "raid3"), "the same player under two tokens is one unit")
H.check(not UnitIsUnit("party1", "raid4"), "two players are not")
H.check(UnitIsUnit("party1", "party1"), "a token is itself")
H.check(not UnitIsUnit("party1", "party8"), "and a token nobody occupies is nobody")

H.eq(UnitGroupRolesAssigned("party1"), "NONE",
    "roles are declared on this client but unmeasured, so the default claims nothing")
WoW.SetUnit("raid4", { name = "Someone Else", role = "HEALER" })
H.eq(UnitGroupRolesAssigned("raid4"), "HEALER", "a test that sets one gets it back")

------------------------------------------------------------
-- GetRaidRosterInfo's full tuple
------------------------------------------------------------

WoW.reset()
WoW.inRaid, WoW.groupMembers = true, 2
WoW.SetUnit("raid1", { name = "Karuzo Elegia", class = "MAGE", level = 60, dead = true })
WoW.raidRoster = {
    { name = "Karuzo Elegia", subgroup = 2, unit = "raid1" },
    { name = "Tanky Person", subgroup = 1, rank = 2, class = "WARRIOR", level = 58,
      zone = "Blackrock Depths", online = false, isML = true, combatRole = "TANK" },
}

local name, rank, sg, level, class, file, zone, online, dead, role, isML, combatRole =
    GetRaidRosterInfo(1)
H.eq(name, "Karuzo Elegia", "the roster entry's name")
H.eq(rank, 0, "rank defaults to 0")
H.eq(sg, 2, "and the subgroup is the entry's")
H.eq(level, 60, "the rest falls back to the unit the entry names: level")
H.eq(class, "MAGE", "localised class")
H.eq(file, "MAGE", "and class file name")
H.eq(zone, "", "zone is empty unless the test sets one")
H.eq(online, true, "online unless said otherwise")
H.eq(dead, true, "dead follows the unit")
H.eq(role, "NONE", "role claims nothing")
H.eq(isML, false, "and nobody is master looter by default")
H.eq(combatRole, "NONE", "nor has a combat role")

local n2, r2, s2, l2, c2, f2, z2, o2, d2, ro2, ml2, cr2 = GetRaidRosterInfo(2)
H.eq(n2 .. "|" .. r2 .. "|" .. s2, "Tanky Person|2|1", "an entry with no unit reads its own fields")
H.eq(l2 .. "|" .. c2 .. "|" .. f2, "58|WARRIOR|WARRIOR", "level and class")
H.eq(z2, "Blackrock Depths", "zone")
H.eq(o2, false, "offline")
H.eq(d2, false, "not dead")
H.eq(ro2 .. "|" .. tostring(ml2) .. "|" .. cr2, "NONE|true|TANK", "role, master looter, combat role")

H.eq(GetRaidRosterInfo(3), nil, "past the end of the roster there is nobody")

------------------------------------------------------------
-- What a host must still get for free: the combat refusal model
------------------------------------------------------------

-- The reason sharing this file matters. Priestly's copy predates all of this,
-- so its tests could not see a refusal the client makes.
WoW.reset()
local window = WoW.makeFrame("StubTestWindow")
local row = WoW.makeFrame("StubTestRow", window, "SecureActionButtonTemplate")
WoW.inCombat = true

row:SetAttribute("type1", "spell")
H.eq(#WoW.combatWrites, 1, "a secure write in combat is recorded for the host to assert on")

window:Hide()
H.eq(#WoW.blockedCalls, 1, "hiding a frame that parents a secure button is refused, not obeyed")
H.eq(WoW.blockedCalls[1].method, "Hide", "and recorded as the call the client blocked")

WoW.inCombat = false
window:Hide()
H.eq(#WoW.blockedCalls, 1, "out of combat the same call goes through")

H.done("test_stub")
