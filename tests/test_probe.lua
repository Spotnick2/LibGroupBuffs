------------------------------------------------------------
-- test_probe.lua - Tools/LibGroupBuffsProbe under the stub.
--
-- The probe runs on the owner's client, where a typo costs a game session,
-- and the r33 audit's procedures (a battleground, a combat sweep, a cold
-- relaunch) cost more than one. So every command and every procedure step's
-- code runs here first, with the real ForeverProbe host from its checkout
-- (private, so CI skips this file: FOREVERPROBE_OPTIONAL=1), against stubbed
-- units. The stub lacks several APIs the probe samples - UnitIsVisible,
-- UnitInRange, C_PvP, most of C_Secrets - which is the point: an absent API
-- must log as MISSING, never error.
--
--   & 'C:\Program Files (x86)\Lua\5.1\lua.exe' tests\test_probe.lua
------------------------------------------------------------

dofile("tests/wow_stubs.lua")
local H = dofile("tests/harness.lua")
WoW.allowGlobal("ForeverProbe", "ForeverProbeDB", "LibGroupBuffsProbeDB")
local FP = H.loadForeverProbe()
local lib = H.loadLibrary()

local NS = {}
assert(loadfile("Tools/LibGroupBuffsProbe/LibGroupBuffsProbe.lua"))("LibGroupBuffsProbe", NS)
WoW.dispatch("ADDON_LOADED", "LibGroupBuffsProbe")
local T = NS._test
H.check(T and T.Probe, "the probe exposes its test seam")
H.check(type(LibGroupBuffsProbeDB) == "table" and type(LibGroupBuffsProbeDB.log) == "table",
    "its saved log is bound at ADDON_LOADED")
H.eq(#WoW.messages, 0, "and nothing went to chat")

local log = LibGroupBuffsProbeDB.log
local function logHas(needle)
    for _, line in ipairs(log) do
        if tostring(line):find(needle, 1, true) then return true end
    end
    return false
end
local function clearLog() for i = #log, 1, -1 do log[i] = nil end end

------------------------------------------------------------
-- The procedures are well-formed
------------------------------------------------------------

local procs = {}
for key, proc in pairs(FP.procedures or {}) do
    if tostring(key):find("LibGroupBuffsProbe", 1, true) then procs[tostring(key):match("/(.*)$") or key] = proc end
end
for _, name in ipairs({ "bg", "sweep", "spells", "look" }) do
    local proc = procs[name]
    H.check(proc ~= nil, "procedure '" .. name .. "' is registered")
    if proc then
        H.eq(type(proc.steps), "table", name .. " has steps")
        for i, step in ipairs(proc.steps or {}) do
            local kinds = 0
            for _, k in ipairs({ "run", "event", "wait", "ask", "reload" }) do
                if step[k] ~= nil then kinds = kinds + 1 end
            end
            H.check(kinds <= 1, name .. " step " .. i .. " has at most one of run/event/wait/ask/reload")
            H.eq(type(step.text), "string", name .. " step " .. i .. " has text")
            if step.wait then H.eq(type(step.timeout), "number", name .. " step " .. i .. " waits with a timeout") end
        end
        local last = proc.steps[#proc.steps]
        H.check(last and last.reload ~= nil, name .. " ends with a reload, so the results reach the disk")
    end
end

-- Run every `run`, `wait` and `check` a procedure carries, out of combat, and
-- fail on a throw. The sweep's own step runs in combat below.
local function drive(name, opts)
    opts = opts or {}
    local proc = procs[name]
    if not proc then return end
    for i, step in ipairs(proc.steps) do
        if not (opts.skip and opts.skip[i]) then
            if step.run then
                local ok, err = pcall(step.run)
                H.check(ok, name .. " step " .. i .. " run: " .. tostring(err))
            end
            if step.wait then
                local ok, err = pcall(step.wait)
                H.check(ok, name .. " step " .. i .. " wait: " .. tostring(err))
            end
            if step.check then
                local ok, pass, detail = pcall(step.check)
                H.check(ok, name .. " step " .. i .. " check: " .. tostring(pass))
                H.check(detail == nil or type(detail) == "string", name .. " step " .. i .. " check detail is text")
            end
        end
    end
end

------------------------------------------------------------
-- sample: a party, a raid, in combat, with APIs the stub lacks
------------------------------------------------------------

WoW.reset()
H.TeachSpells({ "FORT_SINGLE", "FORT_GROUP" })
H.Party3()
clearLog()
H.eq(T.sample("party"), 3, "the player and two party members are sampled")
H.check(logHas("SAMPLE party begin") and logHas("SAMPLE party end: 3 units"), "bracketed by begin and end lines")
H.check(logHas("party1: "), "one line per unit")
H.check(logHas("visible=MISSING"), "an API the stub lacks is MISSING, not an error")
H.check(logHas("isBattleground=MISSING"), "including a whole namespace")
H.check(logHas("byIndex=nil walk=1"), "an unbuffed member: slot 1 empty, the walk stops at 1")
H.check(logHas("lib.BuffRem=\"MISSING\"/\"live\""), "and the library's own read agrees")
H.check(logHas("minor=" .. tostring(lib.shared.MINOR)), "the sample names the MINOR that ran")
H.eq(#WoW.messages, 0, "nothing to chat")

WoW.SetAura("party1", "Power Word: Fortitude", 3600, 1800)
WoW.range.party1 = true
clearLog()
T.sample("buffed", "party1")
H.check(logHas("byIndex=aura walk=2"), "a buffed member: slot 1 holds an aura, slot 2 is the first empty")
H.check(logHas("byName=aura"), "and the by-name read finds it")
H.check(logHas("rangeName=true"), "range by name answers")
H.check(logHas("lib.ReadBuff=\"HAS\""), "the library reads HAS")
H.check(not logHas("Sten Thornbeard") and not logHas("Karuzo"), "no player name is logged")

-- A raid of 40.
WoW.reset()
H.TeachSpells({ "FORT_SINGLE" })
WoW.inRaid = true
WoW.groupMembers = 40
for i = 1, 40 do
    WoW.raidRoster[i] = { name = "Raider" .. i, subgroup = math.ceil(i / 5) }
    WoW.SetUnit("raid" .. i, { name = "Raider" .. i, guid = "R" .. i, class = "WARRIOR" })
end
clearLog()
H.eq(T.sample("raid"), 41, "the player and forty raiders")
H.check(logHas("raid40: "), "down to the last slot")
H.check(not logHas("Raider7"), "and no raider's name")

-- In combat, reads throw: the sample says so and the library answers UNKNOWN
-- for a GUID it never read (the raid sample above cached an absence for the
-- old occupant of the slot).
WoW.SetUnit("raid3", { name = "Newcomer", guid = "R3b", class = "MAGE" })
H.secrecy(true)
clearLog()
T.sample("combat", "raid3")
H.check(logHas("combat=true"), "the sample records combat")
H.check(logHas("aurasSecret=true"), "and the secrecy flag")
H.check(logHas("byIndex=THREW walk=-1"), "the index read threw at slot 1")
H.check(logHas("byName=nil"), "while the by-name read quietly returned nil, as measured")
H.check(logHas("lib.ReadBuff=\"BLOCKED\""), "the library sees BLOCKED")
H.check(logHas("lib.BuffRem=\"UNKNOWN\"/nil"), "and reports UNKNOWN with no basis")
H.secrecy(false)

-- Secrecy out of combat: the flag alone, as a PvP instance might hold it.
WoW.secret = true
clearLog()
T.sample("flag", "raid4")
H.check(logHas("combat=false") and logHas("aurasSecret=true"), "flag up, no combat")
H.check(logHas("byIndex=nil walk=1"), "the index read answers nil")
H.check(logHas("lib.ReadBuff=\"BLOCKED\""), "which the library refuses to call an absence while the flag is up")
WoW.secret = false

-- The step that screenshots the window must have it on screen as it
-- completes: Open alone schedules through a timer (Codex, round 1).
WoW.reset()
H.TeachSpells({ "FORT_SINGLE" })
H.Party3()
do
    local w = T.window()
    if w then w:Close(true) WoW.flushTimers(1) end
    local shown, visible = T.openNow()
    H.check(shown, "openNow puts the frame on screen before any timer runs")
    H.check(visible, "and the window is logically open")
    H.check(T.window().main:IsShown(), "so a screenshot taken as the step completes shows it")
end

-- The bg procedure's own steps.
WoW.reset()
H.TeachSpells({ "FORT_SINGLE" })
H.Party3()
clearLog()
drive("bg")
H.check(logHas("SAMPLE outside begin") and logHas("SAMPLE after leaving end"), "every sampling step ran")
H.eq(#WoW.messages, 0, "nothing to chat")

------------------------------------------------------------
-- sweep: every entry runs, out of combat and in it
------------------------------------------------------------

WoW.reset()
H.TeachSpells({ "FORT_SINGLE" })
H.Party3()
local ui = T.window()
WoW.allowMethod("IsClampedToScreen")         -- in the dump; the stub never needed it before
ui:Open()
WoW.flushTimers(1)
ui:Update()
H.check(ui.main and ui.main:IsShown(), "the probe's window is up")
clearLog()
local remembered = T.rememberWindow()
H.eq(type(remembered), "string", "the window's state before the sweep is text: " .. tostring(remembered))
local p0 = { ui.main:GetPoint() }
H.check(not ui.main:IsMouseEnabled(), "Init never enables the mouse on the main frame")
WoW.inCombat = true
WoW.blockedCalls = {}
local result = T.sweep()
H.eq(type(result), "string", "the sweep returns a summary")
H.check(logHas("SWEEP main:Hide() begin") and logHas("SWEEP main:Hide() end"), "each entry is bracketed in the log")
local function verdict(label) return result:match(label:gsub("%p", "%%%0") .. "=([^;]+)") end
H.eq(verdict("main:Hide()"), "unchanged", "a refused hide leaves the frame shown")
H.eq(verdict("main:ClearAllPoints()+SetPoint(same)"), "unchanged", "and a refused re-anchor leaves the anchor")
H.eq(verdict("main:SetShown(false)"), "changed",
    "a method nobody measured is not refused by the stub: the sweep in game decides")
H.eq(verdict("main:SetFrameStrata(MEDIUM)"), "changed", "same for the strata")
H.eq(verdict("plain:Hide()"), "changed", "and the plain frame is free")
H.eq(verdict("plain:SetAlpha(0.5)"), "changed", "in every respect")
H.check(#WoW.blockedCalls > 0, "the stub refused the measured calls")
for _, line in ipairs(log) do
    H.check(not tostring(line):find("threw:", 1, true), "no sweep entry threw: " .. tostring(line))
end
H.check(T.sweepIsDirty(), "after a sweep the window counts as dirty")
H.check(T.restoreWindow():find("in combat", 1, true) ~= nil, "it cannot be restored while the fight is on")
H.check(T.sweepIsDirty(), "and stays dirty")
WoW.inCombat = false
H.check(WoW.events[T.sweepWatch] and WoW.events[T.sweepWatch].PLAYER_REGEN_ENABLED,
    "the probe listens for the fight's end on its own")
H.runScript(T.sweepWatch, "OnEvent", "PLAYER_REGEN_ENABLED")
H.check(not T.sweepIsDirty(), "and restores the window there, whatever became of the procedure")
H.check(logHas("sweep outstanding at combat's end: restored"), "saying so")
H.check(T.restoreWindow():find("restored", 1, true) ~= nil, "restoring again on demand is harmless")
-- The anchor restore has to be seen to do something: the stub refuses the
-- sweep's re-anchor, so break the anchor by hand before restoring again.
ui.main:ClearAllPoints()
ui.main:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -3, 3)
H.eq((ui.main:GetPoint()), "BOTTOMRIGHT", "the anchor is broken")
H.check(T.restoreWindow():find("restored", 1, true) ~= nil, "and restored again")
WoW.flushTimers(1)
H.eq(ui.main:GetFrameStrata(), "LOW", "to its strata")
H.check(not ui.main:IsMouseEnabled(), "to its mouse state, which the sweep's EnableMouse(true) had changed")
do
    local p1 = { ui.main:GetPoint() }
    H.eq(p1[1], p0[1], "and to its anchor point")
    H.eq(tostring(p1[4]) .. "," .. tostring(p1[5]), tostring(p0[4]) .. "," .. tostring(p0[5]), "at the same offset")
end
H.eq(ui.main:GetAlpha(), 1, "and its alpha (the window's alpha lives on its glass, not the frame)")
drive("sweep", { skip = { [3] = true } })   -- step 3 is the sweep itself, run in combat above
H.eq(#WoW.messages, 0, "nothing to chat")

------------------------------------------------------------
-- The moments that only a wait step gets right
--
-- Inside the PLAYER_REGEN_DISABLED handler InCombatLockdown() is still false
-- on this client, and ForeverProbe completes an event step there and runs
-- the next auto step at once; a procedure resumed at PLAYER_LOGIN runs its
-- next auto step before PLAYER_ENTERING_WORLD; a screenshot fires as a step
-- completes, after the click that completed it moved the cursor off the
-- row. So the sweep, the combat sample, the relaunch check and the popover
-- shots are wait steps whose condition is the thing itself.
------------------------------------------------------------

local function stepWhere(name, needle)
    for _, step in ipairs(procs[name].steps) do
        if step.text:find(needle, 1, true) then return step end
    end
end
WoW.inCombat = false
local pull = stepWhere("sweep", "Pull one mob")
H.check(pull and pull.wait and not pull.event, "the sweep waits for lockdown instead of the combat event")
H.check(not pull.wait(), "and does not complete while lockdown is off, as it is inside PLAYER_REGEN_DISABLED")
WoW.inCombat = true
H.check(pull.wait(), "only once lockdown is on")
WoW.inCombat = false
local gates = stepWhere("bg", "Gates open")
H.check(gates and gates.wait and not gates.event, "the battleground's combat sample waits the same way")
H.check(not gates.wait(), "off")
WoW.inCombat = true
H.check(gates.wait(), "on")
WoW.inCombat = false

-- The popover shots complete only while the popover is up.
ui:Close(true)
WoW.flushTimers(1)
T.openNow()
local hover = stepWhere("bg", "Hover a row of the probe window so its popover shows")
H.check(hover and hover.wait and hover.screenshot, "the first popover shot is a wait with a screenshot")
H.check(not hover.wait(), "which does not complete while nothing is hovered")
H.runScript(H.ActiveRows(ui)[1], "OnEnter")
H.check(ui.pop:IsShown(), "hovering a row shows the probe's popover")
H.check(hover.wait(), "and then the step completes, with the popover on screen for the shot")
local hover2 = stepWhere("bg", "Hover a row of the probe window again")
H.check(hover2 and hover2.wait and hover2.screenshot, "the far-member shot is the same kind of step")

-- The synthetic host carries out deferred work at combat's end on its own.
WoW.inCombat = true
H.eq(ui:Close(true), false, "a close in combat is deferred")
H.check(ui.main:IsShown(), "the frame stays up")
WoW.inCombat = false
H.runScript(T.sweepWatch, "OnEvent", "PLAYER_REGEN_ENABLED")
H.check(not ui.main:IsShown(), "and the probe host lands it at combat's end, sweep or no sweep")

------------------------------------------------------------
-- spells: snapshots, and the procedure's steps
------------------------------------------------------------

WoW.reset()
local missing = T.snapshot("test")
H.eq(missing, #T.SPELL_IDS, "a client that knows none of the IDs: every one is missing")
for _, s in ipairs(T.SPELL_IDS) do WoW.DefineSpell(s[1], "Spell " .. s[1]) end
H.eq(T.snapshot("test2"), 0, "defined on the client: none missing")
H.check(logHas("SPELLS test missing=" .. #T.SPELL_IDS), "a snapshot logs its phase and count")
H.check(logHas("SPELLS test2 missing=0"), "each time")
H.check(T.summary():find("test=" .. #T.SPELL_IDS, 1, true) ~= nil, "the summary lists this run's phases")
local relaunch = stepWhere("spells", "Waiting for the relaunch")
H.check(relaunch and relaunch.wait and not relaunch.run, "the relaunch check is a wait, not an auto step")
H.check(not relaunch.wait(), "which does not complete before the entering-world snapshots exist")
-- Through the probe's own frame: dispatching to every frame would also build
-- ForeverProbe's console, which needs widget methods the stub does not model.
H.check(WoW.events[T.spellWatch] and WoW.events[T.spellWatch].PLAYER_LOGIN, "the probe listens for PLAYER_LOGIN")
H.check(WoW.events[T.spellWatch].SPELL_DATA_LOAD_RESULT, "and for SPELL_DATA_LOAD_RESULT")
H.runScript(T.spellWatch, "OnEvent", "PLAYER_LOGIN")
H.runScript(T.spellWatch, "OnEvent", "PLAYER_ENTERING_WORLD", true, false)
H.runScript(T.spellWatch, "OnEvent", "SPELL_DATA_LOAD_RESULT", 1243, true)
H.runScript(T.spellWatch, "OnEvent", "SPELL_DATA_LOAD_RESULT", 99999, true)
WoW.flushTimers(6)
H.check(logHas("SPELL_DATA_LOAD_RESULT 1243 true"), "a load result for one of the IDs is logged")
H.check(not logHas("SPELL_DATA_LOAD_RESULT 99999"), "and one for any other spell is not")
H.check(logHas("SPELLS PLAYER_LOGIN "), "a login is snapshotted")
H.check(logHas("SPELLS PLAYER_ENTERING_WORLD+5s "), "and again five seconds after entering the world")
H.check(relaunch.wait(), "after which the relaunch check completes")
H.check(select(1, relaunch.check()), "and passes when every id resolved at both phases")
drive("spells")
H.eq(#WoW.messages, 0, "nothing to chat")

H.done("test_probe")
