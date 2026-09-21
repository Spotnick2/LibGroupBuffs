# LibGroupBuffs-1.0

Shared engine for PallyPower-style group buff managers on **World of Warcraft: Forever** (1.60.1,
interface `16001`).

Built out of [Priestly](https://github.com/Spotnick2/priestly), which ported from TBC Classic
Anniversary to Forever. Its siblings — Druidly and Magely — are the same addon with a different
`DEFS` table, so the parts that are not class-specific live here instead of three times over.

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
- account-wide SavedVariables are written but never read back

Each of those cost a debugging cycle to find. Rediscovering them per addon is the expensive path.

## Layout

| File | What it holds |
|---|---|
| `Compat.lua` | `lib.API` — every removed or moved API, measured against the live client |
| `Engine.lua` | aura cache and combat secrecy, learned durations, roster gathering, group stats, target picking *(in progress)* |
| `UI.lua` | the generic row and popover frames, driven by a `DEFS` table *(in progress)* |
| `LibStub/` | bundled; designed to be embedded many times and resolve to one instance |

## Using it

`.pkgmeta` in the consuming addon:

```yaml
externals:
  Libs/LibGroupBuffs-1.0:
    url: https://github.com/Spotnick2/LibGroupBuffs
```

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
