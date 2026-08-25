.DEFAULT_GOAL := help
SHELL := /bin/bash

APP := dist/Densha.app
CLI := $(APP)/Contents/Helpers/densha
DAEMON_LOG := $(HOME)/.local/state/densha/denshad.log

.PHONY: help build test fmt lint lint-scripts version xcode hooks app app-debug run stop \
	status logs icon install install-agent uninstall-agent sign-check signing notarize dsyms smoke \
	appcast verify-appcast changelog validate-changelog licenses verify-release release clean

help: ## Show this help
	@echo "Densha — make targets"
	@echo
	@grep -hE '^[a-zA-Z][a-zA-Z0-9_-]*:.*## ' $(MAKEFILE_LIST) \
		| awk -F':.*## ' '{ printf "  %-18s %s\n", $$1, $$2 }'

build: ## Build every target (debug)
	swift build

test: ## Run the test suite
	swift test

fmt: ## Format Swift sources in place
	swift format --in-place --recursive Sources Tests

lint: lint-scripts ## Report formatting and version problems without changing anything
	./Scripts/sync-version.sh --check
	swift format lint --recursive --strict Sources Tests

lint-scripts: ## Syntax-check every shell script
	@for s in Scripts/*.sh; do bash -n "$$s" || exit 1; done
	@echo "scripts OK"

version: ## Regenerate Sources/DenshaCore/Version.swift from version.env
	./Scripts/sync-version.sh

hooks: ## Install the local pre-commit hook
	@printf '%s\n' '#!/bin/sh -e' \
		"git diff --cached --name-only -z --diff-filter=ACM -- '*.swift' | xargs -0 swift format --in-place" \
		"git diff --cached --name-only -z --diff-filter=ACM -- '*.swift' | xargs -0 git add" \
		> .git/hooks/pre-commit
	@chmod +x .git/hooks/pre-commit
	@echo "installed .git/hooks/pre-commit"

xcode: ## Open the package in Xcode
	open Package.swift

app: ## Build Densha.app (release)
	./Scripts/build-app.sh release

app-debug: ## Build Densha.app (debug)
	./Scripts/build-app.sh debug

run: app-debug ## Rebuild (debug) and relaunch the app
	-@pkill -f "Densha.app/Contents/MacOS/Densha" 2>/dev/null || true
	@sleep 0.5
	-@$(CLI) daemon stop >/dev/null 2>&1 || true
	open $(APP)

stop: ## Quit the app and stop the daemon
	-@pkill -f "Densha.app/Contents/MacOS/Densha" 2>/dev/null || true
	@sleep 0.5
	-@pkill -f "Helpers/denshad" 2>/dev/null || true
	@echo "app and daemon stopped"

icon: ## Regenerate Resources/Densha.icns
	swift Scripts/make-icon.swift

install: app ## Build, then symlink densha onto PATH
	$(CLI) install-cli

install-agent: app ## Start denshad at login via launchd
	$(CLI) daemon install

uninstall-agent: ## Stop starting denshad at login
	-$(CLI) daemon uninstall

status: ## Show service status
	@$(CLI) status

logs: ## Follow the daemon's own log
	tail -f "$(DAEMON_LOG)"

sign-check: ## Show the bundle's signature and Gatekeeper verdict
	@codesign --verify --strict --verbose=2 $(APP)
	@codesign -dv $(APP) 2>&1 | grep -E 'flags|Signature|TeamIdentifier|Identifier=' || true
	@echo "--- gatekeeper ---"
	-@spctl -a -vv $(APP) 2>&1 || true

signing: ## Report signing and notarizing availability
	@./Scripts/signing-status.sh

notarize: ## Sign, notarize and staple for distribution
	./Scripts/notarize.sh

dsyms: ## Verify and zip the release dSYMs
	./Scripts/package-dsyms.sh

smoke: ## Launch-test the packaged app as a user machine would
	./Scripts/verify-app-launch.sh $(APP)

appcast: ## Regenerate appcast.xml from the published release
	./Scripts/make-appcast.sh

verify-appcast: ## Check appcast.xml is signed and matches version.env
	@./Scripts/verify-appcast.sh

changelog: ## Print this version's release notes as HTML
	@./Scripts/changelog-to-html.sh

licenses: ## Collect third-party license notices
	@./Scripts/collect-licenses.sh

validate-changelog: ## Fail unless CHANGELOG.md documents this version
	@./Scripts/validate-changelog.sh

verify-release: ## Fail unless the app is notarized and accepted
	@./Scripts/verify-release.sh $(APP)

release: ## Bump version.env, commit, tag and push: make release VERSION=0.1.2
	@if [ -z "$(VERSION)" ]; then \
		echo "usage: make release VERSION=0.1.2"; exit 1; \
	fi
	./Scripts/release.sh "$(VERSION)"

clean: ## Remove build artifacts
	-swift package clean
	rm -rf .build dist build
