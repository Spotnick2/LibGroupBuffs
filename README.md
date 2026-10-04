# LibGroupBuffs-1.0

Shared engine for PallyPower-style group buff managers on **World of Warcraft: Forever** (1.60.1,
interface `16001`).

Built out of [Priestly](https://github.com/Spotnick2/priestly), which ported from TBC Classic
Anniversary to Forever. Its siblings — [Wildly](https://github.com/Spotnick2/Wildly) and
[Magely](https://github.com/Spotnick2/Magely) — are the same addon with a different `DEFS` table, so
the parts that are not class-specific live here instead of three times over. All three use it.

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
| `LibGroupBuffs.lua` | the whole library, in sections: `Compat` (`lib.API`, every removed or moved API, measured against the live client), `Glass` (the bridge to LibGlass-1.0), `Settings`, `Engine`, `UI`, `Visibility`, and `New`, the per-addon entry point |
| `LibGroupBuffs-1.0.xml` | the entry point a consuming addon loads |
| `LibStub/` | bundled; designed to be embedded many times and resolve to one instance |

One file on purpose: every runtime file of an embedded library needs its own version guard and
completion marker, so up to r25 every release touched six of each. Now it touches one.

**Dependency:** the window is drawn in [LibGlass-1.0](https://github.com/Spotnick2/LibGlass), the
"liquid glass" material shared by the Glass addons. Your addon embeds it **beside** this library
(below). It is not bundled inside, because LibGlass builds its texture paths from its own embed
folder, and a nested copy would draw blank.

## Using it

`.pkgmeta` in the consuming addon, with both libraries:

```yaml
externals:
  Libs/LibGlass-1.0:
    url: https://github.com/Spotnick2/LibGlass
    tag: r1
  Libs/LibGroupBuffs-1.0:
    url: https://github.com/Spotnick2/LibGroupBuffs
    tag: r26
ignore:
  # ...your own list...
  # CurseForge's packager does not apply an external's own ignore list:
  - Libs/LibGlass-1.0/tests
  - Libs/LibGlass-1.0/docs
  - Libs/LibGlass-1.0/Tools
  - Libs/LibGlass-1.0/AGENTS.md
  - Libs/LibGlass-1.0/CLAUDE.md
  - Libs/LibGlass-1.0/README.md
  - Libs/LibGroupBuffs-1.0/tests
  - Libs/LibGroupBuffs-1.0/AGENTS.md
  - Libs/LibGroupBuffs-1.0/CLAUDE.md
  - Libs/LibGroupBuffs-1.0/README.md
```

Pin tags, and keep comments off value lines: the packager reads `tag: r26   # x` as the ref
`r26   # x`. Tags are named after the library's `MINOR`: `r26` is `MINOR = 26`. **Move a pin only
in a release you make anyway.** Players get a fix sooner than that regardless, because LibStub
runs the newest copy any of their addons ships.

Your TOC, LibGlass first, both before any of your own files:

```
Libs\LibGlass-1.0\LibGlass-1.0.xml
Libs\LibGroupBuffs-1.0\LibGroupBuffs-1.0.xml
```

For development, check both repositories out next to your addon (`../LibGlass`,
`../LibGroupBuffs`). Your tests load them from there, and your deploy script copies them into
`Libs/` for in-game testing.

Then one call, once, at load:

```lua
local lib = LibStub("LibGroupBuffs-1.0", true)   -- silent: nil if the library is missing
if not lib then print("MyAddon: LibGroupBuffs-1.0 is missing - reinstall the addon") return end
local ok, GB = pcall(lib.New, lib, {
    owner  = "MyAddon",
    report = function(text, kind) print("MyAddon: " .. text) end,   -- the library never prints
    needs  = 26,                                                    -- the MINOR you pinned
})
if not ok then print("MyAddon: " .. GB) return end
```

`New` errors, with a message meant for the player, when another addon's copy did not finish
loading, when LibGlass is missing, or when the newest copy loaded is older than `needs`. What it
returns is dot-called: each function finds the newest copy's code when it runs, so hold them as
locals if you like.

```lua
GB.RegisterEvents(frame, "PLAYER_LOGIN", "UNIT_AURA")   -- a rejected name reaches report(text, "events")

local settings = GB.Settings({                           -- owner and report filled in
    scopes = { { label = "account-wide", get = function()
        if not MyAddonDB then MyAddonDB = {} end
        return MyAddonDB
    end } },
    measuredOnBuild = "70205",                           -- the build your notes were measured on
})
settings:Set("lockFrame", true)
settings:HandleEnteringWorld(isInitialLogin, isReloadingUi)   -- from PLAYER_ENTERING_WORLD

local engine = GB.Engine({
    defs = {
        { id = "mark", snglID = 1126, grpID = 21849, sngl = "Mark of the Wild",
          grp = "Gift of the Wild", duration = 1800 },
        { id = "thorns", snglID = 467, sngl = "Thorns", duration = 600 },   -- no group form
    },
    bucketSize = 8,
    membersFor = function(def, members) ... end,   -- e.g. Thorns only on tanks
})
engine:RefreshSpells()                             -- at login and on SPELLS_CHANGED

local ui = GB.UI({                                 -- owner filled in
    engine = engine,
    title  = "|cffff9933MyAddon|r",
    footerItems = function() return { { itemID = 17021, usedBy = "Gift of the Wild" } } end,
    getPos = function() return MyAddonDB.pos end,
    setPos = function(pos) settings:Set("pos", pos) end,
})
local vis = GB.Visibility({ ui = ui, isMyClass = ..., showSolo = ...,
    getPreference = ..., setPreference = ... })
vis:Login()                                        -- and GroupJoined, RosterChanged, ContentChanged...
```

Also on the instance: `GB.EventFailures()`, `GB.TimerColor`, `GB.Pct`, `GB.FmtTime`, and read-only
`GB.API`, `GB.STATES`, `GB.PET_GROUP`, `GB.LOAD_CHECK_KEY`, `GB.CLASS_ICONS`, `GB.MINOR`.

Addons built against r25 and earlier reach the library through `lib.API`, `lib.Engine.New`,
`lib.UI.New`, `lib.Settings.New`, `lib.Visibility.New` and `lib.Status`. Those stay, unchanged:
the newest copy loaded serves every addon, including ones that have not moved yet.

`tests/config_scan.lua` (not shipped) lets your tests fail on any other write to your saved table.

Only the runtime files and `LICENSE` end up in your addon's `Libs` folder, given the ignores
above.

## Tests

```powershell
pwsh tests/run.ps1
```

LibGlass comes from `$env:LIBGLASS`, else `../LibGlass`; CI fetches the ref in
`tests/libglass-ref.txt`. Plain Lua 5.1 — the interpreter WoW uses — with no game client. The stub in `tests/wow_stubs.lua` is
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
