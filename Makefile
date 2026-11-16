# Fred build entry points. Everything goes through SwiftPM via scripts/swift.sh (Xcode or
# the Command Line Tools; no Xcode project).
#   make            build release .app into build/Fred.app
#   make install    build, copy to /Applications, (re)launch
#   make test       run unit tests (debug build, all runtime checks on)
#   make bench      run core benchmarks (release), compared with Benchmarks/baseline.tsv
#   make bench-save same, then make this run the new baseline (commit it)
#   make lint       release + debug build must produce zero compiler warnings
#   make smoke      live checks against the running app (no focus change)
#   make check      lint + test + smoke: before every commit, and first thing after a break
#   make debug-app  debug .app (checks on) into build/Fred-debug.app
#   make release    what CI publishes: build/release/Fred-<version>.zip + fred.rb (scripts/release.sh)

APP        := build/Fred.app
INSTALLED  := /Applications/Fred.app
SIGN_ID    := Fred Local Signing
KEYCHAIN   := $(HOME)/Library/Keychains/fred-signing.keychain-db
KC_PASS    := $(HOME)/Library/Application Support/FredDev/keychain-password

.PHONY: all app install run test bench bench-save lint smoke check clean signing debug-app dev release

all: app

signing:
	@./scripts/setup-signing.sh >/dev/null

app: signing
	./scripts/swift.sh build -c release --product Fred
	./scripts/bundle.sh release "$(APP)"

debug-app: signing
	./scripts/swift.sh build -c debug --product Fred
	./scripts/bundle.sh debug build/Fred-debug.app

install: app
	-@pkill -x Fred; sleep 0.2
	rm -rf "$(INSTALLED)"
	ditto "$(APP)" "$(INSTALLED)"
	open "$(INSTALLED)"

run: install

# Like install, but with a Dock icon so UI automation can see/grant Fred.
dev: app
	-@pkill -x Fred; sleep 0.2
	rm -rf "$(INSTALLED)"
	ditto "$(APP)" "$(INSTALLED)"
	open -a "$(INSTALLED)" --args --regular

test:
	./scripts/swift.sh test

bench:
	./scripts/swift.sh build -c release --product fredbench
	.build/release/fredbench bench

bench-save:
	./scripts/swift.sh build -c release --product fredbench
	.build/release/fredbench save

# Warnings are errors-in-waiting (Swift 6 concurrency diagnostics turn into errors in
# newer language modes). The CLT linker's "search path not found" notes are ignored.
lint:
	@./scripts/lint.sh

smoke:
	@./scripts/smoke.sh

check: lint test smoke

# Locally this signs with the self-signed identity and skips notarization (no Apple
# credentials here); CI signs with Developer ID and notarizes when its secrets exist.
release: signing
	./scripts/release.sh

clean:
	rm -rf .build build
