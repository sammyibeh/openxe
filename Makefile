# OpenXE — developer entry points. Thin wrappers over scripts/ and SwiftPM.
# Run `make` (or `make help`) for the list.

.DEFAULT_GOAL := help
.PHONY: help build test app engine package-engine fresh clean

help: ## Show this help
	@echo "OpenXE make targets:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "} {printf "  \033[1m%-16s\033[0m %s\n", $$1, $$2}'

build: ## Compile (release) with SwiftPM
	swift build -c release

test: ## Run unit + gated integration tests
	swift test

app: ## Build, ad-hoc sign, and install OpenXE.app to /Applications (scripts/build-app.sh)
	scripts/build-app.sh

engine: ## Build a Wine-Crossover engine from LGPL source (needs ~10-15 GB free; scripts/build-engine.sh)
	scripts/build-engine.sh

package-engine: ## Tar a built engine + compute SHA-256 + print an EngineDescriptor (scripts/package-engine.sh)
	scripts/package-engine.sh

fresh: ## Wipe all OpenXE state back to first-run (scripts/reset-fresh.sh; preview with ARGS=--dry-run)
	scripts/reset-fresh.sh $(ARGS)

clean: ## Remove SwiftPM build products and dist/
	rm -rf .build dist
