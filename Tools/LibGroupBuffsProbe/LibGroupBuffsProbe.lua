-- LibGroupBuffsProbe: LibGroupBuffs's developer probe, a ForeverProbe module
-- (/fp gb). Its lines go to the ForeverProbe console and
-- LibGroupBuffsProbeDB.log, never to chat. It is never packaged.
--
-- It drives the window through lib:New with a synthetic host (the three priest
-- buffs, everything else in plain fields), so the library can be checked in
-- game without Priestly, Wildly or Magely.
--   /fp gb state          which copies run, and whether the window wears the clean preset
--   /fp gb show|hide      open or close the window
--   /fp gb sample [unit]  one sample of the aura, range and roster APIs: every unit, or one
--   /fp gb resolve        how every consumer's spell IDs resolve right now
--   /fp steps gb look     the r29 look check, with screenshots
--   /fp steps gb bg       a battleground: aura reads, range and roster before the gates,
--                         in combat, after, and after leaving (#63)
--   /fp steps gb sweep    which writes to the protected window this build refuses in
--                         combat, one call at a time (Wildly #42)
--   /fp steps gb spells   spell data at login: GetSpellInfo(id) against a cold cache,
--                         for every consumer's IDs (Magely #48)
-- The embedded libraries are these checkouts (deploy.ps1). A newer copy in
-- another addon would win LibStub, so `state` and every sample log which
-- MINOR runs.
--
-- The buffs are a priest's: on another class the engine finds nothing to
-- show. The window parents secure buttons, so the library itself refuses to
-- show or hide it in combat.
--
-- Every client API a sample touches is read with rawget and called inside
-- pcall: an API this build lacks logs as MISSING, a throw as THREW, and a
-- secret value is rendered by Probe.Show without being compared. Nothing
-- here logs a name another player chose; GUIDs go through Probe.Shape.

local ADDON, NS = ...
local MAX_LOG = 3000
local OWNER = "LibGroupBuffsProbe"
local Probe = ForeverProbe:Module("LibGroupBuffsProbe", { api = 1, cmd = "gb" })
local function say(msg) Probe:Say(msg) end
local Show, Shape = Probe.Show, Probe.Shape

local DEFS = {
    { id = "fort", snglID = 1243, grpID = 21562, sngl = "Power Word: Fortitude", grp = "Prayer of Fortitude", duration = 3600 },
    { id = "spirit", snglID = 14752, grpID = 27681, sngl = "Divine Spirit", grp = "Prayer of Spirit", duration = 3600 },
    { id = "shadow", snglID = 976, grpID = 27683, sngl = "Shadow Protection", grp = "Prayer of Shadow Protection", duration = 600 },
}

local engine, ui                -- built on first use, once (one instance per owner)
local durations, pos = {}, nil

local function lib() return LibStub("LibGroupBuffs-1.0", true) end

local function build()
    if ui then return ui end
    local GB = lib():New({
        owner = OWNER,
        report = function(text, kind) say("report[" .. tostring(kind) .. "] " .. tostring(text)) end,
    })
    engine = GB.Engine({
        defs = DEFS,
        bucketSize = 8,
        showSolo = function() return true end,
        trackPets = function() return false end,
        isBuffEnabled = function() return true end,
        isVisible = function() return true end,
        learnDuration = function(spell, seconds) durations[spell] = seconds end,
        learnedDuration = function(spell) return durations[spell] end,
    })
    ui = GB.UI({
        engine = engine,
        owner = OWNER,
        title = "LibGroupBuffs probe",
        version = "dev",
        appearance = function() return nil end,
        unknownClassIcon = "Interface\\Icons\\INV_Misc_QuestionMark",
        footerItems = function() return {} end,
        alpha = function() return 0.96 end,
        scale = function() return 1 end,
        locked = function() return false end,
        popoverSide = function() return "auto" end,
        showClickHints = function() return true end,
        getPos = function() if not pos then return nil, "no saved pos" end return pos end,
        setPos = function(p) pos = p end,
        setVisible = function() end,
        onCloseDeferred = function(_, manual) say("close deferred by combat, manual=" .. tostring(manual)) end,
    })
    engine:RefreshSpells()
    return ui
end

-- A dotted global path, read with rawget: an API this build lacks is nil, not
-- an error (the test stub errors on an unknown global; the client answers nil).
local function lookup(path)
    local t = _G
    for part in path:gmatch("[^.]+") do
        if type(t) ~= "table" then return nil end
        t = rawget(t, part)
    end
    return t
end

-- Call a client API by path, inside pcall, and render its first two returns
-- as text. A secret return is rendered, never compared.
local function try(path, ...)
    local fn = lookup(path)
    if type(fn) ~= "function" then return "MISSING" end
    local r = Probe.Pack(pcall(fn, ...))
    if not r[1] then return "THREW" end
    if r.n >= 3 then return Show(r[2]) .. "/" .. Show(r[3]) end
    return Show(r[2])
end

-- ─── state / show / hide / clear ────────────────────────────────────────────

local function panelSize()
    local panel = ui and ui.main and ui.main.glass
    return panel and panel.size
end

local function state()
    local L = lib()
    if not L then say("LibGroupBuffs-1.0 is not loaded"); return end
    local _, gm = LibStub:GetLibrary("LibGlass-1.0", true)
    say("LibGroupBuffs MINOR " .. Show(L.shared and L.shared.MINOR) .. ", ready " .. Show(L.ready)
        .. "; LibGlass MINOR " .. Show(gm))
    local why = L:Refusal()
    say("refusal: " .. (why and why.code or "none"))
    local g = L.glass
    if not g then say("no LibGlass instance yet (built with the first window): /fp gb show"); return end
    local st = g.STYLE
    say("material: grain " .. Show(st.grain) .. ", gloss " .. Show(st.gloss)
        .. ", thinRim " .. Show(st.thinRim) .. ", shadowAlpha " .. Show(st.shadowAlpha)
        .. " (clean: 0 / 0.25 / true / 0.3)")
    say("panel size key " .. Show(panelSize()) .. " (clean: thin)")
end

Probe:Command("state", state, "which copies run; is the window clean")

Probe:Command("show", function()
    local ok, err = pcall(build)
    if not ok then say("build refused: " .. tostring(err)); return end
    ui:Open()
    say("open requested; visible " .. Show(ui:IsVisible()))
end, "build the synthetic window and open it")

Probe:Command("hide", function()
    if ui then say("close returned " .. Show(ui:Close(true))) else say("nothing built yet") end
end, "close the window")

Probe:Command("clear", function() Probe:ClearLog(); say("log cleared") end, "empty the saved log")

-- ─── sample: the aura, range and roster APIs, unit by unit (#63) ────────────
--
-- One sample is one moment: the instance and group context, then one line
-- per unit with what the client answers for it. The battleground procedure
-- takes one outside, one on entering, one before the gates, one in combat,
-- one after, one with a far-away teammate and one after leaving.

local rosterEvents, rosterEventsInCombat = 0, 0
local watch = CreateFrame("Frame")
Probe:RegisterEvents(watch, { "GROUP_ROSTER_UPDATE" })
watch:SetScript("OnEvent", function(_, event)
    if event == "GROUP_ROSTER_UPDATE" then
        rosterEvents = rosterEvents + 1
        if InCombatLockdown() then rosterEventsInCombat = rosterEventsInCombat + 1 end
    end
end)

-- Slot 1 of the helpful auras as "aura", "nil" or "THREW", and how far an
-- index walk gets: the first empty slot (1 = none at all, 41 = full), or
-- minus the slot that threw. Every touch of the struct is inside the pcall:
-- on this client a secret value throws when it is compared.
local function auraIndexRead(unit)
    local byIndex = lookup("C_UnitAuras.GetAuraDataByIndex")
    if type(byIndex) ~= "function" then return "MISSING", 0 end
    local first, walk = "nil", 41
    for i = 1, 40 do
        local ok, kind = pcall(function()
            local a = byIndex(unit, i, "HELPFUL")
            if a == nil then return "nil" end
            return "aura"
        end)
        if i == 1 then first = ok and kind or "THREW" end
        if not ok then walk = -i break end
        if kind == "nil" then walk = i break end
    end
    return first, walk
end

local function auraNameRead(unit, name)
    local byName = lookup("C_UnitAuras.GetAuraDataBySpellName")
    if type(byName) ~= "function" then return "MISSING" end
    local ok, kind = pcall(function()
        local a = byName(unit, name, "HELPFUL")
        if a == nil then return "nil" end
        return "aura"
    end)
    return ok and kind or "THREW"
end

local function unitSample(unit)
    if not UnitExists(unit) then say("  " .. unit .. ": absent"); return end
    local def = DEFS[1]
    local parts = {
        "class=" .. try("UnitClass", unit),
        "guid=" .. Shape((select(2, pcall(UnitGUID, unit)))),
        "visible=" .. try("UnitIsVisible", unit),
        "connected=" .. try("UnitIsConnected", unit),
        "inRange=" .. try("UnitInRange", unit),
        "phase=" .. try("UnitPhaseReason", unit),
        "inBG=" .. try("UnitInBattleground", unit),
        "identitySecret=" .. try("C_Secrets.ShouldUnitIdentityBeSecret", unit),
        "auraSlot1Secret=" .. try("C_Secrets.ShouldUnitAuraIndexBeSecret", unit, 1, "HELPFUL"),
    }
    local first, walk = auraIndexRead(unit)
    parts[#parts + 1] = "byIndex=" .. first .. " walk=" .. walk
    parts[#parts + 1] = "byName=" .. auraNameRead(unit, def.sngl)
    parts[#parts + 1] = "rangeName=" .. try("C_Spell.IsSpellInRange", def.sngl, unit)
    parts[#parts + 1] = "rangeID=" .. try("C_Spell.IsSpellInRange", def.snglID, unit)
    parts[#parts + 1] = "rangeGrp=" .. try("C_Spell.IsSpellInRange", def.grp, unit)
    if engine and def.names then
        local L = lib()
        local okR, st = pcall(L.API.ReadBuff, unit, def.names)
        parts[#parts + 1] = "lib.ReadBuff=" .. (okR and Show(st) or "THREW")
        local okS, sr = pcall(L.API.SpellRange, unit, def.sngl)
        parts[#parts + 1] = "lib.SpellRange=" .. (okS and Show(sr) or "THREW")
        local okB, _, _, st2, _, basis = pcall(engine.BuffRem, engine, unit, def)
        parts[#parts + 1] = "lib.BuffRem=" .. (okB and (Show(st2) .. "/" .. Show(basis)) or "THREW")
    end
    say("  " .. unit .. ": " .. table.concat(parts, " "))
end

local function sample(label, only)
    local okB, err = pcall(build)
    if not okB then say("build refused: " .. tostring(err)) end
    say("SAMPLE " .. tostring(label) .. " begin")
    local L = lib()
    say("  minor=" .. Show(L and L.shared and L.shared.MINOR) .. " locale=" .. try("GetLocale")
        .. " combat=" .. try("InCombatLockdown")
        .. " aurasSecret=" .. try("C_Secrets.ShouldAurasBeSecret")
        .. " restrictions=" .. try("C_Secrets.HasSecretRestrictions"))
    local okI, name, itype, _, _, _, _, _, instID = pcall(GetInstanceInfo)
    say("  instance=" .. (okI and (Show(name) .. "/" .. Show(itype) .. "/id " .. Show(instID)) or "THREW")
        .. " isInInstance=" .. try("IsInInstance")
        .. " isBattleground=" .. try("C_PvP.IsBattleground")
        .. " matchState=" .. try("C_PvP.GetActiveMatchState")
        .. " playerInBG=" .. try("UnitInBattleground", "player"))
    local INSTANCE = lookup("LE_PARTY_CATEGORY_INSTANCE")
    say("  isInRaid=" .. try("IsInRaid") .. "/" .. (INSTANCE ~= nil and try("IsInRaid", INSTANCE) or "no LE_PARTY_CATEGORY_INSTANCE")
        .. " members=" .. try("GetNumGroupMembers") .. "/" .. (INSTANCE ~= nil and try("GetNumGroupMembers", INSTANCE) or "-")
        .. " rosterEvents=" .. rosterEvents .. " (" .. rosterEventsInCombat .. " in combat) since the last sample")
    rosterEvents, rosterEventsInCombat = 0, 0
    local units = {}
    if only and only ~= "" then
        units[1] = only
    else
        units[1] = "player"
        if UnitExists("target") then units[#units + 1] = "target" end
        local n = GetNumGroupMembers()
        if IsInRaid() then
            for i = 1, math.min(n, 40) do units[#units + 1] = "raid" .. i end
        else
            for i = 1, math.min(n - 1, 4) do units[#units + 1] = "party" .. i end
        end
    end
    for _, u in ipairs(units) do unitSample(u) end
    say("SAMPLE " .. tostring(label) .. " end: " .. #units .. " units")
    return #units
end

Probe:Command("sample", function(args)
    local only = args and args:match("^%s*(%S+)")
    sample("command", only)
end, "one sample of the aura, range and roster APIs: every unit, or the one named")

Probe:Steps("bg", {
    rev = 1,
    title = "Battleground: aura reads, range and roster (#63)",
    { text = "Outdoors, out of combat, on your priest, not queued. Press Sample.", button = "Sample",
      run = function() return sample("outside") end },
    { text = "Queue for any battleground and enter it.", event = "PLAYER_ENTERING_WORLD" },
    { text = "Sampling right after entering.", auto = true, run = function() return sample("entered") end },
    { text = "Waiting for the raid to fill (5 or more).", timeout = 180,
      wait = function() local n = GetNumGroupMembers(); return n >= 5, "members " .. tostring(n) end },
    { text = "Sampling before the gates open.", auto = true, run = function() return sample("before gates") end,
      check = function() return not InCombatLockdown(), "out of combat" end },
    { text = "Open the probe window.", button = "Open", screenshot = "probe window, before gates",
      run = function()
          local ok, err = pcall(build)
          if not ok then error(err, 0) end
          ui:Open()
          return ui:IsVisible()
      end },
    { text = "Open Priestly's window (/priestly show) and hover a row so its popover shows. Then press Next.",
      screenshot = "Priestly popover, before gates" },
    { text = "In the popover: is the RANGE mark (left of the time) '?' for every member?", ask = true },
    { text = "And is the TIME column '?' for every member, with the row grey and '?'?", ask = true },
    { text = "Gates open: fight until you are in combat.", event = "PLAYER_REGEN_DISABLED" },
    { text = "Sampling in combat.", auto = true, run = function() return sample("in combat") end },
    { text = "Leave combat (wait it out).", event = "PLAYER_REGEN_ENABLED" },
    { text = "Sampling after combat, still inside.", auto = true, run = function() return sample("after combat") end },
    { text = "Out of combat, with a teammate far across the map: press Sample, and type their raid index in the Note.",
      button = "Sample", screenshot = "popover, far member", run = function() return sample("far member") end },
    { text = "Hover Priestly's popover again: does any member show '?' in the RANGE mark now?", ask = true },
    { text = "Leave the battleground.", event = "PLAYER_ENTERING_WORLD" },
    { text = "Sampling after leaving.", auto = true, run = function() return sample("after leaving") end },
    { text = "Type /reload to save the results.", reload = true },
})

-- ─── sweep: which writes the client refuses on the protected window ─────────
--
-- Measured on 69913: hide, move, re-anchor, unclamp and stop-drag are refused
-- on a frame that parents secure buttons (Priestly FOREVER-PROBE §13). Alpha,
-- scale, size, strata, level, SetShown, EnableMouse and the regions were not.
-- Each entry is tried once in combat between a begin and an end line, so the
-- host's ADDON_ACTION_BLOCKED log (same console) attributes a refusal to the
-- call; "unchanged" alone is not proof, since a write can be a no-op.

local sweepSaved

local function get(obj, method, default)
    local fn = obj and obj[method]
    if type(fn) ~= "function" then return default end
    local ok, v = pcall(fn, obj)
    if ok then return v end
    return default
end

local SWEEP = {
    -- { label, act(main), read(main) }
    { "main:SetAlpha(0.5)", function(m) m:SetAlpha(0.5) end, function(m) return m:GetAlpha() end },
    { "main:SetScale(1.05)", function(m) m:SetScale(1.05) end, function(m) return m:GetScale() end },
    { "main:SetWidth(+2)", function(m) m:SetWidth(m:GetWidth() + 2) end, function(m) return m:GetWidth() end },
    { "main:SetHeight(+2)", function(m) m:SetHeight(m:GetHeight() + 2) end, function(m) return m:GetHeight() end },
    { "main:SetSize(+1,+1)", function(m) m:SetSize(m:GetWidth() + 1, m:GetHeight() + 1) end,
      function(m) return m:GetWidth() end },
    { "main:SetFrameStrata(MEDIUM)", function(m) m:SetFrameStrata("MEDIUM") end, function(m) return m:GetFrameStrata() end },
    { "main:SetFrameLevel(+1)", function(m) m:SetFrameLevel(m:GetFrameLevel() + 1) end, function(m) return m:GetFrameLevel() end },
    { "main:SetShown(false)", function(m) m:SetShown(false) end, function(m) return m:IsShown() end },
    { "main:SetShown(true)", function(m) m:SetShown(true) end, function(m) return m:IsShown() end },
    { "main:EnableMouse(false)", function(m) m:EnableMouse(false) end, function(m) return m:IsMouseEnabled() end },
    { "main:EnableMouse(true)", function(m) m:EnableMouse(true) end, function(m) return m:IsMouseEnabled() end },
    { "main:Hide()", function(m) m:Hide() end, function(m) return m:IsShown() end },
    { "main:Show()", function(m) m:Show() end, function(m) return m:IsShown() end },
    { "main:ClearAllPoints()+SetPoint(same)", function(m)
          local p, rel, rp, x, y = m:GetPoint(1)
          m:ClearAllPoints()
          m:SetPoint(p, rel, rp, x, y)
      end, function(m)
          local p, _, _, x, y = m:GetPoint(1)
          return tostring(p) .. "," .. tostring(x) .. "," .. tostring(y)
      end },
    { "main:SetClampedToScreen(false)", function(m) m:SetClampedToScreen(false) end,
      function(m) return m:IsClampedToScreen() end },
    { "main:SetClampedToScreen(true)", function(m) m:SetClampedToScreen(true) end,
      function(m) return m:IsClampedToScreen() end },
    -- Regions of the protected frame.
    { "main.glass.wash:SetShown(false)", function(m) m.glass.wash:SetShown(false) end,
      function(m) return m.glass.wash:IsShown() end },
    { "main.glass.wash:SetShown(true)", function(m) m.glass.wash:SetShown(true) end,
      function(m) return m.glass.wash:IsShown() end },
    { "LibGlass.SetWash(main.glass, 0.2)", function(m) lib().glass.SetWash(m.glass, 0.2) end,
      function(m) return m.glass.wash.glassPeak end },
    { "row1.timer:Hide()", function() ui.rows[1].timer:Hide() end, function() return ui.rows[1].timer:IsShown() end },
    { "row1.timer:Show()", function() ui.rows[1].timer:Show() end, function() return ui.rows[1].timer:IsShown() end },
    -- The secure button itself.
    { "row1:SetAttribute(spell1, same)", function()
          local r = ui.rows[1]
          r:SetAttribute("spell1", r:GetAttribute("spell1"))
      end, function() return ui.rows[1]:GetAttribute("spell1") end },
    { "row1:SetWidth(+1)", function() local r = ui.rows[1]; r:SetWidth(r:GetWidth() + 1) end,
      function() return ui.rows[1]:GetWidth() end },
    { "pop:Hide()", function() ui.pop:Hide() end, function() return ui.pop:IsShown() end },
}

-- The same calls on a plain frame: the control, expected free.
local PLAIN = {
    { "plain:SetAlpha(0.5)", function(f) f:SetAlpha(0.5) end, function(f) return f:GetAlpha() end },
    { "plain:SetFrameStrata(HIGH)", function(f) f:SetFrameStrata("HIGH") end, function(f) return f:GetFrameStrata() end },
    { "plain:Hide()", function(f) f:Hide() end, function(f) return f:IsShown() end },
    { "plain:Show()", function(f) f:Show() end, function(f) return f:IsShown() end },
    { "plain:SetShown(false)", function(f) f:SetShown(false) end, function(f) return f:IsShown() end },
    { "plain:SetShown(true)", function(f) f:SetShown(true) end, function(f) return f:IsShown() end },
    { "plain:SetPoint(CENTER,1,1)", function(f) f:ClearAllPoints(); f:SetPoint("CENTER", 1, 1) end,
      function(f) local _, _, _, x = f:GetPoint(1); return x end },
}

local function sweepOne(entry, target)
    local label, act, read = entry[1], entry[2], entry[3]
    local okB, before = pcall(read, target)
    say("SWEEP " .. label .. " begin")
    local okA, err = pcall(act, target)
    local okR, after = pcall(read, target)
    local verdict
    if not okA then
        verdict = "threw: " .. tostring(err)
    elseif not okB or not okR then
        verdict = "unreadable"
    elseif Show(before) == Show(after) then
        verdict = "unchanged"
    else
        verdict = "changed"
    end
    say("SWEEP " .. label .. " end " .. (okB and Show(before) or "?") .. " -> " .. (okR and Show(after) or "?")
        .. " [" .. verdict .. "]")
    return verdict
end

local function rememberWindow()
    local m = ui.main
    sweepSaved = {
        alpha = get(m, "GetAlpha", 1), scale = get(m, "GetScale", 1),
        width = get(m, "GetWidth", 0), height = get(m, "GetHeight", 0),
        strata = get(m, "GetFrameStrata", "LOW"), level = get(m, "GetFrameLevel", 1),
        clamped = get(m, "IsClampedToScreen", true),
    }
    return "alpha " .. Show(sweepSaved.alpha) .. " scale " .. Show(sweepSaved.scale)
        .. " size " .. Show(sweepSaved.width) .. "x" .. Show(sweepSaved.height)
        .. " strata " .. Show(sweepSaved.strata) .. " level " .. Show(sweepSaved.level)
        .. " shown " .. Show(get(m, "IsShown", nil)) .. " pop shown " .. Show(get(ui.pop, "IsShown", nil))
end

local function sweep()
    if not ui or not ui.main then error("no window: run step 1 first", 0) end
    local results = {}
    for _, e in ipairs(SWEEP) do results[#results + 1] = e[1] .. "=" .. sweepOne(e, ui.main) end
    local plain = CreateFrame("Frame", nil, UIParent)
    plain:SetSize(10, 10)
    plain:SetPoint("CENTER")
    plain:Show()
    for _, e in ipairs(PLAIN) do results[#results + 1] = e[1] .. "=" .. sweepOne(e, plain) end
    plain:Hide()
    say("SWEEP done: read the host log between each begin/end pair for ADDON_ACTION_BLOCKED")
    return table.concat(results, "; ")
end

local function restoreWindow()
    if not sweepSaved or not ui or not ui.main then return "nothing saved" end
    local m, s = ui.main, sweepSaved
    m:SetAlpha(s.alpha)
    m:SetScale(s.scale)
    if s.width > 0 and s.height > 0 then m:SetSize(s.width, s.height) end
    m:SetFrameStrata(s.strata)
    m:SetFrameLevel(s.level)
    m:SetClampedToScreen(s.clamped)
    m:EnableMouse(true)
    m:Show()
    local inst = lib().glass
    if inst and inst.SetWash and m.glass then inst.SetWash(m.glass, inst.STYLE.wash) end
    ui:OnCombatEnd()
    ui:Update()
    return "restored; shown " .. Show(get(m, "IsShown", nil))
end

Probe:Steps("sweep", {
    rev = 1,
    title = "Protected window: which writes this build refuses in combat (Wildly #42)",
    { text = "Out of combat, near one mob you can pull. Building and opening the probe window.", auto = true,
      run = function()
          local ok, err = pcall(build)
          if not ok then error(err, 0) end
          ui:Open()
          ui:Update()
          return rememberWindow()
      end,
      check = function()
          return not InCombatLockdown() and ui and ui.main and ui.main:IsShown(), "window up, out of combat"
      end },
    { text = "Pull one mob and stay in combat (do not kill it yet).", event = "PLAYER_REGEN_DISABLED" },
    { text = "Trying each write on the protected frame. Watch the console for ADDON_ACTION_BLOCKED.", auto = true,
      run = function() return sweep() end,
      check = function() return InCombatLockdown(), "still in combat while sweeping" end },
    { text = "Kill the mob or let combat end.", event = "PLAYER_REGEN_ENABLED" },
    { text = "Restoring the window.", auto = true, run = function() return restoreWindow() end,
      check = function() return ui and ui.main and ui.main:IsShown(), "window back" end },
    { text = "Type /reload to save the results.", reload = true },
})

-- ─── spells: GetSpellInfo(id) against a cold cache (Magely #48) ──────────────
--
-- The consumers resolve their spell names from IDs at login and on
-- SPELLS_CHANGED. On an English client a miss is invisible (the fallback is
-- the English literal); on any other it leaves a name that matches nothing.
-- This records, at each load phase, which IDs have no name yet, whether the
-- client says their data is cached, and whether it says they exist at all.

local SPELL_IDS = {
    { 1243, "Priestly: Power Word: Fortitude" }, { 21562, "Priestly: Prayer of Fortitude" },
    { 14752, "Priestly: Divine Spirit" }, { 27681, "Priestly: Prayer of Spirit" },
    { 976, "Priestly: Shadow Protection" }, { 27683, "Priestly: Prayer of Shadow Protection" },
    { 1126, "Wildly: Mark of the Wild" }, { 21849, "Wildly: Gift of the Wild" }, { 467, "Wildly: Thorns" },
    { 1459, "Magely: Arcane Intellect" }, { 23028, "Magely: Arcane Brilliance" },
    { 1008, "Magely: Amplify Magic" }, { 604, "Magely: Dampen Magic" },
}

local logBound = false
local buffered, runSnaps = {}, {}     -- lines before the log is bound; this run's phases

local function snapshot(phase, quiet)
    local cached = lookup("C_Spell.IsSpellDataCached")
    local exists = lookup("C_Spell.DoesSpellExist")
    local info = lookup("C_Spell.GetSpellInfo")
    local parts, missing, uncached = {}, 0, {}
    for _, s in ipairs(SPELL_IDS) do
        local id = s[1]
        local named = false
        if type(info) == "function" then
            local ok, i = pcall(info, id)
            if ok and type(i) == "table" then
                local ok2, has = pcall(function() return i.name ~= nil end)
                named = ok2 and has or false
            end
        end
        local c = type(cached) == "function" and select(2, pcall(cached, id))
        local e = type(exists) == "function" and select(2, pcall(exists, id))
        if not named then missing = missing + 1 end
        if c == false then uncached[#uncached + 1] = id end
        parts[#parts + 1] = id .. ":" .. (named and "ok" or "NIL")
            .. (c == false and "/uncached" or "") .. (e == false and "/absent" or "")
    end
    runSnaps[#runSnaps + 1] = { phase = phase, missing = missing }
    if not quiet then
        local text = "SPELLS " .. tostring(phase) .. " missing=" .. missing .. "/" .. #SPELL_IDS .. " " .. table.concat(parts, " ")
        if logBound then say(text) else buffered[#buffered + 1] = text end
    end
    return missing, uncached
end

local function summary()
    local parts = {}
    for _, s in ipairs(runSnaps) do parts[#parts + 1] = s.phase .. "=" .. s.missing end
    return table.concat(parts, " ")
end

local function missingAt(phase)
    local m
    for _, s in ipairs(runSnaps) do if s.phase == phase then m = s.missing end end
    return m
end

local spellWatch = CreateFrame("Frame")
Probe:RegisterEvents(spellWatch, { "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "SPELLS_CHANGED", "SPELL_DATA_LOAD_RESULT" })
spellWatch:SetScript("OnEvent", function(_, event, a, b)
    if event == "SPELL_DATA_LOAD_RESULT" then
        -- (spellID, success), one per requested spell. Only ours are worth a line.
        for _, s in ipairs(SPELL_IDS) do
            if s[1] == a then
                if logBound then say("SPELL_DATA_LOAD_RESULT " .. Show(a) .. " " .. Show(b)) end
                snapshot(event)
                break
            end
        end
        return
    end
    snapshot(event)
    if event == "PLAYER_ENTERING_WORLD" then
        C_Timer.After(5, function() snapshot("PLAYER_ENTERING_WORLD+5s") end)
    end
end)
snapshot("file scope")

Probe:Command("resolve", function()
    snapshot("command")
    say("this run: " .. summary())
end, "how every consumer's spell IDs resolve right now")

Probe:Steps("spells", {
    rev = 1,
    title = "Spell data at login: GetSpellInfo(id) against a cold cache (Magely #48)",
    { text = "This session's snapshots: how many of the consumers' spell IDs had no name at each phase.", auto = true,
      run = function() snapshot("now"); return summary() end,
      check = function()
          local m = missingAt("PLAYER_LOGIN")
          return m == 0, "missing at PLAYER_LOGIN: " .. tostring(m)
      end },
    { text = "Exit the game fully and relaunch (a cold spell cache), then log in on the same character.",
      reload = "exit" },
    { text = "The relaunch's snapshots.", auto = true, run = function() return summary() end,
      check = function()
          local a, b = missingAt("PLAYER_LOGIN"), missingAt("PLAYER_ENTERING_WORLD")
          return a == 0 and b == 0, "missing at login " .. tostring(a) .. ", entering world " .. tostring(b)
      end },
    { text = "Request spell data for every ID the client says is not cached.", button = "Request",
      run = function()
          local _, uncached = snapshot("before request")
          local req = lookup("C_Spell.RequestLoadSpellData")
          if type(req) ~= "function" then return "RequestLoadSpellData MISSING" end
          for _, id in ipairs(uncached) do pcall(req, id) end
          return #uncached .. " requested"
      end },
    { text = "Waiting for every ID to resolve.", timeout = 30,
      wait = function()
          local m = snapshot("waiting", true)
          return m == 0, "unresolved " .. m
      end },
    { text = "Type /reload to save the results.", reload = true },
})

-- ─── look (r29) ─────────────────────────────────────────────────────────────

Probe:Steps("look", {
    rev = 1,
    title = "r29: the window wears the clean preset",
    { text = "Out of combat, on a priest. Reading the versions and the material.", auto = true,
      run = function() state(); local L = lib(); return L and L.shared.MINOR end,
      check = function()
          local L = lib()
          return L ~= nil and L.shared.MINOR >= 29, "LibGroupBuffs MINOR " .. tostring(L and L.shared.MINOR)
      end },
    { text = "Open the window over scenery.", button = "Open", screenshot = "window, clean", run = function()
          local ok, err = pcall(build)
          if not ok then error(err, 0) end
          ui:Open()
          return ui:IsVisible()
      end },
    { text = "Thin rim, smooth body (no grain), bars about 60% see-through?", ask = true,
      screenshot = "clean look" },
    { text = "Check the material again, now that a window exists.", button = "Check",
      run = function() state(); return panelSize() end,
      check = function() return panelSize() == "thin", "panel size " .. tostring(panelSize()) end },
    { text = "Close the window.", button = "Close", run = function() return ui and ui:Close(true) end },
    { text = "Type /reload to save the results.", reload = true },
})

-- ─── boot ───────────────────────────────────────────────────────────────────

local boot = CreateFrame("Frame")
Probe:RegisterEvents(boot, { "ADDON_LOADED" })
boot:SetScript("OnEvent", function(_, _, name)
    if name ~= ADDON then return end
    Probe:Ready()
    if type(LibGroupBuffsProbeDB) ~= "table" then LibGroupBuffsProbeDB = {} end
    if type(LibGroupBuffsProbeDB.log) ~= "table" then LibGroupBuffsProbeDB.log = {} end
    Probe:UseLog(LibGroupBuffsProbeDB.log, MAX_LOG)
    LibGroupBuffsProbeDB.loads = (LibGroupBuffsProbeDB.loads or 0) + 1
    logBound = true
    for _, line in ipairs(buffered) do say(line) end
    buffered = {}
    say("loaded (" .. LibGroupBuffsProbeDB.loads .. " loads). /fp gb for the commands; /fp steps gb bg|sweep|spells|look")
end)

-- The test seam (tests/test_probe.lua), never on _G.
if type(NS) == "table" then
    NS._test = {
        Probe = Probe, DEFS = DEFS, SPELL_IDS = SPELL_IDS,
        build = build, sample = sample, sweep = sweep, snapshot = snapshot, summary = summary,
        rememberWindow = rememberWindow, restoreWindow = restoreWindow,
        window = function() return ui, engine end,
        spellWatch = spellWatch,
    }
end
