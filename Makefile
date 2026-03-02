APP_NAME     = Scrolly
BUNDLE_ID    = com.bcardiff.scrolly
BUILD_DIR    = .build/release
APP_BUNDLE   = $(APP_NAME).app
BINARY       = $(BUILD_DIR)/$(APP_NAME)
ENTITLEMENTS = Resources/Scrolly.entitlements
PLIST        = Resources/Info.plist

.PHONY: build app install clean run

build:
	swift build -c release

app: build
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	mkdir -p $(APP_BUNDLE)/Contents/Resources
	cp $(BINARY)     $(APP_BUNDLE)/Contents/MacOS/
	cp $(PLIST)      $(APP_BUNDLE)/Contents/
	# Ad-hoc sign with entitlements (no Apple Developer account needed)
	codesign --sign - \
	         --entitlements $(ENTITLEMENTS) \
	         --force \
	         --options runtime \
	         $(APP_BUNDLE)
	@echo ""
	@echo "Built $(APP_BUNDLE)"
	@echo "Grant Accessibility permission in:"
	@echo "  System Settings → Privacy & Security → Accessibility"

install: app
	cp -r $(APP_BUNDLE) /Applications/
	@echo "Installed to /Applications/$(APP_BUNDLE)"

run: app
	open $(APP_BUNDLE)

clean:
	rm -rf $(APP_BUNDLE) .build
