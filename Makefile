# Tiled: the everyday commands. `make help` lists them.
#
# These wrap the scripts so there is one obvious spelling per task; the
# scripts remain the source of truth and are what every gate runs.

.PHONY: help build release test test-q check app app-universal install run repro mutation doctor clean

VERSION := $(shell tr -d '[:space:]' < VERSION)

help:
	@echo "Tiled $(VERSION)"
	@echo ""
	@echo "  make build      debug build (swift build)"
	@echo "  make release    release build"
	@echo "  make test       hermetic unit suite (full transcript)"
	@echo "  make test-q     hermetic unit suite (failures and summary only)"
	@echo "  make check      run the suite once and check the README test count"
	@echo "  make app        release build bundled as build/Tiled.app"
	@echo "  make app-universal  same, fat binary for Apple Silicon + Intel"
	@echo "  make install    build, install to /Applications, launch"
	@echo "  make run        run the dev build from the terminal"
	@echo "  make repro      live end-to-end suite (needs Accessibility + a quiet desktop)"
	@echo "  make doctor     read-only preflight for a live run"
	@echo "  make mutation   would the unit suite notice an injected bug?"
	@echo "  make clean      remove build products"

build:
	swift build

release:
	swift build -c release

test:
	swift test

test-q:
	./scripts/test.sh

check:
	./scripts/check-test-count.sh

app:
	./scripts/make-app.sh

app-universal:
	UNIVERSAL=1 ./scripts/make-app.sh

install:
	./scripts/install-app.sh

run:
	swift run

repro:
	./scripts/run-repro.sh

mutation:
	python3 tools/mutation/mutate.py

doctor:
	./scripts/doctor.sh

clean:
	rm -rf .build build
