# C4MCP - Control4 MCP Server Driver
# ===================================
#
# Usage:
#   make build     Build c4mcp.c4z
#   make clean     Remove build artifacts

.PHONY: build clean help

SHELL := /bin/bash

PROJECT := c4mcp
PROJFILE := $(PROJECT)/$(PROJECT).c4zproj

build:
	@echo ""
	@echo "Building $(PROJECT)..."
	@mkdir -p "$(PROJECT)/build"
	@DriverPackager.exe "$$(wslpath -w "$(PROJECT)")" "$$(wslpath -w "$(PROJECT)/build")" "$$(wslpath -w "$(PROJFILE)")"
	@c4zfile="$(PROJECT)/build/$(PROJECT).c4z"; \
	echo "Packaged: $$c4zfile"; \
	echo ""; \
	echo "Validating..."; \
	if ! DriverValidator.exe -d "$$c4zfile"; then \
		echo ""; \
		echo "ERROR: Driver validation failed"; \
		rm -f "$$c4zfile"; \
		exit 1; \
	fi; \
	echo ""; \
	echo "Built: $$c4zfile"

clean:
	@echo "Cleaning build artifacts..."
	@rm -rf $(PROJECT)/build
	@echo "Clean complete."

help:
	@echo ""
	@echo "C4MCP Build System"
	@echo "=================="
	@echo ""
	@echo "Commands:"
	@echo "  make build   Build c4mcp.c4z"
	@echo "  make clean   Remove build artifacts"
	@echo ""
