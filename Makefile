# pterm - macOS Terminal Emulator
# Build system: SPM + xcrun metal + shell scripts

.PHONY: build debug test clean bundle run shaders

# Output directories
BUILD_DIR = .build
APP_BUNDLE = $(BUILD_DIR)/pterm.app
SHADER_DIR = Sources/PtermApp/Rendering/Shaders
METAL_TOOLCHAIN = TOOLCHAINS=Metal

# Build release
build:
	swift build -c release
	@$(MAKE) bundle CONFIG=release

# Build debug
debug:
	swift build -c debug
	@$(MAKE) bundle CONFIG=debug

# Run the app (debug)
run: debug
	@open $(APP_BUNDLE)

# Run tests
test:
	swift test

# Clean
clean:
	swift package clean
	rm -rf $(BUILD_DIR)/pterm.app

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
	$(METAL_TOOLCHAIN) xcrun -sdk macosx metal -c $(SHADER_DIR)/terminal.metal \
		-o $(BUILD_DIR)/shaders/terminal.air; \
	$(METAL_TOOLCHAIN) xcrun -sdk macosx metallib $(BUILD_DIR)/shaders/terminal.air \
		-o $(APP_BUNDLE)/Contents/Resources/default.metallib; \
	echo "Bundle created at $(APP_BUNDLE)"

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
		$(APP_BUNDLE)
	@echo "Code signed."

# Notarize (requires APPLE_ID and TEAM_ID)
notarize: sign
	@if [ -z "$(APPLE_ID)" ] || [ -z "$(TEAM_ID)" ]; then \
		echo "Usage: make notarize IDENTITY='...' APPLE_ID='...' TEAM_ID='...'"; \
		exit 1; \
	fi
	ditto -c -k --keepParent $(APP_BUNDLE) $(BUILD_DIR)/pterm.zip
	xcrun notarytool submit $(BUILD_DIR)/pterm.zip \
		--apple-id "$(APPLE_ID)" \
		--team-id "$(TEAM_ID)" \
		--wait
	xcrun stapler staple $(APP_BUNDLE)
	@echo "Notarized and stapled."
