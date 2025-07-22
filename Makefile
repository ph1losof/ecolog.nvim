.PHONY: test test-file test-watch deps clean help

PLENARY_DIR := /tmp/plenary.nvim
TELESCOPE_DIR := /tmp/telescope.nvim
FZF_LUA_DIR := /tmp/fzf-lua
SNACKS_DIR := /tmp/snacks.nvim
NVIM_CMP_DIR := /tmp/nvim-cmp
BLINK_CMP_DIR := /tmp/blink.cmp
LSPSAGA_DIR := /tmp/lspsaga.nvim

help:
	@echo "Available targets:"
	@echo "  deps        - Install test dependencies"
	@echo "  test        - Run all tests"
	@echo "  test-file   - Run a specific test file (use FILE=path/to/test.lua)"
	@echo "  test-watch  - Run tests in watch mode"
	@echo "  clean       - Clean test dependencies"

deps:
	@echo "Installing test dependencies..."
	@[ -d $(PLENARY_DIR) ] || git clone https://github.com/nvim-lua/plenary.nvim $(PLENARY_DIR)
	@[ -d $(TELESCOPE_DIR) ] || git clone https://github.com/nvim-telescope/telescope.nvim $(TELESCOPE_DIR)
	@[ -d $(FZF_LUA_DIR) ] || git clone https://github.com/ibhagwan/fzf-lua $(FZF_LUA_DIR)
	@[ -d $(SNACKS_DIR) ] || git clone https://github.com/folke/snacks.nvim $(SNACKS_DIR)
	@[ -d $(NVIM_CMP_DIR) ] || git clone https://github.com/hrsh7th/nvim-cmp $(NVIM_CMP_DIR)
	@[ -d $(BLINK_CMP_DIR) ] || git clone https://github.com/saghen/blink.cmp $(BLINK_CMP_DIR)
	@[ -d $(LSPSAGA_DIR) ] || git clone https://github.com/nvimdev/lspsaga.nvim $(LSPSAGA_DIR)
	@echo "Dependencies installed!"

test: deps
	@echo "Running all tests..."
	@nvim --headless -u tests/minimal_init.lua \
		-c "lua require('plenary.test_harness').test_directory('tests/spec/', {minimal_init='tests/minimal_init.lua'})" \
		-c "qa!"

test-file: deps
	@if [ -z "$(FILE)" ]; then \
		echo "Usage: make test-file FILE=tests/spec/your_test.lua"; \
		exit 1; \
	fi
	@echo "Running test file: $(FILE)"
	@nvim --headless -u tests/minimal_init.lua \
		-c "PlenaryBustedFile $(FILE)" \
		-c "qa!"

test-watch: deps
	@echo "Running tests in watch mode..."
	@echo "Press Ctrl+C to stop"
	@while true; do \
		clear; \
		make test; \
		echo ""; \
		echo "Watching for changes... Press Ctrl+C to stop"; \
		fswatch -1 -r lua/ tests/spec/; \
	done

clean:
	@echo "Cleaning test dependencies..."
	@rm -rf $(PLENARY_DIR) $(TELESCOPE_DIR) $(FZF_LUA_DIR) $(SNACKS_DIR) $(NVIM_CMP_DIR) $(BLINK_CMP_DIR) $(LSPSAGA_DIR)
	@echo "Clean complete!"