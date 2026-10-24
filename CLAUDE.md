# Claude Instructions

Read [AGENTS.md](AGENTS.md) for project-specific agent instructions.

## Consulting Codex

The shared `codex-consult` skill (user level) has the invocation and the gotchas. For this repo:

For LibGroupBuffs specifically, good things to hand Codex: a change to a contract in `Compat.lua`
(especially struct-vs-tuple or a tri-state return), anything touching version handling or table
identity across an upgrade, and the design of a host interface - what belongs in the library and
what each consumer (Priestly, Wildly, Magely) must supply. Point it at the consumers too: Priestly
at `C:/Projects/WoW/Priestly`, and the unported TBC siblings at `C:/Projects/WoW/Wildly` and
`C:/Projects/WoW/Magely`, which are the only check that a seam is not shaped around Priestly alone.

**Always hand it `AGENTS.md` and Priestly's `docs/FOREVER-PROBE.md` alongside the diff.** Those
findings are measured on the live client, and a cold reviewer will otherwise argue from Classic-era
or Retail behaviour that does not hold here - that auras throw for the whole group in combat, that
no SavedVariables survive a restart, that the client's secure handler decides which mouse edge
acts. The newest `C:/Projects/WoW/References/Forever/api/forever-api-<build>.md` is the full measured API surface if
a question turns on whether something exists.
