-- ============================================================================
-- LibGroupBuffs-1.0
--
-- The shared engine behind Priestly, Magely and Wildly, in ONE file: one
-- version guard at the top, one completion marker (lib.ready) on the last line.
--
-- It used to be six files, each with its own copy of the guard and its own
-- marker, so every release touched six MINOR literals and froze six fixtures.
-- The files survive as sections below, each inside its own do ... end so the
-- private locals of one (Methods, Fail, Call...) can never be captured by
-- another. Keep it that way: a new local belongs inside its section.
--
-- A copy loading after an equal or newer one does nothing (NewLibrary returns
-- nil). A newer copy loading after an older one gets the SAME lib table and
-- fills it in place: see AGENTS.md, "An upgrade reuses the existing tables".
-- ============================================================================

local MAJOR, MINOR = "LibGroupBuffs-1.0", 27
local lib = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end          -- an equal or newer copy is already loaded

-- Private to this copy and shared by its sections: assigned in the Glass
-- section, read by the window and by lib.Status / lib:New.
local GlassUsable, GlassInst, GLASS_MISSING

do -- Compat ==================================================================

-- ============================================================================
-- LibGroupBuffs-1.0 : Compat
--
-- The WoW: Forever (1.60.1) API surface, in one place.
--
-- Forever is Vanilla content running on the Retail/Mainline codebase, so the
-- APIs these addons grew up on (UnitBuff, GetSpellInfo, the spell-tab walk,
-- GetItemIcon, MouseIsOver) are gone or changed shape. Adapters live here -
-- never as injected globals, which would change capability detection for every
-- other addon and make load order matter.
--
-- Consumers take a file-local alias so call sites read normally:
--     local API = LibStub("LibGroupBuffs-1.0").API
--
-- Everything here was measured on the live client, not inferred from
-- documentation. The surprises are commented where they bite; the full notes
-- live in docs/FOREVER-NOTES.md.
-- ============================================================================


lib.API = lib.API or {}
local API = lib.API

local max, huge = math.max, math.huge

-- ─── events ───────────────────────────────────────────────────
-- Unknown event names THROW on RegisterEvent on this client, so registration is
-- guarded. A silently missing handler is worse than a noisy one, so failures
-- are returned to the caller to report - a library has no business printing to
-- somebody else's chat frame.

-- Kept for diagnosis (`/dump LibStub("LibGroupBuffs-1.0").API.eventFailures`).
-- Kept across a library upgrade: a newer embedded copy reuses `lib.API`, and
-- resetting this would throw away the failures an older copy recorded.
API.eventFailures = API.eventFailures or {}

-- The same failures, per consumer: `eventFailuresByOwner[owner][event]`. The
-- flat eventFailures above is shared by every addon embedding the library, so
-- it cannot say which one asked, and two failing on the same name overwrite
-- each other.
API.eventFailuresByOwner = API.eventFailuresByOwner or {}

-- Returns ok, failedList. Prints nothing and reports to no one, so a caller
-- that ignores the return value has a silently dead handler; consumers should
-- use RegisterEventsReported below. Kept unchanged for consumers pinned to r2.
function API.RegisterEvents(frame, ...)
    -- Arguments are checked before anything is registered. A nil event name is
    -- a programming error (a misspelt constant, a conditional that came out
    -- nil), and meeting it partway through would leave the earlier events
    -- registered, the later ones never tried and nobody told.
    if type(frame) ~= "table" or type(frame.RegisterEvent) ~= "function" then
        error("RegisterEvents: frame must be a frame, got " .. type(frame), 2)
    end
    local n = select("#", ...)
    for i = 1, n do
        local ev = select(i, ...)
        if type(ev) ~= "string" or ev == "" then
            error("RegisterEvents: event " .. i .. " is not an event name (" .. tostring(ev) .. ")", 2)
        end
    end

    local failed
    for i = 1, n do
        local ev = select(i, ...)
        -- Two ways to refuse, and both count. RegisterEvent throws on a name
        -- this client does not know, and it is declared to return a boolean
        -- (`RegisterEvent(eventName) -> registered:bool` in the API dump), so
        -- a plain `false` is a refusal too. Checking only for a throw would
        -- call it success, and the handler would be silently dead.
        local ok, result = pcall(frame.RegisterEvent, frame, ev)
        if not ok or result == false then
            API.eventFailures[ev] = ok and "RegisterEvent returned false" or tostring(result)
            failed = failed or {}
            failed[#failed + 1] = ev
        end
    end
    return failed == nil, failed
end

-- RegisterEvents that cannot be silent. `owner` names the consumer ("Priestly")
-- and `report` is how it tells its user, called with the list of rejected
-- names when there are any. Both are required and checked up front: a missing
-- reporter is a programming error, and it fails at load where a test catches
-- it rather than as a dead handler in game. The library still never prints -
-- what the report says, and where, is the consumer's business.
--
-- Returns ok, failedList, like RegisterEvents.
function API.RegisterEventsReported(frame, owner, report, ...)
    if type(owner) ~= "string" or owner == "" then
        error("RegisterEventsReported: owner must name the addon registering", 2)
    end
    if type(report) ~= "function" then
        error("RegisterEventsReported: report must be a function - rejected events would be silent", 2)
    end
    local ok, failed = API.RegisterEvents(frame, ...)
    if not ok then
        local mine = API.eventFailuresByOwner[owner] or {}
        API.eventFailuresByOwner[owner] = mine
        for _, ev in ipairs(failed) do mine[ev] = API.eventFailures[ev] end
        report(failed)
    end
    return ok, failed
end

-- ─── auras ───────────────────────────────────────────────────────────────────
-- UnitBuff / UnitDebuff / AuraUtil are gone; C_UnitAuras returns a struct.
-- Player auras are additionally unreadable while tainted in combat, which the
-- caller handles through a cache - here we only report the condition.

local C_UnitAuras = C_UnitAuras
local C_Secrets = C_Secrets

function API.AurasAreSecret()
    if C_Secrets and C_Secrets.ShouldAurasBeSecret then
        local ok, secret = pcall(C_Secrets.ShouldAurasBeSecret)
        return ok and secret or false
    end
    return false
end

-- Read one aura and match it against `names`, with every single touch of the
-- returned data inside the pcall.
--
-- That is stronger than it looks. On this client a secret value throws not
-- only when a field is read off it but when it is *compared* or even
-- truth-tested: `if aura then` on a secret table, or `nm == name` on a secret
-- string, raises exactly like a field access. Guarding only the read - which is
-- what an earlier version of this file did - leaves the test one line later
-- unprotected.
--
-- Returns one of:
--   "HIT", remaining, duration, expirationTime, matchedName
--   "MISS"     - an aura is there, but not one of ours
--   "EMPTY"    - no aura in that slot, so the walk can stop
--   "BLOCKED"  - the client would not let us look
--
-- Declared ONCE at file scope rather than inside matchAura. A function
-- expression is a fresh closure every time it is evaluated, and this is the
-- hottest line in the addon: a 40-man raid with three buffs tripped it
-- thousands of times a second, each allocating a closure and - because the
-- results were packed with `{ pcall(...) }` - a table as well, for data read
-- five values later and thrown away (#6). Everything it needs now arrives as
-- an argument, and pcall's returns are taken as plain multiple returns.
local function tryMatch(getter, names, ...)
    local aura = getter(...)
    if not aura then return "EMPTY" end

    local nm = aura.name
    local matched
    for j = 1, #names do
        if names[j] and nm == names[j] then
            matched = names[j]
            break
        end
    end
    if not matched then return "MISS" end

    local dur = aura.duration or 0
    local exp = aura.expirationTime or 0
    local remaining
    if exp == 0 then
        remaining = huge          -- permanent, not expired
    else
        remaining = max(0, exp - GetTime())
    end
    return "HIT", remaining, dur, exp, matched
end

local function matchAura(getter, names, ...)
    local ok, st, rem, dur, exp, matched = pcall(tryMatch, getter, names, ...)
    if not ok then return "BLOCKED" end
    return st, rem, dur, exp, matched
end

-- Returns status, remaining, duration, expirationTime.
--
--   "HAS"     - the unit has one of `names`
--   "NONE"    - the unit demonstrably does not
--   "BLOCKED" - the client would not let us look
--
-- `names` is a list of localized spell names: the single and group forms of one
-- buff apply the same tracked aura under two different names.
--
-- BLOCKED is deliberately distinct from NONE. Auras are secret while tainted in
-- combat on this client, and reporting "not buffed" because we were not allowed
-- to look sends you casting for no reason. Note that we *attempt* the read
-- either way rather than refusing whenever ShouldAurasBeSecret() is true: if
-- the restriction turns out not to cover party and raid helpful auras, we keep
-- live data instead of coasting on a cache.
-- Walk one unit's helpful auras ONCE, matching every name in `names`.
--
-- Returns a record rather than a tuple, because a caller wants to ask it
-- several questions later:
--   { blocked = bool, sawAny = bool, found = { [name] = {rem,dur,exp} } }
--
-- `names` is the union of every name anybody is tracking, not one buff's pair.
-- That is the whole point: confirming an absence is what costs a walk, and a
-- priest tracking three buffs used to walk each member's auras three times per
-- refresh pass to confirm three absences (#6). One walk answers all of them.
-- Does this pass's walk answer for every one of `names`?
--
-- `pass.covers` is built once, the first time it is asked, rather than per
-- read: this sits on the hot path and the union does not change inside a pass.
function API.PassCovers(pass, names)
    local covers = pass.covers
    if not covers then
        covers = {}
        for i = 1, #(pass.names or {}) do covers[pass.names[i]] = true end
        pass.covers = covers
    end
    for i = 1, #names do
        if names[i] and not covers[names[i]] then return false end
    end
    return true
end

function API.ScanAuras(unit, names)
    local rec = { blocked = false, sawAny = false, found = {} }
    if not C_UnitAuras then rec.blocked = true return rec end
    local byIndex = C_UnitAuras.GetAuraDataByIndex or C_UnitAuras.GetBuffDataByIndex
    if not byIndex then rec.blocked = true return rec end

    -- The walk stops at the first empty slot, so it costs roughly "number of
    -- buffs on that unit" iterations rather than 40.
    for i = 1, 40 do
        local st, rem, dur, exp, matched = matchAura(byIndex, names, unit, i, "HELPFUL")
        if st == "BLOCKED" then
            rec.blocked = true
            break
        end
        if st == "EMPTY" then break end
        rec.sawAny = true
        -- Keep the FIRST of a duplicated name, which is the one the old
        -- early-returning walk reported.
        if st == "HIT" and not rec.found[matched] then
            rec.found[matched] = { rem = rem, dur = dur, exp = exp }
        end
    end
    return rec
end

-- `pass`, when given, is a table the caller keeps for one refresh pass:
--
--   { names = <every tracked name>, covers = <that list as a set>, units = {} }
--
-- ReadBuff fills `pass.units[unit]` with that unit's scan the first time it
-- has to walk, and every later buff on the same unit in the same pass reads
-- the answer out of it. Without a pass the behaviour is exactly what it was:
-- a fresh walk, scoped to this buff's names.
--
-- A scan only records the names it was asked to match, so it can only answer
-- for those. Asking a pass about a name outside its union would get a
-- confident "not there" for an aura the walk simply never looked for - and the
-- ReadAura seam hands a host's own name list straight in here, so that is not
-- a hypothetical. Such a call bypasses the pass and reads live: slower, and an
-- answer rather than a wrong one.
--
-- The caller owns the boundary deliberately. A pass that expired on a timer,
-- or on some guess about what counts as "now", would be a cache that answers
-- stale in a way nothing can see; an explicit begin and end is a thing a test
-- can drive.
function API.ReadBuff(unit, names, pass)
    if not unit or not UnitExists(unit) then return "NONE" end
    if not C_UnitAuras then return "BLOCKED" end

    local fastPathBlocked = false

    -- Fast path: ask by name rather than walking every aura.
    if C_UnitAuras.GetAuraDataBySpellName then
        for i = 1, #names do
            if names[i] then
                local st, rem, dur, exp, matched = matchAura(
                    C_UnitAuras.GetAuraDataBySpellName, names, unit, names[i], "HELPFUL")
                if st == "HIT" then return "HAS", rem, dur, exp, matched end
                if st == "BLOCKED" then fastPathBlocked = true end
            end
        end
    end

    -- A by-name miss is NOT trusted as "not buffed". C_Spell.GetSpellInfo(name)
    -- only resolves spells the player knows on this client, and if the by-name
    -- aura lookup shares that resolution then a priest who has not learned
    -- Prayer of Fortitude would never see it on people another priest buffed.
    -- So confirm an absence by walking.
    local scan
    if pass and API.PassCovers(pass, names) then
        scan = pass.units[unit]
        if not scan then
            scan = API.ScanAuras(unit, pass.names)
            pass.units[unit] = scan
        end
    else
        scan = API.ScanAuras(unit, names)
    end

    if not scan.blocked then
        for i = 1, #names do
            local hit = names[i] and scan.found[names[i]]
            if hit then return "HAS", hit.rem, hit.dur, hit.exp, names[i] end
        end
    end

    -- Only the WALK decides absence. A throw from the fast path says nothing
    -- about the unit if the walk then completed and proved the buff is not
    -- there - latching that flag would pin the member on "unknown" forever.
    if scan.blocked then return "BLOCKED" end
    if fastPathBlocked and not scan.sawAny then return "BLOCKED" end
    -- Secrecy may hide auras by handing back an empty list rather than
    -- throwing. Seeing nothing at all while it is active is not evidence of
    -- being unbuffed.
    if not scan.sawAny and API.AurasAreSecret() then return "BLOCKED" end
    return "NONE"
end

-- ─── spells ──────────────────────────────────────────────────────────────────
-- GetSpellInfo returned a tuple; C_Spell.GetSpellInfo returns a struct.

local C_Spell = C_Spell

local function spellInfo(spell)
    if not spell or not C_Spell or not C_Spell.GetSpellInfo then return nil end
    local ok, info = pcall(C_Spell.GetSpellInfo, spell)
    if ok then return info end
    return nil
end
API.SpellInfo = spellInfo

-- Localized name for a spell ID, or nil if the client does not know that spell
-- at all (the Prayer ranks may simply not exist in this version).
function API.SpellName(spellID)
    local info = spellInfo(spellID)
    return info and info.name or nil
end

function API.SpellIcon(spell, fallback)
    local info = spellInfo(spell)
    if info and info.iconID then return info.iconID end
    if C_Spell and C_Spell.GetSpellTexture then
        local ok, tex = pcall(C_Spell.GetSpellTexture, spell)
        if ok and tex then return tex end
    end
    return fallback or ""
end

-- IsSpellInRange used to return 1 / 0 / nil. C_Spell.IsSpellInRange returns
-- true / false / nil, and `0` is truthy in Lua - a mechanical port of the old
-- `if r == 1` / `elseif r == 0` ladder silently reports everything as unknown.
-- Tri-state string keeps the call sites honest.
function API.SpellRange(unit, spell)
    if not unit or not UnitExists(unit) then return "UNKNOWN" end
    if not UnitIsConnected(unit) then return "OFFLINE" end
    if not spell then return "UNKNOWN" end

    local r
    if C_Spell and C_Spell.IsSpellInRange then
        local ok, res = pcall(C_Spell.IsSpellInRange, spell, unit)
        if ok then r = res end
    end
    if r == nil then return "UNKNOWN" end
    if r == true or r == 1 then return "IN_RANGE" end
    return "OUT_RANGE"
end

-- ─── spellbook ───────────────────────────────────────────────────────────────
-- GetNumSpellTabs / GetSpellTabInfo / GetSpellBookItemName(BOOKTYPE_SPELL) are
-- gone. C_SpellBook answers by spell ID; the by-name walk is kept only for the
-- rank subtext, which nothing else exposes.

local C_SpellBook = C_SpellBook
local BANK = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player

-- Accepts a spell ID (preferred - locale proof) or a localized name.
function API.KnowsSpell(spell)
    if not spell then return false end

    if type(spell) == "number" and C_SpellBook then
        if C_SpellBook.IsSpellKnown then
            local ok, known = pcall(C_SpellBook.IsSpellKnown, spell, BANK)
            if ok and known then return true end
        end
        if C_SpellBook.IsSpellInSpellBook then
            local ok, inBook = pcall(C_SpellBook.IsSpellInSpellBook, spell, BANK, false)
            if ok and inBook then return true end
        end
        if C_SpellBook.IsSpellKnownOrInSpellBook then
            local ok, known = pcall(C_SpellBook.IsSpellKnownOrInSpellBook, spell)
            if ok and known then return true end
        end
        return false
    end

    -- Name form: walk the book. Used for spells we have no ID for.
    if C_SpellBook and C_SpellBook.GetSpellBookItemName then
        local found = false
        pcall(function()
            for i = 1, 300 do
                local nm = C_SpellBook.GetSpellBookItemName(i, BANK)
                if not nm then break end
                if nm == spell then found = true return end
            end
        end)
        return found
    end
    return false
end

-- Highest known rank of a spell, read out of the spellbook subtext ("Rank 3").
--
-- Returns `rank, how`:
--
--   0,   "absent"     the spell is not in the book
--   n,   "read"       a number was read out of the subtext
--   1,   "unranked"   the spell is there and carries NO subtext, so this
--                     client does not rank it - rank 1 is the right answer
--   nil, "unreadable" there IS a subtext and no number could be read from it
--
-- That last case is the point. The subtext is a LOCALIZED string, and matching
-- digits out of it is a guess about every language at once: deDE "Rang 2" and
-- ruRU "Ранг 2" happen to use ASCII digits, but nothing promises that, and a
-- locale that spells the number or uses its own digits parses to nothing.
-- This used to fall back to rank 1, which is indistinguishable from a genuine
-- rank 1 and picks the wrong reagent for a priest who has rank 2 - the failure
-- looks like "the addon is confused" with nothing saying why (#64, and the
-- same shape as the localization work in Priestly#21).
--
-- No locale is KNOWN to break it. This is about the answer being honest when
-- one does, not about a reported bug.
-- Subtexts this client gave us that no number could be read out of, by spell
-- name. Read by Engine:SpellReport, so a player whose reagent count looks
-- wrong can paste the line that says why instead of guessing.
API.rankUnreadable = API.rankUnreadable or {}

function API.GetSpellRank(spellName)
    if not spellName then return 0, "absent" end
    if not (C_SpellBook and C_SpellBook.GetSpellBookItemName) then
        if API.KnowsSpell(spellName) then return 1, "unranked" end
        return 0, "absent"
    end

    -- The whole book is scanned before anything is decided, because ONE
    -- unreadable entry makes the highest rank unknown no matter what else was
    -- read. A book holding "Rank 1" and an unreadable entry does not mean
    -- rank 1: ranks are ordered, the unreadable one may be above it, and
    -- answering 1 there is the original bug wearing a readable entry as
    -- cover. Deciding per entry as they arrived got this wrong.
    local best, sawUnranked, unreadable = nil, false, nil
    pcall(function()
        for i = 1, 300 do
            local nm, sub = C_SpellBook.GetSpellBookItemName(i, BANK)
            if not nm then break end
            if nm == spellName then
                sub = sub and tostring(sub) or ""
                if sub == "" then
                    sawUnranked = true          -- no subtext: this client does not rank it
                else
                    local r = tonumber(sub:match("(%d+)"))
                    if r then
                        if not best or r > best then best = r end
                    else
                        unreadable = unreadable or sub
                    end
                end
            end
        end
    end)

    local rank, how
    if unreadable then
        rank, how = nil, "unreadable"
    elseif best then
        rank, how = best, "read"
    elseif sawUnranked then
        rank, how = 1, "unranked"
    else
        rank, how = 0, "absent"
    end

    -- The record holds what is wrong NOW. Anything other than a fresh
    -- unreadable result clears it - including the spell being gone from the
    -- book - or the report goes on describing a client that has since
    -- changed, or a spell that is no longer there.
    if how == "unreadable" then
        API.rankUnreadable[spellName] = unreadable
    else
        API.rankUnreadable[spellName] = nil
    end
    return rank, how
end

-- ─── items ───────────────────────────────────────────────────────────────────
-- C_Item.GetItemIcon is a FALSE FRIEND: it takes an ItemLocation. The by-ID
-- form is GetItemIconByID.

local C_Item = C_Item
local QUESTION_MARK = "Interface\\Icons\\INV_Misc_QuestionMark"

function API.ItemIcon(itemID)
    if not itemID then return QUESTION_MARK end
    if C_Item and C_Item.GetItemIconByID then
        local ok, icon = pcall(C_Item.GetItemIconByID, itemID)
        if ok and icon then return icon end
    end
    if C_Item and C_Item.GetItemInfo then
        local ok, _, _, _, _, _, _, _, _, _, icon = pcall(C_Item.GetItemInfo, itemID)
        if ok and icon then return icon end
    end
    return QUESTION_MARK
end

-- ─── mouse ───────────────────────────────────────────────────────────────────
-- The MouseIsOver(frame) global is gone here. Every frame carries an
-- :IsMouseOver() method, which is what it wrapped anyway.

function API.IsMouseOver(frame)
    if not frame then return false end
    if frame.IsMouseOver then
        local ok, over = pcall(frame.IsMouseOver, frame)
        if ok then return over and true or false end
    end
    if MouseIsOver then
        local ok, over = pcall(MouseIsOver, frame)
        if ok then return over and true or false end
    end
    return false
end

-- ─── unit identity and names ─────────────────────────────────────────────────
-- Forever characters have a SURNAME, and first names are not unique: two
-- characters called Karuzo can be in the same raid. Key on GUID; display the
-- full Name-Surname. Never split a name on "-" to strip a realm - on this
-- client that eats the surname.

-- Stable identity for caching. Falls back to the unit token only when the GUID
-- is unavailable (which would make the cache entry short-lived, not wrong).
function API.UnitKey(unit)
    if not unit then return nil end
    local ok, guid = pcall(UnitGUID, unit)
    if ok and guid then return guid end
    return unit
end

-- Full display name including the surname. `fallback` is used when the unit is
-- gone (e.g. a raid roster name we already have in hand).
function API.UnitDisplayName(unit, fallback)
    if unit then
        if GetUnitName then
            local ok, nm = pcall(GetUnitName, unit, false)
            if ok and nm and nm ~= "" and nm ~= UNKNOWNOBJECT then return nm end
        end
        local ok, nm = pcall(UnitName, unit)
        if ok and nm and nm ~= "" and nm ~= UNKNOWNOBJECT then return nm end
    end
    return fallback or "?"
end

-- ─── containers ──────────────────────────────────────────────────────────────
-- GetContainerNumSlots / GetContainerItemInfo moved to C_Container, and the
-- latter returns a struct rather than positional values.

local C_Container = C_Container

-- How many of `itemID` the player is carrying.
--
-- C_Item.GetItemCount answers for the whole carried inventory in one call,
-- which is both cheaper than walking every slot and free of any assumption
-- about which bag ids exist. The bag walk is only a fallback, and it has to
-- include the reagent bag: that sits outside the 0..NUM_BAG_SLOTS range, so a
-- hardcoded `0, 4` silently reports zero for anything stored there.
function API.CountItem(itemID)
    if not itemID then return 0 end

    if C_Item and C_Item.GetItemCount then
        local ok, count = pcall(C_Item.GetItemCount, itemID)
        if ok and count then return count end
    end

    if not C_Container then return 0 end

    local bags = {}
    for bag = 0, (NUM_BAG_SLOTS or 4) do bags[#bags + 1] = bag end
    local reagentBag = Enum and Enum.BagIndex and Enum.BagIndex.ReagentBag
    if reagentBag then bags[#bags + 1] = reagentBag end

    local total = 0
    for _, bag in ipairs(bags) do
        local ok, slots = pcall(C_Container.GetContainerNumSlots, bag)
        if ok and slots then
            for slot = 1, slots do
                local gotInfo, info = pcall(C_Container.GetContainerItemInfo, bag, slot)
                if gotInfo and info and info.itemID == itemID then
                    total = total + (info.stackCount or 0)
                end
            end
        end
    end
    return total
end

-- ─── item info for tooltips ─────────────────────────────────────────────────
-- GameTooltip has NO item-setting method on this client. Measured against the
-- full widget-method dump: no SetItemByID, no SetHyperlink, no SetBagItem, no
-- SetInventoryItem. So the caller builds the tooltip lines and this hands back
-- the data (Priestly issue #29).
--
-- Returns nil when the item is not in the client's cache, having asked for it
-- first. That matters: C_Item.GetItemInfo returns NOTHING on a cache miss
-- rather than nil, and the cache is per client - the same call succeeds on one
-- character and comes back empty on another.

-- When each item was last asked for, so an id the server will never answer
-- cannot produce an unbounded stream of requests. An item that is merely slow
-- is still retried; one that does not exist is retried rarely. The window is
-- longer than the footer's own refresh, which is what was firing it.
local itemAsked = {}
local ITEM_RETRY = 10

-- Ask the client to load an item, at most once every ITEM_RETRY seconds.
-- Returns whether it asked, which is only of interest to the tests.
local function RequestItem(itemID)
    if not (itemID and C_Item and C_Item.RequestLoadItemDataByID) then return false end
    local now = (GetTime and GetTime()) or 0
    local last = itemAsked[itemID]
    if last and (now - last) < ITEM_RETRY then return false end
    itemAsked[itemID] = now
    pcall(C_Item.RequestLoadItemDataByID, itemID)
    return true
end

-- Resolve an item, asking the client for it if it is not there yet. Returns
-- the name and quality, or nothing - having made the request either way.
--
-- Both callers go through this, because the interesting case is the one where
-- the cache FLAG and the DATA disagree: IsItemDataCachedByID answers true
-- while GetItemInfo still returns nothing. Believe the data. A warm-up that
-- trusted the flag would decide there was nothing to ask for, and then the
-- placeholder it exists to prevent is exactly what the first hover shows.
local function ResolveItem(itemID)
    -- Guarded like API.CountItem above. Without it a nil id reaches three
    -- C_Item calls and asks the server to load nothing, and the pcalls keep
    -- it quiet - so the caller cannot tell "you passed nil" from "cache miss,
    -- try again", which are not the same problem.
    if not itemID then return nil end

    -- C_Item is the file-local alias taken at load time, as every other
    -- contract here does.
    if not (C_Item and C_Item.GetItemInfo) then return nil end

    if C_Item.IsItemDataCachedByID then
        local known, cached = pcall(C_Item.IsItemDataCachedByID, itemID)
        if known and not cached then
            RequestItem(itemID)
            return nil   -- the caller shows a placeholder; the next hover has it
        end
    end

    -- Read directly rather than packing pcall's returns into a table:
    -- GetItemInfo answers with nineteen values, and building that table on
    -- every hover to read two of them needed a comment explaining the index
    -- offset as well.
    local ok, name, _, quality = pcall(C_Item.GetItemInfo, itemID)
    if not ok or name == nil then
        -- The flag said yes and the data still is not there. Ask again, or
        -- every later call misses the same way.
        RequestItem(itemID)
        return nil
    end
    return name, quality
end

-- Ask for an item before anyone needs it. The window calls this for the
-- reagents it draws, at build time and on its own refresh, so the data is
-- there before a tooltip can be opened - the placeholder a cache miss shows
-- has nothing to re-run it, so a miss at hover time reads "Loading..." for as
-- long as the cursor stays put.
function API.WarmItem(itemID)
    ResolveItem(itemID)
end

-- Whether an item resolves right now, for a caller deciding if what it has
-- already drawn is out of date.
function API.ItemReady(itemID)
    return (ResolveItem(itemID)) ~= nil
end

function API.ItemInfo(itemID)
    local name, quality = ResolveItem(itemID)
    if not name then return nil end

    local r, g, b = 1, 1, 1
    if quality and C_Item and C_Item.GetItemQualityColor then
        local okColour, qr, qg, qb = pcall(C_Item.GetItemQualityColor, quality)
        if okColour and qr then r, g, b = qr, qg, qb end
    end
    return name, r, g, b
end

-- ─── addon metadata ──────────────────────────────────────────────────────────
-- GetAddOnMetadata moved to C_AddOns.

function API.AddonVersion(addonName)
    local get = C_AddOns and C_AddOns.GetAddOnMetadata
    if get then
        local ok, version = pcall(get, addonName, "Version")
        if ok and version and version ~= "" then return version end
    end
    return "dev"
end

-- ─── client ──────────────────────────────────────────────────────────────────

-- Build number, used to invalidate anything learned from a previous patch.
function API.ClientBuild()
    local ok, _, build = pcall(GetBuildInfo)
    return ok and tostring(build) or "?"
end

-- The client's language. Worth reporting with a bug report and nothing else:
-- spell names are resolved from IDs precisely so no code has to branch on it.
function API.Locale()
    local ok, locale = pcall(GetLocale)
    return (ok and locale) or "?"
end

-- ─── click registration ─────────────────────────────────────────────────────
-- Register BOTH mouse edges. The client decides which one acts.
--
-- Blizzard_FrameXML/SecureTemplates.lua computes, on every click:
--
--     useOnKeyDown = <the button's "useOnKeyDown" attribute>
--                    or GetCVarBool("ActionButtonUseKeyDown")
--     clickAction  = (down and useOnKeyDown) or (not down and not useOnKeyDown)
--
-- which is `down == useOnKeyDown`, so of the two edges exactly one performs
-- the action. Registering both is one cast, right whatever the CVar says and
-- whenever it changes. Registering one edge left rows dead for anyone whose
-- client acts on release (Priestly issue #17). Measured in game: one cast per
-- click with the attribute unset, forced true, and forced false.
--
-- It does not double-cast for two reasons, and the second is the one to check
-- if it ever does: `clickAction` admits one edge, and the other edge can reach
-- the press-and-hold release path only through the "typerelease" attribute.
-- A button that sets "typerelease" WOULD cast twice and spend two reagents.

-- The RegisterForClicks event names to register a secure buff button with.
function API.ClickEdges()
    return "LeftButtonDown", "RightButtonDown", "LeftButtonUp", "RightButtonUp"
end

-- The files THIS copy consists of, so it is always the active copy's own list.
-- lib.Status walks it. Up to r25 the library was six files, each recording
-- itself; since r26 it is one, and an upgrade over r25 replaces the list so
-- the six old records stop counting.
lib.FILES = { "LibGroupBuffs" }

-- The file records itself here on its last line, so a copy that threw partway
-- leaves no record. Reused across upgrades, and every entry is compared with
-- the active MINOR rather than merely being present: after a newer copy threw,
-- the older copy's entries are still here.
lib.fileMinors = lib.fileMinors or {}

end -- Compat

do -- Glass ===================================================================

-- The material is LibGlass-1.0, the "liquid glass" library shared by the Glass
-- addons (github.com/Spotnick2/LibGlass). Up to r25 this section was a v1 copy
-- of it with its own 14 textures; a fix to the material is a LibGlass PR now.
--
-- LibGlass is embedded SIDE BY SIDE, not inside this library: each consuming
-- addon declares it as a .pkgmeta external at Libs\LibGlass-1.0 and its TOC
-- loads LibGlass-1.0.xml BEFORE LibGroupBuffs-1.0.xml. Nested inside this
-- folder it would compute a media path that does not exist (LibGlass derives
-- it from the addon name and its own embed path), and the packager does not
-- fetch an external's own externals anyway.
--
-- One instance serves every window, created on first use and kept across
-- upgrades of this library (lib.glass), so a newer copy never makes a second
-- one. LibGlass migrates its own instances when a newer LibGlass loads.

local GLASS = "LibGlass-1.0"
GLASS_MISSING = MAJOR .. " needs " .. GLASS .. ", which is missing or did not finish "
    .. "loading: embed it at Libs\\" .. GLASS .. " and load its XML before " .. MAJOR .. "'s"

-- Usable means registered AND complete: LibGlass marks itself ready on its
-- last line, so a newer LibGlass copy that threw partway is registered under
-- its MINOR with the older copy's marker still in place.
GlassUsable = function()
    local glass, active = LibStub:GetLibrary(GLASS, true)
    return type(glass) == "table" and active ~= nil and glass.ready == active
end

-- Checked on every use, not only at creation: a LibGlass upgrade that threw
-- after our instance existed would otherwise go unnoticed until a draw failed
-- somewhere less obvious.
GlassInst = function()
    if not GlassUsable() then error(GLASS_MISSING, 2) end
    if lib.glass == nil then lib.glass = LibStub(GLASS):New() end
    return lib.glass
end

end -- Glass

do -- Settings ================================================================

-- ============================================================================
-- Settings.lua  -  one write path for an addon's saved table, and the two
-- checks that watch for the client being fixed or updated.
--
-- On WoW: Forever 1.60.1 nothing an addon writes survives a real restart:
-- account-wide and per-character SavedVariables, and CVars too. The fix is
-- Blizzard's. Until it lands, every addon on the library routes its settings
-- through one setter, so whatever the fix needs - a migration, a validation
-- pass, a different store - lands in one place instead of in each handler.
--
--     local settings = LibStub("LibGroupBuffs-1.0").Settings.New({
--         owner  = "Priestly",
--         scopes = {                     -- the FIRST scope is the settings store
--             { label = "per-character", get = function() ... return PriestlyDB end },
--             { label = "account-wide",  get = function() ... return PriestlySVCheck end },
--         },
--         measuredOnBuild = "69913",     -- in the addon's SOURCE; see CheckBuild
--         -- svBrokenSince / svBrokenOnBuild are accepted and no longer used; see CheckLoad
--         report    = function(text, kind) ... end,  -- required: the library never prints
--         onChanged = function(key) ... end,         -- optional
--     })
--     settings:Set("lockFrame", true)
--     settings:HandleEnteringWorld(isInitialLogin, isReloadingUi)
--
-- The addon owns its SavedVariables: `get` creates the table if it is missing
-- and returns it, and is called on every operation, never cached, so a table
-- replaced or cleared later is still the one written to.
-- ============================================================================

-- Reused across upgrades. Objects hold the shared metatable, and methods are
-- assigned into the shared table, so an object made by an older copy runs the
-- newer methods once one loads.
lib.Settings = lib.Settings or {}
lib.SettingsMethods = lib.SettingsMethods or {}
lib.SettingsMeta = lib.SettingsMeta or {}
local Settings, Methods = lib.Settings, lib.SettingsMethods
lib.SettingsMeta.__index = Methods

-- Written by the load check, so no setter may touch it and no DEFAULTS table
-- may contain it: a default would recreate it every session, and the check
-- could never tell a real load from a fresh start.
Settings.LOAD_CHECK_KEY = "svLoadCheck"

local function Fail(msg) error("LibGroupBuffs Settings.New: " .. msg, 3) end

function Settings.New(spec)
    if type(spec) ~= "table" then Fail("spec must be a table") end
    if type(spec.owner) ~= "string" or spec.owner == "" then
        Fail("owner must name the addon")
    end
    if type(spec.report) ~= "function" then
        Fail("report must be a function - the checks would have no way to speak")
    end
    if spec.onChanged ~= nil and type(spec.onChanged) ~= "function" then
        Fail("onChanged must be a function or nil")
    end
    if type(spec.measuredOnBuild) ~= "string" or spec.measuredOnBuild == "" then
        Fail("measuredOnBuild must be a build number string")
    end
    -- Which build loading is broken on is no longer part of the decision:
    -- the marker carries the build it was written on, and that settles it
    -- (CheckLoad). Both names stay ACCEPTED so the three addons that pass one
    -- keep working until they drop it, and a wrong TYPE is still refused -
    -- silence about a field you passed is worse than an error.
    for _, key in ipairs({ "svBrokenSince", "svBrokenOnBuild" }) do
        if spec[key] ~= nil and (type(spec[key]) ~= "string" or spec[key] == "") then
            Fail(key .. " must be a build number string (it is no longer used; you may drop it)")
        end
    end
    if type(spec.scopes) ~= "table" or #spec.scopes == 0 then
        Fail("scopes must list at least one saved table; the first is the settings store")
    end
    local scopes = {}
    for i, scope in ipairs(spec.scopes) do
        if type(scope) ~= "table" or type(scope.label) ~= "string" or type(scope.get) ~= "function" then
            Fail("scope " .. i .. " needs a label and a get function")
        end
        scopes[i] = { label = scope.label, get = scope.get }
    end
    -- Nothing is created here: the addon's tables may not exist yet.
    return setmetatable({
        owner = spec.owner,
        scopes = scopes,
        report = spec.report,
        onChanged = spec.onChanged,
        measuredOnBuild = spec.measuredOnBuild,
    }, lib.SettingsMeta)
end

local function Store(self)
    local db = self.scopes[1].get()
    if type(db) ~= "table" then
        error(self.owner .. ": the settings scope's get returned no table", 3)
    end
    return db
end

local function Reserved(key)
    if key == Settings.LOAD_CHECK_KEY then
        error("LibGroupBuffs Settings: " .. key .. " belongs to the load check", 3)
    end
end

-- Report a write the owner made itself: a migration, a cache replaced from
-- inside a getter, a write through a local alias. No equality check - the
-- caller already knows it changed something.
function Methods:Changed(key)
    if self.onChanged then self.onChanged(key) end
end

-- An unchanged value is not a change: a caller that sets the same value on
-- every refresh would otherwise run the hook on a hot path. Tables are always
-- reported - the caller may have built a new one with new contents, and
-- comparing them is not this function's job.
function Methods:Set(key, value)
    Reserved(key)
    local db = Store(self)
    if type(value) ~= "table" and db[key] == value then return end
    db[key] = value
    self:Changed(key)
end

-- One entry of a nested table, created if missing. Reported under the table's
-- own key, since that is what was saved.
function Methods:SetIn(tableKey, subKey, value)
    Reserved(tableKey)
    local db = Store(self)
    local t = db[tableKey]
    if type(t) ~= "table" then
        t = {}
        db[tableKey] = t
    end
    if t[subKey] == value then return end
    t[subKey] = value
    self:Changed(tableKey)
end

-- API.ClientBuild answers "?" when the build cannot be read; for these checks
-- that is "unknown", never "a new build".
local function CurrentBuild()
    local api = lib.API
    local build = api and api.ClientBuild and api.ClientBuild()
    if not build or build == "?" then return nil end
    return build
end

-- --- Has Blizzard fixed it? --------------------------------------------------
--
-- Every scope keeps a marker, written every session. If it is there at login,
-- the client read that file. Each scope is checked on its own, because they
-- can be fixed separately.
--
-- A returning marker can still be a false positive, and each case is handled:
--
--   * /reload keeps the client running and can hand back its cached copy.
--     Never announced (`announce` is false).
--   * Logging out to character select and back in is an initial login in the
--     same process, and can be served from the same cache. Lua cannot tell it
--     from a real start, and no clock helps: GetTime on this client is system
--     uptime, not client uptime, so it does not reset across a restart either.
--   * Every login after a real fix, and every later patch. The marker
--     latches `loads` once a restart has proven loading works, and carries it
--     forward for as long as it keeps coming back.
--
-- THE MARKER ANSWERS THIS ITSELF, and no constant is needed for it.
--
-- It records the build it was written on. A build only changes when the
-- client is patched, and applying a patch requires a full exit - so a marker
-- that comes back carrying a DIFFERENT build than the one now running cannot
-- have come from the cache. That process is gone. It was read from disk, and
-- loading works.
--
-- The same build is the ambiguous case, and stays silent: it is what a relog
-- to character select looks like, and it is also what a healthy client looks
-- like session after session. Nothing is lost by saying nothing there. The
-- transition this check exists to catch - broken, then fixed - always arrives
-- WITH a patch, so it always arrives as a build change.
--
-- What this replaces, and why it was wrong in both directions: trusting any
-- build except one named constant announced a fix on every relog (#27, three
-- addons at once, on 69913 -> 69977, which patched WITHOUT fixing loading).
-- Presuming broken from a constant onward then took the noise away but left
-- the detector needing a human to re-measure and ship a new constant before
-- it could ever speak. This needs neither: it is the one comparison that is
-- actually decisive, and it is in data the addon already writes.
local function Marker(holder)
    local previous = holder[Settings.LOAD_CHECK_KEY]
    if type(previous) ~= "table" or previous.stamp == nil then return nil end
    return previous
end

-- A marker written by a build other than the one running now survived a
-- client restart. That proves loading works now, not that it was ever broken:
-- the first such marker is the fix, and the `loads` latch keeps each later
-- patch on a healthy client from announcing it again. An older copy of this library may not have stamped a build
-- at all; unknown is not evidence, so it stays silent.
local function CrossedARestart(previous, build)
    return previous ~= nil and build ~= nil
        and type(previous.build) == "string" and previous.build ~= ""
        and previous.build ~= build
end

function Methods:CheckLoad(announce)
    local build = CurrentBuild()
    local key = Settings.LOAD_CHECK_KEY

    local cameBack = {}
    for _, scope in ipairs(self.scopes) do
        local holder = scope.get()
        if type(holder) == "table" then
            local previous = Marker(holder)
            local crossed = CrossedARestart(previous, build)
            -- r12 latched the same fact as `announced = true` (it read "told
            -- once"); a marker it wrote has no `loads`. Ignoring it would tell
            -- every player r12 already told, again, at the next patch - the
            -- repeat #27 exists to stop (issue #31). Read either, write `loads`.
            local proven = previous ~= nil
                and (previous.loads == true or previous.announced == true)
            if announce and crossed and not proven then
                cameBack[#cameBack + 1] = { label = scope.label, build = previous.build }
            end
            -- Rewritten with the build running NOW, which is what stops this
            -- repeating within a build: every later login reads its own build
            -- back. `loads` stops it repeating across builds: once a restart
            -- has proven loading, the next patch on a healthy client is not
            -- news. It lives only as long as the marker keeps coming back, so
            -- a REGRESSION clears it - the marker stops loading, a fresh one
            -- is written without it - and the fix after that speaks again.
            -- A /reload never sets it: it cannot follow a patch, so it would
            -- latch a claim nobody was told.
            holder[key] = {
                stamp = (type(date) == "function" and date("%Y-%m-%d %H:%M:%S")) or "?",
                build = build,
                loads = (proven or (announce and crossed)) or nil,
            }
        end
    end
    self:Changed(key)

    if #cameBack == 0 then return end
    local labels, builds, oneBuild = {}, {}, true
    for i, entry in ipairs(cameBack) do
        labels[i] = entry.label
        builds[i] = entry.build .. " (" .. entry.label .. ")"
        if entry.build ~= cameBack[1].build then oneBuild = false end
    end
    -- Each scope's marker carries its own build: one character can last have
    -- played on an older build than the account-wide table another updated.
    local saved = oneBuild and ("game build " .. cameBack[1].build)
        or ("game builds " .. table.concat(builds, " and "))
    self.report("Saved settings came back (" .. table.concat(labels, " and ")
        .. "). They were saved on " .. saved .. " and read back on " .. tostring(build)
        .. ", so the game was fully restarted in between - the settings bug is fixed.",
        "settingsLoaded")
end

-- --- Which build were the findings measured on? -----------------------------
--
-- The addon's notes on how this beta behaves were measured on one client
-- build, and the beta updates without announcement. The build lives in the
-- addon's SOURCE, the one thing that survives a restart here: a stored build
-- could never fire, because the build only changes across a restart, which is
-- when stored data is lost.
--
-- Reported at every real login until someone re-measures and bumps the
-- constant. Deliberately not latched: a notice shown once and missed would
-- leave the addon running on stale findings with nothing left to say so.
function Methods:CheckBuild()
    local build = CurrentBuild()
    if not build or build == self.measuredOnBuild then return end
    self.report("This version was tested on game build " .. self.measuredOnBuild
        .. "; you are on " .. build .. ". It should still work, but if anything "
        .. "misbehaves, please report it.", "newBuild")
end

-- PLAYER_LOGIN fires on /reload too and cannot tell the two apart.
-- PLAYER_ENTERING_WORLD can: on 1.60.1.69913 it carries (isInitialLogin,
-- isReloadingUi). It also fires on every zone change with both false, which
-- is ignored. The addon registers the event and passes the payload on.
function Methods:HandleEnteringWorld(isInitialLogin, isReloadingUi)
    if not (isInitialLogin or isReloadingUi) then return end
    local realLogin = isInitialLogin and not isReloadingUi
    self:CheckLoad(realLogin)
    if realLogin then self:CheckBuild() end
end

end -- Settings

do -- Engine ==================================================================

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
        -- How far the GROUP form reaches. On Forever every group buff measured
        -- so far covers the whole raid - all three Prayers read "Power infuses
        -- all party and raid members" in game - which is not what Vanilla and
        -- TBC did, and not what a window drawing one row per subgroup assumes.
        --
        -- Declared by the host rather than guessed: the tooltip saying so is a
        -- localized string, and the only alternative is to assume, which is
        -- silently wrong the day a party-only group buff exists.
        if def.groupScope ~= nil
            and def.groupScope ~= "raid" and def.groupScope ~= "party"
        then
            Fail("def " .. def.id .. ": groupScope must be \"raid\", \"party\" or nil")
        end
    end
    -- The names in a def are the host's own literals right now, so that is
    -- what their provenance is. Stamped HERE rather than left to the first
    -- refresh, because a def with no stamp at all then means something
    -- specific: it was built by a copy of this library older than r16. See
    -- Resolve.
    for _, def in ipairs(host.defs) do
        def.snglFrom = def.snglFrom or "fallback"
        if def.grpID then def.grpFrom = def.grpFrom or "fallback" end
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
--
-- The fallback STAYS. A name that never resolved is the host's enUS literal,
-- and on a client speaking another language it simply never matches an aura -
-- the same outcome as having no name at all, and it cannot match the wrong
-- aura, because a German buff is not called "Prayer of Fortitude". On an
-- English client it is the correct name, so dropping it would only lose
-- matches. What the fallback DOES hide is the failure itself: a whole addon
-- reading every member as unbuffed looks identical to a raid that genuinely
-- has no buffs (priestly#21, reported from a localized client and never
-- diagnosed, because nothing said so).
--
-- So each form records how its name was arrived at, captured BEFORE the
-- fallback is applied:
--
--   "resolved"   the client answered this time
--   "remembered" it did not, but an earlier refresh did - the name is real
--   "fallback"   it never has: this is the host's literal, in English
--   "unknown"    this def predates the tracking: a copy of the library older
--                than r16 built it, LibStub handed the same table to this
--                one, and the name in it may be either
--
-- Per FORM, not per buff: the single spell resolving while the group one does
-- not is the ordinary case at low level, and one flag could not say that.
-- Nothing is inferred from comparing names, either: a locale that leaves a
-- spell untranslated resolves to exactly the literal, and would look like a
-- failure forever.
-- An upgrade in place is why `status == nil` is not the same as "fallback".
-- Engine.New stamps every def it accepts, so a def reaching here unstamped
-- was built by an older copy - and its name may already be a real one the
-- client gave r15. Calling that the host's English literal would send a
-- diagnostic exactly the wrong way, and the name cannot be used to tell:
-- a locale that leaves a spell untranslated resolves to the literal.
local function Resolve(id, current, status)
    local name = id and lib.API.SpellName(id) or nil
    if name then return name, "resolved" end
    -- Nothing came back. Keep what we have, and say what we know about it.
    if status == "resolved" or status == "remembered" then return current, "remembered" end
    return current, status or "unknown"
end

function Methods:RefreshSpells()
    local API = lib.API
    for _, d in ipairs(self.defs) do
        d.sngl, d.snglFrom = Resolve(d.snglID, d.sngl, d.snglFrom)
        if d.grpID then d.grp, d.grpFrom = Resolve(d.grpID, d.grp, d.grpFrom) end
        d.names = { d.sngl, d.grp }
        d.hasSingle = API.KnowsSpell(d.snglID) and true or false
        d.hasGroup = (d.grpID and API.KnowsSpell(d.grpID)) and true or false
    end
    -- Every name anybody is tracking, in one list. An aura pass walks a unit
    -- once against this rather than once per buff, so it has to be rebuilt
    -- wherever the names are - which is here, and nowhere else.
    local all = {}
    for _, d in ipairs(self.defs) do
        for _, nm in ipairs(d.names) do
            if nm then all[#all + 1] = nm end
        end
    end
    self.allNames = all
end

-- What the addon is actually matching auras against, for a bug report. The
-- library answers with data and the host decides how to say it: only the host
-- knows what it calls its buffs, and three addons track different ones.
--
-- `unresolved` is the field worth acting on: a form still on its English
-- fallback is the signature of the bug above. It is not the same as a spell
-- the player has not learned, which is ordinary and appears as known = false,
-- nor as one whose provenance is "unknown", where an older copy of this
-- library built the def and the name may be either.
function Methods:SpellReport()
    local out = { locale = lib.API.Locale and lib.API.Locale() or "?", unresolved = 0 }
    for _, d in ipairs(self.defs) do
        local forms = {}
        forms[#forms + 1] =
            { role = "single", id = d.snglID, name = d.sngl,
              from = d.snglFrom or "unknown", known = d.hasSingle == true }
        if d.grpID then
            forms[#forms + 1] =
                { role = "group", id = d.grpID, name = d.grp,
                  from = d.grpFrom or "unknown", known = d.hasGroup == true }
        end
        for _, form in ipairs(forms) do
            if form.from == "fallback" then out.unresolved = out.unresolved + 1 end
        end
        out[#out + 1] = { id = d.id, label = d.label, forms = forms }
    end

    -- Ranks this client described in words we could not read a number out of.
    -- The subtext is localized, so matching digits is a guess about every
    -- language at once; when the guess fails the rank is UNKNOWN, and what the
    -- client actually said is worth more than any inference from it. Rank
    -- picks the reagent, so this is the difference between counting the right
    -- candle and counting a different one (#64).
    -- Only THIS engine's spells. API.rankUnreadable belongs to the library,
    -- which is shared by three addons, so copying all of it into every report
    -- makes Wildly's report name a Prayer - and a player reading it cannot
    -- tell whether their own addon is the one with the problem.
    local unreadable = lib.API.rankUnreadable
    if unreadable then
        local mine = {}
        for _, d in ipairs(self.defs) do
            if d.grp then mine[d.grp] = true end
            if d.sngl then mine[d.sngl] = true end
        end
        for name, subtext in pairs(unreadable) do
            if mine[name] then
                out.ranks = out.ranks or {}
                out.ranks[#out.ranks + 1] = { name = name, subtext = subtext }
            end
        end
    end
    return out
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

-- ─── Aura passes ────────────────────────────────────────────────────────────
--
-- One refresh asks about every member and every buff, and confirming an
-- absence costs a walk of that member's auras. Done buff-by-buff that is one
-- walk per member per buff; a 40-man raid with three buffs measured ~1700
-- aura reads per pass, several times a second (#6). Inside a pass each member
-- is walked once and every buff reads the answer out of it.
--
-- The boundary is explicit on purpose. A pass that ended on a timer would be
-- a cache that goes stale invisibly; this one is opened and closed by the
-- caller, and a test can put a changed roster between two reads and get two
-- answers.
function Methods:BeginAuraPass()
    -- No names yet means RefreshSpells has not run, and a pass whose union is
    -- empty would match nothing and report every member unbuffed. Refusing to
    -- open one costs the walk sharing and keeps the answer right.
    local all = self.allNames
    if not all or #all == 0 then self.auraPass = nil return end
    self.auraPass = { names = all, units = {} }
end

-- Always safe to call, and always safe to skip: BeginAuraPass replaces
-- whatever was there, so a pass leaked by a throw mid-refresh is discarded at
-- the start of the next one rather than answering for it.
function Methods:EndAuraPass()
    self.auraPass = nil
end

-- A raw aura read, routed through whatever pass is open.
--
-- For a host that asks about auras outside the rows - a visibility rule, say -
-- so that its reads join the pass instead of walking the same members again.
-- Returns what API.ReadBuff returns: "HAS", "NONE" or "BLOCKED", then
-- remaining, duration, expiration, matched name.
function Methods:ReadAura(unit, names)
    return lib.API.ReadBuff(unit, names, self.auraPass)
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
    local status, rem, dur, exp, matched = API.ReadBuff(unit, def.names, self.auraPass)

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

-- Whether a def's group form covers the whole raid. Defaults to raid, because
-- every group buff measured on this client does.
function Methods:IsRaidWide(def)
    return def.hasGroup and (def.groupScope or "raid") == "raid"
end

-- Who to cast a RAID-WIDE group spell at, or nil when nobody needs it.
--
-- The difference from PickTarget is the nil. PickTarget always answers with
-- somebody - the lowest remaining, if nobody is missing - which is right for a
-- cheap single-target top-up and wrong for this: the window draws one row per
-- subgroup, so a raid-wide buff was offered eight times, and each of those
-- clicks cast it again at a reagent each. One cast covers everyone, so once
-- everyone has it there is nothing left to offer and the click goes quiet.
--
-- That is what makes "click any row" safe rather than expensive: PreClick
-- re-picks at click time out of combat, so the second click through the eighth
-- find nobody missing and cast nothing at all.
--
-- Refreshing early is deliberately NOT offered here. It costs a reagent and
-- buys little on an hour-long buff; a member who needs topping up individually
-- is what the single-target click and the popover are for.
function Methods:PickRaidTarget(members, def, st)
    local anyMissing = false
    for _, m in ipairs(members) do
        -- Only somebody we could actually CAST on counts as missing. An
        -- offline or dead member has no buff and cannot be given one, and
        -- PickTarget skips them - so counting them here left every row armed
        -- forever and handed the click an already-buffed member instead. One
        -- disconnected raider would have restored the exact reagent waste this
        -- exists to stop.
        if self:IsValidTarget(m.unit) then
            local known = st and st.byUnit and st.byUnit[m.unit]
            local state = known and known.state
            if not state then local _; _, _, state = self:BuffRem(m.unit, def) end
            if state == ST_MISSING then anyMissing = true break end
        end
    end
    if not anyMissing then return nil end
    return self:PickTarget(members, def, true, st)
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

end -- Engine

do -- UI ======================================================================

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
--         onTick = function(ui, elapsed) end,   -- optional: every ~0.5s while visible
--         onAppearance = function(ui) end,      -- optional: the look was (re)applied
--     })
--
-- A companion pane - a second frame of the addon's own under the window, like
-- Magely's cooldowns - lives on those hooks, and on four rules:
--
--   * NON-SECURE only: plain frames, no secure templates, no attributes. Such
--     a frame anchored to the window is free in combat (measured on 70009,
--     Spotnick2/Magely#12): it can show, hide, resize and re-anchor during a
--     fight. Parent it to UIParent, not to the window: a child of a protected
--     frame is protected too.
--   * Anchored in onLayout, which runs at the end of an out-of-combat Update.
--     It does not run in combat; a pane that changes size during a fight
--     manages that itself.
--   * Visibility follows ui:IsVisible(), via onVisibility: when the window is
--     closed in combat the pane hides AT ONCE, though the window's own frame
--     stays up until the fight ends (the client refuses to hide it).
--   * onTick drives its countdowns: on the window's own half-second tick,
--     in and out of combat, only while the window is visible. `elapsed` is
--     the time since the previous tick. onAppearance re-reads ui:Appearance()
--     and ui:Alpha(): it runs whenever ApplyAppearance does, which the alpha
--     slider and a spec change call without an Update.
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

-- The slice margin the bar textures are DRAWN for. LibGlass's SIZES table
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
    local media = GlassInst().MEDIA
    local mask = box:CreateMaskTexture()
    mask:SetTexture(media .. "bar_mask",
                    "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(box)
    tile:AddMaskTexture(mask)

    local edge = box:CreateTexture(nil, "OVERLAY")
    edge:SetAllPoints(box)
    edge:SetTexture(media .. "bar_edge")
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
    "appearance", "footerItems", "alpha", "scale", "locked", "popoverSide", "showClickHints",
    "getPos", "setPos", "setVisible", "onLayout", "onVisibility", "onCloseDeferred",
    "onTick", "onAppearance",
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

-- How large the window is drawn. SetScale rather than rescaling every
-- constant: it takes the text and the textures with it, needs no layout
-- arithmetic, and cannot get the row maths wrong - and the glass is sized
-- against those constants, so touching them would squeeze the corners flat
-- again (see the note above ROW_H).
--
-- Clamped rather than trusted. A host slider is one typo from 0, which draws
-- nothing and gives the player no way back to the options panel.
local SCALE_MIN, SCALE_MAX = 0.5, 2.5
function Methods:Scale()
    local v = Call(self.host.scale)
    if type(v) ~= "number" or v ~= v then return 1 end
    if v < SCALE_MIN then return SCALE_MIN end
    if v > SCALE_MAX then return SCALE_MAX end
    return v
end

-- One scale for both frames. The popover anchors to a row on the main frame,
-- so scaling them apart makes the anchoring drift.
--
-- Refused in combat, like everything else that touches these frames: both
-- parent secure buttons, and the client silently blocks a SetScale on one.
-- ApplyAppearance runs on every rebuild, so the next one out of combat
-- carries it.
local function ApplyScale(self)
    if InCombatLockdown() then return false end
    local want = self:Scale()
    for _, f in ipairs({ self.main, self.pop }) do
        if f and f.SetScale and (f:GetScale() or 1) ~= want then f:SetScale(want) end
    end
    return true
end

-- ─── The glass material ──────────────────────────────────────────────────────
--
-- LibGlass draws it; this decides where. A panel is the window and the
-- popover; a fill is one coloured row inside them. The material is layered
-- textures, not a shader - what it cannot do is blur what is behind it, so
-- the world shows through sharp. See LibGlass's docs/GLASS-MATERIAL.md.
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
    if f.glass then return f.glass end
    if InCombatLockdown() then return nil end
    if f.SetBackdrop then f:SetBackdrop(nil) end
    f.glass = GlassInst().Apply(f, "large")
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
    if row.fill and rawget(row.fill, FILL_TAG) then return row.fill end
    if InCombatLockdown() then return nil end

    -- r17 put the fill in a child StatusBar. Replacing the reference is not
    -- enough: that frame is still parented to the row and still drawing its
    -- gloss over the icon this change exists to uncover, and a frame cannot
    -- be destroyed on this client. A FRAME has Hide; the table this builds
    -- does not, which is what tells the two apart.
    local previous = row.fill
    if previous and not rawget(previous, FILL_TAG)
        and type(previous.Hide) == "function" then
        previous:Hide()
    end

    local Glass = GlassInst()
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
    if row.bg and row.bg.SetColorTexture then
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
    if main.hdr and rawget(main.hdr, HDR_TAG) then return main.hdr end
    if InCombatLockdown() then return nil end
    local tint = main.hdrBg
    if not tint or not tint.AddMaskTexture then return nil end

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
    local Glass = GlassInst()
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
    if not old or old == tile then return end
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

    if not r.iconEdge then
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

    if not pr.classEdge then
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

local function StyleFooterButton(btn)
    btn:SetSize(FTR_H - 2 + 24, FTR_H)  -- icon + room for the count

    if not btn.iconEdge then
        local old = btn.icon
        btn.icon, btn.iconEdge = IconTile(btn, FTR_H - 4, "LEFT", btn, "LEFT", 0, 0)
        ReplaceIcon(old, btn.icon)
    end

    Style(btn.countTxt, ROW_FONT, "LEFT")
    btn.countTxt:ClearAllPoints()
    btn.countTxt:SetPoint("LEFT", btn.icon, "RIGHT", 4, 0)
end

local function MakeFooterButton(ui, parent)
    local btn = CreateFrame("Button", nil, parent)
    btn._ui = ui
    btn:EnableMouse(true)

    btn.countTxt = btn:CreateFontString(nil, "OVERLAY")
    StyleFooterButton(btn)

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
    xEdge:SetTexture(GlassInst().MEDIA .. "bar_edge")
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

-- The popover's own header. Same rules as StyleHeader.
local function StylePopHeader(pop)
    if not pop.hdrEdge then
        local old = pop.hdrIcon
        pop.hdrIcon, pop.hdrEdge =
            IconTile(pop, POP_HDR_H - 10, "TOPLEFT", pop, "TOPLEFT", 7, -6)
        ReplaceIcon(old, pop.hdrIcon)
    end

    Style(pop.hdrTxt, NAME_FONT, "LEFT")
    pop.hdrTxt:ClearAllPoints()
    pop.hdrTxt:SetPoint("LEFT",  pop.hdrIcon, "RIGHT", 6, 0)
    pop.hdrTxt:SetPoint("RIGHT", pop,         "RIGHT", -6, 0)
    pop.hdrTxt:SetPoint("TOP",   pop,         "TOP",   0, -8)
end

-- This version's header, on a window built a moment ago or by an older copy.
-- Same rules as StyleRow: idempotent, and the tile only if there is not one.
local function StyleHeader(main)
    main.hdrBg:SetHeight(HDR_H)
    -- The drag strip covers the header, so it is the header's height or a
    -- band of it stops answering the mouse. Set once at build before r19,
    -- which left an adopted window draggable only by its top 24px.
    if main.dragHandle then main.dragHandle:SetHeight(HDR_H) end

    if not main.specEdge then
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
    -- Before anything is assigned to self: Init returns early once self.main
    -- exists, so a window that threw halfway through building would stay
    -- half-built, failing every later refresh on some missing part instead
    -- of naming what is missing.
    GlassInst()
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

    pop.hdrTxt = pop:CreateFontString(nil, "OVERLAY")
    StylePopHeader(pop)
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
-- Runs `body` with an aura pass open, and closes it whether body returns or
-- THROWS.
--
-- The throw is the whole reason this exists. A pass belongs to one refresh;
-- one that outlived a failed refresh would still be answering at click time,
-- which is the read that must be live - a member buffed since the snapshot
-- would still look unbuffed, and the click would refuse to fire. Host
-- callbacks run inside both brackets (onLayout, footerItems, the visibility
-- and duration seams), so a throw here is somebody else's bug arriving in the
-- middle of ours. Replacing the pass at the NEXT refresh does not help: the
-- click comes first.
--
-- The error is re-raised at level 0, so it reads as the original message
-- rather than pointing at this line.
local function WithAuraPass(self, body)
    local engine = self.engine
    engine:BeginAuraPass()
    local ok, err = pcall(body, self)
    engine:EndAuraPass()
    if not ok then error(err, 0) end
end

-- One aura pass for the whole refresh. Every row here is asking about the
-- same members at the same instant, and each member's auras are walked once
-- for all of them rather than once per buff (#6).
local function RefreshTimersBody(self)
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

function Methods:RefreshTimers()
    WithAuraPass(self, RefreshTimersBody)
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
--
-- A panel that is already built needs nothing from LibGlass to be recoloured,
-- so a window an older copy built (with its own v1 glass) keeps refreshing even
-- when another addon's newer copy arrived without LibGlass: the material's
-- tint alpha is then the value v1 and LibGlass r1 share. Building still needs
-- LibGlass, and says so.
local BUILT_TINT = { 0.13, 0.16, 0.22, 0.24 }
local function TintPanel(f, colour, alpha)
    local g = Panel(f)
    if not g or not g.tint then return end
    local base = GlassUsable() and GlassInst().STYLE.tint or BUILT_TINT
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
    ApplyScale(self)
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
    -- Last, so a companion reads the look the window now wears.
    Call(self.host.onAppearance, self)
end

-- ─── Footer ─────────────────────────────────────────────────────────────────

-- Counts and colours of the items currently laid out. Cheap; the ticker runs
-- it every few seconds and the addon calls it on BAG_UPDATE.
function Methods:RefreshFooter()
    for i, btn in ipairs(self.footerBtns) do
        local item = self.footerItems[i]
        if item and btn:IsShown() then
            -- Ask for the item's name here, where there is something that
            -- runs again. A tooltip opened on a cache miss shows a
            -- placeholder and has nothing to re-run it, so it would read
            -- "Loading..." for as long as the cursor stayed on it; this runs
            -- at build time and every few seconds after, so by the time
            -- anyone can hover, the data has arrived.
            lib.API.WarmItem(item.itemID)
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
    -- item. The load is asynchronous, though, so remember that this tooltip
    -- is showing a placeholder - the ticker finishes the job when the data
    -- lands, rather than leaving "Loading..." under the cursor.
    GameTooltip:SetText(name or "Loading...", r or 1, g or 1, b or 1)
    self.tipButton = btn
    self.tipPending = (name == nil)
    local have = lib.API.CountItem(btn._itemID)
    GameTooltip:AddLine((have == 1 and "1 in your bags" or (have .. " in your bags")),
        0.85, 0.85, 0.85)
    if btn._usedBy then
        GameTooltip:AddLine("Used by " .. btn._usedBy, 0.55, 0.75, 1.0)
    end
    GameTooltip:Show()
end

-- Redraw a reagent tooltip that is still showing the placeholder, once the
-- item's name arrives. Called from the ticker, which already runs while the
-- cursor sits still.
--
-- Only ever OUR tooltip: GameTooltip is shared, and between the hover and the
-- data arriving the player may have moved onto something else entirely. The
-- owner is checked as well as our own flag, because a tooltip taken over by
-- another addon is not ours to rewrite.
function Methods:RefreshPendingTooltip()
    if not self.tipPending then return end
    local btn = self.tipButton
    if not (btn and btn._itemID) then
        self.tipPending = false
        return
    end
    if GameTooltip:GetOwner() ~= btn or not GameTooltip:IsShown() then
        self.tipPending = false
        return
    end
    if not lib.API.ItemReady(btn._itemID) then return end
    self.tipPending = false
    self:FooterEnter(btn)
end

function Methods:FooterLeave()
    self.tipPending = false
    self.tipButton = nil
    ReleaseTooltip()
end

-- ─── Ticker ─────────────────────────────────────────────────────────────────

function Methods:MainTick(dt)
    if not self.visible then return end
    self.tick = self.tick + dt
    self.footerTick = self.footerTick + dt
    if self.tick >= 0.5 then
        local elapsed = self.tick
        self.tick = 0
        self:RefreshTimers()
        -- On the half-second tick, not the footer's three: a placeholder
        -- under the cursor is what the player is looking at, and three
        -- seconds of "Loading..." is most of a hover.
        self:RefreshPendingTooltip()
        -- The window's clock, for a companion's countdowns: one clock, and it
        -- stops when the window is closed, which a pane's own OnUpdate would
        -- have to track for itself.
        Call(self.host.onTick, self, elapsed)
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
    -- Both sides in PHYSICAL pixels. A row's GetCenter is in its own frame's
    -- coordinate space, and scaling the window makes that a different space
    -- from UIParent's - so comparing them directly is right only at scale 1,
    -- and at scale 2 a row against the right edge reports a number from the
    -- left half and the popover opens into the crowded side.
    --
    -- Multiplying by the effective scale is what the client's own
    -- GetScaledCenter does (Blizzard_SharedXMLBase/FrameUtil.lua:226 in
    -- C:/Projects/wow-ui-source).
    local rowMid    = rowX * anchorRow:GetEffectiveScale()
    local screenMid = screenW * UIParent:GetEffectiveScale() / 2
    return (rowMid < screenMid) and "right" or "left"
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

-- Where a row's LEFT click is aimed, re-picked now rather than trusted from
-- the last layout. A raid-wide group buff is aimed across the roster and
-- answers nil once nobody needs it; everything else keeps the old behaviour of
-- picking inside the row's own members.
local function PrimaryPick(engine, r)
    if r._castMembers then return engine:PickRaidTarget(r._castMembers, r._def) end
    return engine:PickTarget(r._members, r._def, r._groupMode)
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
        local unit
        if which == 1 then
            unit = PrimaryPick(engine, row)
        else
            unit = engine:PickTarget(row._members, def, false)
        end
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
        -- THE moment the reagent is saved. A raid-wide buff is drawn on one
        -- row per subgroup, so it is offered eight times in a full raid; this
        -- re-picks at click time, finds nobody left missing after the first
        -- cast, and clears the spell. Clicks two through eight cast nothing.
        local unit = PrimaryPick(engine, r)
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
    local pUnit = r._primary   and PrimaryPick(engine, r) or nil
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
-- When the window is still on screen, a deferred close calls the addon's
-- onCloseDeferred, so every way of closing - the X button, a slash command, a
-- keybind, AND the addon's own automatic closes - explains itself the same
-- way. An automatic close used to say nothing (#45): a player who unticked
-- "show when solo" mid-fight watched the window stay up, apparently ignored.
-- `manual` decides only whether the close is saved as the player's
-- preference, never whether it is explained. What matters is that a frame
-- is still visible, NOT whether the window was logically open: a close after
-- an automatic one during the same fight finds `visible` already false. Said
-- once per pending close, not once per click. The return value is there for
-- a caller that wants to handle it itself.
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
        if not self.closeExplained and self.main and self.main:IsShown() then
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
    if self.pop then StylePopHeader(self.pop) end
    for _, r   in ipairs(self.rows)       do StyleRow(r) end
    for i, pr  in ipairs(self.popRows)    do StylePopRow(pr, i) end
    -- The footer's buttons are built lazily, one per item the host offers, so
    -- there may be none yet - and LayoutFooter adds more later. New ones come
    -- out of MakeFooterButton already styled; these are the ones r18 made.
    for _, btn in ipairs(self.footerBtns) do StyleFooterButton(btn) end
    for _, fs in ipairs(self.headers) do
        Style(fs, GRP_FONT, "CENTER")
        fs:SetWidth(ROW_W)
    end

    -- Blizzard's close button has no label of ours. It cannot be destroyed,
    -- so it is hidden, unhooked from the mouse, and replaced.
    local x = main.closeBtn
    if x and not x.label then
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

-- The rebuild proper. Split from Update so it can run inside WithAuraPass,
-- and so the combat branch stays OUTSIDE it: that branch calls RefreshTimers,
-- which opens a pass of its own, and a pass nested inside a pass would have
-- the inner one's close end the outer.
local function Rebuild(self)
    if not self:Init() then return end
    -- Before anything is measured or placed: a window an older copy built
    -- arrives here with the previous layout, and every position below is
    -- computed from this one's metrics.
    self:AdoptLayout()
    local engine = self.engine
    local main = self.main

    local groups, ord = engine:GatherGroups()
    if #ord == 0 then self:Close(); return end

    -- The pass this runs inside is open from the top, which puts ActiveDefs
    -- inside it too - deliberately. A host's visibility rule can read auras:
    -- Priestly's "show Shadow Protection when somebody has it" walks the whole
    -- roster looking for one, immediately before these rows ask about the same
    -- members (#6).
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

    -- Each buff's members for each group, asked ONCE: the same list then drives
    -- the stats, the targets, the popover and the clicks, so they cannot
    -- disagree. A group where no buff covers anybody (Thorns on tanks, and this
    -- group has none) gets no header and no rows.
    --
    -- The raid-wide lists are stitched together from THESE lists rather than
    -- asked for again. A host's membersFor is a callback and may answer
    -- differently between calls; asking twice made the row show somebody
    -- needing the buff while the click aimed at a list they were not in.
    local plan, raidWide = {}, {}
    for _, gNum in ipairs(ord) do
        local rowsHere = {}
        for _, def in ipairs(defs) do
            local members = engine:MembersFor(def, groups[gNum])
            if #members > 0 then
                rowsHere[#rowsHere + 1] = { def = def, members = members }
                -- One cast of a raid-wide buff covers everyone, so its target
                -- is chosen across the roster rather than inside one subgroup.
                -- That is what lets a click on any row fix everybody, and what
                -- leaves the other rows' clicks nothing to do.
                if engine:IsRaidWide(def) then
                    local all = raidWide[def.id]
                    if not all then all = {}; raidWide[def.id] = all end
                    for _, m in ipairs(members) do all[#all + 1] = m end
                end
            end
        end
        plan[#plan + 1] = { gNum = gNum, rows = rowsHere }
    end

    for _, step in ipairs(plan) do
        if rowIdx >= maxRows then break end
        local gNum, rowsHere = step.gNum, step.rows

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
                -- A raid-wide group spell is aimed across the roster and goes
                -- quiet once nobody needs it; a party-scope one keeps picking
                -- inside this row's own members, as it always did.
                local castMembers = raidWide[def.id] or members
                local primaryUnit
                if primary and raidWide[def.id] then
                    primaryUnit = engine:PickRaidTarget(castMembers, def)
                elseif primary then
                    primaryUnit = engine:PickTarget(members, def, groupMode, st)
                end
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
                -- Kept on the row so PreClick and the tooltip re-pick against
                -- the same list this pass used. Nil for a party-scope def,
                -- which reads as "use my own members".
                r._castMembers = raidWide[def.id]

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

function Methods:Update()
    if InCombatLockdown() then
        if self.visible then
            self:RefreshTimers()
        else
            self.pendingShow = true
        end
        return
    end
    WithAuraPass(self, Rebuild)
end

-- ─── Is this copy usable? ───────────────────────────────────────────────────
--
-- Called on whichever copy is active, which may be newer than the host's own.
-- If this copy threw before getting here, the previous copy's Status is still
-- on the table and answers "incomplete", because this copy replaced lib.FILES
-- and never wrote its record; if there is no Status at all, a host treats
-- that absence as "incomplete".
--
--     local status = lib.Status and lib.Status(NEEDS_MINOR)
--
-- Returns one of:
--
--   "ok"          the copy finished loading, and the active MINOR is at least
--                 the host's floor
--   "incomplete"  the copy did not reach its last line - or an older copy's
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
    -- The window draws through LibGlass, so a copy without it is as unusable
    -- as one that did not finish. Asked of the ACTIVE copy, this is also what
    -- an r25 host is told when another addon's newer copy came without it.
    if not GlassUsable() then return "incomplete", active end
    if type(needsMinor) == "number" and active < needsMinor then
        return "too-old", active
    end
    return "ok", active
end

end -- UI

do -- Visibility ==============================================================

-- ============================================================================
-- Visibility.lua  -  when the window opens itself, and when it must not.
--
-- Priestly, Wildly and Magely each carried their own copy of this, near
-- line-for-line. Every defect that produced had the same shape: found in one
-- addon, fixed there, and left standing in the other two - a roster arriving
-- after login counting as a join, a settings change reopening a window the
-- player closed, a solo toggle dropped in combat, and more.
--
-- The list is on #22, in one place. A tally repeated in each file is a tally
-- that drifts out of step with the other two, which is exactly the failure
-- mode this file exists to end.
--
-- So the DECISION lives here. The addon still owns its events, its slash
-- commands and its class: it reports what changed, this decides whether that
-- warrants opening, closing or refreshing, and UI carries the request out
-- safely.
--
--     local vis = LibStub("LibGroupBuffs-1.0").Visibility.New({
--         ui            = ui,
--         isMyClass     = function() return g_IsPriest end,   -- optional
--         showSolo      = function() return Priestly_ShowSolo() end,
--         getPreference = function() return Priestly_WindowVisible() end,
--         setPreference = function(v) Priestly_SetWindowVisible(v) end,
--     })
--
-- and from the addon's own event handler:
--
--     vis:Login()            -- a new session; opens if it should
--     vis:ReadyCheck()
--     vis:GroupJoined()      -- the client's own join event
--     vis:RosterChanged()    -- after the host has pruned its caches
--     vis:SoloToggled(on)
--     vis:ContentChanged()   -- something may have given the window rows
--
-- PREFERENCE is not VISIBILITY. `getPreference` is the saved "the player wants
-- this window", which is true, false, or nil for never said; `ui:IsVisible()`
-- is whether the window is logically open right now, and the two disagree all
-- the time - in combat the frame can still be on screen after a close, and a
-- window that closed itself for want of rows never wrote false. Never cache
-- the preference: the close button and the addon's own slash commands change
-- it without passing through here.
-- ============================================================================

-- Reused across upgrades. Objects hold the shared metatable, and methods are
-- assigned into the shared table, so an object an older copy made runs the
-- newer methods once one loads - including one that has already observed a
-- roster or latched a join, which is the state that matters.
lib.Visibility = lib.Visibility or {}
lib.VisibilityMethods = lib.VisibilityMethods or {}
lib.VisibilityMeta = lib.VisibilityMeta or {}
local Visibility, Methods = lib.Visibility, lib.VisibilityMethods
lib.VisibilityMeta.__index = Methods

local function Fail(msg)
    error("LibGroupBuffs Visibility: " .. msg, 3)
end

local function Call(fn, ...)
    if type(fn) ~= "function" then return nil end
    return fn(...)
end

function Visibility.New(spec)
    if type(spec) ~= "table" then Fail("New(spec) needs a table") end
    if type(spec.ui) ~= "table" then Fail("spec.ui must be the window object") end
    for _, name in ipairs({ "getPreference", "setPreference" }) do
        if type(spec[name]) ~= "function" then
            Fail(name .. " must be a function: the addon owns where its settings live")
        end
    end
    for _, name in ipairs({ "isMyClass", "showSolo" }) do
        if spec[name] ~= nil and type(spec[name]) ~= "function" then
            Fail(name .. " must be a function or nil")
        end
    end

    local self = setmetatable({
        ui            = spec.ui,
        isMyClass     = spec.isMyClass,
        showSolo      = spec.showSolo,
        getPreference = spec.getPreference,
        setPreference = spec.setPreference,
        -- How many people we have SEEN, or nil for "not looked yet". The
        -- difference is the whole point: a join is a 0-to-n change where the 0
        -- was observed, and GetNumGroupMembers() can read 0 at login while
        -- already in a group.
        lastGroupSize = nil,
        -- Set by the client's own join event, spent by the roster that follows.
        joinedPending = false,
    }, lib.VisibilityMeta)
    return self
end

-- Is this addon's window for this character at all? A host that does not say
-- is always eligible.
function Methods:Eligible()
    if self.isMyClass == nil then return true end
    return Call(self.isMyClass) and true or false
end

-- Would the window open by itself right now? In a group, or solo mode - and
-- never over a close the player asked for.
function Methods:WantsOpen()
    if not self:Eligible() then return false end
    if Call(self.getPreference) == false then return false end
    if GetNumGroupMembers() > 0 then return true end
    return Call(self.showSolo) and true or false
end

-- A new session. Whatever was seen before this login was not seen in it, and
-- an upgrade mid-session deliberately does NOT reset these - only a login does.
function Methods:Login()
    self.lastGroupSize = nil
    self.joinedPending = false
    if self:WantsOpen() then self.ui:Open(0.6) end
end

-- A ready check is a good moment to rebuff, but not a reason to override
-- someone who closed the window.
function Methods:ReadyCheck()
    if not self:Eligible() then return end
    if Call(self.getPreference) == false then return end
    self.ui:Open(0.4)
end

-- The client saying you joined, rather than us inferring it from the roster
-- changing. It fires: Blizzard's own UI for this build registers and acts on
-- it (Blizzard_DamageMeter/DamageMeter.lua:78 in C:/Projects/wow-ui-source).
-- Latched rather than acted on here: the roster that follows is what knows how
-- many people there are.
function Methods:GroupJoined()
    self.joinedPending = true
end

-- The roster changed. Joining is the one case that reopens a window the player
-- deliberately closed - that is advertised behaviour - and any other churn
-- leaves the close alone.
function Methods:RosterChanged()
    local n = GetNumGroupMembers()
    -- The join event if the client sent one, and otherwise the roster: nil is
    -- not 0, so the first roster we ever see tells us where we are and not
    -- that somebody just invited us. The event is what makes logging in alone
    -- and then being invited work, because there may be no zero-member roster
    -- in between for the fallback to measure against.
    local joined = self.joinedPending or (self.lastGroupSize == 0 and n > 0)
    self.joinedPending = false
    self.lastGroupSize = n

    if joined then Call(self.setPreference, true) end
    local ui = self.ui
    if n > 0 and not ui:IsVisible() and self:Eligible()
        and (joined or Call(self.getPreference) ~= false)
    then
        ui:Open(0.5)
    elseif n == 0 and not (Call(self.showSolo) and true or false) then
        ui:Close()   -- auto-close, not manual
    else
        ui:ScheduleRefresh()
    end
end

-- The solo checkbox. Not refused in combat: ui:Open and ui:Close both remember
-- what was asked and carry it out when the fight ends, so ticking the box
-- mid-fight is honoured rather than lost.
function Methods:SoloToggled(enabled)
    if not self:Eligible() then return end
    local ui = self.ui
    if enabled then
        if not ui:IsVisible() then
            Call(self.setPreference, true)
            ui:Open(0.1)
        end
    elseif GetNumGroupMembers() == 0 then
        ui:Close()
    end
end

-- Something may have given the window rows, or taken them away: a setting, a
-- spell learned, a tank appearing, an aura landing. One method for all of
-- them, because the decision is the same and splitting it is what left copies
-- of it in each host's handlers.
--
-- A window that closed ITSELF for want of rows is not a close the player
-- asked for, so this may reopen it - WantsOpen is what tells the two apart.
-- Whether the notification is meaningful at all stays with the host: Magely
-- does not ask after an aura in combat, because an aura cannot be read then.
function Methods:ContentChanged()
    local ui = self.ui
    if ui:IsVisible() then
        if not InCombatLockdown() then ui:Open(0.1) end
    elseif self:WantsOpen() then
        ui:Open(0.1)
    end
end

end -- Visibility

do -- New =====================================================================

-- lib:New(opts): the per-addon entry point. LibGlass-1.0's shape, so one rule
-- covers both libraries.
--
--     local GB = LibStub("LibGroupBuffs-1.0"):New({
--         owner  = "Priestly",                 -- required, unique per session
--         report = function(text, kind) end,   -- required: the library never prints
--         needs  = 26,                         -- optional floor: the MINOR this build needs
--     })
--     local engine = GB.Engine(host)            -- dot calls, like LibGlass's
--     local ui     = GB.UI(host)                -- host.owner filled in if absent
--     local cfg    = GB.Settings(spec)          -- spec.owner / spec.report filled in if absent
--     local vis    = GB.Visibility(spec)
--     GB.RegisterEvents(frame, "PLAYER_LOGIN", ...)   -- rejections reach report(text, "events")
--     GB.EventFailures()                       -- { [event] = why } for this owner, or nil
--     GB.TimerColor(pct), GB.Pct(rem, dur), GB.FmtTime(s)
--     GB.API, GB.STATES, GB.PET_GROUP, GB.LOAD_CHECK_KEY, GB.CLASS_ICONS, GB.MINOR
--
-- New does the version check a host used to carry in its own bridge: it
-- errors unless the active copy finished loading, LibGlass-1.0 is usable and
-- the active MINOR is at least `needs`. A host pcalls it and prints the error
-- with its own prefix.
--
-- Upgrade rules (EMBEDDED-LIBRARIES.md §5): every instance function looks up
-- lib.impl.<name> WHEN IT RUNS, so an instance an older copy made runs the
-- newest copy's code; lib.impl, lib.instances and lib.shared keep their
-- identity and are filled in place; a newer copy only ADDS functions an older
-- instance lacks, it never replaces one. Shared values are data only - a
-- function reached through lib.shared and held by a host would be the copy
-- that put it there, forever.
--
-- The older entry points (lib.Engine.New, lib.UI.New, lib.Settings.New,
-- lib.Visibility.New, lib.API, lib.Status) stay exactly as they are: hosts
-- built against r25 and earlier call them.

lib.impl = lib.impl or {}
lib.instances = lib.instances or {}
lib.shared = lib.shared or {}
lib.instanceMT = lib.instanceMT or {}
lib.instanceMT.__index = lib.shared

-- Read-only data, the active copy's.
lib.shared.API = lib.API
lib.shared.STATES = lib.Engine.STATES
lib.shared.PET_GROUP = lib.Engine.PET_GROUP
lib.shared.LOAD_CHECK_KEY = lib.Settings.LOAD_CHECK_KEY
lib.shared.CLASS_ICONS = lib.UI.CLASS_ICONS
lib.shared.MINOR = MINOR

local impl = lib.impl

-- A constructor's argument errors name the line that called it, at level 3
-- from its Fail helper. Reached through an instance, level 3 is a library
-- frame - in Lua 5.1 the marker a tail call leaves, which has no position at
-- all - so the host's line was lost. Caught here without a position and
-- raised again at the host's level: 1 is Construct, 2 impl, 3 the instance
-- function, 4 the host. (Lua 5.1 counts a tail call as a level too, so the
-- count holds whether or not those frames tail-call.)
local function Construct(new, arg)
    local ok, made = pcall(new, arg)
    if not ok then error(made, 4) end
    return made
end

function impl.Engine(_, host)
    return Construct(lib.Engine.New, host)
end

function impl.UI(inst, host)
    if type(host) == "table" and host.owner == nil then host.owner = inst.owner end
    return Construct(lib.UI.New, host)
end

function impl.Settings(inst, spec)
    if type(spec) == "table" then
        if spec.owner == nil then spec.owner = inst.owner end
        if spec.report == nil then spec.report = inst.report end
    end
    return Construct(lib.Settings.New, spec)
end

function impl.Visibility(_, spec)
    return Construct(lib.Visibility.New, spec)
end

-- One reporter for everything an instance has to say: rejected events arrive
-- as text, like the settings checks' messages, with kind "events".
function impl.RegisterEvents(inst, frame, ...)
    return lib.API.RegisterEventsReported(frame, inst.owner, function(failed)
        inst.report("unsupported events skipped: " .. table.concat(failed, ", "), "events")
    end, ...)
end

function impl.EventFailures(inst)
    return lib.API.eventFailuresByOwner[inst.owner]
end

function impl.TimerColor(_, pct) return lib.UI.TimerColor(pct) end
function impl.Pct(_, rem, dur) return lib.UI.Pct(rem, dur) end
function impl.FmtTime(_, s) return lib.UI.FmtTime(s) end

-- The functions an instance carries. A newer copy appends; it never removes.
local FUNCTIONS = { "Engine", "UI", "Settings", "Visibility", "RegisterEvents", "EventFailures",
                    "TimerColor", "Pct", "FmtTime" }

-- Give an instance every function it lacks. Never overwrites: a function an
-- older copy bound already dispatches through lib.impl, and a host may have
-- wrapped one. rawget, because the instance reads lib.shared through its
-- metatable, and a shared value must never stand in for a function.
local function Migrate(inst)
    for _, name in ipairs(FUNCTIONS) do
        if rawget(inst, name) == nil then
            inst[name] = function(...) return lib.impl[name](inst, ...) end
        end
    end
end

function lib:New(opts)
    if self ~= lib then
        error(MAJOR .. ": call New with a colon - LibStub(\"" .. MAJOR .. "\"):New(opts)", 2)
    end
    if type(opts) ~= "table" then error(MAJOR .. ": New needs an options table", 2) end
    local owner, report, needs = opts.owner, opts.report, opts.needs
    if type(owner) ~= "string" or owner == "" then
        error(MAJOR .. ": New needs opts.owner, the addon's name", 2)
    end
    if type(report) ~= "function" then
        error(MAJOR .. ": New needs opts.report(text, kind) - the library never prints", 2)
    end
    if needs ~= nil and type(needs) ~= "number" then
        error(MAJOR .. ": opts.needs must be a MINOR number", 2)
    end
    if lib.instances[owner] ~= nil then
        error(MAJOR .. ": " .. owner .. " already has an instance - New is called once per addon", 2)
    end
    -- The state checks are for players, not developers: no file position.
    local _, active = LibStub:GetLibrary(MAJOR, true)
    if lib.ready ~= active then
        error(MAJOR .. " r" .. tostring(active) .. " did not finish loading - another addon's copy "
            .. "failed; the first error this session names it", 0)
    end
    if not GlassUsable() then error(GLASS_MISSING, 0) end
    if needs and active < needs then
        error(owner .. " needs " .. MAJOR .. " r" .. needs .. " or newer, and the newest copy "
            .. "loaded is r" .. active .. " - nothing is broken, an addon is out of date", 0)
    end
    local inst = setmetatable({ owner = owner, report = report, needs = needs }, lib.instanceMT)
    Migrate(inst)
    lib.instances[owner] = inst
    return inst
end

-- An upgrade reaches the instances an older copy made.
for _, inst in pairs(lib.instances) do Migrate(inst) end

-- Internals for the tests only.
lib._test = { Migrate = Migrate, FUNCTIONS = FUNCTIONS }

end -- New

-- ============================================================================
-- Last, so a copy that threw partway through is not marked complete: Status
-- and New compare this with the active MINOR, and after a newer copy threw,
-- the older copy's marker is still here with the older number.
--
-- The named per-file markers are written too, all at once and all equal:
-- hosts released before lib.Status (Priestly v2.0.5-v2.0.6, Wildly v1.0.0,
-- pins r5-r11) decide whether the library loaded by reading them, and refuse
-- to start when one is missing or older than the active MINOR.
-- ============================================================================
lib.compatMinor, lib.glassMinor, lib.settingsMinor = MINOR, MINOR, MINOR
lib.engineMinor, lib.uiMinor, lib.visibilityMinor = MINOR, MINOR, MINOR
lib.fileMinors.LibGroupBuffs = MINOR
lib.ready = MINOR
