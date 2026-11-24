------------------------------------------------------------
-- test_covered.lua - auras that cover a buff (r38, #95).
--
-- A member with Might of Stormwind (or Warchief's Blessing) gets "A more
-- powerful spell is already active" from Power Word: Fortitude. They have no
-- Fortitude aura, so they read as missing, and the picker aimed every click at
-- them. A def lists such auras in `coveredBy`; a covered member is neither
-- missing nor ever picked, and the window names the aura.
--
--   & 'C:\Program Files (x86)\Lua\5.1\lua.exe' tests\test_covered.lua
------------------------------------------------------------

dofile("tests/wow_stubs.lua")
local H = dofile("tests/harness.lua")
local lib = H.loadLibrary()
local S = lib.Engine.STATES
local HAS, MISSING, UNKNOWN = S.HAS, S.MISSING, S.UNKNOWN

local MIGHT, MIGHT_MELEE, WARCHIEF, WARCHIEF_2, WARCHIEF_3 = 460939, 460940, 16609, 355366, 1304594
local COVERS = { MIGHT, MIGHT_MELEE, WARCHIEF, WARCHIEF_2, WARCHIEF_3 }

-- The client has three of the five; the other two resolve to nothing.
local function DefineWorldBuffs()
    WoW.DefineSpell(MIGHT, "Might of Stormwind")
    WoW.DefineSpell(MIGHT_MELEE, "Might of Stormwind")
    WoW.DefineSpell(WARCHIEF, "Warchief's Blessing")
end

local host, E

local function setup(known)
    WoW.reset()
    H.TeachSpells(known or { "FORT_SINGLE", "FORT_GROUP" })
    DefineWorldBuffs()
    host = H.PriestEngine()
    host.def("fort").coveredBy = COVERS
    E = host.engine
    E:RefreshSpells()
    WoW.SetUnit("player", { name = "Karuzo Elegia", guid = "P0", class = "PRIEST" })
    WoW.SetUnit("party1", { name = "Sten Thornbeard", guid = "P1", class = "WARRIOR" })
    WoW.SetUnit("party2", { name = "Mirel Dawnsong", guid = "P2", class = "MAGE" })
    WoW.groupMembers = 3
    return host.def("fort")
end

local function members()
    return {
        { unit = "player", name = "Karuzo Elegia" },
        { unit = "party1", name = "Sten Thornbeard" },
        { unit = "party2", name = "Mirel Dawnsong" },
    }
end

------------------------------------------------------------
-- The def field is checked at load
------------------------------------------------------------

local function newWith(coveredBy)
    return pcall(lib.Engine.New, {
        bucketSize = 8,
        defs = { { id = "fort", snglID = 1243, coveredBy = coveredBy } },
    })
end
H.check(newWith(nil), "no coveredBy is fine")
H.check(newWith({}), "an empty list is fine")
H.check(newWith(COVERS), "a list of spell IDs is fine")
local ok, err = newWith("Might of Stormwind")
H.check(not ok and tostring(err):find("coveredBy must be a list"), "a string is refused: " .. tostring(err))
ok, err = newWith({ "Might of Stormwind" })
H.check(not ok and tostring(err):find("spell IDs"), "a list of names is refused: " .. tostring(err))

------------------------------------------------------------
-- Names come from the IDs
------------------------------------------------------------

local fort = setup()
H.eq(#fort.coverNames, 2, "two names: the variants share one, the unknown IDs resolve to none")
H.eq(fort.coverNames[1], "Might of Stormwind", "in the def's order")
H.eq(fort.coverNames[2], "Warchief's Blessing", "both factions")
H.eq(host.def("spirit").coverNames, nil, "a def without the field has none")

local inUnion = {}
for _, nm in ipairs(E.allNames) do inUnion[nm] = true end
H.check(inUnion["Might of Stormwind"] and inUnion["Warchief's Blessing"],
    "covering names join the aura pass's union, so one walk answers them")

local report = E:SpellReport()
local fortReport
for _, d in ipairs(report) do if d.id == "fort" then fortReport = d end end
H.eq(#fortReport.covers, 5, "the report lists every covering ID")
H.eq(fortReport.covers[1].name, "Might of Stormwind", "with its name")
H.eq(fortReport.covers[4].name, nil, "and nil for one this client does not have")
H.eq(report[2].covers, nil, "a def without covering auras reports none")

-- A name the client gave once is remembered if it stops answering.
WoW.spells[WARCHIEF] = nil
E:RefreshSpells()
H.eq(fort.coverNames[2], "Warchief's Blessing", "a resolved name is remembered")

------------------------------------------------------------
-- The picker never aims at a covered member (the bug)
------------------------------------------------------------

fort = setup()
WoW.SetAura("player", "Might of Stormwind", 7200, 5000, MIGHT)
local ms = members()

H.eq(E:PickTarget(ms, fort, false), "party1",
    "the first missing member is skipped when covered; the next missing one is picked")

local cover, coverRem = E:CoverOf("player", fort)
H.eq(cover, "Might of Stormwind", "CoverOf names the aura")
H.eq(coverRem, 5000, "with its time left")
H.eq(E:CoverOf("party1", fort), false, "false for a member known to have none")
H.eq(E:CoverOf("player", host.def("spirit")), false, "false for a def with no covering auras")

local rem, _, state = E:BuffRem("player", fort)
H.eq(state, MISSING, "BuffRem still answers about Fortitude itself")
H.eq(rem, 0, "with no time")

-- Nobody else missing: the shortest-remaining fallback must not land on them.
WoW.SetAura("party1", "Power Word: Fortitude", 3600, 3000)
WoW.SetAura("party2", "Power Word: Fortitude", 3600, 1000)
H.eq(E:PickTarget(ms, fort, false), "party2", "the fallback picks the shortest of the others")

-- A covered member who still has Fortitude, lower than anybody else's.
WoW.SetAura("player", "Power Word: Fortitude", 3600, 100)
H.eq(E:PickTarget(ms, fort, false), "party2",
    "a covered member's own short Fortitude is not a target: the recast is refused too")
local st = E:GroupStat(ms, fort)
H.eq(st.minR, 1000, "and not the row's shortest time either")
H.eq(st.byUnit.player.state, HAS, "their own Fortitude is still seen")
H.eq(st.byUnit.player.covered, "Might of Stormwind", "and the cover beside it")
WoW.ClearAuras("player")
WoW.SetAura("player", "Might of Stormwind", 7200, 5000, MIGHT)

-- Everyone covered: the first-valid fallback must not pick them either.
fort = setup()
for _, u in ipairs({ "player", "party1", "party2" }) do
    WoW.SetAura(u, "Warchief's Blessing", 7200, 5000, WARCHIEF)
end
H.eq(E:PickTarget(members(), fort, false), nil, "nobody to aim at when all are covered")
H.eq(E:PickTarget(members(), fort, true), nil, "group form too")
H.eq(E:PickRaidTarget(members(), fort), nil, "and the raid-wide pick finds nobody missing")

-- The same answers through GroupStat's states (the window's path).
fort = setup()
WoW.SetAura("player", "Might of Stormwind", 7200, 5000, MIGHT)
st = E:GroupStat(members(), fort)
H.eq(st.nMiss, 2, "a covered member does not count as missing")
H.eq(st.nCovered, 1, "they are counted as covered")
H.eq(st.nUnknown, 0, "not as unknown")
H.eq(E:PickTarget(members(), fort, false, st), "party1", "PickTarget with st skips them")
WoW.SetAura("party1", "Power Word: Fortitude", 3600, 3000)
WoW.SetAura("party2", "Power Word: Fortitude", 3600, 1000)
st = E:GroupStat(members(), fort)
H.check(st.allHave, "everyone else buffed: the row is complete")
H.eq(E:PickRaidTarget(members(), fort, st), nil, "and the raid-wide click goes quiet")
H.eq(E:PickRaidTarget(members(), fort), nil, "without st too")

-- Without coveredBy nothing changes: the covered member is picked as before.
fort = setup()
fort.coveredBy = nil
E:RefreshSpells()
WoW.SetAura("player", "Might of Stormwind", 7200, 5000, MIGHT)
H.eq(E:PickTarget(members(), fort, false), "player", "a def without the field keeps the old pick")
H.eq(E:GroupStat(members(), fort).nCovered, 0, "and counts nobody as covered")

------------------------------------------------------------
-- Durations: nothing is learned from the covering aura
------------------------------------------------------------

fort = setup()
WoW.SetAura("player", "Might of Stormwind", 7200, 5000, MIGHT)
E:GroupStat(members(), fort)
H.eq(host.durations["Might of Stormwind"], nil, "the covering aura's duration is not learned")

------------------------------------------------------------
-- Combat: the cache rules
------------------------------------------------------------

fort = setup()
WoW.SetAura("player", "Might of Stormwind", 7200, 600, MIGHT)
E:GroupStat(members(), fort)                     -- the last look before the pull
H.secrecy(true)
st = E:GroupStat(members(), fort)
H.eq(st.byUnit.player.covered, "Might of Stormwind", "coverage carries forward while auras are secret")
H.eq(st.nMiss, 2, "the others stay remembered as missing")
H.eq(E:PickTarget(members(), fort, false), "party1", "and the covered member is still skipped")

WoW.time = WoW.time + 700                        -- its own clock runs out mid-fight
st = E:GroupStat(members(), fort)
H.eq(st.byUnit.player.covered, nil, "a covering aura that ran out covers no more")
H.eq(st.byUnit.player.state, MISSING, "and they are missing again, as remembered")
H.eq(st.nMiss, 3, "counted as such")

-- Never seen: UNKNOWN, never a confident MISS.
WoW.SetUnit("party3", { name = "Ilse Varn", guid = "P3", class = "ROGUE" })
rem, _, state = E:BuffRem("party3", fort)
H.eq(state, UNKNOWN, "BuffRem: nothing cached")
H.eq(E:CoverOf("party3", fort), nil, "CoverOf: nil, it cannot be known")
H.secrecy(false)

-- Two covering auras up: the longer one is remembered, so coverage does not
-- end mid-fight when the shorter one runs out (Codex round 1 on #95).
fort = setup()
WoW.SetAura("player", "Might of Stormwind", 7200, 300, MIGHT)
WoW.SetAura("player", "Warchief's Blessing", 7200, 3000, WARCHIEF)
cover, coverRem = E:CoverOf("player", fort)
H.eq(cover, "Warchief's Blessing", "the longer-lasting cover is the answer")
H.eq(coverRem, 3000, "with its time")
H.secrecy(true)
WoW.time = WoW.time + 600                        -- the shorter one has run out
H.eq(E:CoverOf("player", fort), "Warchief's Blessing", "coverage outlives the shorter aura")
H.eq(E:PickTarget(members(), fort, false), "party1", "and the member is still skipped")
H.secrecy(false)

-- A permanent cover outlasts a timed one, even one longer than the clamped
-- PERMANENT (Codex round 2).
fort = setup()
WoW.SetAura("player", "Might of Stormwind", 0, nil, MIGHT)             -- permanent
WoW.SetAura("player", "Warchief's Blessing", 20000, 15000, WARCHIEF)   -- timed, > 9999
cover, coverRem = E:CoverOf("player", fort)
H.eq(cover, "Might of Stormwind", "the permanent cover wins")
H.eq(coverRem, lib.Engine.PERMANENT, "reported as PERMANENT")
H.secrecy(true)
WoW.time = WoW.time + 16000                      -- the timed one has run out
H.eq(E:CoverOf("player", fort), "Might of Stormwind", "and is what combat remembers")
H.secrecy(false)

-- A read refused for one name proves only what it saw: a longer cover
-- remembered from before stands (Codex round 2). The stub's walk blocks
-- every name at once, so the partial refusal is staged on ReadBuff.
fort = setup()
WoW.SetAura("player", "Might of Stormwind", 7200, 300, MIGHT)
WoW.SetAura("player", "Warchief's Blessing", 7200, 3000, WARCHIEF)
E:CoverOf("player", fort)                        -- remembers Warchief's, 3000
local realRead = lib.API.ReadBuff
lib.API.ReadBuff = function(unit, names, pass)
    if names[1] == "Warchief's Blessing" then return "BLOCKED" end
    return realRead(unit, names, pass)
end
cover, coverRem = E:CoverOf("player", fort)
H.eq(cover, "Warchief's Blessing", "a partly refused read keeps the longer remembered cover")
H.eq(coverRem, 3000, "with its time")
lib.API.ReadBuff = realRead
H.secrecy(true)
WoW.time = WoW.time + 600
H.eq(E:CoverOf("player", fort), "Warchief's Blessing", "and it is still remembered afterwards")
H.secrecy(false)

-- But only when that aura's OWN read was refused: read afresh with less time,
-- it is what the read says (Codex round 3).
fort = setup()
WoW.SetAura("player", "Might of Stormwind", 7200, 300, MIGHT)
WoW.SetAura("player", "Warchief's Blessing", 7200, 3000, WARCHIEF)
E:CoverOf("player", fort)                        -- remembers Warchief's, 3000
WoW.ClearAuras("player")
WoW.SetAura("player", "Warchief's Blessing", 7200, 200, WARCHIEF)   -- now 200 left
lib.API.ReadBuff = function(unit, names, pass)
    if names[1] == "Might of Stormwind" then return "BLOCKED" end
    return realRead(unit, names, pass)
end
cover, coverRem = E:CoverOf("player", fort)
lib.API.ReadBuff = realRead
H.eq(coverRem, 200, "a fresh read of the remembered aura replaces its old time")
H.secrecy(true)
WoW.time = WoW.time + 250
H.eq(E:CoverOf("player", fort), false, "so coverage ends when it really runs out")
H.secrecy(false)

-- The remembered aura's own read says it is gone while the other name's is
-- refused: the memory is dropped, not reported (Codex round 4).
fort = setup()
WoW.SetAura("player", "Warchief's Blessing", 7200, 3000, WARCHIEF)
E:CoverOf("player", fort)                        -- remembers Warchief's
WoW.ClearAuras("player")
WoW.SetAura("player", "Renew", 15, 10)
lib.API.ReadBuff = function(unit, names, pass)
    if names[1] == "Might of Stormwind" then return "BLOCKED" end
    return realRead(unit, names, pass)
end
H.eq(E:CoverOf("player", fort), nil, "a contradicted memory is not reported; the rest is unknown")
lib.API.ReadBuff = realRead
H.secrecy(true)
H.eq(E:CoverOf("player", fort), nil, "and cannot resurface once every read is refused")
H.secrecy(false)

-- Clearing coveredBy takes effect before the next refresh.
fort = setup()
WoW.SetAura("player", "Might of Stormwind", 7200, 5000, MIGHT)
fort.coveredBy = nil
H.eq(E:CoverOf("player", fort), false, "a cleared list covers nothing at once")
H.eq(E:AuraEventIsRelevant("party1", { addedAuras = { { name = "Might of Stormwind" } } }), false,
    "and the event filter stops matching it")

-- A def an older copy refreshed: coveredBy is there, coverNames is not.
fort = setup()
fort.coverNames, fort.coverSingles, fort.coverByID = nil, nil, nil
WoW.SetAura("player", "Might of Stormwind", 7200, 5000, MIGHT)
H.eq(E:CoverOf("player", fort), "Might of Stormwind", "CoverOf resolves the names itself")
fort.coverNames, fort.coverSingles, fort.coverByID = nil, nil, nil
H.eq(E:AuraEventIsRelevant("party1", { addedAuras = { { name = "Warchief's Blessing" } } }), true,
    "and so does the aura event filter")
fort.coverNames, fort.coverSingles, fort.coverByID = nil, nil, nil
E.allNames = { "Power Word: Fortitude", "Prayer of Fortitude" }   -- the old copy's union
E:BeginAuraPass()
H.eq(E:CoverOf("player", fort), "Might of Stormwind", "inside such a pass the read goes live")
WoW.ClearAuras("player")
H.eq(E:CoverOf("player", fort), false, "and a live absence is an absence")
E:EndAuraPass()

-- A buff seen missing but whose cover was never looked at (an engine an older
-- copy filled before the pull) is UNKNOWN, not MISSING.
fort = setup()
E:BuffRem("party1", fort)                        -- Fortitude's absence cached...
H.secrecy(true)                                  -- ...but never the cover
st = E:GroupStat({ { unit = "party1", name = "Sten Thornbeard" } }, fort)
H.eq(st.byUnit.party1.state, UNKNOWN, "missing, but cover unknown: UNKNOWN")
H.eq(st.nMiss, 0, "and not counted as missing")
H.secrecy(false)

-- An engine an older copy built has no coverCache yet.
fort = setup()
E.coverCache = nil
WoW.SetAura("player", "Might of Stormwind", 7200, 5000, MIGHT)
H.eq(E:CoverOf("player", fort), "Might of Stormwind", "CoverOf makes its cache on first use")
E:PruneCache()
H.check(E.coverCache.P0, "PruneCache keeps a fresh entry")
WoW.time = WoW.time + 4000
E:PruneCache()
H.eq(E.coverCache.P0, nil, "and drops one not seen in an hour")

------------------------------------------------------------
-- UNIT_AURA: a covering aura landing is relevant
------------------------------------------------------------

fort = setup()
H.eq(E:AuraEventIsRelevant("party1", { addedAuras = { { name = "Might of Stormwind" } } }), true,
    "a covering aura landing is relevant")
H.eq(E:AuraEventIsRelevant("party1", { addedAuras = { { name = "Mark of the Wild" } } }), false,
    "an unrelated one is not")

------------------------------------------------------------
-- The window: the popover and the combat list name the aura
------------------------------------------------------------

WoW.reset()
H.TeachSpells({ "FORT_SINGLE" })
DefineWorldBuffs()
local engineHost = H.PriestEngine()
engineHost.def("fort").coveredBy = COVERS
local uhost = H.PriestUI({ engineHost = engineHost })
local ui = uhost.ui
uhost.config.visible.spirit = false
uhost.config.visible.shadow = false
uhost.engine:RefreshSpells()
H.Party3()
WoW.SetAura("player", "Might of Stormwind", 7200, 5000, MIGHT)
ui:Update()
local row = H.ActiveRows(ui)[1]
H.check(row, "a Fortitude row")
H.eq(row:GetAttribute("unit1"), "party1", "the row's click is wired at the next member, not the covered one")
H.eq(row:GetAttribute("spell1"), "Power Word: Fortitude", "and armed")
row:SetAttribute("unit1", "player")              -- stale wiring, for PreClick to fix
H.runScript(row, "PreClick", "LeftButton")
H.eq(row:GetAttribute("unit1"), "party1", "PreClick aims at the next member who needs it")

H.runScript(row, "OnEnter")
local pr = ui.popRows[1]
H.eq(pr._unit, "player", "the popover's first row is the covered member")
H.eq(pr._cover, "Might of Stormwind", "it knows the covering aura")
H.eq(pr.timeTxt:GetText(), lib.UI.FmtTime(5000), "and shows its time instead of MISS")
H.eq(ui.popRows[2].timeTxt:GetText(), "MISS", "a member really missing it still reads MISS")

WoW.clearTooltip()
H.runScript(pr, "OnEnter")
local text = WoW.tooltipText()
H.check(text:find("Might of Stormwind", 1, true) and text:find("Power Word: Fortitude", 1, true),
    "the popover row's tooltip names the aura and the buff it blocks: " .. text)
-- The cover goes while the cursor rests on the row (Codex round 4).
WoW.mouseOver[pr] = true
WoW.ClearAuras("player")
ui:RefreshTimers()
H.eq(pr.timeTxt:GetText(), "MISS", "the row turns to MISS")
H.eq(WoW.tooltipText(), "", "and its stale tooltip goes with the cover")
WoW.SetAura("player", "Might of Stormwind", 7200, 5000, MIGHT)
ui:RefreshTimers()
H.check(WoW.tooltipText():find("Might of Stormwind", 1, true),
    "and comes back, redrawn, when the cover does: " .. WoW.tooltipText())
WoW.mouseOver[pr] = nil
H.runScript(pr, "OnLeave")
WoW.ClearAuras("player")
ui:RefreshTimers()
H.eq(WoW.tooltipText(), "", "with the mouse elsewhere nothing is drawn")
WoW.SetAura("player", "Might of Stormwind", 7200, 5000, MIGHT)
ui:RefreshTimers()
H.eq(WoW.tooltipText(), "", "not even when the cover comes back")
WoW.clearTooltip()
H.runScript(ui.popRows[2], "OnEnter")
H.eq(WoW.tooltipText(), "", "a member who is not covered gets no such tooltip")
H.runScript(row, "OnLeave")

-- In combat the hint lists them apart, by aura, and not as needing it.
H.secrecy(true)
WoW.clearTooltip()
ui:ShowClickHint(row)
text = WoW.tooltipText()
local needs = text:match("Needs it, from what can still be seen:(.-)Covered by") or ""
H.check(needs:find("Sten Thornbeard") and not needs:find("Karuzo Elegia"),
    "the covered member is not in the needs list: " .. needs)
local coveredPart = text:match("Covered by a stronger buff:(.*)$") or ""
H.check(coveredPart:find("Karuzo Elegia") and coveredPart:find("Might of Stormwind"),
    "they are listed under the covering aura: " .. coveredPart)
H.secrecy(false)

H.done("test_covered")
