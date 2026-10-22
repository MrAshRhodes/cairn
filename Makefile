SWIFTW := scripts/swiftw

.PHONY: build test run app chromium-app cef webkit-build webkit-run webkit-app dmg clean

# Chromium (CEF) is the default local engine. Preparing it is idempotent: the pinned
# archive is verified (downloaded once) and the wrapper is rebuilt incrementally for
# the host architecture.
cef:
	python3 engine/tool.py fetch
	python3 engine/tool.py build
build: cef
	CAIRN_WITH_CHROMIUM=1 $(SWIFTW) build
# Unit and integration tests exercise WebKit and need no CEF.
test:
	CAIRN_WITH_CHROMIUM=0 $(SWIFTW) test
# CEF cannot run from an unbundled `swift run`; launch the bundled app instead.
run: chromium-app
	open dist/Cairn.app
app: chromium-app
chromium-app: cef
	CAIRN_WITH_CHROMIUM=1 scripts/bundle-app.sh
webkit-build:
	CAIRN_WITH_CHROMIUM=0 $(SWIFTW) build
webkit-run:
	CAIRN_WITH_CHROMIUM=0 $(SWIFTW) run Cairn
webkit-app:
	CAIRN_WITH_CHROMIUM=0 scripts/bundle-app.sh
dmg: app
	scripts/make-dmg.sh
clean:
	rm -rf .build dist
