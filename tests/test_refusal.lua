------------------------------------------------------------
-- test_refusal.lua - refusal memory (r39, #97).
--
-- Camp Benefits can't be listed in coveredBy: its parts and values depend on
-- the camp and the level, and the client exposes neither. The client does say
-- when it refused a cast. Measured out of combat (#97, runs #646 and #518):
-- SENT("player", name, castGUID, spellID), then FAILED("player", castGUID,
-- spellID), then UI_ERROR_MESSAGE(57, SPELL_FAILED_AURA_BOUNCED). A member
-- the player's single-form cast of a rank bounced on, whoever started it, is
-- skipped by PreClick's single-form pick of that rank for 30 seconds.
--
--   & 'C:\Program Files (x86)\Lua\5.1\lua.exe' tests\test_refusal.lua
------------------------------------------------------------

dofile("tests/wow_stubs.lua")
local H = dofile("tests/harness.lua")
local lib = H.loadLibrary()
local S = lib.Engine.STATES

local BOUNCED = "A more powerful spell is already active"
-- A FrameXML global string, which the stub doesn't define.
rawset(_G, "SPELL_FAILED_AURA_BOUNCED", BOUNCED)
local RANK3 = 1245          -- the rank SENT named in run #518

local host, E, fort

local function setup()
    WoW.reset()
    H.TeachSpells({ "FORT_SINGLE", "FORT_GROUP" })
    -- Ranks 1 and 3 known: a cast by name sends the highest (measured, #97).
    WoW.Know(RANK3, "Power Word: Fortitude")
    host = H.PriestEngine()
    E = host.engine
    E:RefreshSpells()
    H.Party3()
    WoW.now = 1000
    fort = host.def("fort")
    return fort
end

local function members()
    return {
        { unit = "player", name = "Karuzo Elegia" },
        { unit = "party1", name = "Sten Thornbeard" },
        { unit = "party2", name = "Mirel Dawnsong" },
    }
end

local NAMES = { player = "Karuzo Elegia", party1 = "Sten Thornbeard", party2 = "Mirel Dawnsong" }
local cast = 0

-- The client's answer to a cast at `unit`, as measured: `how` is "bounce"
-- (the default), "land", "range" (FAILED with no SENT, error 402) or a UI
-- error message for another failure.
local function answer(unit, how, opts)
    opts = opts or {}
    cast = cast + 1
    local guid = "Cast-" .. cast
    local spell = opts.spell or RANK3
    local ev = function(...) return E:RefusalEvent(...) end
    local changed = false
    local function note(c) changed = changed or c end
    if how == "range" then
        note(ev("UNIT_SPELLCAST_FAILED", "player", guid, spell))
        note(ev("UI_ERROR_MESSAGE", 402, "Out of range."))
        return changed
    end
    note(ev("UNIT_SPELLCAST_SENT", "player", opts.target or NAMES[unit], guid, spell))
    if how == "land" then
        note(ev("UNIT_SPELLCAST_SUCCEEDED", "player", guid, spell))
        return changed
    end
    if how == "quiet" then
        note(ev("UNIT_SPELLCAST_FAILED_QUIET", "player", guid, spell))
        return changed
    end
    note(ev("UNIT_SPELLCAST_FAILED", "player", opts.failedGUID or guid, spell))
    note(ev("UI_ERROR_MESSAGE", 57, (how == nil or how == "bounce") and BOUNCED or how))
    return changed
end

local function refusedOn(unit) return E:RefusalOf(unit, fort) ~= nil end

------------------------------------------------------------
-- A refused cast is learned, and PreClick's pick skips that member
------------------------------------------------------------

setup()
local ms = members()
H.eq(E.refusals, nil, "no state until an event: an engine an older copy built works unchanged")
H.eq(E:PickTarget(ms, fort, false), "player", "the first missing member is picked")
H.check(answer("player"), "a bounce on a member is learned, and says so")
local rec = E:RefusalOf("player", fort)
H.check(rec, "RefusalOf has the record")
H.eq(rec.spellID, RANK3, "with the rank SENT named")
H.eq(rec.reason, "stronger-effect", "a stable reason")
H.eq(rec.retryAt, 1030, "and a deadline 30 seconds on")
H.eq(E:PickTarget(ms, fort, false, nil, true), "party1", "PreClick's single-form pick skips them")
H.eq(E:PickTarget(ms, fort, false), "player",
    "the aim wired between clicks does not: a click in combat uses it, and combat forgets refusals")

local st = E:GroupStat(ms, fort)
H.eq(st.byUnit.player.refused, rec, "GroupStat carries the record")
H.eq(st.byUnit.player.state, S.MISSING, "the state stays what the auras say")
H.eq(st.nMiss, 3, "every count stays: they still lack the buff")
H.eq(st.nRefused, 1, "counted apart")
H.check(not st.allHave, "the row is not complete")
H.eq(E:PickTarget(ms, fort, false, st, true), "party1", "PickTarget with st skips them too")

-- Everyone else buffed: the fallbacks don't land on them either.
WoW.SetAura("party1", "Power Word: Fortitude", 3600, 3000)
WoW.SetAura("party2", "Power Word: Fortitude", 3600, 1000)
H.eq(E:PickTarget(ms, fort, false, nil, true), "party2", "the shortest of the others, not the refused member")

-- Single form only: the group form and the raid-wide pick are unchanged.
H.eq(E:PickTarget(ms, fort, true, nil, true), "player", "a group-form pick still aims at them")
H.eq(E:PickRaidTarget(ms, fort), "player", "and so does the raid-wide pick")

-- Whoever started the cast: SENT names who got it, so the record is true
-- for a cast from an action bar or a macro as much as for the window's.
setup()
H.check(answer("party1"), "a bounce on another member is learned for that member")
H.check(refusedOn("party1") and not refusedOn("player"), "and only for them")

------------------------------------------------------------
-- The deadline, and what clears a record early
------------------------------------------------------------

setup()
answer("player")
WoW.now = 1029.9
H.check(refusedOn("player"), "held until the deadline")
WoW.now = 1030
H.check(not refusedOn("player"), "and gone at it")
H.eq(E:PickTarget(members(), fort, false, nil, true), "player", "the member is picked again")

-- A refresh never extends it: a second bounce keeps the deadline.
setup()
answer("player")
WoW.now = 1020
H.check(not answer("player"), "a second bounce changes nothing")
H.eq(E:RefusalOf("player", fort).retryAt, 1030, "the first deadline stands")

-- A top-up is refused too: a member who has the buff and whose refresh
-- bounced keeps the record (run #520, where clearing it on the buff sent
-- every click straight back to them).
setup()
WoW.SetAura("party1", "Power Word: Fortitude", 3600, 1760)
WoW.SetAura("party2", "Power Word: Fortitude", 3600, 3000)
WoW.SetAura("player", "Power Word: Fortitude", 3600, 3500)
H.eq(E:PickTarget(members(), fort, false, nil, true), "party1", "everyone buffed: the shortest is topped up")
answer("party1")
local st2 = E:GroupStat(members(), fort)
H.check(st2.byUnit.party1.refused, "seen with the buff, the refused top-up stays on record")
H.eq(st2.byUnit.party1.state, S.HAS, "while their state says they have it")
H.eq(E:PickTarget(members(), fort, false, st2, true), "party2", "the next top-up goes to the next shortest")
H.eq(E:PickTarget(members(), fort, false, nil, true), "party2", "with or without GroupStat's states")

setup()
answer("player")
E:AuraEventIsRelevant("player", { addedAuras = { { name = "Mark of the Wild" } } })
H.check(refusedOn("player"), "an aura gained keeps it")
E:AuraEventIsRelevant("party1", { removedAuraInstanceIDs = { 7 } })
H.check(refusedOn("player"), "another member's loss keeps it")
E:AuraEventIsRelevant("player", { removedAuraInstanceIDs = {} })
H.check(refusedOn("player"), "an empty removal list is no change")
E:AuraEventIsRelevant("player", { removedAuraInstanceIDs = { 7 } })
H.check(not refusedOn("player"), "an aura lost on them clears it: the blocker may be what went")
answer("player")
E:AuraEventIsRelevant("player", { updatedAuraInstanceIDs = { 9 } })
H.check(not refusedOn("player"), "so does an aura changed in place")
answer("player")
E:AuraEventIsRelevant("player", { isFullUpdate = true })
H.check(not refusedOn("player"), "so does a full update")
answer("player")
E:AuraEventIsRelevant("player", nil)
H.check(not refusedOn("player"), "and an event with no details")

for _, ev in ipairs({ "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "PLAYER_ENTERING_WORLD" }) do
    setup()
    answer("player")
    H.check(E:RefusalEvent(ev), ev .. " clears every refusal, and says so")
    H.check(not refusedOn("player"), "gone after " .. ev)
    H.check(not E:RefusalEvent(ev), "with nothing left, it says nothing changed")
end

setup()
answer("player")
E:RefreshSpells()
H.check(refusedOn("player"), "a spell refresh with the same rank keeps it")
WoW.Know(2791, "Power Word: Fortitude")
E:RefreshSpells()
H.check(not refusedOn("player"), "a new rank ends it: the record is of the rank it was learned from")
H.check(answer("player", nil, { spell = 2791 }), "the new rank's own bounce is learned")
H.eq(E:RefusalOf("player", fort).spellID, 2791, "as that rank")

-- A lower rank cast from the spellbook bounces: it says nothing about the
-- rank the window casts, so it is not kept, and it never overwrites a live
-- record of that rank (Codex, 6045a9a).
setup()
WoW.Know(1244, "Power Word: Fortitude")
H.check(not answer("player", nil, { spell = 1244 }), "a lower rank's bounce is not learned")
H.check(not refusedOn("player"), "nothing held back")
answer("player")
WoW.now = 1010
H.check(not answer("player", nil, { spell = 1244 }), "a lower rank's bounce on a refused member changes nothing")
H.eq(E:RefusalOf("player", fort) and E:RefusalOf("player", fort).retryAt, 1030,
    "the window rank's record keeps its deadline")

-- A rank that can't be resolved applies no record.
setup()
answer("player")
H.check(refusedOn("player"), "learned")
WoW.knownSpells[RANK3] = nil
WoW.knownSpells[H.SPELL.FORT_SINGLE] = nil
H.check(not refusedOn("player"), "with no rank to compare, the record applies to nothing")

setup()
answer("player")
WoW.now = 1031
E:PruneCache()
H.eq(E.refusals.byKey.P0, nil, "PruneCache drops a record past its deadline")

-- A member who leaves loses theirs, so rejoining within the 30 s starts afresh.
setup()
answer("party1")
H.check(refusedOn("party1"), "learned on party1")
local p1 = WoW.units.party1
WoW.RemoveUnit("party1")
E:PruneCache()
WoW.units.party1 = p1
H.check(not refusedOn("party1"), "gone after they left and a roster prune ran")

------------------------------------------------------------
-- What is never learned
------------------------------------------------------------

local function notLearned(label, fn, unit)
    setup()
    fn()
    H.check(not refusedOn(unit or "player"), label)
end

notLearned("a cast answered in combat", function()
    WoW.combat = true; answer("player"); WoW.combat = false
end)
notLearned("a cast sent in combat and answered after", function()
    WoW.combat = true
    E:RefusalEvent("UNIT_SPELLCAST_SENT", "player", NAMES.player, "Cast-c", RANK3)
    WoW.combat = false
    E:RefusalEvent("UNIT_SPELLCAST_FAILED", "player", "Cast-c", RANK3)
    E:RefusalEvent("UI_ERROR_MESSAGE", 57, BOUNCED)
end)
notLearned("SENT naming nobody in the group", function() answer("player", nil, { target = "Odo Farwalker" }) end)
notLearned("a secret target name", function() answer("player", nil, { target = WoW.Secret("SENT target") }) end)
notLearned("a name two members share", function()
    WoW.SetUnit("party2", { name = "Karuzo Elegia", guid = "P2", class = "MAGE" })
    answer("player")
end)
notLearned("SENT for another spell", function() answer("player", nil, { spell = 585 }) end)
notLearned("the group form bouncing", function() answer("player", nil, { spell = H.SPELL.FORT_GROUP }) end)
notLearned("a member whose GUID can't be read", function()
    WoW.units.player.guid = nil
    answer("player")
    WoW.units.player.guid = "P0"
end)
-- The pet is looked at before party1: a GUID-less match first must still
-- make the name ambiguous, not be skipped.
notLearned("a name a member shares whose GUID can't be read", function()
    WoW.SetUnit("pet", { name = NAMES.party1, guid = "Pet-0", class = "WARRIOR" })
    WoW.units.pet.guid = nil
    answer("party1")
end, "party1")
notLearned("a secret castGUID on FAILED", function()
    E:RefusalEvent("UNIT_SPELLCAST_SENT", "player", NAMES.player, "Cast-s", RANK3)
    E:RefusalEvent("UNIT_SPELLCAST_FAILED", "player", WoW.Secret("castGUID"), RANK3)
    E:RefusalEvent("UI_ERROR_MESSAGE", 57, BOUNCED)
end)
notLearned("a secret unit token on SENT", function()
    E:RefusalEvent("UNIT_SPELLCAST_SENT", WoW.Secret("unit"), NAMES.player, "Cast-u", RANK3)
    E:RefusalEvent("UNIT_SPELLCAST_FAILED", "player", "Cast-u", RANK3)
    E:RefusalEvent("UI_ERROR_MESSAGE", 57, BOUNCED)
end)
notLearned("another unit's cast", function()
    E:RefusalEvent("UNIT_SPELLCAST_SENT", "party1", NAMES.player, "Cast-p", RANK3)
    E:RefusalEvent("UNIT_SPELLCAST_FAILED", "party1", "Cast-p", RANK3)
    E:RefusalEvent("UI_ERROR_MESSAGE", 57, BOUNCED)
end)
notLearned("FAILED for another cast", function() answer("player", nil, { failedGUID = "Cast-0" }) end)
notLearned("a quiet failure", function() answer("player", "quiet") end)
notLearned("another failure's message on error 57", function() answer("player", "Interrupted") end)
notLearned("out of range: FAILED with no SENT, then error 402", function() answer("player", "range") end)
notLearned("a cast that landed", function() answer("player", "land") end)
notLearned("FAILED more than a second after SENT", function()
    E:RefusalEvent("UNIT_SPELLCAST_SENT", "player", NAMES.player, "Cast-l", RANK3)
    WoW.now = WoW.now + 1.5
    E:RefusalEvent("UNIT_SPELLCAST_FAILED", "player", "Cast-l", RANK3)
    E:RefusalEvent("UI_ERROR_MESSAGE", 57, BOUNCED)
end)
notLearned("the error more than a second after FAILED", function()
    E:RefusalEvent("UNIT_SPELLCAST_SENT", "player", NAMES.player, "Cast-e", RANK3)
    E:RefusalEvent("UNIT_SPELLCAST_FAILED", "player", "Cast-e", RANK3)
    WoW.now = WoW.now + 1.5
    E:RefusalEvent("UI_ERROR_MESSAGE", 57, BOUNCED)
end)
notLearned("the error before FAILED", function()
    E:RefusalEvent("UNIT_SPELLCAST_SENT", "player", NAMES.player, "Cast-x", RANK3)
    E:RefusalEvent("UI_ERROR_MESSAGE", 57, BOUNCED)
    E:RefusalEvent("UNIT_SPELLCAST_FAILED", "player", "Cast-x", RANK3)
end)
notLearned("FAILED for a different rank than SENT", function()
    E:RefusalEvent("UNIT_SPELLCAST_SENT", "player", NAMES.player, "Cast-k", RANK3)
    E:RefusalEvent("UNIT_SPELLCAST_FAILED", "player", "Cast-k", 1244)
    E:RefusalEvent("UI_ERROR_MESSAGE", 57, BOUNCED)
end)

-- Two failed casts waiting for one error: it can't say whose, so neither.
setup()
E:RefusalEvent("UNIT_SPELLCAST_SENT", "player", NAMES.player, "Cast-a", RANK3)
E:RefusalEvent("UNIT_SPELLCAST_SENT", "player", NAMES.party1, "Cast-b", RANK3)
E:RefusalEvent("UNIT_SPELLCAST_FAILED", "player", "Cast-a", RANK3)
E:RefusalEvent("UNIT_SPELLCAST_FAILED", "player", "Cast-b", RANK3)
E:RefusalEvent("UI_ERROR_MESSAGE", 57, BOUNCED)
H.check(not refusedOn("player") and not refusedOn("party1"), "one error for two failed casts teaches nothing")

-- Two casts in flight, one fails: the error is that one's.
setup()
E:RefusalEvent("UNIT_SPELLCAST_SENT", "player", NAMES.player, "Cast-a", RANK3)
E:RefusalEvent("UNIT_SPELLCAST_SENT", "player", NAMES.party1, "Cast-b", RANK3)
E:RefusalEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-a", RANK3)
E:RefusalEvent("UNIT_SPELLCAST_FAILED", "player", "Cast-b", RANK3)
E:RefusalEvent("UI_ERROR_MESSAGE", 57, BOUNCED)
H.check(refusedOn("party1") and not refusedOn("player"), "the one failed cast gets the error")

-- A slot whose occupant changed: the record follows who SENT named.
setup()
WoW.SetUnit("party1", { name = "Orla Vane", guid = "P9", class = "PALADIN" })
answer("party1", nil, { target = "Orla Vane" })
H.check(refusedOn("party1"), "the new occupant's bounce is theirs")
H.eq(E.refusals.byKey.P1, nil, "and nothing went to the one who left the slot")

-- In a raid "player" and its raidN are one member: their name resolves.
setup()
WoW.inRaid = true
WoW.SetUnit("raid1", { name = "Karuzo Elegia", guid = "P0", class = "PRIEST" })
WoW.SetUnit("raid2", { name = "Sten Thornbeard", guid = "P1", class = "WARRIOR" })
WoW.groupMembers = 2
answer("player")
H.check(refusedOn("player"), "a raid alias of the player resolves to the one GUID")
WoW.SetUnit("raidpet2", { name = "Sten Thornbeard", guid = "Pet-2", class = "WARRIOR" })
answer("raid2", nil, { target = "Sten Thornbeard" })
H.check(not refusedOn("raid2"), "a pet sharing a member's name makes it ambiguous")
WoW.inRaid = false

-- A name that doesn't pin the cast to one roster member (Codex, 6045a9a):
-- a pet, whose name isn't unique, or a target, mouseover or focus outside
-- the group with the member's name.
notLearned("a roster pet named in SENT", function()
    WoW.SetUnit("partypet1", { name = "Wolf", guid = "Pet-1", class = "HUNTER" })
    answer("partypet1", nil, { target = "Wolf" })
end, "partypet1")
for _, token in ipairs({ "target", "mouseover", "focus" }) do
    notLearned("the " .. token .. " outside the group sharing the member's name", function()
        WoW.SetUnit(token, { name = NAMES.party1, guid = "Outsider-1", class = "WARRIOR" })
        answer("party1")
    end, "party1")
end
setup()
WoW.SetUnit("target", { name = NAMES.party1, guid = "P1", class = "WARRIOR" })
answer("party1")
H.check(refusedOn("party1"), "the member themselves as the target is fine")

-- A cast that lands clears an earlier refusal of the same member.
setup()
answer("player")
H.check(answer("player", "land"), "a cast that lands clears the refusal, and says so")
H.check(not refusedOn("player"), "gone")

-- Overlapping casts each wait for their own FAILED by castGUID.
setup()
E:RefusalEvent("UNIT_SPELLCAST_SENT", "player", NAMES.player, "Cast-o1", RANK3)
E:RefusalEvent("UNIT_SPELLCAST_SENT", "player", NAMES.party1, "Cast-o2", RANK3)
E:RefusalEvent("UNIT_SPELLCAST_FAILED", "player", "Cast-o1", RANK3)
E:RefusalEvent("UI_ERROR_MESSAGE", 57, BOUNCED)
E:RefusalEvent("UNIT_SPELLCAST_FAILED", "player", "Cast-o2", RANK3)
E:RefusalEvent("UI_ERROR_MESSAGE", 57, BOUNCED)
H.check(refusedOn("player") and refusedOn("party1"), "each bounce is its own cast's")

------------------------------------------------------------
-- The window: the host forwards, PreClick re-aims, the wired aim stays
------------------------------------------------------------

WoW.reset()
H.TeachSpells({ "FORT_SINGLE" })
WoW.Know(RANK3, "Power Word: Fortitude")
local uhost = H.PriestUI()
local ui = uhost.ui
uhost.config.visible.spirit = false
uhost.config.visible.shadow = false
uhost.engine:RefreshSpells()
E, fort = uhost.engine, uhost.def("fort")
H.Party3()
WoW.now = 2000
ui:Update()

local evs = ui:RefusalEvents()
H.eq(#evs, #lib.Engine.REFUSAL_EVENTS, "RefusalEvents lists the events to forward")
local has = {}
for _, ev in ipairs(evs) do has[ev] = true end
H.check(has.UNIT_SPELLCAST_SENT and has.UNIT_SPELLCAST_FAILED and has.UI_ERROR_MESSAGE
    and has.PLAYER_REGEN_DISABLED, "the cast, its failure, the error and combat entry among them")
evs[1] = "NOT_AN_EVENT"
H.eq(ui:RefusalEvents()[1], lib.Engine.REFUSAL_EVENTS[1], "a copy: the host can't change the list")

local row = H.ActiveRows(ui)[1]
H.eq(row:GetAttribute("unit1"), "player", "the row is wired at the first member missing Fortitude")
-- Both edges, as the client runs them, then the cast sent after PostClick.
H.runScript(row, "PreClick", "LeftButton", true)
H.runScript(row, "PostClick", "LeftButton", true)
ui:RefusalEvent("UNIT_SPELLCAST_SENT", "player", NAMES.player, "Cast-w1", RANK3)
ui:RefusalEvent("UNIT_SPELLCAST_FAILED", "player", "Cast-w1", RANK3)
ui:RefusalEvent("UI_ERROR_MESSAGE", 57, BOUNCED)
H.runScript(row, "PreClick", "LeftButton", false)
H.runScript(row, "PostClick", "LeftButton", false)
H.check(E:RefusalOf("player", fort), "the forwarded events taught the engine the refusal")
WoW.flushTimers(1)
H.eq(row:GetAttribute("unit1"), "player",
    "the aim wired for a click in combat is the ordinary one: combat forgets the refusal")
WoW.now = WoW.now + 2
H.runScript(row, "PreClick", "LeftButton", true)
H.eq(row:GetAttribute("unit1"), "party1", "the next click's PreClick skips the refused member")
H.runScript(row, "PostClick", "LeftButton", true)
WoW.now = WoW.now + 2

-- The popover names the refusal, and its manual click stays armed.
H.runScript(row, "OnEnter")
local pr = ui.popRows[1]
H.eq(pr._unit, "player", "the popover's first row is the refused member")
H.check(pr._refused, "it knows the refusal")
H.eq(pr:GetAttribute("spell1"), "Power Word: Fortitude", "its click is still armed")
H.eq(pr.timeTxt:GetText(), "MISS", "and it still reads MISS: the auras say so")
WoW.clearTooltip()
H.runScript(pr, "OnEnter")
local tip = WoW.tooltipText()
H.check(tostring(tip):find("was refused on them", 1, true), "the tooltip says it was refused: " .. tostring(tip))
H.check(tostring(tip):find("skip them for up to 30 seconds", 1, true), "and for how long, with no frozen countdown")
H.runScript(pr, "OnLeave")

-- A popover click on another member: its bounce is learned the same way.
local pr2 = ui.popRows[2]
H.eq(pr2._unit, "party1", "the second popover row")
H.runScript(pr2, "PreClick", "LeftButton", true)
ui:RefusalEvent("UNIT_SPELLCAST_SENT", "player", NAMES.party1, "Cast-w2", RANK3)
ui:RefusalEvent("UNIT_SPELLCAST_FAILED", "player", "Cast-w2", RANK3)
ui:RefusalEvent("UI_ERROR_MESSAGE", 57, BOUNCED)
H.check(E:RefusalOf("party1", fort), "a popover click's refusal is learned")
H.runScript(row, "OnLeave")
WoW.now = WoW.now + 2
H.runScript(row, "PreClick", "LeftButton", true)
H.eq(row:GetAttribute("unit1"), "party2", "the row's next click goes to the one member left")

-- Everyone refused: PreClick casts nothing, but the aim wired for combat
-- stays armed (Codex, 9223733).
ui:RefusalEvent("UNIT_SPELLCAST_SENT", "player", NAMES.party2, "Cast-w3", RANK3)
ui:RefusalEvent("UNIT_SPELLCAST_FAILED", "player", "Cast-w3", RANK3)
ui:RefusalEvent("UI_ERROR_MESSAGE", 57, BOUNCED)
H.runScript(row, "PostClick", "LeftButton", true)
WoW.flushTimers(1)
H.check(E:RefusalOf("party2", fort), "the last member refused too")
WoW.now = WoW.now + 2
H.runScript(row, "PreClick", "LeftButton", true)
H.eq(row:GetAttribute("spell1"), nil, "with everyone refused, the click out of combat casts nothing")
H.runScript(row, "PostClick", "LeftButton", true)
H.eq(row:GetAttribute("spell1"), "Power Word: Fortitude", "but the wired aim is re-armed")
WoW.combat = true
ui:RefusalEvent("PLAYER_REGEN_DISABLED")
H.check(not E:RefusalOf("player", fort) and not E:RefusalOf("party1", fort), "combat entry forgets them all")
H.eq(row:GetAttribute("spell1"), "Power Word: Fortitude", "and the row stays armed in combat")
H.check(row:GetAttribute("unit1") ~= nil, "at a member")
WoW.combat = false

------------------------------------------------------------
-- An upgrade: an engine and a window r36 built, then this copy loads
------------------------------------------------------------

-- The released r36, never synthesised: it must lack what this copy adds.
local function readFile(path)
    local f = assert(io.open(path, "rb"))
    local src = f:read("*a")
    f:close()
    return src
end
WoW.reset()
LibStub = nil
assert(loadfile("LibStub/LibStub.lua"))(H.HOST, {})
H.loadLibGlass()
assert(loadstring(readFile("tests/fixtures/LibGroupBuffs-r36.lua"), "=r36"))(H.HOST, {})
local _, oldMinor = LibStub:GetLibrary("LibGroupBuffs-1.0")
H.eq(oldMinor, 36, "the r36 fixture is active")
H.TeachSpells({ "FORT_SINGLE" })
WoW.Know(RANK3, "Power Word: Fortitude")
local ohost = H.PriestUI()
ohost.config.visible.spirit = false
ohost.config.visible.shadow = false
ohost.engine:RefreshSpells()
H.Party3()
WoW.now = 3000
ohost.ui:Update()
local orow = H.ActiveRows(ohost.ui)[1]
H.check(orow and orow._ui == ohost.ui, "r36 built the window and its row")
H.loadLibrary(".", { noGlass = true })
local _, newMinor = LibStub:GetLibrary("LibGroupBuffs-1.0")
H.check(newMinor > 36, "this copy is active now: r" .. tostring(newMinor))
local oE, ofort = ohost.engine, ohost.def("fort")
H.eq(oE.refusals, nil, "the old engine has no refusal state")
H.check(type(ohost.ui.RefusalEvents) == "function", "the old window has the new entry points")
H.eq(oE:RefusalOf("player", ofort), nil, "and RefusalOf answers nil")
H.runScript(orow, "PreClick", "LeftButton")
ohost.ui:RefusalEvent("UNIT_SPELLCAST_SENT", "player", NAMES.player, "Cast-u1", RANK3)
ohost.ui:RefusalEvent("UNIT_SPELLCAST_FAILED", "player", "Cast-u1", RANK3)
ohost.ui:RefusalEvent("UI_ERROR_MESSAGE", 57, BOUNCED)
H.check(oE:RefusalOf("player", ofort), "a row r36 built, through its old PreClick closure, teaches the engine")
H.runScript(orow, "PostClick", "LeftButton")
WoW.now = WoW.now + 2
H.runScript(orow, "PreClick", "LeftButton")
H.eq(orow:GetAttribute("unit1"), "party1", "and its next click skips the refused member")
H.eq(oE:GroupStat(members(), ofort).nRefused, 1, "GroupStat counts it on the old engine")

H.eq(#WoW.messages, 0, "nothing to chat")
H.done("test_refusal")
