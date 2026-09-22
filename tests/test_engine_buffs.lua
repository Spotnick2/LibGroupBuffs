------------------------------------------------------------
-- test_engine_buffs.lua - aura reads, the GUID-keyed cache, combat secrecy,
-- durations, group stats, target picking and UNIT_AURA filtering.
--
-- Ported from Priestly's tests/test_buffs.lua with the same scenarios and the
-- same expected results, run against an engine shaped like Priestly's
-- (H.PriestEngine). What stayed in Priestly: the build-change reset of stored
-- durations (its own store) and the timer formatting (its UI).
--
-- The interesting case is combat: on this client auras become unreadable while
-- tainted, and a naive read reports everyone as unbuffed - the whole frame
-- flips red the instant a pull starts.
--
--   & 'C:\Program Files (x86)\Lua\5.1\lua.exe' tests\test_engine_buffs.lua
------------------------------------------------------------

dofile("tests/wow_stubs.lua")
local H = dofile("tests/harness.lua")
local lib = H.loadLibrary()
local S = lib.Engine.STATES
local HAS, MISSING, UNKNOWN = S.HAS, S.MISSING, S.UNKNOWN

local host, E

local function setup()
    WoW.reset()
    H.TeachSpells({ "FORT_SINGLE", "FORT_GROUP" })
    host = H.PriestEngine()
    E = host.engine
    E:RefreshSpells()
    return host.def("fort")
end

local function member(unit) return { unit = unit, name = WoW.units[unit].name } end

------------------------------------------------------------
-- BuffRem: three states, not two
------------------------------------------------------------

local fort = setup()
WoW.SetUnit("party1", { name = "Karuzo Elegia", guid = "P1" })

local rem, dur, state = E:BuffRem("party1", fort)
H.eq(state, MISSING, "no aura -> MISSING")
H.eq(rem, 0, "and no time")

WoW.SetAura("party1", "Power Word: Fortitude", 3600, 1800)
rem, dur, state = E:BuffRem("party1", fort)
H.eq(state, HAS, "aura present -> HAS")
H.eq(rem, 1800, "remaining is passed through")
H.eq(dur, 3600, "duration is passed through")

H.eq(select(3, E:BuffRem("party9", fort)), MISSING, "a unit that does not exist is MISSING")

------------------------------------------------------------
-- Combat secrecy: count down from the cache instead of guessing
------------------------------------------------------------

H.secrecy(true)
WoW.time = WoW.time + 60

rem, dur, state = E:BuffRem("party1", fort)
H.eq(state, HAS, "a cached buff stays HAS while auras are unreadable")
H.eq(rem, 1740, "and the timer keeps counting down from the cached expiry")

WoW.SetUnit("party2", { name = "Sten Thornbeard", guid = "P2" })
rem, dur, state = E:BuffRem("party2", fort)
H.eq(state, UNKNOWN, "no cached state under secrecy -> UNKNOWN, never a confident MISS")

WoW.time = WoW.time + 2000
rem, dur, state = E:BuffRem("party1", fort)
H.eq(state, MISSING, "a cached buff that expired during the fight is MISSING")

H.secrecy(false)

-- Live data wins over the cache whenever it can be read at all.
fort = setup()
WoW.SetUnit("party1", { name = "Karuzo Elegia", guid = "P1" })
WoW.SetAura("party1", "Power Word: Fortitude", 3600, 1800)
E:BuffRem("party1", fort)                      -- seed the cache
WoW.secret = true                              -- flag on...
WoW.auraReadsThrow = false                     -- ...but reads still work
WoW.ClearAuras("party1")
WoW.SetAura("party1", "Renew", 15, 10)         -- still has *something*
rem, dur, state = E:BuffRem("party1", fort)
H.eq(state, MISSING,
    "a readable aura list beats the cache: losing the buff is seen, not masked by stale state")

WoW.ClearAuras("party1")
rem, dur, state = E:BuffRem("party1", fort)
H.eq(state, UNKNOWN,
    "an empty aura list under secrecy is not evidence of being unbuffed - and the "
    .. "cache was already cleared by the definite read above, so: unknown")
H.secrecy(false)

-- A permanent aura has no expiry, and is neither expired nor infinite.
fort = setup()
WoW.SetUnit("party1", { name = "Karuzo Elegia", guid = "P1" })
WoW.SetAura("party1", "Power Word: Fortitude", 0, nil)   -- expirationTime 0
rem, dur, state = E:BuffRem("party1", fort)
H.eq(state, HAS, "a permanent aura is HAS")
H.eq(rem, lib.Engine.PERMANENT, "with the PERMANENT sentinel, not math.huge")
H.secrecy(true)
rem, dur, state = E:BuffRem("party1", fort)
H.eq(rem, lib.Engine.PERMANENT, "and stays permanent from the cache")
H.secrecy(false)

------------------------------------------------------------
-- The cache is keyed by GUID, not by unit token
------------------------------------------------------------

fort = setup()
WoW.SetUnit("raid3", { name = "Karuzo Elegia", guid = "P1" })
WoW.SetAura("raid3", "Power Word: Fortitude", 3600, 1800)
E:BuffRem("raid3", fort)                              -- caches under P1

WoW.ClearAuras("raid3")
WoW.SetUnit("raid3", { name = "Sten Thornbeard", guid = "P2" })
H.secrecy(true)
rem, dur, state = E:BuffRem("raid3", fort)
H.eq(state, UNKNOWN,
    "the new occupant of raid3 does not inherit the previous player's buff")

WoW.SetUnit("raid7", { name = "Karuzo Elegia", guid = "P1" })
rem, dur, state = E:BuffRem("raid7", fort)
H.eq(state, HAS, "the same character keeps their state after moving slots")
H.secrecy(false)

------------------------------------------------------------
-- Durations: seeds are only seeds
------------------------------------------------------------

local SINGLE, PRAYER = "Power Word: Fortitude", "Prayer of Fortitude"

fort = setup()
H.eq(E:DurationFor(fort, nil, SINGLE), 3600, "with nothing learned, the def's seed is used")
H.eq(E:DurationFor(fort, 1800, SINGLE), 1800, "an observed duration always wins")

WoW.SetUnit("party1", { name = "Karuzo Elegia", guid = "P1" })
WoW.SetAura("party1", SINGLE, 1800, 900)
E:BuffRem("party1", fort)
H.eq(host.durations[SINGLE], 1800, "a live aura hands the real duration to the addon")
H.eq(E:DurationFor(fort, nil, SINGLE), 1800,
    "and that is what later bars are scaled against")

WoW.ClearAuras("party1")
WoW.SetAura("party1", SINGLE, 600, 300)
E:BuffRem("party1", fort)
H.eq(host.durations[SINGLE], 600, "durations are replaced in both directions, not maxed")

-- The single and group forms of one buff share a def id and do NOT share a
-- duration.
fort = setup()
WoW.SetUnit("party1", { name = "A One", guid = "P1" })
WoW.SetUnit("party2", { name = "B Two", guid = "P2" })
WoW.SetAura("party1", SINGLE, 1800, 900)
WoW.SetAura("party2", PRAYER, 3600, 1800)
E:BuffRem("party1", fort)
E:BuffRem("party2", fort)
H.eq(host.durations[SINGLE], 1800, "the single form keeps its own duration")
H.eq(host.durations[PRAYER], 3600, "and the group form keeps its own")
E:BuffRem("party2", fort)
E:BuffRem("party1", fort)
H.eq(host.durations[SINGLE], 1800, "still the single form's duration")
H.eq(host.durations[PRAYER], 3600, "still the group form's")
H.eq(E:DurationFor(fort, nil, PRAYER), 3600,
    "and a bar scales against the spell that member actually has")
H.eq(E:DurationFor(fort, nil, SINGLE), 1800, "...not against the other one")

-- Storage is optional: an addon without it gets the seed.
do
    local bare = lib.Engine.New({
        defs = { { id = "fort", snglID = H.SPELL.FORT_SINGLE, sngl = SINGLE, duration = 1234 } },
        bucketSize = 8,
    })
    bare:RefreshSpells()
    WoW.SetUnit("party1", { name = "A One", guid = "P1" })
    WoW.SetAura("party1", SINGLE, 1800, 900)
    H.check(pcall(bare.BuffRem, bare, "party1", bare.defs[1]), "reading without storage is fine")
    H.eq(bare:DurationFor(bare.defs[1], nil, SINGLE), 1234, "and the seed is the fallback")
end

------------------------------------------------------------
-- GroupStat
------------------------------------------------------------

fort = setup()
WoW.SetUnit("party1", { name = "A One", guid = "P1" })
WoW.SetUnit("party2", { name = "B Two", guid = "P2" })
WoW.SetUnit("party3", { name = "C Three", guid = "P3" })
local members = { member("party1"), member("party2"), member("party3") }

local st = E:GroupStat(members, fort)
H.eq(st.nTotal, 3, "counts everyone")
H.eq(st.nMiss, 3, "nobody buffed -> all missing")
H.check(st.allHave == false, "and allHave is false")

WoW.SetAura("party1", "Power Word: Fortitude", 3600, 3000)
WoW.SetAura("party2", "Power Word: Fortitude", 1800, 1200)
st = E:GroupStat(members, fort)
H.eq(st.nMiss, 1, "one still missing")
H.eq(st.minR, 1200, "the bar shows the lowest remaining time")
H.eq(st.minDur, 1800, "scaled by the duration of that same aura")

WoW.SetAura("party3", "Power Word: Fortitude", 3600, 2000)
st = E:GroupStat(members, fort)
H.eq(st.nMiss, 0, "everyone buffed")
H.check(st.allHave == true, "allHave")

WoW.units.party3.connected = false
st = E:GroupStat(members, fort)
H.eq(st.nMiss, 1, "a disconnected member counts as missing")
WoW.units.party3.connected = true

H.secrecy(true)
for k in pairs(E.cache) do E.cache[k] = nil end
st = E:GroupStat(members, fort)
H.eq(st.nUnknown, 3, "with no cache under secrecy everyone is unknown")
H.eq(st.nMiss, 0, "and nobody is reported as missing")
H.check(st.allHave == false, "unknown is not 'everyone has it' either")
H.secrecy(false)

------------------------------------------------------------
-- PickTarget
------------------------------------------------------------

local function party3()
    local d = setup()
    WoW.SetUnit("party1", { name = "A One", guid = "P1" })
    WoW.SetUnit("party2", { name = "B Two", guid = "P2" })
    WoW.SetUnit("party3", { name = "C Three", guid = "P3" })
    return d, { member("party1"), member("party2"), member("party3") }
end

fort, members = party3()
WoW.SetAura("party1", "Power Word: Fortitude", 3600, 3000)
WoW.SetAura("party3", "Power Word: Fortitude", 3600, 3000)
H.eq(E:PickTarget(members, fort, false), "party2", "single target picks the one missing it")

WoW.SetAura("party2", "Power Word: Fortitude", 3600, 500)
H.eq(E:PickTarget(members, fort, false), "party2",
    "with nobody missing it picks the lowest remaining")
H.eq(E:PickTarget(members, fort, true), "party2",
    "a group spell also refreshes whoever has the least time left")

-- A group spell only covers the target's own subgroup, and a raid's pet
-- bucket mixes pets from several parties: aiming at the first valid pet kept
-- recasting on one already buffed while the others stayed missing.
fort, members = party3()
WoW.SetAura("party1", "Power Word: Fortitude", 3600, 3000)
H.eq(E:PickTarget(members, fort, true), "party2",
    "a group spell is aimed at a member still missing the buff")

-- Range matters.
fort, members = party3()
WoW.range.party1 = false        -- missing the buff, but too far away
WoW.range.party2 = true
WoW.range.party3 = true
H.eq(E:PickTarget(members, fort, false), "party2",
    "an in-range member beats the first missing one when that one is out of range")
H.eq(E:PickTarget(members, fort, true), "party2", "a group spell is aimed at somebody reachable")

WoW.range.party2 = false
WoW.range.party3 = false
H.eq(E:PickTarget(members, fort, false), "party1",
    "falls back to an out-of-range target rather than none at all")

WoW.range.party1, WoW.range.party2, WoW.range.party3 = nil, nil, nil
H.check(E:PickTarget(members, fort, false) ~= nil, "unknown range does not veto every target")

-- The range check tests the spell the click will actually cast: the group
-- form reaches 40 yards where the single form reaches 30.
fort = setup()
WoW.SetUnit("party1", { name = "Zoruka Mortalis", guid = "P1" })
WoW.SetUnit("party2", { name = "Sten Thornbeard", guid = "P2" })
local spread = { member("party1"), member("party2") }
WoW.range.party1 = { ["Power Word: Fortitude"] = false, ["Prayer of Fortitude"] = false }
WoW.range.party2 = { ["Power Word: Fortitude"] = false, ["Prayer of Fortitude"] = true }
H.eq(E:PickTarget(spread, fort, true), "party2",
    "a group spell is range-checked against its own reach")
H.eq(E:PickTarget(spread, fort, false), "party1",
    "the single-target click uses the shorter range, finds nobody, and falls back")
WoW.range.party1, WoW.range.party2 = nil, nil

-- Dead and offline members are never targets.
fort, members = party3()
WoW.SetAura("party1", "Power Word: Fortitude", 3600, 3000)
WoW.SetAura("party2", "Power Word: Fortitude", 3600, 500)
WoW.SetAura("party3", "Power Word: Fortitude", 3600, 3000)
WoW.units.party1.dead = true
WoW.units.party2.connected = false
H.eq(E:PickTarget(members, fort, true), "party3", "dead and offline members are skipped")
WoW.units.party3.dead = true
H.check(E:PickTarget(members, fort, true) == nil, "nobody valid -> no target")
H.check(E:PickTarget(members, fort, false) == nil, "...for either click")

-- UNKNOWN is never treated as missing, but is still a last-resort target.
fort, members = party3()
H.secrecy(true)
H.eq(E:PickTarget(members, fort, false), "party1",
    "with every member unknown, the first valid member is the fallback")
H.secrecy(false)
WoW.SetAura("party2", "Power Word: Fortitude", 3600, 500)
E:BuffRem("party2", fort)                   -- cache party2 only
H.secrecy(true)
H.eq(E:PickTarget(members, fort, false), "party2",
    "a known buffed member beats unknown ones: unknown is not counted as missing")
H.secrecy(false)

-- GroupStat's per-member states are reused: no second aura read.
fort, members = party3()
WoW.SetAura("party2", "Power Word: Fortitude", 3600, 500)
st = E:GroupStat(members, fort)
local realRead, reads = lib.API.ReadBuff, 0
lib.API.ReadBuff = function(...) reads = reads + 1 return realRead(...) end
local picked = E:PickTarget(members, fort, false, st)
lib.API.ReadBuff = realRead
H.eq(picked, "party1", "the stats' states pick the missing member")
H.eq(reads, 0, "without reading a single aura again")

------------------------------------------------------------
-- Cache pruning
------------------------------------------------------------

fort = setup()
WoW.SetUnit("party1", { name = "A One", guid = "P1" })
WoW.SetAura("party1", "Power Word: Fortitude", 3600, 3000)
E:BuffRem("party1", fort)
H.check(E.cache["P1"] ~= nil, "the read was cached")
WoW.time = WoW.time + 7200
E:PruneCache()
H.check(E.cache["P1"] == nil, "stale characters are pruned")

------------------------------------------------------------
-- UNIT_AURA filtering
------------------------------------------------------------

fort = setup()
H.check(E:AuraEventIsRelevant("party1", { isFullUpdate = true }) == true,
    "a full update on a group member is relevant")
H.check(E:AuraEventIsRelevant("raidpet4", { isFullUpdate = true }) == true,
    "and on a group member's pet")
H.check(E:AuraEventIsRelevant("target", { isFullUpdate = true }) == false,
    "units never drawn are ignored")
H.check(E:AuraEventIsRelevant("nameplate3", { isFullUpdate = true }) == false,
    "nameplates are ignored")
H.check(E:AuraEventIsRelevant(nil, { isFullUpdate = true }) == false, "no unit is ignored")
H.check(E:AuraEventIsRelevant("player", nil) == true,
    "no payload at all -> refresh, it cannot be told")
H.check(E:AuraEventIsRelevant("raid1", {
    addedAuras = { { name = "Power Word: Fortitude" } } }) == true,
    "one of the addon's buffs being applied is relevant")
H.check(E:AuraEventIsRelevant("raid1", {
    addedAuras = { { name = "Prayer of Shadow Protection" } } }) == true,
    "including a buff whose row is hidden: its aura may be what shows the row")
H.check(E:AuraEventIsRelevant("raid1", {
    addedAuras = { { name = "Renew" }, { name = "Mark of the Wild" } } }) == false,
    "somebody else's HoT ticking is not")
H.check(E:AuraEventIsRelevant("raid1", { removedAuraInstanceIDs = { 12 } }) == true,
    "a removal carries no spell, so it counts")

-- Secret values throw when truth-tested, not only when read.
H.check(pcall(E.AuraEventIsRelevant, E, "party1", { addedAuras = { WoW.SecretAura() } }),
    "a secret aura in the payload does not throw")
H.check(E:AuraEventIsRelevant("party1", { addedAuras = { WoW.SecretAura() } }) == true,
    "and an unreadable payload refreshes rather than being skipped")
local secretInfo = WoW.SecretUpdateInfo()
H.check(pcall(E.AuraEventIsRelevant, E, "player", secretInfo),
    "a payload whose own fields are secret does not throw")
H.check(E:AuraEventIsRelevant("player", secretInfo) == true, "and counts as relevant")

H.done("test_engine_buffs")
