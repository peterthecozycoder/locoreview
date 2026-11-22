.PHONY: test
PLENARY_PATH ?= .deps/plenary.nvim

test:
	PLENARY_PATH=$(PLENARY_PATH) nvim --headless -u tests/minimal_init.lua -c "lua require('plenary.test_harness').test_directory('tests', { minimal_init = 'tests/minimal_init.lua' })"
