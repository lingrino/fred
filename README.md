# Fred

A personal launcher and clipboard history for macOS 27, built for one user and tuned for
latency.

## Use

| Keys | Does |
|---|---|
| **⌘Space** | Launcher: apps, System Settings panes, Chrome bookmarks, contacts, system commands, calculator |
| **⌘⇧C** | Clipboard history (text, images, files; 90 days) |
| ↩ | Open the selected result (row 1 by default) / paste the selected clip |
| ⌘1 … ⌘5 | Open result n (clipboard: ⌘1…⌘9) |
| ↑ ↓ / ⌃P ⌃N | Move selection |
| ⌘↩ | Launcher: reveal app in Finder · Clipboard: copy without pasting |
| ⌘⌫ | Clipboard: delete the selected clip |
| ↩ / ⌘C / ⌘O | Contact card: paste the field into your app / copy it / open Contacts.app |
| Esc | Close |

- Type math (`2+2`, `(1200*3)/4`, `sqrt(2)`, `5!`) for an inline result; ↩ copies it.
- Commands: Empty Trash, Sleep, Lock, Restart, Shut Down, Force Quit…, Quit Fred,
  Restart Fred (keywords like `emptytrash`, `shutdown`, `forcequit` work too).
- Fred learns from what you pick: typing "f" ranks the app you usually open for "f" first.

Hotkeys are ⌘Space / ⌘⇧C. Only one app can hold a hotkey: if another app grabs them
first, Fred keeps retrying and takes over as soon as they're free.

## Build

Command Line Tools only (no Xcode). `make install` builds, signs with the local identity
and installs to /Applications. `make test`, `make bench`. Details for the maintainer
(architecture, measurements, rules) are in [CLAUDE.md](CLAUDE.md).

Data lives in `~/Library/Application Support/Fred/` (learning log, clipboard log, images).
