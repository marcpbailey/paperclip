ADAPTER_SRC    := packages/adapters/openrouter-agent

LINKCAST_ROOT  ?= $(HOME)/Projects/linkcast
ADAPTER_DEPLOY := $(LINKCAST_ROOT)/crew/paperclip/companies/linkcast/adapters/paperclip-openrouter-agent
AVENGERSTOWER  := $(LINKCAST_ROOT)/crew/paperclip/companies/linkcast/environments/avengerstower

PROJECT       := paperclip-linkcast
COMPOSE_FILES := -f docker/docker-compose.yml -f local/compose/paperclip-boot-linkcast.yaml

.PHONY: all build-adapter sync-adapter build-container stamp-agents deploy-adapter deploy-container restart update test fulltest \
        _build-paperclip-base _build-avengerstower-base \
        build-avengerstower-browser build-avengerstower-media help

test: ## Run the fast unit/integration test suite
	pnpm vitest run packages/adapters/openrouter-agent packages/adapters/openrouter-external --passWithNoTests

fulltest: ## Run the full pre-hand-off verification suite (Level 2 tests)
	pnpm -r typecheck
	pnpm test:run
	pnpm build

all: build-container build-adapter sync-adapter restart test ## Full rebuild (container + adapter), sync, restart, and fast test

stamp-agents: ## Stamp preamble into all AGENTS.md files (delegates to linkcast meta-repo)
	$(MAKE) -C $(LINKCAST_ROOT) stamp-agents

build-container: stamp-agents _build-paperclip-base _build-avengerstower-base ## Rebuild server image (stamp agents → paperclip base → avengerstower/base layer)

_build-paperclip-base: ## Build the upstream paperclip base image from source
	docker build \
	    --build-arg GIT_SHA=$$(git rev-parse --short HEAD) \
	    --build-arg BUILD_DATE=$$(date -u +%Y-%m-%dT%H:%M:%SZ) \
	    -t paperclip-local:latest \
	    -f Dockerfile \
	    .

_build-avengerstower-base: ## Build the avengerstower/base layer on top of paperclip-local
	docker build \
	    --build-arg BASE_IMAGE=paperclip-local:latest \
	    -t linkcast/avengerstower-base:latest \
	    $(AVENGERSTOWER)/base

build-avengerstower-browser: ## Build the avengerstower/browser environment (playwright + chromium)
	docker build \
	    --build-arg BASE_IMAGE=linkcast/avengerstower-base:latest \
	    -t linkcast/avengerstower-browser:latest \
	    $(AVENGERSTOWER)/browser

build-avengerstower-media: ## Build the avengerstower/media environment (ffmpeg, vlc, mpv)
	docker build \
	    --build-arg BASE_IMAGE=linkcast/avengerstower-base:latest \
	    -t linkcast/avengerstower-media:latest \
	    $(AVENGERSTOWER)/media

build-adapter: ## Compile the openrouter-agent adapter (npm run build only)
	cd $(ADAPTER_SRC) && npm run build
	printf '{"version":"%s","gitSha":"%s","buildDate":"%s"}\n' \
	    "$$(node -p "require('./$(ADAPTER_SRC)/package.json').version")" \
	    "$$(git rev-parse --short HEAD)" \
	    "$$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
	    > $(ADAPTER_SRC)/dist/build-info.json

sync-adapter: ## Sync compiled adapter to the linkcast crew overlay
	mkdir -p $(ADAPTER_DEPLOY)
	rsync -a --delete --exclude=node_modules $(ADAPTER_SRC)/ $(ADAPTER_DEPLOY)/

deploy-adapter: build-adapter sync-adapter restart ## Compile adapter, sync to overlay, and restart

deploy-container: build-container restart ## Rebuild server image and restart

update: ## Sync local main with an upstream release (VERSION=vX.Y.Z to skip prompt)
	git fetch origin
	@if [ -n "$(VERSION)" ]; then \
	    target="origin/release/$(VERSION)"; \
	else \
	    echo "Recent releases:"; \
	    branches=$$(git branch -r | grep 'origin/release/v' | sort -V | tail -10 | tac | sed 's|.*origin/release/||'); \
	    echo "  0) Abort (default)"; \
	    echo "$$branches" | awk '{print "  "NR") "$$0}'; \
	    printf "Select number [0]: "; \
	    read choice; \
	    choice=$${choice:-0}; \
	    if [ "$$choice" = "0" ]; then echo "Aborted."; exit 0; fi; \
	    ver=$$(echo "$$branches" | sed -n "$${choice}p"); \
	    target="origin/release/$$ver"; \
	fi; \
	echo "Merging $$target" && \
	git merge "$$target" && \
	git push fork main && \
	git push paperclip main

restart: ## Restart the Paperclip stack (via paperclip-control.sh)
	./local/bin/paperclip-control.sh restart

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?##' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-20s %s\n", $$1, $$2}'
