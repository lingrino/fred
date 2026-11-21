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
1. Read this file, `git log --oneline -20`, and the memory notes if this Mac has any
   (they are local to one Mac and may be gone: everything durable is in this file).
   Check "Open decisions".
2. `sw_vers; swift --version`: if macOS, Xcode or the Command Line Tools changed, read
   "What OS/toolchain updates can break" below before anything else. On a new Mac: Xcode
   27.2 (or whatever CI's `DEVELOPER_DIR` says), the user's dotfiles (`dot`, which also
   installs the Fred cask), then `scripts/setup-signing.sh` (AWS SSO login). The user
   grants the privacy permissions once: the cask and `make install` builds share them.
3. `make install`, then `make check` (zero-warning build, unit tests, live smoke test
   against the installed app; no focus stealing). The install matters: a brew release
   has no control socket, so smoke can't reach it. Fix what it reports before new work.
4. `make bench`: compares with `Benchmarks/baseline.tsv`, flags ≥20% & ≥0.5 µs slower
   (rerun once; medians wobble). `fredctl stats` shows the user's real latency. When the
   user is idle: `fredctl live run` and `fredctl hotkeybench 30` (on-screen checks).
5. Branch → work → test of the right kind (see "Testing") → `make check` → `make install`
   → commit → PR. CI must pass; the PR is squash-merged, and every merge to main is a
   release (see "CI and releases"). If a benchmark moves on purpose, `make bench-save` and
   say why in the commit.

## What it does (and deliberately doesn't)

- **Launcher** (⌘Space): one ranked list (max 5
  rows) over apps, System Settings panes and the settings inside them ("True Tone" →
  Displays, from each pane's `.searchTerms`), system commands, Chrome bookmarks, contacts.
  Instant-answer row: calculator ("2+2"), else `Converter` (units, data sizes/rates,
  durations, time zones: "5 km in mi", "1 GiB to MB", "3pm pst in tokyo"; offline; a
  number glued to a one-letter unit, "4k"/"3d", is left to search, "3 d" converts).
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
- Bundle id `com.lingrino.fred` since 2026-11-16 (was `dev.fred.Fred`; the switch meant
  granting every permission again, before Fred went on the user's other Macs).

## Build, run, test

```
make check         # lint + test + smoke — run before every commit
make lint          # debug+release+tests build with -warnings-as-errors (own scratch dir)
make test          # unit tests (debug, all runtime checks on)
make smoke         # scripts/smoke.sh: live checks against the running app via fredctl
make dev           # release build → /Applications/Fred.app, relaunch with --regular (Dock icon so computer-use can see it)
make install       # same, as the user runs it (accessory app, no Dock icon)
make bench         # FredBench over a synthetic seeded catalog, Δ vs Benchmarks/baseline.tsv
                   #   (then the same queries over this Mac's catalog, not baselined)
make bench-save    # …and make this run the baseline
make release       # what CI publishes (build/release/: zip + cask); not notarized locally
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
- No Swift formatter/linter beyond the compiler: style is consistent by hand and a
  reformat would bury `git blame`. Zero warnings is the rule (`make lint`). Shell scripts
  pass shellcheck, workflows actionlint (both in CI).

### CI and releases (`.github/workflows`)
- `validate`, on every PR. The main ruleset requires a PR (no direct pushes, no force
  pushes) and its `lint`, `test` and `scripts` jobs: `make lint`; `make test` plus a
  release dry run (ad-hoc signed) and `brew style` on the generated cask; shellcheck and
  actionlint. Runner label `xcode-27`: GitHub's macOS 27 arm64 image (images are named
  by Xcode major). Its default Xcode lags (27.1 with the 27.0 SDK, which refuses the 27.2
  deployment target), so both workflows set `DEVELOPER_DIR` to the Xcode this Mac uses
  (27.2). `make smoke` and the on-screen checks need the installed app and its
  grants, so they stay local: `make check` before opening a PR.
- `release`, on every push to main: version 0.0.N, N = commits on main (squash merges, so
  every merge bumps it; `scripts/bundle.sh` stamps it into the bundle with the git hash
  as `FredRevision`). `scripts/release.sh` builds, signs, notarizes (API key), staples,
  zips and writes the cask. With the Apple secrets it publishes GitHub release `v0.0.N`
  and, while the repo is public, `Casks/fred.rb` in lingrino/homebrew-tap; without them
  it keeps the ad-hoc zip as a run artifact only.
- Secrets come from Terraform in lingrino/infra (`secrets_github.tf`, `local.mac_app_repos`:
  every Mac app the maintainer releases this way gets the same ones):
  `HOMEBREW_TAP_GITHUB_TOKEN`, and from AWS Secrets Manager `github/keys/apple-developer`:
  `APPLE_CERT_P12_BASE64`, `APPLE_CERT_PASSWORD` (Developer ID Application certificate),
  `APPLE_API_KEY_P8_BASE64`, `APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID` (App Store Connect
  API key for notarytool). Both belong to the team, not to Fred. The user puts them there
  with `scripts/store-release-secrets.sh <.p12> <AuthKey_ID.p8> <issuer>`: it asks for the
  .p12 password, checks the identity imports and notarytool accepts the key, then writes
  the JSON; repos get it on infra's next apply (its terraform workflow, or the Monday run).
  Rerun it with a new certificate before the current one expires (the first: 2027-12-16);
  releases already signed and notarized keep working after that.
- Upgrades: `brew upgrade` swaps /Applications/Fred.app under the running process; the
  Indexer's FSEvents see Fred's own bundle change and `AppDelegate.selfChanged` restarts
  Fred once its executable is a different file.
- Crashes: Fred comes back by itself (`CrashRelaunch`, since 0.0.50; before that a crash
  left the hotkeys dead until someone noticed, as on 2026-11-21). Each Fred keeps one
  child, `/bin/sh` blocked on a pipe: "quit" on it (every `NSApp.terminate`, and SIGTERM,
  which Fred now handles off main) ends the child; end-of-file without it (a trap,
  kill -9, a memory kill) makes the child `open` the bundle again, ~0.2 s later. So
  `pkill -x Fred`, Quit Fred and logout still leave Fred stopped, and a force quit does
  not. The crash times ride along as `--crashed t1,t2,…`; after 3 crashes within 10
  minutes (`RelaunchPolicy`) the next Fred doesn't arm and the following crash is final.
  State: `fredctl stats` → "crash relaunch", Fred Settings → "After a crash"; smoke
  expects "armed". Not a launchd agent with KeepAlive (considered 2026-11-21): every start
  would have to go through launchd or run unsupervised, it is one more Login Items entry
  to allow on every Mac, and it starts Fred outside LaunchServices, untried with the
  privacy grants. To test: `kill -KILL $(pgrep -x Fred)` (no crash report; `-SEGV` writes
  one to ~/Library/Logs/DiagnosticReports: delete it afterwards), then `fredctl stats`;
  a fourth kill within 10 minutes must stay down (`open /Applications/Fred.app` after).
- Renovate keeps action versions current (`renovate.json`).
- The user's Macs install Fred through their dotfiles (lingrino/dotfiles):
  `cask 'lingrino/tap/fred'` in `home/exact_private_dot_config/private_homebrew/Brewfile_*`
  (personal, mini, work). Their `dot` (chezmoi update) runs `brew bundle cleanup --force
  --zap` and `brew upgrade`: a merge to main reaches each Mac on its next `dot`, and a cask
  missing from that Mac's Brewfile is uninstalled and its zap trashes
  `~/Library/Application Support/Fred` (it happened 2026-11-16; the user put it back).

Toolchain (Xcode 27 is active on this Mac since 2026-11, and in CI):
- `scripts/swift.sh` wraps `swift`. With Xcode active it is plain `swift`. With only the
  Command Line Tools active it works around two CLT bugs seen 2026-11-14: stale Feb-2024
  `PackageDescription *.private.swiftinterface` files that broke every manifest (SwiftPM
  gets a clean copy via `SWIFTPM_CUSTOM_LIBS_DIR`), and the swift-testing macro plugin
  not being found (test builds get `-plugin-path`). Check that branch with
  `DEVELOPER_DIR=/Library/Developer/CommandLineTools scripts/swift.sh test --scratch-path <dir>`.
- Local builds are signed with the same Developer ID as releases (no timestamp, not
  notarized), from a dedicated keychain (`~/Library/Keychains/developer-id.keychain-db`,
  password in `~/Library/Application Support/DeveloperID/`) that `scripts/setup-signing.sh`
  fills from `github/keys/apple-developer`; `make` checks it with `--check`. The
  maintainer's other Mac apps use the same keychain (a copy of the script with the same
  paths), so it is set up once per Mac. Every Developer ID signature has the same
  designated requirement (bundle id + team ID), so the user's privacy grants carry across
  `brew upgrade` and `make install` and survive certificate renewals. The user's Mac
  installs the cask like the others; `make install` replaces it with a local build
  (control socket included) until the next `brew upgrade`. Never switch local builds to
  ad-hoc or another identity, or change the bundle id `com.lingrino.fred`: that means
  granting every permission again.

## Privacy grants (user-only; check with `fredctl permissions`)

contacts (Contacts) · postEvents ("Device Control and Data Access" = Accessibility, for ⌘V)
· pasteboard (Paste from Other Apps = Allow) · chromeData (Full Disk Access;
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
  Fold.swift               text folding (case/diacritics/marks/separator runs) + word-start masks + char masks
  SearchIndex.swift        SoA index in ONE 128B-aligned allocation (masks/spans/starts/items/bytes)
  Matcher.swift            tiered matcher: EXACT 1300 > PREFIX 900 > WORDPREFIX 800 > ACRONYM 700 > SUBSTRING 500 > FUZZY 300 (+0…79 fine)
  Search.swift             TopK (inline storage), Ranking (kind prior, roles, learning blend, cutoff), Searcher (hot loop)
  Learning.swift           event log → frecency (14d half-life) + query→item associations (competition, prefix lookup, latch)
  Catalog.swift            merged items (SoA) + stable FNV keys + key→item lookup
  Calculator.swift         allocation-free recursive-descent evaluator
  Converter.swift          units/data/time-zone instant answers: byte-level parsing, offset math (no formatters)
  ClipStore.swift          clipboard history SoA + append-only log + images dir + search
  AppendFile.swift         the logs' write side (O_APPEND, 0600, torn-write cut-off, foreign files moved aside)
  Disjoint.swift           @unchecked Sendable box for concurrentPerform buffers (disjoint writes)
  RelaunchPolicy.swift     when to stop relaunching after crashes (3 within 10 minutes)
  Sources/*.swift          AppScanner, SettingsScanner, Commands, ChromeBookmarks (Foundation only)
Sources/Fred/              the app
  main.swift               FredApplication (fast key dispatch to QueryField), single-instance lock, entry point
  AppDelegate.swift        wiring; startup order (indexer first, hotkey + panels, deferred checks)
  Engine.swift             catalog/searcher/learning/icon atlas/title atlas owner (main thread)
  Indexer.swift            background reindex (sources in parallel) on FSEvents / Contacts change / wake
  IconAtlas.swift          all icons pre-rendered (parallel) into one bitmap; rows use sub-images
  TitleAtlas.swift         all catalog titles pre-rendered as A8 masks (rows = mask + color layer)
  UI/Panel.swift           FloatingPanel: fixed-size non-activating window, Liquid Glass clipped by a mask,
                           present()/park() instead of order in/out; Theme constants; DevMode
  UI/QueryField.swift      custom single-line text input (fast path + NSTextInputClient for IME)
  UI/ResultList.swift      ResultList (NSView host) + RowLayer (pure CALayer row; title-atlas mask when it fits)
  UI/TextImage.swift       one-line Core Text → CGImage for dynamic strings; CALayer.still()
  UI/Launcher.swift        launcher controller: keystroke → search → rows, keys, modes, actions, latency stats
  ClipboardController.swift pasteboard polling, clipboard panel + preview, paste
  Actions.swift            open, system commands (loginwindow AEs, lock, Finder), ⌘V posting
  CrashRelaunch.swift      the child that reopens Fred after a crash; SIGTERM as a clean exit
  SettingsWindow.swift     "Fred Settings" health window (AppKit, plain NSWindow)
  LiveTests.swift          on-screen checks via posted key events: hotkeybench, typing, ⌘, (user idle only)
  Snapshot.swift           offscreen PNG of a view's layer tree (fredctl snapshot/card/settings)
  ContactsSource / ContactCard / Permissions / LoginItem / HotKeys / ControlServer / Log
Sources/FredBench/         `fredbench scan` (what sources find), `bench`, `save` (baseline)
Benchmarks/baseline.tsv    p50 per benchmark (ns), compared by `make bench`
scripts/                   swift.sh (toolchain wrapper), bundle.sh, release.sh, setup-signing.sh,
                           fredctl, lint.sh, smoke.sh, make-icon.swift
.github/workflows/         validate (PR checks), release (every merge to main), review
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
  floor, so sub-setting entries are mostly skipped once 5 good rows exist; a differential
  fuzz test (`FuzzTests.pruningNeverChangesResults`) checks pruning never changes results.
- Sub-setting terms shared by ≥4 settings ("privacy", "screen") or repeating a title word
  are dropped at scan time (`SettingsScanner.pruneKeywords`): noise and search cost.
- 1-char queries: EXACT/PREFIX (+WORDPREFIX except bookmarks). 2 chars: up to ACRONYM.
  FUZZY needs ≥3 chars, first char on a word start, ≤ m/3 gaps in the tightest window.
- Learning points `min(300, 15·log2(1+F) + 50·A)`, full for text tiers ≥ ACRONYM, ½
  substring, ¼ fuzzy — the text tier before role penalties, so picks promote sub-settings
  too. Latch (+5000, any tier ≥ ACRONYM) when one item owns an exact query. Weak results (substring/fuzzy,
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
- A parked panel is not inert: it is ordered in, and tracking areas keep delivering
  mouse-moved to it (`ignoresMouseEvents` only stops clicks). Whatever a panel holds while
  parked is stale (the clipboard list's indices are not refreshed then), so handlers of
  events that can arrive while parked check `panel.shown` first (`ResultList.mouseMoved`;
  `FloatingPanel.performKeyEquivalent` as a precaution: AppKit was only seen offering key
  equivalents to the key window).
  0.0.48 crashed on 2026-11-21 (index out of range) when the hourly prune had dropped
  clips and the pointer then crossed the parked clipboard list; smoke covers it
  (`fredctl clip hover`).
- Logs (learning, clipboard) truncate a torn tail before appending; never append after an
  unparsed tail (`AppendFile`: O_APPEND, a failed write is cut back off).
- The query field holds at most 256 UTF-16 units: it typesets and rasterizes its whole
  text on every edit, and nothing reads past 80 bytes anyway.
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
- `clipboard.log` — "FRDC" v1; ADD/TOUCH/DELETE records; compacted at load and by the
  hourly prune once garbage is large. `images/<hash>.png`.
- `fred.lock` — flock held by the running Fred: one instance per user.
- `control.sock` — dev socket (local builds only).
The directory is 0700, logs 0600. A log with another header or version is moved aside
(`*.unrecognized-<time>`), never overwritten. Item keys: FNV-1a of (kind, payload); apps
use bundle id (path fallback). Changing key derivation orphans learned history — don't, or
migrate. `FormatTests` pins keys, command ids, clip hashes and both log formats byte for byte.

## Control socket (`scripts/fredctl`)

Only in locally built apps (`bundle.sh` sets FredDevTools in Info.plist; releases have no
socket): it reads contacts and clipboard history with Fred's grants. Commands that render
offscreen refuse with "busy" while the user has that panel on screen.
`stats` (incl. per-stage latency), `resetstats`, `permissions`, `request`, `query <q>` (also
prints the instant-answer row and its µs), `settings [png]` (no arg: show the window — takes
focus; with a path: render it offscreen),
`snapshot <png> [q]` (renders the content layer tree offscreen — no glass — and
doesn't steal focus), `card <png> <q>`, `type <q>`/`show`/`hide`/`key down|up|esc`
(visible UI — **don't use while the user is active**, it takes keyboard focus), `shadow`,
`learn`, `reindex`, `dryrun on|off`, `clip search|show|pick <n>|snapshot|forget <q>|hover <n>`
(`hover`: a mouse-moved over row n of the parked clipboard list, which must ignore it),
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

- The repo is public (since 2026-11-16), and so are PR bodies, review comments and CI
  logs. Never commit the user's real data — contact names, bookmarks,
  clipboard text, learning history, query logs, or the names of third-party apps installed
  on their Mac — in tests, docs, benchmarks, comments or commit messages, even when
  debugging a real-world ranking complaint: reproduce it with fictional names (Goober
  Chroma, Vivid Story Composer, iTally, Kermit Frog, `*.example` hosts). Apple's stock
  apps (Safari, Finder, System Settings…) are fine.
  Push only branches for PRs (main takes PRs only; never `git push --all`/`--mirror`);
  other refs in this clone (e.g.
  `refs/codex/…` checkpoints) are local tool state. Commits and PR bodies carry no
  agent attribution (no `Co-Authored-By` trailer): the user authors them.
- Don't drive other apps with `osascript` (`tell application …`): it raises an Automation
  prompt for the agent's terminal, and only the user answers privacy prompts. Quit apps
  with `pkill -x`; check state with `pgrep`, `fredctl` or screenshots.

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
- Toolchain: the CLT workarounds (`scripts/swift.sh`, only when the CLT is active), new
  compiler diagnostics (`make lint`), the CI runner label (`xcode-27`: move to the next
  Xcode major's label when GitHub ships it) and the workflows' `DEVELOPER_DIR` (keep it on
  the local Xcode; the image's readme lists what's installed). Signing: losing the signing
  keychain or its password just means `scripts/setup-signing.sh` again; a renewed
  certificate goes through `store-release-secrets.sh`, an infra apply, then `setup-signing.sh`.

## Open decisions

None.

(Resolved 2026-11-15: Liquid Glass is the only backdrop; numbers in "Latency notes".
2026-11-16: releases are signed with the Developer ID, notarized and published to the
tap; the repo is public; every Mac, the user's included, installs the cask, and local
builds sign with the same Developer ID.)

## Latency notes (measured 2026-11-14, M4 Max, macOS 27.2; `fredctl stats`)

Keystroke (p50): OS delivery ~0.4–1.5 ms (outside our control) → Fred ~0.76 ms in-process:
key handling ~0.28 ms (QueryField fast path + field text render) · search+rows ~0.04 ms ·
draw+commit ~0.44 ms (mostly the fixed CA→window-server commit). Hotkey → frame committed
~2.2 ms before Liquid Glass (becoming key ~1.2 ms of it), 5.3–6.4 ms with it (below).
Search kernel alone (`make bench`, 2026-11-16, synthetic catalog): p50 4–25 µs over a
13k-entry index (this Mac's own ~2.3k entries: 1–6 µs); sub-settings (long strings) cost
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
  frame ~2 ms both. 2026-11-16: 8.1–8.4 ms (makeKey ~4.5 ms) — identical for the builds
  before and after that day's review, so the change is outside Fred (not investigated). The user chose glass at +2–2.5 ms (both < one 120 Hz frame); the
  earlier "~10 ms" no longer reproduces. Vibrancy code was deleted (git history).
- Ordering a window out discards its rendered state → panels are "parked" (ordered in,
  alpha 0, click-through, `canBecomeKey == false`) instead of ordered out.
- Row text rasterized per keystroke ~150 µs → `TitleAtlas` (all titles pre-rendered as A8
  masks, rows are mask + color layers).
- Rows as NSViews: AppKit bookkeeping on hide/show → rows are plain CALayer trees.
