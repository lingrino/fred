# Fred — maintainer guide

Fred is a personal macOS launcher + clipboard manager built for an audience
of one. Claude is the sole maintainer. Optimize for: latency first, then the
maintainer's understanding. Prefer changing code over adding settings — there is no
preferences UI and there should not be one.

## What it does (and deliberately doesn't)

- **Launcher** (⌥Space for now; ⌘Space later — see "Hotkeys"): one ranked list (max 5
  rows) over apps, System Settings panes, system commands, Chrome bookmarks, contacts.
  Inline calculator ("2+2"). Learns from picks (zoxide/Firefox-style). Enter = row 1 /
  selected row, ⌘1…⌘5 = row n, ↑↓/⌃N⌃P move, Esc closes, ⌘↩ reveals an app in Finder.
  Contact → card of phones/emails (Enter copies, ⌘O opens Contacts.app).
  "Force Quit…" → running-app list.
- **Clipboard history** (⌥⇧C): text, images, file lists; 90 days; token-AND substring
  search; Enter pastes into the frontmost app, ⌘↩ copies only, ⌘⌫ deletes, ⌘1…⌘9.
- **Not** in scope (user said so): file search/indexing, snippets, web search fallbacks,
  music, dictionary, password managers, workflows. Don't add them unless asked.

## User decisions (2026-11-14, kickoff)

- Hotkeys ⌥Space / ⌥⇧C for now; the user moves Fred to ⌘Space / ⌘⇧C when ready (then
  change `AppDelegate.launcherKey`).
- Clipboard pick pastes into the front app. Contact pick shows a card in Fred.
- macOS 27.2 is the minimum OS forever; high-end Apple Silicon only. Use RAM/cores freely.
- Stop and ask the user only for one-way doors or things only they can do (privacy grants).

## Build, run, test

```
make test          # unit tests (debug, all runtime checks on) — run before every commit
make dev           # release build → /Applications/Fred.app, relaunch with --regular (Dock icon so computer-use can see it)
make install       # same, as the user runs it (accessory app, no Dock icon)
make bench         # FredBench: search micro-benchmarks over the real catalog
scripts/fredctl …  # talk to the running app (see "Control socket")
```

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
macOS 27 blocks other apps from Chrome's profile dir) · finder (Automation, Empty Trash).
Fred re-checks empty sources when the launcher opens, so grants given while running apply.

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
  ClipStore.swift          clipboard history SoA + append-only log + images dir + search
  Sources/*.swift          AppScanner, SettingsScanner, Commands, ChromeBookmarks (Foundation only)
Sources/Fred/              the app
  AppDelegate.swift        wiring; startup order (hotkey + panel first, indexing async)
  Engine.swift             catalog/searcher/learning/icon atlas owner (main thread)
  Indexer.swift            background reindex on FSEvents / Contacts change / wake
  IconAtlas.swift          all icons pre-rendered (parallel) into one bitmap; rows use sub-images
  UI/Panel.swift           non-activating glass NSPanel + Theme constants
  UI/ResultList.swift      fixed pool of self-drawn rows (Core Text, no AutoLayout/table)
  UI/Launcher.swift        launcher controller: keystroke → search → rows, keys, modes, actions
  ClipboardController.swift pasteboard polling, clipboard panel + preview, paste
  Actions.swift            open, system commands (loginwindow AEs, lock, Finder), ⌘V posting
  ContactsSource / ContactCard / Permissions / LoginItem / ControlServer / Snapshot
Sources/FredBench/         `fredbench scan` (what sources find) and `fredbench` (benchmarks)
```

Data flow: Indexer (utility queue) → `Catalog` (immutable, Sendable) → main → `Engine.setCatalog`
→ `Searcher.setCatalog` + icon atlas rebuild if app list changed. Each keystroke:
`Launcher.queryChanged` → `Matcher.Query` → `Searcher.search` (learning boosts applied
sparsely) → `ResultList.set` — synchronous, same run-loop turn.

### Ranking (FredCore/Search.swift `Ranking`, Matcher.swift)
- Tier base + fine (0…79) + kind prior (app 20, command 15, settings 10, contact 5, bookmark 0).
- Entry roles: title; alias (−5: file name, CFBundleName, command keywords); secondary (−100:
  bookmark host, contact org/email, settings/command synonyms).
- 1-char queries: EXACT/PREFIX (+WORDPREFIX except bookmarks). 2 chars: up to ACRONYM.
  FUZZY needs ≥3 chars, first char on a word start, ≤ m/3 gaps in the tightest window.
- Learning points `min(300, 15·log2(1+F) + 50·A)`, full for tiers ≥ ACRONYM, ½ substring,
  ¼ fuzzy. Latch (+5000) when one item owns an exact query. Results more than 350 below
  the best unpinned score are dropped.
- Tests in `Tests/FredCoreTests/MatcherTests.swift` pin the intended orderings. Add a test
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
  builds/tests keep all checks — correctness is established by tests.
- Panels are built once and only ordered in/out. No window animations, no implicit CA actions.

## Storage (`~/Library/Application Support/Fred/`)

- `learning.log` — "FRDL" v1; records `u32 time | u64 key | u8 row | u8 qlen | q`.
- `clipboard.log` — "FRDC" v1; ADD/TOUCH/DELETE records; compacted at load. `images/<hash>.png`.
- `control.sock` — dev socket.
Item keys: FNV-1a of (kind, payload); apps use bundle id (path fallback). Changing key
derivation orphans learned history — don't, or migrate.

## Control socket (`scripts/fredctl`)

`stats`, `permissions`, `request`, `query <q>`, `snapshot <png> [q]` (offscreen render,
doesn't steal focus), `card <png> <q>`, `type <q>`/`show`/`hide`/`key down|up|esc`
(visible UI — **don't use while the user is active**, it takes keyboard focus),
`learn`, `reindex`, `dryrun on|off`, `clip search|show|snapshot|forget`.

## Testing etiquette on the user's Mac

- Never execute Sleep/Restart/Shut Down/Lock/Empty Trash/Force Quit for testing — use
  `fredctl dryrun on` or launch with `FRED_DRY_RUN=1`.
- Don't pollute clipboard history; remove test clips with `fredctl clip forget <q>`.
- Prefer `snapshot` over showing panels; the user may be typing in another app.
