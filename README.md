# LibGroupBuffs-1.0

Shared engine for PallyPower-style group buff managers on **World of Warcraft: Forever** (1.60.1,
interface `16001`).

Built out of [Priestly](https://github.com/Spotnick2/priestly), which ported from TBC Classic
Anniversary to Forever. Its siblings — [Wildly](https://github.com/Spotnick2/Wildly) and
[Magely](https://github.com/Spotnick2/Magely) — are the same addon with a different `DEFS` table, so
the parts that are not class-specific live here instead of three times over. All three use it.

The buff window and its popover use `LOW` frame strata, so normal `MEDIUM` or
higher UI panels can cover them. The popover keeps its higher frame level within
`LOW`. Existing windows adopt this on their next out-of-combat rebuild. Custom
bag addons that also use `LOW` still need an in-game overlap check.

## Optional minimize/restore (r31)

Pass `minimizable = true` to `GB.UI` to add a `-` / `+` header control. Hosts that
do not opt in keep their existing header. The version text is omitted from an
opted-in header to reserve the controls' space; keep version information in the
host's diagnostics.

- `ui:IsMinimized()` reports the requested, session-only state. It defaults to
  false on a new UI instance; no SavedVariables are read or written for it.
- `ui:SetMinimized(bool)` and `ui:ToggleMinimized()` return false if disabled or
  combat defers the layout. During combat, only the requested state changes; the
  latest request is applied by the normal `OnCombatEnd` rebuild. An optional
  `onMinimizeDeferred(ui, minimized)` hook can explain that delay to the player.
- Minimize is separate from close: `IsVisible()` stays true, no closed preference
  is saved, and a close wins over either mode. Refreshes and subsequent opens keep
  the session's minimized state. Restore uses the current roster and settings.
- The header keeps its position when the body changes height. Dragging while
  minimized saves a top anchor so an expanded window on the next login uses the
  same header position. Lock and reset retain their normal behavior.
- A companion host must handle `ui:IsMinimized()` in `onLayout` before opting in:
  hide the companion while minimized and restore it when expanded. This hook runs
  after the protected layout has actually changed, outside combat. The existing
  `onVisibility` and `onTick` contracts are unchanged; minimized is still open.

In-game acceptance still includes clicks, dragging, edge clamping, scale, popup
dismissal, and minimize/restore/close ordering during combat. Unit tests cannot
prove the client's visual layout or protection behavior.

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
    # r6 or newer: the window uses its clean preset (r29)
    tag: r6
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
    needs  = 28,                                                    -- the MINOR you pinned
})
if not ok then
    -- New's error is a plain string. Why it refused, with a code to word each case
    -- for your players, comes from lib:Refusal (r28); nil means it was not a refusal
    -- (a bug, or a mistake in the call itself). The ACTIVE copy may predate r28 -
    -- another addon's older copy, or an r28 that failed before installing Refusal,
    -- which is exactly when New refuses - so check it exists, and fall back to GB,
    -- the string New raised.
    local why = type(lib.Refusal) == "function" and lib:Refusal(28) or nil
    local code = why and why.code
    if code == "glass-missing" or code == "too-old" then
        print("MyAddon: cannot start - its download is incomplete or outdated; reinstall MyAddon")
    else
        print("MyAddon: cannot start - " .. (why and why.text or GB))
    end
    return
end
```

`New` refuses, with a plain string meant for the player, when another addon's copy did not
finish loading (`"incomplete"`), when LibGlass is missing (`"glass-missing"`) or did not finish
loading (`"glass-incomplete"`), or when the newest copy loaded is older than `needs`
(`"too-old"`, meaning your own copy is stale). `lib:Refusal(needs)` returns that reason as
`{ code, text, active, needs, glassMinor }`, or nil. New codes may be added, so treat one you
don't know as a generic failure. What `New`
returns is dot-called: each function finds the newest copy's code when it runs, so hold them as
locals if you like.

```lua
GB.RegisterEvents(frame, "PLAYER_LOGIN", "UNIT_AURA")   -- a rejected name reaches report(text, "events")

local settings = GB.Settings({                           -- owner and report filled in
    scopes = { { label = "account-wide", get = function()
        if not MyAddonDB then MyAddonDB = {} end
        return MyAddonDB
    end } },
    measuredOnBuild = "70338",                           -- the build your notes were measured on
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

Starting with r32, `GB.UI(host)` accepts `glass`, a LibGlass instance selected before the
window is built, and `bodyStyle(frame)`, an optional callback returning a body descriptor:
`{ tint = { r, g, b, a }, wash = multiplier, backing = { r, g, b, a } }`. Components are
plain numbers; colors are 0–1. `wash` multiplies the selected material's own wash and is
clamped to 0–1 after multiplication. The backing is masked beneath the tint. A body descriptor
owns opacity, so the host's `alpha` callback does not override it. Returning nil retains the
normal appearance/alpha behavior. Set these construction options before `Init`; changing
the material on an already built window requires a reload.

Panels, icon decoration, headers, and row fills use that window's material. The library never
mutates its style. Hosts that omit both fields keep the shared Clean material and existing
opacity behavior, including objects built by an older library before an upgrade.

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
