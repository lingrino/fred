# Fred — maintainer guide

Fred is a personal macOS launcher + clipboard manager built for an audience
of one. Claude is the sole maintainer. Optimize for: latency first, then the
maintainer's understanding. Prefer changing code over adding settings — there is no
preferences UI and there should not be one.

This is the agent guide for any coding agent. Claude Code (v2.1.277+) reads it natively
when there is no CLAUDE.md, so don't add one: a CLAUDE.md here would shadow this file.

## Coming back after a break

Development is at a slow pace since 2026-11-15: features are done, Fred is in daily use.
To pick it up again:
1. Read this file, `git log --oneline -20`, and the memory notes. Check "Open decisions".
2. `sw_vers; swift --version`: if macOS or the Command Line Tools changed, read
   "What OS/toolchain updates can break" below before anything else.
3. `make check` (zero-warning build, unit tests, live smoke test against the installed
   app; no focus stealing). Fix what it reports before new work.
4. `make bench`: compares with `Benchmarks/baseline.tsv`, flags ≥20% & ≥0.5 µs slower
   (rerun once; medians wobble). `fredctl stats` shows the user's real latency. When the
   user is idle: `fredctl live run` and `fredctl hotkeybench 30` (on-screen checks).
5. Work → test of the right kind (see "Testing") → `make check` → `make install` → commit.
   If a benchmark moves on purpose, `make bench-save` and say why in the commit.

## What it does (and deliberately doesn't)

- **Launcher** (⌘Space): one ranked list (max 5
  rows) over apps, System Settings panes and the settings inside them ("True Tone" →
  Displays, from each pane's `.searchTerms`), system commands, Chrome bookmarks, contacts.
  Instant-answer row: calculator ("2+2"), else `Converter` (units, data sizes/rates,
  durations, time zones: "5 km in mi", "1 GiB to MB", "3pm pst in tokyo"; offline).
  Learns from picks (zoxide/Firefox-style). Enter = row 1 /
  selected row, ⌘1…⌘5 = row n, ↑↓/⌃N⌃P move, Esc closes, ⌘↩ reveals an app in Finder.
  Contact → card of phones/emails/addresses: Enter (or ⌘n/click) TYPES the value into the
  front app (keyboard events, clipboard untouched), ⌘C copies it and closes, ⌘↩ opens it
  (tel:/mailto:/Maps/URL), ⌘O opens Contacts.app. Esc always closes Fred.
  ⌘, (either panel) or the "Fred Settings" command → Fred Settings window: read-only
  health page (each privacy grant + "Open…" to its System Settings page, hotkeys, login
  item, index sizes, live CPU/memory/latency; 1 s timer only while open). Not a prefs UI.
  "Force Quit…" → running-app list. Moving the mouse over a row selects it (only real
  movement; rows changing under a still pointer don't steal the selection).
- **Clipboard history** (⌘⇧C): text, images, file lists; 90 days; token-AND substring
  search; Enter pastes into the frontmost app, ⌘↩ copies only, ⌘⌫ deletes, ⌘1…⌘9.
- **Not** in scope (user said so): file search/indexing, snippets, web search fallbacks,
  music, dictionary, password managers, workflows. Don't add them unless asked.

## User decisions (2026-11-14, kickoff)

- Hotkeys ⌘Space / ⌘⇧C (`AppDelegate.launcherKey`/`clipboardKey`; ⌥Space / ⌥⇧C until
  2026-11-15). A combination belongs to one app: if another app holds it, Fred retries
  every 2 s (`fredctl stats` → hotkeys).
- Clipboard pick pastes into the front app. Contact pick shows a card in Fred.
- macOS 27.2 is the minimum OS forever; high-end Apple Silicon only. Use RAM/cores freely.
- Stop and ask the user only for one-way doors or things only they can do (privacy grants).

## Build, run, test

```
make check         # lint + test + smoke — run before every commit
make lint          # debug+release+tests build with -warnings-as-errors (own scratch dir)
make test          # unit tests (debug, all runtime checks on)
make smoke         # scripts/smoke.sh: live checks against the running app via fredctl
make dev           # release build → /Applications/Fred.app, relaunch with --regular (Dock icon so computer-use can see it)
make install       # same, as the user runs it (accessory app, no Dock icon)
make bench         # FredBench over the real catalog, Δ vs Benchmarks/baseline.tsv
make bench-save    # …and make this run the baseline
scripts/fredctl …  # talk to the running app (see "Control socket")
```

### Testing — which kind for which change
- FredCore logic: Swift Testing unit tests in `Tests/FredCoreTests`. Ranking complaint →
  a test in `MatcherTests`/`RegressionTests` first; parsers → `ConverterTests`/
  `CalculatorTests`; storage formats → `ClipStoreTests`; invariants → `FuzzTests`.
- Hot-path speed: `make bench` (add a benchmark next to the code you touch).
- App integration (real sources on this Mac, grants, hotkeys, ranking on the real
  catalog, rendering, implicit animations): add an expectation to `scripts/smoke.sh`.
  Only stable system items — nothing that depends on the user's learning history.
- Looks: `fredctl snapshot <png> <q>`, `card <png> <q>`, `settings <png>`, then view the PNG.
- Focus/typing/hotkeys (can't be automated without taking the screen): computer use,
  only when the user is idle (see "Control socket").
- No formatter/linter beyond the compiler: style is consistent by hand and a reformat
  would bury `git blame`. Zero warnings is the rule (`make lint`).

Toolchain quirks on this machine (Command Line Tools only, no Xcode):
- `scripts/swift.sh` wraps `swift`: the CLT ships stale Feb-2024
  `PackageDescription *.private.swiftinterface` files that break every manifest; the
  wrapper points SwiftPM at a clean copy (`SWIFTPM_CUSTOM_LIBS_DIR`). Delete it when a
  plain `swift build` works.
- Tests need `-Xswiftc -plugin-path …/host/plugins/testing` (in the Makefile) because the
  default build system doesn't find the swift-testing macro plugin.
- `codesign` uses a self-signed identity ("Fred Local Signing") in a dedicated keychain
  (`scripts/setup-signing.sh`, password in `~/Library/Application Support/FredDev/`).
  This keeps the designated requirement stable so the user's privacy grants survive
  rebuilds. Never switch to ad-hoc signing or change the bundle id `dev.fred.Fred`.

## Privacy grants (user-only; check with `fredctl permissions`)

contacts (Contacts) · postEvents ("Device Control and Data Access" = Accessibility, for ⌘V)
· pasteboard (Paste from Other Apps = Allow) · chromeData (Files & Folders → Google Chrome;
macOS 27 blocks other apps from Chrome's profile dir) · finder (Automation, Empty Trash)
· loginwindow (Automation, Sleep/Restart/Shut Down).
Fred re-checks empty sources when the launcher opens, so grants given while running apply.
Fred Settings (⌘,) shows the same statuses.

**Never call AEDeterminePermissionToAutomateTarget or send Apple Events on the main
thread.** While a consent prompt is on screen they block (even with askUserIfNeeded=false,
from other threads) — that froze the whole app once. `Permissions.refreshAutomation` runs
on its own queue and main only reads the cached result; `Actions.sendToLoginWindow` and
`emptyTrash` dispatch to background queues.

## Architecture

```
Sources/FredCore/          pure logic, no AppKit — unit-tested, benchmarked
  Fold.swift               text folding (case/diacritics/separators) + word-start masks + char masks
  SearchIndex.swift        SoA index in ONE 128B-aligned allocation (masks/spans/starts/items/bytes)
  Matcher.swift            tiered matcher: EXACT 1300 > PREFIX 900 > WORDPREFIX 800 > ACRONYM 700 > SUBSTRING 500 > FUZZY 300 (+0…79 fine)
  Search.swift             TopK (inline storage), Ranking (kind prior, roles, learning blend, cutoff), Searcher (hot loop)
  Learning.swift           event log → frecency (14d half-life) + query→item associations (competition, prefix lookup, latch)
  Catalog.swift            merged items (SoA) + stable FNV keys + key→item lookup
  Calculator.swift         allocation-free recursive-descent evaluator
  Converter.swift          units/data/time-zone instant answers: byte-level parsing, offset math (no formatters)
  ClipStore.swift          clipboard history SoA + append-only log + images dir + search
  Disjoint.swift           @unchecked Sendable box for concurrentPerform buffers (disjoint writes)
  Sources/*.swift          AppScanner, SettingsScanner, Commands, ChromeBookmarks (Foundation only)
Sources/Fred/              the app
  main.swift               FredApplication (fast key dispatch to QueryField) + entry point
  AppDelegate.swift        wiring; startup order (indexer first, hotkey + panels, deferred checks)
  Engine.swift             catalog/searcher/learning/icon atlas/title atlas owner (main thread)
  Indexer.swift            background reindex (sources in parallel) on FSEvents / Contacts change / wake
  IconAtlas.swift          all icons pre-rendered (parallel) into one bitmap; rows use sub-images
  TitleAtlas.swift         all catalog titles pre-rendered as A8 masks (rows = mask + color layer)
  UI/Panel.swift           FloatingPanel: fixed-size non-activating window, Liquid Glass clipped by a mask,
                           present()/park() instead of order in/out; Theme constants; DevMode
  UI/QueryField.swift      custom single-line text input (fast path + NSTextInputClient for IME)
  UI/ResultList.swift      ResultList (NSView host) + RowLayer (pure CALayer row)
  UI/TextImage.swift       one-line Core Text → CGImage for dynamic strings; CALayer.still()
  UI/Launcher.swift        launcher controller: keystroke → search → rows, keys, modes, actions, latency stats
  ClipboardController.swift pasteboard polling, clipboard panel + preview, paste
  Actions.swift            open, system commands (loginwindow AEs, lock, Finder), ⌘V posting
  SettingsWindow.swift     "Fred Settings" health window (AppKit, plain NSWindow)
  LiveTests.swift          on-screen checks via posted key events: hotkeybench, typing, ⌘, (user idle only)
  ContactsSource / ContactCard / Permissions / LoginItem / HotKeys / ControlServer / Log
Sources/FredBench/         `fredbench scan` (what sources find), `bench`, `save` (baseline)
Benchmarks/baseline.tsv    p50 per benchmark (ns), compared by `make bench`
scripts/                   swift.sh (toolchain wrapper), bundle.sh, setup-signing.sh, fredctl,
                           lint.sh, smoke.sh, make-icon.swift
```

Data flow: Indexer (utility queue) → `Catalog` (immutable, Sendable) → main → `Engine.setCatalog`
→ `Searcher.setCatalog` + icon atlas rebuild if app list changed. Each keystroke:
`Launcher.queryChanged` → `Matcher.Query` → `Searcher.search` (learning boosts applied
sparsely) → `ResultList.set` — synchronous, same run-loop turn.

### Ranking (FredCore/Search.swift `Ranking`, Matcher.swift)
- Tier base + fine (0…79) + kind prior (app 20, command 15, settings 10, contact 5, bookmark 0).
- Entry roles (`Ranking.rolePenalty`): title; alias (−5 fine: file name, CFBundleName,
  command keywords); secondary (−100: bookmark host, contact org/email, hand-written
  settings/command synonyms); sub-setting title (−450); pane's own search terms (−495);
  sub-setting search terms (−500). Sub-settings fill rows under real apps/panes ("display"
  → Displays pane, then the "Display" sub-setting); with adjusted score < ACRONYM they
  count as weak for the relative cutoff. Branch-and-bound adds the role penalty to the
  floor, so sub-setting entries are mostly skipped once 5 good rows exist.
- Sub-setting terms shared by ≥4 settings ("privacy", "screen") or repeating a title word
  are dropped at scan time (`SettingsScanner.pruneKeywords`): noise and search cost.
- 1-char queries: EXACT/PREFIX (+WORDPREFIX except bookmarks). 2 chars: up to ACRONYM.
  FUZZY needs ≥3 chars, first char on a word start, ≤ m/3 gaps in the tightest window.
- Learning points `min(300, 15·log2(1+F) + 50·A)`, full for tiers ≥ ACRONYM, ½ substring,
  ¼ fuzzy. Latch (+5000) when one item owns an exact query. Weak results (substring/fuzzy,
  raw tier < ACRONYM) more than 350 below the best unpinned score are dropped; strong
  tiers are never cut ("lock" shows the exact "Lock" AND the prefix "Lock Screen").
- Tests in `Tests/FredCoreTests/MatcherTests.swift` (and `RegressionTests.swift`) pin the intended orderings. Add a test
  for every ranking complaint before changing constants.

## Performance rules

- Measure, don't guess: `fredctl stats` (keystroke→rows, hotkey→shown p50/p99),
  `fredctl query <q>` (search µs), `make bench`.
- Hot path (keystroke): no allocation, no String APIs, no locks, no dynamic dispatch in
  the loop over entries. Scratch buffers are owned by `Searcher` (note:
  `withUnsafeTemporaryAllocation` only guarantees the stack up to 1 KB).
- No caches. Precompute at index time (folding, masks, icon atlas) and rebuild wholesale;
  every source is cheap enough to re-read in full.
- FredCore builds with `-Ounchecked -enforce-exclusivity=unchecked` in release; debug
  builds/tests keep all checks — correctness is established by tests (incl. fuzz tests in
  `FuzzTests.swift`, regression tests in `RegressionTests.swift`). Preconditions vanish in
  release: guard limits explicitly. The app target (Fred) keeps normal release checks.
- Anything that indexes a catalog or clip list across time must survive a swap: rows keep
  item keys (resolve with `Catalog.item(forKey:)`), the clipboard list re-resolves by hash
  and refreshes on every store change while shown.
- Logs (learning, clipboard) truncate a torn tail before appending; never append after an
  unparsed tail.
- Panels are built once and only ordered in/out. No window animations, no implicit CA actions.
- Every Fred-created layer uses `CALayer.still()` (delegate `NoActions` vetoes ALL implicit
  animations — an `actions` dictionary missed the default "transition" on mask removal,
  which flashed a text-colored box on rows). Verify with `fredctl animcheck <q1>|<q2>`:
  it must report only the caret `blink`.
- **Never** wrap hot-path layer updates in `CATransaction.begin/commit`: when no implicit
  transaction is open yet (start of a key event), an explicit one is top-level and commits
  to the window server immediately (~200 µs each). Layers are created with
  `CALayer.still()` (actions disabled) instead; the keystroke does exactly one commit
  (`Launcher.commitNow`).
- Measured keystroke pipeline and why each piece is shaped the way it is: see
  "Latency notes" at the end of this file.

## Storage (`~/Library/Application Support/Fred/`)

- `learning.log` — "FRDL" v1; records `u32 time | u64 key | u8 row | u8 qlen | q`.
- `clipboard.log` — "FRDC" v1; ADD/TOUCH/DELETE records; compacted at load. `images/<hash>.png`.
- `control.sock` — dev socket.
Item keys: FNV-1a of (kind, payload); apps use bundle id (path fallback). Changing key
derivation orphans learned history — don't, or migrate.

## Control socket (`scripts/fredctl`)

`stats` (incl. per-stage latency), `resetstats`, `permissions`, `request`, `query <q>` (also
prints the instant-answer row and its µs), `settings [png]` (no arg: show the window — takes
focus; with a path: render it offscreen),
`snapshot <png> [q]` (renders the content layer tree offscreen — no glass — and
doesn't steal focus), `card <png> <q>`, `type <q>`/`show`/`hide`/`key down|up|esc`
(visible UI — **don't use while the user is active**, it takes keyboard focus), `shadow`,
`learn`, `reindex`, `dryrun on|off`, `clip search|show|pick <n>|snapshot|forget <q>`,
`animcheck <q1>|<q2>` (implicit animations on layers; alpha-0 panel, no focus).
On screen, **user idle only** (Fred posts real key events into its own panel; aborts if
the panel isn't key, so nothing reaches another app): `hotkeybench <n>` (n × ⌘Space →
type → hide; real show/keystroke latency per stage; result: `hotkeybench` again) and
`live run` (contact typing path with Unicode, ⌘, → Fred Settings, focus return; result:
`live`). Posted events reset HIDIdleTime: wait ~30 s and re-check idle between runs.

Interactive testing with computer use: `make dev` (Dock icon + Fred activates on show,
because the automation tool only types into the frontmost app). Check the user is away
first: `ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1e9)}'` (seconds idle).
Measure in production mode (`make install`) for hotkey latency; close the panel with
`fredctl hide` there (the tool can't send keys to a non-frontmost focused panel).

## Testing etiquette on the user's Mac

- The repo is public. Never commit the user's real data — contact names, bookmarks,
  clipboard text, learning history, query logs — in tests, docs, benchmarks or commit
  messages, even when debugging a real-world ranking complaint: reproduce it with
  fictional names.
  Push only `main`; other refs in this clone (e.g. `refs/codex/…` checkpoints) are
  local tool state.

- Never execute Sleep/Restart/Shut Down/Lock/Empty Trash/Force Quit for testing — use
  `fredctl dryrun on` or launch with `FRED_DRY_RUN=1`.
- Don't pollute clipboard history; remove test clips with `fredctl clip forget <q>`.
- Prefer `snapshot` over showing panels; the user may be typing in another app.

## What OS/toolchain updates can break

Fred leans on things Apple can change. `make smoke` notices most of them (source counts,
grants, hotkeys, known queries); `fredbench scan` shows what each source finds.
- Settings panes: `/System/Library/ExtensionKit/Extensions/*.appex` with the settings
  extension point, `x-apple.systempreferences:<bundle id>` URLs, `en.lproj/*.searchTerms`
  plists (sub-settings), `?Privacy_*` anchors (Fred Settings "Open…" buttons).
- Lock: private `login.framework` `SACLockScreenImmediate` (dlsym; logs if missing).
- Chrome bookmarks: `~/Library/Application Support/Google/Chrome/*/Bookmarks` JSON behind
  macOS 27 app-data protection (user grant).
- Clipboard: `NSPasteboard.accessBehavior` ("Paste from Other Apps"); paste/typing via
  CGEvent (`CGPreflightPostEventAccess`). Hotkeys: Carbon `RegisterEventHotKey`.
- Liquid Glass / `NSGlassEffectView` cost (re-measure with `fredctl hotkeybench 30` when idle).
- Toolchain: the CLT stale-interface workaround (`scripts/swift.sh`), the testing plugin
  path (Makefile), new compiler diagnostics (`make lint`). Signing keychain + password in
  `~/Library/Application Support/FredDev/` — losing it means a new identity, and the user
  must re-grant every permission (one-way door: ask first).

## Open decisions

None. (Resolved 2026-11-15: Liquid Glass is the only backdrop; numbers in "Latency notes".)

## Latency notes (measured 2026-11-14, M4 Max, macOS 27.2; `fredctl stats`)

Keystroke (p50): OS delivery ~0.4–1.5 ms (outside our control) → Fred ~0.76 ms in-process:
key handling ~0.28 ms (QueryField fast path + field text render) · search+rows ~0.04 ms ·
draw+commit ~0.44 ms (mostly the fixed CA→window-server commit). Hotkey → frame committed
~2.2 ms (becoming key ~1.2 ms of it). Search kernel alone (`make bench`, 2026-11-15): p50
4–21 µs over a 13.4k-entry index; the ~600 sub-settings (+2.7k entries, long strings) cost
~+3 µs on few-match queries. Converter: 0.04 µs for plain words, ~0.3 µs for digit
queries that aren't conversions, ~1 µs per unit answer, ~5 µs per time answer (it was
15/95 µs with String/DateFormatter/Calendar — keep it on bytes and offset arithmetic).

What was measured and why the code looks the way it does — don't regress these:
- NSTextField/field editor costs ~3.7 ms per key → `QueryField` (custom NSTextInputClient,
  fast path in keyDown, IME/dead keys via inputContext).
- NSApplication/NSWindow key dispatch ~100 µs → `FredApplication.sendEvent` hands plain
  key-downs for Fred panels straight to the field.
- Explicit `CATransaction.begin/commit` at the start of an event = an extra full commit
  (~200 µs) → never use them in hot paths; layers are `CALayer.still()`.
- Resizing a window: 1.3–2.6 ms → the window is fixed at max height; only the backdrop view
  resizes.
- Liquid Glass (NSGlassEffectView) re-renders on resize (~1 ms) and on every key-state
  change → one full-height glass view, never resized, clipped by a mask layer; panels are
  parked, not ordered out. On-screen A/B 2026-11-15 (`hotkeybench 30`, p50, five runs):
  ⌘Space→frame glass 5.3–6.4 ms vs vibrancy 3.4–3.6 ms (commit ~3 vs 0.7 ms); keystroke→
  frame ~2 ms both. The user chose glass at +2–2.5 ms (both < one 120 Hz frame); the
  earlier "~10 ms" no longer reproduces. Vibrancy code was deleted (git history).
- Ordering a window out discards its rendered state → panels are "parked" (ordered in,
  alpha 0, click-through, `canBecomeKey == false`) instead of ordered out.
- Row text rasterized per keystroke ~150 µs → `TitleAtlas` (all titles pre-rendered as A8
  masks, rows are mask + color layers).
- Rows as NSViews: AppKit bookkeeping on hide/show → rows are plain CALayer trees.
