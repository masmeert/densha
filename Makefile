.DEFAULT_GOAL := help
SHELL := /bin/bash

APP := dist/Densha.app
CLI := $(APP)/Contents/Helpers/densha
DAEMON_LOG := $(HOME)/.local/state/densha/denshad.log

.PHONY: help build test fmt lint lint-scripts version xcode hooks hook-check app app-debug run stop restart-app \
	status logs icon install install-agent uninstall-agent sign-check signing notarize dsyms smoke \
	appcast verify-appcast changelog validate-changelog verify-release release clean

help:
	@echo "Densha — make targets"
	@echo
	@printf '%s\n' \
		"  build            Build every target (debug)" \
		"  test             Run the test suite" \
		"  fmt              Format Swift sources in place" \
		"  lint             Report formatting and version problems without changing anything" \
		"  lint-scripts     Syntax-check every shell script" \
		"  version          Regenerate Sources/DenshaCore/Version.swift from version.env" \
		"  hooks            Install the local pre-commit hook" \
		"  hook-check       Run the pre-commit hook on every Swift file" \
		"  xcode            Open the package in Xcode" \
		"  app              Build Densha.app (release)" \
		"  app-debug        Build Densha.app (debug)" \
		"  run              Rebuild (debug) and relaunch the app" \
		"  restart-app      Alias for run" \
		"  stop             Quit the app and stop the daemon" \
		"  icon             Regenerate Resources/Densha.icns" \
		"  install          Build, then symlink densha onto PATH" \
		"  install-agent    Start denshad at login via launchd" \
		"  uninstall-agent  Stop starting denshad at login" \
		"  status           Show service status" \
		"  logs             Follow the daemon's own log" \
		"  sign-check       Show the bundle's signature and Gatekeeper verdict" \
		"  signing          Report signing and notarizing availability" \
		"  notarize         Sign, notarize and staple for distribution" \
		"  dsyms            Verify and zip the release dSYMs" \
		"  smoke            Launch-test the packaged app as a user machine would" \
		"  appcast          Regenerate appcast.xml from the published release" \
		"  verify-appcast   Check appcast.xml is signed and matches version.env" \
		"  changelog        Print this version's release notes as HTML" \
		"  validate-changelog  Fail unless CHANGELOG.md documents this version" \
		"  verify-release   Fail unless the app is notarized and accepted" \
		"  release          Bump version.env, commit, tag and push: make release VERSION=0.1.2" \
		"  clean            Remove build artifacts"

build:
	swift build

test:
	swift test

fmt:
	swift format --in-place --recursive Sources Tests

lint: lint-scripts
	./Scripts/sync-version.sh --check
	swift format lint --recursive --strict Sources Tests

lint-scripts:
	@count=0; \
	for script in Scripts/*.sh; do \
		bash -n "$$script"; \
		count=$$((count + 1)); \
	done; \
	printf 'shell scripts OK: %d files\n' "$$count"

version:
	./Scripts/sync-version.sh

hooks:
	mise install
	mise exec -- pre-commit install

hook-check:
	mise exec -- pre-commit run --all-files

xcode:
	open Package.swift

app:
	./Scripts/build-app.sh release

app-debug:
	./Scripts/build-app.sh debug

run: app-debug
	-@pkill -f "Densha.app/Contents/MacOS/Densha" 2>/dev/null || true
	@sleep 0.5
	open $(APP)

restart-app: run

stop:
	-@pkill -f "Densha.app/Contents/MacOS/Densha" 2>/dev/null || true
	@sleep 0.5
	-@pkill -f "Helpers/denshad" 2>/dev/null || true
	@echo "app and daemon stopped"

icon:
	swift Scripts/make-icon.swift

install: app
	$(CLI) install-cli

install-agent: app
	$(CLI) daemon install

uninstall-agent:
	-$(CLI) daemon uninstall

status:
	@$(CLI) status

logs:
	tail -f "$(DAEMON_LOG)"

sign-check:
	@codesign --verify --strict --verbose=2 $(APP)
	@codesign -dv $(APP) 2>&1 | grep -E 'flags|Signature|TeamIdentifier|Identifier=' || true
	@echo "--- gatekeeper ---"
	-@spctl -a -vv $(APP) 2>&1 || true

signing:
	@./Scripts/signing-status.sh

notarize:
	./Scripts/notarize.sh

dsyms:
	./Scripts/package-dsyms.sh

smoke:
	./Scripts/verify-app-launch.sh $(APP)

appcast:
	./Scripts/make-appcast.sh

verify-appcast:
	@./Scripts/verify-appcast.sh

changelog:
	@./Scripts/changelog-to-html.sh

validate-changelog:
	@./Scripts/validate-changelog.sh

verify-release:
	@./Scripts/verify-release.sh $(APP)

release:
	@if [ -z "$(VERSION)" ]; then \
		echo "usage: make release VERSION=0.1.2"; exit 1; \
	fi
	./Scripts/release.sh "$(VERSION)"

clean:
	-swift package clean
	rm -rf .build dist build
