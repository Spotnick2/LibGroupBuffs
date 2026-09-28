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
local basis
rem, dur, state, _, basis = E:BuffRem("party1", fort)
H.eq(state, MISSING,
    "a readable aura list beats the cache: losing the buff is seen, not masked by stale state")
H.eq(basis, "live", "and it is this moment's read")

-- An empty aura list under secrecy is not evidence of being unbuffed, so the
-- read is refused - but the definite absence seen a moment ago is remembered,
-- which is better than the UNKNOWN this used to report.
WoW.ClearAuras("party1")
rem, dur, state, _, basis = E:BuffRem("party1", fort)
H.eq(state, MISSING, "the absence just confirmed still stands")
H.eq(basis, "remembered", "as remembered, not as a fresh read")
H.secrecy(false)

------------------------------------------------------------
-- A confirmed absence is remembered, and reported as remembered
--
-- It is the last thing anybody can learn before combat closes the reads.
-- Dropping it turned a member checked a second ago into UNKNOWN the moment a
-- fight started; keeping it can go stale, so it never passes as a live read.
------------------------------------------------------------

fort = setup()
WoW.SetUnit("party1", { name = "Karuzo Elegia", guid = "P1" })
rem, dur, state, _, basis = E:BuffRem("party1", fort)
H.eq(state, MISSING, "seen without the buff")
H.eq(basis, "live", "live, while it could be read")

H.secrecy(true)
rem, dur, state, _, basis = E:BuffRem("party1", fort)
H.eq(state, MISSING, "and still missing once the reads close")
H.eq(basis, "remembered", "from what was last seen, not a fresh read")
H.secrecy(false)

-- Never seen at all is still UNKNOWN: remembering absences is not guessing.
WoW.SetUnit("party2", { name = "Sten Thornbeard", guid = "P2" })
H.secrecy(true)
H.eq(select(3, E:BuffRem("party2", fort)), UNKNOWN, "a member never read is unknown")
H.eq(select(5, E:BuffRem("party2", fort)), nil, "with no basis to report")
H.secrecy(false)

-- A buff of their own clears the remembered absence.
WoW.SetAura("party1", "Power Word: Fortitude", 3600, 1800)
E:BuffRem("party1", fort)
H.secrecy(true)
rem, dur, state, _, basis = E:BuffRem("party1", fort)
H.eq(state, HAS, "buffed since: the absence is gone")
H.eq(basis, "remembered", "counting down from what was seen")

-- ...and once that runs out mid-fight, it is arithmetic, not a read.
WoW.time = WoW.time + 1900
rem, dur, state, _, basis = E:BuffRem("party1", fort)
H.eq(state, MISSING, "a cached buff that ran out during the fight")
H.eq(basis, "expired", "reported as expired rather than merely remembered")
H.secrecy(false)

-- Remembered absences age out with everything else.
E:PruneCache()
H.check(E.cache["P1"] ~= nil, "a fresh entry survives pruning")
WoW.time = WoW.time + 7200
E:PruneCache()
H.check(E.cache["P1"] == nil, "a stale one does not")

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
H.eq(st.byUnit.party1.basis, nil, "and no basis is claimed for them")
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

------------------------------------------------------------
-- Where each spell name came from, and saying so
--
-- A name that never resolved is the host's English literal. On a client
-- speaking another language it matches no aura at all, so every member reads
-- as unbuffed - a whole addon that looks broken in exactly the way a raid
-- with no buffs looks. That is priestly#21, reported from a localized client
-- and never diagnosed, because nothing said which names were being matched.
------------------------------------------------------------

setup()
local report = E:SpellReport()
H.eq(report.locale, "enUS", "the report carries the client's language")
H.eq(report.unresolved, 0, "and nothing is unresolved when the client answers")

local fort
for _, entry in ipairs(report) do if entry.id == "fort" then fort = entry end end
H.check(fort ~= nil, "every tracked buff is in the report")
H.eq(fort.forms[1].role, "single", "the single form first")
H.eq(fort.forms[1].from, "resolved", "resolved from the client")
H.eq(fort.forms[1].name, H.NAME.FORT_SINGLE, "with the name it answered")
H.check(fort.forms[1].known, "and whether the player knows it")
H.eq(fort.forms[2].role, "group", "then the group form")

-- A spell the player has not learned is ordinary, and must not look like a
-- failure: the client still answers for it by ID.
-- Teach only the single form: TeachSpells adds to what the client knows, so
-- the group one has to be forgotten explicitly.
setup()
WoW.knownSpells[H.SPELL.FORT_GROUP] = nil
E:RefreshSpells()
report = E:SpellReport()
for _, entry in ipairs(report) do
    for _, form in ipairs(entry.forms) do
        if form.id == H.SPELL.FORT_GROUP then
            H.eq(form.from, "resolved", "an unlearned spell still resolves by ID")
            H.check(not form.known, "and is reported as not known")
        end
    end
end
H.eq(report.unresolved, 0, "so nothing counts as unresolved")

-- The failure itself: the client answers for nothing. The names stay as the
-- host wrote them, and the report says that is what they are.
------------------------------------------------------------
-- The report carries a rank the client described in words we cannot read
--
-- Rank decides which reagent a group spell burns, so an unreadable one is not
-- a curiosity - it is the difference between counting the right item and
-- counting a different one. The report is where a player's "this looks wrong"
-- turns into a line saying why (#64).
------------------------------------------------------------

setup()
lib.API.rankUnreadable["Prayer of Fortitude"] = nil
E:RefreshSpells()
H.eq(E:SpellReport().ranks, nil, "a report says nothing about ranks when all of them read")

lib.API.rankUnreadable["Prayer of Fortitude"] = "Rang zwei"
local ranked = E:SpellReport()
H.check(ranked.ranks and #ranked.ranks == 1, "an unreadable rank reaches the report")
H.eq(ranked.ranks[1].name, "Prayer of Fortitude", "naming the spell")
H.eq(ranked.ranks[1].subtext, "Rang zwei",
    "and quoting what the client said, rather than what we guessed from it")
lib.API.rankUnreadable["Prayer of Fortitude"] = nil

setup()
local realName = lib.API.SpellName
lib.API.SpellName = function() return nil end
local bare = H.PriestEngine()
bare.engine:RefreshSpells()
report = bare.engine:SpellReport()
H.check(report.unresolved > 0, "names that never resolved are counted")
for _, entry in ipairs(report) do
    for _, form in ipairs(entry.forms) do
        H.eq(form.from, "fallback", "and each is reported as the host's own literal")
    end
end

-- Once a name HAS resolved, a later refresh that fails keeps it and says so:
-- the name is a real one from the client, not an English guess.
lib.API.SpellName = realName
local recovered = H.PriestEngine()
recovered.engine:RefreshSpells()
lib.API.SpellName = function() return nil end
recovered.engine:RefreshSpells()
report = recovered.engine:SpellReport()
H.eq(report.unresolved, 0, "a remembered name is not a fallback")
H.eq(report[1].forms[1].from, "remembered", "it is reported as remembered")
H.eq(report[1].forms[1].name, H.NAME.FORT_SINGLE, "and it is the client's own name")
lib.API.SpellName = realName

-- Per FORM. The single spell resolving while the group one does not is the
-- ordinary case at low level, and a status kept per buff could not say it.
setup()
local realName2 = lib.API.SpellName
lib.API.SpellName = function(id)
    if id == H.SPELL.FORT_SINGLE then return H.NAME.FORT_SINGLE end
    return nil
end
local split = H.PriestEngine()
split.engine:RefreshSpells()
report = split.engine:SpellReport()
H.eq(report[1].forms[1].from, "resolved", "the form the client answered for is resolved")
H.eq(report[1].forms[2].from, "fallback", "while the one it did not is still the host's literal")
H.check(report.unresolved > 0, "and the count notices the half that failed")
lib.API.SpellName = realName2

-- Localized: the name follows the client, and nothing is left in English.
setup()
WoW.spells[H.SPELL.FORT_SINGLE] = { name = "Machtwort: Seelenstaerke", iconID = 1 }
WoW.locale = "deDE"
E:RefreshSpells()
report = E:SpellReport()
H.eq(report.locale, "deDE", "the report says which language")
H.eq(report[1].forms[1].name, "Machtwort: Seelenstaerke", "and the name the client gave")
H.eq(report[1].forms[1].from, "resolved", "resolved, not fallen back to")

H.done("test_engine_buffs")
