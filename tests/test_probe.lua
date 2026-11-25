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
for _, name in ipairs({ "bg", "sweep", "spells", "look", "camp", "refusal", "memory" }) do
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
-- SetShown(false) is a hide, and WowTestKit refuses it as one (the pre-kit
-- stub let it through as unmeasured); the sweep in game decides it.
H.eq(verdict("main:SetShown(false)"), "unchanged",
    "SetShown(false) is refused by the stub as the hide it is: the sweep in game decides")
-- Measured on 70959 (#82): the strata is refused, the alpha is not.
H.eq(verdict("main:SetFrameStrata(MEDIUM)"), "unchanged", "a refused strata change leaves the strata")
H.eq(verdict("main:SetAlpha(0.5)"), "changed", "while the alpha, allowed, changes")
H.eq(verdict("plain:Hide()"), "changed", "and the plain frame is free")
H.eq(verdict("plain:SetAlpha(0.5)"), "changed", "in every respect")
H.check(#WoW.blockedCalls > 0, "the stub refused the measured calls")
for _, line in ipairs(log) do
    H.check(not tostring(line):find("threw:", 1, true), "no sweep entry threw: " .. tostring(line))
end
H.check(T.sweepIsDirty(), "after a sweep the window counts as dirty")
-- Back to the sweep step and run it again in the same fight: the snapshot
-- must still be the window before the FIRST sweep.
-- The alpha is what the sweep can change (the client refuses its level,
-- size and strata writes on this frame), so it is what tells a stale snapshot
-- from the first one.
local level0, width0, alpha0 = 0, 0, 1
do
    local snap = T.remembered()
    level0, width0, alpha0 = snap.level, snap.width, snap.alpha
end
H.check(ui.main:GetAlpha() ~= alpha0, "the first sweep changed the alpha")
T.sweep()
H.eq(T.remembered().alpha, alpha0, "a repeated sweep keeps the first snapshot's alpha")
H.eq(T.remembered().level, level0, "and its level")
H.eq(T.remembered().width, width0, "and its width")
H.check(T.restoreWindow():find("in combat", 1, true) ~= nil, "it cannot be restored while the fight is on")
H.check(T.sweepIsDirty(), "and stays dirty")
WoW.inCombat = false
H.check(WoW.events[T.sweepWatch] and WoW.events[T.sweepWatch].PLAYER_REGEN_ENABLED,
    "the probe listens for the fight's end on its own")
H.runScript(T.sweepWatch, "OnEvent", "PLAYER_REGEN_ENABLED")
H.check(not T.sweepIsDirty(), "and restores the window there, whatever became of the procedure")
H.check(logHas("sweep outstanding at combat's end: restored"), "saying so")
H.check(T.restoreWindow():find("restored", 1, true) ~= nil, "restoring again on demand is harmless")
H.eq(ui.main:GetAlpha(), alpha0, "to the alpha it had before the first of two sweeps")
-- The rest of the restore has to be seen to do something: the stub refuses
-- the sweep's re-anchor, strata, level and mouse writes (measured on 70959,
-- #82), so break them by hand, out of combat, before restoring again.
ui.main:ClearAllPoints()
ui.main:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -3, 3)
ui.main:SetFrameStrata("HIGH")
ui.main:SetFrameLevel(level0 + 5)
ui.main:EnableMouse(true)
H.eq((ui.main:GetPoint()), "BOTTOMRIGHT", "the anchor is broken")
H.check(ui.main:GetFrameStrata() == "HIGH" and ui.main:GetFrameLevel() == level0 + 5
    and ui.main:IsMouseEnabled(), "and so are the strata, the level and the mouse")
H.check(T.restoreWindow():find("restored", 1, true) ~= nil, "and restored again")
WoW.flushTimers(1)
H.eq(ui.main:GetFrameStrata(), "LOW", "to its strata")
H.eq(ui.main:GetFrameLevel(), level0, "to the level it had before the first of two sweeps")
H.check(not ui.main:IsMouseEnabled(), "to its mouse state")
do
    local p1 = { ui.main:GetPoint() }
    H.eq(p1[1], p0[1], "and to its anchor point")
    H.eq(tostring(p1[4]) .. "," .. tostring(p1[5]), tostring(p0[4]) .. "," .. tostring(p0[5]), "at the same offset")
end
H.eq(ui.main:GetAlpha(), 1, "and its alpha (the window's alpha lives on its glass, not the frame)")
drive("sweep", { skip = { [3] = true } })   -- step 3 is the sweep itself, run in combat above
H.eq(#WoW.messages, 0, "nothing to chat")

-- A close the player made mid-fight survives the restore (Codex review of
-- #76): the X after a sweep, then the fight's end.
ui:Open()
WoW.flushTimers(1)
ui:Update()
H.check(ui:IsVisible() and ui.main:IsShown(), "the window is open again")
WoW.inCombat = true
T.sweep()
H.eq(ui:Close(true), false, "the player closes it mid-fight: deferred")
WoW.inCombat = false
H.runScript(T.sweepWatch, "OnEvent", "PLAYER_REGEN_ENABLED")
WoW.flushTimers(1)
H.check(not T.sweepIsDirty(), "the sweep is restored")
H.check(not ui:IsVisible(), "the window stays closed")
H.check(not ui.main:IsShown(), "and off screen: the restore does not reopen it")
local restoreStep = procs.sweep.steps[5]
H.check(select(1, restoreStep.check()), "and the procedure's restore check accepts a closed window")

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

------------------------------------------------------------
-- camp and refusal (#95, #97): the cast watch and fresh waits
------------------------------------------------------------

WoW.reset()
H.TeachSpells({ "FORT_SINGLE", "FORT_GROUP" })
H.Party3()
clearLog()
drive("camp")
drive("refusal")
H.check(logHas("AURAS camp begin"), "the camp procedure samples the auras")
H.check(logHas("GetGameMessageInfo(57)="), "the refusal procedure looks up error 57's name")
H.eq(#WoW.messages, 0, "nothing to chat")

-- A second run of a procedure, with no /reload between, waits for new casts
-- (Codex review of fd7386a): the baseline goes when the step is left.
T.watching(true)
local castStep = stepWhere("camp", "on YOURSELF")
H.check(castStep and castStep.wait and castStep.leave, "a cast step is a wait that can be left")
castStep.leave("done")      -- drive() above polled it; the panel leaves a step before entering it again
local function succeed() H.runScript(T.castWatch, "OnEvent", "UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-1", 1245) end
H.check(not castStep.wait(), "it does not complete before a cast")
succeed()
H.check(castStep.wait(), "a cast completes it")
castStep.leave("done")
H.check(not castStep.wait(), "run again, the first run's cast does not complete it")
succeed()
H.check(castStep.wait(), "a new cast does")
castStep.leave("stopped")
-- Only a Fortitude result completes a step: walking out of range or fighting
-- raises UI errors of their own, and other spells get cast (Codex review of
-- f9db8fd).
local errStep = stepWhere("refusal", "Ordinary failure")
H.check(errStep and errStep.wait and errStep.leave, "the refusal steps wait the same way")
errStep.leave("done")
H.check(not errStep.wait(), "not before a result")
H.runScript(T.castWatch, "OnEvent", "UI_ERROR_MESSAGE", 50, "You are moving")
H.runScript(T.castWatch, "OnEvent", "UI_ERROR_MESSAGE", 57, "A more powerful spell is already active")
H.check(not errStep.wait(), "a UI error alone does not complete it")
H.runScript(T.castWatch, "OnEvent", "UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-9", 585)
H.check(not errStep.wait(), "nor does another spell's cast")
H.check(logHas("spell=585 (not Fortitude)"), "which is logged as not Fortitude")
H.runScript(T.castWatch, "OnEvent", "UNIT_SPELLCAST_FAILED", "player", "Cast-10", 2791)
H.check(errStep.wait(), "a Fortitude rank's failure does")
errStep.leave("done")
H.check(not errStep.wait(), "and a second run waits for a new one")
H.check(logHas("UI_ERROR_MESSAGE type=57"), "the error is still logged with its type")
H.check(logHas("UNIT_SPELLCAST_SUCCEEDED castGUID="), "a cast by its castGUID's shape, not its value")
H.runScript(T.castWatch, "OnEvent", "UNIT_SPELLCAST_SENT", "player", "Sten Thornbeard", "Cast-2", 1245)
H.check(logHas("resolves to party1"), "SENT's target resolves to the member's unit token")
H.check(not logHas("Sten Thornbeard"), "and the name itself is never logged")

-- Buffy's rows are followed too (run #646 was on a mage, where the probe
-- window has none): a click logs the aim, and SENT is matched against it.
local brow = CreateFrame("Button", nil, UIParent, "SecureActionButtonTemplate")
brow:SetScript("PreClick", function() end)
brow:SetScript("PostClick", function() end)
brow:SetAttribute("unit1", "party1")
brow:SetAttribute("spell1", "Power Word: Fortitude")
rawset(_G, "Buffy", { ui = { rows = { brow }, popRows = {} } })
T.watching(true)
clearLog()
T.hookRows()
H.check(brow._probeHooked, "a row of Buffy's window is hooked")
local function sent(name, guid) H.runScript(T.castWatch, "OnEvent", "UNIT_SPELLCAST_SENT", "player", name, guid, 1245) end
WoW.now = 100
H.runScript(brow, "PreClick", "LeftButton", false)
H.check(logHas("PreClick buffy-row1") and logHas('unit1="party1"'), "its click logs where the library aimed it")
sent("Sten Thornbeard", "Cast-3")
H.check(logHas('aimed="party1" aimAge=0.000 match=yes'), "and SENT's target is matched against that aim")
H.runScript(brow, "PreClick", "LeftButton", false)
sent("Mirel Dawnsong", "Cast-4")
H.check(logHas("match=NO"), "a cast that went to someone else does not match")

-- A click's aim is consumed by one SENT, so an action-bar cast after it is
-- never compared with it (Codex review of f9db8fd).
clearLog()
H.runScript(brow, "PreClick", "LeftButton", false)
sent("Sten Thornbeard", "Cast-5")
sent("Sten Thornbeard", "Cast-6")
H.check(logHas("aimed=nil match=no aim"), "a second cast after one click has no aim")
-- PostClick does not bring a consumed aim back.
clearLog()
H.runScript(brow, "PreClick", "LeftButton", false)
sent("Sten Thornbeard", "Cast-7")
H.runScript(brow, "PostClick", "LeftButton", false)
sent("Sten Thornbeard", "Cast-8")
H.check(logHas("aimed=nil match=no aim"), "nor after its PostClick")
-- An aim no cast used lapses after a second, and when the step is left.
clearLog()
H.runScript(brow, "PreClick", "LeftButton", false)
WoW.now = 101.5
sent("Sten Thornbeard", "Cast-11")
H.check(logHas("aimed=nil match=no aim"), "an aim older than a second is not used")
clearLog()
H.runScript(brow, "PreClick", "LeftButton", false)
stepWhere("refusal", "Ordinary failure").leave("skipped")
sent("Sten Thornbeard", "Cast-12")
H.check(logHas("aimed=nil match=no aim"), "nor one from a step that was left")
-- A row click in combat that sends nothing: leaving the row step drops its
-- aim, so the action-bar fallback, its own step, is not matched to it, even
-- within the second (Codex review of 2ca7a8c).
local rowStep = stepWhere("refusal", "left-click Buffy's Fortitude row once")
local fallback = stepWhere("refusal", "from your action bar; else press Skip")
H.check(rowStep and rowStep.leave and fallback and fallback.wait, "the combat row click and its fallback are separate steps")
clearLog()
WoW.now = 102
H.runScript(brow, "PreClick", "LeftButton", false)
H.runScript(brow, "PostClick", "LeftButton", false)
rowStep.leave("done")
sent("Sten Thornbeard", "Cast-14")
H.check(logHas("aimed=nil match=no aim") and not logHas("match=yes"), "the fallback cast is not matched to the click that sent nothing")
-- The action-bar case: no click on a row, no aim.
clearLog()
sent("Sten Thornbeard", "Cast-13")
H.check(logHas("resolves to party1") and logHas("aimed=nil match=no aim"), "an action-bar cast resolves but has no row aim")
WoW.now = nil
rawset(_G, "Buffy", nil)
T.watching(false)
H.eq(#WoW.messages, 0, "nothing to chat")

-- memory (#97, r39): the probe window opts in like a host, and a refused
-- click on its Fortitude row is learned and logged.
rawset(_G, "SPELL_FAILED_AURA_BOUNCED", "A more powerful spell is already active")
WoW.Know(1245, "Power Word: Fortitude")   -- the rank a cast by name sends
clearLog()
drive("memory", { skip = { [8] = true, [9] = true } })
H.check(logHas("MEMORY start: refusals none"), "the memory procedure starts with nothing on record")
local feed = T.feed()
H.check(feed and WoW.events[feed] and WoW.events[feed].UNIT_SPELLCAST_SENT and WoW.events[feed].PLAYER_REGEN_DISABLED,
    "it registers the library's refusal events on its own frame")
local prow
for _, r in ipairs((T.window()).rows or {}) do
    if r._active and r._def and r._def.id == "fort" then prow = r end
end
H.check(prow, "the probe window has a Fortitude row")
-- The stub knows Prayer of Fortitude, so the left click casts the group
-- form, which is never learned from: the right click casts the single form.
local aimed = prow and prow:GetAttribute("unit2")
local learned = stepWhere("memory", "It should be refused, and learned")
H.check(learned and learned.wait and learned.check and learned.leave, "the click step waits for a learned refusal")
learned.leave("done")
H.check(not learned.wait(), "and does not complete before one")
H.runScript(prow, "PreClick", "RightButton", true)
H.check(logHas("PreClick probe-row") and logHas("unit2=") and logHas("spell2="),
    "a right click logs the slot it reads, unit2/spell2")
local who = ({ player = "Karuzo Elegia", party1 = "Sten Thornbeard", party2 = "Mirel Dawnsong" })[aimed]
H.runScript(feed, "OnEvent", "UNIT_SPELLCAST_SENT", "player", who, "Cast-m1", 1245)
H.runScript(feed, "OnEvent", "UNIT_SPELLCAST_FAILED", "player", "Cast-m1", 1245)
H.runScript(feed, "OnEvent", "UI_ERROR_MESSAGE", 57, "A more powerful spell is already active")
H.check(logHas("MEMORY after UI_ERROR_MESSAGE: refusals " .. tostring(aimed) .. "=1245/\"stronger-effect\"/30s"),
    "the learned refusal is logged: aimed at " .. tostring(aimed))
H.check(not logHas(tostring(who)), "the member's name is never logged")
H.check(learned.wait(), "the learned refusal completes the click step")
H.check(select(1, learned.check()), "and its check passes with one on record")
-- A Prayer or a landed cast doesn't complete it: only a new record does.
learned.leave("done")
H.check(not learned.wait(), "a second run waits for a new record")
learned.leave("done")
clearLog()
T.memoryState("probe test")
H.check(logHas("; fort row wired unit1=") and logHas("; next click picks left="),
    "the state reads the wired aim and what the next click's PreClick picks")
H.check(not logHas("right=" .. '"' .. tostring(aimed) .. '"'), "the next right click skips the refused member")
-- The lapse starts from a live record and tells a deadline from an early clear.
local lapseStep = stepWhere("memory", "nothing is on record any more")
H.check(lapseStep and lapseStep.wait and lapseStep.leave, "the lapse is a wait")
lapseStep.leave("done")
H.check(not lapseStep.wait(), "it waits while the record lives")
WoW.now = (WoW.now or 0) + 31
local done, detail = lapseStep.wait()
H.check(done and tostring(detail):find("at its deadline", 1, true), "and reports a lapse at the deadline: " .. tostring(detail))
lapseStep.leave("done")
local fresh, why = lapseStep.wait()
H.check(not fresh and tostring(why):find("nothing on record", 1, true), "with nothing on record it says so instead of passing")
lapseStep.leave("done")
-- The blocked press: with the members refused, a press on the row that
-- armed nothing. Nobody offline: that would be a false pass (Codex, 2581b88).
local blocked = stepWhere("memory", "a press that armed no spell")
H.check(blocked and blocked.wait, "the blocked click is a wait")
blocked.leave("done")
local okNone, whyNone = blocked.wait()
H.check(not okNone and tostring(whyNone):find("needs both of you refused", 1, true),
    "with fewer than two refused it waits, and says why: " .. tostring(whyNone))
for i, u in ipairs({ "player", "party1", "party2" }) do
    local name = ({ player = "Karuzo Elegia", party1 = "Sten Thornbeard", party2 = "Mirel Dawnsong" })[u]
    H.runScript(feed, "OnEvent", "UNIT_SPELLCAST_SENT", "player", name, "Cast-b" .. i, 1245)
    H.runScript(feed, "OnEvent", "UNIT_SPELLCAST_FAILED", "player", "Cast-b" .. i, 1245)
    H.runScript(feed, "OnEvent", "UI_ERROR_MESSAGE", 57, "A more powerful spell is already active")
end
H.check(not blocked.wait(), "everyone refused, but no press yet")
WoW.now = WoW.now + 1
H.runScript(prow, "PreClick", "RightButton", true)
H.eq(prow:GetAttribute("spell2"), nil, "the press armed nothing: everyone is refused")
local ok3, why3 = blocked.wait()
H.check(ok3, "and that completes the step: " .. tostring(why3))
blocked.leave("done")
H.runScript(feed, "OnEvent", "PLAYER_REGEN_DISABLED")
H.check(logHas("MEMORY after PLAYER_REGEN_DISABLED: refusals none"), "combat entry clears it, and that is logged")
T.watching(false)
H.eq(#WoW.messages, 0, "nothing to chat")

-- Every widget method the probe, the window it drives and ForeverProbe's
-- console called is on that type in the pinned build (tests/test_methods.lua
-- does the same for the library alone).
local recorded = Kit.checkMethods()
check(recorded >= 95, "the probe's procedures reached the window and the console (" .. recorded .. " recorded)")

H.done("test_probe")
