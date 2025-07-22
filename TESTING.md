# Testing Guide for ecolog.nvim

This guide explains how to test all features of the ecolog.nvim plugin.

## Quick Start

### Run All Tests

```bash
# Using make
make test

# Using test script
./scripts/test.sh all
```

### Run Specific Test

```bash
# Using make
make test-file FILE=tests/spec/ecolog_spec.lua

# Using test script
./scripts/test.sh file tests/spec/ecolog_spec.lua
```

## Manual Feature Testing

### 1. Environment Variable Management

**Basic .env Loading:**

1. Create a test `.env` file:
   ```bash
   echo "TEST_VAR=hello" > .env
   echo "SECRET_KEY=mysecret" >> .env
   ```
2. Open Neovim in the same directory
3. Run `:EcologInspect` to verify variables are loaded
4. Check `:lua print(vim.env.TEST_VAR)` outputs "hello"

**Multiple .env Files:**

1. Create multiple env files:
   ```bash
   echo "APP_ENV=development" > .env
   echo "APP_ENV=local" > .env.local
   echo "APP_ENV=dev" > .env.development
   ```
2. Verify precedence order (`.env.local` should override `.env`)

### 2. Completion Testing

**nvim-cmp Integration:**

1. Install nvim-cmp if not already installed
2. Create a file with environment variable references:
   ```javascript
   // test.js
   const apiKey = process.env.
   ```
3. Trigger completion after `env.` - should show available variables

**blink-cmp Integration:**

1. Install blink-cmp as alternative to nvim-cmp
2. Test same completion scenarios

### 3. Shelter Mode (Security Features)

**Partial Masking:**

1. Enable shelter mode: `:lua require('ecolog').toggle_shelter()`
2. Run `:EcologPeek` - sensitive values should be partially masked
3. Verify pattern: `mysecret` → `mys***et`

**Full Masking:**

1. Configure full masking:
   ```lua
   require('ecolog').setup({
     shelter = {
       configuration = {
         partial_mode = false
       }
     }
   })
   ```
2. Verify all characters are masked except first/last

### 4. Monorepo Support

**Turborepo:**

1. Create a Turborepo structure:
   ```bash
   mkdir -p apps/web apps/api
   echo "WEB_PORT=3000" > apps/web/.env
   echo "API_PORT=4000" > apps/api/.env
   ```
2. Navigate to different workspaces
3. Verify correct .env file is loaded per workspace

**Nx Monorepo:**

1. Similar test with Nx workspace structure
2. Check `:EcologInspect` shows workspace-specific variables

### 5. Integration Features

**Telescope Integration:**

1. Run `:Telescope ecolog env`
2. Search for variables
3. Press `<CR>` to insert selected variable

**FZF-lua Integration:**

1. Run `:lua require('fzf-lua').ecolog()`
2. Test search and selection

**LSP Hover:**

1. Hover over an environment variable reference
2. Should show value in hover window

### 6. Command Testing

Test each command:

- `:EcologSelect` - Opens variable selector
- `:EcologPeek [var]` - Shows variable value
- `:EcologInspect` - Opens inspection window
- `:EcologSwapShelter` - Toggles shelter mode
- `:EcologResetCache` - Clears variable cache
- `:EcologGotoEnv` - Jumps to .env file

### 7. Advanced Features

**Variable Interpolation:**

1. Create .env with interpolation:
   ```bash
   BASE_URL=http://localhost
   API_URL=${BASE_URL}/api
   DEFAULT_PORT=${PORT:-3000}
   ```
2. Verify interpolation works correctly

**Type Validation:**

1. Configure types:
   ```lua
   require('ecolog').setup({
     types = {
       PORT = "number",
       DEBUG = "boolean"
     }
   })
   ```
2. Test validation with invalid values

**Secret Manager Integration:**

1. Configure AWS Secrets Manager or Vault
2. Test secret retrieval (requires credentials)

## Performance Testing

### Large .env Files

1. Create a large .env file:
   ```bash
   for i in {1..1000}; do
     echo "VAR_$i=value_$i" >> .env.large
   done
   ```
2. Test loading performance
3. Test shelter mode performance

### File Watching

1. Modify .env file while Neovim is running
2. Verify changes are detected and reloaded

## Troubleshooting Tests

If tests fail:

1. Check Neovim version: `nvim --version` (requires 0.7.0+)
2. Install missing dependencies: `make deps`
3. Clear test cache: `make clean`
4. Run specific failing test: `./scripts/test.sh file <test_file>`

## Contributing Tests

When adding new features:

1. Write tests in `tests/spec/`
2. Follow existing test patterns
3. Test both success and error cases
4. Run full test suite before submitting PR

