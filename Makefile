APP_NAME := Miss Minutes
APP := dist/$(APP_NAME).app
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
CLT := /Library/Developer/CommandLineTools/Library/Developer
TEST_FLAGS := -Xswiftc -F$(CLT)/Frameworks -Xlinker -F$(CLT)/Frameworks -Xlinker -rpath -Xlinker $(CLT)/Frameworks -Xlinker -rpath -Xlinker $(CLT)/usr/lib

.PHONY: build test test-swift test-bridge run sheet icon app dmg install clean

build:
	swift build

test: test-swift test-bridge

test-swift:
	swift test $(TEST_FLAGS)

test-bridge:
	cd bridge && node --test 'test/**/*.test.mjs'

run: build
	.build/debug/MissMinutes

# Renders every pose and mood to dist/sheet.png for reviewing the character.
sheet: build
	@mkdir -p dist
	.build/debug/MissMinutes --render-sheet dist/sheet.png

icon: build
	Scripts/make-icns.sh dist/AppIcon.icns .build/debug/MissMinutes

app:
	Scripts/build-app.sh

dmg: app
	Scripts/make-dmg.sh

install: app
	rm -rf "/Applications/$(APP_NAME).app"
	cp -R "$(APP)" "/Applications/$(APP_NAME).app"
	$(LSREGISTER) -u "$(CURDIR)/$(APP)" >/dev/null || true
	$(LSREGISTER) -f "/Applications/$(APP_NAME).app" >/dev/null
	@echo "✓ Installed to /Applications/$(APP_NAME).app"

clean:
	rm -rf .build dist
