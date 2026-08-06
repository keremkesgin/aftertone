APP_NAME    := Turntable
BUNDLE_ID   := dev.kesgin.Turntable
VERSION     := 0.1.0
BUILD_NUM   := 1
CONFIG      := debug

BUILD_DIR   := build
APP         := $(BUILD_DIR)/$(APP_NAME).app
CONTENTS    := $(APP)/Contents
BIN         := .build/$(CONFIG)/$(APP_NAME)

# No Developer ID on this machine yet, so dev builds are ad-hoc signed. That is enough to
# carry the apple-events entitlement under the hardened runtime and to get a real TCC
# prompt. Swap this for "Developer ID Application: …" once notarized distribution matters.
SIGN_ID     ?= -

.PHONY: all app build bundle sign run test bench artwork-bench lyrics-bench clean tcc-reset print-config

all: app

build:
	swift build -c $(CONFIG) --product $(APP_NAME)

bundle: build
	@rm -rf "$(APP)"
	@mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	@cp "$(BIN)" "$(CONTENTS)/MacOS/$(APP_NAME)"
	@sed -e 's|__BUNDLE_ID__|$(BUNDLE_ID)|' \
	     -e 's|__VERSION__|$(VERSION)|' \
	     -e 's|__BUILD__|$(BUILD_NUM)|' \
	     Bundle/Info.plist > "$(CONTENTS)/Info.plist"
	@printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	@if [ -d Resources ]; then \
	    /usr/bin/rsync -a --exclude='.gitkeep' --exclude='.DS_Store' Resources/ "$(CONTENTS)/Resources/"; \
	fi
	@echo "bundled → $(APP)"

# --options runtime enables the hardened runtime, which is what makes the entitlement
# necessary in the first place. Signing with it now means dev and release exercise the
# same Apple Events code path.
sign: bundle
	@codesign --force --sign "$(SIGN_ID)" \
	          --options runtime \
	          --entitlements Bundle/$(APP_NAME).entitlements \
	          --timestamp=none \
	          "$(APP)"
	@codesign --verify --verbose=1 "$(APP)" 2>&1 | sed 's/^/  /'
	@echo "signed with: $(SIGN_ID)"

app: sign

run: app
	@open "$(APP)"

# Deterministic tests for the Spotify parse boundary and error mapping. Not XCTest:
# XCTest.framework ships with Xcode, which is not installed here, so `swift test` cannot
# link. Exits non-zero on failure.
test: build
	@"$(BIN)" --selftest

# How long a poll blocks the main thread, and whether it ever does at all.
bench: app
	@"$(CONTENTS)/MacOS/$(APP_NAME)" --bench

# Artwork pipeline: cache → network → placeholder fallback, never blank.
artwork-bench: app
	@"$(CONTENTS)/MacOS/$(APP_NAME)" --artwork-bench

# Lyrics pipeline against the live current Spotify track: writes a synthetic .lrc to a
# scratch directory, confirms the store matches it and the parser/active-line tracking
# behave sanely. Never touches ~/Music/Lyrics.
lyrics-bench: app
	@"$(CONTENTS)/MacOS/$(APP_NAME)" --lyrics-bench

# Ad-hoc signatures are identified by cdhash, which changes on every rebuild — so macOS
# treats each build as a new app and the Automation grant goes stale. Clear it to get a
# fresh prompt (this is also how you re-test the denial path).
tcc-reset:
	@tccutil reset AppleEvents $(BUNDLE_ID) || true
	@echo "Automation grant for $(BUNDLE_ID) cleared."

print-config:
	@echo "bundle id : $(BUNDLE_ID)"
	@echo "version   : $(VERSION) ($(BUILD_NUM))"
	@echo "config    : $(CONFIG)"
	@echo "sign id   : $(SIGN_ID)"

clean:
	@rm -rf $(BUILD_DIR) .build
