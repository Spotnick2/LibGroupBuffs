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
  once: check the version guard, table identity across an upgrade, that instance functions
  dispatch through `lib.impl` at call time, and that nothing assumes one particular consumer.
- `C:\Projects\References\EMBEDDED-LIBRARIES.md` is the shared rulebook for embedded libraries
  (packaging, pinning, upgrade rules, tests); LibGlass-1.0 (`C:\Projects\LibGlass`) is the worked
  example this library now follows.

## What This Repository Is

`LibGroupBuffs-1.0` is the shared engine behind three WoW: Forever addons — Priestly, Wildly and
Magely — which are the same PallyPower-style group buff manager with different `DEFS` tables.
All three consume it. Changes are validated through Priestly first (the pilot), so keep them
class-agnostic from the start.

It is a **LibStub library**, embedded into each addon at package time through `.pkgmeta` externals.
It **depends on LibGlass-1.0**, which each consumer embeds *beside* it (`Libs\LibGlass-1.0`,
loaded first), never inside it.
There is no build system and no package manager; validation is a Lua 5.1 test suite plus in-game
testing through a consuming addon.

Target client: **WoW: Forever 1.60.1**, interface `16001`, `WOW_PROJECT_ID == WOW_PROJECT_MAINLINE`.
Vanilla content, Retail codebase.

## Layout

**One runtime file, `LibGroupBuffs.lua`** (since r26; r25 and earlier were six). One
`MAJOR, MINOR` literal and one `NewLibrary` guard at the top; `lib.ready = MINOR` (with
`lib.fileMinors.LibGroupBuffs`) on the **last line**. The former files are **sections**, each
wrapped in its own `do ... end` (`do -- Compat ===`, `Glass`, `Settings`, `Engine`, `UI`,
`Visibility`, `New`) so one section's private locals (`Methods`, `Fail`, `Call`...) can never be
captured by another, and so the main chunk stays far under Lua 5.1's 200-local limit. **A new
local belongs inside its section.** The only file-level locals shared between sections are
`GlassUsable`, `GlassInst` and `GLASS_MISSING`, assigned in the Glass section. Below, "Compat.lua"
and the like name those sections.

- **`lib:New(opts)`** — the per-addon entry point (the `New` section), shaped like LibGlass's:
  `LibStub("LibGroupBuffs-1.0"):New({ owner, report = function(text, kind), needs })`. It errors
  (a message for players, no file position) unless the active copy finished loading
  (`lib.ready`), LibGlass is usable and the active MINOR is at least `needs`; a dot call, a
  missing owner or reporter, or a second instance for the same owner are developer errors. The
  instance is **dot-called**: `Engine`, `UI` (the owner filled in when the host gave none),
  `Settings` (owner and reporter filled in when absent, never over the host's), `Visibility`,
  `RegisterEvents` (rejections reach the same `report(text, "events")`), `EventFailures`,
  `TimerColor`, `Pct`, `FmtTime`; and **data only**
  through `lib.shared`: `API`, `STATES`, `PET_GROUP`, `LOAD_CHECK_KEY`, `CLASS_ICONS`, `MINOR`.
  - Every instance function is `function(...) return lib.impl[name](inst, ...) end`, so an
    instance an older copy made runs the newest code. **Never** capture an impl function in
    anything that outlives the load, and never put a function in `lib.shared`: a host holding it
    would keep the copy that put it there.
  - `lib.impl`, `lib.instances`, `lib.shared`, `lib.instanceMT` keep their identity
    (`X = X or {}`). On load the newest copy migrates every instance by **adding** functions it
    lacks (`== nil`); it never replaces one, because a host may have wrapped it.
  - A new instance function: an `impl.X` plus an entry appended to `FUNCTIONS`. Never remove or
    rename one: within `LibGroupBuffs-1.0` the API only grows. Migration checks with `rawget`,
    because the instance reads `lib.shared` through `__index`.
  - Constructors go through `Construct`, which re-raises a constructor's argument error at the
    host's level (4). Without it the host's file:line is lost: the constructors' `Fail` raises at
    level 3, which through an instance is a library frame.
- **The pre-r26 surface is frozen, not removed:** `lib.API`, `lib.Engine.New`, `lib.UI.New`,
  `lib.Settings.New`, `lib.Visibility.New`, `lib.Status`, `lib.FILES`, `lib.fileMinors`, **and the
  named markers** `lib.compatMinor`, `glassMinor`, `settingsMinor`, `engineMinor`, `uiMinor`,
  `visibilityMinor`, all written as MINOR next to `lib.ready`. Hosts pinned to r25 and earlier
  call them on whichever copy is newest, and those from before `Status` (Priestly v2.0.5-v2.0.6,
  Wildly v1.0.0) refuse to start unless every named marker equals the active MINOR.
- **`lib.Status(needsMinor)`** answers "is this copy usable?" for those older hosts: `"ok"`,
  `"incomplete"` (the copy did not finish, an older copy's record survives under a newer active
  MINOR, **or LibGlass is missing or half-loaded**) or `"too-old"` (complete, just behind - nothing
  crashed, and a host must not say otherwise), plus the active MINOR. `lib.FILES` is now
  `{ "LibGroupBuffs" }`; an upgrade over r25 replaces the six-file list, so the old records stop
  counting. If a newer copy throws before the UI section, the previous copy's `Status` is still on
  the table and answers "incomplete", because the new `lib.FILES` has no record yet.
- `Compat.lua` — `lib.API`, every removed or moved API. **Nothing outside this section may call a
  moved API directly.**
- `LibGroupBuffs-1.0.xml` — the entry point a consuming addon references: `LibStub\LibStub.lua`,
  then `LibGroupBuffs.lua`. It lists **only files that exist**, and **never LibGlass**: consumers
  load it beside this library (`tests/test_packaging.lua` checks).
  `tests/harness.lua` loads exactly this list, so the suite fails the same way the client would.
- `Settings.lua` — `lib.Settings.New(spec)`: one write path for an addon's saved table
  (`Set`, `SetIn`, `Changed`), the SavedVariables-fix detector and the build watch
  (`HandleEnteringWorld`). The addon passes accessors for its own saved tables (the first is the
  settings store), its `measuredOnBuild` / `svBrokenOnBuild` constants and a required
  `report(text, kind)`. The library composes the plain-text messages, because the "full exit, not a
  relog" caveat is part of the detector being right; the addon adds its prefix and colour.
- `Engine.lua` — `lib.Engine.New(host)`: one engine per addon, holding its own GUID-keyed aura
  cache. Aura reads with the combat-secrecy fallback (`HAS` / `MISSING` / `UNKNOWN`), durations,
  the roster (`GatherGroups`, pets in `bucketSize` buckets from `PET_GROUP`), `ActiveDefs`,
  `MembersFor`, `GroupStat`, `PickTarget`, `ClickSpells`, `AuraEventIsRelevant`, `PruneCache`.
  Host seams: `defs` (ID-based: `id`, `snglID`, optional `grpID`), config accessors
  (`showSolo`, `trackPets`, `isBuffEnabled`), `isVisible(def, groups, ord)`,
  `membersFor(def, members)`, and duration storage (`learnDuration` / `learnedDuration`).
  Contracts worth knowing before changing it:
  - The addon calls `MembersFor` **once per row** and passes that list to `GroupStat`,
    `PickTarget`, its row and its popover, so they cannot disagree; an empty list means no row.
  - `PickTarget(members, def, anyValid, st)` reuses `st.byUnit` (no second aura read). UNKNOWN is
    never picked as missing, but can be the last-resort fallback. Range is checked against the
    spell the click actually casts. `anyValid` (group spell) only picks which spell is
    range-checked: the target is still the member who needs the buff most, because a row can
    span subgroups (a raid's pet bucket) and a group spell covers only the target's subgroup.
  - `RefreshSpells` updates the addon's defs **in place**; the defs table belongs to one engine.
  - The library has no frames or timers: the addon calls `PruneCache` (on roster changes) and
    throttles refreshes itself. Durations are stored by the addon, keyed by the spell name seen.
  - `AuraEventIsRelevant` keeps every payload touch inside one `pcall` and checks every def, not
    only visible ones.
  - **Aura passes.** Confirming a member does NOT have a buff costs a walk of their auras, so
    reading buff-by-buff walks each member once per buff. `BeginAuraPass()` / `EndAuraPass()`
    bracket a refresh: inside one, each member is walked once and every buff reads the answer
    out of it. `UI.lua` opens a pass around `RefreshTimers` and around `Update` (before
    `ActiveDefs`, so a host's visibility rule joins it), and a host reading auras of its own
    should go through `engine:ReadAura(unit, names)` rather than `API.ReadBuff` for the same
    reason. The boundary is the caller's on purpose: a pass that expired on a timer would be a
    cache going stale where nothing could observe it. **Do not widen a pass past one refresh** —
    inside one, a changed roster is deliberately not seen. Two rules it must keep:
    - A scan records only the names it was asked to match, so a pass answers only for its own
      union. A read for any other name **bypasses** the pass and goes live (`API.PassCovers`);
      without that, `ReadAura` with a host's own name list returns a confident absence for an
      aura the walk never looked for.
    - Both brackets close the pass **on a throw** as well as on return (`WithAuraPass` in
      `UI.lua`). Host callbacks run inside them and can throw; a pass that outlived a failed
      refresh would still be answering at click time, and replacing it at the next refresh is
      too late because the click comes first.
- `UI.lua` — `lib.UI.New(host)`: the buff window over an engine — main frame, one row per group
  per buff, the per-member popover, drag handle, close button, reagent footer and ticker. Host
  seams: `owner`, `title`, `version`, `appearance()` (icon and colour overrides — Wildly's orange
  header, Magely's per-spec colours), `unknownClassIcon`, `footerItems()` (data, not frames), config
  accessors (`alpha`, `locked`, `popoverSide`, `showClickHints`), position/visibility storage
  (`getPos` returning `pos, whyNil`, `setPos`, `setVisible`), `onCloseDeferred(ui, manual)`, and `onLayout` /
  `onVisibility` / `onTick` / `onAppearance` for a companion pane such as Magely's cooldowns.
  Contracts:
  - **Frames are anonymous.** The library creates no globals; tests and addons reach frames
    through the ui object.
  - **Every installed handler and delayed callback dispatches through the ui object**
    (`self._ui:Method()`), because handlers are installed once and a captured function would keep
    running the copy that installed it. Pool sizes: groups `8 + ceil(40 / bucketSize)`, rows
    `groups * #defs`, popover rows `max(5, bucketSize)` (player subgroups are never split).
  - **Combat: the window touches NOTHING.** Both frames parent secure buttons, which makes them
    protected, and the client refuses to hide, move, re-anchor, unclamp or stop a drag on one -
    silently, as an `ADDON_ACTION_BLOCKED` blamed on whichever addon's taint the call path carries.
    Parking the window offscreen, which this file did until r7, was blocked at the first call and
    never worked. So `Init` refuses, `Update` only refreshes visuals and remembers a show,
    handlers never write attributes, and `Close` (returns false), `ResetPosition` (false) and
    `DragStop` only record what the player asked for. `OnCombatEnd` does all of it, in that order.
    `Close` bumps a generation so a show queued earlier (`Open(delay)`) cannot reopen the window.
  - **A deferred close is always reported** while the frame is still on screen, whoever asked
    for it: the X button, a slash command, or the addon's own automatic close (the group emptied,
    "show when solo" unticked mid-fight). The host gets `onCloseDeferred(ui, manual)`, and **what
    it says is the host's choice**. The library reports; the addon decides whether the player
    hears it. Staying silent when `manual` is false is a legitimate choice: a window that stays
    up through the fight is what a buffer wants (it shows who needs a rebuff), and it goes once
    combat ends. Answering the player's own X (`manual` true) is the case worth a line. It is said once per pending close **and kind**: the player's
    X after an automatic close in the same fight is answered too, and a manual explanation covers
    the rest of that fight. `manual` also decides whether the close is saved as the player's
    preference (`setVisible(false)`). Until r27 automatic closes said nothing (#45). An r26
    copy's latch, `true`, reads as manual. **A host that does speak for automatic closes should
    word the two kinds differently**: one that prints the same line for both prints it twice when
    the player clicks X after an automatic close in the same fight. That is deliberate: the click
    is answered, as it was before r27, and staying silent was the round-1 defect on #53. A host
    that ignores `manual == false` keeps r26's behaviour exactly. A show queued in combat (the
    window wanted again) clears the latch, so a close after it is explained again. Known limit:
    the explanation for an automatic close can be overtaken by such a show in the same fight,
    and then the window stays after combat.
  - **A show out of combat supersedes a close recorded in combat:** `Rebuild` clears
    `closePending` when it shows the window, so an `OnCombatEnd` handled late never hides a
    window that is logically open.
  - **Companion panes (#24, r27).** An addon's own frame under the window, like Magely's
    cooldowns, uses only the window's hooks (rules also in the UI section's header):
    - **non-secure, parented to UIParent, anchored to the window**. That is the shape measured
      free in combat (70009, Spotnick2/Magely#12). A child of the window was not measured, and
      would hide with it and take its alpha. (Protection spreads to a secure frame's
      *ancestors*, not its children, so "a child would be protected" is not the reason.)
    - **anchored, sized and scaled in `onLayout`**, which ends every out-of-combat rebuild. As
      UIParent's child the pane copies `main:GetScale()`, or its width is wrong on screen.
      `onLayout` does not run in combat.
    - **visibility follows `ui:IsVisible()`** through `onVisibility`: a close in combat hides the
      pane at once, while the window's frame waits for the fight's end. On the **first** show,
      `onVisibility(true)` arrives just before the first `onLayout`, so it finds no pane: guard
      for that.
    - **`onTick(ui, elapsed)`** is a refresh cadence on the window's half-second tick, in and out
      of combat, only while it is visible, restarting at 0 on every show (the footer's clock
      too). It runs **last** in the tick, so a host error cannot skip the window's own refresh.
      `elapsed` is visible time, not wall time: count cooldowns from `GetTime()`.
    - **`onAppearance(ui)`** runs when the look changes **outside** a rebuild (alpha or scale
      slider, spec change) and only after the first `onLayout`. A window this copy built starts
      at `laidOut = false`; only a window an older copy built (`laidOut == nil`) counts as laid
      out by being open. `visible` alone must never stand in: on the first show
      `onVisibility(true)` precedes `onLayout`, and a host may call `ApplyAppearance` from it.
      A rebuild calls `ApplyLook`
      directly and ends in `onLayout`, where the pane takes the look too.
    - Host callbacks are not wrapped in `pcall`: a throwing `onTick` is the host's script error,
      every half second, and the library does not hide it.
    `tests/test_companion.lua` builds one and runs every hook.
  - **`Open` coalesces**, like `ScheduleRefresh`: the events that open a window arrive in pairs
    (`RAID_ROSTER_UPDATE` with `GROUP_ROSTER_UPDATE`, `PLAYER_TALENT_UPDATE` with
    `SPELLS_CHANGED`) and each queued `Update` is a full rebuild. The earliest pending deadline
    wins, so a sooner request supersedes a later one rather than being dropped. A host cannot do
    this for itself: it would have to call `Update` directly and lose the generation check.
  - **The addon keeps policy:** events, slash commands, who the window opens for, and when.
- `Glass.lua` (the Glass section) — **the material is LibGlass-1.0**
  (github.com/Spotnick2/LibGlass, contract in its `CLAUDE.md`). Up to r25 this was a v1 copy
  with 14 textures of its own; there is no `Media/` here any more. **A material change is a
  LibGlass PR**, never a local patch. The window reaches it only through `GlassInst()`, at call
  time: one LibGlass instance per session, created on first use and kept on `lib.glass` across
  upgrades of this library (LibGlass migrates its own instances). `GlassUsable()` (LibGlass
  registered AND its `ready` equal to its active MINOR) gates `GlassInst`, `lib.Status` and
  `lib:New`, so a copy shipped without LibGlass, or one whose LibGlass threw mid-load, says so
  instead of failing somewhere obscure. The window uses `Apply`, `Mask`, `MEDIA`, `STYLE` and the
  regions `g.tint` / `g.rim` / `g.mask` / `g.shadow` / `g.top`, all in LibGlass's contract.
  `MEDIA` is LibGlass's, derived from the host addon that loaded the winning LibGlass copy.
  Colours passed to a glass bar's `SetStatusBarColor` must be plain (LibGlass's hook compares
  them). Panels an r25 copy built keep their v1 regions (opaque rim) until `/reload`: nothing
  repaints them, and `TintPanel` / `RimColour` only touch `g.tint` / `g.rim`, which both have.
  **Only building needs LibGlass**: a window already built keeps refreshing without it
  (`TintPanel` falls back to the tint alpha v1 and LibGlass r1 share), so one addon's packaging
  mistake cannot stop another addon's working window. `Init` checks LibGlass **before** assigning
  anything to `self`, because it returns early once `self.main` exists, and a window that threw
  halfway through building would otherwise stay half-built.
  - **Geometry is adopted too, not only looks.** Frames are built ONCE - `Init` returns early when
    `self.main` exists - so a window an older copy built reaches newer code with the previous
    sizes, fonts and icons while every position the newer code computes is measured against metrics
    those frames do not have. `Methods:AdoptLayout` brings them up: it runs before anything is
    placed, once per window (`main._layout`), and refuses in combat. Its parts are the `Style*`
    helpers, which are separate from the `Make*` builders precisely so both paths share them and
    stay idempotent. **A change to the metrics means bumping `LAYOUT` and covering it in
    `tests/test_versions.lua`, which builds a window from the previous tag's fixture and upgrades
    it in place.** Fresh construction passing proves nothing about this.
  - **Adoption is on demand, never at load.** A host upgrading in place hands the new code the OLD
    frames, already wearing an r16 backdrop or an r17 StatusBar fill. `Panel` and `Fill` clear
    what they find before they draw, and both refuse in combat, because the window's frames are
    protected. A texture created in the wrong place is not a cosmetic bug: **a child frame draws
    above its parent's regions whatever the draw layer says**, which is how the r17 fill washed
    every class icon green in game with a green suite behind it. Fills are drawn on the row.
  - **A mask small in BOTH directions must not be sliced.** A sliced `MaskTexture` on a ~20px
    square box makes the masked texture draw a fragment of its art in the top-left corner and
    nothing else; unsliced, the asset scales and is correct. It is not about being short — the same
    mask *sliced* is fine at 123x26 here and at 300x12 and 330x7 in GlassUnitFrames. Every failing
    case is small both ways; which axis decides has not been measured. Slice margins themselves are
    in texture pixels and **must match the generator** (`bar_mask` is 32px, radius 5, margins 8):
    scaling a margin down to fit a small box cuts through the corner arc, which is a second wrong
    thing that hid behind the first. `tests/test_ui_window.lua` walks
    every region the window builds and fails on a sliced mask narrower than the asset. Four other
    explanations for this were deployed as fixes first and none was it — the note in
    `PORTING-TBC-TO-FOREVER.md` records the method that ended it, which is worth more than the
    fact: when a rendering symptom has several plausible causes, **deploy a comparison, not a
    fix**. A window that draws the same widget five times is already a test rig.
  - **Geometry follows the material, not the other way round.** A row shorter than about twice the
    mask's 8px corner radius has its corners squeezed flat and reads as a painted rectangle again,
    which is what the first pass at `ROW_H = 15` looked like. Every string goes through `Style()`:
    a string left on a Blizzard template is one line in the wrong typeface with no shadow, and on
    a translucent panel a light letter lands on a light patch of the world. The tests check both,
    because neither is visible to any other assertion.
- **`def.groupScope`** — how far the GROUP form reaches: `"raid"` (the default) or `"party"`. On
  Forever every group buff measured covers the whole raid, which is not what Vanilla or TBC did and
  not what a window drawing one row per subgroup assumes. Declared by the host, because the tooltip
  that says so is a localized string and the only alternative is to assume — silently wrong the day
  a party-only group buff exists. For a raid-wide def, `Engine:PickRaidTarget` aims across the whole
  roster and answers **nil once nobody needs it**, which is what stops eight subgroup rows spending
  eight reagents on one cast (#19); `PickTarget` still always answers with somebody, which is right
  for a cheap single-target top-up and wrong for this. Refreshing a raid-wide buff early is
  deliberately not offered.
- `Engine:RefreshSpells` resolves names from IDs, and records **per form** how each was arrived at
  — `resolved` (the client answered), `remembered` (it did not, but an earlier refresh did) or
  `fallback` (never has: this is the host's English literal) or `unknown`. The fallback stays,
  because on an English client it is correct and on any other it simply never matches; what it
  hides is the failure, which is why `Engine:SpellReport()` exists. Never infer a failure by
  comparing a name to the literal: a locale that leaves a spell untranslated resolves to exactly
  that string.
  `unknown` is the upgrade case, and the reason `Engine.New` stamps every def it accepts: a def
  reaching `RefreshSpells` **unstamped** was built by a copy older than r16, so the name in it may
  already be one the client gave that copy. Reporting it as the host's English literal would call
  a correctly localized addon broken. Unstamped is not the same as never-resolved, and only
  stamping at creation lets the two be told apart.
- `Visibility.lua` — `lib.Visibility.New(spec)`: **when the window opens itself, and when it must
  not.** The addon still owns its events, its slash commands and its class; it reports what changed
  (`Login`, `ReadyCheck`, `GroupJoined`, `RosterChanged`, `SoloToggled`, `ContentChanged`) and this
  decides whether that warrants opening, closing or refreshing.
  - **This is the exception to "the addon keeps policy", and it was earned.** Three near
    line-for-line copies produced five defects — a roster after login counting as a join, a settings
    change reopening a deliberate close, a solo toggle dropped in combat, and two more — each found
    in one addon, fixed there, and left standing in the others (#22).
  - **Preference is not visibility.** `getPreference` is the saved "the player wants this window"
    (true / false / **nil for never said**); `ui:IsVisible()` is whether it is logically open now.
    They disagree constantly: in combat the frame can still be on screen after a close, and a window
    that closed itself for want of rows never wrote false — which is exactly what lets
    `ContentChanged` reopen one and not the other. **Never cache the preference**: the close button
    and the addon's slash commands change it without passing through here.
  - **`ContentChanged` is one method on purpose.** A setting, a spell learned, a tank appearing, an
    aura landing — the decision is identical, and splitting it is what left a copy of `WantsOpen` in
    each host's handlers. Whether the notification is *meaningful* stays with the host: Magely does
    not report an aura in combat, because an aura cannot be read then.
  - `lastGroupSize` is **nil until a roster is seen**, and a join is a 0-to-n change where the 0 was
    observed. Only `Login` resets it — an upgrade must not, or a session that has watched a roster
    forgets it. Test upgrades with an object that has already observed one.
- `Settings` — whether saved settings came back is decided by **the marker's own build**, not by
  any constant. The marker records the build it was written on; a build only changes when the
  client is patched, and applying a patch requires a full exit, so a marker returning under a
  *different* build cannot be the client's in-process cache. Same build says nothing — that is
  what a relog to character select looks like, and no clock helps, since `GetTime` here is system
  uptime and does not reset across a restart. Once a restart has proven loading, the marker
  latches `loads` and carries it while it keeps coming back, so later patches on a healthy client
  say nothing. A regression drops the marker, and the latch with it, so the next fix is announced
  again. Each scope names its own marker's build. `svBrokenSince` / `svBrokenOnBuild` are
  accepted and **unused**; hosts may drop them.
- Planned, not yet present: the options-panel widgets (`SafeFrame`, `MakeCheckButton`, tabs).
- `LibStub/` — bundled, unmodified, public domain.
- `tests/` — Lua 5.1, no game client. Two files are also used by consumers, `dofile`d from their
  library checkout (neither is shipped):
  - `tests/config_scan.lua` — fails their run on a write to their SavedVariables outside a
    `config-owner` region.
  - `tests/wow_stubs.lua` — the stub itself. A host sets `WoW.SetPlayerDefaults` (it is not a
    priest), `WoW.allowGlobal(...)` for its own globals, and defines any API only it calls. Both
    work after the file has run, which is the only order a host has. Keeping a copy is what let
    Priestly's drift out of the combat refusal model, so every refusal measured here is measured
    once. `tests/test_stub.lua` is that contract: the seam and the returns hosts read.
    `WoW.build`'s default is the **installed client's** build (`.build.info` in the World of
    Warcraft root names it without launching the game), never a host's `measuredOnBuild`: hosts
    re-probe at different times, and one can be sitting on an older measured build deliberately,
    with its login notice firing. Bump it here when the client moves, and the date in
    `GetBuildInfo` with it. Take the date from the build-date string embedded in the client
    executable (`_classic_beta_/WowB.exe`), which the API dump's header repeats. Don't use the
    file's modified time: it is when the patch was applied, and for 70009 it is a day later.
- `.pkgmeta` — **not for publishing** (the library never is): its `ignore` list decides what the
  packager copies into each consuming addon's `Libs/LibGroupBuffs-1.0`. Only runtime files and
  `LICENSE` ship. `tests/test_packaging.lua` checks nothing the XML loads (following `<Include>`) is
  ignored, and that every file `git ls-files` lists is either loaded, `LICENSE`, or ignored — so a
  new file that is not runtime code fails the suite until it gets an entry here. **CurseForge's
  packager does not apply this list** (Priestly #53), so each consumer repeats the non-dot entries
  under `Libs/LibGroupBuffs-1.0/` in its own `.pkgmeta`. It also checks that every texture the code
  names exists in the LibGlass checkout's `Media/`, and that no texture is tracked here again.

## Library Rules

- **Never print, and never let a failure be silent either.** A library has no business writing to
  somebody else's chat frame, so it hands failures to the consumer to report. Where ignoring the
  return value would silently lose one, take the consumer's reporter and refuse to run without it:
  `API.RegisterEventsReported(frame, owner, report, ...)` errors if `report` is not a function, and
  records failures per consumer in `API.eventFailuresByOwner[owner]`. `API.RegisterEvents` stays for
  consumers pinned to an older tag.
- **No globals** beyond what LibStub requires — including frame names: `UI.lua` creates its frames
  anonymous, and `test_ui_window` fails if building the window adds a global. No `_G` injection: defining a real `GetItemInfo`
  changes capability detection for every other addon on the machine.
- **No addon-specific behaviour.** Anything that differs between Priestly, Wildly and Magely
  belongs in the addon or behind a host callback, not in a branch here.
- **Version bumps:** raise the one `MINOR` in `LibGroupBuffs.lua` whenever behaviour changes, in
  the same PR, so an older embedded copy loses to a newer one, and tag the merge `r<MINOR>` for
  consumers to pin. `LibStub:NewLibrary` returns nil when an equal or newer copy already loaded.
  `tests/test_versions.lua` checks the literal appears exactly once and `lib.ready = MINOR` is the
  last line.
- **An upgrade reuses the existing tables.** A newer copy loading after an older one gets the same
  `lib` and `lib.API`, so write `X = X or {}` for anything holding state (see `eventFailures`), and
  never replace a table other code may have taken a reference to. `tests/test_versions.lua` checks
  equal-after-equal, older-after-newer and newer-after-older against the real released source in
  `tests/fixtures/`: `<File>-rN.lua` per file up to r25 (the last multi-file release), and from
  r26 on **one fixture per release**, `LibGroupBuffs-rN.lua`. When a tag goes out, freeze it there
  for the next MINOR's upgrade test (`git show rN:LibGroupBuffs.lua`). While the source still
  declares that MINOR, `test_versions` requires it to equal the fixture, so a behaviour change
  merged without a bump fails rather than shipping as a second, different `rN`; never synthesise the older copy from the current source,
  since it would already contain what the upgrade must add. (A synthetic NEWER copy - the current
  source with MINOR+1 - is right for testing what an upgrade does to this copy's objects.) Objects
  handed to consumers hold a shared metatable whose methods table is assigned in place, so an
  upgrade reaches objects an older copy created.
- **A copy that throws partway leaves `NewLibrary` already counting its MINOR**, with the older
  copy's functions and marker still on the shared table. So `lib.ready` is the last line, and every
  entry point compares it with the active MINOR - **equal**, never merely set. Released r2-r25
  copies keep their own per-file guards (`lib.<file>Minor`, `lib.fileMinors.<File>`), which still
  reject them correctly when they load after a newer copy.

## Client Rules (measured, not inferred)

- **Three sources, three questions.** The dump (`C:/Projects/References/forever-api-<build>.md`)
  says what **exists**. A probe in game says what **works**. And `C:/Projects/wow-ui-source` —
  Blizzard's shipped Interface code for this exact build, with `version.txt` naming it — says what
  the client's **own UI does and depends on**. That third one closes the gap behind "a function in
  the dump is not a working function": if the shipped UI registers an event and acts on it, it
  fires (`GROUP_JOINED` was settled that way). It also explains a dump *miss* that is not an
  absence — `SetBackdropColor` is FrameXML Lua, not the C API. It settles nothing below Lua: a mask
  that renders as a fragment is a renderer question, and only a screenshot answers those.

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

**LibGlass comes from a checkout:** `$env:LIBGLASS`, else `..\LibGlass`. `tests/run.ps1` warns
when it is not at the ref in `tests/libglass-ref.txt`, which is what CI fetches; the harness passes
`(host, ns)` to every chunk as the client does (`H.HOST`, "Priestly"). Tests of LibGlass being
absent or half-loaded load it themselves (`freshLibStub(true)` in `test_versions.lua`).

`tests/wow_stubs.lua` is an **allowlist**: it fails the run on the read of any global it does not
define. That only works if it also models the client's absences and shapes honestly — a stub more
forgiving than the client lets broken code pass a green suite, which is how a call to the removed
`MouseIsOver` shipped once. Before stubbing a new global, confirm it exists in the newest
`C:/Projects/References/forever-api-<build>.md`, and stub it with the client's exact signature.

Strict globals only catch what actually runs, so every script handler the library installs needs a
test that executes it.

**Methods are strict too, since #34.** A frame answers an unknown PascalCase key with an error, not
a silent no-op — the no-op is how a call to `GameTooltip:SetItemByID`, which this client does not
have at all, passed a green suite and failed only in game. Confirm a method in the build dump, then
implement it or add it to `KNOWN_METHODS`; if it is not in the dump, the caller is what needs
fixing. `WoW.allowMethod` is the host's escape hatch, and it is for methods you have checked, not
for quieting a failure.

A key that is **not** PascalCase reads nil, because it is the addon's own field and an unset field
is nil. That matters more than it sounds: while the stub handed back a callable, `if not f.iconEdge`
was false under test and true in the client, so guards had to be written `type(f.iconEdge) ~=
"table"` to work at all, and four assertions written in one afternoon could not fail. PascalCase
members a Blizzard template would have created (`Left`, `Text`, `Low`, `High`) read nil for the same
reason — `Tools/PriestlyProbe` decides whether a template applied by asking whether `frame.Left` is
nil, and the catch-all answered yes every time.

`tests/harness.lua` loads LibGlass, then exactly what `LibGroupBuffs-1.0.xml` lists, in order,
and fails on anything missing — the same way the client would. `tests/test_versions.lua` loads the
library in three orders to check an upgrade keeps table identity and state, and covers `lib:New`
instances across an upgrade (held functions run the newer code exactly once, a newer copy only
adds, a copy throwing mid-load is refused). `tests/test_new.lua` covers the entry point itself.
Mutation-test changes to either: capture an impl function, share a per-owner registry, replace
`lib.shared` or `lib.impl`, drop the `ready` or LibGlass check - each must turn a test red.

`tests/test_ui_clicks.lua` and `test_ui_window.lua` cover the window: every handler it installs is
executed and its effect asserted (the stub records text, textures, anchors, tooltips, and every
`SetAttribute` made while `WoW.inCombat`, in `WoW.combatWrites`). A new handler needs a test that
runs it.

`tests/test_engine_buffs.lua` and `test_engine_rows.lua` are Priestly's engine tests ported with
the same scenarios and expectations (`H.PriestEngine` builds a Priestly-shaped host), plus hosts
shaped like Wildly (a single-only, tank-filtered Thorns) and Magely (two optional buffs) — the
seams exist for them, so test them there.

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

Consumers pin a tag, so nothing reaches them until one exists. The checklist is
`EMBEDDED-LIBRARIES.md` §9:

1. Raise `MINOR` for any behaviour change, in the same PR. The PR's tests are green, and so are
   the pilot consumer's (Priestly) against the merged commit: `pwsh ..\Priestly\tests\run.ps1`.
2. After merge, the pilot validates **that exact commit** in game, pinned by `commit:` in a
   Priestly PR.
3. Tag the merge commit `r<MINOR>` and push the tag: `git tag r26 && git push origin r26`. The tag
   and `MINOR` must match. The pilot switches its pin to `tag: r<MINOR>` and reruns its CI before
   it releases.
4. Freeze the release as `tests/fixtures/LibGroupBuffs-r<MINOR>.lua` for the next MINOR's upgrade
   test.
5. **The other consumers bump their pin in their next release, not now.** No fan-out of PRs:
   players get the fix as soon as any one of their addons ships it, because LibStub runs the
   newest copy loaded.

Never move or reuse a tag once pushed: a consumer's release is pinned to it. The same goes for
LibGlass: this library's tests pin it in `tests/libglass-ref.txt`, and a consumer pins it in its
own `.pkgmeta`.
