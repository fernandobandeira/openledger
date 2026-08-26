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
	docker compose down -v && $(MAKE) up && $(MAKE) schema

.PHONY: schema
schema: ## Load the design schema and the seed chart
	@psql "$(DB_URL)" -v ON_ERROR_STOP=1 --single-transaction -q -f schema/schema.sql
	@psql "$(DB_URL)" -v ON_ERROR_STOP=1 --single-transaction -q -f schema/chart.sql
	@echo "  loaded schema/schema.sql + schema/chart.sql"

.PHONY: psql
psql: ## Open a psql shell
	psql "$(DB_URL)"

.PHONY: test
test: ## Run the Go tests
	go test ./...

.PHONY: build
build: ## Build the binary
	go build -o bin/openledger ./cmd/openledger

.PHONY: tidy
tidy: ## Tidy modules
	go mod tidy
