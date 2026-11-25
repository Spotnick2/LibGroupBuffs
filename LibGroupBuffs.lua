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

local MAJOR, MINOR = "LibGroupBuffs-1.0", 39
local lib = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end          -- an equal or newer copy is already loaded

-- Private to this copy and shared by its sections: assigned in the Glass
-- section, read by the window, lib.Status and lib:Refusal.
local GlassState, GlassUsable, GlassInst, GLASS_MISSING, GlassTooOld, GlassFontFile

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

-- Merchant and bag APIs are kept here so consumers do not bind client globals.
function API.MerchantItem(index)
    if not (C_MerchantFrame and C_MerchantFrame.GetItemInfo and GetMerchantItemID) then return nil end
    local ok, info = pcall(C_MerchantFrame.GetItemInfo, index)
    if not ok or not info then return nil end
    local idOk, itemID = pcall(GetMerchantItemID, index)
    if idOk then return itemID, info end
end

function API.MerchantItemCount()
    if not GetMerchantNumItems then return 0 end
    local ok, count = pcall(GetMerchantNumItems)
    return ok and type(count) == "number" and count or 0
end

function API.Money()
    if not GetMoney then return 0 end
    local ok, money = pcall(GetMoney)
    return ok and type(money) == "number" and money or 0
end

function API.BuyMerchantItem(index, quantity)
    if not BuyMerchantItem then return false end
    return pcall(BuyMerchantItem, index, quantity)
end

-- Conservative room estimate: partial stacks and ordinary bag slots only.
-- Specialty bags are omitted unless the item already has a partial stack there.
function API.ItemRoom(itemID)
    if not (C_Item and C_Item.GetItemMaxStackSizeByID and C_Container
        and C_Container.GetContainerNumFreeSlots and C_Container.GetContainerNumSlots
        and C_Container.GetContainerItemInfo) then return 0 end
    local ok, stackSize = pcall(C_Item.GetItemMaxStackSizeByID, itemID)
    if not ok or type(stackSize) ~= "number" or stackSize < 1 then return 0 end
    local room = 0
    local bags = {}
    for bag = 0, (NUM_BAG_SLOTS or 4) do bags[#bags + 1] = bag end
    local reagentBag = Enum and Enum.BagIndex and Enum.BagIndex.ReagentBag
    if reagentBag then bags[#bags + 1] = reagentBag end
    for _, bag in ipairs(bags) do
        local freeOk, free, family = pcall(C_Container.GetContainerNumFreeSlots, bag)
        if freeOk and type(free) == "number" and (family == 0 or family == nil) then
            room = room + free * stackSize
        end
        local slotsOk, slots = pcall(C_Container.GetContainerNumSlots, bag)
        if slotsOk and type(slots) == "number" then
            for slot = 1, slots do
                local itemOk, entry = pcall(C_Container.GetContainerItemInfo, bag, slot)
                if itemOk and entry and entry.itemID == itemID then
                    room = room + math.max(0, stackSize - (entry.stackCount or stackSize))
                end
            end
        end
    end
    return room
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

-- THE LibGlass rule, the only copy: usable means registered AND complete.
-- LibGlass marks itself ready on its last line, so a newer LibGlass copy that
-- threw partway is registered under its MINOR with the older copy's marker
-- still in place. Returns nil when usable, else why - "glass-missing" or
-- "glass-incomplete" - and LibGlass's active MINOR when it is registered.
GlassState = function()
    local glass, glassMinor = LibStub:GetLibrary(GLASS, true)
    if type(glass) ~= "table" or glassMinor == nil then return "glass-missing", nil end
    if glass.ready ~= glassMinor then return "glass-incomplete", glassMinor end
    return nil, glassMinor
end

GlassUsable = function()
    return GlassState() == nil
end

-- The window wears LibGlass's clean preset (r29), which exists from r6: an
-- older LibGlass ignores the option and silently draws the original look, so
-- CREATING the instance needs r6. It is a floor on building, not on being
-- usable: a window already built, or an instance an older copy already made,
-- keeps refreshing on whatever LibGlass is loaded. Returns the LibGlass MINOR
-- when it is below the floor, else nil.
local GLASS_FLOOR = 6
GlassTooOld = function()
    local _, glassMinor = LibStub:GetLibrary(GLASS, true)
    if type(glassMinor) == "number" and glassMinor < GLASS_FLOOR then return glassMinor, GLASS_FLOOR end
    return nil
end

-- Checked on every use, not only at creation: a LibGlass upgrade that threw
-- after our instance existed would otherwise go unnoticed until a draw failed
-- somewhere less obvious.
GlassInst = function()
    if not GlassUsable() then error(GLASS_MISSING, 2) end
    if lib.glass == nil then
        local old = GlassTooOld()
        if old then
            error(MAJOR .. " needs " .. GLASS .. " r" .. GLASS_FLOOR .. " or newer to build its window, "
                .. "and the newest copy loaded is r" .. old .. ": update the addon that embeds it", 2)
        end
        lib.glass = LibStub(GLASS):New({ preset = "clean" })
    end
    return lib.glass
end

-- The file the window's text is drawn in: LibGlass's Arial Narrow member,
-- which from LibGlass r12 is chosen by the client's language (#84,
-- LibGlass#69). A font file has no per-character fallback, so Arial Narrow
-- draws Korean and Chinese as empty boxes, and on those clients LibGlass
-- names the file Blizzard uses instead. Before r12 it is Arial Narrow on every
-- client, and so is the fallback here when LibGlass or its table is missing.
GlassFontFile = function(fallback)
    local glass = LibStub:GetLibrary(GLASS, true)
    local fonts = type(glass) == "table" and rawget(glass, "FONTS")
    local arial = type(fonts) == "table" and fonts.arial
    local file = type(arial) == "table" and arial.file
    if type(file) == "string" and file ~= "" then return file end
    return fallback
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
        -- Raid assignments (r37, the Assign section): which slot a def is,
        -- by its snglID or assignSlot. Checked here so a typo is a load error.
        if def.assign ~= nil and def.assign ~= "owner" and def.assign ~= "targets" then
            Fail("def " .. def.id .. ": assign must be \"owner\", \"targets\" or nil")
        end
        -- Auras that cover this buff (r38, #95): a stronger buff the client
        -- refuses to cast over. See Methods:CoverOf.
        if def.coveredBy ~= nil then
            if type(def.coveredBy) ~= "table" then
                Fail("def " .. def.id .. ": coveredBy must be a list of spell IDs or nil")
            end
            for _, id in ipairs(def.coveredBy) do
                if type(id) ~= "number" then
                    Fail("def " .. def.id .. ": coveredBy must list spell IDs (numbers)")
                end
            end
        end
    end
    if host.assignments ~= nil and type(host.assignments) ~= "table" then
        Fail("assignments must be the handle GB.Assignments returned, or nil")
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
        -- The raid's assignments (r37), or nil for an engine that has none.
        assignments = host.assignments,
        -- [unitKey] = { [defId] = { exp, dur, spell, stamp } }. Per engine:
        -- def ids are only unique within one addon.
        cache = {},
        -- [unitKey] = { [defId] = { name, exp, stamp } or { none, stamp } }:
        -- the covering aura last seen (r38). Apart from `cache`, so a buff's
        -- own entry keeps its shape. An engine an older copy built gets it
        -- on first use.
        coverCache = {},
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

-- Covering auras (r38, #95) by name, resolved from their IDs like the buff's
-- own. By ID a name resolves whether or not the player knows the spell, which
-- a world buff never is. There is no English fallback: an ID this client does
-- not have covers nothing. A name resolved once is remembered, as the buff's
-- own names are, and several IDs sharing one name (a buff's variants) count
-- once. `coverSingles` holds each name as a one-name list, for CoverOf.
local function ResolveCovers(d)
    if not d.coveredBy then
        d.coverNames, d.coverByID, d.coverSingles = nil, nil, nil
        return
    end
    local byID = d.coverByID or {}
    d.coverByID = byID
    local list, singles, seen = {}, {}, {}
    for _, id in ipairs(d.coveredBy) do
        byID[id] = lib.API.SpellName(id) or byID[id]
        local nm = byID[id]
        if nm and not seen[nm] then
            seen[nm] = true
            list[#list + 1] = nm
            singles[#singles + 1] = { nm }
        end
    end
    d.coverNames, d.coverSingles = list, singles
end

-- The covering names, resolved now if no refresh by this copy has: a def an
-- older copy refreshed carries `coveredBy` but none of what it derives. Until
-- the host's next RefreshSpells the pass union lacks them, so their reads go
-- live (API.PassCovers): slower, never wrong.
local function CoverNames(d)
    if not d.coveredBy then return nil end   -- cleared since the last refresh
    if not d.coverSingles then ResolveCovers(d) end
    return d.coverNames
end

function Methods:RefreshSpells()
    local API = lib.API
    for _, d in ipairs(self.defs) do
        d.sngl, d.snglFrom = Resolve(d.snglID, d.sngl, d.snglFrom)
        if d.grpID then d.grp, d.grpFrom = Resolve(d.grpID, d.grp, d.grpFrom) end
        d.names = { d.sngl, d.grp }
        d.hasSingle = API.KnowsSpell(d.snglID) and true or false
        d.hasGroup = (d.grpID and API.KnowsSpell(d.grpID)) and true or false
        ResolveCovers(d)
    end
    -- Every name anybody is tracking, in one list. An aura pass walks a unit
    -- once against this rather than once per buff, so it has to be rebuilt
    -- wherever the names are - which is here, and nowhere else. Covering
    -- auras are in it too: a pass that did not walk for them could not
    -- answer for them (API.PassCovers), and each would cost a walk of its own.
    local all = {}
    for _, d in ipairs(self.defs) do
        for _, nm in ipairs(d.names) do
            if nm then all[#all + 1] = nm end
        end
        for _, nm in ipairs(d.coverNames or {}) do all[#all + 1] = nm end
    end
    self.allNames = all
    -- A rank learned or a spell changed: what bounced may land now (#97).
    self:ClearRefusals()
end

-- What the addon is actually matching auras against, for a bug report. The
-- library answers with data and the host decides how to say it: only the host
-- knows what it calls its buffs, and three addons track different ones.
--
-- `unresolved` is the field worth acting on: a form still on its English
-- fallback is the signature of the bug above. It is not the same as a spell
-- the player has not learned, which is ordinary and appears as known = false,
-- nor as one whose provenance is "unknown", where an older copy of this
-- library built the def and the name may be either. Those are counted apart,
-- in `unknown` (r34): a host that prints "N names unresolved" can then say
-- "N names of unknown origin" for the upgrade case instead of saying nothing,
-- which is what hiding them inside a zero `unresolved` amounted to.
function Methods:SpellReport()
    local out = { locale = lib.API.Locale and lib.API.Locale() or "?", unresolved = 0, unknown = 0 }
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
            if form.from == "fallback" then
                out.unresolved = out.unresolved + 1
            elseif form.from == "unknown" then
                out.unknown = out.unknown + 1
            end
        end
        local entry = { id = d.id, label = d.label, forms = forms }
        -- The covering auras (r38): each ID with the name it resolved to, or
        -- nil. An unresolved one covers nothing, which is worth seeing.
        if d.coveredBy then
            entry.covers = {}
            for _, id in ipairs(d.coveredBy) do
                entry.covers[#entry.covers + 1] = { id = id, name = d.coverByID and d.coverByID[id] }
            end
        end
        out[#out + 1] = entry
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
local function PruneTable(cache, cutoff)
    for key, defs in pairs(cache) do
        local live = false
        for _, entry in pairs(defs) do
            if entry.stamp and entry.stamp > cutoff then live = true break end
        end
        if not live then cache[key] = nil end
    end
end

function Methods:PruneCache()
    local cutoff = GetTime() - 3600
    PruneTable(self.cache, cutoff)
    if self.coverCache then PruneTable(self.coverCache, cutoff) end
    -- Refusals past their deadline (#97). A member who left is never asked
    -- about again, so theirs only waits for it.
    local R = self.refusals
    if R then
        local now = GetTime()
        for key, recs in pairs(R.byKey) do
            for defId, rec in pairs(recs) do
                if now >= rec.retryAt then recs[defId] = nil end
            end
            if next(recs) == nil then R.byKey[key] = nil end
        end
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

-- ─── Covering auras (r38, #95) ──────────────────────────────────────────────
--
-- A stronger buff can make the client refuse this one: a member with Might
-- of Stormwind or Warchief's Blessing gets "A more powerful spell is already
-- active" from Power Word: Fortitude. That member has no Fortitude aura, so
-- they read as missing, and the picker - first missing member wins - aimed
-- every click at them, and the row's button never buffed anybody else.
--
-- A def lists those auras by spell ID in `coveredBy`. A covered member does
-- not count as missing and is never picked by a row's click, but BuffRem
-- still answers about the buff itself: its own presence, duration and the
-- durations learned from it stay separate from the covering aura's, and
-- nothing here is learned.
--
-- Returns the covering aura's name and its remaining time, false when the
-- member is known to have none, or nil when it cannot be known: the reads are
-- closed and this character was never looked at. Combat follows BuffRem's
-- rules: the last thing seen carries forward, and a covering aura whose own
-- clock runs out during the fight stops covering.
--
-- With two covering auras up, the one that lasts longest is the answer, and
-- the one remembered: remembering the first would end the coverage mid-fight
-- when it ran out, with the other still up.
function Methods:CoverOf(unit, def)
    local names = CoverNames(def)
    if not names or #names == 0 then return false end
    if not unit or not UnitExists(unit) then return false end
    local API = lib.API
    local key = API.UnitKey(unit)
    self.coverCache = self.coverCache or {}

    -- One read per name, each answered by the pass's single walk when one
    -- is open. ReadBuff stops at the first name it finds. Remaining times
    -- are compared raw: a permanent aura (math.huge) outlasts any timed one,
    -- which the clamped PERMANENT would not.
    local status, best, bestRem, bestExp = "NONE", nil, -1, 0
    local refused
    for _, single in ipairs(def.coverSingles) do
        local st, rem, _, exp, matched = API.ReadBuff(unit, single, self.auraPass)
        if st == "HAS" then
            if rem > bestRem then best, bestRem, bestExp = matched, rem, exp or 0 end
        elseif st == "BLOCKED" then
            status = "BLOCKED"
            refused = refused or {}
            refused[single[1]] = true
        end
    end

    local entries = self.coverCache[key or ""]
    local cached = key and entries and entries[def.id]
    -- What the cache still vouches for: name and remaining, or nil.
    local cachedRem
    if cached and cached.name then
        if cached.exp == 0 then
            cachedRem = math.huge
        elseif cached.exp - GetTime() > 0 then
            cachedRem = cached.exp - GetTime()
        end
    end

    if best then
        -- A read that was refused for some names proves only what it saw. A
        -- longer cover remembered from before stands only if its OWN read
        -- was the one refused; one read afresh says what it says.
        if refused and cachedRem and refused[cached.name] and cachedRem > bestRem then
            best, bestRem = cached.name, cachedRem
            cached.stamp = GetTime()
        elseif key then
            entries = entries or {}
            self.coverCache[key] = entries
            entries[def.id] = { name = best, exp = bestExp, stamp = GetTime() }
        end
        return best, (bestRem == math.huge) and PERMANENT or bestRem
    end
    if status == "NONE" then
        if key then
            entries = entries or {}
            self.coverCache[key] = entries
            entries[def.id] = { none = true, stamp = GetTime() }
        end
        return false
    end

    if not cached then return nil end
    if cached.none or not cachedRem then return false end
    -- The remembered aura's own read came back and said it is gone, while
    -- another name's was refused: the memory is contradicted and dropped, and
    -- what is left cannot be known.
    if not refused[cached.name] then
        entries[def.id] = nil
        return nil
    end
    return cached.name, (cachedRem == math.huge) and PERMANENT or cachedRem
end

-- BuffRem with the covering aura beside it: rem, dur, state, spell, basis,
-- cover, coverRem. A member not seen with the buff whose cover cannot be
-- known is UNKNOWN rather than MISSING: we do not know that a click on them
-- would land. Only a def with covering auras can be changed by this.
local function MemberState(self, unit, def)
    local rem, dur, state, spell, basis = self:BuffRem(unit, def)
    local cover, coverRem = self:CoverOf(unit, def)
    if cover == nil and state ~= ST_HAS then
        return 0, dur, ST_UNKNOWN, spell, nil, nil, nil
    end
    return rem, dur, state, spell, basis, cover or nil, coverRem
end

-- ─── Refusals (r39, #97) ────────────────────────────────────────────────────
--
-- Some blockers can't be listed in coveredBy. Camp Benefits (1229741) is one
-- aura whose parts depend on the camp's items and whose values scale with
-- level, and the client exposes neither: one camp refuses Fortitude rank 3,
-- another may not. What the client does say is when it refused a cast.
-- Measured out of combat, in one frame (#97, runs #646 and #518):
--
--     UNIT_SPELLCAST_SENT("player", targetName, castGUID, spellID)
--     UNIT_SPELLCAST_FAILED("player", castGUID, spellID)
--     UI_ERROR_MESSAGE(57, SPELL_FAILED_AURA_BOUNCED)
--
-- Type 57 is ERR_SPELL_FAILED_S, which also carries "Interrupted" and "Can't
-- do that while moving", so the message is what tells a bounce apart.
--
-- A refusal says only that this spell bounced on this member just now, not
-- what blocked it or for how long. So it is kept apart from the aura evidence
-- (state, nMiss, allHave and CoverOf are unchanged) and only steers the
-- picker: a single-form cast skips the member for REFUSAL_HOLD seconds. The
-- group form, and the popover's manual click, are not affected.
--
-- Learned only from this window's own out-of-combat clicks, and only when the
-- member the click aimed at is the one SENT names:
--   - the click's PreClick notes the attempt (NoteAttempt). Both mouse edges
--     run PreClick and one of them casts, so a second edge naming another
--     member or spell spoils the attempt instead of replacing it;
--   - SENT arrives after PostClick has re-aimed the button (0.06-0.16 s
--     measured), so the attributes can't be read back then;
--   - SENT's target is a name. It must resolve to exactly one roster member,
--     whose GUID is the attempt's. A secret or ambiguous name is nobody;
--   - FAILED must carry SENT's castGUID, and the UI error follows it. An
--     out-of-range cast fails during the click with no SENT, so it never
--     reaches the error.
-- Nothing is learned in combat, where SENT's target can be secret (#646).
--
-- A record clears early when the buff is seen on the member, when the
-- member loses an aura (the blocker may be what went), on combat entry and
-- exit, on a world transition and when the spells are refreshed. Nothing is
-- saved: a /reload forgets it all.
--
-- The host opts in by forwarding UI:RefusalEvents() to UI:RefusalEvent. A
-- host that doesn't learns nothing, and its engine behaves as r38's did.
local REFUSAL_HOLD = 30
local ATTEMPT_WINDOW = 1
local REFUSAL_REASON = "stronger-effect"

-- The state, made on first use: an engine an older copy built has none.
local function Refusals(self)
    local R = self.refusals
    if not R then
        R = { byKey = {} }
        self.refusals = R
    end
    return R
end

local function DropRecord(R, key, defId)
    local recs = R.byKey[key]
    if not recs then return false end
    local had = recs[defId] ~= nil
    recs[defId] = nil
    if next(recs) == nil then R.byKey[key] = nil end
    return had
end

-- The refusal on record for this member and def, or nil: { spellID, reason,
-- retryAt }, retryAt on GetTime()'s clock. `state`, when given, is the
-- member's state for the def: seen with the buff, the record goes.
function Methods:RefusalOf(unit, def, state)
    local R = self.refusals
    if not R or not unit or not def then return nil end
    local key = lib.API.UnitKey(unit)
    local recs = key and R.byKey[key]
    local rec = recs and recs[def.id]
    if not rec then return nil end
    if GetTime() >= rec.retryAt or state == ST_HAS then
        DropRecord(R, key, def.id)
        return nil
    end
    return rec
end

-- Forget every refusal, and any click still waiting for its cast. Returns
-- whether there was a refusal to forget.
function Methods:ClearRefusals()
    local R = self.refusals
    self.refusals = nil
    return (R and next(R.byKey) ~= nil) and true or false
end

-- A click is about to cast `spell` at `unit` for `def`: called from PreClick,
-- after the library has aimed the button. `source` is the button. `spell`
-- nil means the click casts nothing. Only a single-form cast is noted.
--
-- Which edge casts isn't known here (the client's rule needs arguments
-- PreClick doesn't get), so every edge notes. The edge that comes after the
-- cast was answered notes an attempt nothing consumes; it lapses after
-- ATTEMPT_WINDOW, and a click on another button before then is spoiled
-- (not learned from) rather than misattributed.
function Methods:NoteAttempt(def, unit, spell, source)
    if InCombatLockdown() then return end
    local R = Refusals(self)
    local now = GetTime()
    local a = R.attempt
    if a and now - a.at > ATTEMPT_WINDOW then
        a = nil
        R.attempt = nil
    end
    local key = unit and lib.API.UnitKey(unit)
    local single = def and spell ~= nil and spell == def.sngl and key ~= nil
    if a then
        -- The other edge of the same click, or another click before the
        -- first one's cast: different aims make the attempt unattributable.
        if not a.castGUID and (not single or a.key ~= key or a.def ~= def or a.source ~= source) then
            a.mixed = true
        end
        return
    end
    if single then
        R.attempt = { def = def, key = key, spell = spell, source = source, at = now }
    end
end

-- The roster's units, pets included: a name SENT gives must match exactly one.
local function RosterUnits()
    local out = { "player", "pet" }
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            out[#out + 1] = "raid" .. i
            out[#out + 1] = "raidpet" .. i
        end
    else
        for i = 1, 4 do
            out[#out + 1] = "party" .. i
            out[#out + 1] = "partypet" .. i
        end
    end
    return out
end

-- The GUID of the one roster member called `name` (GetUnitName(unit, false),
-- the form SENT gives), or nil: nobody, two members, or a name that can't be
-- compared because it is secret.
local function ResolveTarget(name)
    local API, found = lib.API, nil
    for _, u in ipairs(RosterUnits()) do
        if UnitExists(u) then
            local ok, same = pcall(function()
                local n = GetUnitName(u, false)
                return n ~= nil and n == name
            end)
            if not ok then return nil end
            if same then
                local key = API.UnitKey(u)
                if found and found ~= key then return nil end
                found = key
            end
        end
    end
    return found
end

local function Learn(R, a)
    local recs = R.byKey[a.key] or {}
    R.byKey[a.key] = recs
    local old = recs[a.def.id]
    -- A refresh never extends a record: only its own deadline ends it.
    if old and GetTime() < old.retryAt then return false end
    recs[a.def.id] = { spellID = a.spellID, reason = REFUSAL_REASON, retryAt = GetTime() + REFUSAL_HOLD }
    return true
end

-- One event against the attempt. Runs in a pcall: a secret payload throws on
-- comparison, and that drops the attempt.
local function Observe(R, a, event, a1, a2, a3, a4)
    if event == "UNIT_SPELLCAST_SENT" then
        if a1 ~= "player" then return false end
        if a.castGUID or a.mixed then R.attempt = nil return false end
        if lib.API.SpellName(a4) ~= a.spell or ResolveTarget(a2) ~= a.key then
            R.attempt = nil
            return false
        end
        a.castGUID, a.spellID = a3, a4
        return false
    end
    -- Before SENT there is nothing to join: an out-of-range cast fails here.
    if not a.castGUID then return false end
    if event == "UNIT_SPELLCAST_FAILED" or event == "UNIT_SPELLCAST_FAILED_QUIET" then
        if a1 ~= "player" or a2 ~= a.castGUID then return false end
        if event == "UNIT_SPELLCAST_FAILED" and a3 == a.spellID then
            a.failed = true
        else
            R.attempt = nil
        end
        return false
    end
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        if a1 ~= "player" or a2 ~= a.castGUID then return false end
        R.attempt = nil
        return DropRecord(R, a.key, a.def.id)
    end
    if event == "UI_ERROR_MESSAGE" then
        if not a.failed then return false end
        R.attempt = nil
        local bounced = rawget(_G, "SPELL_FAILED_AURA_BOUNCED")
        if type(bounced) == "string" and a2 == bounced then return Learn(R, a) end
    end
    return false
end

-- The events a host forwards to learn refusals (UI:RefusalEvents).
local REFUSAL_EVENTS = { "UNIT_SPELLCAST_SENT", "UNIT_SPELLCAST_FAILED", "UNIT_SPELLCAST_FAILED_QUIET",
    "UNIT_SPELLCAST_SUCCEEDED", "UI_ERROR_MESSAGE", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
    "PLAYER_ENTERING_WORLD" }
lib.Engine.REFUSAL_EVENTS = REFUSAL_EVENTS

-- One forwarded event. Returns true when what the picker skips has changed.
function Methods:RefusalEvent(event, ...)
    if event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED"
        or event == "PLAYER_ENTERING_WORLD"
    then
        return self:ClearRefusals()
    end
    local R = self.refusals
    local a = R and R.attempt
    if not a then return false end
    if InCombatLockdown() or GetTime() - a.at > ATTEMPT_WINDOW then
        R.attempt = nil
        return false
    end
    local ok, changed = pcall(Observe, R, a, event, ...)
    if not ok then
        R.attempt = nil
        return false
    end
    return changed and true or false
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
    -- A refusal (r39, #97) was learned from the single form, so only a
    -- single-form cast skips the member it bounced on.
    local single = spell ~= nil and spell == def.sngl
    local firstValid, bestUnit, bestRem = nil, nil, math.huge
    for _, m in ipairs(members) do
        if self:IsValidTarget(m.unit)
            and (not requireInRange or lib.API.SpellRange(m.unit, spell) == "IN_RANGE")
        then
            local rem, state, cover, refused
            local known = st and st.byUnit and st.byUnit[m.unit]
            if known then
                rem, state, cover, refused = known.rem, known.state, known.covered, known.refused
            else
                local _
                rem, _, state, _, _, cover = MemberState(self, m.unit, def)
                refused = self:RefusalOf(m.unit, def, state)
            end
            -- A covered member is skipped by every branch, the two fallbacks
            -- included: the cast would be refused, whoever ends up aimed at
            -- them (#95). So is one the client just refused it on (#97).
            if not cover and not (single and refused) then
                firstValid = firstValid or m.unit
                if state == ST_MISSING then return m.unit end
                if state == ST_HAS and rem < bestRem then
                    bestRem = rem
                    bestUnit = m.unit
                end
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
            local state, cover
            if known and known.state then
                state, cover = known.state, known.covered
            else
                local _
                _, _, state, _, _, cover = MemberState(self, m.unit, def)
            end
            -- A covered member cannot be given it either (#95).
            if state == ST_MISSING and not cover then anyMissing = true break end
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
--
-- With assignments (r37), availability still comes first; then the raid's
-- word replaces the addon's own: a buff assigned to me has a row whatever my
-- toggle or mode says, one somebody else has (or an assignOnly def with no
-- targets) has none, and anything unassigned keeps exactly the rule above.
function Methods:ActiveDefs(groups, ord)
    local out, assigned = {}, self.assignments
    for _, d in ipairs(self.defs) do
        if d.hasSingle or d.hasGroup then
            local rule = assigned and assigned:RowRule(d)
            if rule == "force" or (rule == nil
                and (not self.isBuffEnabled or self.isBuffEnabled(d.id))
                and (not self.isVisible or self.isVisible(d, groups, ord)))
            then
                out[#out + 1] = d
            end
        end
    end
    return out
end

-- The members one buff's row covers: the whole group unless the addon narrows
-- it (Thorns goes on tanks). Called ONCE per row; the result drives the stats,
-- the targets, the popover and the clicks alike, so they cannot disagree. An
-- empty list means no row. The input list is never modified.
--
-- A targets def with a list assigned to me (r37) covers exactly the listed
-- players, and skips the addon's own filter: a druid in Thorns mode "self"
-- still keeps Thorns on the non-tank the raid asked for. Pets never count.
function Methods:MembersFor(def, members)
    local assigned = self.assignments
    local names = assigned and assigned:TargetNames(def)
    if names then
        local out = {}
        for _, m in ipairs(members) do
            local class = m.class
            if not (type(class) == "string" and class:find("^PET")) then
                local name = lib.AssignImpl.NameOf(m.unit)
                if name and names[name] then out[#out + 1] = m end
            end
        end
        return out
    end
    if not self.membersFor then return members end
    local out = self.membersFor(def, members)
    if type(out) ~= "table" then
        error("LibGroupBuffs Engine: membersFor must return a list (an empty one for none)", 2)
    end
    return out
end

-- Returns { miss, minR, minDur, allHave, nMiss, nUnknown, nCovered, nTotal,
-- byUnit }
--
-- Offline members count as missing. nUnknown counts members whose auras
-- cannot be read right now (combat secrecy, nothing cached); they are
-- deliberately NOT counted as missing. nCovered (r38) counts members a
-- stronger aura covers (CoverOf): neither missing nor in minR, since nobody
-- can cast the buff on them; byUnit names the aura in `covered`.
function Methods:GroupStat(members, def)
    local minR, minDur, miss, unknown, covered, refusedN = PERMANENT, 0, {}, 0, 0, 0
    local byUnit = {}
    for _, m in ipairs(members) do
        if not UnitIsConnected(m.unit) then
            miss[#miss + 1] = m
        else
            local r, d, state, spell, basis, cover, coverRem = MemberState(self, m.unit, def)
            -- The client's last refusal of the single form on them (r39,
            -- #97), or nil. It changes no count: the auras still say they
            -- are missing it.
            local refused = self:RefusalOf(m.unit, def, state)
            if refused then refusedN = refusedN + 1 end
            byUnit[m.unit] = { rem = r, state = state, basis = basis,
                               covered = cover, coverRem = coverRem, refused = refused }
            if cover then
                covered = covered + 1
            elseif state == ST_UNKNOWN then
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
        nCovered = covered,
        nRefused = refusedN,
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
    -- A member who loses an aura may have lost what refused a cast on them
    -- (#97), and a full update can't say: their refusals go.
    local R = self.refusals
    if R and next(R.byKey) ~= nil then
        pcall(function()
            if updateInfo and not updateInfo.isFullUpdate and not updateInfo.removedAuraInstanceIDs then return end
            local key = lib.API.UnitKey(unit)
            if key then R.byKey[key] = nil end
        end)
    end
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
                    -- A covering aura landing changes who counts as missing.
                    local covers = CoverNames(d)
                    if covers then
                        for i = 1, #covers do
                            if nm == covers[i] then return true end
                        end
                    end
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
--         onCloseDeferred = function(ui, manual) end,   -- optional: combat refused the hide
--         onTick = function(ui, elapsed) end,   -- optional: every ~0.5s while visible
--         onAppearance = function(ui) end,      -- optional: the look changed, no rebuild
--     })
--
-- A companion pane - a second frame of the addon's own under the window, like
-- Magely's cooldowns - lives on those hooks, and on four rules:
--
--   * NON-SECURE only: plain frames, no secure templates, no attributes,
--     PARENTED TO UIParent and anchored to the window. That is the shape
--     measured free in combat (build 70009, Spotnick2/Magely#12): it showed,
--     hid, resized and re-anchored during a fight with nothing blocked. A
--     child of the window was not measured - and would hide whenever the
--     window does, and take its alpha.
--   * Anchored, sized AND scaled in onLayout, which ends every out-of-combat
--     rebuild: being UIParent's, the pane does not inherit the window's scale,
--     so it copies it (pane:SetScale(main:GetScale())) or its width, measured
--     in the window's units, comes out wrong on screen. onLayout does not run
--     in combat; a pane that changes size during a fight manages that itself.
--   * Visibility follows ui:IsVisible(), via onVisibility: when the window is
--     closed in combat the pane hides AT ONCE, though the window's own frame
--     stays up until the fight ends (the client refuses to hide it). On the
--     FIRST show onVisibility(true) arrives just before the first onLayout,
--     so it finds no pane yet: guard for that (onLayout shows the pane).
--   * onTick(ui, elapsed) is a refresh cadence: on the window's half-second
--     tick, in and out of combat, only while the window is visible. `elapsed`
--     is the window's visible time since the previous tick, NOT wall time -
--     nothing ticks while it is closed or the UI is hidden - so count
--     cooldowns down from GetTime(), never by summing `elapsed`.
--   * onAppearance(ui) runs when the look changes OUTSIDE a rebuild - the
--     alpha or scale slider, a spec change - and only once the window has
--     been laid out. A rebuild ends in onLayout instead, so the pane takes
--     the look (ui:Appearance(), ui:Alpha(), the scale) there as well.
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
-- Optional material belongs to one window; old hosts retain the shared Clean instance.
local function WindowGlass(frame)
    local ui = frame and frame._ui
    return (ui and ui.host.glass) or GlassInst()
end

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
    local media = WindowGlass(parent).MEDIA
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
-- The file is LibGlass's for this client's language (#84). If that one does
-- not load (SetFont returns false: two of the Chinese clients' files are
-- missing on an English client, porting guide "A font file draws one
-- script"), Arial Narrow: a font string with no font throws on SetText.
local function Style(fs, size, justify)
    local file = GlassFontFile(FONT_FILE)
    if not fs:SetFont(file, size, "") and file ~= FONT_FILE then
        fs:SetFont(FONT_FILE, size, "")
    end
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
    COVERED = { 0.45, 0.75, 1.00 },   -- r38: a stronger aura blocks the buff
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

-- Defined with the appearance code below; Init, above it, applies the look.
local ApplyLook

-- ─── Construction ───────────────────────────────────────────────────────────

local function Fail(msg) error("LibGroupBuffs UI.New: " .. msg, 3) end

local OPTIONAL_FUNCTIONS = {
    "appearance", "footerItems", "previewFooterItems", "alpha", "scale", "locked", "popoverSide", "showClickHints",
    "growDirection",
    "getPos", "setPos", "setVisible", "onLayout", "onVisibility", "onCloseDeferred",
    "onTick", "onAppearance", "onMinimizeDeferred", "bodyStyle",
}

function UI.New(host)
    if type(host) ~= "table" then Fail("host must be a table") end
    if host.glass ~= nil and (type(host.glass) ~= "table"
        or type(host.glass.Apply) ~= "function" or type(host.glass.Mask) ~= "function"
        or type(host.glass.STYLE) ~= "table" or type(host.glass.MEDIA) ~= "string") then
        Fail("glass must be a LibGlass instance or nil")
    end
    if host.minimizable ~= nil and type(host.minimizable) ~= "boolean" then
        Fail("minimizable must be a boolean or nil")
    end
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
        -- false, not nil: this copy built the window, and nil is how a window
        -- an older copy built says it predates the field (ApplyAppearance).
        laidOut = false,
        minimized = false,      -- session-only preference, separate from visible
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
-- The look is applied on every rebuild (ApplyLook), so the next one out of
-- combat carries it.
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
    f.glass = WindowGlass(f).Apply(f, "large")
    if f._ui.host.bodyStyle then
        local backing = f:CreateTexture(nil, "BACKGROUND", nil, -7)
        backing:SetAllPoints(f)
        backing:AddMaskTexture(f.glass.mask)
        backing:SetColorTexture(0, 0, 0, 0)
        f.glass.bodyBacking = backing
    end
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

    local Glass = WindowGlass(row)
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
    local Glass = WindowGlass(main)
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
    xEdge:SetTexture(WindowGlass(xBtn).MEDIA .. "bar_edge")
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

-- Opt-in: a host with a companion pane must first teach its onLayout hook to
-- honour IsMinimized(). Older hosts keep their existing header and semantics.
local function MakeMinimizeButton(ui, main)
    local btn = MakeCloseButton(ui, main)
    btn:ClearAllPoints()
    btn:SetPoint("RIGHT", main.closeBtn, "LEFT", -3, 0)
    btn:SetScript("OnClick", function(b) return b._ui:ToggleMinimized() end)
    btn:SetScript("OnEnter", function(b) return b._ui:MinimizeButtonHover(b, true) end)
    btn:SetScript("OnLeave", function(b) return b._ui:MinimizeButtonHover(b, false) end)
    return btn
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
    if main._ui.host.minimizable then
        -- Reserve both controls' space. The version remains in host diagnostics.
        main.version:Hide()
        main.title:SetPoint("RIGHT", main, "RIGHT", -(2 * (HDR_H - 12) + 14), 0)
    end
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
    local glass = self.host.glass or GlassInst()
    local nGroups, nRows, nPop = self:Capacity()
    self.capacity = { groups = nGroups, rows = nRows, popRows = nPop }

    -- ── Main frame ──────────────────────────────────────────────────────
    local main = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    main._ui = self
    self.main = main
    main:SetFrameStrata("LOW")
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
    if self.host.minimizable then main.minimizeBtn = MakeMinimizeButton(self, main) end

    -- Covers the header only, so the row buttons still get their clicks.
    local drag = CreateFrame("Frame", nil, main)
    drag._ui = self
    drag:SetPoint("TOPLEFT",  hdrBg, "TOPLEFT",  0, 0)
    drag:SetPoint("TOPRIGHT", hdrBg, "TOPRIGHT",
        self.host.minimizable and -(2 * (HDR_H - 12) + 9) or -16, 0)
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
    pop:SetFrameStrata("LOW")
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
    ApplyLook(self)
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

-- What a popover row's tooltip says, as a key: nil when it shows nothing.
-- PopRowEnter records the key it drew, so a refresh can tell it is stale.
local function PopRowTipKey(pr)
    local unit = pr._unit
    if not unit then return nil end
    -- Who, not which slot: a roster change can put somebody else at the
    -- same unit token while the row is hovered, and the tooltip names them.
    local who = tostring(lib.API.UnitKey(unit))
    if not UnitIsConnected(unit) then return "offline:" .. who end
    if pr._cover and pr._def then
        return "cover:" .. who .. ":" .. tostring(pr._def.id) .. ":" .. pr._cover
    end
    if pr._refused and pr._def then
        return "refused:" .. who .. ":" .. tostring(pr._def.id) .. ":" .. tostring(pr._refused.retryAt)
    end
    return nil
end

function Methods:ApplyPopRowVisuals(pr)
    if not pr._active then return end
    local engine = self.engine
    local S = lib.Engine.STATES
    local unit, def = pr._unit, pr._def
    local rem, buffDur, state, spell = engine:BuffRem(unit, def)
    local has = (state == S.HAS) and rem > 0
    -- A stronger aura that blocks this buff (r38, #95). Their own buff, if
    -- they still have one, is what the row shows; otherwise the covering
    -- aura's time, in its own colour, and the row's tooltip names it.
    local cover, coverRem = engine:CoverOf(unit, def)
    if cover == nil and not has then state = S.UNKNOWN end
    pr._cover = cover or nil
    -- The client's last refusal on them (r39, #97): named in the tooltip.
    pr._refused = (not cover) and engine:RefusalOf(unit, def, state) or nil
    -- The row's own tooltip, open under the cursor, says what was true when
    -- the mouse arrived, and OnEnter does not fire again while the mouse
    -- rests there: redraw it when that changes. Compared with what the
    -- tooltip shows, not with the row's last state, since a rebuild of the
    -- open popover resets the row (#95).
    if lib.API.IsMouseOver(pr) and PopRowTipKey(pr) ~= pr._tipKey then
        self:PopRowLeave()
        self:PopRowEnter(pr)
    end
    -- The range dot describes the spell the LEFT click casts: a group spell
    -- can reach further than the single form, so the single spell's range
    -- would mark members out of reach that the group spell lands on fine.
    local primarySpell = engine:ClickSpells(def)
    local range = lib.API.SpellRange(unit, primarySpell)
    local dur = engine:DurationFor(def, buffDur, spell)
    local pct = has and UI.Pct(rem, dur) or 0

    if not UnitIsConnected(unit) then
        SetFill(pr, POP_ROW_H, 0.30, 0.30, 0.30, 0.75)   -- offline
    elseif has then
        SetFill(pr, POP_ROW_H, 0.10, 0.65, 0.20, 0.80)   -- buffed
    elseif cover then
        SetFill(pr, POP_ROW_H, 0.15, 0.40, 0.70, 0.80)   -- covered
    elseif state == S.UNKNOWN then
        SetFill(pr, POP_ROW_H, 0.30, 0.30, 0.30, 0.65)   -- unreadable
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
    elseif cover then
        pr.timeTxt:SetText(UI.FmtTime(coverRem or 0))
        pr.timeTxt:SetTextColor(unpack(COLOUR.COVERED))
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
    if self.previewGroups then return end
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
    -- An existing instance, else one a usable LibGlass at the floor can make,
    -- else the built tint: recolouring a panel never constructs one below r6.
    local body = Call(f._ui.host.bodyStyle, f)
    local own = f._ui.host.glass
    if type(body) == "table" then
        local glass = WindowGlass(f)
        if type(body.tint) == "table" then g.tint:SetColorTexture(unpack(body.tint)) end
        if type(body.wash) == "number" and glass.SetWash then
            glass.SetWash(g, math.max(0, math.min(1, glass.STYLE.wash * body.wash)))
        end
        if g.bodyBacking then
            local backing = body.backing or { 0, 0, 0, 0 }
            g.bodyBacking:SetColorTexture(unpack(backing))
        end
        return
    end
    local glass = own or lib.glass
    if not glass and GlassUsable() and not GlassTooOld() then glass = GlassInst() end
    local base = glass and glass.STYLE.tint or BUILT_TINT
    if g.bodyBacking then g.bodyBacking:SetColorTexture(0, 0, 0, 0) end
    if glass and glass.SetWash then glass.SetWash(g, glass.STYLE.wash) end
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

-- The look itself, with no host hook: what Init and a rebuild use, since a
-- rebuild ends in onLayout, where a companion takes the look anyway.
function ApplyLook(self)
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
end

-- The look changed without a rebuild (the alpha or scale slider, a spec
-- change): tell a companion, last, so it reads the look the window now
-- wears - but only once onLayout has run, because that is where a companion
-- builds its pane, and before it there is nothing to recolour.
function Methods:ApplyAppearance()
    if not self.main then return end
    ApplyLook(self)
    -- A window an older copy built has no laidOut at all (nil); if it is
    -- open, that copy took it through onLayout. A window this copy built
    -- starts at false, so `visible` alone never stands in for it: on the
    -- first show onVisibility(true) runs BEFORE the first onLayout, and a
    -- host calling ApplyAppearance from there must not reach a pane that
    -- onLayout has not built yet.
    local laidOut = self.laidOut
    if laidOut == nil then laidOut = self.visible end
    if laidOut then Call(self.host.onAppearance, self) end
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
    local items = Call(self.previewGroups and self.host.previewFooterItems or self.host.footerItems) or {}
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
    local elapsed
    if self.tick >= 0.5 then
        elapsed = self.tick
        self.tick = 0
        self:RefreshTimers()
        -- On the half-second tick, not the footer's three: a placeholder
        -- under the cursor is what the player is looking at, and three
        -- seconds of "Loading..." is most of a hover.
        self:RefreshPendingTooltip()
    end
    if self.footerTick >= 3.0 then
        self.footerTick = 0
        self:RefreshFooter()
    end
    -- The window's clock, for a companion's countdowns: one clock, and it
    -- stops when the window is closed, which a pane's own OnUpdate would have
    -- to track for itself. Last, so a host error here (not pcall'd: errors
    -- are never hidden) cannot skip the window's own work on this frame.
    if elapsed then Call(self.host.onTick, self, elapsed) end
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

-- Convert the existing anchor without moving the current rectangle. A later
-- SetSize then moves only the edge opposite the chosen one.
local function AnchorEdge(main, edge)
    local point, relativeTo, relativePoint, x, y = main:GetPoint()
    if not point then return false end
    local target = edge == "up" and "BOTTOMLEFT" or "TOPLEFT"
    if point == target then return false end
    local fx = point:find("LEFT", 1, true) and 0 or (point:find("RIGHT", 1, true) and 1 or 0.5)
    local fy = point:find("TOP", 1, true) and 1 or (point:find("BOTTOM", 1, true) and 0 or 0.5)
    main:ClearAllPoints()
    main:SetPoint(target, relativeTo or UIParent, relativePoint,
        x - fx * main:GetWidth(), y + ((edge == "up" and 0 or 1) - fy) * main:GetHeight())
    return true
end

local function GrowthDirection(self)
    local direction = Call(self.host.growDirection)
    return (direction == "up" or direction == "down") and direction or nil
end

local function SavePosition(self)
    local point, _, relPoint, x, y = self.main:GetPoint()
    Call(self.host.setPos, { point = point, relPoint = relPoint, x = x, y = y })
end

function Methods:DragStart()
    if self.previewGroups then return end
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
    if self.previewGroups then return end
    if Call(self.host.locked) then return end
    local growth = GrowthDirection(self)
    if growth then AnchorEdge(self.main, growth)
    elseif self.main._minimized then AnchorEdge(self.main, "down") end
    self.moved = true
    -- GetPoint reports relativeTo as nil after StopMovingOrSizing while the
    -- restore anchors explicitly to UIParent. That is not a mismatch: the
    -- frame is PARENTED to UIParent, and a nil relativeTo means "my parent".
    -- Measured in game - saved and restored values match to the decimal.
    SavePosition(self)
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
        local growth = GrowthDirection(self)
        if growth then AnchorEdge(self.main, growth); self.moved = true end
    end
    return true
end

-- What the last position restore decided, for the addon's diagnostic command.
-- Routine refreshes skip the restore and are only counted, so the decision
-- that matters is still there when somebody asks.
function Methods:RestoreInfo()
    return { log = self.restoreLog, skips = self.restoreSkips }
end

-- A visual-only raid sample. Changing mode is refused in combat because the
-- main and popover frame parent secure buttons. Disarm every pooled button
-- before exposing synthetic members, including rows left over from a real
-- roster that the sample will not use.
function Methods:SetPreview(groupCount)
    if groupCount ~= nil and groupCount ~= 5 and groupCount ~= 8 then
        error("LibGroupBuffs UI:SetPreview expects 5, 8, or nil", 2)
    end
    if InCombatLockdown() then return false end
    if self.previewGroups == groupCount then return true end
    if groupCount then
        for _, pool in ipairs({ self.rows, self.popRows }) do
            for _, button in ipairs(pool) do
                for _, key in ipairs({ "type1", "spell1", "unit1", "type2", "spell2", "unit2" }) do
                    button:SetAttribute(key, nil)
                end
            end
        end
    end
    self.previewGroups = groupCount
    if self.pop then self.pop:Hide() end
    if self.main then
        for _, control in ipairs({ self.main.closeBtn, self.main.minimizeBtn }) do
            if control then
                if groupCount then control:Hide() else control:Show() end
            end
        end
    end
    self.hintRow = nil
    return true
end

function Methods:IsPreview()
    return self.previewGroups ~= nil
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
    if self.main and self.main._minimized then return end
    local pop = self.pop
    if not pop then return end
    self.popHidePending = false

    local engine = self.engine
    local preview = self.previewGroups ~= nil
    pop.hdrIcon:SetTexture(lib.API.SpellIcon(def.hasSingle and def.snglID or def.grpID, def.fallbackIcon))
    local popPrimary, popSecondary
    if not preview then popPrimary, popSecondary = engine:ClickSpells(def) end
    -- Name whatever the primary click actually casts.
    pop.hdrTxt:SetText(preview and (def.sngl or def.grp) or (popPrimary or def.sngl))
    pop._anchorRow = anchorRow

    local fallbackIcon = self.host.unknownClassIcon or "Interface\\Icons\\INV_Misc_QuestionMark"
    local cnt = math.min(#members, #self.popRows)
    for i = 1, cnt do
        local m, pr = members[i], self.popRows[i]
        pr._active = true
        pr._unit = not preview and m.unit or nil
        pr._def = def
        pr._preview = preview and m._preview[def.id] or nil
        pr._cover = nil   -- ApplyPopRowVisuals names it, below

        -- Left: the primary spell on this person (a group spell covers their
        -- subgroup). Right: the secondary spell on this person.
        pr:SetAttribute("type1",  not preview and "spell" or nil)
        pr:SetAttribute("spell1", popPrimary)
        pr:SetAttribute("unit1",  not preview and m.unit or nil)
        pr:SetAttribute("type2",  not preview and "spell" or nil)
        pr:SetAttribute("spell2", popSecondary)
        pr:SetAttribute("unit2",  not preview and m.unit or nil)

        pr.classIcon:SetTexture((m.class and UI.CLASS_ICONS[m.class]) or fallbackIcon)
        local cr, cg, cb = ClassColor(m.class)
        pr.nameTxt:SetText(m.name)
        pr.nameTxt:SetTextColor(cr, cg, cb)

        if preview then
            local state = pr._preview
            if state and state.kind == "HAS" then
                SetFill(pr, POP_ROW_H, 0.10, 0.65, 0.20, 0.80)
                pr.rangeTxt:SetText("R")
                pr.rangeTxt:SetTextColor(0.15, 1.00, 0.15)
                pr.timeTxt:SetText(UI.FmtTime(state.rem))
                pr.timeTxt:SetTextColor(UI.TimerColor(UI.Pct(state.rem, state.dur)))
            elseif state and state.kind == "UNKNOWN" then
                SetFill(pr, POP_ROW_H, 0.30, 0.30, 0.30, 0.65)
                pr.rangeTxt:SetText("?")
                pr.rangeTxt:SetTextColor(unpack(COLOUR.UNKNOWN))
                pr.timeTxt:SetText("?")
                pr.timeTxt:SetTextColor(unpack(COLOUR.UNKNOWN))
            else
                SetFill(pr, POP_ROW_H, 0.70, 0.13, 0.13, 0.80)
                pr.rangeTxt:SetText("R")
                pr.rangeTxt:SetTextColor(0.15, 1.00, 0.15)
                pr.timeTxt:SetText("MISS")
                pr.timeTxt:SetTextColor(unpack(COLOUR.MISS))
            end
        else
            self:ApplyPopRowVisuals(pr)
        end
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

function Methods:PopRowPreClick(pr, button)
    if self.previewGroups then return end
    if InCombatLockdown() then return end
    -- Block a cast at somebody offline or dead. A member a stronger aura
    -- covers (#95), or one the client just refused it on (#97), is NOT
    -- blocked here: this is the player's own choice of target, and whether
    -- the group form bounces off them is unmeasured.
    local valid = self.engine:IsValidTarget(pr._unit)
    if not valid then
        pr:SetAttribute("spell1", nil)
        pr:SetAttribute("spell2", nil)
    end
    if pr._def then
        local spell = valid and pr:GetAttribute(button == "RightButton" and "spell2" or "spell1") or nil
        self.engine:NoteAttempt(pr._def, valid and pr._unit or nil, spell, pr)
    end
end

function Methods:PopRowPostClick(pr)
    if self.previewGroups then return end
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
    pr._tipKey = PopRowTipKey(pr)
    if pr._unit and not UnitIsConnected(pr._unit) then
        OwnTooltip(pr, "ANCHOR_RIGHT", TIP_GAP)
        GameTooltip:SetText(lib.API.UnitDisplayName(pr._unit, "Unknown"), 0.6, 0.6, 0.6)
        GameTooltip:AddLine("This player is offline", 1, 0.5, 0.5)
        GameTooltip:Show()
    elseif pr._unit and pr._cover and pr._def then
        -- Named here because the row has room only for a time (#95).
        local def = pr._def
        OwnTooltip(pr, "ANCHOR_RIGHT", TIP_GAP)
        GameTooltip:SetText(lib.API.UnitDisplayName(pr._unit, "Unknown"), 1, 1, 1)
        GameTooltip:AddLine("Has " .. pr._cover .. ", which is stronger:", unpack(COLOUR.COVERED))
        GameTooltip:AddLine((def.sngl or def.grp or "this buff") .. " cannot be cast on them.",
            unpack(COLOUR.COVERED))
        GameTooltip:Show()
    elseif pr._unit and pr._refused and pr._def then
        -- A refusal names no aura: the client said only that something
        -- stronger is active (#97).
        local def = pr._def
        local left = math.max(1, math.ceil(pr._refused.retryAt - GetTime()))
        OwnTooltip(pr, "ANCHOR_RIGHT", TIP_GAP)
        GameTooltip:SetText(lib.API.UnitDisplayName(pr._unit, "Unknown"), 1, 1, 1)
        GameTooltip:AddLine((def.sngl or "This buff") .. " was refused on them:", unpack(COLOUR.COVERED))
        GameTooltip:AddLine("a more powerful spell is already active.", unpack(COLOUR.COVERED))
        GameTooltip:AddLine("The window's clicks skip them for " .. left .. "s.", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end
end

function Methods:PopRowLeave(pr)
    if pr then pr._tipKey = nil end
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
    local needs, covered = {}, {}
    for _, m in ipairs(row._members) do
        local known = st.byUnit[m.unit]
        if not UnitIsConnected(m.unit) then
            needs[#needs + 1] = { m.name, "offline", COLOUR.OFFLINE }
        elseif known and known.covered then
            -- Does not need it and cannot be given it (#95): listed apart.
            covered[#covered + 1] = { m.name, known.covered, COLOUR.COVERED }
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
    GameTooltip:AddLine(" ")
    if #needs == 0 then
        if lastKnown then
            -- Covers the same ground as the heading: nobody was missing it at
            -- the last look, and nothing has run out or gone offline since.
            GameTooltip:AddLine("Nobody needs it, from what can still be seen.",
                0.40, 0.85, 0.40)
        elseif #covered > 0 then
            GameTooltip:AddLine("Nobody else needs it.", 0.40, 0.85, 0.40)
        else
            GameTooltip:AddLine("Everyone here has it.", 0.40, 0.85, 0.40)
        end
    else
        -- One heading for a list that mixes "was missing at the last look"
        -- with "ran out since": saying "missing when the fight started"
        -- would be false of half of it. The rows say which is which.
        GameTooltip:AddLine(lastKnown and "Needs it, from what can still be seen:" or "Needs it:",
            1.00, 0.82, 0.22)
        for _, line in ipairs(needs) do
            GameTooltip:AddDoubleLine(line[1], line[2], 1, 1, 1, unpack(line[3]))
        end
    end
    -- Neither missing nor buffable (#95): the aura that blocks it, by name.
    if #covered > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Covered by a stronger buff:", unpack(COLOUR.COVERED))
        for _, line in ipairs(covered) do
            GameTooltip:AddDoubleLine(line[1], line[2], 1, 1, 1, unpack(line[3]))
        end
    end
end

-- ─── Row handlers ───────────────────────────────────────────────────────────

-- Re-pick the target at click time, skipping the dead and offline. Does
-- nothing in combat: SetAttribute is refused under lockdown, so the click uses
-- whatever was wired before the pull.
function Methods:RowPreClick(r, button)
    if self.previewGroups then return end
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
        -- What this click casts, and at whom, for the refusal it may draw (#97).
        engine:NoteAttempt(df, unit, unit and r._primary or nil, r)
    else
        if not r._secondary then
            r:SetAttribute("spell2", nil)
            return
        end
        local unit = engine:PickTarget(ms, df, false)
        r:SetAttribute("spell2", unit and r._secondary or nil)
        if unit then r:SetAttribute("unit2", unit) end
        engine:NoteAttempt(df, unit, unit and r._secondary or nil, r)
    end
end

-- Re-arm, but only where there is still somewhere to cast: restoring the spell
-- unconditionally put it back while unit1 was the build-time "player"
-- fallback, so the next click - the first in combat, where PreClick cannot
-- re-aim - buffed yourself.
function Methods:RowPostClick(r)
    if self.previewGroups then return end
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
    if not self.previewGroups then self:ShowClickHint(r) end
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

-- Requested state, like IsVisible: the actual protected layout may lag until
-- combat ends. Open/refresh never clear this preference; Close never reopens it.
function Methods:IsMinimized()
    return self.host.minimizable == true and self.minimized == true
end

function Methods:SetMinimized(minimized)
    if not self.host.minimizable then return false end
    minimized = minimized and true or false
    local changed = self.minimized ~= minimized
    self.minimized = minimized
    if InCombatLockdown() then
        if changed and self.visible then Call(self.host.onMinimizeDeferred, self, minimized) end
        return false
    end
    if self.visible then self:Update() end
    return true
end

function Methods:ToggleMinimized()
    return self:SetMinimized(not self:IsMinimized())
end

function Methods:MinimizeButtonHover(btn, over)
    self:CloseButtonHover(btn, over)
    if not over then ReleaseTooltip(); return end
    OwnTooltip(btn, "ANCHOR_RIGHT", TIP_GAP)
    GameTooltip:SetText(self:IsMinimized() and "Restore window" or "Minimize window")
    if InCombatLockdown() then GameTooltip:AddLine("Applies when combat ends.", 1, 0.82, 0) end
    GameTooltip:Show()
end

local function SetVisible(self, visible)
    local was = self.visible
    self.visible = visible
    if was ~= visible then Call(self.host.onVisibility, self, visible) end
end

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
-- an automatic one during the same fight finds `visible` already false.
--
-- Said once per pending close AND kind, not once per click: the host gets
-- onCloseDeferred(ui, manual), so it can word "your group emptied" and "you
-- clicked X" differently, and the player's own close after an automatic one
-- in the same fight is answered too - it is a new thing to tell them. A
-- manual explanation covers any later close in that fight. The return value
-- is there for a caller that wants to handle it itself.
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
        -- Once per pending close and kind: an automatic close explained
        -- earlier in the fight does not answer the player's own click on X
        -- later, which is a new thing to tell them.
        local kind = manual and "manual" or "auto"
        local told = self.closeExplained
        if told == true then told = "manual" end   -- r26 latched manual closes only
        if self.main and self.main:IsShown() and told ~= "manual" and told ~= kind then
            self.closeExplained = kind
            Call(self.host.onCloseDeferred, self, manual and true or false)
        end
    else
        self.closeExplained = nil
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

-- Refusal memory (r39, #97). A host that wants it registers these events on
-- its own frame and forwards each one, with all its arguments:
--
--     if ui.RefusalEvents then
--         GB.RegisterEvents(frame, unpack(ui:RefusalEvents()))
--     end
--     -- in OnEvent, for each of them:  ui:RefusalEvent(event, ...)
--
-- A copy for every event it might carry, so a host can't change the list.
-- A host that forwards nothing learns nothing.
function Methods:RefusalEvents()
    local out = {}
    for i, ev in ipairs(lib.Engine.REFUSAL_EVENTS) do out[i] = ev end
    return out
end

function Methods:RefusalEvent(event, ...)
    if self.engine:RefusalEvent(event, ...) then self:ScheduleRefresh() end
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
        self.closeExplained = nil
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
local LAYOUT = 3

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
    -- The font file is part of the layout (#84): a window an older copy drew
    -- in Arial Narrow keeps it on a Korean or Chinese client, every string
    -- of it, unless it is styled again here, once.
    local font = GlassFontFile(FONT_FILE)
    if main._layout == LAYOUT and main._fontFile == font then return true end
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
    -- Their labels are font strings too, made once with the button.
    for _, b in ipairs({ main.closeBtn, main.minimizeBtn }) do
        if b and b.label then Style(b.label, ROW_FONT, "CENTER") end
    end
    if self.host.minimizable and not main.minimizeBtn then
        main.minimizeBtn = MakeMinimizeButton(self, main)
        main.dragHandle:ClearAllPoints()
        main.dragHandle:SetPoint("TOPLEFT", main.hdrBg, "TOPLEFT", 0, 0)
        main.dragHandle:SetPoint("TOPRIGHT", main.hdrBg, "TOPRIGHT", -(2 * (HDR_H - 12) + 9), 0)
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
    main._fontFile = font
    return true
end

-- The rebuild proper. Split from Update so it can run inside WithAuraPass,
-- and so the combat branch stays OUTSIDE it: that branch calls RefreshTimers,
-- which opens a pass of its own, and a pass nested inside a pass would have
-- the inner one's close end the outer.
local PREVIEW_CLASSES = { "PRIEST", "DRUID", "MAGE", "WARRIOR", "HUNTER" }

local function PreviewRoster(self)
    local groups, ord = {}, {}
    for gNum = 1, self.previewGroups do
        local members = {}
        groups[gNum], ord[gNum] = members, gNum
        for slot = 1, 5 do
            local index = (gNum - 1) * 5 + slot
            local member = {
                unit = "preview" .. index,
                name = "Member " .. index,
                class = PREVIEW_CLASSES[slot],
                _preview = {},
            }
            for _, def in ipairs(self.engine.defs) do
                local dur = type(def.duration) == "number" and def.duration > 0 and def.duration or 3600
                local pattern = gNum % 4
                local kind = pattern == 0 and "UNKNOWN"
                    or (pattern == 3 or (pattern == 2 and slot <= 2)) and "MISSING" or "HAS"
                member._preview[def.id] = { kind = kind, dur = dur, rem = math.floor(dur * (0.3 + slot * 0.1)) }
            end
            members[#members + 1] = member
        end
    end
    return groups, ord
end

local function PreviewStat(members, def)
    local miss, unknown, minR, minDur = {}, 0, math.huge, 0
    for _, member in ipairs(members) do
        local state = member._preview[def.id]
        if state.kind == "MISSING" then miss[#miss + 1] = member
        elseif state.kind == "UNKNOWN" then unknown = unknown + 1
        elseif state.rem < minR then minR, minDur = state.rem, state.dur end
    end
    return {
        miss = miss, nMiss = #miss, nUnknown = unknown, nTotal = #members,
        allHave = #miss == 0 and unknown == 0,
        minR = minR == math.huge and 0 or minR, minDur = minDur,
    }
end

local function Rebuild(self)
    if not self:Init() then return end
    -- Before anything is measured or placed: a window an older copy built
    -- arrives here with the previous layout, and every position below is
    -- computed from this one's metrics.
    self:AdoptLayout()
    local engine = self.engine
    local main = self.main

    local preview = self.previewGroups ~= nil
    local groups, ord
    if preview then groups, ord = PreviewRoster(self) else groups, ord = engine:GatherGroups() end
    if #ord == 0 then self:Close(); return end

    -- The pass this runs inside is open from the top, which puts ActiveDefs
    -- inside it too - deliberately. A host's visibility rule can read auras:
    -- Priestly's "show Shadow Protection when somebody has it" walks the whole
    -- roster looking for one, immediately before these rows ask about the same
    -- members (#6).
    local defs
    if preview then
        -- Every def, as before, except those that only exist when assigned
        -- (r37): an unassigned priest's preview has no Fear Ward row.
        defs = {}
        for _, d in ipairs(engine.defs) do
            if not d.assignOnly then defs[#defs + 1] = d end
        end
    else
        defs = engine:ActiveDefs(groups, ord)
    end
    if #defs == 0 then self:Close(); return end

    ApplyLook(self)
    if preview then
        if not self.previewSavedTitle then self.previewSavedTitle = main.title:GetText() end
        main.title:SetText(self.previewSavedTitle .. " [Test]")
    elseif self.previewSavedTitle then
        main.title:SetText(self.previewSavedTitle)
        self.previewSavedTitle = nil
    end
    if preview then
        if main.closeBtn then main.closeBtn:Hide() end
        if main.minimizeBtn then main.minimizeBtn:Hide() end
    end
    -- Normal UI panels must remain usable above the buff window. Apply on
    -- rebuild too, so a window constructed by an older library is upgraded.
    -- Rebuild only runs outside combat; both frames parent secure buttons.
    main:SetFrameStrata("LOW")
    self.pop:SetFrameStrata("LOW")

    for _, r in ipairs(self.rows) do r._active = false; r:Hide() end
    for _, h in ipairs(self.headers) do h:Hide() end

    local maxRows, maxGroups = #self.rows, #self.headers
    local rowIdx, hdrIdx = 0, 0
    local y = -(HDR_H + 6)
    local inRaid = preview or IsInRaid()
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
            local members = preview and groups[gNum] or engine:MembersFor(def, groups[gNum])
            if #members > 0 then
                rowsHere[#rowsHere + 1] = { def = def, members = members }
                -- One cast of a raid-wide buff covers everyone, so its target
                -- is chosen across the roster rather than inside one subgroup.
                -- That is what lets a click on any row fix everybody, and what
                -- leaves the other rows' clicks nothing to do.
                if not preview and engine:IsRaidWide(def) then
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
                local st = preview and PreviewStat(members, def) or engine:GroupStat(members, def)
                local primary, secondary
                if not preview then primary, secondary = engine:ClickSpells(def) end
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
                r._castMembers = preview and nil or raidWide[def.id]

                self:ApplyRowVisuals(r, st)

                -- Left: the group spell on whoever needs it most (it covers
                -- their subgroup; a pet row spans several), or the single one
                -- when there is no group spell. Right: the single spell on
                -- whoever needs it most.
                r:SetAttribute("type1",  not preview and "spell" or nil)
                r:SetAttribute("spell1", primaryUnit and primary or nil)
                r:SetAttribute("unit1",  not preview and (primaryUnit or "player") or nil)
                r:SetAttribute("type2",  not preview and "spell" or nil)
                r:SetAttribute("spell2", secondaryUnit and secondary or nil)
                r:SetAttribute("unit2",  not preview and (secondaryUnit or "player") or nil)

                r:Show()
                y = y - ROW_H - 1
            end
        end
    end

    -- Every buff filtered down to nobody: there is nothing to show.
    if rowIdx == 0 then self:Close(); return end

    y = y - 2
    y = self:LayoutFooter(y)

    local growth = GrowthDirection(self)
    local reanchored = false
    if growth and (self.moved or main:IsShown()) then
        reanchored = AnchorEdge(main, growth)
    end
    local minimized = self:IsMinimized()
    -- A close can hide the old layout before a deferred mode change is applied.
    -- Preserve its header too; an unpositioned first layout still restores below.
    if minimized ~= (main._minimized == true) and main:GetPoint() then
        if not growth then AnchorEdge(main, "down") end
        self.moved = true
    end
    if minimized then
        for _, r in ipairs(self.rows) do r._active = false; r:Hide() end
        for _, h in ipairs(self.headers) do h:Hide() end
        for _, btn in ipairs(self.footerBtns) do btn:Hide() end
        main.ftrLine:Hide()
        self.pop:Hide()
        self.popHidePending = false
        self.hintRow = nil
        self.tipPending, self.tipButton = false, nil
        if GameTooltip:GetOwner() and GameTooltip:GetOwner()._ui == self then ReleaseTooltip() end
    end
    main._minimized = minimized
    if main.minimizeBtn then main.minimizeBtn.label:SetText(minimized and "+" or "-") end
    main:SetSize(FRAME_W, minimized and (HDR_H + 8) or (math.abs(y) + 2))

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
    if growth then
        if AnchorEdge(main, growth) then reanchored = true end
        if reanchored and self.host.getPos and self.host.getPos() then SavePosition(self) end
        self.moved = true
    end

    main:Show()
    -- Shown for real, out of combat: a close recorded in combat is superseded
    -- by this later request, and OnCombatEnd must not hide the window it
    -- would leave logically open (and a companion following IsVisible up).
    self.closePending = false
    self.closeExplained = nil
    -- Fresh ticks: time left over from before a close is not this showing's
    -- (and the rebuild has just laid the footer out).
    if not self.visible then self.tick, self.footerTick = 0, 0 end
    SetVisible(self, true)
    if not preview then Call(self.host.setVisible, true) end
    self.laidOut = true
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
            -- The window is wanted again before the fight ends: whatever close
            -- was explained is reversed, so a close after this one is new
            -- news and gets its own explanation.
            self.closeExplained = nil
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

do -- Assign ==================================================================

-- ============================================================================
-- Raid buff assignments (#92): who casts each raid-wide buff, and who a
-- caster keeps a single-target buff on. Shared by every host on the client and
-- by every client in the group, whichever of the four addons each one runs.
--
-- WHAT IS ASSIGNED. The slot table below is protocol data, the same in every
-- copy: a standalone Priestly must be able to draw and edit a mage's slot. A
-- host's def opts in with `assign = "owner"` or `assign = "targets"`, and is
-- matched to its slot by `assignSlot or snglID`. `assignOnly = true` gives a
-- def no row until the player has targets for it (Fear Ward).
--
-- STATE. One record per slot, { ver, writer, value }, kept for the whole
-- group session, clears included, so an old value can never come back.
-- Records order by (ver, writer, value): every client keeps the same winner
-- whatever order messages arrive in. A local edit takes
-- max(server time, current ver + 1), so it beats everything its editor has
-- seen, and after a /reload everything older than the current server second.
--
-- AN OWNER COUNTS ONLY WHILE LIVE: in the group, connected, heard from within
-- PEER_TTL (not counted down while chat is locked down), and still able to
-- cast the slot's spell (the group form for the raid-wide ones). Otherwise the
-- slot acts unowned and other casters get their rows back; the record stays,
-- so the claim resumes when the owner does.
--
-- PROTOCOL v1, prefix "LibGroupBuffs" on the selected group's channel (the
-- home group if any, else the instance group; RAID, PARTY or INSTANCE_CHAT):
--     1^H^<class>^<known spell ids, csv>^<digest>      hello
--     1^A^<slot key>^<ver>^<writer>^<value>            one record
-- A hello goes out on joining, on entering the world, when what the player
-- can cast changes, to answer a new peer, and every HELLO_PERIOD. A peer whose
-- digest differs from ours schedules ONE repair a few seconds later, which
-- sends every record the channel has not already carried during the wait, so
-- a joiner in a full raid is answered about once, not by everyone.
--
-- MEASURED (NodeRadar FOREVER-PROBE.md, porting guide): PARTY and RAID arrive
-- in about 0.25 s, the throttle allows about 10 then 1 a second and DROPS what
-- it refuses (result 3), 256 bytes arrive cut to 255 with no error, the
-- sender reads "Name Surname" = GetUnitName(unit, false), and our own
-- messages come back to us. Not measured: a raid instance, a boss fight,
-- INSTANCE_CHAT.
--
-- UPGRADES. lib.assign is the client's state and keeps its identity; every
-- frame script and timer calls lib.AssignImpl.<name> when it runs. The
-- functions take the client as their first argument and reach the game only
-- through its `env` (default: the real API), so the tests run several
-- clients side by side on a simulated channel.
--
-- EVENTS. This section is the one exception to "events are the host's
-- policy" (AGENTS.md): one anonymous frame, created when the first host opts
-- in, registered through that host's instance so a refusal reaches its
-- reporter. The library still never prints.
-- ============================================================================

local PREFIX, PROTO, SEP = "LibGroupBuffs", "1", "^"
local MAX_BYTES = 255
local HELLO_PERIOD, HELLO_JITTER, PEER_TTL = 60, 10, 180
-- A version counts VER_SCALE steps per server second: max(server seconds x
-- VER_SCALE, current + 1). Edits within one second take the next steps, so a
-- version stays inside its second unless a slot sees VER_SCALE edits in it,
-- and an edit made in a later second (after a /reload, say) beats every
-- earlier one. One more than a day ahead of the server is refused, so every
-- accepted record can still be beaten by a later edit; ~1.8e12 is an exact
-- integer in Lua 5.1's doubles (2^53).
local VER_SCALE, VER_AHEAD, VER_DIGITS = 1000, 86400, 16
local BUCKET, REFILL, BACKOFF = 10, 1, 2
local PRIO_EDIT, PRIO_HELLO, PRIO_REPAIR = 1, 2, 3
local HOME = LE_PARTY_CATEGORY_HOME or 1
local INSTANCE = LE_PARTY_CATEGORY_INSTANCE or 2

-- The v1 slot table. `needs` is the spell an owner must know (the group form
-- for the raid-wide buffs); a slot with `choices` is owned with one of them.
-- `label` names the slot in the panel.
local SLOTS = {
    { key = 1243,  class = "PRIEST", kind = "owner",   needs = 21562, label = 21562 }, -- Prayer of Fortitude
    { key = 14752, class = "PRIEST", kind = "owner",   needs = 27681, label = 27681 }, -- Prayer of Spirit
    { key = 976,   class = "PRIEST", kind = "owner",   needs = 27683, label = 27683 }, -- Prayer of Shadow Protection
    { key = 6346,  class = "PRIEST", kind = "targets", needs = 6346,  label = 6346  }, -- Fear Ward
    { key = 1126,  class = "DRUID",  kind = "owner",   needs = 21849, label = 21849 }, -- Gift of the Wild
    { key = 467,   class = "DRUID",  kind = "targets", needs = 467,   label = 467   }, -- Thorns
    { key = 1459,  class = "MAGE",   kind = "owner",   needs = 23028, label = 23028 }, -- Arcane Brilliance
    { key = 1008,  class = "MAGE",   kind = "owner",   choices = { 1008, 604 }, label = 1008 }, -- Amplify / Dampen
}
local SLOT_BY_KEY, CLASS_ORDER = {}, { "PRIEST", "DRUID", "MAGE" }
for _, slot in ipairs(SLOTS) do SLOT_BY_KEY[slot.key] = slot end
lib.ASSIGN_SLOTS = SLOTS

lib.AssignImpl = lib.AssignImpl or {}
lib.AssignHandle = lib.AssignHandle or {}
lib.AssignHandleMeta = lib.AssignHandleMeta or {}
lib.AssignHandleMeta.__index = lib.AssignHandle
local AI, Handle = lib.AssignImpl, lib.AssignHandle

-- ─── The game, behind one table ─────────────────────────────────────────────

-- Everything that can be secret is read inside a pcall, comparisons included:
-- on this client a secret value throws when it is compared, not only read.
local function ReadName(unit)
    local n = GetUnitName(unit, false)
    if type(n) == "string" and n ~= "" and n ~= UNKNOWNOBJECT then return n end
    return nil
end

local function NameOf(unit)
    if not unit then return nil end
    local ok, n = pcall(ReadName, unit)
    if ok then return n end
    return nil
end
AI.NameOf = NameOf

local PARTY_UNITS = { "player", "party1", "party2", "party3", "party4" }

local DEFAULT_ENV = {}
function DEFAULT_ENV.now() return GetTime() end
function DEFAULT_ENV.serverNow()
    local ok, t = pcall(GetServerTime)
    if ok and type(t) == "number" then return math.floor(t) end
    return math.floor(GetTime())
end
function DEFAULT_ENV.send(msg, channel)
    return C_ChatInfo.SendAddonMessage(PREFIX, msg, channel)
end
function DEFAULT_ENV.lockdown()
    local f = C_ChatInfo and C_ChatInfo.InChatMessagingLockdown
    if not f then return false end
    local ok, v = pcall(f)
    return ok and v == true
end
function DEFAULT_ENV.combat() return InCombatLockdown() and true or false end
function DEFAULT_ENV.after(delay, fn) C_Timer.After(delay, fn) end
function DEFAULT_ENV.random() return math.random() end
function DEFAULT_ENV.category()
    if IsInGroup(HOME) then return HOME end
    if IsInGroup(INSTANCE) then return INSTANCE end
    return nil
end
function DEFAULT_ENV.channel(category)
    if category == INSTANCE then return "INSTANCE_CHAT" end
    if IsInRaid(category) then return "RAID" end
    return "PARTY"
end
-- name -> { unit, class, online, pet = false }, and the player's own name.
function DEFAULT_ENV.roster()
    local out, units = {}, PARTY_UNITS
    if IsInRaid() then
        units = {}
        for i = 1, GetNumGroupMembers() do units[i] = "raid" .. i end
    end
    for _, unit in ipairs(units) do
        if UnitExists(unit) then
            local name = NameOf(unit)
            if name then
                local _, class = UnitClass(unit)
                out[name] = { unit = unit, class = class, online = UnitIsConnected(unit) and true or false }
            end
        end
    end
    return out, NameOf("player")
end
function DEFAULT_ENV.knows(spellID) return lib.API.KnowsSpell(spellID) end
function DEFAULT_ENV.myClass()
    local _, class = UnitClass("player")
    return class
end

local function Env(c) return c.env or DEFAULT_ENV end

-- ─── Records ────────────────────────────────────────────────────────────────

-- Whether record a is newer than b. A total order: every client keeps the
-- same winner, even for an equal version and writer with different values.
local function Newer(a, b)
    if not b then return true end
    if not a then return false end
    if a.ver ~= b.ver then return a.ver > b.ver end
    if a.writer ~= b.writer then return a.writer > b.writer end
    return a.value > b.value
end
AI.Newer = Newer

local function Split(s, sep)
    local out, start = {}, 1
    while true do
        local i = s:find(sep, start, true)
        if not i then out[#out + 1] = s:sub(start); return out end
        out[#out + 1] = s:sub(start, i - 1)
        start = i + 1
    end
end

local function Names(value)
    if value == "" then return {} end
    return Split(value, ",")
end

-- One checksum over the canonical full records, other classes and clears
-- included. "0" for none. A checksum can collide: repair is a convergence
-- mechanism, not a proof.
local function Digest(records)
    local keys = {}
    for k in pairs(records) do keys[#keys + 1] = k end
    if #keys == 0 then return "0" end
    table.sort(keys)
    local h = 5381
    for _, k in ipairs(keys) do
        local r = records[k]
        local s = k .. "|" .. r.ver .. "|" .. r.writer .. "|" .. r.value .. "\n"
        for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
    end
    return string.format("%08x", h)
end
AI.Digest = Digest

local function EncodeRecord(key, r)
    return table.concat({ PROTO, "A", key, tostring(r.ver), r.writer, r.value }, SEP)
end
AI.EncodeRecord = EncodeRecord

-- A key names a slot ("1243") or a caster's list on one ("467:Name Surname").
local function ParseKey(key)
    local id, caster = key:match("^(%d+):(.+)$")
    if id then
        local slot = SLOT_BY_KEY[tonumber(id)]
        if slot and slot.kind == "targets" then return slot, caster end
        return nil
    end
    local slot = SLOT_BY_KEY[tonumber(key) or -1]
    if slot and slot.kind == "owner" and tostring(slot.key) == key then return slot end
    return nil
end

local function ValidName(name)
    return name ~= "" and not name:find("[%^,:|]")
end

-- Whether a value is well formed for its slot. Every client applies the same
-- rule, so no client can hold a record the others refuse.
local function ValidValue(slot, value)
    if value == "" then return true end
    if slot.kind == "targets" then
        for _, name in ipairs(Names(value)) do
            if not ValidName(name) then return false end
        end
        return true
    end
    local owner, choice = value:match("^([^,]+),(%d+)$")
    if slot.choices then
        if not owner then return false end
        choice = tonumber(choice)
        for _, id in ipairs(slot.choices) do
            if id == choice then return ValidName(owner) end
        end
        return false
    end
    return ValidName(value)
end

-- An owner slot's value: the owner, and the chosen spell for a slot with
-- choices.
local function ParseOwner(slot, value)
    if value == "" then return nil end
    if slot.choices then
        local owner, choice = value:match("^([^,]+),(%d+)$")
        return owner, tonumber(choice)
    end
    return value, nil
end

-- ─── The client ─────────────────────────────────────────────────────────────

-- Fills in whatever a client lacks, so an upgrade adds fields without
-- dropping the state an older copy built.
function AI.Fill(c)
    c.records = c.records or {}
    c.peers = c.peers or {}
    c.queue = c.queue or {}
    c.seq = c.seq or 0
    c.subs = c.subs or {}
    c.roster = c.roster or {}
    c.mySpells = c.mySpells or {}
    c.spellList = c.spellList or ""
    c.otherVersions = c.otherVersions or {}
    c.gen = c.gen or 0
    c.effective = c.effective or ""
    -- Diagnostics for the in-game check: what the client answered each send
    -- with (by result code), and what arrived on our prefix.
    c.stats = c.stats or { results = {}, received = 0, accepted = 0 }
    return c
end

function AI.NewClient(env)
    return AI.Fill({ env = env })
end

function AI.Wipe(c)
    c.records, c.peers, c.queue = {}, {}, {}
    c.repair, c.blockedUntil = nil, nil
    c.pending = nil
    c.otherVersions = {}
    c.gen = c.gen + 1
end

local function Report(c, text)
    local sub = c.subs[1]
    if sub and sub.report then sub.report(text, "assign") end
end

-- A peer's age stands still while chat is locked down: nobody can say hello
-- then, so a fight longer than PEER_TTL must not expire everyone at unlock.
-- Sampled on ADDON_RESTRICTION_STATE_CHANGED, combat and every check. During
-- that event's dispatch the client still reports no lockdown (the restriction
-- is "Activating", enforced only once dispatch ends), so the event's own state
-- is kept in c.chatRestricted and counts as locked.
function AI.LockClock(c)
    local env = Env(c)
    local now = env.now()
    if c.chatRestricted or env.lockdown() then
        c.lockedAt = c.lockedAt or now
    elseif c.lockedAt then
        local from = c.lockedAt
        c.lockedAt = nil
        for _, peer in pairs(c.peers) do
            if peer.seen < from then peer.seen = peer.seen + (now - from) else peer.seen = now end
        end
    end
end

-- Whether `name` is in the group now and can cast `spell`.
local function Capable(c, name, spell)
    if not name or not spell then return false end
    if name == c.me then return c.mySpells[spell] == true end
    local member, peer = c.roster[name], c.peers[name]
    if not member or not member.online or not peer or not peer.spells[spell] then return false end
    AI.LockClock(c)
    return c.lockedAt ~= nil or Env(c).now() - peer.seen <= PEER_TTL
end
AI.Capable = Capable

-- The live owner of an owner slot, and the chosen spell, or nil.
function AI.Owner(c, slot)
    local rec = c.records[tostring(slot.key)]
    if not rec then return nil end
    local owner, choice = ParseOwner(slot, rec.value)
    if owner and Capable(c, owner, choice or slot.needs) then return owner, choice end
    return nil
end

-- The recorded owner whether live or not, for the panel's "away".
function AI.RecordedOwner(c, slot)
    local rec = c.records[tostring(slot.key)]
    if not rec then return nil end
    return ParseOwner(slot, rec.value)
end

-- A caster's target list on a targets slot (names, possibly empty).
function AI.Targets(c, slot, caster)
    local rec = caster and c.records[slot.key .. ":" .. caster]
    if not rec then return {} end
    return Names(rec.value)
end

-- What the hosts' windows depend on, as one string: when it changes, they
-- are told. It covers capability loss, expiry and return, not only records.
local function Effective(c)
    local parts = {}
    for _, slot in ipairs(SLOTS) do
        if slot.kind == "owner" then
            local owner, choice = AI.Owner(c, slot)
            parts[#parts + 1] = tostring(owner) .. "," .. tostring(choice)
        else
            parts[#parts + 1] = table.concat(AI.Targets(c, slot, c.me), ",")
        end
    end
    return table.concat(parts, ";")
end

function AI.Changed(c)
    local now = Effective(c)
    if now ~= c.effective then
        c.effective = now
        for _, sub in ipairs(c.subs) do
            if sub.onChanged then
                local ok, err = pcall(sub.onChanged)
                if not ok and sub.report then sub.report("assignment update failed: " .. tostring(err), "assign") end
            end
        end
    end
    AI.PanelRefresh(c)
end

-- Applies a record if it beats the stored one. Returns whether it did.
function AI.Apply(c, key, rec)
    if c.repair then
        local seen = c.repair.seen[key]
        if Newer(rec, seen) then c.repair.seen[key] = rec end
    end
    if not Newer(rec, c.records[key]) then return false end
    c.records[key] = rec
    return true
end

-- ─── Sending ────────────────────────────────────────────────────────────────

-- One entry per key: a newer record replaces an older one, and the entry
-- keeps the more urgent of the two priorities.
local function Enqueue(c, qkey, prio, msg, rec)
    local old = c.queue[qkey]
    if old and rec and old.rec and Newer(old.rec, rec) then return end
    c.seq = c.seq + 1
    c.queue[qkey] = { qkey = qkey, prio = old and math.min(old.prio, prio) or prio, seq = c.seq,
                      msg = msg, rec = rec }
end

local function NextEntry(c)
    local best
    for _, e in pairs(c.queue) do
        if not best or e.prio < best.prio or (e.prio == best.prio and e.seq < best.seq) then best = e end
    end
    return best
end

function AI.HelloMessage(c)
    return table.concat({ PROTO, "H", c.myClass or "", c.spellList, Digest(c.records) }, SEP)
end

function AI.SchedulePump(c, delay)
    local env = Env(c)
    local at = env.now() + delay
    if c.pumpAt and c.pumpAt <= at then return end
    c.pumpAt = at
    env.after(delay, function() return lib.AssignImpl.Pump(c) end)
end

-- Sends what the token bucket allows. A throttle or lockdown answer keeps the
-- message and backs off; the measured throttle drops what it refuses, so a
-- message is only taken off the queue once the client accepted it.
function AI.Pump(c)
    c.pumpAt = nil
    if not c.group or not c.channel then c.queue = {}; return end
    local env = Env(c)
    local now = env.now()
    c.tokens = math.min(BUCKET, (c.tokens or BUCKET) + (now - (c.refilled or now)) * REFILL)
    c.refilled = now
    if c.blockedUntil and now < c.blockedUntil then return AI.SchedulePump(c, c.blockedUntil - now) end
    if env.lockdown() then return AI.SchedulePump(c, BACKOFF) end
    while c.tokens >= 1 do
        local e = NextEntry(c)
        if not e then return end
        local msg = e.msg or AI.HelloMessage(c)
        local ok, res = pcall(env.send, msg, c.channel)
        local code = ok and tostring(res) or "error"
        c.stats.results[code] = (c.stats.results[code] or 0) + 1
        if ok and (res == 0 or res == nil or res == true) then
            c.queue[e.qkey] = nil
            c.tokens = c.tokens - 1
            if e.rec and c.repair then
                local key = e.qkey:sub(3)
                if Newer(e.rec, c.repair.seen[key]) then c.repair.seen[key] = e.rec end
            end
        elseif ok and (res == 3 or res == 8 or res == 11) then
            c.blockedUntil = now + BACKOFF
            return AI.SchedulePump(c, BACKOFF)
        else
            c.queue[e.qkey] = nil
            if not (ok and res == 5) and not c.sendFailed then
                c.sendFailed = true
                Report(c, "an assignment message could not be sent (" .. tostring(res) .. ")")
            end
        end
    end
    if next(c.queue) then AI.SchedulePump(c, 1 / REFILL) end
end

function AI.SendHello(c)
    if not c.group or not c.me then return end
    Enqueue(c, "H", PRIO_HELLO)
    AI.SchedulePump(c, 0)
end

-- Soon, not now: a burst of roster events or new peers sends one hello.
function AI.HelloSoon(c)
    if c.helloSoon or not c.group then return end
    c.helloSoon = true
    local env = Env(c)
    env.after(1 + env.random() * 2, function() return lib.AssignImpl.HelloSoonFire(c) end)
end

function AI.HelloSoonFire(c)
    c.helloSoon = nil
    AI.SendHello(c)
end

function AI.StartHelloLoop(c)
    c.helloGen = (c.helloGen or 0) + 1
    local gen, env = c.helloGen, Env(c)
    env.after(HELLO_PERIOD + (env.random() * 2 - 1) * HELLO_JITTER,
        function() return lib.AssignImpl.HelloTick(c, gen) end)
end

function AI.HelloTick(c, gen)
    if gen ~= c.helloGen or not c.group then return end
    AI.Expire(c)
    AI.SendHello(c)
    AI.StartHelloLoop(c)
    AI.Changed(c)
end

-- ─── Repair ─────────────────────────────────────────────────────────────────

function AI.ScheduleRepair(c)
    if c.repair then return end
    c.repair = { seen = {}, gen = c.gen }
    local env = Env(c)
    env.after(1 + env.random() * 4, function() return lib.AssignImpl.RepairFire(c) end)
end

function AI.RepairFire(c)
    local rep = c.repair
    c.repair = nil
    if not rep or rep.gen ~= c.gen or not c.group then return end
    local mine, differs = Digest(c.records), false
    for name, peer in pairs(c.peers) do
        if peer.digest ~= mine and c.roster[name] then differs = true; break end
    end
    if not differs then return end
    for key, rec in pairs(c.records) do
        if Newer(rec, rep.seen[key]) then
            Enqueue(c, "A:" .. key, PRIO_REPAIR, EncodeRecord(key, rec), rec)
        end
    end
    AI.SchedulePump(c, 0)
end

-- ─── Receiving ──────────────────────────────────────────────────────────────

local function Plain(text, channel, sender)
    return type(text) == "string" and type(channel) == "string" and type(sender) == "string"
        and #text <= MAX_BYTES and channel ~= "" and sender ~= ""
end

function AI.Receive(c, text, channel, sender)
    -- No payload was measured secret, but a comparison on one would throw:
    -- the type and size checks run protected, and only plain strings go on.
    c.stats.received = c.stats.received + 1
    local ok, plain = pcall(Plain, text, channel, sender)
    if not ok or not plain then return end
    if not c.group or channel ~= c.channel or sender == c.me then return end
    local member = c.roster[sender]
    if not member then return end
    c.stats.accepted = c.stats.accepted + 1
    local f = Split(text, SEP)
    if f[1] ~= PROTO then
        c.otherVersions[sender] = f[1]
        return
    end
    if f[2] == "H" and #f == 5 then
        if f[3] ~= member.class then return end
        local spells = {}
        for id in f[4]:gmatch("%d+") do spells[tonumber(id)] = true end
        local isNew = c.peers[sender] == nil
        c.peers[sender] = { class = f[3], spells = spells, digest = f[5], seen = Env(c).now() }
        if isNew then AI.HelloSoon(c) end
        if f[5] ~= Digest(c.records) then AI.ScheduleRepair(c) end
        AI.Changed(c)
    elseif f[2] == "A" and #f == 6 then
        local key, ver, writer, value = f[3], AI.ParseVersion(c, f[4]), f[5], f[6]
        local slot = ParseKey(key)
        if not slot or not ver or not ValidName(writer) or not ValidValue(slot, value) then return end
        if AI.Apply(c, key, { ver = ver, writer = writer, value = value }) then AI.Changed(c) end
    end
end

-- A version as sent: decimal digits with no sign, point or leading zero, and
-- no more than VER_AHEAD past the server's clock. Anything else is refused.
function AI.ParseVersion(c, text)
    if type(text) ~= "string" or #text > VER_DIGITS or not text:match("^[1-9]%d*$") then return nil end
    local ver = tonumber(text)
    if not ver or ver > (Env(c).serverNow() + VER_AHEAD) * VER_SCALE then return nil end
    return ver
end

-- ─── Group and capability ───────────────────────────────────────────────────

function AI.Expire(c)
    local env = Env(c)
    AI.LockClock(c)
    if c.lockedAt then return end
    local now = env.now()
    for name, peer in pairs(c.peers) do
        if not c.roster[name] or now - peer.seen > PEER_TTL then c.peers[name] = nil end
    end
end

-- The selected group decides everything: records, peers, timers and the
-- queue belong to it, and a change of selected group starts them again.
function AI.RosterChanged(c)
    local env = Env(c)
    local category = env.category()
    if category ~= c.group then
        AI.Wipe(c)
        c.group = category
        c.helloGen = (c.helloGen or 0) + 1
        if category then
            c.channel = env.channel(category)
            c.roster, c.me = env.roster()
            AI.StartHelloLoop(c)
            AI.HelloSoon(c)
        else
            c.channel, c.roster = nil, {}
        end
    elseif category then
        c.channel = env.channel(category)
        c.roster, c.me = env.roster()
    end
    AI.Expire(c)
    AI.Changed(c)
end

-- What the player can cast, from their own spellbook (never from their own
-- echo). A change goes out in a hello.
function AI.SpellsChanged(c)
    local env = Env(c)
    c.myClass = env.myClass()
    local known, list = {}, {}
    for _, slot in ipairs(SLOTS) do
        if slot.class == c.myClass then
            for _, id in ipairs(slot.choices or { slot.needs }) do
                if not known[id] and env.knows(id) then known[id] = true; list[#list + 1] = id end
            end
        end
    end
    table.sort(list)
    local text = table.concat(list, ",")
    c.mySpells = known
    if text ~= c.spellList then
        c.spellList = text
        AI.HelloSoon(c)
    end
    AI.Changed(c)
end

-- ─── Edits ──────────────────────────────────────────────────────────────────

-- Writes one record and sends it. Refused out of a group, in combat (the
-- panel is read-only there), and when the message would not fit: 256 bytes
-- arrive cut to 255 with no error, so an edit that cannot be sent whole is
-- not applied either. Returns ok, why.
function AI.Edit(c, key, value)
    local env = Env(c)
    if not c.group or not c.me then return false, "group" end
    if env.combat() then return false, "combat" end
    local slot = ParseKey(key)
    if not slot or not ValidValue(slot, value) then return false, "invalid" end
    local cur = c.records[key]
    local ver = env.serverNow() * VER_SCALE
    if cur and cur.ver >= ver then ver = cur.ver + 1 end
    if ver > (env.serverNow() + VER_AHEAD) * VER_SCALE then return false, "version" end
    local rec = { ver = ver, writer = c.me, value = value }
    local msg = EncodeRecord(key, rec)
    if #msg > MAX_BYTES then return false, "size" end
    c.records[key] = rec
    Enqueue(c, "A:" .. key, PRIO_EDIT, msg, rec)
    AI.SchedulePump(c, 0)
    AI.Changed(c)
    return true
end

function AI.SetOwner(c, slot, owner, choice)
    local value = ""
    if owner then value = slot.choices and (owner .. "," .. tostring(choice)) or owner end
    return AI.Edit(c, tostring(slot.key), value)
end

function AI.SetTargets(c, slot, caster, names)
    return AI.Edit(c, slot.key .. ":" .. caster, table.concat(names or {}, ","))
end

function AI.Pending(c, key)
    local e = c.queue["A:" .. key]
    return e ~= nil and e.prio == PRIO_EDIT
end

-- ─── The live client ────────────────────────────────────────────────────────

lib.assign = AI.Fill(lib.assign or {})

-- UNIT_CONNECTION: a member going offline or back changes who is a live
-- owner without any roster event. ADDON_RESTRICTION_STATE_CHANGED: chat
-- locking and unlocking, for the peer clock.
local EVENTS = { "CHAT_MSG_ADDON", "GROUP_ROSTER_UPDATE", "GROUP_JOINED", "GROUP_LEFT",
                 "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
                 "UNIT_CONNECTION", "ADDON_RESTRICTION_STATE_CHANGED" }

function AI.OnEvent(c, event, ...)
    if event == "CHAT_MSG_ADDON" then
        local prefix, text, channel, sender = ...
        if prefix == PREFIX then return AI.Receive(c, text, channel, sender) end
    elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
        AI.LockClock(c)
        AI.PanelRefresh(c)
    elseif event == "ADDON_RESTRICTION_STATE_CHANGED" then
        local kind, state = ...
        local E = rawget(_G, "Enum")
        local types = E and E.AddOnRestrictionType
        local states = E and E.AddOnRestrictionState
        local CHAT = types and types.Chat or 5
        local INACTIVE = states and states.Inactive or 0
        if kind == CHAT and type(state) == "number" then
            c.chatRestricted = state ~= INACTIVE or nil
            AI.LockClock(c)
            AI.Changed(c)
        end
    else
        local wasGroup = c.group
        AI.RosterChanged(c)
        if event == "PLAYER_ENTERING_WORLD" and wasGroup and c.group == wasGroup then AI.HelloSoon(c) end
    end
end

-- Started by the first host to opt in; later hosts subscribe to the same one.
function AI.Start(c, inst)
    if c.frame then return end
    local frame = CreateFrame("Frame")
    c.frame = frame
    frame:SetScript("OnEvent", function(_, event, ...) return lib.AssignImpl.OnEvent(lib.assign, event, ...) end)
    inst.RegisterEvents(frame, unpack(EVENTS))
    local ok, res = pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX)
    -- 0 registered, 1 already registered (by this very prefix, so fine).
    if not ok or (res ~= 0 and res ~= 1 and res ~= nil and res ~= true) then
        inst.report("assignments are off: the client refused the message prefix (" .. tostring(res) .. ")", "assign")
    end
    AI.RosterChanged(c)
end

-- ─── The host's handle ──────────────────────────────────────────────────────

local function SlotFor(def)
    if type(def) ~= "table" or (def.assign ~= "owner" and def.assign ~= "targets") then return nil end
    local slot = SLOT_BY_KEY[def.assignSlot or def.snglID]
    if slot and slot.kind == def.assign then return slot end
    return nil
end
AI.SlotFor = SlotFor

-- What the engine does with a def's row: "force" (the raid asked me), "hide"
-- (somebody else has it, or an assignOnly def with nothing to do), or nil
-- for today's rule.
function Handle:RowRule(def)
    local c, slot = self.client, SlotFor(def)
    if not slot then return nil end
    if slot.kind == "owner" then
        local owner, choice = AI.Owner(c, slot)
        if owner == c.me and owner ~= nil then
            if slot.choices and choice ~= def.snglID then return "hide" end
            return "force"
        end
        if owner then return "hide" end
        return def.assignOnly and "hide" or nil
    end
    if #AI.Targets(c, slot, c.me) > 0 then return "force" end
    return def.assignOnly and "hide" or nil
end

-- The names a targets def is assigned to for me, as a set, or nil.
function Handle:TargetNames(def)
    local c, slot = self.client, SlotFor(def)
    if not slot or slot.kind ~= "targets" then return nil end
    local names = AI.Targets(c, slot, c.me)
    if #names == 0 then return nil end
    local set = {}
    for _, n in ipairs(names) do set[n] = true end
    return set
end

function Handle:Owner(def)
    local slot = SlotFor(def)
    if not slot or slot.kind ~= "owner" then return nil end
    return AI.Owner(self.client, slot)
end

function Handle:IsMine(def)
    local owner = self:Owner(def)
    return owner ~= nil and owner == self.client.me
end

function Handle:SpellsChanged() return AI.SpellsChanged(self.client) end
function Handle:Open() return AI.TogglePanel(self.client) end

-- ─── The panel ──────────────────────────────────────────────────────────────
--
-- An ordinary frame parented to UIParent, with no secure child: the measured
-- companion-pane shape, free to show, hide and change in combat. Editing is
-- refused in combat anyway, and the menus only write assignment data.

local PANEL_W, LINE_H, PAD = 320, 20, 10
local FONT_FILE = "Fonts\\ARIALN.TTF"
local GREY = "|cff888888"

local function Text(fs, size, justify)
    local file = GlassFontFile(FONT_FILE)
    if not fs:SetFont(file, size, "") and file ~= FONT_FILE then fs:SetFont(FONT_FILE, size, "") end
    fs:SetShadowColor(0, 0, 0, 0.9)
    fs:SetShadowOffset(1, -1)
    if justify then fs:SetJustifyH(justify) end
    return fs
end

local function SpellLabel(id)
    return lib.API.SpellName(id) or ("spell " .. tostring(id))
end

local function SlotLabel(slot)
    if slot.choices then
        local names = {}
        for _, id in ipairs(slot.choices) do names[#names + 1] = SpellLabel(id) end
        return table.concat(names, " / ")
    end
    return SpellLabel(slot.label)
end

local function ClassHex(class)
    local col = RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if not col then return "|cffcccccc" end
    return string.format("|cff%02x%02x%02x", math.floor(col.r * 255 + 0.5),
        math.floor(col.g * 255 + 0.5), math.floor(col.b * 255 + 0.5))
end

-- The player and every live peer of `class` who can cast `spell`, by name.
local function Casters(c, class, spell)
    local out = {}
    local function consider(name, cls)
        if cls == class and Capable(c, name, spell) then out[#out + 1] = name end
    end
    if c.me then consider(c.me, c.myClass) end
    for name, peer in pairs(c.peers) do
        if name ~= c.me then consider(name, peer.class) end
    end
    table.sort(out)
    return out
end
AI.Casters = Casters

local function SlotCasters(c, slot)
    if slot.choices then
        local seen, out = {}, {}
        for _, id in ipairs(slot.choices) do
            for _, name in ipairs(Casters(c, slot.class, id)) do
                if not seen[name] then seen[name] = true; out[#out + 1] = name end
            end
        end
        table.sort(out)
        return out
    end
    return Casters(c, slot.class, slot.needs)
end

function AI.BuildPanel(c)
    if c.panel then return c.panel end
    local f = CreateFrame("Frame", nil, UIParent)
    f:SetSize(PANEL_W, 80)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 100)
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(fr) fr:StartMoving() end)
    f:SetScript("OnDragStop", function(fr) fr:StopMovingOrSizing() end)
    f.glass = GlassInst().Apply(f, "large")
    f.title = Text(f:CreateFontString(nil, "OVERLAY"), 14, "LEFT")
    f.title:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -PAD)
    f.title:SetText("Buff assignments")
    local close = CreateFrame("Button", nil, f)
    close:SetSize(18, 18)
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)
    close.label = Text(close:CreateFontString(nil, "OVERLAY"), 14, "CENTER")
    close.label:SetPoint("CENTER", close, "CENTER", 0, 0)
    close.label:SetText("\195\151")
    close:SetScript("OnClick", function() return lib.AssignImpl.TogglePanel(lib.assign, false) end)
    f.closeBtn = close
    f.note = Text(f:CreateFontString(nil, "OVERLAY"), 11, "LEFT")
    f.note:SetWidth(PANEL_W - 2 * PAD)
    f.lines = {}
    f:Hide()
    c.panel = f
    return f
end

local function Line(f, i)
    local b = f.lines[i]
    if b then return b end
    b = CreateFrame("Button", nil, f)
    b:SetSize(PANEL_W - 2 * PAD, LINE_H)
    b.label = Text(b:CreateFontString(nil, "OVERLAY"), 12, "LEFT")
    b.label:SetPoint("LEFT", b, "LEFT", 0, 0)
    b.value = Text(b:CreateFontString(nil, "OVERLAY"), 12, "RIGHT")
    b.value:SetPoint("RIGHT", b, "RIGHT", 0, 0)
    b:SetScript("OnClick", function(btn) return lib.AssignImpl.LineClick(lib.assign, btn) end)
    f.lines[i] = b
    return b
end

local function OwnerText(c, slot)
    local owner, choice = AI.Owner(c, slot)
    local key = tostring(slot.key)
    local text
    if owner then
        text = owner .. (choice and (" - " .. SpellLabel(choice)) or "")
    else
        local recorded = AI.RecordedOwner(c, slot)
        text = GREY .. "Nobody" .. (recorded and (" (" .. recorded .. " away)") or "") .. "|r"
    end
    if AI.Pending(c, key) then text = text .. GREY .. " (sending)|r" end
    return text
end

local function TargetsText(c, slot, caster)
    local names = AI.Targets(c, slot, caster)
    local text = #names > 0 and table.concat(names, ", ") or (GREY .. "No targets|r")
    if AI.Pending(c, slot.key .. ":" .. caster) then text = text .. GREY .. " (sending)|r" end
    return text
end

function AI.PanelRefresh(c)
    local f = c.panel
    if not f or not f:IsShown() then return end
    local n, y = 0, -(PAD + 22)
    local function add(label, value, slot, caster)
        n = n + 1
        local b = Line(f, n)
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, y)
        b.label:SetText(label)
        b.value:SetText(value)
        b._slotKey, b._caster = slot and slot.key, caster
        b:Show()
        y = y - LINE_H
    end
    if c.group then
        for _, class in ipairs(CLASS_ORDER) do
            local any = false
            for _, slot in ipairs(SLOTS) do
                if slot.class == class then
                    local hex = ClassHex(class)
                    local casters = SlotCasters(c, slot)
                    if slot.kind == "owner" then
                        if #casters > 0 or AI.RecordedOwner(c, slot) then
                            any = true
                            add(hex .. SlotLabel(slot) .. "|r", OwnerText(c, slot), slot)
                        end
                    else
                        for _, caster in ipairs(casters) do
                            any = true
                            add(hex .. SlotLabel(slot) .. "|r  " .. caster, TargetsText(c, slot, caster), slot, caster)
                        end
                    end
                end
            end
            if any then y = y - 6 end
        end
    end
    for i = n + 1, #f.lines do f.lines[i]:Hide() end
    local note
    if not c.group then note = "Join a group to assign buffs."
    elseif n == 0 then note = "Nobody here runs a buff addon that shares assignments yet."
    elseif Env(c).combat() then note = "In combat: edits wait, and buff windows update after combat."
    else note = "Click a line to change it. Anyone can change any assignment." end
    f.note:ClearAllPoints()
    f.note:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, y - 4)
    f.note:SetText(GREY .. note .. "|r")
    f:SetHeight(-y + 4 + 30)
end

function AI.TogglePanel(c, show)
    local f = AI.BuildPanel(c)
    if show == nil then show = not f:IsShown() end
    if show then f:Show(); AI.PanelRefresh(c) else f:Hide() end
    return show
end

local function Say(c, text)
    local f = c.panel
    if f and f:IsShown() then f.note:SetText(GREY .. text .. "|r") end
end

function AI.LineClick(c, btn)
    local slot = btn._slotKey and SLOT_BY_KEY[btn._slotKey]
    if not slot then return end
    if Env(c).combat() then return Say(c, "Edits wait until combat ends.") end
    if not (MenuUtil and MenuUtil.CreateContextMenu) then return Say(c, "This client has no menus to edit with.") end
    local key, caster = btn._slotKey, btn._caster
    if slot.kind == "owner" then
        MenuUtil.CreateContextMenu(btn, function(_, root) return lib.AssignImpl.OwnerMenu(lib.assign, root, key) end)
    else
        local set = {}
        for _, name in ipairs(AI.Targets(c, slot, caster)) do set[name] = true end
        c.pending = { key = key, caster = caster, set = set }
        MenuUtil.CreateContextMenu(btn, function(_, root) return lib.AssignImpl.TargetsMenu(lib.assign, root) end)
    end
end

local function Scroll(root)
    if root.SetScrollMode then root:SetScrollMode(20 * 20) end
end

function AI.OwnerMenu(c, root, key)
    local slot = SLOT_BY_KEY[key]
    Scroll(root)
    root:CreateTitle(SlotLabel(slot))
    local function isOwner(data)
        local owner, choice = AI.RecordedOwner(c, slot)
        return owner == data.owner and choice == data.choice
    end
    local function set(data)
        local ok, why = AI.SetOwner(c, slot, data.owner, data.choice)
        if not ok then Say(c, why == "size" and "That name is too long to send." or "Not changed (" .. tostring(why) .. ").") end
    end
    root:CreateRadio("Nobody", isOwner, set, { owner = nil })
    for _, id in ipairs(slot.choices or { slot.needs }) do
        if slot.choices then root:CreateTitle(SpellLabel(id)) end
        for _, name in ipairs(Casters(c, slot.class, id)) do
            root:CreateRadio(name, isOwner, set, { owner = name, choice = slot.choices and id or nil })
        end
    end
end

function AI.TargetsMenu(c, root)
    local p = c.pending
    if not p then return end
    local slot = SLOT_BY_KEY[p.key]
    Scroll(root)
    root:CreateTitle(SlotLabel(slot) .. ": " .. p.caster)
    local names = {}
    for name, member in pairs(c.roster) do
        if member.online ~= nil then names[#names + 1] = name end
    end
    for name in pairs(p.set) do
        if not c.roster[name] then names[#names + 1] = name end
    end
    table.sort(names)
    for _, name in ipairs(names) do
        root:CreateCheckbox(name, function(n) return p.set[n] == true end,
            function(n) p.set[n] = (not p.set[n]) or nil end, name)
    end
    root:CreateDivider()
    root:CreateButton("Apply", function() return lib.AssignImpl.ApplyTargets(lib.assign) end)
    root:CreateButton("Clear", function()
        p.set = {}
        return lib.AssignImpl.ApplyTargets(lib.assign)
    end)
end

-- Checks the roster again: somebody may have left while the menu was open.
function AI.ApplyTargets(c)
    local p = c.pending
    if not p then return end
    local slot = SLOT_BY_KEY[p.key]
    local names = {}
    for name in pairs(p.set) do
        if c.roster[name] then names[#names + 1] = name end
    end
    table.sort(names)
    local ok, why = AI.SetTargets(c, slot, p.caster, names)
    if not ok then
        Say(c, why == "size" and "Too many names to send in one message: remove some." or "Not changed (" .. tostring(why) .. ").")
    end
end

-- Internals for the tests only.
lib._assignTest = { SLOTS = SLOTS, PREFIX = PREFIX, PEER_TTL = PEER_TTL, HELLO_PERIOD = HELLO_PERIOD,
                    MAX_BYTES = MAX_BYTES, DEFAULT_ENV = DEFAULT_ENV, VER_AHEAD = VER_AHEAD,
                    VER_SCALE = VER_SCALE }

end -- Assign

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
-- New does the version check a host used to carry in its own bridge. When it
-- refuses it raises a plain STRING - a table would break a host that joins
-- it with `..`, and the client's own error handler, which formats errors
-- with string.format("%s") (Lua 5.1 ignores __tostring there) - and the
-- reason is asked for separately, from the same rule New used (#54):
--
--     local ok, GB = pcall(lib.New, lib, opts)
--     if not ok then
--         -- Refusal is new in r28, and the active copy may be older (or an r28
--         -- that threw before installing it), so check it, and fall back to GB.
--         local why = type(lib.Refusal) == "function" and lib:Refusal(opts.needs) or nil
--         -- why == nil: not a refusal, or no Refusal to ask - print tostring(GB)
--         -- why.code: "incomplete"        the active copy did not finish loading
--         --           "glass-missing"     LibGlass-1.0 is not loaded at all
--         --           "glass-incomplete"  LibGlass-1.0 did not finish loading
--         --           "glass-too-old"     LibGlass-1.0 is below r6 (r29) and no window exists yet
--         --           "too-old"           the active MINOR is below needs
--         -- why.text (a sentence for players), why.active, why.needs, why.glassMinor
--     end
--
-- Checked in that order. The codes are part of the contract: never renamed
-- or removed, but new ones may be added, so a host treats a code it does not
-- know as a generic failure. Mistakes in the host's own call (a dot call,
-- owner, report, needs, a second New for the same owner) are strings at the
-- caller's line: they are the developer's, not the player's.
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

-- Why New would refuse, or nil if it would not: { code, text, active,
-- needs, glassMinor }, every field filled whenever it is known. New decides
-- with this very function, so a host asking after a refusal gets the reason
-- New had - and asking needs no pcall: it reads markers, it never throws.
-- The texts are for players; a host is free to word each code its own way.
local SEE_WHICH = " - one addon's copy failed. With /console scriptErrors 1 and /reload, "
    .. "the first error names it; updating or disabling that addon should fix this"

function lib:Refusal(needs)
    if self ~= lib then
        error(MAJOR .. ": call Refusal with a colon - lib:Refusal(needs)", 2)
    end
    local _, active = LibStub:GetLibrary(MAJOR, true)
    local glassWhy, glassMinor = GlassState()
    local function Refusal(code, text)
        return { code = code, text = text, active = active, needs = needs, glassMinor = glassMinor }
    end
    if lib.ready ~= active then
        return Refusal("incomplete", MAJOR .. " r" .. tostring(active) .. " did not finish loading"
            .. SEE_WHICH)
    end
    if glassWhy == "glass-missing" then
        return Refusal(glassWhy, "the LibGlass-1.0 library is missing - reinstalling the addon "
            .. "should fix it")
    end
    if glassWhy == "glass-incomplete" then
        return Refusal(glassWhy, "the LibGlass-1.0 library (r" .. tostring(glassMinor)
            .. ") did not finish loading" .. SEE_WHICH)
    end
    local tooOld, floor = GlassTooOld()
    if lib.glass == nil and tooOld then
        return Refusal("glass-too-old", "the LibGlass-1.0 library (r" .. tostring(glassMinor)
            .. ") is too old: this window needs r" .. floor .. " or newer - updating the addons "
            .. "that embed it should fix this")
    end
    if type(needs) == "number" and active < needs then
        -- LibStub runs the NEWEST copy loaded, so an active copy below the
        -- host's floor means the host's own copy is stale or did not register:
        -- its own reinstall is the fix, not other addons'.
        return Refusal("too-old", "this addon needs " .. MAJOR .. " r" .. needs
            .. " or newer, and the newest copy loaded is r" .. tostring(active)
            .. " - reinstalling the addon should fix it")
    end
    return nil
end

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

-- The raid's buff assignments (r37, the Assign section), shared by every host
-- on the client: the first call starts the client's one comms frame through
-- this instance, so a refused event reaches its reporter. One handle per
-- host; a second call returns the same one.
--
--     local assign = GB.Assignments({ onChanged = function() ... end })
--     GB.Engine({ ..., assignments = assign })
--     assign:SpellsChanged()   -- after the engine's RefreshSpells
--     assign:Open()            -- toggles the panel
local function NewAssignments(arg)
    local inst, spec = arg.inst, arg.spec
    if type(spec) ~= "table" then error(MAJOR .. ": Assignments needs a spec table", 0) end
    if spec.onChanged ~= nil and type(spec.onChanged) ~= "function" then
        error(MAJOR .. ": Assignments: onChanged must be a function or nil", 0)
    end
    local c = lib.assign
    for _, h in ipairs(c.subs) do
        if h.owner == inst.owner then return h end
    end
    local h = setmetatable({ owner = inst.owner, report = inst.report, onChanged = spec.onChanged, client = c },
        lib.AssignHandleMeta)
    c.subs[#c.subs + 1] = h
    lib.AssignImpl.Start(c, inst)
    lib.AssignImpl.SpellsChanged(c)
    return h
end

function impl.Assignments(inst, spec)
    return Construct(NewAssignments, { inst = inst, spec = spec })
end

function impl.TimerColor(_, pct) return lib.UI.TimerColor(pct) end
function impl.Pct(_, rem, dur) return lib.UI.Pct(rem, dur) end
function impl.FmtTime(_, s) return lib.UI.FmtTime(s) end

-- The functions an instance carries. A newer copy appends; it never removes.
local FUNCTIONS = { "Engine", "UI", "Settings", "Visibility", "RegisterEvents", "EventFailures",
                    "TimerColor", "Pct", "FmtTime", "Assignments" }

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
    -- The state checks are for players, not developers: no file position, and
    -- lib:Refusal(needs) gives the same reason with a code.
    local why = lib:Refusal(needs)
    if why then error(why.text, 0) end
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
