SWIFTW := scripts/swiftw

.PHONY: build test run app chromium-app webkit-app dmg clean
build:
	$(SWIFTW) build
test:
	$(SWIFTW) test
run:
	$(SWIFTW) run Cairn
app: chromium-app
chromium-app:
	CAIRN_WITH_CHROMIUM=1 scripts/bundle-app.sh
webkit-app:
	CAIRN_WITH_CHROMIUM=0 scripts/bundle-app.sh
dmg: app
	scripts/make-dmg.sh
clean:
	rm -rf .build dist
