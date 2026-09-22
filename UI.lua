-- ============================================================================
-- UI.lua  -  the buff window: the main frame with one row per group per buff,
-- the per-member popover, the drag handle, the close button, the reagent
-- footer and the ticker. Shared by Priestly, Wildly and Magely.
--
--     local ui = LibStub("LibGroupBuffs-1.0").UI.New({
--         engine  = engine,             -- this addon's Engine object
--         owner   = "Priestly",         -- for diagnostics only; frames are anonymous
--         title   = "|cff99ddffPriestly|r",
--         version = "2.0.5",
--         appearance = function() return { icon = specTexture } end,   -- optional
--         unknownClassIcon = texture,   -- optional: a member whose class is unknown
--         footerItems = function() return { { itemID =, icon =, usedBy =,
--                                             color = function(count) return r, g, b end } } end,
--         alpha = fn, locked = fn, popoverSide = fn, showClickHints = fn,   -- optional
--         getPos = function() return pos, whyNil end, setPos = function(pos) end,
--         setVisible = function(visible) end,
--         onLayout = function(ui) end, onVisibility = function(ui, visible) end,  -- optional
--     })
--
-- The addon keeps its events, slash commands, options panel and policy (who
-- the window opens for, and when) and calls the methods below from them.
--
-- Three rules this file is built around:
--
--   * Secure buttons: plain SecureActionButtonTemplate plus attributes, both
--     mouse edges registered (API.ClickEdges), no typerelease, no secure
--     snippets (loadstring_untainted is missing on this client). Nothing
--     writes an attribute under combat lockdown - the client refuses it.
--   * Both frames parent secure buttons, which makes them PROTECTED: in
--     combat the client refuses to hide, move, re-anchor or unclamp them, and
--     refuses to stop a drag. Nothing here touches them while locked down;
--     what the player asked for happens in OnCombatEnd.
--   * Every script handler and every delayed callback calls a METHOD on the ui
--     object when it runs. Handlers are installed once, when the frames are
--     built, so a closure over an implementation function would keep running
--     that copy of the library forever; a method lookup runs the newest one.
-- ============================================================================

-- Same MINOR as every runtime file; see Settings.lua for the two-check guard.
local MAJOR, MINOR = "LibGroupBuffs-1.0", 7
local lib, active = LibStub:GetLibrary(MAJOR, true)
if not lib or active ~= MINOR then return end
if lib.uiMinor == MINOR then return end

lib.UI = lib.UI or {}
lib.UIMethods = lib.UIMethods or {}
lib.UIMeta = lib.UIMeta or {}
local UI, Methods = lib.UI, lib.UIMethods
lib.UIMeta.__index = Methods

-- ─── Layout ─────────────────────────────────────────────────────────────────

local ICON_W     = 16
local BAR_W      = 91
local ROW_H      = 15
local ROW_W      = ICON_W + BAR_W       -- 107
local GRP_HDR_H  = 10
local FRAME_W    = ROW_W + 12           -- 119
local ROW_X      = 5
local HDR_H      = 24                   -- styled header bar height
local FTR_H      = 14                   -- reagent footer height
-- Wide enough for a full Forever name: characters have surnames, and first
-- names are not unique, so the whole name has to fit.
local POP_W      = 236
local POP_ROW_H  = 22
local POP_HDR_H  = 24

-- The worst roster the engine can produce: a full raid in eight subgroups of
-- at most five, and a pet on every member.
local MAX_RAID      = 40
local MAX_SUBGROUPS = 8
local SUBGROUP_SIZE = 5

-- Public tables are filled in place, never replaced: a consumer may hold a
-- reference, and a newer embedded copy must be able to add or correct entries
-- without detaching it (the same rule as lib.API and Engine.STATES).
UI.CLASS_ICONS = UI.CLASS_ICONS or {}
for class, icon in pairs({
    WARRIOR  = "Interface\\Icons\\ClassIcon_Warrior",
    PALADIN  = "Interface\\Icons\\ClassIcon_Paladin",
    HUNTER   = "Interface\\Icons\\ClassIcon_Hunter",
    ROGUE    = "Interface\\Icons\\ClassIcon_Rogue",
    PRIEST   = "Interface\\Icons\\ClassIcon_Priest",
    SHAMAN   = "Interface\\Icons\\ClassIcon_Shaman",
    MAGE     = "Interface\\Icons\\ClassIcon_Mage",
    WARLOCK  = "Interface\\Icons\\ClassIcon_Warlock",
    DRUID    = "Interface\\Icons\\ClassIcon_Druid",
    PET_HUNTER  = "Interface\\Icons\\Ability_Hunter_BeastCall",
    PET_WARLOCK = "Interface\\Icons\\Spell_Shadow_SummonImp",
    PET_PRIEST  = "Interface\\Icons\\Spell_Shadow_Shadowfiend",
    PET_MAGE    = "Interface\\Icons\\Spell_Frost_SummonWaterElemental_2",
    PET         = "Interface\\Icons\\Ability_Hunter_BeastCall",
}) do
    UI.CLASS_ICONS[class] = icon
end

-- Colours an addon can override through appearance(); these are Priestly's.
UI.DEFAULT_APPEARANCE = UI.DEFAULT_APPEARANCE or {}
for key, colour in pairs({
    mainBg     = { 0.04, 0.04, 0.10 },          -- alpha comes from host.alpha()
    border     = { 0.40, 0.40, 0.65, 0.85 },
    header     = { 0.07, 0.07, 0.18, 0.98 },
    headerLine = { 0.40, 0.40, 0.65, 0.55 },
    footerLine = { 0.40, 0.40, 0.65, 0.40 },
    popBg      = { 0.05, 0.05, 0.12 },
    popBorder  = { 0.42, 0.42, 0.65, 1 },
    groupText  = { 0.52, 0.52, 0.70 },
}) do
    local t = UI.DEFAULT_APPEARANCE[key] or {}
    UI.DEFAULT_APPEARANCE[key] = t
    for i = 1, 4 do t[i] = colour[i] end
end

local DEFAULT_POS = { point = "CENTER", relPoint = "CENTER", x = 300, y = 50 }

-- ─── Small helpers ──────────────────────────────────────────────────────────

-- Returns r, g, b for a fraction (0..1) of a buff's duration left: PallyPower's
-- smooth green -> yellow -> red gradient.
function UI.TimerColor(pct)
    if pct >= 0.5 then
        return (1.0 - pct) * 2, 1.0, 0.0
    else
        return 1.0, pct * 2, 0.0
    end
end

-- Fraction of the buff's duration still to run, clamped. A permanent aura
-- reports PERMANENT remaining, which would otherwise drive the gradient past
-- 1.0 and hand TimerColor a negative red channel.
function UI.Pct(rem, dur)
    if not rem or not dur or dur <= 0 or rem <= 0 then return 0 end
    local p = rem / dur
    if p > 1 then return 1 end
    return p
end

function UI.FmtTime(s)
    if not s or s <= 0 then return "" end
    if s > 9998 then return "" end
    return string.format("%d:%02d", math.floor(s / 60), math.floor(s % 60))
end

local function ClassColor(classFile)
    local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
    if c then return c.r, c.g, c.b end
    return 0.80, 0.80, 0.80
end

-- C_Timer exists on this client; the OnUpdate frame is the fallback for one
-- that does not. Going through C_Timer also keeps deferred work reachable from
-- the tests.
local function After(delay, fn)
    if C_Timer and C_Timer.After then
        C_Timer.After(delay, fn)
        return
    end
    local t = 0
    local f = CreateFrame("Frame")
    f:SetScript("OnUpdate", function(self, dt)
        t = t + dt
        if t >= delay then self:SetScript("OnUpdate", nil); fn() end
    end)
end

-- MEASURED, build 69913: a frame that parents secure buttons is PROTECTED, and
-- in combat the client refuses to hide it, move it, re-anchor it, unclamp it
-- or stop a drag on it - each attempt is an ADDON_ACTION_BLOCKED, silently
-- ignored, and blamed on whichever addon's taint the call path carries.
--
-- So parking the window offscreen during combat, which this file used to do,
-- was never possible: SetClampedToScreen was blocked before anything moved.
-- Nothing here touches either frame while locked down. What the player asked
-- for is remembered and done when combat ends, a fight being the one time the
-- rows are worth having on screen anyway.

local function Call(fn, ...)
    if fn then return fn(...) end
end

-- ─── Construction ───────────────────────────────────────────────────────────

local function Fail(msg) error("LibGroupBuffs UI.New: " .. msg, 3) end

local OPTIONAL_FUNCTIONS = {
    "appearance", "footerItems", "alpha", "locked", "popoverSide", "showClickHints",
    "getPos", "setPos", "setVisible", "onLayout", "onVisibility",
}

function UI.New(host)
    if type(host) ~= "table" then Fail("host must be a table") end
    if type(host.engine) ~= "table" or getmetatable(host.engine) ~= lib.EngineMeta then
        Fail("engine must be an engine from this library's Engine.New")
    end
    if type(host.owner) ~= "string" or host.owner == "" then Fail("owner must name the addon") end
    for _, key in ipairs(OPTIONAL_FUNCTIONS) do
        if host[key] ~= nil and type(host[key]) ~= "function" then
            Fail(key .. " must be a function or nil")
        end
    end
    -- Nothing is built here: frames that parent secure buttons cannot be
    -- created in combat, and the addon may be loading into one.
    return setmetatable({
        host = host,
        engine = host.engine,
        visible = false,        -- the window is logically open (in combat the
                                -- frame can still be up after a close)
        moved = false,          -- a position has been applied this session
        refQueued = false,
        pendingShow = false,    -- a show that arrived during combat
        showGen = 0,            -- bumped by Close: queued shows older than it are dropped
        restoreLog = "the window has not been built yet",
        restoreSkips = 0,
        tick = 0, footerTick = 0,
        rows = {}, popRows = {}, headers = {}, footerBtns = {},
        footerItems = {},
    }, lib.UIMeta)
end

-- How many of each element the worst roster needs. Popover rows cover a whole
-- raid subgroup as well as a pet bucket: only pets are split into buckets.
function Methods:Capacity()
    local size = self.engine.bucketSize
    local groups = MAX_SUBGROUPS + math.ceil(MAX_RAID / size)
    return groups, groups * #self.engine.defs, math.max(SUBGROUP_SIZE, size)
end

function Methods:Appearance()
    local out = {}
    for k, v in pairs(UI.DEFAULT_APPEARANCE) do out[k] = v end
    local custom = Call(self.host.appearance)
    if type(custom) == "table" then
        for k, v in pairs(custom) do out[k] = v end
    end
    return out
end

function Methods:Alpha()
    local a = Call(self.host.alpha)
    return type(a) == "number" and a or 0.96
end

local function Backdrop(f, edge)
    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = edge,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
end

local function MakeRow(ui, parent, i)
    local r = CreateFrame("Button", nil, parent, "SecureActionButtonTemplate")
    r._ui = ui
    r:SetSize(ROW_W, ROW_H)
    r:EnableMouse(true)
    r:RegisterForClicks(lib.API.ClickEdges())

    r.bg = r:CreateTexture(nil, "BACKGROUND")
    r.bg:SetAllPoints()

    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(ICON_W - 2, ICON_W - 2)
    r.icon:SetPoint("LEFT", r, "LEFT", 1, 0)
    r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    r.timer = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    r.timer:SetPoint("RIGHT", r, "RIGHT", -3, 0)

    r.missCount = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    r.missCount:SetPoint("LEFT", r, "LEFT", ICON_W + 2, 0)
    r.missCount:SetTextColor(1.0, 1.0, 1.0)

    r.missAll = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    r.missAll:SetPoint("CENTER", r, "CENTER", ICON_W / 2, 0)
    r.missAll:SetTextColor(1.0, 0.28, 0.28)
    r.missAll:SetText("MISS")

    r:SetScript("PreClick",  function(self, button) return self._ui:RowPreClick(self, button) end)
    r:SetScript("PostClick", function(self, button) return self._ui:RowPostClick(self, button) end)
    r:SetScript("OnEnter",   function(self) return self._ui:RowEnter(self) end)
    r:SetScript("OnLeave",   function(self) return self._ui:RowLeave(self) end)

    r._active = false
    r:Hide()
    return r
end

local function MakePopRow(ui, parent, i)
    local pr = CreateFrame("Button", nil, parent, "SecureActionButtonTemplate")
    pr._ui = ui
    pr:SetSize(POP_W - 10, POP_ROW_H)
    pr:SetPoint("TOPLEFT", parent, "TOPLEFT",
        5, -(POP_HDR_H + 5) - (i - 1) * (POP_ROW_H + 2))
    pr:EnableMouse(true)
    pr:RegisterForClicks(lib.API.ClickEdges())
    pr:SetFrameLevel(202)  -- above the popover's level 200

    pr.bg = pr:CreateTexture(nil, "BACKGROUND")
    pr.bg:SetAllPoints()

    pr.rangeTxt = pr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pr.rangeTxt:SetPoint("LEFT", pr, "LEFT", 3, 0)
    pr.rangeTxt:SetWidth(13)
    pr.rangeTxt:SetJustifyH("CENTER")

    pr.classIcon = pr:CreateTexture(nil, "ARTWORK")
    pr.classIcon:SetSize(POP_ROW_H - 6, POP_ROW_H - 6)
    pr.classIcon:SetPoint("LEFT", pr.rangeTxt, "RIGHT", 2, 0)
    pr.classIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    pr.nameTxt = pr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pr.nameTxt:SetPoint("LEFT",  pr.classIcon, "RIGHT", 3,  0)
    pr.nameTxt:SetPoint("RIGHT", pr,           "RIGHT", -44, 0)
    pr.nameTxt:SetJustifyH("LEFT")

    pr.timeTxt = pr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pr.timeTxt:SetPoint("RIGHT", pr, "RIGHT", -3, 0)
    pr.timeTxt:SetWidth(40)
    pr.timeTxt:SetJustifyH("RIGHT")

    pr:SetScript("PreClick",  function(self, button) return self._ui:PopRowPreClick(self, button) end)
    pr:SetScript("PostClick", function(self, button) return self._ui:PopRowPostClick(self, button) end)
    pr:SetScript("OnEnter",   function(self) return self._ui:PopRowEnter(self) end)
    pr:SetScript("OnLeave",   function(self) return self._ui:PopRowLeave(self) end)

    pr._active = false
    pr:Hide()
    return pr
end

local function MakeFooterButton(ui, parent)
    local btn = CreateFrame("Button", nil, parent)
    btn._ui = ui
    btn:SetSize(FTR_H - 2 + 24, FTR_H)  -- icon + room for the count
    btn:EnableMouse(true)

    btn.icon = btn:CreateTexture(nil, "ARTWORK")
    btn.icon:SetSize(FTR_H - 4, FTR_H - 4)
    btn.icon:SetPoint("LEFT", btn, "LEFT", 0, 0)
    btn.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    btn.countTxt = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    btn.countTxt:SetPoint("LEFT", btn.icon, "RIGHT", 2, 0)

    btn:SetScript("OnEnter", function(self) return self._ui:FooterEnter(self) end)
    btn:SetScript("OnLeave", function(self) return self._ui:FooterLeave(self) end)
    btn:Hide()
    return btn
end

-- Build the frames, once. Refused in combat: secure buttons cannot be created
-- under lockdown. Returns whether the frames exist.
function Methods:Init()
    if self.main then return true end
    if InCombatLockdown() then return false end
    local look = self:Appearance()
    local alpha = self:Alpha()
    local nGroups, nRows, nPop = self:Capacity()
    self.capacity = { groups = nGroups, rows = nRows, popRows = nPop }

    -- ── Main frame ──────────────────────────────────────────────────────
    local main = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    main._ui = self
    self.main = main
    main:SetFrameStrata("HIGH")
    main:SetClampedToScreen(true)
    main:SetMovable(true)
    Backdrop(main, 14)
    main:SetBackdropColor(look.mainBg[1], look.mainBg[2], look.mainBg[3], alpha)
    main:SetBackdropBorderColor(unpack(look.border))
    main:Hide()

    local hdrBg = main:CreateTexture(nil, "ARTWORK")
    hdrBg:SetColorTexture(unpack(look.header))
    hdrBg:SetPoint("TOPLEFT",  main, "TOPLEFT",  4, -4)
    hdrBg:SetPoint("TOPRIGHT", main, "TOPRIGHT", -4, -4)
    hdrBg:SetHeight(HDR_H)
    main.hdrBg = hdrBg

    local hdrLine = main:CreateTexture(nil, "ARTWORK")
    hdrLine:SetColorTexture(unpack(look.headerLine))
    hdrLine:SetHeight(1)
    hdrLine:SetPoint("TOPLEFT",  hdrBg, "BOTTOMLEFT",  0, 0)
    hdrLine:SetPoint("TOPRIGHT", hdrBg, "BOTTOMRIGHT", 0, 0)
    main.hdrLine = hdrLine

    main.specIcon = main:CreateTexture(nil, "OVERLAY")
    main.specIcon:SetSize(HDR_H - 6, HDR_H - 6)
    main.specIcon:SetPoint("LEFT", hdrBg, "LEFT", 4, 0)
    main.specIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    main.title = main:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    main.title:SetPoint("LEFT", main.specIcon, "RIGHT", 3, 0)
    main.title:SetText(self.host.title or self.host.owner)

    main.version = main:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    main.version:SetPoint("LEFT", main.title, "RIGHT", 2, 0)
    main.version:SetText(self.host.version and ("|cff555577" .. self.host.version .. "|r") or "")

    local xBtn = CreateFrame("Button", nil, main, "UIPanelCloseButton")
    xBtn._ui = self
    xBtn:SetPoint("TOPRIGHT", main, "TOPRIGHT", 3, 3)
    xBtn:SetScale(0.6)
    xBtn:SetScript("OnClick", function(b) return b._ui:Close(true) end)
    main.closeBtn = xBtn

    -- Covers the header only, so the row buttons still get their clicks.
    local drag = CreateFrame("Frame", nil, main)
    drag._ui = self
    drag:SetPoint("TOPLEFT",  hdrBg, "TOPLEFT",  0, 0)
    drag:SetPoint("TOPRIGHT", hdrBg, "TOPRIGHT", -16, 0)  -- leave room for the X
    drag:SetHeight(HDR_H)
    drag:EnableMouse(true)
    -- Gated rather than unregistered: leaving RegisterForDrag in place keeps
    -- this clear of the secure-frame rules, so the lock can be toggled in
    -- combat like any other setting.
    drag:RegisterForDrag("LeftButton")
    drag:SetScript("OnDragStart", function(d) return d._ui:DragStart() end)
    drag:SetScript("OnDragStop",  function(d) return d._ui:DragStop() end)
    main.dragHandle = drag

    for i = 1, nGroups do
        local fs = main:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetTextColor(unpack(look.groupText))
        fs:Hide()
        self.headers[i] = fs
    end
    for i = 1, nRows do self.rows[i] = MakeRow(self, main, i) end

    -- ── Popover ─────────────────────────────────────────────────────────
    local pop = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    pop._ui = self
    self.pop = pop
    pop:SetFrameStrata("DIALOG")
    pop:SetFrameLevel(200)
    pop:SetClampedToScreen(true)
    Backdrop(pop, 12)
    pop:SetBackdropColor(look.popBg[1], look.popBg[2], look.popBg[3], alpha)
    pop:SetBackdropBorderColor(unpack(look.popBorder))
    -- No EnableMouse, so the secure child buttons receive the clicks.
    pop:Hide()

    pop.hdrIcon = pop:CreateTexture(nil, "ARTWORK")
    pop.hdrIcon:SetSize(POP_HDR_H - 6, POP_HDR_H - 6)
    pop.hdrIcon:SetPoint("TOPLEFT", pop, "TOPLEFT", 7, -6)
    pop.hdrIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    pop.hdrTxt = pop:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    pop.hdrTxt:SetPoint("LEFT",  pop.hdrIcon, "RIGHT", 5, 0)
    pop.hdrTxt:SetPoint("RIGHT", pop,         "RIGHT", -6, 0)
    pop.hdrTxt:SetPoint("TOP",   pop,         "TOP",   0, -8)
    pop.hdrTxt:SetJustifyH("LEFT")
    pop.hdrTxt:SetTextColor(1.0, 0.82, 0.22)

    local hdiv = pop:CreateTexture(nil, "ARTWORK")
    hdiv:SetColorTexture(0.32, 0.32, 0.55, 0.55)
    hdiv:SetHeight(1)
    hdiv:SetPoint("TOPLEFT",  pop, "TOPLEFT",  5, -(POP_HDR_H + 2))
    hdiv:SetPoint("TOPRIGHT", pop, "TOPRIGHT", -5, -(POP_HDR_H + 2))

    for i = 1, nPop do self.popRows[i] = MakePopRow(self, pop, i) end

    -- Hover polling hides the popover once the mouse is over neither it nor
    -- its row. It replaced OnLeave handlers, which fire on the way TO the
    -- popover.
    pop._hoverTimer = 0
    pop:SetScript("OnUpdate", function(p, dt) return p._ui:PopoverTick(dt) end)

    -- ── Footer ──────────────────────────────────────────────────────────
    main.ftrLine = main:CreateTexture(nil, "ARTWORK")
    main.ftrLine:SetColorTexture(unpack(look.footerLine))
    main.ftrLine:SetHeight(1)
    main.ftrLine:Hide()

    -- ── Ticker ──────────────────────────────────────────────────────────
    main:SetScript("OnUpdate", function(m, dt) return m._ui:MainTick(dt) end)
    return true
end

-- ─── Visuals ────────────────────────────────────────────────────────────────

function Methods:ApplyRowVisuals(r, st)
    local dur = st.minDur or 3600
    local pct = UI.Pct(st.minR, dur)

    -- Flat colours matching PallyPower: green when everyone has it, yellow
    -- when some are missing it, red when nobody does - and grey when it cannot
    -- be read at all.
    if st.nUnknown == st.nTotal then
        r.bg:SetColorTexture(0.30, 0.30, 0.30, 0.60)
    elseif st.allHave then
        r.bg:SetColorTexture(0.0, 0.70, 0.0, 0.50)
    elseif st.nMiss == st.nTotal then
        r.bg:SetColorTexture(1.0, 0.0, 0.0, 0.50)
    else
        r.bg:SetColorTexture(1.0, 1.0, 0.5, 0.50)
    end

    r.timer:Hide()
    r.missAll:Hide()
    r.missCount:Hide()

    if st.nMiss > 0 then
        r.missCount:SetText(st.nMiss)
        r.missCount:Show()
    end

    if st.nUnknown == st.nTotal then
        r.missAll:SetText("?")
        r.missAll:SetTextColor(0.65, 0.65, 0.65)
        r.missAll:Show()
    elseif st.nMiss == st.nTotal then
        r.missAll:SetText("MISS")
        r.missAll:SetTextColor(1.0, 0.28, 0.28)
        r.missAll:Show()
    elseif st.minR > 0 then
        local tr, tg, tb = UI.TimerColor(pct)
        r.timer:SetText(UI.FmtTime(st.minR))
        r.timer:SetTextColor(tr, tg, tb)
        r.timer:Show()
    end
end

function Methods:ApplyPopRowVisuals(pr)
    if not pr._active then return end
    local engine = self.engine
    local S = lib.Engine.STATES
    local unit, def = pr._unit, pr._def
    local rem, buffDur, state, spell = engine:BuffRem(unit, def)
    local has = (state == S.HAS) and rem > 0
    -- The range dot describes the spell the LEFT click casts: a group spell
    -- can reach further than the single form, so the single spell's range
    -- would mark members out of reach that the group spell lands on fine.
    local primarySpell = engine:ClickSpells(def)
    local range = lib.API.SpellRange(unit, primarySpell)
    local dur = engine:DurationFor(def, buffDur, spell)
    local pct = has and UI.Pct(rem, dur) or 0

    if not UnitIsConnected(unit) then
        pr.bg:SetColorTexture(0.30, 0.30, 0.30, 0.70)   -- offline
    elseif state == S.UNKNOWN then
        pr.bg:SetColorTexture(0.30, 0.30, 0.30, 0.60)   -- unreadable
    elseif has then
        pr.bg:SetColorTexture(0.0, 0.70, 0.0, 0.50)     -- buffed
    else
        pr.bg:SetColorTexture(1.0, 0.0, 0.0, 0.50)      -- missing
    end

    if range == "IN_RANGE" then
        pr.rangeTxt:SetText("R")
        pr.rangeTxt:SetTextColor(0.15, 1.00, 0.15)
    elseif range == "OUT_RANGE" then
        pr.rangeTxt:SetText("R")
        pr.rangeTxt:SetTextColor(1.00, 0.85, 0.10)
    elseif range == "OFFLINE" then
        pr.rangeTxt:SetText("R")
        pr.rangeTxt:SetTextColor(0.50, 0.50, 0.50)
    else
        pr.rangeTxt:SetText("?")
        pr.rangeTxt:SetTextColor(0.50, 0.50, 0.50)
    end

    if has then
        local tr, tg, tb = UI.TimerColor(pct)
        pr.timeTxt:SetText(UI.FmtTime(rem))
        pr.timeTxt:SetTextColor(tr, tg, tb)
    elseif state == S.UNKNOWN then
        pr.timeTxt:SetText("?")
        pr.timeTxt:SetTextColor(0.65, 0.65, 0.65)
    else
        pr.timeTxt:SetText("MISS")
        pr.timeTxt:SetTextColor(1.00, 0.22, 0.22)
    end
end

-- Visual only: colours, timers, counts. Never touches a secure attribute, so
-- it is what runs in combat. (It still reads auras through the engine, which
-- updates the engine's cache and learned durations.)
function Methods:RefreshTimers()
    for _, r in ipairs(self.rows) do
        if r._active then
            self:ApplyRowVisuals(r, self.engine:GroupStat(r._members, r._def))
        end
    end
    if self.pop and self.pop:IsShown() then
        for _, pr in ipairs(self.popRows) do
            if pr._active then self:ApplyPopRowVisuals(pr) end
        end
    end
end

-- Colours and icon, re-read from the addon. Backdrop opacity only, never the
-- frame's own alpha.
function Methods:ApplyAppearance()
    if not self.main then return end
    local look = self:Appearance()
    local alpha = self:Alpha()
    local main, pop = self.main, self.pop
    main:SetBackdropColor(look.mainBg[1], look.mainBg[2], look.mainBg[3], alpha)
    main:SetBackdropBorderColor(unpack(look.border))
    main.hdrBg:SetColorTexture(unpack(look.header))
    main.hdrLine:SetColorTexture(unpack(look.headerLine))
    main.ftrLine:SetColorTexture(unpack(look.footerLine))
    for _, h in ipairs(self.headers) do h:SetTextColor(unpack(look.groupText)) end
    if look.icon then main.specIcon:SetTexture(look.icon) end
    if look.title then main.title:SetText(look.title) end
    pop:SetBackdropColor(look.popBg[1], look.popBg[2], look.popBg[3], alpha)
    pop:SetBackdropBorderColor(unpack(look.popBorder))
end

-- ─── Footer ─────────────────────────────────────────────────────────────────

-- Counts and colours of the items currently laid out. Cheap; the ticker runs
-- it every few seconds and the addon calls it on BAG_UPDATE.
function Methods:RefreshFooter()
    for i, btn in ipairs(self.footerBtns) do
        local item = self.footerItems[i]
        if item and btn:IsShown() then
            local count = lib.API.CountItem(item.itemID)
            btn.countTxt:SetText(count)
            if item.color then
                btn.countTxt:SetTextColor(item.color(count))
            else
                btn.countTxt:SetTextColor(1, 1, 1)
            end
        end
    end
end

-- Lays the footer out at y; returns the new y. Only called from a rebuild.
function Methods:LayoutFooter(y)
    local main = self.main
    local items = Call(self.host.footerItems) or {}
    self.footerItems = items
    for i = #self.footerBtns + 1, #items do
        self.footerBtns[i] = MakeFooterButton(self, main)
    end
    for _, btn in ipairs(self.footerBtns) do btn:Hide() end
    if #items == 0 then
        main.ftrLine:Hide()
        return y
    end

    main.ftrLine:ClearAllPoints()
    main.ftrLine:SetPoint("TOPLEFT",  main, "TOPLEFT",  ROW_X, y)
    main.ftrLine:SetPoint("TOPRIGHT", main, "TOPRIGHT", -ROW_X, y)
    main.ftrLine:Show()
    y = y - 2

    local xOff = ROW_X + 2
    for i, item in ipairs(items) do
        local btn = self.footerBtns[i]
        btn._itemID = item.itemID
        btn._usedBy = item.usedBy
        btn.icon:SetTexture(item.icon or lib.API.ItemIcon(item.itemID))
        btn:ClearAllPoints()
        btn:SetPoint("TOPLEFT", main, "TOPLEFT", xOff, y)
        btn:Show()
        xOff = xOff + btn:GetWidth() + 4
    end
    self:RefreshFooter()
    return y - FTR_H
end

-- Built by hand: this client's GameTooltip has no item setter at all (see
-- API.ItemInfo).
function Methods:FooterEnter(btn)
    if not btn._itemID then return end
    GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
    local name, r, g, b = lib.API.ItemInfo(btn._itemID)
    -- A cache miss is not an error: ItemInfo has asked the client for the
    -- item, so the next hover will have it.
    GameTooltip:SetText(name or "Loading...", r or 1, g or 1, b or 1)
    local have = lib.API.CountItem(btn._itemID)
    GameTooltip:AddLine((have == 1 and "1 in your bags" or (have .. " in your bags")),
        0.85, 0.85, 0.85)
    if btn._usedBy then
        GameTooltip:AddLine("Used by " .. btn._usedBy, 0.55, 0.75, 1.0)
    end
    GameTooltip:Show()
end

function Methods:FooterLeave()
    GameTooltip:Hide()
end

-- ─── Ticker ─────────────────────────────────────────────────────────────────

function Methods:MainTick(dt)
    if not self.visible then return end
    self.tick = self.tick + dt
    self.footerTick = self.footerTick + dt
    if self.tick >= 0.5 then
        self.tick = 0
        self:RefreshTimers()
    end
    if self.footerTick >= 3.0 then
        self.footerTick = 0
        self:RefreshFooter()
    end
end

function Methods:PopoverTick(dt)
    local pop = self.pop
    if not pop:IsShown() then return end
    if self.popHidePending then return end   -- waiting for combat to end
    pop._hoverTimer = pop._hoverTimer + dt
    if pop._hoverTimer < 0.15 then return end
    pop._hoverTimer = 0
    local API = lib.API
    local overPop = API.IsMouseOver(pop)
    local overAnchor = pop._anchorRow and API.IsMouseOver(pop._anchorRow)
    local overChild = false
    for _, pr in ipairs(self.popRows) do
        if pr._active and pr:IsShown() and API.IsMouseOver(pr) then
            overChild = true
            break
        end
    end
    if not overPop and not overAnchor and not overChild then
        if InCombatLockdown() then
            -- Hiding it is blocked: it parents secure buttons. Leave it, stop
            -- polling, and close it when the fight ends.
            self.popHidePending = true
        else
            pop:Hide()
        end
    end
end

-- ─── Dragging ───────────────────────────────────────────────────────────────

function Methods:DragStart()
    if Call(self.host.locked) then return end
    -- The main frame parents secure buttons, which makes moving it a
    -- protected action in combat.
    if InCombatLockdown() then return end
    self.main:StartMoving()
end

function Methods:DragStop()
    -- A drag that combat interrupted cannot be stopped here: the frame is
    -- protected, and StopMovingOrSizing is blocked. It keeps following the
    -- cursor until the fight ends, which is when OnCombatEnd finishes this.
    if InCombatLockdown() then
        self.dragPending = true
        return
    end
    -- Release first: StopMovingOrSizing is harmless on a frame that was never
    -- moving, and skipping it would leave a frame locked mid-drag stuck to
    -- the cursor.
    --
    -- The bail below protects the SAVED position, not where the frame sits
    -- now: a drag interrupted by the lock leaves the window where the cursor
    -- was for the rest of the session, and the saved spot comes back on the
    -- next login.
    self.dragPending = false
    self.main:StopMovingOrSizing()
    if Call(self.host.locked) then return end
    self.moved = true
    -- GetPoint reports relativeTo as nil after StopMovingOrSizing while the
    -- restore anchors explicitly to UIParent. That is not a mismatch: the
    -- frame is PARENTED to UIParent, and a nil relativeTo means "my parent".
    -- Measured in game - saved and restored values match to the decimal.
    local point, _, relPoint, x, y = self.main:GetPoint()
    Call(self.host.setPos, { point = point, relPoint = relPoint, x = x, y = y })
end

-- Put the window back at the default spot and forget the saved one. It
-- ignores the lock, so a locked window dragged somewhere unreachable can always
-- be recovered. In combat only the saved position is cleared: re-anchoring the
-- frame is blocked, because it parents secure buttons. It moves when combat
-- ends. Returns whether it moved now.
function Methods:ResetPosition()
    Call(self.host.setPos, nil)
    self.moved = false
    if InCombatLockdown() then
        self.resetPending = true
        return false
    end
    self.resetPending = false
    if self.main then
        self.main:ClearAllPoints()
        self.main:SetPoint(DEFAULT_POS.point, UIParent, DEFAULT_POS.relPoint, DEFAULT_POS.x, DEFAULT_POS.y)
    end
    return true
end

-- What the last position restore decided, for the addon's diagnostic command.
-- Routine refreshes skip the restore and are only counted, so the decision
-- that matters is still there when somebody asks.
function Methods:RestoreInfo()
    return { log = self.restoreLog, skips = self.restoreSkips }
end

-- ─── Popover ────────────────────────────────────────────────────────────────

-- Which side of its row the popover opens on: the addon's choice, or on
-- "auto" whichever side of the screen has room, decided fresh every time
-- since the window can be dragged.
function Methods:PopoverSide(anchorRow)
    local pref = Call(self.host.popoverSide)
    if pref == "left" or pref == "right" then return pref end
    -- GetCenter is nil before layout, and the screen width can be 0 during a
    -- UI scale change - which is TRUTHY in Lua. Either way, fall back to the
    -- left rather than guessing.
    local rowX = anchorRow and anchorRow:GetCenter()
    local screenW = UIParent and UIParent:GetWidth()
    if not rowX or not screenW or screenW == 0 then return "left" end
    return (rowX < screenW / 2) and "right" or "left"
end

function Methods:UpdatePopover(anchorRow, members, def)
    if InCombatLockdown() then return end
    local pop = self.pop
    if not pop then return end
    self.popHidePending = false

    local engine = self.engine
    pop.hdrIcon:SetTexture(lib.API.SpellIcon(def.hasSingle and def.snglID or def.grpID, def.fallbackIcon))
    local popPrimary, popSecondary = engine:ClickSpells(def)
    -- Name whatever the primary click actually casts.
    pop.hdrTxt:SetText(popPrimary or def.sngl)
    pop._anchorRow = anchorRow

    local fallbackIcon = self.host.unknownClassIcon or "Interface\\Icons\\INV_Misc_QuestionMark"
    local cnt = math.min(#members, #self.popRows)
    for i = 1, cnt do
        local m, pr = members[i], self.popRows[i]
        pr._active = true
        pr._unit = m.unit
        pr._def = def

        -- Left: the primary spell on this person (a group spell covers their
        -- subgroup). Right: the secondary spell on this person.
        pr:SetAttribute("type1",  "spell")
        pr:SetAttribute("spell1", popPrimary)
        pr:SetAttribute("unit1",  m.unit)
        pr:SetAttribute("type2",  "spell")
        pr:SetAttribute("spell2", popSecondary)
        pr:SetAttribute("unit2",  m.unit)

        pr.classIcon:SetTexture((m.class and UI.CLASS_ICONS[m.class]) or fallbackIcon)
        local cr, cg, cb = ClassColor(m.class)
        pr.nameTxt:SetText(m.name)
        pr.nameTxt:SetTextColor(cr, cg, cb)

        self:ApplyPopRowVisuals(pr)
        pr:Show()
    end
    for i = cnt + 1, #self.popRows do
        self.popRows[i]._active = false
        self.popRows[i]:Hide()
    end

    pop:SetSize(POP_W, POP_HDR_H + 7 + cnt * (POP_ROW_H + 2) + 6)
    pop:ClearAllPoints()
    if self:PopoverSide(anchorRow) == "right" then
        pop:SetPoint("LEFT", anchorRow, "RIGHT", 4, 0)
    else
        pop:SetPoint("RIGHT", anchorRow, "LEFT", -4, 0)
    end
    pop:Show()
end

function Methods:PopRowPreClick(pr)
    if InCombatLockdown() then return end
    -- Block a cast at somebody offline or dead.
    if not self.engine:IsValidTarget(pr._unit) then
        pr:SetAttribute("spell1", nil)
        pr:SetAttribute("spell2", nil)
    end
end

function Methods:PopRowPostClick(pr)
    if InCombatLockdown() then return end
    local df = pr._def
    if df then
        -- Same rule as the main rows: do not re-arm a click aimed at someone
        -- dead, offline or gone.
        local valid = self.engine:IsValidTarget(pr._unit)
        local primary, secondary = self.engine:ClickSpells(df)
        pr:SetAttribute("spell1", valid and primary or nil)
        pr:SetAttribute("spell2", valid and secondary or nil)
    end
    self:ScheduleRefresh()
end

function Methods:PopRowEnter(pr)
    if pr._unit and not UnitIsConnected(pr._unit) then
        GameTooltip:SetOwner(pr, "ANCHOR_RIGHT")
        GameTooltip:SetText(lib.API.UnitDisplayName(pr._unit, "Unknown"), 0.6, 0.6, 0.6)
        GameTooltip:AddLine("This player is offline", 1, 0.5, 0.5)
        GameTooltip:Show()
    end
end

function Methods:PopRowLeave()
    GameTooltip:Hide()
end

-- ─── Click hints ────────────────────────────────────────────────────────────
--
-- What a row's clicks will actually cast, shown on hover. The mapping is not
-- fixed - without a group spell, left-click casts the single one - so the
-- addon, which knows, says. Getting it wrong can cost a reagent.

-- How a group reads in a sentence. nil for pet buckets: they are a display
-- grouping, not a subgroup, and a group spell cast on a pet covers that pet's
-- own party - so the hint names the target instead.
function Methods:GroupLabel(gNum)
    if not gNum then return "this group" end
    if gNum >= lib.Engine.PET_GROUP then return nil end
    if IsInRaid() then return "group " .. gNum end
    return "your party"
end

function Methods:HideClickHint()
    GameTooltip:Hide()
end

function Methods:ShowClickHint(row)
    local show = self.host.showClickHints
    if show and not show() then return end
    local def = row and row._def
    if not def then return end

    -- The popover opens on this same hover, so sit on the other side.
    local side = (self:PopoverSide(row) == "right") and "ANCHOR_LEFT" or "ANCHOR_RIGHT"
    GameTooltip:SetOwner(row, side)
    GameTooltip:SetText(def.hasGroup and def.grp or def.sngl, 0.62, 0.85, 1.0)

    -- Resolve each click the way the click itself resolves it. Out of combat
    -- PreClick picks again at click time, so the wired attributes are NOT the
    -- answer; in combat PreClick cannot write, so they are.
    local engine = self.engine
    local function resolve(which)
        if InCombatLockdown() then
            return row:GetAttribute("spell" .. which), row:GetAttribute("unit" .. which)
        end
        local spell = (which == 1) and row._primary or row._secondary
        if not spell or not row._members then return nil end
        local unit = engine:PickTarget(row._members, def, (which == 1) and row._groupMode or false)
        if not unit then return nil end   -- PreClick clears the spell here too
        return spell, unit
    end

    local function describe(label, spell, unit)
        if not spell then
            GameTooltip:AddLine(label .. "  |cff888888nothing to buff|r", 1, 1, 1)
            return
        end
        -- Decided from the spell the button carries, never from which button
        -- it is: with a group spell but no single form, BOTH clicks cast the
        -- group spell, and calling that a single-target cast on a named person
        -- is the mistake this tooltip exists to stop.
        local target = (def.hasGroup and spell == def.grp and self:GroupLabel(row._gNum))
                        or lib.API.UnitDisplayName(unit, "whoever needs it")
        GameTooltip:AddLine(label .. "  |cffffffff" .. spell .. "|r on " .. target, 1, 1, 1)
    end

    describe("|cffaaaaaaLeft|r ", resolve(1))
    describe("|cffaaaaaaRight|r", resolve(2))
    GameTooltip:Show()
end

-- ─── Row handlers ───────────────────────────────────────────────────────────

-- Re-pick the target at click time, skipping the dead and offline. Does
-- nothing in combat: SetAttribute is refused under lockdown, so the click uses
-- whatever was wired before the pull.
function Methods:RowPreClick(r, button)
    if InCombatLockdown() then return end
    local ms, df = r._members, r._def
    if not ms or not df then return end
    local engine = self.engine

    -- Write the spell from the pick EVERY time, not only when clearing it:
    -- setting just the unit left a button an earlier click had disarmed
    -- disarmed for good. Only an invalid target gives nil - PickTarget's
    -- second pass ignores range.
    if button == "LeftButton" then
        if not r._primary then
            r:SetAttribute("spell1", nil)
            return
        end
        local unit = engine:PickTarget(ms, df, r._groupMode)
        r:SetAttribute("spell1", unit and r._primary or nil)
        if unit then r:SetAttribute("unit1", unit) end
    else
        if not r._secondary then
            r:SetAttribute("spell2", nil)
            return
        end
        local unit = engine:PickTarget(ms, df, false)
        r:SetAttribute("spell2", unit and r._secondary or nil)
        if unit then r:SetAttribute("unit2", unit) end
    end
end

-- Re-arm, but only where there is still somewhere to cast: restoring the spell
-- unconditionally put it back while unit1 was the build-time "player"
-- fallback, so the next click - the first in combat, where PreClick cannot
-- re-aim - buffed yourself.
function Methods:RowPostClick(r)
    if InCombatLockdown() then return end
    local df, ms = r._def, r._members
    if not df or not ms then return end
    local engine = self.engine
    local pUnit = r._primary   and engine:PickTarget(ms, df, r._groupMode) or nil
    local sUnit = r._secondary and engine:PickTarget(ms, df, false) or nil
    r:SetAttribute("spell1", pUnit and r._primary or nil)
    r:SetAttribute("unit1",  pUnit or "player")
    r:SetAttribute("spell2", sUnit and r._secondary or nil)
    r:SetAttribute("unit2",  sUnit or "player")
    self:ScheduleRefresh()
end

-- Opens the popover over this row's current members and buff - read from the
-- row now, not captured when it was built.
function Methods:RowEnter(r)
    if not r._active or not r._members or not r._def then return end
    self:UpdatePopover(r, r._members, r._def)
    self:ShowClickHint(r)
end

-- The popover's own hide is the hover poll's job: an OnLeave would fire on the
-- way TO the popover. Dropping the tooltip here is right either way.
function Methods:RowLeave()
    self:HideClickHint()
end

-- ─── Visibility ─────────────────────────────────────────────────────────────

function Methods:IsVisible()
    return self.visible
end

function Methods:MainFrame()
    return self.main
end

local function SetVisible(self, visible)
    local was = self.visible
    self.visible = visible
    if was ~= visible then Call(self.host.onVisibility, self, visible) end
end

-- Close the window. `manual` means the player asked, which the addon saves.
-- Returns whether the frames are hidden NOW: in combat they cannot be, so the
-- window stops refreshing and goes when the fight ends. The addon can say so.
function Methods:Close(manual)
    if InCombatLockdown() then
        self.closePending = true
    else
        self.closePending = false
        if self.main then self.main:Hide() end
        if self.pop then self.pop:Hide() end
    end
    SetVisible(self, false)
    -- Cancel any show queued earlier: the player has since asked for the
    -- window to close, and honouring the older request would reopen it.
    self.pendingShow = false
    self.showGen = self.showGen + 1
    if manual then Call(self.host.setVisible, false) end
    return not self.closePending
end

-- Rebuild and show the window after `delay` seconds, unless it is closed in
-- the meantime. Everything that opens the window later goes through here, so
-- a close always wins over an older request.
function Methods:Open(delay)
    local gen = self.showGen
    After(delay or 0, function()
        if self.showGen ~= gen then return end
        self:Update()
    end)
end

-- Refresh an OPEN window, coalescing bursts of events into one rebuild. Never
-- opens a closed window.
function Methods:ScheduleRefresh()
    if self.refQueued or not self.visible then return end
    self.refQueued = true
    After(0.35, function()
        self.refQueued = false
        if not self.visible then return end
        if InCombatLockdown() then
            self:RefreshTimers()   -- visual only
        else
            self:Update()
        end
    end)
end

-- Combat is over: unpark, apply a reset asked for during the fight, and do the
-- rebuild combat deferred - including a show asked for while locked down.
function Methods:OnCombatEnd()
    if InCombatLockdown() then return end
    -- Everything the fight refused, in the order the player asked for it.
    if self.dragPending then self:DragStop() end
    if self.popHidePending then
        self.popHidePending = false
        if self.pop then self.pop:Hide() end
    end
    if self.closePending then
        self.closePending = false
        if self.main then self.main:Hide() end
        if self.pop then self.pop:Hide() end
    end
    if self.resetPending then self:ResetPosition() end
    if self.visible or self.pendingShow then
        self.pendingShow = false
        self:Open(0.2)
    end
end

-- ─── The full rebuild ───────────────────────────────────────────────────────

-- Rebuild and SHOW the window. In combat it only refreshes what is on screen
-- (secure attributes cannot be written) and remembers a show request for
-- when combat ends.
function Methods:Update()
    if InCombatLockdown() then
        if self.visible then
            self:RefreshTimers()
        else
            self.pendingShow = true
        end
        return
    end
    if not self:Init() then return end
    local engine = self.engine
    local main = self.main

    local groups, ord = engine:GatherGroups()
    if #ord == 0 then self:Close(); return end
    local defs = engine:ActiveDefs(groups, ord)
    if #defs == 0 then self:Close(); return end

    self:ApplyAppearance()

    for _, r in ipairs(self.rows) do r._active = false; r:Hide() end
    for _, h in ipairs(self.headers) do h:Hide() end

    local maxRows, maxGroups = #self.rows, #self.headers
    local rowIdx, hdrIdx = 0, 0
    local y = -(HDR_H + 6)
    local inRaid = IsInRaid()
    local PET_GROUP = lib.Engine.PET_GROUP

    for _, gNum in ipairs(ord) do
        if rowIdx >= maxRows then break end

        -- Each buff's members for this group, asked ONCE: the same list then
        -- drives the stats, the targets, the popover and the clicks, so they
        -- cannot disagree. A group where no buff covers anybody (Thorns on
        -- tanks, and this group has none) gets no header and no rows.
        local groupMembers = groups[gNum]
        local rowsHere = {}
        for _, def in ipairs(defs) do
            local members = engine:MembersFor(def, groupMembers)
            if #members > 0 then rowsHere[#rowsHere + 1] = { def = def, members = members } end
        end

        if #rowsHere > 0 and (inRaid or gNum >= PET_GROUP) then
            hdrIdx = hdrIdx + 1
            if hdrIdx <= maxGroups then
                local hdr = self.headers[hdrIdx]
                y = y - 1
                hdr:ClearAllPoints()
                hdr:SetPoint("TOPLEFT", main, "TOPLEFT", ROW_X + 2, y)
                if gNum >= PET_GROUP then
                    local n = gNum - PET_GROUP + 1
                    hdr:SetText(n > 1 and ("-- Pets " .. n .. " --") or "-- Pets --")
                else
                    hdr:SetText("-- Group " .. gNum .. " --")
                end
                hdr:Show()
                y = y - GRP_HDR_H
            end
        end

        for _, entry in ipairs(rowsHere) do
            local def, members = entry.def, entry.members
            do
                rowIdx = rowIdx + 1
                if rowIdx > maxRows then break end
                local r = self.rows[rowIdx]
                local st = engine:GroupStat(members, def)
                local primary, secondary = engine:ClickSpells(def)
                local groupMode = def.hasGroup and true or false
                local primaryUnit   = primary   and engine:PickTarget(members, def, groupMode, st) or nil
                local secondaryUnit = secondary and engine:PickTarget(members, def, false, st) or nil

                r:ClearAllPoints()
                r:SetPoint("TOPLEFT", main, "TOPLEFT", ROW_X, y)
                r:SetSize(ROW_W, ROW_H)
                r.icon:SetTexture(lib.API.SpellIcon(def.hasSingle and def.snglID or def.grpID, def.fallbackIcon))

                r._active    = true
                r._members   = members
                r._def       = def
                r._primary   = primary
                r._secondary = secondary
                r._groupMode = groupMode
                r._gNum      = gNum

                self:ApplyRowVisuals(r, st)

                -- Left: the group spell on whoever needs it most (it covers
                -- their subgroup; a pet row spans several), or the single one
                -- when there is no group spell. Right: the single spell on
                -- whoever needs it most.
                r:SetAttribute("type1",  "spell")
                r:SetAttribute("spell1", primaryUnit and primary or nil)
                r:SetAttribute("unit1",  primaryUnit or "player")
                r:SetAttribute("type2",  "spell")
                r:SetAttribute("spell2", secondaryUnit and secondary or nil)
                r:SetAttribute("unit2",  secondaryUnit or "player")

                r:Show()
                y = y - ROW_H - 1
            end
        end
    end

    -- Every buff filtered down to nobody: there is nothing to show.
    if rowIdx == 0 then self:Close(); return end

    y = y - 2
    y = self:LayoutFooter(y)

    main:SetSize(FRAME_W, math.abs(y) + 2)

    if not self.moved and not main:IsShown() then
        main:ClearAllPoints()
        local p, why
        if self.host.getPos then p, why = self.host.getPos() end
        if p then
            main:SetPoint(p.point or DEFAULT_POS.point, UIParent, p.relPoint or DEFAULT_POS.relPoint,
                p.x or DEFAULT_POS.x, p.y or DEFAULT_POS.y)
            self.moved = true
            self.restoreLog = string.format("applied saved %s/%s %.1f,%.1f",
                tostring(p.point), tostring(p.relPoint), tonumber(p.x) or 0/0, tonumber(p.y) or 0/0)
        else
            main:SetPoint(DEFAULT_POS.point, UIParent, DEFAULT_POS.relPoint, DEFAULT_POS.x, DEFAULT_POS.y)
            self.restoreLog = "used the DEFAULT - " .. tostring(why or "no saved position")
        end
    else
        self.restoreSkips = self.restoreSkips + 1
    end

    main:Show()
    SetVisible(self, true)
    Call(self.host.setVisible, true)
    Call(self.host.onLayout, self)

    -- A rebuild rewires the rows but not an open popover, whose members and
    -- attributes still name the previous roster's unit tokens - and a row's
    -- OnEnter does not fire again while the mouse rests on it.
    local pop = self.pop
    if pop:IsShown() and not self.popHidePending then
        local anchor = pop._anchorRow
        if anchor and anchor._active and anchor._members and anchor._def then
            self:UpdatePopover(anchor, anchor._members, anchor._def)
        else
            pop:Hide()    -- the row it belonged to is gone
        end
    end
end

-- Last, so a file that threw partway through is not marked installed.
lib.uiMinor = MINOR
