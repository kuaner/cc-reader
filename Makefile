SHELL := /bin/zsh

PROJECT := CCReader.xcodeproj
PROJECT_YML := project.yml
SCHEME := CCReader
APP_NAME := CC Reader.app
DESTINATION := generic/platform=macOS
ARCHS ?= arm64 x86_64
ONLY_ACTIVE_ARCH ?= NO

XCODEGEN ?= xcodegen
XCODEBUILD ?= xcodebuild
OPEN ?= open
HDIUTIL ?= hdiutil
GIT ?= git

CONFIG ?= Debug
VERSION ?=
BUILD_NUMBER ?=
TAG_PREFIX ?= v
REMOTE ?= origin
DERIVED_DATA ?= build/DerivedData
BUILD_PRODUCTS := $(DERIVED_DATA)/Build/Products
APP_PATH := $(BUILD_PRODUCTS)/$(CONFIG)/$(APP_NAME)
ARCHIVE_PATH ?= build/CCReader.xcarchive
DMG_NAME ?= cc-reader.dmg
DMG_PATH ?= build/$(DMG_NAME)
DMG_STAGING_DIR ?= build/dmg-root
VOLNAME ?= CC Reader

.DEFAULT_GOAL := help

.PHONY: help gen open-xcode build debug release run app-path archive dmg version release-tag clean

help:
	@printf "cc-reader build helpers\n\n"
	@printf "  make gen         Generate $(PROJECT) from project.yml\n"
	@printf "  make open-xcode  Open $(PROJECT)\n"
	@printf "  make debug       Build a Debug app into $(BUILD_PRODUCTS)/Debug\n"
	@printf "  make release     Build a Release app into $(BUILD_PRODUCTS)/Release\n"
	@printf "  make run         Build with CONFIG=<Debug|Release> and open the app\n"
	@printf "  make app-path    Print the expected app bundle path for CONFIG\n"
	@printf "  make archive     Create an xcarchive at $(ARCHIVE_PATH)\n"
	@printf "  make dmg         Build Release and package $(DMG_PATH)\n"
	@printf "  make version     Update MARKETING_VERSION (and optional build number)\n"
	@printf "  make release-tag Update version, commit, tag, and push to remote\n"
	@printf "  make clean       Remove the local build directory\n\n"
	@printf "Optional overrides:\n"
	@printf "  make build CONFIG=Release\n"
	@printf "  make run CONFIG=Release\n"
	@printf "  make archive ARCHIVE_PATH=build/custom.xcarchive\n"
	@printf "  make dmg DMG_NAME=cc-reader-beta.dmg\n"
	@printf "  make build ARCHS='arm64 x86_64'\n"
	@printf "  make version VERSION=0.2.0 BUILD_NUMBER=2\n"
	@printf "  make release-tag VERSION=0.2.0 BUILD_NUMBER=2\n"

gen:
	@command -v $(XCODEGEN) >/dev/null || { echo "xcodegen not found. Install it with: brew install xcodegen"; exit 1; }
	$(XCODEGEN) generate

open-xcode: gen
	$(OPEN) $(PROJECT)

build: gen
	$(XCODEBUILD) \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIG) \
		-derivedDataPath $(DERIVED_DATA) \
		-destination '$(DESTINATION)' \
		ARCHS='$(ARCHS)' \
		ONLY_ACTIVE_ARCH=$(ONLY_ACTIVE_ARCH) \
		build

debug:
	$(MAKE) build CONFIG=Debug

release:
	$(MAKE) build CONFIG=Release

run: build
	@test -d "$(APP_PATH)" || { echo "App bundle not found at $(APP_PATH)"; exit 1; }
	$(OPEN) "$(APP_PATH)"

app-path:
	@printf "%s\n" "$(APP_PATH)"

archive: gen
	$(XCODEBUILD) \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration Release \
		-derivedDataPath $(DERIVED_DATA) \
		-archivePath $(ARCHIVE_PATH) \
		-destination '$(DESTINATION)' \
		ARCHS='$(ARCHS)' \
		ONLY_ACTIVE_ARCH=$(ONLY_ACTIVE_ARCH) \
		archive

dmg:
	$(MAKE) release CONFIG=Release
	@command -v $(HDIUTIL) >/dev/null || { echo "hdiutil not found"; exit 1; }
	@rm -rf "$(DMG_STAGING_DIR)" "$(DMG_PATH)"
	@mkdir -p "$(DMG_STAGING_DIR)"
	@cp -R "$(BUILD_PRODUCTS)/Release/$(APP_NAME)" "$(DMG_STAGING_DIR)/$(APP_NAME)"
	@ln -s /Applications "$(DMG_STAGING_DIR)/Applications"
	$(HDIUTIL) create \
		-volname "$(VOLNAME)" \
		-srcfolder "$(DMG_STAGING_DIR)" \
		-ov \
		-format UDZO \
		"$(DMG_PATH)"
	@printf "Created %s\n" "$(DMG_PATH)"

version:
	@test -n "$(VERSION)" || { echo "VERSION is required. Example: make version VERSION=0.2.0 BUILD_NUMBER=2"; exit 1; }
	@perl -0pi -e 's/MARKETING_VERSION: .*/MARKETING_VERSION: $(VERSION)/' "$(PROJECT_YML)"
	@if [ -n "$(BUILD_NUMBER)" ]; then \
		perl -0pi -e 's/CURRENT_PROJECT_VERSION: .*/CURRENT_PROJECT_VERSION: $(BUILD_NUMBER)/' "$(PROJECT_YML)"; \
	fi
	@printf "Updated %s to MARKETING_VERSION=%s" "$(PROJECT_YML)" "$(VERSION)"
	@if [ -n "$(BUILD_NUMBER)" ]; then printf ", CURRENT_PROJECT_VERSION=%s" "$(BUILD_NUMBER)"; fi
	@printf "\n"

release-tag:
	@test -n "$(VERSION)" || { echo "VERSION is required. Example: make release-tag VERSION=0.2.0 BUILD_NUMBER=2"; exit 1; }
	@test -z "$$($(GIT) status --porcelain)" || { echo "Git working tree must be clean before release-tag"; exit 1; }
	@$(GIT) rev-parse "$(TAG_PREFIX)$(VERSION)" >/dev/null 2>&1 && { echo "Tag $(TAG_PREFIX)$(VERSION) already exists"; exit 1; } || true
	$(MAKE) version VERSION=$(VERSION) BUILD_NUMBER=$(BUILD_NUMBER)
	@$(GIT) add "$(PROJECT_YML)"
	@$(GIT) commit -m "Release $(TAG_PREFIX)$(VERSION)"
	@$(GIT) tag "$(TAG_PREFIX)$(VERSION)"
	$(GIT) push $(REMOTE) HEAD
	$(GIT) push $(REMOTE) "$(TAG_PREFIX)$(VERSION)"
	@printf "Released %s (commit + tag + pushed)\n" "$(TAG_PREFIX)$(VERSION)"

clean:
	rm -rf build