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
test: ## Run all tests on the `make up` postgres; without DATABASE_URL, `cargo test --workspace` self-starts a container
	@# Bare `cargo test` tests only the binary crate (default-members); the
	@# container fallback fires for `cargo test --workspace` / `-p e2e` run
	@# without DATABASE_URL. The e2e suite (crates/e2e) spawns the compiled
	@# `openledger` binary resolved from the test executable's own path — a
	@# separate crate never sees CARGO_BIN_EXE_* — and resolving an existing
	@# file guarantees no build, so build the binary explicitly first.
	cargo build -p openledger
	DATABASE_URL="$(DB_URL)" cargo test --workspace

.PHONY: openapi
openapi: ## Regenerate crates/api/openapi.json from the annotations
	@# The committed spec is written by the snapshot test itself, under an
	@# explicit opt-in — so a normal test run can only ever FAIL on drift,
	@# never paper over it by rewriting the file it was about to compare.
	OPENLEDGER_WRITE_SPEC=1 cargo test -p api --test spec

.PHONY: openapi-check
openapi-check: ## Fail if crates/api/openapi.json drifted from the annotations
	cargo test -p api --test spec

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
	cargo fmt --check && cargo clippy --workspace --all-targets -- -D warnings

.PHONY: deny
deny: ## Check dependencies against deny.toml (CI always runs this; local needs cargo-deny installed)
	@# Not part of `tidy` on purpose: tidy must not fail on a machine that
	@# has no cargo-deny. CI runs the same check unconditionally.
	cargo deny check
