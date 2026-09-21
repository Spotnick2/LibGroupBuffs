# LibGroupBuffs-1.0 Agent Instructions

Trust these instructions. Search the codebase only when information here is incomplete, stale, or
appears incorrect.

## What This Repository Is

`LibGroupBuffs-1.0` is the shared engine behind three WoW: Forever addons — Priestly, Druidly and
Magely — which are the same PallyPower-style group buff manager with different `DEFS` tables.

It is a **LibStub library**, embedded into each addon at package time through `.pkgmeta` externals.
There is no build system and no package manager; validation is a Lua 5.1 test suite plus in-game
testing through a consuming addon.

Target client: **WoW: Forever 1.60.1**, interface `16001`, `WOW_PROJECT_ID == WOW_PROJECT_MAINLINE`.
Vanilla content, Retail codebase.

## Layout

- `Compat.lua` — `lib.API`, every removed or moved API. **Nothing outside this file may call a
  moved API directly.**
- `Engine.lua` — aura cache, combat secrecy, learned durations, roster, group stats, targeting.
- `UI.lua` — generic row and popover frames driven by a `DEFS` table.
- `LibGroupBuffs-1.0.xml` — load order; the entry point a consuming addon references.
- `LibStub/` — bundled, unmodified, public domain.
- `tests/` — Lua 5.1, no game client.

## Library Rules

- **Never print.** A library has no business writing to somebody else's chat frame. Return failures
  to the caller — `API.RegisterEvents` returns `ok, failedList` for exactly this reason.
- **No globals** beyond what LibStub requires. No `_G` injection: defining a real `GetItemInfo`
  changes capability detection for every other addon on the machine.
- **No addon-specific behaviour.** Anything that differs between Priestly, Druidly and Magely
  belongs in the addon or behind a host callback, not in a branch here.
- **Version bumps:** raise `MINOR` in `Compat.lua` whenever behaviour changes, so an older embedded
  copy loses to a newer one. `LibStub:NewLibrary` returns nil when a newer copy already loaded, and
  every file must honour that early return.

## Client Rules (measured, not inferred)

Full notes in the consuming addon's `docs/FOREVER-PROBE.md`. The ones that bite:

- **Aura reads throw in combat, for every unit** — not just the player. `GetAuraDataBySpellName`
  does *not* throw; it returns nil, which is indistinguishable from "not buffed". Only the index
  walk makes the block visible.
- **A secret value throws when COMPARED or TRUTH-TESTED, not only when read.**
  `if updateInfo.isFullUpdate then` raises. Guarding a field read and testing the result one line
  later is not enough — every touch of client data in combat belongs *inside* the same `pcall`.
- **`C_Spell.GetSpellInfo(name)` resolves only spells the player knows.** By ID it always works.
  Resolve names *from* IDs, never the reverse.
- **`UnitName` returns only the first name** for anyone but the player: characters have surnames,
  and the surname arrives where the realm normally sits. Use `API.UnitDisplayName`.
- **`GetInstanceInfo` returns the continent outdoors**, not an empty string.
- **`MouseIsOver` is gone.** Frames carry `:IsMouseOver()`.
- **`RegisterEvent` throws on an unknown event name.**
- **Account-wide SavedVariables are written but never read back.** Consuming addons must use
  `SavedVariablesPerCharacter`. The library holds no saved state of its own.
- Lua 5.1: `0` is truthy, so `x or default` does not guard a numeric that can be 0.

## Testing

```powershell
pwsh tests/run.ps1
```

`tests/wow_stubs.lua` is an **allowlist**: it fails the run on the read of any global it does not
define. That only works if it also models the client's absences and shapes honestly — a stub more
forgiving than the client lets broken code pass a green suite, which is how a call to the removed
`MouseIsOver` shipped once. Confirm a new global against the live client before stubbing it.

Strict globals only catch what actually runs, so every script handler the library installs needs a
test that executes it.

## Workflow

Issues and pull requests, same as the addons: open an issue, branch, PR referencing it, review
before merge. Any behaviour change here lands in three addons at once, so it deserves more care than
a change in one of them, not less.
