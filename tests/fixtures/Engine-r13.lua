-- ============================================================================
-- Engine.lua  -  the buff logic shared by Priestly, Wildly and Magely: aura
-- reads with a combat-secrecy fallback, durations, the roster, group stats,
-- target picking, click mapping and UNIT_AURA filtering.
--
-- Everything that differs per addon comes in through the host table. Frames,
-- secure attributes, formatting, saved state and event scheduling stay in the
-- addon: the library has no frames and holds no saved state.
--
--     local engine = LibStub("LibGroupBuffs-1.0").Engine.New({
--         defs       = DEFS,        -- owned by this engine; see RefreshSpells
--         bucketSize = 8,           -- popover rows: pets are split into buckets this size
--         showSolo   = function() return ... end,         -- optional, default false
--         trackPets  = function() return ... end,         -- optional, default true
--         isBuffEnabled = function(defId) return ... end, -- optional, default true
--         isVisible  = function(def, groups, ord) ... end,   -- optional extra rule
--         membersFor = function(def, members) ... end,       -- optional row filter
--         learnDuration   = function(spellName, seconds) ... end,  -- optional storage
--         learnedDuration = function(spellName) return ... end,    -- optional storage
--     })
--
-- A def is { id, snglID, grpID (optional), sngl, grp (enUS fallbacks),
-- duration (seed), ... }; anything else on it is the addon's own. The engine
-- fills in the localized names, `names` and `hasSingle` / `hasGroup`.
--
-- Methods are looked up on every call (shared metatable), so an addon calls
-- `engine:BuffRem(...)` - never a copy of `engine.BuffRem` - and a newer
-- embedded copy's methods reach an engine an older copy created.
-- ============================================================================

-- Same MINOR as every runtime file; see Settings.lua for why the guard is two
-- checks, and tests/test_versions.lua for the load orders.
local MAJOR, MINOR = "LibGroupBuffs-1.0", 13
local lib, active = LibStub:GetLibrary(MAJOR, true)
if not lib or active ~= MINOR then return end
if lib.engineMinor == MINOR then return end

lib.Engine = lib.Engine or {}
lib.EngineMethods = lib.EngineMethods or {}
lib.EngineMeta = lib.EngineMeta or {}
local Engine, Methods = lib.Engine, lib.EngineMethods
lib.EngineMeta.__index = Methods

-- Remaining time for a permanent aura. The addon's timer text prints nothing
-- above 9998, and the gradient must not run past full.
Engine.PERMANENT = 9999
-- Filled in place: a consumer may hold this table from an older copy.
Engine.STATES = Engine.STATES or {}
Engine.STATES.HAS, Engine.STATES.MISSING, Engine.STATES.UNKNOWN = "HAS", "MISSING", "UNKNOWN"
-- Pet buckets are numbered from here, so they sort after every raid subgroup.
Engine.PET_GROUP = 99

local PERMANENT = Engine.PERMANENT
local ST_HAS, ST_MISSING, ST_UNKNOWN = "HAS", "MISSING", "UNKNOWN"
local PET_GROUP = Engine.PET_GROUP

local function Fail(msg) error("LibGroupBuffs Engine.New: " .. msg, 3) end

local function OptionalFunction(host, key)
    if host[key] ~= nil and type(host[key]) ~= "function" then
        Fail(key .. " must be a function or nil")
    end
    return host[key]
end

function Engine.New(host)
    if type(host) ~= "table" then Fail("host must be a table") end
    if type(host.defs) ~= "table" or #host.defs == 0 then
        Fail("defs must list at least one buff")
    end
    local seen = {}
    for i, def in ipairs(host.defs) do
        if type(def) ~= "table" or type(def.id) ~= "string" or def.id == "" then
            Fail("def " .. i .. " needs a string id")
        end
        if seen[def.id] then Fail("def id " .. def.id .. " is used twice") end
        seen[def.id] = true
        if type(def.snglID) ~= "number" then
            Fail("def " .. def.id .. " needs snglID, the single-target spell's ID")
        end
        if def.grpID ~= nil and type(def.grpID) ~= "number" then
            Fail("def " .. def.id .. ": grpID must be a spell ID or nil")
        end
    end
    local size = host.bucketSize
    if type(size) ~= "number" or size < 1 or size ~= math.floor(size) then
        Fail("bucketSize must be a positive whole number - the popover's row count")
    end
    return setmetatable({
        defs = host.defs,
        bucketSize = size,
        showSolo = OptionalFunction(host, "showSolo"),
        trackPets = OptionalFunction(host, "trackPets"),
        isBuffEnabled = OptionalFunction(host, "isBuffEnabled"),
        isVisible = OptionalFunction(host, "isVisible"),
        membersFor = OptionalFunction(host, "membersFor"),
        learnDuration = OptionalFunction(host, "learnDuration"),
        learnedDuration = OptionalFunction(host, "learnedDuration"),
        -- [unitKey] = { [defId] = { exp, dur, spell, stamp } }. Per engine:
        -- def ids are only unique within one addon.
        cache = {},
    }, lib.EngineMeta)
end

-- ─── Spells ─────────────────────────────────────────────────────────────────
--
-- Spell IDs are the source of truth: names are resolved from them at runtime
-- (locale-proof), with the def's enUS literals as the fallback when the client
-- does not know the spell at all. Cheap; rerun on SPELLS_CHANGED and talent
-- changes, because what a character knows changes as they level. The def
-- tables are updated in place, never replaced.
function Methods:RefreshSpells()
    local API = lib.API
    for _, d in ipairs(self.defs) do
        d.sngl = API.SpellName(d.snglID) or d.sngl
        if d.grpID then d.grp = API.SpellName(d.grpID) or d.grp end
        d.names = { d.sngl, d.grp }
        d.hasSingle = API.KnowsSpell(d.snglID) and true or false
        d.hasGroup = (d.grpID and API.KnowsSpell(d.grpID)) and true or false
    end
end

-- Click mapping for one buff: primary (left) and secondary (right) spell.
--
-- Left-click prefers the group spell, but when it does not exist it falls back
-- to the single-target spell rather than leaving the primary click dead.
-- Right-click is the mirror of that. A buff with no group spell at all (Thorns,
-- Amplify Magic) casts the single spell on both.
function Methods:ClickSpells(def)
    local grp  = def.hasGroup  and def.grp  or nil
    local sngl = def.hasSingle and def.sngl or nil
    return grp or sngl, sngl or grp
end

-- ─── Aura reads: GUID-keyed cache and combat secrecy ────────────────────────
--
-- On this client every aura read throws once combat taints the addon, for
-- every unit (API.ReadBuff reports BLOCKED). Reading anyway would report every
-- member unbuffed and flip the whole frame red the instant a pull starts, so
-- the engine remembers what each *character* had and counts down from that.
--
-- Keyed by API.UnitKey - the GUID - never by unit token: "raid3" and "party2"
-- are labels handed to a different player when the roster reshuffles. (When a
-- GUID cannot be read UnitKey falls back to the token, which carries that
-- risk; see Compat.lua.)
--
-- A member never seen buffed is UNKNOWN, not a confident MISSING: guessing
-- wrong in that direction sends the player casting into combat for nothing.

local function CacheFor(self, key)
    local e = self.cache[key]
    if not e then e = {}; self.cache[key] = e end
    return e
end

-- Durations here match neither TBC nor Vanilla and still move during the
-- beta, so whatever a live aura reports is handed to the addon to store, in
-- either direction. Keyed by the spell actually seen: single and group forms
-- run for different lengths.
local function Learn(self, spellName, dur)
    if not spellName or not dur or dur <= 0 then return end
    if self.learnDuration then self.learnDuration(spellName, dur) end
end

-- The denominator for a timer: the duration the aura itself reported when
-- there is one, else what the addon learned for that spell, else the seed.
function Methods:DurationFor(def, observed, spellName)
    if observed and observed > 0 then return observed end
    if spellName and self.learnedDuration then
        local learned = self.learnedDuration(spellName)
        if learned then return learned end
    end
    return def.duration or 3600
end

-- Drop characters not seen in an hour, so the cache cannot grow without bound
-- across a long session of pugs. The addon calls this on roster changes.
function Methods:PruneCache()
    local cutoff = GetTime() - 3600
    for key, defs in pairs(self.cache) do
        local live = false
        for _, entry in pairs(defs) do
            if entry.stamp and entry.stamp > cutoff then live = true break end
        end
        if not live then self.cache[key] = nil end
    end
end

-- Returns remaining, duration, state, matchedSpellName, basis
--
-- `basis` says where the answer came from, which matters once auras go
-- unreadable: "live" is this moment's read, "remembered" is the last thing
-- seen (a buff still counting down, or a confirmed absence), "expired" is a
-- remembered buff whose own clock has run out since. nil with UNKNOWN means
-- nothing was ever seen.
function Methods:BuffRem(unit, def)
    if not unit or not UnitExists(unit) then return 0, 0, ST_MISSING, nil, "live" end
    local API = lib.API
    local key = API.UnitKey(unit)

    -- Always attempt the live read, so the cache is never coasted on while
    -- real data is available.
    local status, rem, dur, exp, matched = API.ReadBuff(unit, def.names)

    if status == "HAS" then
        if rem == math.huge then rem = PERMANENT end
        Learn(self, matched, dur)
        if key then
            CacheFor(self, key)[def.id] = {
                exp = exp or 0, dur = dur or 0, spell = matched, stamp = GetTime(),
            }
        end
        return rem, dur, ST_HAS, matched, "live"
    end

    if status == "NONE" then
        -- Remember the absence, not just the buff. A confirmed "they do not
        -- have it" is the last thing anybody can learn before combat closes
        -- the aura reads, and dropping it turned somebody we had just checked
        -- into UNKNOWN the moment a fight started. It can go stale - another
        -- buffer can fix them mid-fight - so it is reported as remembered,
        -- never as a live read.
        if key then
            CacheFor(self, key)[def.id] = { missing = true, stamp = GetTime() }
        end
        return 0, 0, ST_MISSING, nil, "live"
    end

    -- BLOCKED: fall back to what this character was last seen with.
    local cached = key and self.cache[key] and self.cache[key][def.id]
    if not cached then return 0, 0, ST_UNKNOWN end
    if cached.missing then return 0, 0, ST_MISSING, nil, "remembered" end
    local r
    if cached.exp == 0 then
        r = PERMANENT
    else
        r = math.max(0, cached.exp - GetTime())
    end
    if r > 0 then return r, cached.dur, ST_HAS, cached.spell, "remembered" end
    -- Its own clock ran out during the fight, which is arithmetic rather than
    -- a read: that much can still be known.
    return 0, cached.dur, ST_MISSING, cached.spell, "expired"
end

-- ─── Targets ────────────────────────────────────────────────────────────────

-- Can this unit be buffed right now?
function Methods:IsValidTarget(unit)
    if not UnitExists(unit) then return false end
    if not UnitIsConnected(unit) then return false end
    if UnitIsDeadOrGhost(unit) then return false end
    return true
end

-- Who a click should land on: the first member actually missing the buff,
-- else whoever has the least time left, else the first valid member.
--   anyValid = true  (group spell): only changes which spell is range-checked.
--                    It still aims at a member who needs the buff, because a
--                    row can span subgroups - a raid's pet bucket mixes pets
--                    from every party - and a group spell only covers the
--                    target's own subgroup. Aiming at "anybody valid" kept
--                    landing on the same, already buffed, pet.
--   anyValid = false (single target): range-checked against the single form.
-- A member whose auras cannot be read is never picked as "missing" - under
-- combat secrecy that would aim at the first name in the list - but can still
-- be the last-resort fallback.
local function PickCandidate(self, members, def, anyValid, requireInRange, st)
    -- Range-check the spell this click will actually cast. Group spells can
    -- reach further than the single forms, so testing the single spell would
    -- rule out members the group spell reaches perfectly well.
    local spell
    if anyValid and def.hasGroup then
        spell = def.grp
    else
        spell = def.hasSingle and def.sngl or def.grp
    end
    local firstValid, bestUnit, bestRem = nil, nil, math.huge
    for _, m in ipairs(members) do
        if self:IsValidTarget(m.unit)
            and (not requireInRange or lib.API.SpellRange(m.unit, spell) == "IN_RANGE")
        then
            firstValid = firstValid or m.unit
            local rem, state
            local known = st and st.byUnit and st.byUnit[m.unit]
            if known then
                rem, state = known.rem, known.state
            else
                local _
                rem, _, state = self:BuffRem(m.unit, def)
            end
            if state == ST_MISSING then return m.unit end
            if state == ST_HAS and rem < bestRem then
                bestRem = rem
                bestUnit = m.unit
            end
        end
    end
    return bestUnit or firstValid
end

-- `members` is the row's list, already through MembersFor. `st`, when given,
-- is GroupStat's result for the same members and def: its per-member states
-- are reused instead of reading every aura again.
--
-- Prefers somebody in range: a cast at an out-of-range member while an
-- in-range one is missing the buff simply fails. Then retries ignoring range,
-- since the range check answers UNKNOWN in some cases and picking nobody
-- would be worse than picking someone out of range.
function Methods:PickTarget(members, def, anyValid, st)
    return PickCandidate(self, members, def, anyValid, true, st)
        or PickCandidate(self, members, def, anyValid, false, st)
end

-- ─── Roster ─────────────────────────────────────────────────────────────────

-- A pet's "class" for its icon, from its owner.
local function PetClass(ownerUnit)
    if not ownerUnit then return "PET" end
    local _, cls = UnitClass(ownerUnit)
    if cls == "HUNTER"  then return "PET_HUNTER"  end
    if cls == "WARLOCK" then return "PET_WARLOCK" end
    if cls == "PRIEST"  then return "PET_PRIEST"  end
    if cls == "MAGE"    then return "PET_MAGE"    end
    return "PET"
end

-- Returns groups[gNum] = { {unit, name, class}, ... }, ord = sorted group list.
-- Raid subgroups keep their numbers; a party or solo player is group 1; pets
-- go into buckets from PET_GROUP up, sorted last.
--
-- `name` is the full display name including the Forever surname. First names
-- are not unique here - two characters called Karuzo can sit in one raid - so
-- the name is for display only; identity is API.UnitKey.
function Methods:GatherGroups()
    local API = lib.API
    local g, ord = {}, {}
    local pets = {}

    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local name, _, sg = GetRaidRosterInfo(i)
            if name then
                if not g[sg] then g[sg] = {}; ord[#ord + 1] = sg end
                local _, cls = UnitClass("raid"..i)
                g[sg][#g[sg] + 1] = { unit = "raid"..i, name = API.UnitDisplayName("raid"..i, name), class = cls }
                local petUnit = "raidpet"..i
                if UnitExists(petUnit) then
                    pets[#pets + 1] = { unit = petUnit, name = API.UnitDisplayName(petUnit, "Pet"), class = PetClass("raid"..i) }
                end
            end
        end
    elseif GetNumGroupMembers() > 0 then
        g[1] = {}
        local _, pc = UnitClass("player")
        g[1][1] = { unit = "player", name = API.UnitDisplayName("player", "You"), class = pc }
        if UnitExists("pet") then
            pets[#pets + 1] = { unit = "pet", name = API.UnitDisplayName("pet", "Pet"), class = PetClass("player") }
        end
        for i = 1, GetNumGroupMembers() do
            local u = "party"..i
            if UnitExists(u) then
                local _, uc = UnitClass(u)
                g[1][#g[1] + 1] = { unit = u, name = API.UnitDisplayName(u, "?"), class = uc }
                local petUnit = "partypet"..i
                if UnitExists(petUnit) then
                    pets[#pets + 1] = { unit = petUnit, name = API.UnitDisplayName(petUnit, "Pet"), class = PetClass(u) }
                end
            end
        end
        ord[1] = 1
    elseif self.showSolo and self.showSolo() then
        g[1] = {}
        local _, pc = UnitClass("player")
        g[1][1] = { unit = "player", name = API.UnitDisplayName("player", "You"), class = pc }
        if UnitExists("pet") then
            pets[#pets + 1] = { unit = "pet", name = API.UnitDisplayName("pet", "Pet"), class = PetClass("player") }
        end
        ord[1] = 1
    end

    local trackPets = true
    if self.trackPets then trackPets = self.trackPets() and true or false end
    if #pets > 0 and trackPets then
        -- Split into popover-sized buckets. A raid can field more pets than the
        -- popover has rows, and a row that reports "11 missing" while offering
        -- eight of them to click is worse than two rows.
        local size = self.bucketSize
        local bucket, gNum = nil, PET_GROUP
        for i, pet in ipairs(pets) do
            if not bucket or #bucket >= size then
                bucket = {}
                gNum = PET_GROUP + math.floor((i - 1) / size)
                g[gNum] = bucket
                ord[#ord + 1] = gNum
            end
            bucket[#bucket + 1] = pet
        end
    end

    table.sort(ord)
    return g, ord
end

-- ─── Rows ───────────────────────────────────────────────────────────────────

-- Which buffs get a row. Availability comes first and applies to every buff:
-- a row wired to a spell the character does not know is a dead click. The
-- addon's toggle and its extra visibility rule layer on top of availability,
-- never instead of it.
function Methods:ActiveDefs(groups, ord)
    local out = {}
    for _, d in ipairs(self.defs) do
        if (d.hasSingle or d.hasGroup)
            and (not self.isBuffEnabled or self.isBuffEnabled(d.id))
            and (not self.isVisible or self.isVisible(d, groups, ord))
        then
            out[#out + 1] = d
        end
    end
    return out
end

-- The members one buff's row covers: the whole group unless the addon narrows
-- it (Thorns goes on tanks). Called ONCE per row; the result drives the stats,
-- the targets, the popover and the clicks alike, so they cannot disagree. An
-- empty list means no row. The input list is never modified.
function Methods:MembersFor(def, members)
    if not self.membersFor then return members end
    local out = self.membersFor(def, members)
    if type(out) ~= "table" then
        error("LibGroupBuffs Engine: membersFor must return a list (an empty one for none)", 2)
    end
    return out
end

-- Returns { miss, minR, minDur, allHave, nMiss, nUnknown, nTotal, byUnit }
--
-- Offline members count as missing. nUnknown counts members whose auras
-- cannot be read right now (combat secrecy, nothing cached); they are
-- deliberately NOT counted as missing.
function Methods:GroupStat(members, def)
    local minR, minDur, miss, unknown = PERMANENT, 0, {}, 0
    local byUnit = {}
    for _, m in ipairs(members) do
        if not UnitIsConnected(m.unit) then
            miss[#miss + 1] = m
        else
            local r, d, state, spell, basis = self:BuffRem(m.unit, def)
            byUnit[m.unit] = { rem = r, state = state, basis = basis }
            if state == ST_UNKNOWN then
                unknown = unknown + 1
            elseif r <= 0 then
                miss[#miss + 1] = m
            elseif r < minR then
                minR = r
                minDur = self:DurationFor(def, d, spell)
            end
        end
    end
    return {
        miss     = miss,
        minR     = (minR == PERMANENT) and 0 or minR,
        minDur   = minDur,
        allHave  = (#miss == 0 and unknown == 0),
        nMiss    = #miss,
        nUnknown = unknown,
        nTotal   = #members,
        -- Each member's state during this pass, with where it came from, so
        -- PickTarget can reuse it instead of re-reading every aura and the
        -- addon can say how current it is.
        byUnit   = byUnit,
    }
end

-- ─── UNIT_AURA ──────────────────────────────────────────────────────────────
--
-- UNIT_AURA is far noisier here than on TBC: every proc and every HoT tick on
-- anyone in the group fires it. Only group units are interesting, and on a
-- partial update only this addon's own spells are - checked against every
-- def, not only the visible ones, since an aura landing can be what makes a
-- def visible.
--
-- Every field of updateInfo can be a SECRET VALUE in combat, and on this
-- client a secret value throws when it is truth-tested, not only when it is
-- read: `if updateInfo.isFullUpdate then` raises. So the whole inspection runs
-- inside one pcall, and anything that cannot be inspected counts as relevant -
-- the addon refreshes and its throttle absorbs it, rather than dropping an
-- update it was simply not allowed to read.
function Methods:AuraEventIsRelevant(unit, updateInfo)
    local defs = self.defs
    local ok, relevant = pcall(function()
        if not unit then return false end
        if not (unit == "player" or unit == "pet"
            or unit:find("^party") or unit:find("^raid")) then
            return false
        end
        if not updateInfo then return true end
        if updateInfo.isFullUpdate then return true end

        local added = updateInfo.addedAuras
        if added then
            for _, aura in ipairs(added) do
                local nm = aura and aura.name
                for _, d in ipairs(defs) do
                    if nm == d.sngl or nm == d.grp then return true end
                end
            end
        end

        -- Updated/removed auras arrive as instance IDs with no spell attached,
        -- so there is nothing to filter on.
        if updateInfo.updatedAuraInstanceIDs or updateInfo.removedAuraInstanceIDs then
            return true
        end
        return false
    end)

    if not ok then return true end
    return relevant and true or false
end

-- Last, so a file that threw partway through is not marked installed.
lib.engineMinor = MINOR
lib.fileMinors.Engine = MINOR
