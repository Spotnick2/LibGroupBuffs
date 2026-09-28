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
--         onCloseDeferred = function(ui) end,   -- optional: combat refused the hide
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
local MAJOR, MINOR = "LibGroupBuffs-1.0", 19
local lib, active = LibStub:GetLibrary(MAJOR, true)
if not lib or active ~= MINOR then return end
if lib.uiMinor == MINOR then return end

lib.UI = lib.UI or {}
lib.UIMethods = lib.UIMethods or {}
lib.UIMeta = lib.UIMeta or {}
local UI, Methods = lib.UI, lib.UIMethods
lib.UIMeta.__index = Methods

-- ─── Layout ─────────────────────────────────────────────────────────────────

-- Sized for the glass material rather than for the Blizzard backdrop it
-- replaced. Two things drive these numbers:
--
--   * the rounded corners. A row's mask has an 8px radius, so a row shorter
--     than about twice that has its corners squeezed flat and the fill reads
--     as a painted rectangle again - which is exactly how the first pass at
--     15px looked in game.
--   * the icon. A buff icon at 16px next to 10px text is a toolbar; the rows
--     are what the addon is read at a glance, and they are now legible from
--     a raid frame's distance.
local ICON_W     = 24
local BAR_W      = 99
local ROW_H      = 26
local ROW_W      = ICON_W + BAR_W       -- 123
local GRP_HDR_H  = 16
local FRAME_W    = ROW_W + 12           -- 135
local ROW_X      = 5
local HDR_H      = 30                   -- styled header bar height
local FTR_H      = 22                   -- reagent footer height
-- Wide enough for a full Forever name: characters have surnames, and first
-- names are not unique, so the whole name has to fit.
local POP_W      = 250
local POP_ROW_H  = 30
local POP_HDR_H  = 30

-- Text. The client's own Arial Narrow reads closer to the mock-up than Friz
-- Quadrata, and the material's notes make the same choice for the same
-- reason. Sized against the row rather than fixed, so a change to ROW_H does
-- not leave the text where it was.
local FONT_FILE  = "Fonts\\ARIALN.TTF"
local ROW_FONT   = 13
local NAME_FONT  = 14
local TITLE_FONT = 16
local GRP_FONT   = 11
local EM         = "\226\128\148"   -- an em dash, as UTF-8 bytes

-- The slice margin the bar textures are DRAWN for. Glass.lua's own header
-- says margins are in texture pixels and must match the generator, and the
-- generator makes bar_mask and bar_edge at 32px with a radius of 5 and
-- margins of 8. Scaling the margin down to fit a small box - which this file
-- did for one build - cuts through the corner arc itself, so the corners come
-- out part straight edge: a second wrong thing, hiding behind the first. A
-- box too small to hold 8 on each side cannot use these sliced at all, and
-- the suite fails on one rather than letting it draw wrong.
local BAR_SLICE = 8

-- A small rounded icon tile.
--
-- Four explanations for the icons rendering as a sliver were deployed and
-- none of them was it. What settled it was an experiment rather than a fifth
-- guess: the window draws five of these and they are all on screen together,
-- so each call site got a different arrangement and one screenshot answered.
-- No mask drew a whole square icon; an unsliced mask drew a whole rounded
-- one; both sliced cells failed, and differed from the working one ONLY in
-- being sliced.
--
-- The tile keeps a frame of its own. That was built to test one of the wrong
-- theories, but it earns its place anyway: SetAllPoints on a frame is how the
-- mask gets its rectangle without an anchor whose sign has to be reasoned
-- about, and it is the same shape as the row fills, which have been right
-- from the first build.
local function IconTile(parent, size, point, relTo, relPoint, x, y)
    local box = CreateFrame("Frame", nil, parent)
    box:SetSize(size, size)
    box:SetPoint(point or "LEFT", relTo or parent, relPoint or "LEFT", x or 0, y or 0)

    local tile = box:CreateTexture(nil, "ARTWORK")
    tile:SetAllPoints(box)

    -- The mask is NOT sliced, and that is the whole of it. A sliced
    -- MaskTexture on a box this small draws a fragment of the masked art in
    -- the top-left corner of the shape and nothing else. The same asset
    -- SLICED is right on a row's fill at 123x26, and in GlassUnitFrames on
    -- power bars 300x12 and 330x7 - so it is not about being short. Every
    -- case that fails is small in BOTH directions (16 to 22 square); which
    -- axis actually decides has not been measured.
    --
    -- Unsliced, the 32px asset is scaled to the tile, which leaves a corner
    -- radius of about 2.5px at 20px - right for something this small, so
    -- nothing is given up by not slicing it. The client's icons carry a
    -- border in their outer few percent, and the rounding eats its corners;
    -- cropping the rest with SetTexCoord is NOT the way to remove it, because
    -- a mask is applied in the texture's untransformed space.
    local mask = box:CreateMaskTexture()
    mask:SetTexture(lib.Glass.MEDIA .. "bar_mask",
                    "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(box)
    tile:AddMaskTexture(mask)

    local edge = box:CreateTexture(nil, "OVERLAY")
    edge:SetAllPoints(box)
    edge:SetTexture(lib.Glass.MEDIA .. "bar_edge")
    edge:SetTextureSliceMargins(BAR_SLICE, BAR_SLICE, BAR_SLICE, BAR_SLICE)
    local modes = Enum and Enum.UITextureSliceMode
    edge:SetTextureSliceMode((modes and modes.Stretched) or 0)

    return tile, edge, mask, box
end

-- Text over glass needs its own shadow: the panel behind it is translucent,
-- so a light letter can land on a light patch of the world.
local function Style(fs, size, justify)
    fs:SetFont(FONT_FILE, size, "")
    fs:SetShadowColor(0, 0, 0, 0.9)
    fs:SetShadowOffset(1, -1)
    if justify then fs:SetJustifyH(justify) end
    return fs
end

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

-- How far a tooltip sits off the row it describes. ANCHOR_RIGHT measures from
-- the ROW, which is inset from the panel edge and inset again from the glass
-- shadow around it - so with no offset the tooltip lands ON the window it is
-- describing. This is that inset plus a gap.
local TIP_GAP = 16

-- The client's tooltip is sized for the default UI, which is bigger than this
-- window: at full size it reads as a different addon's panel parked next to
-- ours. GameTooltip is SHARED, so the scale is put back whenever we let go of
-- it - leaving it at 0.8 would shrink every other addon's tooltips too.
local TIP_SCALE = 0.8

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
    popDivider = { 0.32, 0.32, 0.55, 0.55 },    -- under the popover's header
    groupText  = { 0.52, 0.52, 0.70 },
}) do
    local t = UI.DEFAULT_APPEARANCE[key] or {}
    UI.DEFAULT_APPEARANCE[key] = t
    for i = 1, 4 do t[i] = colour[i] end
end

-- One ladder for what a member's state looks like, wherever it is drawn: the
-- row's MISS, the popover row's timer text and the combat list. Kept in one
-- place because two of them had already drifted apart.
UI.STATE_COLOUR = UI.STATE_COLOUR or {}
for key, colour in pairs({
    MISS    = { 1.00, 0.28, 0.28 },
    UNKNOWN = { 0.65, 0.65, 0.65 },
    OFFLINE = { 0.50, 0.50, 0.50 },
}) do
    local t = UI.STATE_COLOUR[key] or {}
    UI.STATE_COLOUR[key] = t
    for i = 1, 3 do t[i] = colour[i] end
end
local COLOUR = UI.STATE_COLOUR

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
    "getPos", "setPos", "setVisible", "onLayout", "onVisibility", "onCloseDeferred",
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

-- ─── The glass material ──────────────────────────────────────────────────────
--
-- Glass.lua draws it; this decides where. A panel is the window and the
-- popover; a fill is one coloured row inside them. The material is layered
-- textures, not a shader - what it cannot do is blur what is behind it, so
-- the world shows through sharp. See Glass.lua and its upstream write-up.
--
-- Nothing here is conditional on combat: every layer is created once, when the
-- frame is built, and afterwards only colours and values change. Adding a
-- texture to a protected frame is not one of the calls this client refuses.
-- Made on demand, for the same reason a fill is: Init() returns early when
-- the frames already exist, so a window built by r16 would keep its dialog
-- backdrop for the rest of the session while its rows turned to glass. The
-- old backdrop is removed rather than left underneath, where it would show
-- through the glass as a dark rectangle with square corners.
--
-- Not in combat: this frame parents secure buttons, and while the textures
-- themselves are free, there is no reason to find out which of these calls
-- the client refuses under lockdown. It is retried on the next refresh.
local function Panel(f)
    if type(f.glass) == "table" then return f.glass end
    if InCombatLockdown() then return nil end
    if f.SetBackdrop then f:SetBackdrop(nil) end
    f.glass = lib.Glass.Apply(f, "large")
    return f.glass
end

-- A row's colour is its whole meaning - green has it, red does not - so the
-- fill is a flat colour under the same gloss, mask and edge the material
-- gives a bar, rather than a bar that moves.
--
-- Drawn ON THE ROW, not in a child frame. A child draws above its parent's
-- regions whatever their draw layers say, so a StatusBar fill put its gloss
-- over the class icon and washed it green - measured in game, not reasoned
-- about. Textures on the row itself sit under everything the row draws.
--
-- Made on demand rather than in MakeRow, because of how this library
-- upgrades: LibStub hands these methods the frames an older copy built, and a
-- row from r16 has a flat background texture and none of this. Rows are built
-- once per session, so the cost is one check per row per refresh - and this
-- is the only place a fill is made, because a second one built eagerly would
-- be a path no test could fail.
local FILL_MASK_MARGIN = 8

-- rawget, and a tag of our own: asking a FRAME whether it has SetColour gets
-- an answer either way - the client's frames have metatables, and the test
-- stub answers any unknown method with a callable. Either would have said
-- "this row already has one of ours" about r17's StatusBar.
local FILL_TAG = "glassFill"

local function Fill(row, height)
    if type(row.fill) == "table" and rawget(row.fill, FILL_TAG) then return row.fill end
    if InCombatLockdown() then return nil end

    -- r17 put the fill in a child StatusBar. Replacing the reference is not
    -- enough: that frame is still parented to the row and still drawing its
    -- gloss over the icon this change exists to uncover, and a frame cannot
    -- be destroyed on this client. A FRAME has Hide; the table this builds
    -- does not, which is what tells the two apart.
    local previous = row.fill
    if type(previous) == "table" and not rawget(previous, FILL_TAG)
        and type(previous.Hide) == "function" then
        previous:Hide()
    end

    local Glass = lib.Glass
    local st = Glass.STYLE
    local mask = Glass.Mask(row, "bar_mask", FILL_MASK_MARGIN)

    local bg = row:CreateTexture(nil, "BACKGROUND", nil, 1)
    bg:SetAllPoints(row)
    bg:SetColorTexture(1, 1, 1, 1)
    bg:AddMaskTexture(mask)

    local gloss = row:CreateTexture(nil, "BACKGROUND", nil, 2)
    gloss:SetAllPoints(row)
    gloss:SetTexture(Glass.MEDIA .. "gloss")
    gloss:SetBlendMode("ADD")
    gloss:SetAlpha(st.gloss)
    gloss:AddMaskTexture(mask)

    -- Light passing through the slab catches on the inner lip at the bottom.
    local inner = row:CreateTexture(nil, "BACKGROUND", nil, 3)
    inner:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT")
    inner:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT")
    inner:SetHeight(math.max(3, math.floor((height or 15) * 0.45)))
    inner:SetColorTexture(1, 1, 1, 1)
    inner:SetGradient("VERTICAL", CreateColor(0, 0, 0, st.innerShadow), CreateColor(0, 0, 0, 0))
    inner:AddMaskTexture(mask)

    local edge = row:CreateTexture(nil, "BORDER")
    edge:SetAllPoints(row)
    edge:SetTexture(Glass.MEDIA .. "bar_edge")
    edge:SetTextureSliceMargins(FILL_MASK_MARGIN, FILL_MASK_MARGIN,
                                FILL_MASK_MARGIN, FILL_MASK_MARGIN)
    local modes = Enum and Enum.UITextureSliceMode
    edge:SetTextureSliceMode((modes and modes.Stretched) or 0)

    local fill = { mask = mask, bg = bg, gloss = gloss, inner = inner, edge = edge,
                   [FILL_TAG] = true }
    function fill:SetColour(r, g, b, a) self.bg:SetColorTexture(r, g, b, a) end
    function fill:Colour() return self.bg._colorTexture end

    -- The older copy's flat background would otherwise show through the
    -- rounded corners of this one.
    if type(row.bg) == "table" and row.bg.SetColorTexture then
        row.bg:SetColorTexture(0, 0, 0, 0)
    end
    row.fill = fill
    return fill
end

-- Below Fill, which it calls: a local declared later is a GLOBAL inside a
-- function written above it. In combat there is no fill yet and nothing to
-- colour; the next refresh out of combat builds it.
local function SetFill(row, height, r, g, b, a)
    local fill = Fill(row, height)
    if fill then fill:SetColour(r, g, b, a) end
end

-- How much of the host's header colour survives. The header was the last flat
-- thing on the window: an opaque band with square corners sitting on a
-- translucent, round-cornered panel, which read as a title bar from a
-- different addon. Here the host still chooses the HUE - Wildly's orange,
-- Magely's per-spec - and the material chooses how solid it is, the same
-- bargain TintPanel already makes for the panel itself.
local HDR_TAG   = "glassHeader"
local HDR_TINT  = 0.30

local function HeaderGlass(main)
    if type(main.hdr) == "table" and rawget(main.hdr, HDR_TAG) then return main.hdr end
    if InCombatLockdown() then return nil end
    local tint = main.hdrBg
    if type(tint) ~= "table" or not tint.AddMaskTexture then return nil end

    -- hdrBg itself becomes the tint, rather than a second band drawn over it:
    -- an older copy upgrading in place already has this texture, and two of
    -- them would simply add up.
    --
    -- Not masked, and not for a good reason: it was unmasked while chasing
    -- the icon bug, on a theory about sibling-anchored masks that did not hold
    -- up. At 127x30 this band is the size class where a sliced mask works, so
    -- rounding it is available - it would want its own frame, the shape Fill
    -- uses, and a screenshot to confirm. Left as it is because it reads
    -- correctly: the band is inset 4px inside a panel that is already
    -- rounded, so its own corners barely show, and the gloss is what makes it
    -- glass rather than the corners.
    local Glass = lib.Glass
    local gloss = main:CreateTexture(nil, "ARTWORK", nil, 2)
    gloss:SetAllPoints(tint)
    gloss:SetTexture(Glass.MEDIA .. "gloss")
    gloss:SetBlendMode("ADD")
    gloss:SetAlpha(Glass.STYLE.gloss)

    local hdr = { tint = tint, gloss = gloss, [HDR_TAG] = true }
    main.hdr = hdr
    return hdr
end

-- An older copy's icon is a bare texture on the frame, and a texture cannot
-- be destroyed on this client. It is emptied and hidden, its image handed to
-- the tile that replaces it, and the reference moved on.
local function ReplaceIcon(old, tile)
    if type(old) ~= "table" or old == tile then return end
    if old.GetTexture and tile.SetTexture then tile:SetTexture(old:GetTexture()) end
    if old.SetTexture then old:SetTexture(nil) end
    if old.Hide then old:Hide() end
end

-- This version's geometry, applied to a row whether it was built a moment ago
-- or by an older copy upgrading in place. Separate from MakeRow because
-- frames are built ONCE: Init returns early when self.main exists, so a
-- window an r18 copy made would otherwise keep 15px rows, a bare 14px icon
-- and the old font under r19's code. Everything here is idempotent - anchors
-- are cleared before they are set, fonts are set again, and the icon tile is
-- built only if there is not already one.
local function StyleRow(r)
    r:SetSize(ROW_W, ROW_H)

    -- A table, not merely present: the test stub answers any unknown field
    -- with a no-op method, so `if not r.iconEdge` is true on a fresh row in
    -- game and false under test - which would leave every tested row without
    -- the tile this is here to build.
    if type(r.iconEdge) ~= "table" then
        local old = r.icon
        r.icon, r.iconEdge = IconTile(r, ROW_H - 6, "LEFT", r, "LEFT", 3, 0)
        ReplaceIcon(old, r.icon)
    end

    Style(r.timer, ROW_FONT, "RIGHT")
    r.timer:ClearAllPoints()
    r.timer:SetPoint("RIGHT", r, "RIGHT", -6, 0)

    Style(r.missCount, ROW_FONT, "LEFT")
    r.missCount:ClearAllPoints()
    r.missCount:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
    r.missCount:SetTextColor(1.0, 1.0, 1.0)

    Style(r.missAll, ROW_FONT, "RIGHT")
    r.missAll:ClearAllPoints()
    r.missAll:SetPoint("RIGHT", r, "RIGHT", -6, 0)
    r.missAll:SetTextColor(unpack(COLOUR.MISS))
    r.missAll:SetText("MISS")
end

local function MakeRow(ui, parent, i)
    local r = CreateFrame("Button", nil, parent, "SecureActionButtonTemplate")
    r._ui = ui
    r:EnableMouse(true)
    r:RegisterForClicks(lib.API.ClickEdges())

    r.timer     = r:CreateFontString(nil, "OVERLAY")
    r.missCount = r:CreateFontString(nil, "OVERLAY")
    r.missAll   = r:CreateFontString(nil, "OVERLAY")
    StyleRow(r)

    r:SetScript("PreClick",  function(self, button) return self._ui:RowPreClick(self, button) end)
    r:SetScript("PostClick", function(self, button) return self._ui:RowPostClick(self, button) end)
    r:SetScript("OnEnter",   function(self) return self._ui:RowEnter(self) end)
    r:SetScript("OnLeave",   function(self) return self._ui:RowLeave(self) end)

    r._active = false
    r:Hide()
    return r
end

-- As StyleRow, for a popover row. `i` is its place in the pool, which decides
-- where it sits.
local function StylePopRow(pr, i)
    pr:SetSize(POP_W - 10, POP_ROW_H)
    pr:ClearAllPoints()
    pr:SetPoint("TOPLEFT", pr:GetParent(), "TOPLEFT",
        5, -(POP_HDR_H + 5) - (i - 1) * (POP_ROW_H + 2))

    Style(pr.rangeTxt, ROW_FONT, "CENTER")
    pr.rangeTxt:ClearAllPoints()
    pr.rangeTxt:SetPoint("LEFT", pr, "LEFT", 4, 0)
    pr.rangeTxt:SetWidth(14)

    if type(pr.classEdge) ~= "table" then
        local old = pr.classIcon
        pr.classIcon, pr.classEdge =
            IconTile(pr, POP_ROW_H - 8, "LEFT", pr.rangeTxt, "RIGHT", 4, 0)
        ReplaceIcon(old, pr.classIcon)
    end

    Style(pr.nameTxt, NAME_FONT, "LEFT")
    pr.nameTxt:ClearAllPoints()
    pr.nameTxt:SetPoint("LEFT",  pr.classIcon, "RIGHT", 5,  0)
    pr.nameTxt:SetPoint("RIGHT", pr,           "RIGHT", -46, 0)

    Style(pr.timeTxt, ROW_FONT, "RIGHT")
    pr.timeTxt:ClearAllPoints()
    pr.timeTxt:SetPoint("RIGHT", pr, "RIGHT", -5, 0)
    pr.timeTxt:SetWidth(42)
end

local function MakePopRow(ui, parent, i)
    local pr = CreateFrame("Button", nil, parent, "SecureActionButtonTemplate")
    pr._ui = ui
    pr:EnableMouse(true)
    pr:RegisterForClicks(lib.API.ClickEdges())
    pr:SetFrameLevel(202)  -- above the popover's level 200

    pr.rangeTxt = pr:CreateFontString(nil, "OVERLAY")
    pr.nameTxt  = pr:CreateFontString(nil, "OVERLAY")
    pr.timeTxt  = pr:CreateFontString(nil, "OVERLAY")
    StylePopRow(pr, i)

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

    btn.icon, btn.iconEdge = IconTile(btn, FTR_H - 4, "LEFT", btn, "LEFT", 0, 0)

    btn.countTxt = Style(btn:CreateFontString(nil, "OVERLAY"), ROW_FONT, "LEFT")
    btn.countTxt:SetPoint("LEFT", btn.icon, "RIGHT", 4, 0)

    btn:SetScript("OnEnter", function(self) return self._ui:FooterEnter(self) end)
    btn:SetScript("OnLeave", function(self) return self._ui:FooterLeave(self) end)
    btn:Hide()
    return btn
end

-- Built here rather than from UIPanelCloseButton: that one is a Blizzard
-- gold-and-red disc, which on a glass panel reads as a sticker from another
-- addon. This is the same rounded, sliced edge the rows use, with an x drawn
-- in the panel's own text colour.
--
-- The hover handlers dispatch through the ui object like every other handler
-- in this file. Handlers are installed once and the frames outlive an
-- upgrade, so a closure that recolours the label itself would keep doing
-- exactly what r19 decided, in a window a later copy is otherwise driving.
local function MakeCloseButton(ui, main)
    local xBtn = CreateFrame("Button", nil, main)
    xBtn._ui = ui
    xBtn:SetSize(HDR_H - 12, HDR_H - 12)
    xBtn:SetPoint("TOPRIGHT", main, "TOPRIGHT", -6, -6)
    xBtn:EnableMouse(true)

    local xEdge = xBtn:CreateTexture(nil, "OVERLAY")
    xEdge:SetAllPoints(xBtn)
    xEdge:SetTexture(lib.Glass.MEDIA .. "bar_edge")
    xEdge:SetTextureSliceMargins(BAR_SLICE, BAR_SLICE, BAR_SLICE, BAR_SLICE)
    local xModes = Enum and Enum.UITextureSliceMode
    xEdge:SetTextureSliceMode((xModes and xModes.Stretched) or 0)

    local xTxt = Style(xBtn:CreateFontString(nil, "OVERLAY"), ROW_FONT, "CENTER")
    xTxt:SetPoint("CENTER", xBtn, "CENTER", 0, 0)
    xTxt:SetText("\195\151")
    xBtn.label = xTxt

    xBtn:SetScript("OnEnter", function(b) return b._ui:CloseButtonHover(b, true) end)
    xBtn:SetScript("OnLeave", function(b) return b._ui:CloseButtonHover(b, false) end)
    xBtn:SetScript("OnClick", function(b) return b._ui:Close(true) end)
    ui:CloseButtonHover(xBtn, false)
    return xBtn
end

-- This version's header, on a window built a moment ago or by an older copy.
-- Same rules as StyleRow: idempotent, and the tile only if there is not one.
local function StyleHeader(main)
    main.hdrBg:SetHeight(HDR_H)

    if type(main.specEdge) ~= "table" then
        local old = main.specIcon
        main.specIcon, main.specEdge =
            IconTile(main, HDR_H - 10, "LEFT", main.hdrBg, "LEFT", 5, 0)
        ReplaceIcon(old, main.specIcon)
    end

    Style(main.title, TITLE_FONT, "LEFT")
    main.title:ClearAllPoints()
    main.title:SetPoint("LEFT", main.specIcon, "RIGHT", 5, 0)

    Style(main.version, GRP_FONT, "LEFT")
    main.version:ClearAllPoints()
    main.version:SetPoint("LEFT", main.title, "RIGHT", 3, -1)
end

-- Build the frames, once. Refused in combat: secure buttons cannot be created
-- under lockdown. Returns whether the frames exist.
function Methods:Init()
    if self.main then return true end
    if InCombatLockdown() then return false end
    local nGroups, nRows, nPop = self:Capacity()
    self.capacity = { groups = nGroups, rows = nRows, popRows = nPop }

    -- ── Main frame ──────────────────────────────────────────────────────
    local main = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    main._ui = self
    self.main = main
    main:SetFrameStrata("HIGH")
    main:SetClampedToScreen(true)
    main:SetMovable(true)
    Panel(main)
    main:Hide()

    local hdrBg = main:CreateTexture(nil, "ARTWORK")
    hdrBg:SetPoint("TOPLEFT",  main, "TOPLEFT",  4, -4)
    hdrBg:SetPoint("TOPRIGHT", main, "TOPRIGHT", -4, -4)
    hdrBg:SetHeight(HDR_H)
    main.hdrBg = hdrBg

    local hdrLine = main:CreateTexture(nil, "ARTWORK")
    hdrLine:SetHeight(1)
    hdrLine:SetPoint("TOPLEFT",  hdrBg, "BOTTOMLEFT",  0, 0)
    hdrLine:SetPoint("TOPRIGHT", hdrBg, "BOTTOMRIGHT", 0, 0)
    main.hdrLine = hdrLine

    main.title   = main:CreateFontString(nil, "OVERLAY")
    main.version = main:CreateFontString(nil, "OVERLAY")
    StyleHeader(main)
    main.title:SetText(self.host.title or self.host.owner)
    main.version:SetText(self.host.version and ("|cff555577" .. self.host.version .. "|r") or "")

    main.closeBtn = MakeCloseButton(self, main)

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
        -- Centred across the whole row, not left-aligned next to it: the
        -- separators are the only thing breaking the run of coloured bars,
        -- and a label tucked against the left edge does not read as a break.
        local fs = Style(main:CreateFontString(nil, "OVERLAY"), GRP_FONT, "CENTER")
        fs:SetWidth(ROW_W)
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
    Panel(pop)
    -- No EnableMouse, so the secure child buttons receive the clicks.
    pop:Hide()

    pop.hdrIcon, pop.hdrEdge = IconTile(pop, POP_HDR_H - 10, "TOPLEFT", pop, "TOPLEFT", 7, -6)

    pop.hdrTxt = Style(pop:CreateFontString(nil, "OVERLAY"), NAME_FONT, "LEFT")
    pop.hdrTxt:SetPoint("LEFT",  pop.hdrIcon, "RIGHT", 6, 0)
    pop.hdrTxt:SetPoint("RIGHT", pop,         "RIGHT", -6, 0)
    pop.hdrTxt:SetPoint("TOP",   pop,         "TOP",   0, -8)
    pop.hdrTxt:SetJustifyH("LEFT")
    pop.hdrTxt:SetTextColor(1.0, 0.82, 0.22)

    self:PopDivider()

    for i = 1, nPop do self.popRows[i] = MakePopRow(self, pop, i) end

    -- Hover polling hides the popover once the mouse is over neither it nor
    -- its row. It replaced OnLeave handlers, which fire on the way TO the
    -- popover.
    pop._hoverTimer = 0
    pop:SetScript("OnUpdate", function(p, dt) return p._ui:PopoverTick(dt) end)

    -- ── Footer ──────────────────────────────────────────────────────────
    main.ftrLine = main:CreateTexture(nil, "ARTWORK")
    main.ftrLine:SetHeight(1)
    main.ftrLine:Hide()

    -- ── Ticker ──────────────────────────────────────────────────────────
    main:SetScript("OnUpdate", function(m, dt) return m._ui:MainTick(dt) end)

    -- Colours and icon: the one place they are applied, so a new appearance
    -- key cannot be applied at build time and forgotten on a change, or the
    -- reverse.
    self:ApplyAppearance()
    return true
end

-- Where the divider sits: the one thing that identifies it among the
-- popover's regions.
local DIVIDER_X, DIVIDER_Y = 5, -(POP_HDR_H + 2)

-- Where earlier copies put it. The search below is by POSITION - it is the
-- only handle on a texture a pre-r11 copy kept in a local - so every header
-- height this library has shipped has to be listed, or the divider a running
-- copy already built is missed and a second one is drawn over it. r17 and
-- earlier used a 24px header; r19 made it 30 for the glass layout.
local DIVIDER_YS = { DIVIDER_Y, -(24 + 2) }

-- A divider an older copy of the library (before r11) built. It drew the same
-- line but kept it in a local, so the only way to reach it is by where it is:
-- a texture whose first anchor is the popover's TOPLEFT at the divider's
-- offset. Reading regions and anchors is not a protected call.
local function FindOlderDivider(pop)
    for _, r in ipairs({ pop:GetRegions() }) do
        if r ~= pop.hdrIcon and r:GetObjectType() == "Texture" then
            local point, relativeTo, _, x, y = r:GetPoint()
            if point == "TOPLEFT" and relativeTo == pop and x == DIVIDER_X then
                for _, known in ipairs(DIVIDER_YS) do
                    if y == known then return r end
                end
            end
        end
    end
end

-- The line under the popover's header. Not only built in Init: frames are
-- built once, so a window an older copy made reaches this one with a divider
-- nothing here holds. That line is ADOPTED, never drawn over - a second
-- half-opaque line in the same place would blend the addon's colour with the
-- old one. Only a window with no divider at all gets one built, and not in
-- combat: the popover parents secure buttons, and adding a region to a
-- protected frame under lockdown has not been measured, so the next rebuild
-- after the fight comes back here. Underscored, so it reads nil when absent
-- in the client and the test stub alike (the stub answers any other name
-- with a method).
function Methods:PopDivider()
    local pop = self.pop
    if not pop then return nil end
    if pop._hdiv then return pop._hdiv end
    local older = FindOlderDivider(pop)
    if older then
        pop._hdiv = older
        return older
    end
    if InCombatLockdown() then return nil end
    local hdiv = pop:CreateTexture(nil, "ARTWORK")
    hdiv:SetHeight(1)
    hdiv:SetPoint("TOPLEFT",  pop, "TOPLEFT",  DIVIDER_X, DIVIDER_Y)
    hdiv:SetPoint("TOPRIGHT", pop, "TOPRIGHT", -DIVIDER_X, DIVIDER_Y)
    pop._hdiv = hdiv
    return hdiv
end

-- ─── Visuals ────────────────────────────────────────────────────────────────

function Methods:ApplyRowVisuals(r, st)
    local dur = st.minDur or 3600
    local pct = UI.Pct(st.minR, dur)

    -- Flat colours matching PallyPower: green when everyone has it, yellow
    -- when some are missing it, red when nobody does - and grey when it cannot
    -- be read at all.
    -- The same four states as before, now as the fill's colour. Alpha is
    -- higher than the flat version used: the bar sits on glass rather than on
    -- an opaque dialog background, and a faint fill over a translucent panel
    -- reads as neither colour.
    if st.nUnknown == st.nTotal then
        SetFill(r, ROW_H, 0.30, 0.30, 0.30, 0.75)
    elseif st.allHave then
        SetFill(r, ROW_H, 0.10, 0.65, 0.20, 0.80)
    elseif st.nMiss == st.nTotal then
        SetFill(r, ROW_H, 0.70, 0.13, 0.13, 0.80)
    else
        SetFill(r, ROW_H, 0.75, 0.55, 0.10, 0.80)
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
        r.missAll:SetTextColor(unpack(COLOUR.UNKNOWN))
        r.missAll:Show()
    elseif st.nMiss == st.nTotal then
        r.missAll:SetText("MISS")
        r.missAll:SetTextColor(unpack(COLOUR.MISS))
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
        SetFill(pr, POP_ROW_H, 0.30, 0.30, 0.30, 0.75)   -- offline
    elseif state == S.UNKNOWN then
        SetFill(pr, POP_ROW_H, 0.30, 0.30, 0.30, 0.65)   -- unreadable
    elseif has then
        SetFill(pr, POP_ROW_H, 0.10, 0.65, 0.20, 0.80)   -- buffed
    else
        SetFill(pr, POP_ROW_H, 0.70, 0.13, 0.13, 0.80)   -- missing
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
        pr.timeTxt:SetTextColor(unpack(COLOUR.UNKNOWN))
    else
        pr.timeTxt:SetText("MISS")
        pr.timeTxt:SetTextColor(unpack(COLOUR.MISS))
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
    -- In combat the hint's list of who needs the buff is the only per-member
    -- view there is, and OnEnter does not fire again while the mouse rests on
    -- the row - so buff somebody and the tooltip would still call them
    -- missing. Redraw it here, the same reason a rebuild re-drives the
    -- popover. Out of combat the popover is open and shows this live.
    if InCombatLockdown() and self.hintRow and self.hintRow._active
        and lib.API.IsMouseOver(self.hintRow)
    then
        self:ShowClickHint(self.hintRow)
    end
end

-- Colours and icon, re-read from the addon. Backdrop opacity only, never the
-- frame's own alpha.
-- The glass tint IS the panel's colour and opacity now, so the host's
-- settings have to land there: the backdrop those values used to colour is
-- gone, and leaving them pointed at it made the opacity slider do nothing.
--
-- The material's own tint alpha is what its author settled on for a panel at
-- full opacity, so the host's alpha scales it rather than replacing it - at
-- 100% it looks as the material intends, and below that it thins out.
local function TintPanel(f, colour, alpha)
    local g = Panel(f)
    if not g or not g.tint then return end
    local base = lib.Glass.STYLE.tint
    g.tint:SetColorTexture(colour[1], colour[2], colour[3], base[4] * (alpha or 1))
end

-- The rim is where each addon's border colour went, and it is the one layer
-- that can carry it: the tint is the body, the dark rim is the shadow side.
-- Multiplied into the texture rather than replacing it, so the light stays
-- where the material puts it - concentrated on the top edge, which is what
-- reads as glass rather than as a bezel - and only its hue changes. Alpha is
-- left alone for the same reason.
local function RimColour(f, colour)
    local g = Panel(f)
    if not g or not g.rim or not colour then return end
    g.rim:SetVertexColor(colour[1], colour[2], colour[3])
end

-- Ours while we own it, the way we found it afterwards.
local function OwnTooltip(owner, anchor, xOff)
    if GameTooltip._lgbScale == nil then
        GameTooltip._lgbScale = GameTooltip:GetScale() or 1
    end
    GameTooltip:SetOwner(owner, anchor, xOff or 0, 0)
    GameTooltip:SetScale(TIP_SCALE)
end

local function ReleaseTooltip()
    GameTooltip:Hide()
    if GameTooltip._lgbScale then
        GameTooltip:SetScale(GameTooltip._lgbScale)
        GameTooltip._lgbScale = nil
    end
end

function Methods:ApplyAppearance()
    if not self.main then return end
    local look = self:Appearance()
    local alpha = self:Alpha()
    local main, pop = self.main, self.pop
    TintPanel(main, look.mainBg, alpha)
    RimColour(main, look.border)
    local hdr = HeaderGlass(main)
    local hc = look.header
    main.hdrBg:SetColorTexture(hc[1], hc[2], hc[3],
        (hc[4] or 1) * (hdr and HDR_TINT or 1))
    main.hdrLine:SetColorTexture(unpack(look.headerLine))
    main.ftrLine:SetColorTexture(unpack(look.footerLine))
    for _, h in ipairs(self.headers) do h:SetTextColor(unpack(look.groupText)) end
    if look.icon then main.specIcon:SetTexture(look.icon) end
    if look.title then main.title:SetText(look.title) end
    TintPanel(pop, look.popBg, alpha)
    RimColour(pop, look.popBorder)
    local hdiv = self:PopDivider()
    if hdiv then hdiv:SetColorTexture(unpack(look.popDivider)) end
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
    OwnTooltip(btn, "ANCHOR_RIGHT", TIP_GAP)
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
    ReleaseTooltip()
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
        OwnTooltip(pr, "ANCHOR_RIGHT", TIP_GAP)
        GameTooltip:SetText(lib.API.UnitDisplayName(pr._unit, "Unknown"), 0.6, 0.6, 0.6)
        GameTooltip:AddLine("This player is offline", 1, 0.5, 0.5)
        GameTooltip:Show()
    end
end

function Methods:PopRowLeave()
    ReleaseTooltip()
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
    ReleaseTooltip()
end

function Methods:ShowClickHint(row)
    local def = row and row._def
    if not def then return end
    -- Two separate things share this tooltip. The click lines are the hint,
    -- which the addon's setting turns off. The list of who still needs the
    -- buff is not a hint - in combat it is the only per-member view there is,
    -- since the popover cannot open - so turning hints off must not hide it.
    local show = self.host.showClickHints
    local wantHints = not show or show() and true or false
    local wantNeeds = InCombatLockdown()
    if not wantHints and not wantNeeds then return end

    -- The popover opens on this same hover, so sit on the other side.
    local side = (self:PopoverSide(row) == "right") and "ANCHOR_LEFT" or "ANCHOR_RIGHT"
    OwnTooltip(row, side, (side == "ANCHOR_RIGHT") and TIP_GAP or -TIP_GAP)
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

    if wantHints then
        describe("|cffaaaaaaLeft|r ", resolve(1))
        describe("|cffaaaaaaRight|r", resolve(2))
    end
    self:AddNeedsList(row, def)
    GameTooltip:Show()
end

-- In combat the popover cannot open: it parents secure buttons, so showing,
-- anchoring and re-arming it are all refused. The one thing it was for - who
-- in this group still needs the buff - goes in the tooltip instead, which is
-- not protected. Only those who need it, so a full pet bucket stays readable.
--
-- While auras are secret this is LAST KNOWN, and the wording says so. Every
-- aura read is refused in combat, so a buff stripped mid-fight still reads as
-- present from the cache, and one applied mid-fight is invisible. What can
-- still be known is worth saying precisely, which is what `basis` is for:
--
-- Each row carries its own timing, because the list mixes two kinds of thing
-- and one heading cannot be true of both:
--
--   was missing  seen without it, at the last look before the reads closed
--   ran out      its own clock expired DURING the fight - arithmetic, not a read
--   offline      nothing to do with auras, and no way to tell when it happened
--   ?            never seen: joined mid-fight, or out of range at the pull
function Methods:AddNeedsList(row, def)
    if not InCombatLockdown() or not row._members then return end
    local S = lib.Engine.STATES
    local st = self.engine:GroupStat(row._members, def)
    -- Not "are we in combat": if a future build stops hiding party auras, the
    -- reads work and the list is current again.
    local lastKnown = lib.API.AurasAreSecret()
    local needs = {}
    for _, m in ipairs(row._members) do
        local known = st.byUnit[m.unit]
        if not UnitIsConnected(m.unit) then
            needs[#needs + 1] = { m.name, "offline", COLOUR.OFFLINE }
        elseif known and known.state == S.UNKNOWN then
            -- Never seen, so not claimed as missing.
            needs[#needs + 1] = { m.name, "?", COLOUR.UNKNOWN }
        elseif not known or (known.rem or 0) <= 0 then
            local marker = "MISS"
            if known and known.basis == "expired" then
                marker = "ran out"          -- had it when the fight started
            elseif lastKnown then
                marker = "was missing"      -- at the last look, which is all there is
            end
            needs[#needs + 1] = { m.name, marker, COLOUR.MISS }
        end
    end
    if #needs == 0 then
        GameTooltip:AddLine(" ")
        if lastKnown then
            -- Covers the same ground as the heading: nobody was missing it at
            -- the last look, and nothing has run out or gone offline since.
            GameTooltip:AddLine("Nobody needs it, from what can still be seen.",
                0.40, 0.85, 0.40)
        else
            GameTooltip:AddLine("Everyone here has it.", 0.40, 0.85, 0.40)
        end
        return
    end
    GameTooltip:AddLine(" ")
    -- One heading for a list that mixes "was missing at the last look" with
    -- "ran out since": saying "missing when the fight started" would be false
    -- of half of it. The rows say which is which.
    GameTooltip:AddLine(lastKnown and "Needs it, from what can still be seen:" or "Needs it:",
        1.00, 0.82, 0.22)
    for _, line in ipairs(needs) do
        GameTooltip:AddDoubleLine(line[1], line[2], 1, 1, 1, unpack(line[3]))
    end
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
    self.hintRow = r
    self:UpdatePopover(r, r._members, r._def)
    self:ShowClickHint(r)
end

-- The popover's own hide is the hover poll's job: an OnLeave would fire on the
-- way TO the popover. Dropping the tooltip here is right either way.
function Methods:RowLeave()
    self.hintRow = nil
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
-- window stops refreshing and goes when the fight ends.
--
-- When the player asked and the window is still on screen, a deferred close
-- also calls the addon's onCloseDeferred, so every way of closing - the X
-- button, a slash command, a keybind - can explain itself the same way. What
-- matters is that a frame the player just tried to close is still visible,
-- NOT whether the window was logically open: an automatic close during the
-- same fight (the group emptied) leaves it shown while `visible` is already
-- false. Said once per pending close, not once per click. The return value is
-- there for a caller that wants to handle it itself.
-- A flat square has no affordance of its own - a Blizzard button announces
-- itself by being gold - so it brightens under the cursor. A method rather
-- than a closure, because the frame outlives the copy that installed it.
function Methods:CloseButtonHover(btn, over)
    if not (btn and btn.label) then return end
    if over then
        btn.label:SetTextColor(1, 1, 1)
    else
        btn.label:SetTextColor(0.75, 0.75, 0.8)
    end
end

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
    self.openDue, self.openToken = nil, nil
    self.showGen = self.showGen + 1
    if manual then Call(self.host.setVisible, false) end
    if self.closePending then
        if manual and not self.closeExplained
            and self.main and self.main:IsShown() then
            self.closeExplained = true
            Call(self.host.onCloseDeferred, self)
        end
    else
        self.closeExplained = false
    end
    return not self.closePending
end

-- Rebuild and show the window after `delay` seconds, unless it is closed in
-- the meantime. Everything that opens the window later goes through here, so
-- a close always wins over an older request.
-- Coalesced, like ScheduleRefresh: the events that open a window arrive in
-- pairs - RAID_ROSTER_UPDATE with GROUP_ROSTER_UPDATE on joining a raid,
-- PLAYER_TALENT_UPDATE with SPELLS_CHANGED on a respec - and each queued
-- Update is a full rebuild: the roster gathered, every member's auras read,
-- and a SetAttribute on every secure row.
--
-- A sooner request supersedes a pending later one rather than being dropped,
-- so a 0.2s show queued behind a 0.6s one still happens at 0.2s. The
-- generation check stays, which is why a host cannot do this for itself: a
-- host-side coalescer would have to call Update directly and lose it, and a
-- close would stop beating an older queued show.
function Methods:Open(delay)
    delay = delay or 0
    local due = GetTime() + delay
    -- Something at least as soon is already waiting: let it do the work.
    if self.openDue and self.openDue <= due then return end

    -- The pending request is identified by this table, not by its deadline:
    -- a close and a reopen in the same frame produce the SAME deadline, and
    -- the cancelled timer would then recognise the live request as its own,
    -- clear it, and bail on the generation check - leaving the window shut
    -- with nothing queued.
    local token = {}
    self.openDue, self.openToken = due, token

    local gen = self.showGen
    After(delay, function()
        -- A later call asked for an earlier time and has its own timer.
        if self.openToken ~= token then return end
        self.openDue, self.openToken = nil, nil
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
-- An r6 copy asked to hide a frame during combat, got blocked, and left
-- `_combatHidden` on it. If a newer copy upgraded this window mid-fight, that
-- flag is the only record of the request: without translating it, a logically
-- closed window stays on screen for good.
local function AdoptLegacyState(self)
    for frame, field in pairs({ [self.main or false] = "closePending",
                                [self.pop or false] = "popHidePending" }) do
        if frame and frame._combatHidden then
            frame._combatHidden = nil
            self[field] = true
            -- r6 tried to drop the clamp and the alpha before moving the
            -- frame. Those calls were blocked in combat, but restore them
            -- anyway: out of combat they would have gone through.
            frame:SetAlpha(1)
            frame:SetClampedToScreen(true)
        end
    end
end

function Methods:OnCombatEnd()
    if InCombatLockdown() then return end
    AdoptLegacyState(self)
    -- Everything the fight refused, in the order the player asked for it.
    if self.dragPending then self:DragStop() end
    if self.popHidePending then
        self.popHidePending = false
        if self.pop then self.pop:Hide() end
    end
    if self.closePending then
        self.closePending = false
        self.closeExplained = false
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
-- The layout this copy draws. Bumped whenever the geometry changes, which is
-- what tells an older copy's window apart from one this copy built.
local LAYOUT = 2

-- Bring a window an older copy built up to this one's layout.
--
-- Frames are built ONCE: Init returns early when self.main exists, so without
-- this an r18 window keeps 15px rows, bare icons, the old font and Blizzard's
-- close button while r19's code drives it - the same class of bug Panel and
-- Fill already adopt around, and the one Codex found in r19 (#37). Refused in
-- combat, because rows are secure buttons and resizing one is a protected
-- call; the next rebuild out of combat comes back here.
function Methods:AdoptLayout()
    local main = self.main
    if not main then return false end
    if main._layout == LAYOUT then return true end
    if InCombatLockdown() then return false end

    StyleHeader(main)
    for _, r  in ipairs(self.rows)    do StyleRow(r) end
    for i, pr in ipairs(self.popRows) do StylePopRow(pr, i) end
    for _, fs in ipairs(self.headers) do
        Style(fs, GRP_FONT, "CENTER")
        fs:SetWidth(ROW_W)
    end

    -- Blizzard's close button has no label of ours. It cannot be destroyed,
    -- so it is hidden, unhooked from the mouse, and replaced.
    local x = main.closeBtn
    if type(x) == "table" and type(x.label) ~= "table" then
        if x.Hide then x:Hide() end
        if x.EnableMouse then x:EnableMouse(false) end
        main.closeBtn = MakeCloseButton(self, main)
    end

    -- The divider was adopted where the OLD header put it, which is no longer
    -- under the header. FindOlderDivider knows every height this library has
    -- shipped, so it is found; moving it is this step's job.
    local hdiv = self:PopDivider()
    if hdiv and hdiv.ClearAllPoints then
        hdiv:ClearAllPoints()
        hdiv:SetPoint("TOPLEFT",  self.pop, "TOPLEFT",  DIVIDER_X, DIVIDER_Y)
        hdiv:SetPoint("TOPRIGHT", self.pop, "TOPRIGHT", -DIVIDER_X, DIVIDER_Y)
    end

    main._layout = LAYOUT
    return true
end

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
    -- Before anything is measured or placed: a window an older copy built
    -- arrives here with the previous layout, and every position below is
    -- computed from this one's metrics.
    self:AdoptLayout()
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
                hdr:SetPoint("TOPLEFT", main, "TOPLEFT", ROW_X, y)
                if gNum >= PET_GROUP then
                    local n = gNum - PET_GROUP + 1
                    hdr:SetText(n > 1 and (EM .. " Pets " .. n .. " " .. EM)
                                      or (EM .. " Pets " .. EM))
                else
                    hdr:SetText(EM .. " Group " .. gNum .. " " .. EM)
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
    self.closeExplained = false
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

-- ─── Is this copy usable? ───────────────────────────────────────────────────
--
-- Installed by the LAST file the XML loads, so that its own presence is part
-- of the answer: if UI.lua threw, there is no Status to call, and a host
-- treats that absence as "incomplete".
--
--     local status = lib.Status and lib.Status(NEEDS_MINOR)
--
-- Returns one of:
--
--   "ok"          every file this copy declares finished loading, and the
--                 active MINOR is at least the host's floor
--   "incomplete"  a file did not reach its last line - or an older copy's
--                 record is still here under a newer active MINOR, which is
--                 the same thing: half a table
--   "too-old"     complete, but older than the host needs. Nothing is broken;
--                 a host must not tell the player something crashed.
--
-- Second return is the active MINOR, for the host's message. The library
-- still never prints: what the player is told is the addon's business.
--
-- Hosts used to carry this check themselves - the marker names, one type()
-- test per entry point - which is the library's internals living in every
-- consumer, and it went wrong the same way twice (Spotnick2/priestly#52).
function lib.Status(needsMinor)
    local _, active = LibStub:GetLibrary(MAJOR, true)
    if type(active) ~= "number" then return "incomplete" end
    local expected = lib.FILES
    if type(expected) ~= "table" then return "incomplete", active end
    for _, name in ipairs(expected) do
        if lib.fileMinors[name] ~= active then return "incomplete", active end
    end
    if type(needsMinor) == "number" and active < needsMinor then
        return "too-old", active
    end
    return "ok", active
end

-- Last, so a file that threw partway through is not marked installed.
lib.uiMinor = MINOR
lib.fileMinors.UI = MINOR
