------------------------------------------------------------
-- test_assign.lua - raid buff assignments (r37, the Assign section).
--
-- Most of this runs several clients side by side on a simulated group
-- channel that delays, reorders, drops and throttles messages the way the
-- measured client does: about 10 then 1 a second, a refused send is lost,
-- and the sender hears its own messages back. Each client is the library's
-- own state machine with its own clock, roster and spellbook (`env`).
-- The end of the file drives the live client through real events, the
-- engine seam, the panel and its menus.
--
--   & 'C:\Program Files (x86)\Lua\5.1\lua.exe' tests\test_assign.lua
------------------------------------------------------------

dofile("tests/wow_stubs.lua")
local H = dofile("tests/harness.lua")
H.loadLibrary()
local lib = LibStub("LibGroupBuffs-1.0")
local AI, T = lib.AssignImpl, lib._assignTest

local SLOT = {}
for _, s in ipairs(T.SLOTS) do SLOT[s.key] = s end
local FORT, SPIRIT, MAGIC, THORNS, FEAR, GIFT = SLOT[1243], SLOT[14752], SLOT[1008], SLOT[467], SLOT[6346], SLOT[1126]

-- What each class can cast in these tests.
local PRIEST = { [21562] = true, [27681] = true, [27683] = true, [6346] = true }
local PRIEST_LOW = { [6346] = true }                 -- no Prayers yet
local DRUID = { [21849] = true, [467] = true }
local MAGE = { [23028] = true, [1008] = true, [604] = true }

------------------------------------------------------------
-- The simulated group
------------------------------------------------------------

local function Sim(opts)
    opts = opts or {}
    local sim = { t = 0, server = 1800000000, timers = {}, seq = 0, members = {}, order = {},
                  sent = 0, sentA = 0, lockdown = false, seed = opts.seed or 1 }
    function sim.rand()
        sim.seed = (sim.seed * 1103515245 + 12345) % 2147483648
        return sim.seed / 2147483648
    end
    function sim:at(delay, fn)
        self.seq = self.seq + 1
        self.timers[#self.timers + 1] = { at = self.t + delay, seq = self.seq, fn = fn }
    end
    -- Runs everything due within `seconds`, in time order.
    function sim:run(seconds)
        local stop = self.t + seconds
        while true do
            table.sort(self.timers, function(a, b)
                if a.at ~= b.at then return a.at < b.at end
                return a.seq < b.seq
            end)
            local nxt = self.timers[1]
            if not nxt or nxt.at > stop then break end
            table.remove(self.timers, 1)
            self.t = math.max(self.t, nxt.at)
            nxt.fn()
        end
        self.t = stop
    end
    function sim:roster()
        local out = {}
        for _, name in ipairs(self.order) do
            local m = self.members[name]
            if m.inGroup then out[name] = { unit = m.unit, class = m.class, online = m.online } end
        end
        return out
    end
    -- One message to everyone in the group, the sender included, each after
    -- its own delay (so messages can overtake each other), unless dropped.
    function sim:broadcast(from, msg, channel)
        local who = self.members[from]
        -- The measured throttle: about 10 at once, then 1 a second; a refused
        -- send is lost (result 3).
        local now = self.t
        who.tokens = math.min(10, (who.tokens or 10) + (now - (who.refilled or now)))
        who.refilled = now
        if who.tokens < 1 then return 3 end
        who.tokens = who.tokens - 1
        self.sent = self.sent + 1
        if msg:find("^1%^A") then self.sentA = self.sentA + 1 end
        for _, name in ipairs(self.order) do
            local m = self.members[name]
            if m.inGroup and m.client and not (self.drop and self.drop(from, name, msg)) then
                local delay = 0.1 + self.rand() * (opts.jitter or 0.4)
                self:at(delay, function()
                    if m.inGroup and m.client then AI.Receive(m.client, msg, channel, from) end
                end)
            end
        end
        return 0
    end
    return sim
end

local unitN = 0
local function Member(sim, name, class, spells, opts)
    opts = opts or {}
    unitN = unitN + 1
    local m = { name = name, class = class, spells = spells, unit = "raid" .. unitN, online = true,
                inGroup = opts.inGroup ~= false, combat = false }
    sim.members[name] = m
    sim.order[#sim.order + 1] = name
    -- A boot is a fresh client, as after a /reload: the previous one stops
    -- sending and its timers die with it.
    function m:boot()
        if m.kill then m.kill() end
        local alive = true
        m.kill = function() alive = false; m.client = nil end
        local env = {
            now = function() return sim.t end,
            serverNow = function() return sim.server + math.floor(sim.t) end,
            send = function(msg, channel)
                if not alive then return 0 end
                return sim:broadcast(m.name, msg, channel)
            end,
            lockdown = function() return sim.lockdown end,
            combat = function() return m.combat end,
            after = function(delay, fn) sim:at(delay, function() if alive then fn() end end) end,
            random = function() return sim.rand() end,
            category = function() return m.inGroup and (m.category or 1) or nil end,
            channel = function() return "RAID" end,
            roster = function() return sim:roster(), m.name end,
            knows = function(id) return m.spells[id] == true end,
            myClass = function() return m.class end,
        }
        m.client = AI.NewClient(env)
        m.changes = 0
        m.client.subs[1] = { onChanged = function() m.changes = m.changes + 1 end,
                             report = function(text) m.reported = text end }
        AI.SpellsChanged(m.client)
        AI.RosterChanged(m.client)
        return m.client
    end
    if opts.boot ~= false then m:boot() end
    return m
end

-- Everyone's roster view follows the group.
local function RosterAll(sim)
    for _, name in ipairs(sim.order) do
        local m = sim.members[name]
        if m.client then AI.RosterChanged(m.client) end
    end
end

local function Digests(sim)
    local seen, first, same = {}, nil, true
    for _, name in ipairs(sim.order) do
        local m = sim.members[name]
        if m.inGroup and m.client then
            local d = AI.Digest(m.client.records)
            seen[#seen + 1] = name .. "=" .. d
            first = first or d
            if d ~= first then same = false end
        end
    end
    return same, table.concat(seen, " ")
end

local function OwnerSeenBy(m, slot)
    return (AI.Owner(m.client, slot))
end

------------------------------------------------------------
-- The slot table is protocol data, the same for every host
------------------------------------------------------------

H.eq(#T.SLOTS, 8, "eight slots in protocol v1")
H.eq(T.PREFIX, "LibGroupBuffs", "the prefix")
H.check(#T.PREFIX <= 16, "fits the client's prefix length")
H.eq(MAGIC.choices[1] .. "," .. MAGIC.choices[2], "1008,604", "Amplify and Dampen share one slot")
H.eq(FORT.needs, 21562, "an owner of Fortitude needs Prayer of Fortitude, the group form")

------------------------------------------------------------
-- Records: the order is total, so every client keeps the same winner
------------------------------------------------------------

do
    local a = { ver = 10, writer = "Alia Dawn", value = "X" }
    local b = { ver = 11, writer = "Alia Dawn", value = "X" }
    H.check(AI.Newer(b, a) and not AI.Newer(a, b), "a higher version wins")
    local c = { ver = 10, writer = "Bren Holt", value = "X" }
    H.check(AI.Newer(c, a) and not AI.Newer(a, c), "the writer breaks a tie")
    local d = { ver = 10, writer = "Alia Dawn", value = "Y" }
    H.check(AI.Newer(d, a) and not AI.Newer(a, d), "and the value breaks a tie of version and writer")
    H.check(not AI.Newer(a, { ver = 10, writer = "Alia Dawn", value = "X" }), "an equal record is not newer")
    H.eq(AI.Digest({}), "0", "no records digest to 0")
    local r1 = { ["1243"] = a, ["976"] = c }
    local r2 = { ["976"] = c, ["1243"] = a }
    H.eq(AI.Digest(r1), AI.Digest(r2), "the digest does not depend on insertion order")
    H.check(AI.Digest(r1) ~= AI.Digest({ ["1243"] = d, ["976"] = c }), "and covers the value")
end

------------------------------------------------------------
-- An assignment reaches everyone, and every client agrees who owns it
------------------------------------------------------------

do
    local sim = Sim()
    local alia = Member(sim, "Alia Dawn", "PRIEST", PRIEST)
    local bren = Member(sim, "Bren Holt", "PRIEST", PRIEST)
    local cora = Member(sim, "Cora Leaf", "DRUID", DRUID)
    RosterAll(sim)
    sim:run(5)
    H.check(alia.client.peers["Bren Holt"] ~= nil and bren.client.peers["Alia Dawn"] ~= nil,
        "peers find each other by hello")
    H.check(cora.client.peers["Alia Dawn"].spells[21562], "and learn what each can cast")

    local ok = AI.SetOwner(cora.client, FORT, "Bren Holt")   -- anyone may assign anyone
    H.check(ok, "a druid can assign a priest's slot")
    sim:run(2)
    for _, m in ipairs({ alia, bren, cora }) do
        H.eq(OwnerSeenBy(m, FORT), "Bren Holt", m.name .. " sees Bren on Fortitude")
    end
    H.check((Digests(sim)), "every digest agrees")
    H.check(bren.changes > 0 and alia.changes > 0, "the hosts were told")

    -- Last write wins: Alia takes it over a second later.
    sim:run(1)
    AI.SetOwner(alia.client, FORT, "Alia Dawn")
    sim:run(2)
    for _, m in ipairs({ alia, bren, cora }) do
        H.eq(OwnerSeenBy(m, FORT), "Alia Dawn", m.name .. " sees the later write")
    end

    -- Clearing is a record too.
    sim:run(1)
    AI.SetOwner(bren.client, FORT, nil)
    sim:run(2)
    H.eq(OwnerSeenBy(cora, FORT), nil, "a clear reaches everyone")
    H.eq(cora.client.records["1243"].value, "", "and is kept as a record")

    -- A stale replay of the old assignment cannot bring it back.
    local stale = AI.EncodeRecord("1243", { ver = (sim.server + 1) * T.VER_SCALE, writer = "Cora Leaf", value = "Bren Holt" })
    AI.Receive(alia.client, stale, "RAID", "Bren Holt")
    H.eq(OwnerSeenBy(alia, FORT), nil, "a stale record loses to the newer clear")
end

------------------------------------------------------------
-- Any order of arrival gives the same state
------------------------------------------------------------

do
    for seed = 1, 6 do
        local sim = Sim({ seed = seed, jitter = 2 })
        local a = Member(sim, "Alia Dawn", "PRIEST", PRIEST)
        local b = Member(sim, "Bren Holt", "PRIEST", PRIEST)
        local c = Member(sim, "Cora Leaf", "DRUID", DRUID)
        RosterAll(sim)
        sim:run(5)
        -- Concurrent edits of the same slot in the same second, by three writers.
        AI.SetOwner(a.client, FORT, "Alia Dawn")
        AI.SetOwner(b.client, FORT, "Bren Holt")
        AI.SetOwner(c.client, FORT, "Bren Holt")
        AI.SetOwner(a.client, SPIRIT, "Bren Holt")
        AI.SetTargets(c.client, THORNS, "Cora Leaf", { "Alia Dawn" })
        sim:run(10)
        local same, which = Digests(sim)
        H.check(same, "seed " .. seed .. ": concurrent edits converge (" .. which .. ")")
        H.eq(OwnerSeenBy(a, FORT), OwnerSeenBy(c, FORT), "seed " .. seed .. ": one owner everywhere")
    end
end

------------------------------------------------------------
-- A joiner in a populated raid is answered about once
------------------------------------------------------------

do
    local sim = Sim({ seed = 7 })
    local members = {}
    for i = 1, 39 do
        local class = (i % 3 == 0 and "MAGE") or (i % 3 == 1 and "PRIEST") or "DRUID"
        local spells = (class == "MAGE" and MAGE) or (class == "PRIEST" and PRIEST) or DRUID
        members[i] = Member(sim, "Member" .. string.char(64 + (i % 26) + 1) .. i, class, spells)
    end
    RosterAll(sim)
    sim:run(10)
    AI.SetOwner(members[1].client, FORT, members[1].name)
    AI.SetOwner(members[2].client, GIFT, members[2].name)
    AI.SetOwner(members[3].client, MAGIC, members[3].name, 604)
    AI.SetTargets(members[2].client, THORNS, members[2].name, { members[1].name, members[4].name })
    sim:run(10)
    H.check((Digests(sim)), "39 clients agree before the join")

    local before = sim.sentA
    local joiner = Member(sim, "Zed Late", "PRIEST", PRIEST)
    RosterAll(sim)
    sim:run(70)
    local same = Digests(sim)
    H.check(same, "the joiner converges")
    H.eq(OwnerSeenBy(joiner, MAGIC), members[3].name, "and sees the Magic owner")
    local _, choice = AI.Owner(joiner.client, MAGIC)
    H.eq(choice, 604, "with the chosen spell")
    local repairs = sim.sentA - before
    H.check(repairs >= 4, "the four records were sent (" .. repairs .. ")")
    H.check(repairs <= 4 * 6, "by a handful of peers, not 39 (" .. repairs .. " record messages)")
end

------------------------------------------------------------
-- A record only one peer holds still spreads, and a missed edit is repaired
------------------------------------------------------------

do
    local sim = Sim({ seed = 3 })
    local a = Member(sim, "Alia Dawn", "PRIEST", PRIEST)
    local b = Member(sim, "Bren Holt", "PRIEST", PRIEST)
    local c = Member(sim, "Cora Leaf", "DRUID", DRUID)
    local d = Member(sim, "Dax Moss", "MAGE", MAGE)
    RosterAll(sim)
    sim:run(5)
    -- Dax's edit reaches nobody (every copy dropped).
    sim.drop = function(from) return from == "Dax Moss" end
    AI.SetOwner(d.client, MAGIC, "Dax Moss", 1008)
    sim:run(2)
    sim.drop = nil
    H.eq(OwnerSeenBy(a, MAGIC), nil, "nobody heard the dropped edit")
    sim:run(T.HELLO_PERIOD + 20)
    H.eq(OwnerSeenBy(a, MAGIC), "Dax Moss", "the record only Dax held reached Alia")
    H.eq(OwnerSeenBy(c, MAGIC), "Dax Moss", "and Cora")
    H.check((Digests(sim)), "and everyone agrees")

    -- An edit one synced client missed is repaired by the next hellos.
    sim.drop = function(from, to) return to == "Cora Leaf" end
    AI.SetOwner(a.client, SPIRIT, "Bren Holt")
    sim:run(2)
    sim.drop = nil
    H.eq(OwnerSeenBy(c, SPIRIT), nil, "Cora missed it")
    sim:run(T.HELLO_PERIOD + 20)
    H.eq(OwnerSeenBy(c, SPIRIT), "Bren Holt", "and has it after a hello round")
end

------------------------------------------------------------
-- A /reload: the new client starts empty and its edit still wins
------------------------------------------------------------

do
    local sim = Sim({ seed = 5 })
    local a = Member(sim, "Alia Dawn", "PRIEST", PRIEST)
    local b = Member(sim, "Bren Holt", "PRIEST", PRIEST)
    local c = Member(sim, "Cora Leaf", "DRUID", DRUID)
    RosterAll(sim)
    sim:run(5)
    AI.SetOwner(b.client, FORT, "Alia Dawn")
    sim:run(3)
    -- Bren reloads: a fresh client, nothing remembered.
    b:boot()
    H.eq(next(b.client.records), nil, "after a reload the client remembers nothing")
    sim:run(1)
    AI.SetOwner(b.client, FORT, "Bren Holt")
    sim:run(15)
    for _, m in ipairs({ a, b, c }) do
        H.eq(OwnerSeenBy(m, FORT), "Bren Holt", m.name .. ": the post-reload edit wins")
    end
    H.check((Digests(sim)), "and everyone agrees")

    -- A burst of four edits in one second stays inside that second's
    -- versions, so an edit after a reload (which takes at least a second of
    -- loading screen) beats all of it, from whichever peer it comes back
    -- (#93 reviews).
    sim:run(5)
    local second = sim.server + math.floor(sim.t)
    for _, owner in ipairs({ "Alia Dawn", "Bren Holt", "Alia Dawn", "Bren Holt" }) do
        AI.SetOwner(b.client, SPIRIT, owner)
    end
    local top = b.client.records["14752"].ver
    H.check(top < (second + 1) * T.VER_SCALE, "a burst keeps its versions inside its second")
    sim:run(0.5)
    -- A peer holds a different, also-higher record of the same second.
    AI.Receive(c.client, AI.EncodeRecord("14752", { ver = top + 1, writer = "Cora Leaf", value = "Cora Leaf" }),
        "RAID", "Cora Leaf")
    sim:run(1)
    b:boot()
    AI.SetOwner(b.client, SPIRIT, "Alia Dawn")
    H.check(b.client.records["14752"].ver > top + 1, "the reloaded edit's version is above all of them")
    sim:run(T.HELLO_PERIOD + 20)
    H.check((Digests(sim)), "the clients converge")
    for _, m in ipairs({ a, b, c }) do
        H.eq(OwnerSeenBy(m, SPIRIT), "Alia Dawn", m.name .. ": on the edit made after the reload")
    end

    -- Somebody who saw that edit and changes the slot again wins, even if the
    -- reloaded client has not caught up with the group yet.
    sim:run(2)
    b:boot()
    sim:run(1.5)
    AI.SetOwner(b.client, SPIRIT, "Bren Holt")
    sim:run(1)
    H.eq(OwnerSeenBy(a, SPIRIT), "Bren Holt", "Alia has the reloaded client's edit")
    AI.SetOwner(a.client, SPIRIT, "Alia Dawn")
    sim:run(T.HELLO_PERIOD + 20)
    for _, m in ipairs({ a, b, c }) do
        H.eq(OwnerSeenBy(m, SPIRIT), "Alia Dawn", m.name .. ": the later edit stands")
    end

    -- The same version and writer with different values: one winner everywhere.
    local x = AI.EncodeRecord("976", { ver = (sim.server + 999) * T.VER_SCALE, writer = "Alia Dawn", value = "Alia Dawn" })
    local y = AI.EncodeRecord("976", { ver = (sim.server + 999) * T.VER_SCALE, writer = "Alia Dawn", value = "Bren Holt" })
    AI.Receive(a.client, x, "RAID", "Cora Leaf"); AI.Receive(a.client, y, "RAID", "Cora Leaf")
    AI.Receive(c.client, y, "RAID", "Bren Holt"); AI.Receive(c.client, x, "RAID", "Bren Holt")
    H.eq(a.client.records["976"].value, c.client.records["976"].value, "equal version and writer: same winner either order")
end

------------------------------------------------------------
-- Owners count only while live
------------------------------------------------------------

do
    local sim = Sim()
    local a = Member(sim, "Alia Dawn", "PRIEST", PRIEST)
    local b = Member(sim, "Bren Holt", "PRIEST", PRIEST)
    local low = Member(sim, "Lowe Level", "PRIEST", PRIEST_LOW)
    RosterAll(sim)
    sim:run(5)
    AI.SetOwner(a.client, FORT, "Bren Holt")
    sim:run(2)
    H.eq(OwnerSeenBy(a, FORT), "Bren Holt", "Bren owns Fortitude")

    -- Bren leaves the group: unowned for Alia, the record kept.
    b.inGroup = false
    RosterAll(sim)
    H.eq(OwnerSeenBy(a, FORT), nil, "an owner who left does not count")
    H.eq(a.client.records["1243"].value, "Bren Holt", "but the record stays")
    b.inGroup = true
    b:boot()
    RosterAll(sim)
    sim:run(5)
    H.eq(OwnerSeenBy(a, FORT), "Bren Holt", "and counts again when they are back and heard from")

    -- Offline.
    b.online = false
    RosterAll(sim)
    H.eq(OwnerSeenBy(a, FORT), nil, "an offline owner does not count")
    b.online = true
    RosterAll(sim)
    H.eq(OwnerSeenBy(a, FORT), "Bren Holt", "nor does one who comes back online before their next hello stop counting")

    -- Their addon stops (a reload with it disabled): no hellos, so they expire.
    b.kill()
    sim:run(T.PEER_TTL + T.HELLO_PERIOD + 15)
    H.eq(OwnerSeenBy(a, FORT), nil, "an owner who has gone quiet expires")
    H.check(a.client.peers["Bren Holt"] == nil, "and is no longer a peer")

    -- Only someone who can cast the group form can own it.
    AI.SetOwner(a.client, FORT, "Lowe Level")
    sim:run(2)
    H.eq(OwnerSeenBy(a, FORT), nil, "a priest without Prayer of Fortitude does not own it")
    H.check(#AI.Casters(a.client, "PRIEST", 21562) == 1, "and is not offered as a caster")

    -- While chat is locked down, nobody expires.
    b:boot()
    RosterAll(sim)
    sim:run(5)
    AI.SetOwner(a.client, FORT, "Bren Holt")
    sim:run(2)
    b.kill()
    sim.lockdown = true
    AI.LockClock(a.client)    -- ADDON_RESTRICTION_STATE_CHANGED
    sim:run(T.PEER_TTL + T.HELLO_PERIOD + 15)
    H.eq(OwnerSeenBy(a, FORT), "Bren Holt", "a lockdown does not count down a peer")
    sim.lockdown = false
    AI.LockClock(a.client)
    H.eq(OwnerSeenBy(a, FORT), "Bren Holt", "nor does a long one expire them at unlock (#93 review)")
    sim:run(T.PEER_TTL - 10)
    H.eq(OwnerSeenBy(a, FORT), "Bren Holt", "their age resumes where it stood")
    sim:run(T.HELLO_PERIOD + 15)
    H.eq(OwnerSeenBy(a, FORT), nil, "and a quiet owner still expires after unlock")
end

------------------------------------------------------------
-- State belongs to the selected group
------------------------------------------------------------

do
    local sim = Sim()
    local a = Member(sim, "Alia Dawn", "PRIEST", PRIEST)
    local b = Member(sim, "Bren Holt", "PRIEST", PRIEST)
    RosterAll(sim)
    sim:run(5)
    AI.SetOwner(a.client, FORT, "Bren Holt")
    sim:run(2)
    H.check(a.client.records["1243"] ~= nil, "Alia has a record")
    -- From the home raid to an instance group, never solo in between.
    a.category = 2
    AI.RosterChanged(a.client)
    H.eq(next(a.client.records), nil, "a change of selected group wipes the records")
    H.eq(next(a.client.peers), nil, "and the peers")
    a.category = 1
    AI.RosterChanged(a.client)
    -- Leaving the group altogether.
    a.inGroup = false
    AI.RosterChanged(a.client)
    H.eq(a.client.group, nil, "no group")
    H.eq(next(a.client.queue), nil, "and an empty queue")
    H.check(not AI.SetOwner(a.client, FORT, "Alia Dawn"), "and no edits")
end

------------------------------------------------------------
-- What is accepted from the channel
------------------------------------------------------------

do
    local sim = Sim()
    local a = Member(sim, "Alia Dawn", "PRIEST", PRIEST)
    local b = Member(sim, "Bren Holt", "PRIEST", PRIEST)
    RosterAll(sim)
    sim:run(5)
    local rec = AI.EncodeRecord("1243", { ver = (sim.server + 50) * T.VER_SCALE, writer = "Bren Holt", value = "Bren Holt" })
    AI.Receive(a.client, rec, "RAID", "Somebody Else")
    H.eq(a.client.records["1243"], nil, "a sender outside the group is ignored")
    AI.Receive(a.client, rec, "PARTY", "Bren Holt")
    H.eq(a.client.records["1243"], nil, "and so is the wrong channel")
    AI.Receive(a.client, rec, "RAID", "Alia Dawn")
    H.eq(a.client.records["1243"], nil, "and our own echo")
    AI.Receive(a.client, "2^A^1243^1^X^Y", "RAID", "Bren Holt")
    H.eq(a.client.otherVersions["Bren Holt"], "2", "another protocol version is counted, not read")
    AI.Receive(a.client, "1^A^9999^1^Bren Holt^Bren Holt", "RAID", "Bren Holt")
    H.eq(a.client.records["9999"], nil, "an unknown slot is refused")
    AI.Receive(a.client, "1^A^1008^1^Bren Holt^Bren Holt,999", "RAID", "Bren Holt")
    H.eq(a.client.records["1008"], nil, "a Magic value with a spell that is not a choice is refused")
    AI.Receive(a.client, "1^A^467^1^Bren Holt^Alia Dawn", "RAID", "Bren Holt")
    H.eq(a.client.records["467"], nil, "a target list needs its caster in the key")
    AI.Receive(a.client, "1^H^MAGE^1008^0", "RAID", "Bren Holt")
    H.check(not a.client.peers["Bren Holt"].spells[1008], "a hello naming the wrong class is ignored")
    -- Versions: plain decimal integers, at most a day past the server clock,
    -- so any accepted record can be beaten by the next edit (#93 review).
    for _, bad in ipairs({ "1e9", "0x10", "-5", "1.5", "0123", " 99", "99999999999999999999",
                           tostring((sim.server + T.VER_AHEAD + 10) * T.VER_SCALE) }) do
        AI.Receive(a.client, "1^A^1243^" .. bad .. "^Bren Holt^Bren Holt", "RAID", "Bren Holt")
        H.eq(a.client.records["1243"], nil, "version " .. bad .. " is refused")
    end
    AI.Receive(a.client, rec, "RAID", "Bren Holt")
    H.eq(a.client.records["1243"].value, "Bren Holt", "a good record from a member is kept")
    local edge = AI.EncodeRecord("1243", { ver = (sim.server + math.floor(sim.t) + T.VER_AHEAD) * T.VER_SCALE, writer = "Bren Holt",
                                           value = "Bren Holt" })
    AI.Receive(a.client, edge, "RAID", "Bren Holt")
    H.check(a.client.records["1243"].ver == (sim.server + math.floor(sim.t) + T.VER_AHEAD) * T.VER_SCALE, "the furthest version is kept")
    local ok, why = AI.SetOwner(a.client, FORT, "Alia Dawn")
    H.check(not ok and why == "version", "an edit that would pass the limit waits")
    sim:run(1)
    local furthest = a.client.records["1243"].ver
    H.check(AI.SetOwner(a.client, FORT, "Alia Dawn"), "and goes through a second later, on top")
    H.eq(a.client.records["1243"].ver, furthest + 1, "one step above it")
    AI.Receive(a.client, nil, "RAID", "Bren Holt")
    AI.Receive(a.client, string.rep("x", 300), "RAID", "Bren Holt")
    H.check(true, "a nil or oversized payload is dropped quietly")
end

------------------------------------------------------------
-- Size: a message that would be cut is refused before it is applied
------------------------------------------------------------

do
    local sim = Sim()
    local c = Member(sim, "Cora Leaf", "DRUID", DRUID)
    local names = {}
    for i = 1, 14 do names[i] = "Longname" .. i .. " Surnamelongish" end
    local ok, why = AI.SetTargets(c.client, THORNS, "Cora Leaf", names)
    H.check(not ok and why == "size", "a target list that does not fit 255 bytes is refused")
    H.eq(c.client.records["467:Cora Leaf"], nil, "and not applied locally")
    ok = AI.SetTargets(c.client, THORNS, "Cora Leaf", { names[1], names[2], names[3], names[4] })
    H.check(ok, "four long names fit")
    local msg = AI.EncodeRecord("467:Cora Leaf", c.client.records["467:Cora Leaf"])
    H.check(#msg <= T.MAX_BYTES, "and the encoded message is within the cap (" .. #msg .. ")")
    -- UTF-8 counts in bytes.
    local accented = "\195\137lise \195\128ubert"
    ok = AI.SetOwner(c.client, GIFT, accented)
    H.check(ok, "a UTF-8 name is accepted")
    H.eq(c.client.records["1126"].value, accented, "and kept byte for byte")
end

------------------------------------------------------------
-- The send queue
------------------------------------------------------------

do
    local sent, results = {}, {}
    local t, timers = 0, {}
    local lock = false
    local env = {
        now = function() return t end,
        serverNow = function() return 1800000000 + math.floor(t) end,
        send = function(msg) sent[#sent + 1] = msg; return table.remove(results, 1) or 0 end,
        lockdown = function() return lock end,
        combat = function() return false end,
        after = function(d, fn) timers[#timers + 1] = { at = t + d, fn = fn } end,
        random = function() return 0.5 end,
        category = function() return 1 end,
        channel = function() return "RAID" end,
        roster = function() return { ["Alia Dawn"] = { unit = "raid1", class = "PRIEST", online = true } }, "Alia Dawn" end,
        knows = function(id) return PRIEST[id] == true end,
        myClass = function() return "PRIEST" end,
    }
    local function run(seconds)
        local stop = t + seconds
        while true do
            table.sort(timers, function(a, b) return a.at < b.at end)
            local nxt = timers[1]
            if not nxt or nxt.at > stop then break end
            table.remove(timers, 1)
            t = math.max(t, nxt.at)
            nxt.fn()
        end
        t = stop
    end
    local c = AI.NewClient(env)
    c.subs[1] = { report = function(text) c.lastReport = text end }
    AI.SpellsChanged(c)
    AI.RosterChanged(c)
    run(5)
    local hellos = #sent
    H.check(hellos >= 1, "a hello went out on joining")
    H.check(sent[1]:find("^1%^H%^PRIEST%^") ~= nil, "naming the class (" .. tostring(sent[1]) .. ")")

    -- Coalescing: three edits of one slot before the pump runs send one message.
    sent = {}
    t = t + 0.001
    c.tokens = 0                                   -- the bucket is empty
    AI.SetOwner(c, FORT, "Alia Dawn")
    AI.SetOwner(c, FORT, nil)
    AI.SetOwner(c, FORT, "Alia Dawn")
    run(3)
    local fort = 0
    for _, m in ipairs(sent) do if m:find("^1%^A%^1243%^") then fort = fort + 1 end end
    H.eq(fort, 1, "three edits of one slot while throttled send once")
    H.check(sent[1]:find("Alia Dawn$") ~= nil, "the newest")

    -- A throttled send (3) is kept and retried; a not-in-group (5) is dropped.
    sent = {}
    results = { 3 }
    AI.SetOwner(c, SPIRIT, "Alia Dawn")
    run(0.1)
    H.eq(#sent, 1, "the first try was refused")
    H.check(AI.Pending(c, "14752"), "and is still pending")
    run(5)
    H.eq(#sent, 2, "and was tried again")
    H.check(not AI.Pending(c, "14752"), "and is sent")
    sent = {}
    results = { 5 }
    AI.SetOwner(c, SPIRIT, nil)
    run(5)
    H.eq(#sent, 1, "a not-in-group answer is not retried")
    results = { 9 }
    AI.SetOwner(c, SPIRIT, "Alia Dawn")
    run(5)
    H.check(c.lastReport ~= nil, "another failure is reported to the host once")

    -- Lockdown: nothing goes out until it lifts.
    sent = {}
    lock = true
    AI.SetOwner(c, SPIRIT, nil)
    run(10)
    H.eq(#sent, 0, "nothing is sent while chat is locked down")
    lock = false
    run(5)
    H.eq(#sent, 1, "and it goes once the lockdown lifts")

    -- Edits go before hellos and repairs.
    sent = {}
    c.tokens = 0
    AI.SendHello(c)
    AI.SetOwner(c, FORT, nil)
    run(1.01)
    H.check(sent[1] and sent[1]:find("^1%^A%^1243") ~= nil, "an edit goes before a queued hello")

    -- Combat: refused, the panel is read-only.
    env.combat = function() return true end
    local ok, why = AI.SetOwner(c, FORT, "Alia Dawn")
    H.check(not ok and why == "combat", "edits are refused in combat")
end

------------------------------------------------------------
-- The handle: what a host's window does with each def
------------------------------------------------------------

do
    local sim = Sim()
    local a = Member(sim, "Alia Dawn", "PRIEST", PRIEST)
    local b = Member(sim, "Bren Holt", "PRIEST", PRIEST)
    local m1 = Member(sim, "Mira Frost", "MAGE", MAGE)
    local m2 = Member(sim, "Nils Frost", "MAGE", MAGE)
    local cora = Member(sim, "Cora Leaf", "DRUID", DRUID)
    RosterAll(sim)
    sim:run(5)
    local function handle(m) return setmetatable({ client = m.client }, lib.AssignHandleMeta) end
    local fortDef = { id = "fort", snglID = 1243, assign = "owner" }
    local plainDef = { id = "fort", snglID = 1243 }
    local ampDef = { id = "amplify", snglID = 1008, assign = "owner" }
    local dampDef = { id = "dampen", snglID = 604, assign = "owner", assignSlot = 1008 }
    local thornsDef = { id = "thorns", snglID = 467, assign = "targets" }
    local fearDef = { id = "fearward", snglID = 6346, assign = "targets", assignOnly = true }

    H.eq(handle(a):RowRule(fortDef), nil, "unassigned: today's rule")
    H.eq(handle(a):RowRule(plainDef), nil, "a def that did not opt in has no rule")
    H.eq(handle(a):RowRule(fearDef), "hide", "an assignOnly def with nothing assigned has no row")

    AI.SetOwner(cora.client, FORT, "Bren Holt")
    AI.SetOwner(cora.client, MAGIC, "Nils Frost", 604)
    AI.SetTargets(cora.client, THORNS, "Cora Leaf", { "Alia Dawn" })
    AI.SetTargets(cora.client, FEAR, "Alia Dawn", { "Cora Leaf" })
    sim:run(3)
    H.eq(handle(b):RowRule(fortDef), "force", "the owner's row is forced")
    H.eq(handle(a):RowRule(fortDef), "hide", "another priest's is hidden")
    H.check(handle(b):IsMine(fortDef) and not handle(a):IsMine(fortDef), "IsMine says whose it is")
    H.eq(handle(m2):RowRule(dampDef), "force", "the Magic owner gets the chosen spell")
    H.eq(handle(m2):RowRule(ampDef), "hide", "and not the other one")
    H.eq(handle(m1):RowRule(ampDef), "hide", "another mage gets neither")
    H.eq(handle(m1):RowRule(dampDef), "hide", "of the two")
    H.eq(handle(cora):RowRule(thornsDef), "force", "a druid with a list gets the row")
    H.check(handle(cora):TargetNames(thornsDef)["Alia Dawn"], "listing the target")
    H.eq(handle(a):RowRule(fearDef), "force", "and a priest with Fear Ward targets gets that row")
    H.eq(handle(b):RowRule(fearDef), "hide", "one without stays rowless")
    H.eq(handle(b):TargetNames(fearDef), nil, "with no names")
end

------------------------------------------------------------
-- The engine seam
------------------------------------------------------------

do
    WoW.reset()
    -- A handle whose answers the test sets.
    local rules, names = {}, {}
    local fake = { RowRule = function(_, d) return rules[d.id] end,
                   TargetNames = function(_, d) return names[d.id] end }
    local defs = {
        { id = "fort", snglID = 1243, grpID = 21562, sngl = "Power Word: Fortitude", grp = "Prayer of Fortitude", assign = "owner" },
        { id = "thorns", snglID = 467, sngl = "Thorns", assign = "targets" },
        { id = "fearward", snglID = 6346, sngl = "Fear Ward", assign = "targets", assignOnly = true },
    }
    local enabled = { fort = false, thorns = true, fearward = true }
    local hostFiltered = 0
    local engine = lib.Engine.New({
        defs = defs, bucketSize = 5, assignments = fake,
        isBuffEnabled = function(id) return enabled[id] end,
        membersFor = function(def, members)
            hostFiltered = hostFiltered + 1
            if def.id == "thorns" then return {} end     -- "self" mode with nobody matching
            return members
        end,
    })
    for _, d in ipairs(defs) do d.hasSingle = true end
    defs[1].hasGroup = true
    local function ids(list)
        local out = {}
        for _, d in ipairs(list) do out[#out + 1] = d.id end
        return table.concat(out, ",")
    end
    H.eq(ids(engine:ActiveDefs({}, {})), "thorns,fearward", "no rules: the host's toggles decide")
    rules.fort = "force"
    H.eq(ids(engine:ActiveDefs({}, {})), "fort,thorns,fearward", "an assigned buff shows though its toggle is off")
    rules.fort, rules.fearward = "hide", "hide"
    H.eq(ids(engine:ActiveDefs({}, {})), "thorns", "a buff somebody else has, and an idle assignOnly def, do not")
    rules.fort = "force"
    defs[1].hasSingle, defs[1].hasGroup = false, false
    H.eq(ids(engine:ActiveDefs({}, {})), "thorns", "an assignment never makes an unknown spell castable")
    defs[1].hasSingle, defs[1].hasGroup = true, true

    WoW.SetUnit("raid1", { name = "Alia Dawn", class = "PRIEST" })
    WoW.SetUnit("raid2", { name = "Bren Holt", class = "WARRIOR" })
    WoW.SetUnit("raidpet1", { name = "Fluffy", class = "HUNTER" })
    local members = {
        { unit = "raid1", name = "Alia Dawn", class = "PRIEST" },
        { unit = "raid2", name = "Bren Holt", class = "WARRIOR" },
        { unit = "raidpet1", name = "Fluffy", class = "PET_HUNTER" },
    }
    hostFiltered = 0
    H.eq(#engine:MembersFor(defs[2], members), 0, "no list: the host's filter (Thorns mode)")
    H.eq(hostFiltered, 1, "which ran")
    names.thorns = { ["Bren Holt"] = true, ["Fluffy"] = true }
    hostFiltered = 0
    local out = engine:MembersFor(defs[2], members)
    H.eq(#out, 1, "an assigned list keeps exactly the listed players")
    H.eq(out[1].unit, "raid2", "the non-tank the raid asked for, whatever the mode")
    H.eq(hostFiltered, 0, "without the host's filter")
    names.thorns = { ["Nobody Here"] = true }
    H.eq(#engine:MembersFor(defs[2], members), 0, "a list of absent players gives no row")
    hostFiltered = 0
    H.eq(#engine:MembersFor(defs[1], members), 3, "an owner def keeps the host's filter")
    H.eq(hostFiltered, 1, "(it ran)")

    H.check(not pcall(lib.Engine.New, { defs = { { id = "x", snglID = 1, assign = "mine" } }, bucketSize = 5 }),
        "a misspelt assign kind is a load error")
    H.check(not pcall(lib.Engine.New, { defs = defs, bucketSize = 5, assignments = "yes" }),
        "and so is an assignments that is not a handle")
end

------------------------------------------------------------
-- The live client: events, two hosts, the panel and its menus
------------------------------------------------------------

do
    WoW.reset()
    WoW.inRaid, WoW.groupMembers = true, 3
    WoW.SetUnit("raid1", { name = "Priestly Testcase", class = "PRIEST" })
    WoW.SetUnit("raid2", { name = "Bren Holt", class = "PRIEST" })
    WoW.SetUnit("raid3", { name = "Cora Leaf", class = "DRUID" })
    WoW.raidRoster = { { name = "Priestly Testcase", unit = "raid1" }, { name = "Bren Holt", unit = "raid2" },
                       { name = "Cora Leaf", unit = "raid3" } }
    WoW.units.player = WoW.units.raid1
    for id in pairs(PRIEST) do WoW.Know(id, "Spell " .. id) end
    WoW.DefineSpell(467, "Thorns"); WoW.DefineSpell(21849, "Gift of the Wild")
    WoW.DefineSpell(23028, "Arcane Brilliance"); WoW.DefineSpell(1008, "Amplify Magic"); WoW.DefineSpell(604, "Dampen Magic")

    local said, changed = {}, 0
    local GB = lib:New({ owner = "AssignHost", report = function(text, kind) said[#said + 1] = kind .. ": " .. text end })
    local h = GB.Assignments({ onChanged = function() changed = changed + 1 end })
    local c = lib.assign
    H.eq(h.client, c, "the handle is on the client's one state")
    H.check(c.frame ~= nil, "the first host started the comms frame")
    H.check(WoW.prefixes["LibGroupBuffs"], "and registered the prefix")
    H.eq(GB.Assignments({}), h, "a second call from the same host returns its handle")
    local GB2 = lib:New({ owner = "AssignHost2", report = function() end })
    local h2 = GB2.Assignments({})
    H.check(h2 ~= h and h2.client == c, "a second host subscribes to the same client")
    H.eq(#c.subs, 2, "two subscribers")
    local frames = 0
    for _ in pairs(WoW.events) do frames = frames + 1 end
    H.check(not pcall(GB.Assignments, "x"), "a spec that is not a table is refused")

    H.eq(c.group, 1, "in the home raid")
    H.eq(c.channel, "RAID", "on RAID")
    H.eq(c.me, "Priestly Testcase", "the player by full name")
    WoW.flushTimers(5)
    WoW.flushTimers(1)        -- the pump the hello's timer scheduled
    local hello
    for _, s in ipairs(WoW.addonSent) do if s.message:find("^1%^H") then hello = s end end
    H.check(hello ~= nil and hello.prefix == "LibGroupBuffs" and hello.chatType == "RAID", "a hello went out on RAID")

    -- A peer's hello and record arrive through the real event.
    WoW.dispatch("CHAT_MSG_ADDON", "LibGroupBuffs", "1^H^PRIEST^21562,27681^0", "RAID", "Bren Holt")
    H.check(c.peers["Bren Holt"] ~= nil, "CHAT_MSG_ADDON reaches the client")
    WoW.dispatch("CHAT_MSG_ADDON", "OtherAddon", "1^H^PRIEST^21562^0", "RAID", "Cora Leaf")
    H.eq(c.peers["Cora Leaf"], nil, "another prefix is not ours")
    local before = changed
    WoW.dispatch("CHAT_MSG_ADDON", "LibGroupBuffs",
        AI.EncodeRecord("1243", { ver = (GetServerTime() + 5) * T.VER_SCALE, writer = "Cora Leaf", value = "Bren Holt" }), "RAID", "Cora Leaf")
    H.check(changed > before, "the host hears about an owner change")
    local fortDef = { id = "fort", snglID = 1243, assign = "owner" }
    H.eq(h:Owner(fortDef), "Bren Holt", "and reads it")

    -- The panel.
    H.check(h:Open() == true, "Open shows the panel")
    local f = c.panel
    H.check(f:IsShown(), "it is shown")
    local fortLine
    for _, b in ipairs(f.lines) do
        if b:IsShown() and b._slotKey == 1243 then fortLine = b end
    end
    H.check(fortLine ~= nil, "with a Fortitude line")
    H.check((fortLine.value:GetText() or ""):find("Bren Holt") ~= nil, "showing its owner")
    H.runScript(fortLine, "OnClick")
    local menu = WoW.menus[#WoW.menus]
    H.check(menu ~= nil and menu.owner == fortLine, "a click opens a menu on the line")
    local mine
    for _, e in ipairs(menu.elements) do
        if e.kind == "radio" and e.text == "Priestly Testcase" then mine = e end
    end
    H.check(mine ~= nil, "offering the player")
    mine.b(mine.data)
    H.eq(h:Owner(fortDef), "Priestly Testcase", "choosing it assigns the player")
    H.check(h:IsMine(fortDef), "IsMine agrees")
    WoW.flushTimers(5)
    WoW.flushTimers(1)
    local edit
    for _, s in ipairs(WoW.addonSent) do if s.message:find("^1%^A%^1243%^") then edit = s end end
    H.check(edit ~= nil, "and the edit was sent")

    -- Thorns targets for a druid peer: a checklist with Apply.
    WoW.dispatch("CHAT_MSG_ADDON", "LibGroupBuffs", "1^H^DRUID^467,21849^0", "RAID", "Cora Leaf")
    AI.PanelRefresh(c)
    local thornsLine
    for _, b in ipairs(f.lines) do
        if b:IsShown() and b._slotKey == 467 and b._caster == "Cora Leaf" then thornsLine = b end
    end
    H.check(thornsLine ~= nil, "a druid peer gets a Thorns line")
    H.runScript(thornsLine, "OnClick")
    menu = WoW.menus[#WoW.menus]
    local box, apply
    for _, e in ipairs(menu.elements) do
        if e.kind == "checkbox" and e.text == "Bren Holt" then box = e end
        if e.kind == "button" and e.text == "Apply" then apply = e end
    end
    H.check(box ~= nil and apply ~= nil, "with a checkbox per member and Apply")
    H.check(not box.a(box.data), "unticked at first")
    box.b(box.data)
    H.check(box.a(box.data), "ticked")
    apply.a()
    H.eq(table.concat(AI.Targets(c, THORNS, "Cora Leaf"), ","), "Bren Holt", "Apply writes the list")

    -- A member disconnecting is a UNIT_CONNECTION, not a roster event (#93 review).
    WoW.dispatch("CHAT_MSG_ADDON", "LibGroupBuffs",
        AI.EncodeRecord("1243", { ver = (GetServerTime() + 50) * T.VER_SCALE, writer = "Bren Holt", value = "Bren Holt" }), "RAID", "Bren Holt")
    H.eq(h:Owner(fortDef), "Bren Holt", "Bren owns Fortitude again")
    WoW.units.raid2.connected = false
    before = changed
    WoW.dispatch("UNIT_CONNECTION", "raid2", false)
    H.eq(h:Owner(fortDef), nil, "UNIT_CONNECTION: an owner who disconnects stops counting")
    H.check(changed > before, "and the host is told")
    WoW.units.raid2.connected = true
    WoW.dispatch("UNIT_CONNECTION", "raid2", true)
    H.eq(h:Owner(fortDef), "Bren Holt", "and counts again on reconnecting")
    -- The client reports no lockdown while it dispatches the activation
    -- ("Activating", enforced once dispatch ends), so the event's state counts.
    WoW.chatLockdown = false
    WoW.dispatch("ADDON_RESTRICTION_STATE_CHANGED", 0, 1)
    H.eq(c.lockedAt, nil, "a combat restriction is not the chat one")
    WoW.dispatch("ADDON_RESTRICTION_STATE_CHANGED", 5, 1)
    H.check(c.lockedAt ~= nil, "the chat restriction activating starts the peer clock's pause")
    AI.Changed(c)
    H.check(c.lockedAt ~= nil, "and a check during that dispatch keeps it")
    WoW.chatLockdown = true
    WoW.dispatch("ADDON_RESTRICTION_STATE_CHANGED", 5, 2)
    H.check(c.lockedAt ~= nil, "active: still paused")
    WoW.chatLockdown = false
    WoW.dispatch("ADDON_RESTRICTION_STATE_CHANGED", 5, 0)
    H.eq(c.lockedAt, nil, "inactive resumes it")

    -- In combat the panel is read-only.
    WoW.inCombat = true
    local menus = #WoW.menus
    H.runScript(fortLine, "OnClick")
    H.eq(#WoW.menus, menus, "no menu in combat")
    H.check((f.note:GetText() or ""):find("combat") ~= nil, "and the note says why")
    WoW.inCombat = false

    -- Leaving the group.
    WoW.inRaid, WoW.groupMembers = false, 0
    WoW.dispatch("GROUP_LEFT", 1, "Party-1")
    H.eq(c.group, nil, "GROUP_LEFT with no group left wipes")
    H.eq(next(c.records), nil, "every record")
    H.eq(h:Owner(fortDef), nil, "so nothing is owned")
    H.check(h:Open() == false, "Open toggles the panel closed")
    H.eq(#said, 0, "nothing was reported (" .. table.concat(said, "; ") .. ")")
    H.check((c.stats.results["0"] or 0) >= 2, "the diagnostics count the accepted sends by result code")
    H.check(c.stats.received >= 3 and c.stats.accepted >= 3, "and what arrived on the prefix (three messages)")
end

------------------------------------------------------------
-- An upgrade keeps the client and reaches its frame
------------------------------------------------------------

do
    local c = lib.assign
    local frame = c.frame
    local src = io.open("LibGroupBuffs.lua", "rb"):read("*a"):gsub("\r\n", "\n")
    local minor = tonumber(src:match('local MAJOR, MINOR = "LibGroupBuffs%-1%.0", (%d+)'))
    local newer = src:gsub('local MAJOR, MINOR = "LibGroupBuffs%-1%.0", %d+',
        'local MAJOR, MINOR = "LibGroupBuffs-1.0", ' .. (minor + 1), 1)
    newer = newer:gsub("\nlib%.ready = MINOR", [[

local L = LibStub("LibGroupBuffs-1.0")
local receive = L.AssignImpl.Receive
L._newerReceived = 0
L.AssignImpl.Receive = function(...) L._newerReceived = L._newerReceived + 1 return receive(...) end
lib.ready = MINOR]], 1)
    assert(loadstring(newer, "=newer"))(H.HOST, {})
    H.eq(lib.assign, c, "the newer copy keeps the client")
    H.eq(lib.assign.frame, frame, "and its frame")
    WoW.inRaid, WoW.groupMembers = true, 3
    WoW.dispatch("GROUP_ROSTER_UPDATE")
    WoW.dispatch("CHAT_MSG_ADDON", "LibGroupBuffs", "1^H^PRIEST^21562^0", "RAID", "Bren Holt")
    H.eq(lib._newerReceived, 1, "the frame an older copy made runs the newer code")
end

H.done("test_assign")
