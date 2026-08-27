SHELL := /bin/bash
.DEFAULT_GOAL := help

DB_URL ?= postgres://openledger:openledger@localhost:5433/openledger?sslmode=disable

.PHONY: help
help: ## List targets
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

.PHONY: up
up: ## Start local postgres
	docker compose up -d
	@echo "waiting for postgres..."
	@until docker compose exec -T db pg_isready -U openledger -q; do sleep 0.3; done
	@echo "ready on $(DB_URL)"

.PHONY: down
down: ## Stop local postgres
	docker compose down

.PHONY: reset
reset: ## Drop and recreate the local database
	docker compose down -v && $(MAKE) up && $(MAKE) migrate chart

.PHONY: migrate
migrate: ## Apply the migrations (debug build; a deploy runs the release binary)
	@# DATABASE_URL, not --database-url: the flag is visible in `ps` to anyone
	@# on the host, and this target is the example operators copy.
	DATABASE_URL="$(DB_URL)" cargo run --quiet -- migrate

.PHONY: chart
chart: ## Seed the reference chart of accounts (an EXAMPLE; yours will differ)
	@psql "$(DB_URL)" -v ON_ERROR_STOP=1 --single-transaction -q -f schema/chart.sql
	@echo "  seeded schema/chart.sql"

.PHONY: psql
psql: ## Open a psql shell
	psql "$(DB_URL)"

.PHONY: test
test: ## Run the tests
	cargo test

.PHONY: build
build: ## Build the binary
	cargo build --release

.PHONY: docs
docs: ## Serve the docs site at localhost:3000 (needs Node)
	cd site && npm install --silent && npm run dev

.PHONY: docs-build
docs-build: ## Build the docs site to site/out/ -- plain files, host them anywhere
	cd site && npm install --silent && npm run build
	@echo "  built site/out/"

.PHONY: tidy
tidy: ## Check formatting and lints
	cargo fmt --check && cargo clippy --all-targets -- -D warnings
