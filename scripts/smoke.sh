#!/bin/bash
# Live checks against the running Fred (`make install` first) over its control socket.
# Never takes keyboard focus or touches the clipboard: safe while the user works.
#
# Catches what unit tests can't: a source that stopped finding things after a macOS
# update (settings panes moved, Chrome profile protection, TCC renames), a lost grant or
# hotkey, ranking/converter regressions on the real catalog, implicit animations on rows,
# broken offscreen rendering. Expectations use stable system items only — never anything
# that depends on the user's learning history.
# `check && ok || bad …` is safe here: ok always succeeds, so bad runs only on failure.
# shellcheck disable=SC2015
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
CTL=scripts/fredctl
pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { echo "FAIL: $*"; fail=$((fail + 1)); }

SOCK="$HOME/Library/Application Support/Fred/control.sock"
if [[ ! -S "$SOCK" ]] || ! $CTL stats >/dev/null 2>&1; then echo "smoke: no control socket: Fred isn't running, or it's a brew release (make install)"; exit 1; fi

# Grants, hotkeys, login item.
missing=$($CTL permissions | grep -v ": granted$")
[[ -z "$missing" ]] && ok || bad "permissions: $missing"
stats=$($CTL stats)
grep -q "hotkeys: launcher registered, clipboard registered" <<<"$stats" && ok || bad "hotkeys: $(grep hotkeys <<<"$stats")"
grep -q "login item: enabled" <<<"$stats" && ok || bad "$(grep 'login item' <<<"$stats")"
grep -q "^crash relaunch: armed" <<<"$stats" && ok || bad "$(grep 'crash relaunch' <<<"$stats")"

# Every title is pre-rendered (a title that misses the atlas rasterizes per keystroke).
read -r tin tall <<<"$(sed -nE 's/.*titles: ([0-9]+) of ([0-9]+),.*/\1 \2/p' <<<"$stats")"
[[ -n "${tin:-}" && "$tin" -gt 0 && "$tin" == "$tall" ]] && ok || bad "title atlas: $(grep -o 'titles: [^;]*' <<<"$stats")"

# Every source finds a plausible amount (thresholds well under today's counts).
cat=$(grep "^catalog:" <<<"$stats")
count() { sed -nE "s/.*$1 ([0-9]+).*/\1/p" <<<"$cat"; }
for spec in apps:50 settings:300 commands:8 bookmarks:1 contacts:1; do
  k=${spec%%:*}; min=${spec##*:}; n=$(count "$k")
  [[ -n "$n" && "$n" -ge "$min" ]] && ok || bad "source $k: ${n:-?} items (expected ≥ $min)"
done

# Top result for stable queries (title column of the first non-answer row).
top() { $CTL query "$1" | awk -F'\t' 'NR > 1 && $1 !~ /answer/ && NF > 2 { print $3; exit }'; }
expect_top() { local got; got=$(top "$1"); [[ "$got" == "$2" ]] && ok || bad "query \"$1\": top \"$got\", expected \"$2\""; }
expect_top "safari" "Safari"
expect_top "system settings" "System Settings"
expect_top "activity monitor" "Activity Monitor"
expect_top "empty trash" "Empty Trash"
expect_top "fred settings" "Fred Settings"
expect_top "displays" "Displays"
expect_top "true tone" "True Tone"
expect_top "dark mode" "Appearance"
expect_top "hot corners" "Desktop & Dock"
$CTL query "lock" | grep -q $'\tLock Screen\t' && ok || bad "query \"lock\": no Lock Screen pane"

# Instant answers (title column of the answer row).
answer() { $CTL query "$1" | awk -F'\t' '$1 ~ /answer/ { print $3; exit }'; }
expect_answer() { local got; got=$(answer "$1"); [[ "$got" == "$2" ]] && ok || bad "answer \"$1\": \"$got\", expected \"$2\""; }
expect_answer "2+2" "4"
expect_answer "5 km in mi" "3.10686 mi"
expect_answer "1 GiB to MB" "1,073.74 MB"
expect_answer "100 Mbps in MB/s" "12.5 MB/s"
[[ "$(answer "now in london")" =~ (AM|PM) ]] && ok || bad "answer \"now in london\": no time"
[[ -z "$(answer "safari")" ]] && ok || bad "answer \"safari\": unexpected answer row"

# Rows never animate (only the caret blinks).
for pair in "2+2|calendar" "safari|5 km in mi" "true tone|lock"; do
  out=$($CTL animcheck "$pair")
  extra=$(grep -v -e "^no animations$" -e "blink" <<<"$out")
  [[ -z "$extra" ]] && ok || bad "animcheck $pair: $extra"
done

# Offscreen rendering produces real images.
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
$CTL snapshot "$tmp/l.png" "safari" >/dev/null
[[ $(stat -f %z "$tmp/l.png" 2>/dev/null || echo 0) -gt 10000 ]] && ok || bad "launcher snapshot empty"
$CTL settings "$tmp/s.png" >/dev/null
[[ $(stat -f %z "$tmp/s.png" 2>/dev/null || echo 0) -gt 10000 ]] && ok || bad "settings snapshot empty"
$CTL clip snapshot "$tmp/c.png" >/dev/null
[[ $(stat -f %z "$tmp/c.png" 2>/dev/null || echo 0) -gt 10000 ]] && ok || bad "clipboard snapshot empty"

# A parked panel still gets mouse-moved; its rows must not react (0.0.48 crashed there).
hover=$($CTL clip hover 1)
[[ "$hover" == "row 0 → 0" ]] && ok || bad "parked clipboard list under the mouse: $hover"

# Latency is reported, not judged (it depends on what the machine is doing).
grep -E "keystroke→committed|hotkey→committed" <<<"$stats" | sed 's/^/  /'
echo "smoke: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
