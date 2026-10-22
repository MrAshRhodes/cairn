SWIFTW := scripts/swiftw

.PHONY: build test run app cef dmg clean
.DEFAULT_GOAL := build

# Chromium (CEF) is the only engine, and every Swift build links it. Preparing it is
# idempotent: the pinned archive is verified (downloaded once) and the wrapper is rebuilt
# incrementally for the host architecture.
cef:
	python3 engine/tool.py fetch
	python3 engine/tool.py build
build: cef
	$(SWIFTW) build
test: cef
	$(SWIFTW) test
# CEF cannot run from an unbundled `swift run`; launch the bundled app instead.
run: app
	open dist/Cairn.app
app: cef
	scripts/bundle-app.sh
dmg: app
	scripts/make-dmg.sh
clean:
	rm -rf .build dist
