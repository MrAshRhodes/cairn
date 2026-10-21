SWIFTW := scripts/swiftw

.PHONY: build test run app dmg clean
build:
	$(SWIFTW) build
test:
	$(SWIFTW) test
run:
	$(SWIFTW) run Cairn
app:
	scripts/bundle-app.sh
dmg: app
	scripts/make-dmg.sh
clean:
	rm -rf .build dist
