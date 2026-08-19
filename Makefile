.DEFAULT_GOAL := help
SHELL := /bin/bash

APP := dist/Densha.app
CLI := $(APP)/Contents/Helpers/densha
DAEMON_LOG := $(HOME)/.local/state/densha/denshad.log

.PHONY: help build test fmt lint hooks hook-check xcode app app-debug run stop restart-app \
	status logs icon install install-agent uninstall-agent sign-check signing notarize verify-release release clean

help:
	@echo "Densha — make targets"
	@echo
	@printf '%s\n' \
		"  build            Build every target (debug)" \
		"  test             Run the test suite" \
		"  fmt              Format Swift sources in place" \
		"  lint             Report formatting problems without changing anything" \
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
		"  verify-release   Fail unless the app is notarized and accepted" \
		"  release          Bump, commit, tag and push: make release VERSION=0.1.2" \
		"  clean            Remove build artifacts"

build:
	swift build

test:
	swift test

fmt:
	swift format --in-place --recursive Sources Tests

lint:
	swift format lint --recursive --strict Sources Tests

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
	@echo "codesigning identities in this keychain:"
	@security find-identity -v -p codesigning 2>/dev/null | sed 's/^/  /' || echo "  (none)"
	@echo
	@CN=$$(security find-identity -v -p codesigning 2>/dev/null \
		| grep -m1 -E 'Developer ID Application|Apple Development' \
		| sed -E 's/^[^"]*"([^"]*)".*/\1/'); \
	TEAM=$$(security find-certificate -c "$$CN" -p 2>/dev/null \
		| openssl x509 -noout -subject 2>/dev/null \
		| tr '/' '\n' | sed -n 's/^OU=//p' | head -1); \
	if security find-identity -v -p codesigning 2>/dev/null | grep -q 'Developer ID Application'; then \
		echo "Developer ID Application: present — 'make notarize' will pick it up"; \
	else \
		echo "Developer ID Application: MISSING (local ad-hoc builds still work here)"; \
		echo; \
		echo "Xcode only auto-issues 'Apple Development' certificates; a Developer ID"; \
		echo "must be added by hand. Requires a paid membership and Account Holder/Admin:"; \
		echo "  Xcode > Settings > Accounts > select the team"; \
		echo "    > Manage Certificates > + > Developer ID Application"; \
	fi; \
	echo; \
	if [ -n "$$TEAM" ]; then \
		echo "team id (from certificate OU): $$TEAM"; \
		echo "one-time notary credentials:"; \
		echo "  xcrun notarytool store-credentials densha \\"; \
		echo "    --apple-id YOUR_APPLE_ID --team-id $$TEAM"; \
		echo "  (password is an app-specific password from appleid.apple.com)"; \
	else \
		echo "no Apple certificate found, so no team id to report"; \
	fi
	@echo
	@printf "notarytool profile '%s': " "$${NOTARY_PROFILE:-densha}"
	@xcrun notarytool history --keychain-profile "$${NOTARY_PROFILE:-densha}" >/dev/null 2>&1 \
		&& echo "configured" || echo "not configured"

notarize:
	@set -eu; \
	IDENTITY="$${DENSHA_SIGN_IDENTITY:-}"; \
	if [ -z "$$IDENTITY" ]; then \
		IDENTITY=$$(security find-identity -v -p codesigning 2>/dev/null \
			| grep -m1 'Developer ID Application' \
			| sed -E 's/^[^"]*"([^"]*)".*/\1/'); \
	fi; \
	if [ -z "$$IDENTITY" ]; then \
		echo "no Developer ID Application certificate found."; \
		echo "an 'Apple Development' certificate cannot notarize — run 'make signing'."; \
		exit 1; \
	fi; \
	if [ -n "$${NOTARY_PROFILE:-}" ]; then \
		set -- --keychain-profile "$$NOTARY_PROFILE"; \
	elif [ -n "$${NOTARY_APPLE_ID:-}" ] && [ -n "$${NOTARY_PASSWORD:-}" ] \
		&& [ -n "$${NOTARY_TEAM_ID:-}" ]; then \
		set -- --apple-id "$$NOTARY_APPLE_ID" --team-id "$$NOTARY_TEAM_ID" \
			--password "$$NOTARY_PASSWORD"; \
	else \
		echo "no notary credentials. Either:"; \
		echo "  NOTARY_PROFILE=<name>                       (a stored keychain profile)"; \
		echo "  NOTARY_APPLE_ID + NOTARY_PASSWORD + NOTARY_TEAM_ID   (for CI)"; \
		echo "run 'make signing' for the one-time setup."; \
		exit 1; \
	fi; \
	echo "==> signing as $$IDENTITY"; \
	DENSHA_SIGN_IDENTITY="$$IDENTITY" ./Scripts/build-app.sh release; \
	rm -f dist/Densha.zip; \
	ditto -c -k --keepParent $(APP) dist/Densha.zip; \
	echo "==> notarizing"; \
	xcrun notarytool submit dist/Densha.zip "$$@" --wait; \
	xcrun stapler staple $(APP); \
	rm -f dist/Densha.zip; \
	ditto -c -k --keepParent $(APP) dist/Densha.zip; \
	echo "==> stapled; dist/Densha.zip is the release asset"

verify-release:
	@set -eu; \
	xcrun stapler validate $(APP) >/dev/null 2>&1 \
		|| { echo "FAIL: no stapled notarization ticket"; exit 1; }; \
	out=$$(spctl -a -vv $(APP) 2>&1); \
	echo "$$out" | sed 's/^/  /'; \
	echo "$$out" | grep -q 'accepted' \
		|| { echo "FAIL: Gatekeeper did not accept the bundle"; exit 1; }; \
	codesign -dv $(APP) 2>&1 | grep -q 'adhoc' \
		&& { echo "FAIL: bundle is ad-hoc signed"; exit 1; } || true; \
	echo "  OK: notarized, stapled, accepted"

release:
	@set -eu; \
	if [ -z "$${VERSION:-}" ]; then \
		echo "usage: make release VERSION=0.1.2"; exit 1; \
	fi; \
	case "$$VERSION" in \
		v*) echo "drop the leading v: VERSION=$${VERSION#v}"; exit 1;; \
	esac; \
	if ! printf '%s' "$$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$$'; then \
		echo "VERSION must look like 0.1.2"; exit 1; \
	fi; \
	if [ -n "$$(git status --porcelain)" ]; then \
		echo "working tree is dirty — commit or stash first"; exit 1; \
	fi; \
	if [ "$$(git branch --show-current)" != "main" ]; then \
		echo "releases are cut from main, not $$(git branch --show-current)"; exit 1; \
	fi; \
	if git rev-parse -q --verify "refs/tags/v$$VERSION" >/dev/null; then \
		echo "tag v$$VERSION already exists"; exit 1; \
	fi; \
	sed -i '' -E 's/version: "[0-9]+\.[0-9]+\.[0-9]+"/version: "'"$$VERSION"'"/' \
		Sources/densha/CLI.swift; \
	grep -q 'version: "'"$$VERSION"'"' Sources/densha/CLI.swift \
		|| { echo "failed to set the version in Sources/densha/CLI.swift"; exit 1; }; \
	$(MAKE) --no-print-directory test; \
	git add Sources/densha/CLI.swift; \
	git commit -m "chore: release v$$VERSION"; \
	git tag "v$$VERSION"; \
	git push origin main "v$$VERSION"; \
	echo "pushed v$$VERSION — follow it with: gh run watch"

clean:
	-swift package clean
	rm -rf .build dist build
