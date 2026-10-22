SWIFTW := scripts/swiftw
# Architecture of the Chromium build and of the packaged app: `make app ARCH=x86_64` cross-builds the Intel app on an
# Apple Silicon Mac. `build`, `test` and `run` always use this machine's architecture.
ARCH ?= $(shell uname -m)

.PHONY: build test run app cef dmg clean
.DEFAULT_GOAL := build

# Chromium (CEF) is the only engine, and every Swift build links it. Preparing it is
# idempotent: the pinned archive is verified (downloaded once) and the wrapper is rebuilt
# incrementally for ARCH.
cef:
	python3 engine/tool.py fetch --arch $(ARCH)
	python3 engine/tool.py build --arch $(ARCH)
build: cef
	$(SWIFTW) build
test: cef
	$(SWIFTW) test
# CEF cannot run from an unbundled `swift run`; launch the bundled app instead.
run: app
	open dist/Cairn.app
app: cef
	ARCH=$(ARCH) scripts/bundle-app.sh
dmg: app
	scripts/make-dmg.sh
clean:
	rm -rf .build dist
