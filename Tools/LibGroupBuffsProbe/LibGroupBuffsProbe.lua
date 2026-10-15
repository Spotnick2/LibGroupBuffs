-- LibGroupBuffsProbe: LibGroupBuffs's developer probe, a ForeverProbe module
-- (/fp gb). Its lines go to the ForeverProbe console and
-- LibGroupBuffsProbeDB.log, never to chat. It is never packaged.
--
-- It drives the window through lib:New with a synthetic host (the three priest
-- buffs, everything else in plain fields), so the library can be checked in
-- game without Priestly, Wildly or Magely.
--   /fp gb state        which copies run, and whether the window wears the clean preset
--   /fp gb show|hide    open or close the window
--   /fp steps gb look   the r29 look check, with screenshots
-- The embedded libraries are these checkouts (deploy.ps1). A newer copy in
-- another addon would win LibStub, so `state` and the procedure's first step
-- log which MINOR runs.
--
-- The buffs are a priest's: on another class the engine finds nothing to
-- show. The window parents secure buttons, so the library itself refuses to
-- show or hide it in combat.

local ADDON = ...
local MAX_LOG = 3000
local OWNER = "LibGroupBuffsProbe"
local Probe = ForeverProbe:Module("LibGroupBuffsProbe", { api = 1, cmd = "gb" })
local function say(msg) Probe:Say(msg) end

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

local function panelSize()
    local panel = ui and ui.main and ui.main.glass
    return panel and panel.size
end

local function state()
    local L = lib()
    if not L then say("LibGroupBuffs-1.0 is not loaded"); return end
    local _, gm = LibStub:GetLibrary("LibGlass-1.0", true)
    say("LibGroupBuffs MINOR " .. Probe.Show(L.shared and L.shared.MINOR) .. ", ready " .. Probe.Show(L.ready)
        .. "; LibGlass MINOR " .. Probe.Show(gm))
    local why = L:Refusal()
    say("refusal: " .. (why and why.code or "none"))
    local g = L.glass
    if not g then say("no LibGlass instance yet (built with the first window): /fp gb show"); return end
    local st = g.STYLE
    say("material: grain " .. Probe.Show(st.grain) .. ", gloss " .. Probe.Show(st.gloss)
        .. ", thinRim " .. Probe.Show(st.thinRim) .. ", shadowAlpha " .. Probe.Show(st.shadowAlpha)
        .. " (clean: 0 / 0.25 / true / 0.3)")
    say("panel size key " .. Probe.Show(panelSize()) .. " (clean: thin)")
end

Probe:Command("state", state, "which copies run; is the window clean")

Probe:Command("show", function()
    local ok, err = pcall(build)
    if not ok then say("build refused: " .. tostring(err)); return end
    ui:Open()
    say("open requested; visible " .. Probe.Show(ui:IsVisible()))
end, "build the synthetic window and open it")

Probe:Command("hide", function()
    if ui then say("close returned " .. Probe.Show(ui:Close(true))) else say("nothing built yet") end
end, "close the window")

Probe:Command("clear", function() Probe:ClearLog(); say("log cleared") end, "empty the saved log")

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

local boot = CreateFrame("Frame")
Probe:RegisterEvents(boot, { "ADDON_LOADED" })
boot:SetScript("OnEvent", function(_, _, name)
    if name ~= ADDON then return end
    Probe:Ready()
    if type(LibGroupBuffsProbeDB) ~= "table" then LibGroupBuffsProbeDB = {} end
    if type(LibGroupBuffsProbeDB.log) ~= "table" then LibGroupBuffsProbeDB.log = {} end
    Probe:UseLog(LibGroupBuffsProbeDB.log, MAX_LOG)
    LibGroupBuffsProbeDB.loads = (LibGroupBuffsProbeDB.loads or 0) + 1
    say("loaded (" .. LibGroupBuffsProbeDB.loads .. " loads). /fp gb for the commands, /fp steps gb look")
end)
