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
| `LibGroupBuffs-1.0.xml` | the entry point; lists exactly the files that exist, in load order |

Planned, not yet present: the settings write path, the buff engine and the row/popover UI.
| `LibStub/` | bundled; designed to be embedded many times and resolve to one instance |

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

## Tests

```powershell
pwsh tests/run.ps1
```

Plain Lua 5.1 — the interpreter WoW uses — with no game client. The stub in `tests/wow_stubs.lua` is
an **allowlist**: it fails the run on the read of any global it does not define, and it models the
client's *absences* and odd shapes as well as its presences. That discipline came from real misses,
where a stub more forgiving than the client let broken code pass a green suite.

## License

MIT, same as the addons that use it.
