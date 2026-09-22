------------------------------------------------------------
-- harness.lua - tiny assertion harness + addon loader.
--
--     local H = dofile("tests/harness.lua")
--     H.loadAddon()
--     H.eq(actual, expected, "what this proves")
--     H.done("test_thing")
--
-- Run from the repo root so the relative paths resolve.
------------------------------------------------------------

local H = { run = 0, failures = 0 }

function H.check(cond, msg)
    H.run = H.run + 1
    if not cond then
        H.failures = H.failures + 1
        print("  FAIL: " .. (msg or "assertion failed"))
    end
end

function H.eq(a, b, msg)
    H.check(a == b, (msg or "values differ") ..
        "  (expected " .. tostring(b) .. ", got " .. tostring(a) .. ")")
end

function H.near(a, b, tol, msg)
    tol = tol or 0.001
    H.check(type(a) == "number" and math.abs(a - b) <= tol,
        (msg or "values differ") .. "  (expected ~" .. tostring(b) .. ", got " .. tostring(a) .. ")")
end

-- The files LibGroupBuffs-1.0.xml loads, in order. Read from the XML itself,
-- so the tests load exactly what the client loads: a file listed there that
-- does not exist fails here, the same way it would fail in game.
-- Follows <Include> the way the client does: a path is relative to the XML
-- file that names it. Returns the Lua files in load order, and every XML file
-- read on the way as a second list.
function H.xmlScripts(root)
    root = root or "."
    local files, xmls = {}, {}
    local function walk(xmlPath)
        local f = assert(io.open(root .. "/" .. xmlPath, "rb"), "cannot open " .. xmlPath)
        local xml = f:read("*a")
        f:close()
        xmls[#xmls + 1] = xmlPath
        xml = xml:gsub("<!%-%-.-%-%->", "")    -- listed in a comment is not loaded
        local dir = xmlPath:match("^(.*/)") or ""
        for tag, file in xml:gmatch('<(%a+)%s+file="([^"]+)"') do
            local path = dir .. (file:gsub("\\", "/"))
            if tag == "Script" then
                files[#files + 1] = path
            elseif tag == "Include" then
                walk(path)
            end
        end
    end
    walk("LibGroupBuffs-1.0.xml")
    return files, xmls
end

-- Load the library the way the client does, once. Every file must load: the
-- previous version skipped any that failed, which also hid syntax errors.
function H.loadLibrary(root)
    root = root or "."
    for _, file in ipairs(H.xmlScripts(root)) do
        local chunk, err = loadfile(root .. "/" .. file)
        if not chunk then error("LibGroupBuffs: cannot load " .. file .. ": " .. tostring(err), 2) end
        chunk()
    end
    local lib = LibStub("LibGroupBuffs-1.0")
    return lib, lib.API
end

-- A priest's three buffs, used as realistic sample data.
H.SPELL = {
    FORT_SINGLE   = 1243,  FORT_GROUP   = 21562,
    SPIRIT_SINGLE = 14752, SPIRIT_GROUP = 27681,
    SHADOW_SINGLE = 976,   SHADOW_GROUP = 27683,
}
H.NAME = {
    FORT_SINGLE   = "Power Word: Fortitude",
    FORT_GROUP    = "Prayer of Fortitude",
    SPIRIT_SINGLE = "Divine Spirit",
    SPIRIT_GROUP  = "Prayer of Spirit",
    SHADOW_SINGLE = "Shadow Protection",
    SHADOW_GROUP  = "Prayer of Shadow Protection",
}

-- Teach the stub client every spell name, and make `known` (a list of keys
-- into H.SPELL) the ones the player actually has.
function H.TeachSpells(known)
    for key, id in pairs(H.SPELL) do
        WoW.DefineSpell(id, H.NAME[key])
    end
    for _, key in ipairs(known or {}) do
        WoW.Know(H.SPELL[key], H.NAME[key])
    end
end

-- An engine shaped like Priestly's: the three priest buffs, durations stored
-- in memory, and config the test flips through `host.config`. Everything a
-- real addon keeps in its saved table lives in plain fields here, so a test
-- reads exactly what the engine asked the addon to store.
function H.PriestEngine()
    local lib = LibStub("LibGroupBuffs-1.0")
    local host = {
        config = { showSolo = false, trackPets = true, enabled = {}, visible = {} },
        durations = {},
        visibilityCalls = {},
    }
    host.defs = {
        { id = "fort", snglID = H.SPELL.FORT_SINGLE, grpID = H.SPELL.FORT_GROUP,
          sngl = H.NAME.FORT_SINGLE, grp = H.NAME.FORT_GROUP, duration = 3600 },
        { id = "spirit", snglID = H.SPELL.SPIRIT_SINGLE, grpID = H.SPELL.SPIRIT_GROUP,
          sngl = H.NAME.SPIRIT_SINGLE, grp = H.NAME.SPIRIT_GROUP, duration = 3600 },
        { id = "shadow", snglID = H.SPELL.SHADOW_SINGLE, grpID = H.SPELL.SHADOW_GROUP,
          sngl = H.NAME.SHADOW_SINGLE, grp = H.NAME.SHADOW_GROUP, duration = 600 },
    }
    host.engine = lib.Engine.New({
        defs = host.defs,
        bucketSize = 8,
        showSolo = function() return host.config.showSolo end,
        trackPets = function() return host.config.trackPets end,
        isBuffEnabled = function(id) return host.config.enabled[id] ~= false end,
        isVisible = function(def, groups, ord)
            host.visibilityCalls[#host.visibilityCalls + 1] = { def = def, groups = groups, ord = ord }
            return host.config.visible[def.id] ~= false
        end,
        learnDuration = function(spell, seconds) host.durations[spell] = seconds end,
        learnedDuration = function(spell) return host.durations[spell] end,
    })
    function host.def(id)
        for _, d in ipairs(host.defs) do if d.id == id then return d end end
    end
    return host
end

-- A window shaped like Priestly's, over H.PriestEngine. Everything the addon
-- would keep in its saved table lives in `host.saved`, and every call the
-- window makes back into the addon is recorded, so a test reads exactly what
-- the window asked for.
function H.PriestUI(opts)
    opts = opts or {}
    local lib = LibStub("LibGroupBuffs-1.0")
    local host = opts.engineHost or H.PriestEngine()
    host.saved = { visible = nil, pos = nil }
    host.ui_config = { alpha = 0.96, locked = false, popoverSide = "auto", hints = true }
    host.footer = {}
    host.layouts, host.visibility = 0, {}
    host.ui = lib.UI.New({
        engine  = host.engine,
        owner   = opts.owner or "Priestly",
        title   = opts.title or "|cff99ddffPriestly|r",
        version = "test",
        appearance = function() return host.look end,
        unknownClassIcon = "PRIEST_ICON",
        footerItems = function() return host.footer end,
        alpha       = function() return host.ui_config.alpha end,
        locked      = function() return host.ui_config.locked end,
        popoverSide = function() return host.ui_config.popoverSide end,
        showClickHints = function() return host.ui_config.hints end,
        getPos = function()
            if not host.saved.pos then return nil, "no saved pos" end
            return host.saved.pos
        end,
        setPos     = function(pos) host.saved.pos = pos end,
        setVisible = function(v) host.saved.visible = v end,
        onLayout   = function() host.layouts = host.layouts + 1 end,
        onVisibility = function(_, v) host.visibility[#host.visibility + 1] = v end,
    })
    return host
end

-- A party of three - the player and two members - which most window tests
-- start from.
function H.Party3()
    WoW.SetUnit("player", { name = "Karuzo Elegia", guid = "P0", class = "PRIEST" })
    WoW.SetUnit("party1", { name = "Sten Thornbeard", guid = "P1", class = "WARRIOR" })
    WoW.SetUnit("party2", { name = "Mirel Dawnsong", guid = "P2", class = "MAGE" })
    WoW.groupMembers = 3
end

-- The active rows of a window, in order.
function H.ActiveRows(ui)
    local out = {}
    for _, r in ipairs(ui.rows) do
        if r._active then out[#out + 1] = r end
    end
    return out
end

-- Call a frame's script handler, failing the test rather than the run if it
-- throws - including on an unstubbed global.
function H.runScript(frame, script, ...)
    if not frame then H.check(false, "no frame for " .. script) return end
    local fn = frame._scripts and frame._scripts[script]
    if not fn then H.check(false, "no " .. script .. " handler installed") return end
    local ok, err = pcall(fn, frame, ...)
    H.check(ok, script .. " ran without error: " .. tostring(err))
    return ok
end

-- Combat aura secrecy as measured on the live client: the flag is set AND
-- every index read throws, while the by-name lookup quietly returns nil.
function H.secrecy(on)
    WoW.secret = on and true or false
    WoW.auraReadsThrow = on and true or false
    WoW.inCombat = on and true or false
end

function H.done(name)
    if H.failures > 0 then
        print(string.format("%s: %d/%d FAILED", name, H.failures, H.run))
        os.exit(1)
    end
    print(string.format("%s: %d tests passed", name, H.run))
end

return H
