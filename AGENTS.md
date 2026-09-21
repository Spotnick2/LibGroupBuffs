# LibGroupBuffs-1.0 Agent Instructions

Trust these instructions. Search the codebase only when information here is incomplete, stale, or
appears incorrect.

## Review policy

Use `$wow-addon-review` as the shared source of truth for review routing, committed-diff scope,
client/API evidence handling, validation, finding format, and merge-readiness verdicts.

Repository-specific additions:

- Post every pull-request review and follow-up review on the PR, then link the posted review in the
  final response.
- Start reviews in `C:\Projects\LibGroupBuffs`, or name the repository explicitly (for example,
  `gh pr diff 8 -R Spotnick2/LibGroupBuffs`); PR numbers overlap with consumer repositories.
- The library has no build constant yet. Match Priestly's `MEASURED_ON_BUILD` in
  `C:\Projects\Priestly\PriestlyConfig.lua` to
  `C:/Projects/References/forever-api-<version>.<build>.md`. Runtime measurements live in
  `C:\Projects\Priestly\docs\FOREVER-PROBE.md`.
- A change here ships in every consumer. Review it as a change to Priestly, Wildly and Magely at
  once: check the version guard, table identity across an upgrade, and that nothing assumes one
  particular consumer.

## What This Repository Is

`LibGroupBuffs-1.0` is the shared engine behind three WoW: Forever addons — Priestly, Wildly and
Magely — which are the same PallyPower-style group buff manager with different `DEFS` tables.
Priestly is the only consumer today; Wildly and Magely are still TBC addons and will be ported onto
the library later. Changes land in Priestly first, so keep them class-agnostic from the start.

It is a **LibStub library**, embedded into each addon at package time through `.pkgmeta` externals.
There is no build system and no package manager; validation is a Lua 5.1 test suite plus in-game
testing through a consuming addon.

Target client: **WoW: Forever 1.60.1**, interface `16001`, `WOW_PROJECT_ID == WOW_PROJECT_MAINLINE`.
Vanilla content, Retail codebase.

## Layout

- `Compat.lua` — `lib.API`, every removed or moved API. **Nothing outside this file may call a
  moved API directly.**
- `LibGroupBuffs-1.0.xml` — load order; the entry point a consuming addon references. It lists
  **only files that exist**: a missing one is a load error in every embedding addon.
  `tests/harness.lua` loads exactly this list, so the suite fails the same way the client would.
- `Settings.lua` — `lib.Settings.New(spec)`: one write path for an addon's saved table
  (`Set`, `SetIn`, `Changed`), the SavedVariables-fix detector and the build watch
  (`HandleEnteringWorld`). The addon passes accessors for its own saved tables (the first is the
  settings store), its `measuredOnBuild` / `svBrokenOnBuild` constants and a required
  `report(text, kind)`. The library composes the plain-text messages, because the "full exit, not a
  relog" caveat is part of the detector being right; the addon adds its prefix and colour.
- Planned, not yet present: `Engine.lua` (aura cache, learned durations, roster, group stats,
  targeting) and `UI.lua` (row and popover frames).
- `LibStub/` — bundled, unmodified, public domain.
- `tests/` — Lua 5.1, no game client. `tests/config_scan.lua` is also used by consumers: their
  tests `dofile` it from their library checkout to fail on writes to their SavedVariables outside
  a `config-owner` region. It is not shipped.
- `.pkgmeta` — **not for publishing** (the library never is): its `ignore` list decides what the
  packager copies into each consuming addon's `Libs/LibGroupBuffs-1.0`. Only runtime files and
  `LICENSE` ship. `tests/test_packaging.lua` checks nothing the XML loads (following `<Include>`) is
  ignored, and that every file `git ls-files` lists is either loaded, `LICENSE`, or ignored — so a
  new file that is not runtime code fails the suite until it gets an entry here.

## Library Rules

- **Never print, and never let a failure be silent either.** A library has no business writing to
  somebody else's chat frame, so it hands failures to the consumer to report. Where ignoring the
  return value would silently lose one, take the consumer's reporter and refuse to run without it:
  `API.RegisterEventsReported(frame, owner, report, ...)` errors if `report` is not a function, and
  records failures per consumer in `API.eventFailuresByOwner[owner]`. `API.RegisterEvents` stays for
  consumers pinned to an older tag.
- **No globals** beyond what LibStub requires. No `_G` injection: defining a real `GetItemInfo`
  changes capability detection for every other addon on the machine.
- **No addon-specific behaviour.** Anything that differs between Priestly, Wildly and Magely
  belongs in the addon or behind a host callback, not in a branch here.
- **Version bumps:** raise `MINOR` in **every runtime file** (they must agree;
  `tests/test_versions.lua` checks) whenever behaviour changes, so an older embedded
  copy loses to a newer one, and tag the merge `r<MINOR>` for consumers to pin. `LibStub:NewLibrary`
  returns nil when a newer copy already loaded.
- **An upgrade reuses the existing tables.** A newer copy loading after an older one gets the same
  `lib` and `lib.API`, so write `X = X or {}` for anything holding state (see `eventFailures`), and
  never replace a table other code may have taken a reference to. `tests/test_versions.lua` checks
  equal-after-equal, older-after-newer and newer-after-older, loading every runtime file, against
  the real released source in `tests/fixtures/` (r2, the copy Priestly v2.0.x ships, and r3). When a
  new tag goes out and consumers move to it, add that tag's runtime files as fixtures too; never
  synthesise the older copy from the current source, since it would already contain what the
  upgrade must add. Objects handed to consumers (settings objects) hold a shared metatable whose
  methods table is assigned in place, so an upgrade reaches objects an older copy created.
- **More than one file needs a shared guard.** Returning early from `Compat.lua` does not stop the
  XML from running the next file, and calling `NewLibrary` again with the same version in a second
  file makes that file reject itself. So `Compat.lua` claims the version, and every later file
  checks `LibStub:GetLibrary(MAJOR)` reports its own `MINOR` (else an older copy is loading after a
  newer one) and that it has not installed already (`lib.settingsMinor == MINOR`: equal after
  equal, where reinstalling would replace functions consumers hold). It records that marker as its
  **last** line, so a file that threw partway is not marked installed.

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
- **`GameTooltip` has no item-setting method at all** — no `SetItemByID`, `SetHyperlink`,
  `SetBagItem` or `SetInventoryItem`. Build item tooltips from `API.ItemInfo`.
- **Register secure buff buttons for both mouse edges** (`API.ClickEdges`). The client's secure
  handler acts on exactly one of them, chosen by `ActionButtonUseKeyDown`, so both is one cast; one
  edge is a dead button for anyone whose client acts on release. Never set `typerelease` on such a
  button: that path would cast a second time.
- **`RegisterEvent` throws on an unknown event name**, and is declared to return
  `registered:bool`, so a `false` return is a refusal too. `API.RegisterEvents` treats both as
  failures, and rejects a nil or empty name before registering anything.
- **Nothing an addon writes survives a real restart** — account-wide or per-character
  SavedVariables, or addon CVars. An earlier note here said per-character storage works; it does
  not. `/reload` keeps the client running, so it can prove something is broken, never that it works.
  The library holds no saved state of its own.
- Lua 5.1: `0` is truthy, so `x or default` does not guard a numeric that can be 0.

## Testing

```powershell
pwsh tests/run.ps1
```

`tests/wow_stubs.lua` is an **allowlist**: it fails the run on the read of any global it does not
define. That only works if it also models the client's absences and shapes honestly — a stub more
forgiving than the client lets broken code pass a green suite, which is how a call to the removed
`MouseIsOver` shipped once. Before stubbing a new global, confirm it exists in the newest
`C:/Projects/References/forever-api-<build>.md`, and stub it with the client's exact signature.

Strict globals only catch what actually runs, so every script handler the library installs needs a
test that executes it. And they do not cover **methods**: the stub's frames answer any unknown
method with a silent no-op, so a call to a widget method this client lacks passes unnoticed. For
anything built on a widget method, execute it and assert what it produced.

`tests/harness.lua` loads exactly what `LibGroupBuffs-1.0.xml` lists, in order, and fails on
anything missing — the same way the client would. `tests/test_versions.lua` loads the library in
three orders to check an upgrade keeps table identity and state.

`Settings.lua` is used by addons that also run their own copy of the load-check tests; when you
change it, run the Priestly suite too (below) — its `test_config_seam.lua` checks the same
behaviour through Priestly's wrappers.

### Validate through a consumer before tagging

The library's own tests cover each contract. Priestly exercises the library far more — every aura
read, click and tooltip — so run its suite against your working copy before tagging:

```powershell
pwsh ..\Priestly\tests\run.ps1        # reads this checkout as ../LibGroupBuffs
```

Its first line names the library revision it ran against. `pwsh ..\Priestly\Tools\deploy.ps1`
puts the same working copy into the game for an in-game check.

## Workflow

Issues and pull requests, same as the addons: open an issue, branch, PR referencing it, review
before merge. Any behaviour change here lands in three addons at once, so it deserves more care than
a change in one of them, not less.

For a separate architecture or risk consult, the `codex-consult` skill
(`.claude/skills/codex-consult`) can run Codex headlessly. `$wow-addon-review` remains authoritative
for the WoW code-review method and verdict.

## Releasing

Consumers pin a tag, so nothing reaches them until one exists:

1. Raise `MINOR` in every runtime file for any behaviour change, in the same PR.
2. After merge, tag the merge commit `r<MINOR>` and push the tag: `git tag r3 && git push origin r3`.
   The tag and `MINOR` must match; a consumer reading the tag assumes it knows the version.
3. In each consumer, bump `tag:` in `.pkgmeta` in its own PR. Its CI checks out exactly that tag and
   checks the release zip carries the library, so a bad tag fails there, not in players' hands.

Never move or reuse a tag once pushed: a consumer's release is pinned to it.
