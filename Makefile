VERSION := $(shell tr -d '[:space:]' < VERSION)

.PHONY: build run install test format lint check icon snapshots screenshots zip dmg universal release-local clean

build:
	./scripts/build.sh

universal:
	ARCHS="arm64 x86_64" ./scripts/build.sh

run: build
	open build/SpaceLens.app

# Acesso Total ao Disco e "abrir ao iniciar sessão" funcionam melhor com o app em /Applications.
install: build
	rm -rf /Applications/SpaceLens.app
	cp -R build/SpaceLens.app /Applications/SpaceLens.app
	@echo "✓ /Applications/SpaceLens.app"

test:
	./scripts/test.sh

format:
	swift format -i -r Sources Tests

lint:
	swift format lint --strict -r Sources Tests

check: lint test build

icon:
	./scripts/make-icon.sh

# Captura as telas com dados de demonstração em build/snapshots (build de desenvolvimento, nunca distribuir).
snapshots:
	SNAPSHOT_TOOLS=1 ./scripts/build.sh
	rm -rf build/snapshots && mkdir -p build/snapshots
	SPACELENS_SNAPSHOT_DIR=$(CURDIR)/build/snapshots build/SpaceLens.app/Contents/MacOS/SpaceLens
	@echo "✓ build/snapshots/*.png"

# README screenshots in English and Portuguese (docs/screenshots).
screenshots:
	./scripts/screenshots.sh

zip: build
	./scripts/package.sh zip

dmg: build
	./scripts/package.sh dmg

# Same artifacts the release workflow publishes (universal binary, zip + dmg + checksums) in build/dist.
release-local: universal
	./scripts/package.sh all

clean:
	rm -rf build
