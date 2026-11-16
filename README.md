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

## Build

Command Line Tools only (no Xcode). `make install` builds, signs with the local identity
and installs to /Applications. `make test`, `make bench`. Details for the maintainer
(architecture, measurements, rules) are in [AGENTS.md](AGENTS.md).

Data lives in `~/Library/Application Support/Fred/` (learning log, clipboard log, images).
