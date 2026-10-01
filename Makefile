# Only if the caller hasn't already chosen a toolchain (`$DEVELOPER_DIR`, or
# `sudo xcode-select -s`) and the standard path actually exists — exporting a
# path that isn't there breaks every target with `xcrun: missing DEVELOPER_DIR`
# on a machine that only has the Command Line Tools installed.
ifeq (,$(DEVELOPER_DIR))
ifneq (,$(wildcard /Applications/Xcode.app/Contents/Developer))
export DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer
endif
endif

PROJECT := Codenotch.xcodeproj
SCHEME  := Codenotch
RESOLVED_PACKAGES := $(PROJECT)/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
ARCH    ?= $(shell uname -m)
DEST    ?= platform=macOS,arch=$(ARCH)

# Every build product, module cache and SwiftPM checkout stays inside the repo.
# That is what keeps `rm -rf DerivedData` honest, and it is also the difference
# between working and not working under a harness-confined shell: DSH runs bash
# in a macOS Seatbelt sandbox that allows writes only under the workspace, /tmp
# and $TMPDIR, while Xcode's default derived data lives in ~/Library/Developer.
# `-showBuildSettings` takes the same flags so the app path it prints is the one
# the build actually produced.
DERIVED_DATA ?= $(CURDIR)/DerivedData
XCODE_FLAGS  := -derivedDataPath '$(DERIVED_DATA)' \
                -clonedSourcePackagesDirPath '$(DERIVED_DATA)/SourcePackages'

# Seatbelt refuses to apply a sandbox from inside a sandbox, so the two sandboxes
# the Swift toolchain applies to itself cannot start under DSH's shell sandbox:
# SwiftPM's manifest sandbox (a user default, set by tools/setup-xcode-sandbox.sh)
# and the macro plugin server's (`-disable-sandbox` on swiftc). DSH exports
# DSH_SHELL=1, so neither flag reaches a contributor's build outside DSH.
ifdef DSH_SHELL
SWIFT_SANDBOX_OFF := OTHER_SWIFT_FLAGS='$$(inherited) -disable-sandbox'
endif

# xcodegen is not on every PATH; point XCODEGEN at a release binary to override.
XCODEGEN ?= xcodegen

# Debug signs itself when the maintainer's Developer ID certificate isn't in
# the keychain, which is every machine but the maintainer's — so a contributor
# can `make build`/`make test`/`make run` with no Apple account at all, per
# CONTRIBUTING.md. On the maintainer's own machine this is empty and changes
# nothing: project.yml's stable identity is what keeps a keychain "Always
# Allow" grant alive across rebuilds, and forcing another one there would throw
# that away and bring the prompt back on every `make run`.
#
# `grep`, not `grep -c`: `-c` prints "0" rather than nothing when it matches
# nothing, so `ifeq (,...)` was never true and a machine *without* the
# certificate fell through to signing with an identity it does not have —
# "Signing for Codenotch requires a development team", on every target.
HAS_DEVELOPER_ID := $(shell security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application")

# A personal "Apple Development" certificate, where there is one, is preferred
# over ad-hoc for exactly the reason the maintainer's identity is: it is
# stable, so a keychain "Always Allow" grant survives the next rebuild, and
# working on the credential-reading paths does not mean re-granting after every
# build. Read its team from a valid signing identity: a certificate can remain
# in the keychain without its private key, and choosing it would fail the
# build. With nothing parsed, ad-hoc is the fallback and needs no Apple account.
# The team is the certificate subject's OU, not the bracketed value in the CN
# — that bracketed value is the developer's own id, which only coincides with
# the Team ID on some accounts. On a personal team it does not, so reading it
# had Xcode look for a certificate of a team that does not exist.
DEV_IDENTITY := $(shell security find-identity -v -p codesigning 2>/dev/null \
	| sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)
DEV_TEAM := $(if $(DEV_IDENTITY),$(shell security find-certificate -c "$(DEV_IDENTITY)" -p 2>/dev/null \
	| openssl x509 -noout -subject -nameopt sep_multiline 2>/dev/null \
	| sed -n 's/^ *OU=\([A-Z0-9]*\)$$/\1/p' | head -1))

ifeq (,$(HAS_DEVELOPER_ID))
ifeq (,$(DEV_TEAM))
DEV_SIGN := CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM="" CODE_SIGN_STYLE=Automatic
else
DEV_SIGN := CODE_SIGN_IDENTITY="Apple Development" CODE_SIGN_STYLE=Manual \
	DEVELOPMENT_TEAM="$(DEV_TEAM)" PROVISIONING_PROFILE_SPECIFIER=""
endif
endif

.PHONY: gen build test test-ci verify-deps run install clean

gen:
	$(XCODEGEN) generate
	mkdir -p $(dir $(RESOLVED_PACKAGES))
	cp Package.resolved $(RESOLVED_PACKAGES)

build: gen
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' \
		-configuration Debug $(DEV_SIGN) $(XCODE_FLAGS) $(SWIFT_SANDBOX_OFF) build

test: gen
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' \
		-configuration Debug $(DEV_SIGN) $(XCODE_FLAGS) $(SWIFT_SANDBOX_OFF) test

# Continuous integration: no Developer ID identity exists on a CI runner, and
# unit tests need none — override the manual signing with plain unsigned
# builds rather than asking every contributor to hold a certificate.
test-ci: gen
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' \
		-configuration Debug $(XCODE_FLAGS) $(SWIFT_SANDBOX_OFF) test \
		CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

verify-deps:
	rm -rf $(PROJECT)
	$(MAKE) gen
	xcodebuild -resolvePackageDependencies $(XCODE_FLAGS) -project $(PROJECT) -scheme $(SCHEME)
	@diff -u Package.resolved $(RESOLVED_PACKAGES) || { \
		echo "SwiftPM resolution drifted; intentionally update Package.resolved and commit it if dependencies changed."; \
		exit 1; \
	}

run: build
	@APP=$$(xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' \
		-configuration Debug $(XCODE_FLAGS) -showBuildSettings 2>/dev/null \
		| awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $$2; exit}')/Codenotch.app; \
	pkill -x Codenotch 2>/dev/null; sleep 0.5; \
	open "$$APP"

# Build a Release .app, sign it with whatever identity is available (Developer
# ID, Apple Development, or ad-hoc — the same auto-detection as `DEV_SIGN`),
# and copy it to /Applications. For a contributor who wants a permanent copy
# without the notarized release path. Gatekeeper may ask for a one-time
# right-click → Open on the first launch when the build is not Developer ID
# signed. macOS rejects a bundle whose nested code and binary carry different
# Team IDs, so the whole bundle is signed with one identity rather than left
# unsigned.
install: gen
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' \
		-configuration Release $(DEV_SIGN) $(XCODE_FLAGS) $(SWIFT_SANDBOX_OFF) build
	@APP=$$(xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' \
		-configuration Release $(XCODE_FLAGS) -showBuildSettings 2>/dev/null \
		| awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $$2; exit}')/Codenotch.app; \
	pkill -x Codenotch || true; \
	cp -R "$$APP" /Applications/; \
	open /Applications/Codenotch.app

clean:
	rm -rf build DerivedData $(PROJECT)
