# Claude Sandbox — development tasks.
#
# Every tool runs from a pinned container image when it isn't installed
# locally, so the only hard requirement is Docker (which this project already
# needs). Nothing here installs anything on your machine.

SHELL := /bin/bash
.DEFAULT_GOAL := help

IMAGE       ?= claude-sandbox
REGISTRY    ?= ghcr.io/rsh3khar/claude-sandbox
VERSION     := $(shell sed -n 's/^VERSION="\(.*\)".*/\1/p' claude-sandbox | head -1)
VCS_REF     := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
SHELL_FILES := claude-sandbox install.sh runtime/entrypoint.sh runtime/auto-git.sh tests/image-smoke.sh

DOCKER_RUN := docker run --rm -v "$(PWD):/work" -w /work

SHELLCHECK  := $(shell command -v shellcheck 2>/dev/null)
SHFMT       := $(shell command -v shfmt 2>/dev/null)
BATS        := $(shell command -v bats 2>/dev/null)

## help: Show this help
.PHONY: help
help:
	@echo ""
	@echo "  Claude Sandbox $(VERSION)"
	@echo ""
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/## /  /' | awk -F': ' '{printf "  \033[33m%-16s\033[0m %s\n", $$1, $$2}'
	@echo ""

## lint: Run shellcheck + hadolint
.PHONY: lint
lint: lint-shell lint-docker

.PHONY: lint-shell
lint-shell:
	@echo "==> shellcheck"
ifdef SHELLCHECK
	@shellcheck --severity=warning $(SHELL_FILES)
else
	@$(DOCKER_RUN) koalaman/shellcheck:stable --severity=warning $(SHELL_FILES)
endif

.PHONY: lint-docker
lint-docker:
	@echo "==> hadolint"
	@$(DOCKER_RUN) hadolint/hadolint hadolint --ignore DL3008 --ignore DL3013 --ignore DL4006 --ignore DL3003 Dockerfile

## fmt: Format shell scripts in place
.PHONY: fmt
fmt:
	@echo "==> shfmt -w"
ifdef SHFMT
	@shfmt -i 4 -ci -w $(SHELL_FILES)
else
	@$(DOCKER_RUN) mvdan/shfmt:v3 -i 4 -ci -w $(SHELL_FILES)
endif

## fmt-check: Verify formatting without writing
.PHONY: fmt-check
fmt-check:
	@echo "==> shfmt -d"
ifdef SHFMT
	@shfmt -i 4 -ci -d $(SHELL_FILES)
else
	@$(DOCKER_RUN) mvdan/shfmt:v3 -i 4 -ci -d $(SHELL_FILES)
endif

## test: Run unit tests (no Docker daemon needed)
.PHONY: test
test:
	@echo "==> bats unit tests"
ifdef BATS
	@bats tests/unit
else
	@$(DOCKER_RUN) bats/bats:latest tests/unit
endif

## test-image: Smoke-test the built image (needs a built image)
.PHONY: test-image
test-image: build
	@echo "==> image smoke tests"
	@IMAGE=$(IMAGE) ./tests/image-smoke.sh

## check: lint + fmt-check + test
.PHONY: check
check: lint fmt-check test

## build: Build the sandbox image locally
.PHONY: build
build:
	@echo "==> docker build $(IMAGE):$(VERSION)"
	@DOCKER_BUILDKIT=1 docker build \
		--build-arg VERSION=$(VERSION) \
		--build-arg VCS_REF=$(VCS_REF) \
		-t $(IMAGE) -t $(IMAGE):$(VERSION) .

## rebuild: Build with --no-cache (picks up latest agent CLIs)
.PHONY: rebuild
rebuild:
	@DOCKER_BUILDKIT=1 docker build --no-cache \
		--build-arg VERSION=$(VERSION) \
		--build-arg VCS_REF=$(VCS_REF) \
		-t $(IMAGE) -t $(IMAGE):$(VERSION) .

## dev: Symlink ~/.claude-sandbox to this repo, then build
.PHONY: dev
dev:
	@./install.sh --link --skip-build
	@$(MAKE) build

## run: Launch a sandbox on this repo using the local script
.PHONY: run
run:
	@./claude-sandbox . --no-pull

## dry-run: Print the docker command this repo would launch with
.PHONY: dry-run
dry-run:
	@./claude-sandbox . --dry-run --no-pull

## release-dry: Show what the next release would contain
.PHONY: release-dry
release-dry:
	@echo "Current version: $(VERSION)"
	@echo ""
	@echo "Commits since last tag:"
	@git log $$(git describe --tags --abbrev=0 2>/dev/null)..HEAD --oneline 2>/dev/null || git log --oneline

## clean: Remove local images and build cache
.PHONY: clean
clean:
	@docker image rm -f $(IMAGE) $(IMAGE):$(VERSION) 2>/dev/null || true
	@docker builder prune -f --filter until=24h
