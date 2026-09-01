# Design runner contract

You are one of three parallel design runners, each on a different model. Produce one candidate
design for the BarCut work described in `.audit/grounding.md`. Read that file first, then
CONTEXT.md, docs/adr/0001-preserve-standard-screenshot-behavior.md, every file under Sources/BarCut,
and Tests/BarCutTests/ClipboardMonitorTests.swift. All are short. Do not change any of them.

Write your design package to the output path you were given, nothing else. Markdown, under 300
lines, plain words, no em dashes, no filler. Use these sections in this order:

1. Problem. One paragraph. What makes the shape non-obvious given the constraints in grounding.md.
2. Usage (caller's view). Write this before the types. Show how AppDelegate, ImageHistoryView, the
   annotation editor, and the tests would call the new model. Real Swift call sites, two or three.
3. Shape. Data structures first, as Swift type sketches with `fatalError("not implemented")`
   bodies or `// TODO` pseudocode. Then signatures and a module map (which file owns what). Name
   the load-bearing decisions: on-disk layout, identity/fingerprint, what stays in memory, which
   queue does what and how results re-enter published state, restore order at launch, crash
   safety, eviction and Clear versus files on disk, login item placement. State what the public
   interface hides and why it is no larger than needed.
4. Tradeoffs accepted. One bullet each, "we accept X in exchange for Y".
5. Alternatives considered. At least one structurally different shape and why it lost.
6. Open questions and risks.
7. Next implementation step. One sentence.

Discipline:
- Caller's usage first, derive types from it.
- Prefer a simple interface that hides substantial behavior over many small methods callers must
  coordinate. No pass-through wrappers. No temporal decomposition (load/validate/save modules).
- Encode invariants in types where cheap. Validate at the disk and pasteboard boundaries, trust
  types inside.
- All published state mutation on the main actor. Heavy work (decode, hash, thumbnail, file
  writes) off it, returning values, not mutating shared objects.
- Ask what happens if a write runs twice or the app dies halfway. Startup must converge.
- Delete what the new shape makes unnecessary. Smallest diff that is solid. No new dependencies.
- Be opinionated. Do not hedge toward a safe middle; differences between runners are the signal.
