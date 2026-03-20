# pterm - macOS Terminal Emulator
# Build system: SPM + xcrun metal + shell scripts

.PHONY: build debug test regression-test clean bundle run shaders package verify-bundle verify-signature profile-cpu profile-cpu-attach

# Output directories
BUILD_DIR = .build
APP_BUNDLE = $(BUILD_DIR)/pterm.app
DIST_ARCHIVE = $(BUILD_DIR)/pterm-darwin-arm64.tar.gz
DIST_ZIP = $(BUILD_DIR)/pterm-darwin-arm64.zip
SHADER_DIR = Sources/PtermApp/Rendering/Shaders
METAL_TOOLCHAIN = TOOLCHAINS=Metal

# Build release
build: regression-test package
	@echo "Release build, regression suite, and distribution archives completed."

# Build debug
debug:
	swift build -c debug
	@$(MAKE) bundle CONFIG=debug

# Run the app (debug)
run: debug
	@open $(APP_BUNDLE)

# Profile CPU hot paths by launching a fresh debug app instance
profile-cpu:
	@Scripts/profile-cpu.sh

# Profile CPU hot paths by attaching to an already-running app instance
profile-cpu-attach:
	@Scripts/profile-cpu.sh --attach-existing --no-build

# Run tests
test:
	swift test

# Mandatory regression gate for production/release builds
regression-test:
	swift build -c release
	@$(MAKE) bundle CONFIG=release
	PTERM_TEST_RELEASE_APP_EXECUTABLE="$(APP_BUNDLE)/Contents/MacOS/PtermApp" swift test -c release

# Clean
clean:
	swift package clean
	rm -rf $(BUILD_DIR)/pterm.app
	rm -f $(DIST_ARCHIVE) $(DIST_ZIP)

# Assemble .app bundle
bundle:
	@set -e; \
	CONFIG=$${CONFIG:-debug}; \
	BINARY_DIR=$(BUILD_DIR)/$$CONFIG; \
	echo "Bundling pterm.app ($$CONFIG)..."; \
	mkdir -p $(APP_BUNDLE)/Contents/MacOS; \
	mkdir -p $(APP_BUNDLE)/Contents/Resources; \
	mkdir -p $(BUILD_DIR)/shaders; \
	cp $$BINARY_DIR/PtermApp $(APP_BUNDLE)/Contents/MacOS/PtermApp; \
	cp Resources/Info.plist $(APP_BUNDLE)/Contents/Info.plist; \
	cp Resources/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/AppIcon.icns; \
	cp Resources/close_icon.png $(APP_BUNDLE)/Contents/Resources/close_icon.png; \
	cp Resources/close_circle.png $(APP_BUNDLE)/Contents/Resources/close_circle.png; \
	rm -rf $(APP_BUNDLE)/Contents/Resources/Audio; \
	cp -R Resources/Audio $(APP_BUNDLE)/Contents/Resources/Audio; \
	$(METAL_TOOLCHAIN) xcrun -sdk macosx metal -c $(SHADER_DIR)/terminal.metal \
		-o $(BUILD_DIR)/shaders/terminal.air; \
	$(METAL_TOOLCHAIN) xcrun -sdk macosx metallib $(BUILD_DIR)/shaders/terminal.air \
		-o $(APP_BUNDLE)/Contents/Resources/default.metallib; \
	echo "Bundle created at $(APP_BUNDLE)"

# Create distributable archives from the bundled app (use 'make build' first)
package:
	@rm -f $(DIST_ARCHIVE)
	@rm -f $(DIST_ZIP)
	tar czf $(DIST_ARCHIVE) -C $(BUILD_DIR) pterm.app
	ditto -c -k --sequesterRsrc --keepParent $(APP_BUNDLE) $(DIST_ZIP)
	@echo "Packages created at $(DIST_ARCHIVE) and $(DIST_ZIP)"

# Verify bundle structure and embedded resources
verify-bundle: build
	@test -f $(APP_BUNDLE)/Contents/MacOS/PtermApp
	@test -f $(APP_BUNDLE)/Contents/Info.plist
	@test -f $(APP_BUNDLE)/Contents/Resources/default.metallib
	@test -f $(APP_BUNDLE)/Contents/Resources/AppIcon.icns
	@test -f $(APP_BUNDLE)/Contents/Resources/Audio/type1.aiff
	@echo "Bundle structure verified."

# Verify code signature when the app has been signed
verify-signature:
	codesign --verify --deep --strict --verbose=2 $(APP_BUNDLE)
	spctl --assess --type execute --verbose=4 $(APP_BUNDLE)
	@echo "Signature assessment completed."

# Compile Metal shaders (requires Xcode.app)
shaders:
	@echo "Compiling Metal shaders..."
	@mkdir -p $(BUILD_DIR)/shaders
	$(METAL_TOOLCHAIN) xcrun -sdk macosx metal -c $(SHADER_DIR)/terminal.metal \
		-o $(BUILD_DIR)/shaders/terminal.air
	$(METAL_TOOLCHAIN) xcrun -sdk macosx metallib $(BUILD_DIR)/shaders/terminal.air \
		-o $(APP_BUNDLE)/Contents/Resources/default.metallib
	@echo "Shaders compiled."

# Code sign (requires Developer ID)
sign:
	@if [ -z "$(IDENTITY)" ]; then \
		echo "Usage: make sign IDENTITY='Developer ID Application: ...'"; \
		exit 1; \
	fi
	codesign --deep --force --verify --verbose \
		--sign "$(IDENTITY)" \
		--options runtime \
		--timestamp \
		$(APP_BUNDLE)
	@echo "Code signed."

# Notarize and staple.
# Preferred:
#   make notarize IDENTITY='Developer ID Application: ...' NOTARY_PROFILE='profile-name'
# Alternative:
#   make notarize IDENTITY='...' APPLE_ID='name@example.com' TEAM_ID='TEAMID' APPLE_APP_SPECIFIC_PASSWORD='xxxx-xxxx-xxxx-xxxx'
notarize: build sign package
	@if [ -n "$(NOTARY_PROFILE)" ]; then \
		xcrun notarytool submit $(DIST_ZIP) --keychain-profile "$(NOTARY_PROFILE)" --wait; \
	elif [ -n "$(APPLE_ID)" ] && [ -n "$(TEAM_ID)" ] && [ -n "$(APPLE_APP_SPECIFIC_PASSWORD)" ]; then \
		xcrun notarytool submit $(DIST_ZIP) \
			--apple-id "$(APPLE_ID)" \
			--team-id "$(TEAM_ID)" \
			--password "$(APPLE_APP_SPECIFIC_PASSWORD)" \
			--wait; \
	else \
		echo "Usage:"; \
		echo "  make notarize IDENTITY='Developer ID Application: ...' NOTARY_PROFILE='profile-name'"; \
		echo "or"; \
		echo "  make notarize IDENTITY='...' APPLE_ID='name@example.com' TEAM_ID='TEAMID' APPLE_APP_SPECIFIC_PASSWORD='app-specific-password'"; \
		exit 1; \
	fi
	xcrun stapler staple $(APP_BUNDLE)
	@$(MAKE) verify-signature
	@echo "Notarized and stapled."
