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
	docker compose down -v && $(MAKE) up && $(MAKE) migrate

.PHONY: migrate
migrate: ## Apply migrations in order
	@shopt -s nullglob; \
	files=(migrations/*.sql); \
	if [ $${#files[@]} -eq 0 ]; then echo "  no migrations yet"; exit 0; fi; \
	for f in "$${files[@]}"; do echo "  $$f"; psql "$(DB_URL)" -v ON_ERROR_STOP=1 -q -f "$$f" || exit 1; done

.PHONY: psql
psql: ## Open a psql shell
	psql "$(DB_URL)"

.PHONY: test
test: ## Run tests
	go test ./...

.PHONY: build
build: ## Build the binary
	go build -o bin/openledger ./cmd/openledger

.PHONY: tidy
tidy: ## Tidy modules
	go mod tidy
