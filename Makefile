# Task runner Makefile for @bluehotdog/reworker
#
# Usage: make [target]
# Run 'make help' to see available commands

.DEFAULT_GOAL := help
.PHONY: help install build clean dev test lint format check publish

# Colors for output
CYAN := \033[36m
GREEN := \033[32m
YELLOW := \033[33m
RESET := \033[0m

# Variables
SHELL := /bin/bash

help: ## Display this help message
	@printf "$(CYAN)Available commands:$(RESET)\n"
	@echo ""
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*##/ { printf "  $(GREEN)%-15s$(RESET) %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@echo ""

build: ## Build the ReScript project
	@printf "$(YELLOW)Building ReScript project...$(RESET)\n"
	npx rescript
	@printf "$(GREEN)Build complete!$(RESET)\n"

clean: ## Clean build artifacts
	@printf "$(YELLOW)Cleaning build artifacts...$(RESET)\n"
	npx rescript clean
	@printf "$(GREEN)Clean complete!$(RESET)\n"

dev: ## Start ReScript in watch mode
	@printf "$(YELLOW)Starting ReScript watch mode...$(RESET)\n"
	npx rescript watch

test: build ## Run all tests
	@printf "$(YELLOW)Running tests...$(RESET)\n"
	node src/TestRunner.res.mjs
	@printf "$(GREEN)Tests complete!$(RESET)\n"

lint: ## Run linters and code formatters
	@printf "$(YELLOW)Running linters...$(RESET)\n"
	# ReScript has built-in formatting - no additional linting needed
	@printf "$(GREEN)Linting complete!$(RESET)\n"

install: ## Install project dependencies
	@printf "$(YELLOW)Installing dependencies...$(RESET)\n"
	npm install
	@printf "$(GREEN)Dependencies installed!$(RESET)\n"

format: ## Format ReScript code
	@printf "$(YELLOW)Formatting ReScript code...$(RESET)\n"
	npx rescript format
	@printf "$(GREEN)Code formatted!$(RESET)\n"

publish: check ## Publish package to npm
	@printf "$(YELLOW)Publishing to npm...$(RESET)\n"
	npm publish
	@printf "$(GREEN)Package published!$(RESET)\n"

check: build test ## Run all checks (build + test)
	@printf "$(GREEN)All checks passed!$(RESET)\n"
