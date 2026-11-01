# LibGroupBuffs r33 audit (2026-10-31)

Desk audit of the library at `main` = r33 against the three open user reports, with the
regression tests, stub hardening and probe procedures that came out of it. Nothing here was
measured in game: the owner has no client access until 2026-11-04, and the in-game runs are
tracked as a separate issue. Measured facts quoted below come from Priestly's
`docs/FOREVER-PROBE.md` and `References/Docs/PORTING-TBC-TO-FOREVER.md` (builds 69913 to 70450).

What ships where, at the time of the audit:

| Consumer | Version | LibGroupBuffs pin |
|---|---|---|
| Priestly | v2.0.17 | r31 |
| Wildly | v1.0.6 | r28 |
| Magely | v1.0.6 | r28 |
| Buffy | v0.1.1-alpha3 | r33 |

LibStub runs the newest copy any installed addon ships, so a player with Priestly and Magely
runs r31's engine under both.

## Report B — `ADDON_ACTION_BLOCKED` on `WildlyMain:Hide()` (Wildly #42; Priestly #110, Magely #53)

**Classification: historical. Not reproducible in any version that hosts on this library.**

Evidence:
- `WildlyMain` is a frame name that exists only in Wildly tags v0.1 and v0.1.1. Commit 42ce6ef
  ("Make Wildly.lua a host on LibGroupBuffs' engine and window", v1.0.0) removed it. The report
  names that frame, so it was produced by Wildly v0.1.x.
- The library has never named a frame: every `CreateFrame` passes `nil`, in r33 and in every
  frozen fixture back to UI-r6. An `ADDON_ACTION_BLOCKED` from a library window would name an
  anonymous frame.
- In r33 every write to the two protected frames (main and popover, which parent secure
  buttons) sits behind `InCombatLockdown()`: `Init` (2787), `ApplyScale` (2372), `PopoverTick`
  (3379), `DragStart`/`DragStop` (3421/3429), `ResetPosition` (3464), `SetPreview` (3493),
  `UpdatePopover` (3550), `Close` (3975), `OnCombatEnd` (4082), `AdoptLayout` (4124), `Update`
  (4460, the only path to `Rebuild`). Every `SetAttribute` is behind the same guard.
- The three consumers' only use of `ui:MainFrame()` is a read-only `GetPoint()` in their `pos`
  diagnostic (Priestly.lua:744, Wildly.lua:615, Magely.lua:579). All four call `ui:OnCombatEnd()`
  on `PLAYER_REGEN_ENABLED`.

What this pass added (#76, closing #73):
- `WoW.combatTouches` in the shared stub: every state write to a protected frame in combat,
  refused or not. `PROTECTED_METHODS` stays the measured refusal list; the new record is wider,
  so the window's own rule ("touches NOTHING in combat") is asserted without knowing which
  methods this build refuses. A `SetAttribute` in combat is now recorded and **not** stored,
  which is what the client does.
- The combat sweep in `test_ui_window.lua` now runs every handler the window installs (rows,
  popover rows, footer buttons, the minimize control, drag, close) and every entry point a host
  can reach (`Update`, `RefreshTimers`, `ApplyAppearance`, `ScheduleRefresh`, `SetPreview`,
  `AdoptLayout`, a queued `Open` flushed in combat, `OnCombatEnd` called early) against all three
  records. Automatic closes in `test_ui_window.lua` and `test_companion.lua` assert the records
  too, and `test_visibility.lua` drives `RosterChanged` emptying the group and `SoloToggled`
  against a real window mid-fight.
- AGENTS.md states the rule for hosts: `onVisibility`, `setVisible`, `onCloseDeferred`,
  `onMinimizeDeferred`, `onTick`, `onAppearance` and `setPos(nil)` run in combat and receive
  `ui`; `MainFrame()` hands out the protected frame with no guard; a host must never hide, move,
  resize, rescale or re-anchor it from a hook or a slash command.

Residual, decided in game by the `sweep` procedure: which of `SetAlpha`, `SetScale`, `SetSize`,
`SetWidth`, `SetHeight`, `SetFrameStrata`, `SetFrameLevel`, `SetShown`, `EnableMouse` the client
refuses on a protected frame (only hide, move, re-anchor, unclamp and stop-drag were measured, on
69913), and whether LibGlass's `SetWash` (reached in combat through `ApplyAppearance`, 3133/3145:
`g.wash:SetShown` on a *region* of the protected frame) is free. Nothing in the library calls the
unmeasured methods in combat today; the stub test is what keeps it that way.

Next step: close Wildly #42 as fixed by v1.0.0 (any user still seeing it is on v0.1.x and should
update); close Priestly #110 and Magely #53 as covered by construction, pointing at the sweep
test and the sweep procedure.

## Report A — everyone shows `?` in battlegrounds (#63; Priestly #107, Wildly #43, Magely #50)

**Classification: not reproducible at the desk; the client's behaviour inside a battleground is
unmeasured, and the library's output is honest for every state it can be in.**

How a `?` is produced, in r31 and r33 alike:
- **Range mark** (`rangeTxt`, beside the class icon, 3032-3034): `API.SpellRange` (376-389)
  returned UNKNOWN because `C_Spell.IsSpellInRange(name, unit)` answered nil or threw, or the unit
  does not exist. Range is checked by spell *name* (3008, 383); by name the client answers only
  for spells the player knows (measured, FOREVER-PROBE §8).
- **Time column and row** (`timeTxt` 3041-3043, row `missAll` 2982-2985, grey fill 2963):
  `BuffRem` (1560-1607) returned UNKNOWN because `ReadBuff` (289-340) said BLOCKED **and** the
  GUID-keyed cache has no entry for that member and buff. BLOCKED is: the index walk threw (333),
  the by-name path threw and the walk saw nothing (334), or the walk saw **no aura at all while
  `C_Secrets.ShouldAurasBeSecret()` is true** (338). The cache fills only on HAS or NONE.

The two marks are independent and a report that says "everyone shows `?`" needs to say which
(Priestly's `/priestly help` legend distinguishes them since v2.0.17; Wildly and Magely have no
legend). Pinned in `test_ui_window.lua` ("the two '?' are independent").

Hypotheses, each decided by one line of the `bg` probe sample:

| Id | Hypothesis | What the sample shows | If true |
|---|---|---|---|
| H1 | In instanced PvP the client keeps `ShouldAurasBeSecret()` true, or index reads throw, with no combat on, so the cache can never fill for members never seen outside | `aurasSecret`, `byIndex`, `lib.BuffRem` on the "before gates" sample | Honest UNKNOWN everywhere; fix A1: expose the read state so hosts can explain it, instead of a bare `?` |
| H2 | `IsSpellInRange` answers nil for teammates beyond visibility range, which in a battleground is most of them | `rangeName`/`rangeID` against `visible` on the "far member" sample | Fix A2: a member `UnitIsVisible` says is not visible is OUT_RANGE, not UNKNOWN |
| H3 | A member with no helpful aura at all reads BLOCKED while the flag is up, even where reads work | `byIndex=nil walk=1` together with `aurasSecret=true` and reads that do not throw | Narrow line 338 to the case the probe shows |
| H4 | `IsInRaid()`/`GetNumGroupMembers()` without `LE_PARTY_CATEGORY_INSTANCE` describe the wrong group, or `GetRaidRosterInfo(i)` names a slot whose `raidN` does not exist | `isInRaid`/`members` with and without the category; `raidN: absent` lines | Fix A4: category and `UnitExists` in `GatherGroups` (1745-1757) |

Also pinned, as current behaviour: the roster is not rebuilt in combat (`Update` 4460-4462 only
refreshes timers), so a battleground raid that churns mid-fight keeps old tokens; a newcomer in
an old slot is honestly UNKNOWN and an emptied slot reads as missing, and none of it touches a
protected frame. The secrecy flag held up out of combat (H1's shape) is pinned in
`test_engine_buffs.lua`.

The maintainer's suspicion that this is the non-English report in disguise does not fit the
symptom: a never-resolved name gives `?` in the range mark and **MISS** (not `?`) in the time
column, because the walk still completes. Both marks `?` for everyone needs blocked reads with
nothing cached, which is H1, or H1 plus H2.

Next step: the `bg` procedure (`/fp steps gb bg`), one battleground, after 2026-11-04. Ask the
reporter meanwhile: Priestly version, `GetLocale()`, whether the `?` is beside the icon, in the
time column or both, whether it was in combat, and whether it clears on leaving.

## Report C — non-English clients break (Magely #48; Priestly #111, Wildly #46)

**Classification: no library defect demonstrated. The pipeline is locale-proof once a name
resolves; the one failure mode left is a name that never resolves, which is silent and which two
of the three consumers give their users no way to see.**

Evidence:
- Names are resolved from spell IDs in `RefreshSpells` (1366-1393) through
  `C_Spell.GetSpellInfo(id).name`, which by ID works for spells the player does not know
  (measured, §8). After that every match is by the resolved name: the aura walk (175-178), the
  by-name fast path (300), the `UNIT_AURA` filter (1911), the range check (383), the secure
  buttons' `spell1`/`spell2` (3577, 3580, 4363, 4366). `UnitClass` is used by token, pets are
  bucketed by number. Nothing compares against the English literal.
- New tests drive a deDE client through all of it (`test_engine_buffs.lua` "A localized name,
  end to end", `test_ui_clicks.lua`): an aura under `Machtwort: Seelenstaerke` is HAS by the fast
  path and by the walk, the event filter accepts the German name and no longer the English one,
  `ClickSpells` and the button attributes carry the German names, the range check by the German
  name answers.
- The failure left: a form whose ID never resolved keeps the host's English literal
  (`from = "fallback"`). On a German client it matches no aura (every member MISS), the range is
  UNKNOWN (`?` beside every icon) and a click casts nothing, with no error anywhere. The next
  `RefreshSpells` that resolves repairs all of it. Pinned, with the repair.
- When could an ID fail to resolve? `C_Spell.IsSpellDataCached`, `DoesSpellExist` and
  `RequestLoadSpellData` exist on 70532, which says spell data can be uncached at the moment a
  host calls `RefreshSpells` (login). On an English client the fallback hides that. Unmeasured:
  the `spells` procedure records every consumer's IDs at each load phase across a cold relaunch.

Consumer-side findings (not library changes):
- **Wildly and Magely never call `engine:SpellReport()`.** Priestly prints it at the end of
  `/priestly help` (Priestly.lua:686), which is the one diagnostic that settles a non-English
  report. Magely #48's reporter cannot produce it. Each should add it (Wildly #46, Magely #48).
- Wildly's and Magely's `help` has no `?` legend; Priestly's does (v2.0.17).
- `SpellReport.unresolved` counts only `fallback`, not `unknown` (defs built by a pre-r16 copy):
  #77 added `report.unknown` (r34).

Next step: the `spells` procedure after 2026-11-04; ask the Magely reporter for `GetLocale()`,
the Magely version and whether buffs read as MISS, `?`, or clicks do nothing. A real localized
client run (a second game language installed through the Battle.net app) remains the only direct
evidence and is optional.

## Observations outside the three reports

- `PruneCache` (1504-1513) is never called by the library; all four hosts call it on roster
  changes. A remembered absence (`{ missing = true }`) has no age limit inside `BuffRem`: it is
  reported as `remembered`, by design, and `PruneCache` is what ages it. Pinned, not changed.
- Host hooks run in combat (see Report B); LibGlass `SetWash` is reached on a protected frame's
  region in combat and is unmeasured (sweep).
- Wildly's and Magely's own suites fail against the current shared stub for reasons that predate
  this audit: both expect the stub at build 70205 (it models 70338), and both lack the `.pkgmeta`
  ignore `Libs/LibGroupBuffs-1.0/Tools` that Priestly and Buffy carry (their `test_manifest`
  says so). Priestly's and Buffy's suites are green against this checkout.
- The consumers' `MINOR` pins: Priestly r31, Wildly and Magely r28, Buffy r33. Any fix from the
  gated table reaches a player as soon as one of their addons ships it.

## Gated fixes (after the in-game measurement)

| Id | Only if the probe shows | Change | Bump |
|---|---|---|---|
| A1 | H1: secrecy on out of combat inside the BG | `Methods:AuraReadState()` → `ok` / `combat` / `secret`, so a host can explain `?` | yes |
| A2 | H2: `visible=false` goes with `rangeName=nil` while visible members answer | `API.SpellRange`: not visible → OUT_RANGE (no new string; Codex consult: Compat tri-state) | yes + Codex |
| A3 | H3 | narrow line 338 to the measured case | yes |
| A4 | H4 | `GatherGroups` passes the instance category and requires `UnitExists` | yes |
| B1 | the sweep refuses something the library or LibGlass `SetWash` calls in combat | guard that site; the refused methods join `PROTECTED_METHODS` | yes if a call site changes |
| C1 | `spells` shows `GetSpellInfo(id)` nil / `IsSpellDataCached` false at a phase a host calls `RefreshSpells` | `Resolve` requests the data (pcall'd Compat wrapper); `RefreshSpells` returns the unresolved count; hosts re-call on `SPELL_DATA_LOAD_RESULT` | yes + Codex |
| C2 | `DoesSpellExist(id)` false for a consumer ID | provenance `absent`, excluded from `unresolved` | yes |

Measured facts go to `References/Docs/PORTING-TBC-TO-FOREVER.md` §3 and one AGENTS.md bullet
each; Priestly's `docs/FOREVER-PROBE.md` gets a note from a Priestly session.

## Review status

Every change went through a review loop until the reviewer said "Ready for merge". The method is
the `wow-addon-review` skill's; Codex ran it headlessly through `codex-consult`. While the Codex
quota was out (2026-11-01), a Claude Opus reviewer ran the same method as the skill's fallback.

Tests and probe (#76), in order:
1. **Codex round 1**: not ready. A screenshot step could fire before the window's scheduled open,
   and an interrupted sweep had no recovery. Both fixed: `openNow()` builds and shows at once,
   and the probe restores the window at every fight's end and on `/fp gb restore`.
2. **Opus round 1**: not ready, five findings, all taken. The serious one: inside the
   `PLAYER_REGEN_DISABLED` handler `InCombatLockdown()` is still false on this client (CastProbe
   70338), and ForeverProbe completes an event step there and runs the next `auto` step at once.
   The sweep would have run with lockdown off and measured nothing, and the battleground's "in
   combat" sample would have been taken at the fight's edge. Both are wait steps on
   `InCombatLockdown()` now. The spells check after a relaunch and the popover screenshots are
   wait steps for the same reason. The restore covers mouse state and anchor, and the probe host
   calls `ui:OnCombatEnd()` at every fight's end. In the stub, a combat `SetAttribute` is refused
   only on protected frames, the catch-all's methods count as touches, and the unmeasured
   refusals already in `PROTECTED_METHODS` (`SetAlpha`, `SetSize`, `SetScale`) are marked as such.
3. **Opus round 2**: ready, three optional notes taken. The popover steps say to hold the hover
   until the shutter, the sweep snapshots the window when it runs, and the anchor-restore test
   was made to bite. One left as is: a timed-out popover wait still saves a shot, which the
   step's FAIL flags.
4. **Codex round 2**: agreed with the Opus fixes after checking the step runner itself. New
   finding: running the sweep twice in one fight (Back is allowed) overwrote the first snapshot.
   Fixed: the snapshot is kept while a sweep is outstanding.
5. **Codex round 3**: ready.
6. **Codex review posted on #76**: not ready. A player who closed the window mid-fight after a
   sweep saw it reopen at combat's end, which Opus round 2 had judged intended. Fixed: the
   restore shows and rebuilds only a window that is still open.
7. **Codex follow-up**: ready. Merged.

SpellReport (#77): Opus found one optional point, which was taken: for r33 and later the
upgrade-loop position assertions check that the window is left unchanged. Codex then reviewed it
and found nothing. Merged.

Every regression fix was confirmed by mutation: reverting it turns its test red.

## What this pass changed

Merged into main on 2026-11-01 (b639c5c):
1. **#76** (closes #73, no MINOR bump): the stub seam, the regression tests above, the three probe
   procedures, `tests/test_probe.lua`, the AGENTS.md host-hook rule, and the CI skip.
2. **#77** (closes #75, MINOR 34): `SpellReport().unknown`.

Also:
3. **#74**: the in-game runs after 2026-11-04. Run `spells` first, since it needs a full exit,
   then `sweep`, then `bg`. The issue says where to read the results.
4. Comments on all nine report issues: the classification on #63, Wildly #42 and Magely #48, and
   a pointer on Priestly #107, #110, #111, Wildly #43, #46 and Magely #50, #53.

The library, Priestly and Buffy suites are green against the merged main. r34 is not tagged yet.
The release checklist comes first: Priestly pins b639c5c with `commit:` and the owner validates it
in game. Then tag r34, and freeze `tests/fixtures/LibGroupBuffs-r34.lua`.

## Questions for the reporters

- #63 (Priestly): version, `GetLocale()`, which `?` (beside the icon, in the time column, both),
  in combat or before the gates, does it clear on leaving the battleground, and the output of
  `/priestly help`.
- Magely #48: version, `GetLocale()`, and whether the symptom is MISS for everyone, `?` for
  everyone, or clicks that cast nothing. (Magely has no report command yet: see above.)
- Wildly #42: Wildly version; anything from v1.0.0 on cannot name `WildlyMain`.
