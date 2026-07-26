# Claude Sandbox — development tasks.
#
# Every tool runs from a pinned container image when it isn't installed
# locally, so the only hard requirement is Docker (which this project already
# needs). Nothing here installs anything on your machine.

SHELL := /bin/bash
.DEFAULT_GOAL := help

IMAGE       ?= claude-sandbox
REGISTRY    ?= ghcr.io/rsh3khar/claude-sandbox
CURRENT     := $(shell sed -n 's/^VERSION="\(.*\)".*/\1/p' claude-sandbox | head -1)
VCS_REF     := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
SHELL_FILES := claude-sandbox install.sh runtime/entrypoint.sh runtime/auto-git.sh tests/image-smoke.sh tests/portability.sh

DOCKER_RUN := docker run --rm -v "$(PWD):/work" -w /work

SHELLCHECK  := $(shell command -v shellcheck 2>/dev/null)
SHFMT       := $(shell command -v shfmt 2>/dev/null)
BATS        := $(shell command -v bats 2>/dev/null)

## help: Show this help
.PHONY: help
help:
	@echo ""
	@echo "  Claude Sandbox $(CURRENT)"
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
	@$(DOCKER_RUN) --entrypoint sh bats/bats:latest -c \
		'apk add --no-cache git >/dev/null 2>&1; exec bats tests/unit'
endif

## test-image: Smoke-test the built image (needs a built image)
.PHONY: test-image
test-image: build
	@echo "==> image smoke tests"
	@IMAGE=$(IMAGE) ./tests/image-smoke.sh

## portability: Run pure-function checks under the system bash (3.2 on macOS)
.PHONY: portability
portability:
	@echo "==> portability (system bash)"
	@./tests/portability.sh /bin/bash

## check: lint + test + portability (run before pushing)
.PHONY: check
check: lint test portability
# fmt-check is deliberately not part of `check` or CI. This codebase aligns
# case arms and box-drawing calls into columns on purpose, and shfmt collapses
# that. shellcheck is what catches real defects; formatting stays a judgement
# call. `make fmt` is here if you want it.

## build: Build the sandbox image locally
.PHONY: build
build:
	@echo "==> docker build $(IMAGE):$(CURRENT)"
	@DOCKER_BUILDKIT=1 docker build \
		--build-arg VERSION=$(CURRENT) \
		--build-arg VCS_REF=$(VCS_REF) \
		-t $(IMAGE) -t $(IMAGE):$(CURRENT) .

## rebuild: Build with --no-cache (picks up latest agent CLIs)
.PHONY: rebuild
rebuild:
	@DOCKER_BUILDKIT=1 docker build --no-cache \
		--build-arg VERSION=$(CURRENT) \
		--build-arg VCS_REF=$(VCS_REF) \
		-t $(IMAGE) -t $(IMAGE):$(CURRENT) .

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
	@echo "Current version: $(CURRENT)"
	@echo ""
	@echo "Commits since last tag:"
	@git log $$(git describe --tags --abbrev=0 2>/dev/null)..HEAD --oneline 2>/dev/null || git log --oneline

## release: Cut a release — make release VERSION=0.4.0
.PHONY: release
release:
	@test -n "$(VERSION)" || { echo "usage: make release VERSION=0.4.0"; exit 1; }
	@echo "$(VERSION)" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$$' \
		|| { echo "VERSION must be x.y.z (no leading v)"; exit 1; }
	@test -z "$$(git status --porcelain)" \
		|| { echo "working tree is dirty — commit first"; exit 1; }
	@test "$$(git rev-parse --abbrev-ref HEAD)" = "main" \
		|| { echo "not on main"; exit 1; }
	@git rev-parse "v$(VERSION)" >/dev/null 2>&1 \
		&& { echo "tag v$(VERSION) already exists"; exit 1; } || true
	@$(MAKE) --no-print-directory check
	@echo "==> version -> $(VERSION)"
	@sed -i.bak 's/^VERSION="[^"]*"/VERSION="$(VERSION)"/' claude-sandbox && rm -f claude-sandbox.bak
	@grep -q 'VERSION="$(VERSION)"' claude-sandbox || { echo "version bump failed"; exit 1; }
	@echo "==> CHANGELOG"
	@prev=$$(git describe --tags --abbrev=0 2>/dev/null || echo ""); 	 range=$${prev:+$$prev..}HEAD; 	 { 	   echo "# Changelog"; echo ""; 	   echo "All notable changes to this project are documented here."; echo ""; 	   echo "## [$(VERSION)] - $$(date +%Y-%m-%d)"; echo ""; 	   for t in feat fix perf refactor docs; do 	     case $$t in 	       feat) title="Features" ;; fix) title="Bug Fixes" ;; perf) title="Performance" ;; 	       refactor) title="Refactoring" ;; *) title="Documentation" ;; 	     esac; 	     body=$$(git log $$range --pretty=format:'%s' | sed -n "s/^$$t: /- /p"); 	     if [ -n "$$body" ]; then echo "### $$title"; echo ""; echo "$$body"; echo ""; fi; 	   done; 	   tail -n +4 CHANGELOG.md; 	 } > CHANGELOG.new && mv CHANGELOG.new CHANGELOG.md
	@git add claude-sandbox CHANGELOG.md
	@git commit -q -m "chore: release v$(VERSION)"
	@git tag -a "v$(VERSION)" -m "v$(VERSION)"
	@echo ""
	@echo "  Tagged v$(VERSION). Nothing is published yet."
	@echo "  Push to trigger the release workflow:"
	@echo "    git push origin main --follow-tags"
	@echo ""

## clean: Remove local images and build cache
.PHONY: clean
clean:
	@docker image rm -f $(IMAGE) $(IMAGE):$(CURRENT) 2>/dev/null || true
	@docker builder prune -f --filter until=24h
