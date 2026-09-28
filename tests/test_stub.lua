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
H.eq(select(3, GetBuildInfo()), "Sep 23 2026", "with the date that build reports")
H.eq(select("#", GetInstanceInfo()), 11, "and GetInstanceInfo returns this client's tuple")

-- The realm slot: 70009 splits every unit, 69913 joined for the player and
-- gave a real realm. Unresolved which changed, so both are reachable.
WoW.SetUnit("player", { name = "Karuzo Elegia" })
local first, second = UnitName("player")
H.eq(first .. "|" .. second, "Karuzo|Elegia", "UnitName splits, surname in the realm slot")
WoW.SetUnit("player", { name = "Karuzo Elegia", realm = "ClassicBetaPvE" })
first, second = UnitName("player")
H.eq(first .. "|" .. second, "Karuzo Elegia|ClassicBetaPvE",
    "and a unit given a realm comes back joined, the way 69913 read")
H.eq(GetUnitName("player"), "Karuzo Elegia", "GetUnitName joins under both")
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
H.eq(role, nil, "role is empty, not a value this stub made up")
H.eq(isML, false, "and nobody is master looter by default")
H.eq(combatRole, nil, "nor is a combat role invented")

local n2, r2, s2, l2, c2, f2, z2, o2, d2, ro2, ml2, cr2 = GetRaidRosterInfo(2)
H.eq(n2 .. "|" .. r2 .. "|" .. s2, "Tanky Person|2|1", "an entry with no unit reads its own fields")
H.eq(l2 .. "|" .. c2 .. "|" .. f2, "58|WARRIOR|WARRIOR", "level and class")
H.eq(z2, "Blackrock Depths", "zone")
H.eq(o2, false, "offline")
H.eq(d2, false, "not dead")
H.eq(tostring(ro2) .. "|" .. tostring(ml2) .. "|" .. tostring(cr2), "nil|true|TANK",
    "role, master looter, combat role")

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

-- Whether a frame takes the mouse: a tooltip that can never open looks
-- exactly like one that can, and the catch-all answered the question with
-- the frame itself until this was written down. Both states, because one
-- implementation of this returned true unconditionally.
local mouseFrame = WoW.makeFrame("MouseProbe")
H.check(not mouseFrame:IsMouseEnabled(), "a frame does not take the mouse until told to")
mouseFrame:EnableMouse(true)
H.check(mouseFrame:IsMouseEnabled(), "and does once enabled")
mouseFrame:EnableMouse(false)
H.check(not mouseFrame:IsMouseEnabled(), "and stops again when disabled")

------------------------------------------------------------
-- An undefined widget method is an error, not a no-op
--
-- The stub is the list of what this client has, and that has to cover methods
-- as well as globals. A catch-all that answers anything with a callable is how
-- GameTooltip:SetItemByID - which does not exist on Forever at all - survived
-- a green suite and failed only in game, and how four assertions in one
-- afternoon came to be unfalsifiable: a frame's `iconEdge` answered with a
-- function, so `if not f.iconEdge` was false under test and true in the
-- client, and the branch the test existed to cover never ran.
------------------------------------------------------------

local strict = CreateFrame("Frame")

H.check(not pcall(function() return strict:NoSuchWidgetMethod() end),
    "a PascalCase method the stub does not define is an error")
local _, why = pcall(function() return strict:NoSuchWidgetMethod() end)
H.check(tostring(why):find("NoSuchWidgetMethod", 1, true),
    "and the message names it: " .. tostring(why))
H.check(tostring(why):find("forever%-api"),
    "and says where to check whether this client has it")

-- The ones it does define still work, and so do the deliberate no-ops.
H.check(pcall(function() return strict:SetMovable(true) end),
    "a method this client has, modelled as doing nothing, is fine")
H.check(pcall(function() return strict:Show() end), "and one the stub implements")

-- A host can add its own, having checked the dump.
H.check(not pcall(function() return strict:HostOnlyMethod() end),
    "a host's own method is an error until it is allowed")
WoW.allowMethod("HostOnlyMethod")
H.check(pcall(function() return strict:HostOnlyMethod() end),
    "and works once the host allows it")

------------------------------------------------------------
-- The addon's OWN fields read nil, whatever they are called
--
-- An unset field is nil. Handing back a callable makes every unset flag read
-- as true, which is how a test asserts a state the addon is not in - and it
-- made `type(r.iconEdge) ~= "table"` necessary where `not r.iconEdge` should
-- have done. The split is by case: this client's widget methods are all
-- PascalCase and an addon's fields are not.
------------------------------------------------------------

H.eq(strict.iconEdge, nil, "a camelCase field the addon has not set reads nil")
H.eq(strict.fill, nil, "and a lower-case one")
H.eq(strict._private, nil, "and an underscored one, as before")
strict.fill = { real = true }
H.check(strict.fill.real, "and a field that IS set reads back")

-- PascalCase members a Blizzard template would have created are absent until
-- one really does. Tools/PriestlyProbe decides whether a template applied by
-- asking whether frame.Left is nil, and a catch-all answered yes every time -
-- so the probe could never report a template as missing.
H.eq(strict.Left, nil, "a template's region reads nil when no template made it")
H.eq(strict.Text, nil, "and so does its text")

H.done("test_stub")
