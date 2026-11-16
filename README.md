# Fred

A personal launcher and clipboard history for macOS 27, built for one user and tuned for
latency.

## Use

| Keys | Does |
|---|---|
| **⌘Space** | Launcher: apps, System Settings (panes and the options inside them), Chrome bookmarks, contacts, system commands, calculator, unit/time converter |
| **⌘⇧C** | Clipboard history (text, images, files; 90 days) |
| ↩ | Open the selected result (row 1 by default) / paste the selected clip |
| ⌘1 … ⌘5 | Open result n (clipboard: ⌘1…⌘9) |
| ↑ ↓ / ⌃P ⌃N | Move selection |
| ⌘↩ | Launcher: reveal app in Finder · Clipboard: copy without pasting |
| ⌘⌫ | Clipboard: delete the selected clip |
| ↩ / ⌘C / ⌘↩ / ⌘O | Contact card: type the field into your app (clipboard untouched) / copy it / call, email, map or open it / open Contacts.app |
| ⌘, | Fred Settings (also the "Fred Settings" command) |
| Esc | Close |

- Type math (`2+2`, `(1200*3)/4`, `sqrt(2)`, `5!`) for an inline result; ↩ copies it.
- Conversions, offline: `5 km in mi`, `180 lb`, `72 f`, `1 GiB to MB`, `100 Mbps in MB/s`,
  `90 min`, `3pm pst in tokyo`, `noon et to pt`, `now in london`, `tokyo time`. A unit
  alone converts to its usual counterpart; ↩ copies the number.
- Sub-settings: `true tone`, `night shift`, `hot corners`… open the pane that has them.
- Fred Settings shows whether each privacy permission works (with a button to the right
  System Settings page when one doesn't), plus hotkey/login-item status, index sizes and
  live CPU, memory and latency.
- Commands: Empty Trash, Sleep, Lock, Restart, Shut Down, Force Quit…, Quit Fred,
  Restart Fred (keywords like `emptytrash`, `shutdown`, `forcequit` work too).
- Fred learns from what you pick: typing "f" ranks the app you usually open for "f" first.

Hotkeys are ⌘Space / ⌘⇧C. Only one app can hold a hotkey: if another app grabs them
first, Fred keeps retrying and takes over as soon as they're free.

## Install

```
brew install --cask lingrino/tap/fred
open -a Fred
```

On first launch Fred adds itself to login items and asks for each permission it uses;
Fred Settings (⌘,) shows which ones are missing, each with a button to the right System
Settings page. Three need a manual switch: Paste from Other Apps → Allow (clipboard
history), Full Disk Access (Chrome bookmarks), and turning off Spotlight's ⌘Space
shortcut (System Settings → Keyboard → Keyboard Shortcuts → Spotlight). Update with
`brew upgrade --cask fred`; Fred restarts itself when its app is replaced.

## Build

Xcode 27 or the Command Line Tools (SwiftPM, no Xcode project). `make install` builds,
signs with the maintainer's Developer ID (`scripts/setup-signing.sh`) and installs to
/Applications; to build without it, `FRED_SIGN_IDENTITY=- make install` (ad-hoc). `make test`,
`make bench`. Every PR runs lint and tests in GitHub Actions, and every merge to main is
released as 0.0.N: signed with a Developer ID, notarized, and published to the tap. Details for the maintainer (architecture, measurements, rules)
are in [AGENTS.md](AGENTS.md).

Data lives in `~/Library/Application Support/Fred/` (learning log, clipboard log, images).

MIT licensed (see [LICENSE](LICENSE)). A personal project: no support, issues or roadmap.
