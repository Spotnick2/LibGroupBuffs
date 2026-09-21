------------------------------------------------------------
-- test_engine_rows.lua - which buffs get a row, what the clicks cast, which
-- members a row covers, and the roster those rows are built from.
--
-- Ported from Priestly's tests/test_availability.lua and test_roster.lua with
-- the same scenarios and expected results, against an engine shaped like
-- Priestly's (H.PriestEngine). What stayed in Priestly: the real Shadow
-- Protection modes (its config) and the rendered row counts (its UI). Added:
-- hosts shaped like Wildly and Magely, which is what the seams are for.
--
--   & 'C:\Program Files (x86)\Lua\5.1\lua.exe' tests\test_engine_rows.lua
------------------------------------------------------------

dofile("tests/wow_stubs.lua")
local H = dofile("tests/harness.lua")
local lib = H.loadLibrary()

local host, E

local function setup(known)
    WoW.reset()
    H.TeachSpells(known)
    host = H.PriestEngine()
    E = host.engine
    E:RefreshSpells()
end

local function ids(defs)
    local out = {}
    for _, d in ipairs(defs) do out[#out + 1] = d.id end
    return table.concat(out, ",")
end

local function names(list)
    local out = {}
    for _, m in ipairs(list or {}) do out[#out + 1] = m.name end
    return table.concat(out, ",")
end

------------------------------------------------------------
-- Construction
------------------------------------------------------------

local function newWith(over)
    local h = { defs = { { id = "x", snglID = 1 } }, bucketSize = 8 }
    for k, v in pairs(over) do h[k] = v end
    return pcall(lib.Engine.New, h)
end
H.check(newWith({}), "a minimal host builds")
H.check(not newWith({ defs = {} }), "no defs is an error")
H.check(not newWith({ defs = { { snglID = 1 } } }), "a def without an id is an error")
H.check(not newWith({ defs = { { id = "x" } } }), "a def without a single-target spell ID is an error")
H.check(not newWith({ defs = { { id = "x", snglID = 1 }, { id = "x", snglID = 2 } } }),
    "two defs with one id is an error - the cache is keyed by it")
H.check(not newWith({ defs = { { id = "x", snglID = 1, grpID = "Prayer" } } }),
    "a group spell given by name instead of ID is an error")
H.check(not newWith({ bucketSize = 0 }), "a bucket size of 0 is an error")
H.check(not newWith({ bucketSize = 2.5 }), "and so is a fractional one")
H.check(not newWith({ membersFor = "tanks" }), "a hook that is not a function is an error")

------------------------------------------------------------
-- A level-20 priest: single-target Fortitude only
------------------------------------------------------------

setup({ "FORT_SINGLE" })
local fort = host.def("fort")
H.check(fort.hasSingle == true, "Power Word: Fortitude is known")
H.check(fort.hasGroup == false, "Prayer of Fortitude is not")
H.eq(ids(E:ActiveDefs({}, {})), "fort", "only the buff that can actually be cast gets a row")

local primary, secondary = E:ClickSpells(fort)
H.eq(primary, "Power Word: Fortitude",
    "left-click falls back to the single-target spell - never a dead primary click")
H.eq(secondary, "Power Word: Fortitude", "right-click is the same spell here")

------------------------------------------------------------
-- Group spell learned: left-click becomes the group spell
------------------------------------------------------------

setup({ "FORT_SINGLE", "FORT_GROUP" })
fort = host.def("fort")
H.check(fort.hasGroup == true, "Prayer of Fortitude is known now")
primary, secondary = E:ClickSpells(fort)
H.eq(primary, "Prayer of Fortitude", "left-click prefers the group spell")
H.eq(secondary, "Power Word: Fortitude", "right-click stays single-target")

------------------------------------------------------------
-- Knowing EITHER form is enough for a row
------------------------------------------------------------

setup({ "FORT_SINGLE", "SPIRIT_SINGLE" })
H.eq(ids(E:ActiveDefs({}, {})), "fort,spirit", "Divine Spirit alone is enough for a Spirit row")
primary = E:ClickSpells(host.def("spirit"))
H.eq(primary, "Divine Spirit", "and it casts the single-target form")

setup({ "FORT_SINGLE", "SPIRIT_GROUP" })
H.eq(ids(E:ActiveDefs({}, {})), "fort,spirit", "Prayer of Spirit alone is also enough")
primary, secondary = E:ClickSpells(host.def("spirit"))
H.eq(primary, "Prayer of Spirit", "left-click casts the group form")
H.eq(secondary, "Prayer of Spirit",
    "right-click falls back to the group form when there is no single-target one")

setup({})
H.eq(ids(E:ActiveDefs({}, {})), "", "knowing none of them means no rows")
primary, secondary = E:ClickSpells(host.def("fort"))
H.check(primary == nil and secondary == nil, "and no spell for either click")

------------------------------------------------------------
-- The addon's toggle and visibility rule layer on top of availability
------------------------------------------------------------

setup({ "FORT_SINGLE", "SPIRIT_SINGLE" })
host.config.enabled.spirit = false
H.eq(ids(E:ActiveDefs({}, {})), "fort", "untracking Spirit removes its row")
host.config.enabled.spirit = nil
host.config.enabled.fort = false
H.eq(ids(E:ActiveDefs({}, {})), "spirit", "untracking Fortitude removes its row too")
host.config.enabled.fort = nil

setup({ "FORT_SINGLE", "SHADOW_SINGLE" })
local groups, ord = { [1] = { { unit = "player", name = "P" } } }, { 1 }
host.visibilityCalls = {}
host.config.visible.shadow = false
H.eq(ids(E:ActiveDefs(groups, ord)), "fort", "the visibility rule can hide a row")
host.config.visible.shadow = nil
H.eq(ids(E:ActiveDefs(groups, ord)), "fort,shadow", "and let it show")
local call = host.visibilityCalls[#host.visibilityCalls]
H.check(call and call.def.id == "shadow" and call.groups == groups and call.ord == ord,
    "the rule is asked about the def, with the roster it is being built for")

-- Availability still wins: no rule conjures a row for an unknown spell.
setup({ "FORT_SINGLE" })
host.visibilityCalls = {}
H.eq(ids(E:ActiveDefs({}, {})), "fort", "a visible-but-unknown spell gets no row")
for _, c in ipairs(host.visibilityCalls) do
    H.check(c.def.id ~= "shadow", "and its rule is not even asked")
end

------------------------------------------------------------
-- Localized names come from the client, not from the literals
------------------------------------------------------------

WoW.reset()
WoW.DefineSpell(1243, "Machtwort: Seelenstaerke")
WoW.Know(1243, "Machtwort: Seelenstaerke")
host = H.PriestEngine()
E = host.engine
local defTable = host.def("fort")
E:RefreshSpells()
H.eq(host.def("fort").sngl, "Machtwort: Seelenstaerke",
    "the name is whatever the client says, not the enUS literal")
H.eq(host.def("fort").names[1], "Machtwort: Seelenstaerke", "and the aura lookup uses that name")
H.check(host.def("fort") == defTable, "the def is updated in place, not replaced")
H.eq(host.def("spirit").sngl, "Divine Spirit", "an unknown spell keeps its fallback name")

------------------------------------------------------------
-- Roster: solo
------------------------------------------------------------

setup({ "FORT_SINGLE" })
WoW.SetUnit("player", { name = "Karuzo Elegia", class = "PRIEST" })
groups, ord = E:GatherGroups()
H.eq(#ord, 0, "ungrouped and solo mode off -> nothing to draw")

host.config.showSolo = true
groups, ord = E:GatherGroups()
H.eq(#ord, 1, "solo mode draws one group")
H.eq(names(groups[1]), "Karuzo Elegia", "which is just the player, surname included")

------------------------------------------------------------
-- Roster: party
------------------------------------------------------------

setup({ "FORT_SINGLE" })
WoW.SetUnit("player", { name = "Karuzo Elegia", class = "PRIEST" })
WoW.SetUnit("party1", { name = "Sten Thornbeard", class = "WARRIOR" })
WoW.SetUnit("party2", { name = "Mirel Dawnsong", class = "MAGE" })
WoW.groupMembers = 3
groups, ord = E:GatherGroups()
H.eq(#ord, 1, "a party is one group")
H.eq(names(groups[1]), "Karuzo Elegia,Sten Thornbeard,Mirel Dawnsong",
    "player first, then party members, all with surnames")
H.eq(groups[1][2].class, "WARRIOR", "classes come along for the icon and colour")

------------------------------------------------------------
-- Roster: raid subgroups, and two characters sharing a first name
------------------------------------------------------------

setup({ "FORT_SINGLE" })
WoW.inRaid = true
WoW.groupMembers = 4
WoW.raidRoster = {
    { name = "Karuzo Elegia",     subgroup = 1 },
    { name = "Karuzo Mistwalker", subgroup = 1 },
    { name = "Sten Thornbeard",   subgroup = 2 },
    { name = "Mirel Dawnsong",    subgroup = 2 },
}
WoW.SetUnit("raid1", { name = "Karuzo Elegia",     guid = "P1", class = "PRIEST" })
WoW.SetUnit("raid2", { name = "Karuzo Mistwalker", guid = "P2", class = "PRIEST" })
WoW.SetUnit("raid3", { name = "Sten Thornbeard",   guid = "P3", class = "WARRIOR" })
WoW.SetUnit("raid4", { name = "Mirel Dawnsong",    guid = "P4", class = "MAGE" })
groups, ord = E:GatherGroups()
H.eq(#ord, 2, "two subgroups")
H.eq(ord[1], 1, "sorted ascending")
H.eq(names(groups[1]), "Karuzo Elegia,Karuzo Mistwalker",
    "both Karuzos are listed, told apart only by surname")
H.eq(names(groups[2]), "Sten Thornbeard,Mirel Dawnsong", "subgroup 2")

------------------------------------------------------------
-- Roster: pets go last, in their own group, and can be turned off
------------------------------------------------------------

setup({ "FORT_SINGLE" })
WoW.SetUnit("player", { name = "Karuzo Elegia", class = "PRIEST" })
WoW.SetUnit("party1", { name = "Sten Thornbeard", class = "HUNTER" })
WoW.SetUnit("partypet1", { name = "Broll" })
WoW.groupMembers = 2
groups, ord = E:GatherGroups()
H.eq(#ord, 2, "a pet adds a group")
H.eq(ord[2], lib.Engine.PET_GROUP, "and it sorts to the bottom")
H.eq(names(groups[lib.Engine.PET_GROUP]), "Broll", "the pet is in it")
H.eq(groups[lib.Engine.PET_GROUP][1].class, "PET_HUNTER", "with an owner-appropriate icon key")

host.config.trackPets = false
groups, ord = E:GatherGroups()
H.eq(#ord, 1, "pet tracking off removes the pet group")

------------------------------------------------------------
-- Roster: a full raid with a pet on everyone
------------------------------------------------------------

setup({ "FORT_SINGLE" })
WoW.inRaid = true
WoW.groupMembers = 40
for i = 1, 40 do
    local nm = "Raider" .. i .. " Sur"
    WoW.raidRoster[i] = { name = nm, subgroup = math.ceil(i / 5) }
    WoW.SetUnit("raid" .. i, { name = nm, guid = "R" .. i, class = "HUNTER" })
    WoW.SetUnit("raidpet" .. i, { name = "Pet" .. i, guid = "PET" .. i })
end
groups, ord = E:GatherGroups()
H.eq(#ord, 13, "8 subgroups plus 5 pet buckets")
local seen, pets = {}, 0
for _, gNum in ipairs(ord) do
    H.check(#groups[gNum] <= 8, "group " .. gNum .. " fits the popover")
    for _, m in ipairs(groups[gNum]) do
        seen[m.unit] = true
        if gNum >= lib.Engine.PET_GROUP then pets = pets + 1 end
    end
end
H.eq(pets, 40, "every pet is in some bucket")
H.eq(ord[9], 99, "the first pet bucket is 99")
H.eq(ord[13], 103, "and the fifth is 103, in order")
local missing = 0
for i = 1, 40 do
    if not seen["raid" .. i] or not seen["raidpet" .. i] then missing = missing + 1 end
end
H.eq(missing, 0, "and no raider or pet is lost")

-- The bucket size is the addon's.
do
    local small = lib.Engine.New({ defs = { { id = "x", snglID = 1243 } }, bucketSize = 3 })
    local g2, o2 = small:GatherGroups()
    H.eq(#o2, 8 + 14, "a 3-row popover means 14 pet buckets")
    H.eq(#g2[99], 3, "each at most 3 long")
end

------------------------------------------------------------
-- A Wildly-shaped host: a buff with no group spell, filtered to tanks
------------------------------------------------------------

local THORNS, MARK, GIFT = 467, 1126, 21849
WoW.reset()
WoW.DefineSpell(THORNS, "Thorns"); WoW.Know(THORNS, "Thorns")
WoW.DefineSpell(MARK, "Mark of the Wild"); WoW.Know(MARK, "Mark of the Wild")
WoW.DefineSpell(GIFT, "Gift of the Wild")
local tanks = { party1 = true }
local druid = lib.Engine.New({
    defs = {
        { id = "mark", snglID = MARK, grpID = GIFT, sngl = "Mark of the Wild",
          grp = "Gift of the Wild", duration = 1800 },
        { id = "thorns", snglID = THORNS, sngl = "Thorns", duration = 600 },
    },
    bucketSize = 8,
    membersFor = function(def, members)
        if def.id ~= "thorns" then return members end
        local out = {}
        for _, m in ipairs(members) do
            if tanks[m.unit] then out[#out + 1] = m end
        end
        return out
    end,
})
druid:RefreshSpells()
local thorns = druid.defs[2]
H.check(thorns.hasSingle and not thorns.hasGroup, "Thorns has no group form")
primary, secondary = druid:ClickSpells(thorns)
H.eq(primary, "Thorns", "a single-only buff casts the single spell on the left")
H.eq(secondary, "Thorns", "and on the right")

WoW.SetUnit("party1", { name = "Sten Thornbeard", guid = "P1", class = "WARRIOR" })
WoW.SetUnit("party2", { name = "Mirel Dawnsong", guid = "P2", class = "MAGE" })
local party = { { unit = "party1", name = "Sten Thornbeard" }, { unit = "party2", name = "Mirel Dawnsong" } }
local rowMembers = druid:MembersFor(thorns, party)
H.eq(names(rowMembers), "Sten Thornbeard", "the row covers only the tank")
H.eq(#party, 2, "and the roster itself is untouched")
H.check(druid:MembersFor(druid.defs[1], party) == party, "an unfiltered buff gets the whole group")
local st = druid:GroupStat(rowMembers, thorns)
H.eq(st.nTotal, 1, "stats count the filtered members")
H.eq(druid:PickTarget(rowMembers, thorns, thorns.hasGroup, st), "party1",
    "and the target comes from them, picked as a single target since there is no group spell")
tanks.party1 = nil
H.eq(#druid:MembersFor(thorns, party), 0, "no tank means no members - the addon skips the row")

-- An engine without a filter returns the very same list.
H.check(E:MembersFor(host.def("fort"), party) == party, "no filter, no copy")
local bad = lib.Engine.New({ defs = { { id = "x", snglID = 1 } }, bucketSize = 8,
    membersFor = function() return nil end })
H.check(not pcall(bad.MembersFor, bad, bad.defs[1], party),
    "a filter that returns nothing is an error, not a silently empty row")

------------------------------------------------------------
-- A Magely-shaped host: two optional single-only buffs, both allowed
------------------------------------------------------------

local AMPLIFY, DAMPEN, INTELLECT = 1008, 604, 1459
WoW.reset()
for id, nm in pairs({ [AMPLIFY] = "Amplify Magic", [DAMPEN] = "Dampen Magic",
                      [INTELLECT] = "Arcane Intellect" }) do
    WoW.DefineSpell(id, nm); WoW.Know(id, nm)
end
local modes = { amplify = true, dampen = true }
local mage = lib.Engine.New({
    defs = {
        { id = "intellect", snglID = INTELLECT, sngl = "Arcane Intellect", duration = 1800 },
        { id = "amplify", snglID = AMPLIFY, sngl = "Amplify Magic", duration = 600 },
        { id = "dampen", snglID = DAMPEN, sngl = "Dampen Magic", duration = 600 },
    },
    bucketSize = 8,
    isVisible = function(def) return modes[def.id] ~= false end,
})
mage:RefreshSpells()
H.eq(ids(mage:ActiveDefs({}, {})), "intellect,amplify,dampen",
    "both optional buffs can have rows at once - the rule is not shadow-specific")
modes.dampen = false
H.eq(ids(mage:ActiveDefs({}, {})), "intellect,amplify", "and each is hidden on its own")

------------------------------------------------------------
-- Two addons on one library: nothing shared but the code
------------------------------------------------------------

setup({ "FORT_SINGLE" })
local priest = host.engine
local other = lib.Engine.New({
    defs = { { id = "fort", snglID = MARK, sngl = "Mark of the Wild", duration = 1800 } },
    bucketSize = 8,
})
WoW.DefineSpell(MARK, "Mark of the Wild"); WoW.Know(MARK, "Mark of the Wild")
other:RefreshSpells()
WoW.SetUnit("party1", { name = "A One", guid = "P1" })
WoW.SetAura("party1", "Power Word: Fortitude", 3600, 1800)
priest:BuffRem("party1", host.def("fort"))
H.check(priest.cache.P1 and priest.cache.P1.fort, "the priest engine cached its fort")
H.check(other.cache.P1 == nil, "the other engine's cache is untouched, though its def id is also fort")
H.secrecy(true)
H.eq(select(3, other:BuffRem("party1", other.defs[1])), lib.Engine.STATES.UNKNOWN,
    "so under secrecy it does not read the priest's Fortitude as its own buff")
H.secrecy(false)
H.check(getmetatable(priest) == getmetatable(other), "both run the one shared set of methods")

H.done("test_engine_rows")
