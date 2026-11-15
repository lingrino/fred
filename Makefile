# Fred build entry points. Everything goes through SwiftPM + Command Line Tools; no Xcode.
#   make            build release .app into build/Fred.app
#   make install    build, copy to /Applications, (re)launch
#   make test       run unit tests (debug build, all runtime checks on)
#   make bench      run core benchmarks (release)
#   make debug-app  debug .app (checks on) into build/Fred-debug.app

APP        := build/Fred.app
INSTALLED  := /Applications/Fred.app
SIGN_ID    := Fred Local Signing
KEYCHAIN   := $(HOME)/Library/Keychains/fred-signing.keychain-db
KC_PASS    := $(HOME)/Library/Application Support/FredDev/keychain-password

.PHONY: all app install run test bench clean signing debug-app

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

test:
	./scripts/swift.sh test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing

bench:
	./scripts/swift.sh build -c release --product fredbench
	.build/release/fredbench

clean:
	rm -rf .build build
