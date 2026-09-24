# LibGroupBuffs-1.0

Shared engine for PallyPower-style group buff managers on **World of Warcraft: Forever** (1.60.1,
interface `16001`).

Built out of [Priestly](https://github.com/Spotnick2/priestly), which ported from TBC Classic
Anniversary to Forever. Its siblings — [Wildly](https://github.com/Spotnick2/Wildly) and
[Magely](https://github.com/Spotnick2/Magely) — are the same addon with a different `DEFS` table, so
the parts that are not class-specific live here instead of three times over. Priestly is the only
consumer so far; Wildly and Magely are still on TBC and will follow.

## Why a library

Forever is Vanilla *content* running on the Retail/Mainline *codebase*, and porting to it surfaced a
long list of client behaviours that are not in any documentation, several of which fail **silently**:

- aura reads throw in combat, for every unit — while the by-name lookup quietly returns nil, which
  is indistinguishable from "not buffed"
- a secret value throws when it is *compared* or *truth-tested*, not only when it is read
- `C_Spell.GetSpellInfo(name)` resolves only spells the player knows; by ID it always works
- `UnitName` returns only the first name for anyone but the player, because characters have surnames
- `GetInstanceInfo` returns the continent when you are outdoors, not an empty string
- `MouseIsOver` is gone
- no SavedVariables are read back after a real restart, account-wide or per-character, and addon
  CVars are lost too — nothing an addon writes survives. `/reload` hides this, because it keeps the
  client running

Each of those cost a debugging cycle to find. Rediscovering them per addon is the expensive path.

## Layout

| File | What it holds |
|---|---|
| `Compat.lua` | `lib.API` — every removed or moved API, measured against the live client |
| `Settings.lua` | `lib.Settings` — one write path for your saved table, and the checks that notice when the client is fixed or updated |
| `Engine.lua` | `lib.Engine` — aura reads that survive combat secrecy, the roster, group stats, target picking and click mapping |
| `UI.lua` | `lib.UI` — the buff window: rows, popover, secure click casting, footer, and the combat rules |
| `LibGroupBuffs-1.0.xml` | the entry point; lists exactly the files that exist, in load order |
| `LibStub/` | bundled; designed to be embedded many times and resolve to one instance |

Planned, not yet present: shared options-panel widgets.

## Using it

`.pkgmeta` in the consuming addon:

```yaml
externals:
  Libs/LibGroupBuffs-1.0:
    url: https://github.com/Spotnick2/LibGroupBuffs
    tag: r2
```

Pin a tag. Tracking the branch would let a release's library change without any change to the
addon. Tags are named after the library's `MINOR`: `r2` is `MINOR = 2`.

For development, check this repository out next to the addon (`../LibGroupBuffs`). The consuming
addon's tests load it from there, and its deploy script copies it into `Libs/` for in-game
testing.

Its TOC, before any of its own files:

```
Libs\LibGroupBuffs-1.0\LibGroupBuffs-1.0.xml
```

Then:

```lua
local API = LibStub("LibGroupBuffs-1.0").API
```

Call library functions through `API` rather than copying them into locals: a newer embedded copy
upgrades `API` in place, and a local copy would keep running the old version.

Register events with your own reporter, so a name this client rejects is never silent. The library
still prints nothing itself; what the report says is up to you:

```lua
API.RegisterEventsReported(frame, "MyAddon", function(rejected)
    print("MyAddon: unsupported events skipped: " .. table.concat(rejected, ", "))
end, "PLAYER_LOGIN", "UNIT_AURA")
```

Route settings through one setter, and let the library watch for the SavedVariables fix and for
a new client build. Your addon owns its SavedVariables; the library only calls the accessors:

```lua
local settings = LibStub("LibGroupBuffs-1.0").Settings.New({
    owner  = "MyAddon",
    scopes = { { label = "account-wide", get = function()
        if not MyAddonDB then MyAddonDB = {} end
        return MyAddonDB
    end } },
    measuredOnBuild = "69913",   -- the build your notes were measured on
    svBrokenOnBuild = "69913",   -- the build where SavedVariables are measured broken
    report = function(text) print("MyAddon: " .. text) end,
})
settings:Set("lockFrame", true)
-- from your PLAYER_ENTERING_WORLD handler:
settings:HandleEnteringWorld(isInitialLogin, isReloadingUi)
```

One engine per addon. It needs your buff definitions (by spell ID) and a popover size; everything
else is optional and defaults sensibly:

```lua
local engine = LibStub("LibGroupBuffs-1.0").Engine.New({
    defs = {
        { id = "mark", snglID = 1126, grpID = 21849, sngl = "Mark of the Wild",
          grp = "Gift of the Wild", duration = 1800 },
        { id = "thorns", snglID = 467, sngl = "Thorns", duration = 600 },   -- no group form
    },
    bucketSize = 8,
    membersFor = function(def, members) ... end,   -- e.g. Thorns only on tanks
})
engine:RefreshSpells()                             -- at login and on SPELLS_CHANGED
local groups, ord = engine:GatherGroups()
for _, def in ipairs(engine:ActiveDefs(groups, ord)) do
    local members = engine:MembersFor(def, groups[ord[1]])
    local st = engine:GroupStat(members, def)
    local left, right = engine:ClickSpells(def)
    local target = engine:PickTarget(members, def, def.hasGroup, st)
end
```

And the window, which draws the engine's rows and handles the clicks. Your addon decides when it
opens and supplies its branding, reagents and settings:

```lua
local ui = LibStub("LibGroupBuffs-1.0").UI.New({
    engine = engine,
    owner  = "MyAddon",
    title  = "|cffff9933MyAddon|r",
    footerItems = function() return { { itemID = 17021, usedBy = "Gift of the Wild" } } end,
    getPos = function() return MyAddonDB.pos end,
    setPos = function(pos) settings:Set("pos", pos) end,
})
ui:Open(0.5)                        -- from PLAYER_LOGIN, when your addon wants it shown
-- Open coalesces: call it from every event that should show the window. A burst is one
-- rebuild, and the soonest request wins.
-- and from events: ui:ScheduleRefresh(), ui:OnCombatEnd(), ui:Close(manual) ...
```

`tests/config_scan.lua` (not shipped) lets your tests fail on any other write to your saved table.

Only the runtime files and `LICENSE` end up in your addon's `Libs` folder. The library's own
`.pkgmeta` tells the packager to leave out its tests and notes.

## Tests

```powershell
pwsh tests/run.ps1
```

Plain Lua 5.1 — the interpreter WoW uses — with no game client. The stub in `tests/wow_stubs.lua` is
an **allowlist**: it fails the run on the read of any global it does not define, and it models the
client's *absences* and odd shapes as well as its presences. That discipline came from real misses,
where a stub more forgiving than the client let broken code pass a green suite.

Your addon's tests can use that stub rather than keeping a copy, so the absences and the combat
refusals are measured once:

```lua
dofile(libraryRoot .. "/tests/wow_stubs.lua")
WoW.SetPlayerDefaults({ name = "Wildly Testcase", class = "DRUID" })
WoW.allowGlobal("Wildly", "WildlyDB")     -- your own globals
function EJ_GetNumTiers() return 1 end    -- an API only you call
```

## License

MIT, same as the addons that use it.
