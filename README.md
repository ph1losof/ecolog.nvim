# 🌲 ecolog.nvim

<div align="center">

![Neovim](https://img.shields.io/badge/NeoVim-%2357A143.svg?&style=for-the-badge&logo=neovim&logoColor=white)
![Lua](https://img.shields.io/badge/lua-%232C2D72.svg?style=for-the-badge&logo=lua&logoColor=white)

Ecolog (эколог) - your environment guardian in Neovim. Named after the Russian word for "environmentalist", this plugin protects and manages your environment variables with the same care an ecologist shows for nature.

A modern LSP-powered Neovim plugin for seamless environment variable integration and management. Provides intelligent auto-completion, hover, go-to-definition, references, and diagnostics for environment variables in your projects.

> ⚠️ This is a full rewrite of ecolog.nvim
> If you previously used ecolog.nvim with `shelter.modules`, `integrations.nvim_cmp`, or other v1 config options:
>
> Use `branch = "v1"` in your plugin manager until you migrate

![CleanShot 2026-01-14 at 17 41 04](https://github.com/user-attachments/assets/b5aa42e6-3fae-4a4f-b88f-c1b00eaff495)

</div>

---

## Table of Contents

- [Architecture](#-architecture)
- [Installation](#-installation)
  - [Prerequisites](#prerequisites)
  - [Plugin Setup](#plugin-setup)
  - [Binary Installation](#binary-installation)
- [Features](#-features)
- [Quick Start](#-quick-start)
- [Configuration](#-configuration)
  - [LSP Configuration](#lsp-configuration)
  - [Picker Configuration](#picker-configuration)
  - [Statusline Configuration](#statusline-configuration)
  - [Additional Options](#additional-options)
  - [Full Configuration Example](#full-configuration-example)
- [Commands](#-commands)
- [Lua API](#-lua-api)
- [Hooks System](#-hooks-system)
  - [Available Hooks](#available-hooks)
  - [Hook Registration](#hook-registration)
  - [shelter.nvim Integration](#shelternvim-integration)
- [shelter.nvim Integration](#️-shelternvim-integration)
- [Picker Integration](#-picker-integration)
  - [Supported Backends](#supported-backends)
  - [Keymaps](#keymaps)
  - [Variables Picker](#variables-picker)
  - [Files Picker](#files-picker)
- [Statusline Integration](#-statusline-integration)
  - [Built-in Statusline](#built-in-statusline)
  - [Lualine Integration](#lualine-integration)
  - [Status Data Access](#status-data-access)
- [LSP Backends](#-lsp-backends)
  - [Auto Mode](#auto-mode-default)
  - [Native Mode](#native-mode)
  - [LSPConfig Mode](#lspconfig-mode)
  - [External Mode](#external-mode)
- [ecolog.toml Configuration](#-ecologtoml-configuration)
- [Supported Languages](#-supported-languages)
- [Health Check](#-health-check)
- [Troubleshooting](#-troubleshooting)
- [Related Projects](#-related-projects)

---

## 🏗️ Architecture

This plugin is the **LSP client** for [ecolog-lsp](https://github.com/ph1losof/ecolog-lsp), a Language Server that provides intelligent environment variable analysis using tree-sitter.

**Key differences from traditional approaches:**

| Aspect        | ecolog-plugin (LSP)           | Traditional (regex)          |
| ------------- | ----------------------------- | ---------------------------- |
| Analysis      | Tree-sitter AST parsing       | Regex pattern matching       |
| Completion    | LSP `textDocument/completion` | Custom completion source     |
| Languages     | 5 languages via LSP           | Per-language regex providers |
| Masking       | External via hooks            | Built-in shelter module      |
| Extensibility | Hooks system                  | Direct configuration         |

---

## 📦 Installation

### Prerequisites

- **Neovim 0.10+** (0.11+ recommended for native LSP)
- **ecolog-lsp binary** (see [Binary Installation](#binary-installation))

### Plugin Setup

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "ph1losof/ecolog.nvim",
  lazy = false,
  config = function()
    require("ecolog").setup()
  end,
}
```

Using [packer.nvim](https://github.com/wbthomason/packer.nvim):

```lua
use {
  "ph1losof/ecolog.nvim",
  config = function()
    require("ecolog").setup()
  end,
}
```

### Binary Installation

The plugin requires the `ecolog-lsp` binary. Choose one method:

**Cargo:**

```bash
cargo install ecolog-lsp
```

**From source:**

```bash
cd ecolog-lsp
cargo build --release
# Binary at target/release/ecolog-lsp
```

The plugin automatically detects the binary in this order:

1. Mason install location
2. System PATH
3. Cargo bin directory (`~/.cargo/bin/`)

---

## ✨ Features

**LSP-Powered Intelligence**

- Context-aware auto-completion for environment variables
- Hover information with variable values and metadata
- Go-to-definition to jump to `.env` file declarations
- Find all references across your workspace
- Rename refactoring for safe variable renaming
- Diagnostics for undefined variables and `.env` file linting

**Multi-Backend Picker Integration**

- Telescope, fzf-lua, and snacks.nvim support
- Variable browser with copy/append actions
- File picker for selecting active `.env` files
- Configurable keymaps per backend

**Statusline Integration**

- Built-in statusline component with highlights
- Lualine component with full customization
- Shows active file, variable count, source status

**Extensible Hooks System**

- Transform variables before display
- Integrate with masking plugins (shelter.nvim)
- React to LSP events and file changes

**Source Management**

- Shell environment variables
- `.env` file variables
- Remote sources (future)
- Toggle sources at runtime

**Additional Features**

- Variable interpolation (`${VAR}` syntax)
- Monorepo/workspace support
- Sync variables to `vim.env`
- Generate `.env.example` files

**Security**

- Integrate with [shelter.nvim](https://github.com/ph1losof/shelter.nvim) for value masking
- Prevent accidental exposure in screen shares, meetings, and recordings
- Copy actual values when needed while keeping display masked

---

## 🚀 Quick Start

**Minimal setup:**

```lua
require("ecolog").setup()
```

That's it! The plugin will:

1. Auto-detect and start the LSP
2. Attach to all buffers
3. Provide completions, hover, and go-to-definition

**Add some keymaps:**

```lua
vim.keymap.set("n", "<leader>ev", "<cmd>Ecolog list<cr>", { desc = "List env variables" })
vim.keymap.set("n", "<leader>ef", "<cmd>Ecolog files select<cr>", { desc = "Select env file" })
```

---

## ⚙️ Configuration

### LSP Configuration

```lua
require("ecolog").setup({
  lsp = {
    -- Backend selection: "auto" | "native" | "lspconfig" | false
    -- "auto": Use native (0.11+) or lspconfig fallback
    -- "native": Force vim.lsp.config (requires Neovim 0.11+)
    -- "lspconfig": Force nvim-lspconfig
    -- false: External LSP management (plugin only hooks into events)
    backend = "auto",

    -- Binary path override (auto-detected if nil)
    cmd = nil,

    -- Filetypes to attach (nil = all buffers)
    filetypes = nil,
    -- Or restrict: filetypes = { "javascript", "typescript", "python" },

    -- Workspace root (nil = current working directory)
    root_dir = nil,

    -- Feature toggles (sent to LSP)
    features = {
      hover = true,
      completion = true,
      diagnostics = true,
      definition = true,
    },

    -- Strict mode: only show features in valid contexts
    strict = {
      hover = true,       -- Only hover on valid env var references
      completion = true,  -- Only complete after env object access
    },

    -- LSP initialization options
    init_options = {
      interpolation = {
        enabled = true,   -- Enable ${VAR} expansion
      },
    },

    -- Additional LSP settings
    settings = {},
  },
})
```

### Picker Configuration

```lua
require("ecolog").setup({
  picker = {
    -- Backend: "telescope" | "fzf" | "snacks" | nil (auto-detect)
    backend = nil,

    -- Keymap customization
    keys = {
      copy_value = "<C-y>",      -- Copy variable value
      copy_name = "<C-u>",       -- Copy variable name
      append_value = "<C-a>",    -- Append value at cursor
      append_name = "<CR>",      -- Append name at cursor (default action)
      goto_source = "<C-g>",     -- Go to source file
    },
  },
})
```

### Statusline Configuration

```lua
require("ecolog").setup({
  statusline = {
    -- Hide statusline when no env file is active
    hidden_mode = false,

    -- Icon configuration
    icons = {
      enabled = true,
      env = "",  -- Environment icon
    },

    -- Custom formatters
    format = {
      env_file = function(name) return name end,
      vars_count = function(count) return tostring(count) end,
    },

    -- Highlight configuration (group names or hex colors)
    highlights = {
      enabled = true,
      env_file = "EcologStatusFile",
      vars_count = "EcologStatusCount",
      icons = "EcologStatusIcons",
      sources = "EcologStatusSources",
      sources_disabled = "EcologStatusSourcesDisabled",
      interpolation = "EcologStatusInterpolation",
      interpolation_disabled = "EcologStatusInterpolationDisabled",
    },

    -- Source indicators
    sources = {
      enabled = true,
      show_disabled = false,     -- Show disabled sources dimmed
      format = "compact",        -- "compact" (SF) or "badges" ([S] [F])
      icons = {
        shell = "S",
        file = "F",
      },
    },

    -- Interpolation indicator
    interpolation = {
      enabled = true,
      show_disabled = true,
      icon = "I",
    },
  },
})
```

### Additional Options

```lua
require("ecolog").setup({
  -- Sync environment variables to vim.env for Lua access
  vim_env = false,

  -- Custom variable sorting function
  sort_var_fn = nil,
  -- Example: sort_var_fn = function(a, b) return a.name < b.name end,
})
```

### Full Configuration Example

```lua
require("ecolog").setup({
  lsp = {
    backend = "auto",
    features = {
      hover = true,
      completion = true,
      diagnostics = true,
      definition = true,
    },
    strict = {
      hover = true,
      completion = true,
    },
    init_options = {
      interpolation = { enabled = true },
    },
  },

  picker = {
    backend = nil,  -- auto-detect
    keys = {
      copy_value = "<C-y>",
      copy_name = "<C-u>",
      append_value = "<C-a>",
      append_name = "<CR>",
      goto_source = "<C-g>",
    },
  },

  statusline = {
    hidden_mode = false,
    icons = { enabled = true, env = "" },
    sources = { enabled = true, format = "compact" },
    interpolation = { enabled = true },
  },

  vim_env = false,
})
```

---

## 📋 Commands

All commands use the format `:Ecolog <subcommand> [action]`:

| Command                         | Description                                   |
| ------------------------------- | --------------------------------------------- |
| `:Ecolog list`                  | Open variable picker                          |
| `:Ecolog copy value`            | Copy variable value at cursor                 |
| `:Ecolog files select`          | Open file picker to select active env file(s) |
| `:Ecolog files open_active`     | Open active env file in editor                |
| `:Ecolog files enable`          | Enable File source                            |
| `:Ecolog files disable`         | Disable File source                           |
| `:Ecolog files`                 | Toggle File source                            |
| `:Ecolog shell enable`          | Enable Shell source                           |
| `:Ecolog shell disable`         | Disable Shell source                          |
| `:Ecolog shell`                 | Toggle Shell source                           |
| `:Ecolog remote enable`         | Enable Remote source                          |
| `:Ecolog remote disable`        | Disable Remote source                         |
| `:Ecolog remote`                | Toggle Remote source                          |
| `:Ecolog interpolation enable`  | Enable variable interpolation                 |
| `:Ecolog interpolation disable` | Disable variable interpolation                |
| `:Ecolog interpolation`         | Toggle interpolation                          |
| `:Ecolog workspaces`            | List detected workspaces (monorepo)           |
| `:Ecolog root [path]`           | Set workspace root (default: cwd)             |
| `:Ecolog generate [path]`       | Generate .env.example (use `-` for buffer)    |
| `:Ecolog refresh`               | Restart LSP and reload env files              |
| `:Ecolog info`                  | Show plugin status                            |

**Tab completion** is available for all subcommands and actions.

---

## 🔧 Lua API

### Core Functions

```lua
local ecolog = require("ecolog")

-- Initialize the plugin
ecolog.setup(opts)

-- Variable operations
ecolog.peek()                      -- Peek at variable under cursor
ecolog.goto_definition()           -- Go to variable definition
ecolog.copy("name")                -- Copy variable name at cursor
ecolog.copy("value")               -- Copy variable value at cursor

-- File operations
ecolog.select()                    -- Open file picker
ecolog.files()                     -- Alias for select()

-- Management
ecolog.refresh()                   -- Restart LSP
ecolog.list()                      -- Open variable picker
ecolog.generate_example()          -- Generate .env.example
ecolog.info()                      -- Show plugin status
```

### Async Variable Access

```lua
local ecolog = require("ecolog")

-- Get a single variable by name
ecolog.get("API_KEY", function(var)
  if var then
    print(var.name .. " = " .. var.value)
  end
end)

-- Get all variables
ecolog.all(function(vars)
  for _, var in ipairs(vars) do
    print(var.name)
  end
end)

-- Get variables scoped to a specific path (monorepo)
ecolog.all("/path/to/package", function(vars)
  -- Variables scoped to that package
end)
```

### Hooks Access

```lua
local hooks = require("ecolog").hooks()

hooks.register(name, callback, opts)
hooks.unregister(name, id)
hooks.fire(name, context)          -- For side-effect hooks
hooks.fire_filter(name, value)     -- For transform hooks
hooks.has_hooks(name)
hooks.list()                       -- Get all registered hook names
```

### Statusline Access

```lua
local statusline = require("ecolog").statusline()

statusline.get_statusline()        -- Get formatted statusline string
statusline.is_running()            -- Check if LSP is running
statusline.get_active_file()       -- Get active file name
statusline.get_active_file_path()  -- Get active file full path
statusline.get_active_files()      -- Get all active files
statusline.get_var_count()         -- Get loaded variable count
```

### Lualine Component

```lua
-- Get lualine component
local component = require("ecolog").lualine()

-- Use in lualine config
require("lualine").setup({
  sections = {
    lualine_c = { component },
  },
})
```

---

## 🪝 Hooks System

The hooks system enables external integrations like [shelter.nvim](https://github.com/ph1losof/shelter.nvim) for value masking.

### Available Hooks

| Hook                     | Context                       | Return             | Purpose                                      |
| ------------------------ | ----------------------------- | ------------------ | -------------------------------------------- |
| `on_lsp_attach`          | `{client, bufnr}`             | -                  | LSP attached to buffer                       |
| `on_variables_list`      | `EcologVariable[]`            | `EcologVariable[]` | Filter/transform variables before display    |
| `on_variable_hover`      | `EcologVariable`              | `EcologVariable`   | Transform variable for hover                 |
| `on_variable_peek`       | `EcologVariable`              | `EcologVariable`   | Transform variable for peek/copy (unmasking) |
| `on_active_file_changed` | `{patterns, result, success}` | -                  | Active file selection changed                |
| `on_picker_entry`        | `entry`                       | `entry`            | Transform picker entry display               |

### Hook Registration

```lua
local ecolog = require("ecolog")
local hooks = ecolog.hooks()

-- Register a hook with options
local id = hooks.register(
  "on_variable_peek",
  function(var)
    -- Transform the variable
    var.value = reveal_secret(var.value)
    return var
  end,
  {
    id = "my_hook",      -- Optional: custom ID
    priority = 200,      -- Higher priority runs first (default: 100)
  }
)

-- Unregister a hook
hooks.unregister("on_variable_peek", id)

-- Check if hooks exist
if hooks.has_hooks("on_variable_peek") then
  -- ...
end

-- List all hook names with registered callbacks
local names = hooks.list()
```

### shelter.nvim Integration

```lua
local ecolog = require("ecolog")
local shelter = require("shelter")

-- Mask values in variable list and pickers
ecolog.hooks().register("on_variables_list", function(vars)
  for _, var in ipairs(vars) do
    var.value = shelter.mask(var.value)
  end
  return vars
end, { priority = 200 })

-- Mask values in hover
ecolog.hooks().register("on_variable_hover", function(var)
  var.value = shelter.mask(var.value)
  return var
end, { priority = 200 })

-- Unmask values on peek/copy
ecolog.hooks().register("on_variable_peek", function(var)
  var.value = shelter.reveal(var.value)
  return var
end, { priority = 200 })

-- Transform picker entries
ecolog.hooks().register("on_picker_entry", function(entry)
  entry.display_value = shelter.mask(entry.value)
  return entry
end, { priority = 200 })
```

---

## 🔍 Picker Integration

### Supported Backends

Three picker backends are supported, auto-detected in order:

1. **Telescope** - Full-featured, requires [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim)
2. **fzf-lua** - Fast and lightweight, requires [fzf-lua](https://github.com/ibhagwan/fzf-lua)
3. **snacks.nvim** - Modern UI, requires [snacks.nvim](https://github.com/folke/snacks.nvim)

Force a specific backend:

```lua
require("ecolog").setup({
  picker = {
    backend = "telescope",  -- or "fzf" or "snacks"
  },
})
```

### Keymaps

Default keymaps (all backends):

| Key     | Action                          |
| ------- | ------------------------------- |
| `<CR>`  | Append variable name at cursor  |
| `<C-y>` | Copy variable value             |
| `<C-u>` | Copy variable name              |
| `<C-a>` | Append variable value at cursor |
| `<C-g>` | Go to source file               |

Customize keymaps:

```lua
require("ecolog").setup({
  picker = {
    keys = {
      copy_value = "<C-c>",
      copy_name = "<C-n>",
      append_value = "<C-v>",
      append_name = "<CR>",
      goto_source = "<C-o>",
    },
  },
})
```

### Variables Picker

Open with `:Ecolog list` or `require("ecolog").list()`

Shows all environment variables with:

- Variable name
- Variable value (can be masked via hooks)
- Source (file path or "System Environment")

Supports multi-action via configurable keymaps.

### Files Picker

Open with `:Ecolog files select` or `require("ecolog").select()`

Shows all detected `.env` files in the workspace.

**Multi-select support:**

- Telescope: Use `<Tab>` / `<S-Tab>` to select multiple files
- fzf-lua: Use `<Tab>` to toggle selection
- snacks.nvim: Single select only

---

## 📊 Statusline Integration

### Built-in Statusline

```lua
local statusline = require("ecolog").statusline()

-- Get formatted statusline with highlight codes
local status = statusline.get_statusline()

-- Simple string for basic statuslines
local simple = statusline.get({
  icon = "",
  show_file = true,
  show_count = true,
})
```

**Display format:**

```
 SF I .env (42)
│  │  │ │    └── Variable count
│  │  │ └─────── Active file name
│  │  └───────── Interpolation indicator
│  └──────────── Source indicators (Shell, File)
└─────────────── Icon
```

### Lualine Integration

```lua
require("lualine").setup({
  sections = {
    lualine_c = {
      -- Full component
      require("ecolog").lualine(),
    },
  },
})

-- Or use individual components
require("lualine").setup({
  sections = {
    lualine_c = {
      require("ecolog.statusline.lualine").file(),
      require("ecolog.statusline.lualine").count(),
    },
  },
})
```

### Status Data Access

```lua
local statusline = require("ecolog").statusline()

statusline.is_running()            -- boolean: LSP running?
statusline.get_active_file()       -- string|nil: Current file name
statusline.get_active_file_path()  -- string|nil: Full path
statusline.get_active_files()      -- table: All active files
statusline.get_var_count()         -- number: Total variables
```

---

## LSP Backends

### Auto Mode (Default)

The plugin automatically detects the best available backend:

- **Neovim 0.11+** → Uses native `vim.lsp.start()`
- **Neovim 0.10 + lspconfig** → Uses nvim-lspconfig
- **Neovim 0.10 without lspconfig** → Error (install lspconfig or upgrade)

```lua
lsp = { backend = "auto" }
```

### Native Mode

Requires Neovim 0.11+. Uses `vim.lsp.start()` directly without external dependencies.

```lua
lsp = { backend = "native" }
```

### LSPConfig Mode

Requires [nvim-lspconfig](https://github.com/neovim/nvim-lspconfig). Registers `ecolog` as a server with lspconfig.

```lua
lsp = { backend = "lspconfig" }
```

### External Mode

For users who manage LSP externally. The plugin only hooks into `LspAttach` events.

```lua
lsp = { backend = false }
```

The plugin matches clients by name: `ecolog`, `ecolog_lsp`, or `ecolog-lsp`.

---

## ecolog.toml Configuration

Create an `ecolog.toml` in your workspace root for LSP-level configuration. This takes precedence over plugin settings.

```toml
# Feature toggles
[features]
hover = true              # Enable hover information
completion = true         # Enable auto-completion
diagnostics = true        # Enable diagnostics
definition = true         # Enable go-to-definition

# Strict mode - only show features in valid contexts
[strict]
hover = true              # Only hover on valid env var references
completion = true         # Only complete after env object access

# Workspace configuration
[workspace]
env_files = [".env", ".env.local", ".env.*"]  # Glob patterns for env files

# Source resolution order
[resolution]
precedence = ["Shell", "File", "Remote"]  # Shell vars take priority

# Variable interpolation
[interpolation]
enabled = true            # Enable ${VAR} expansion
max_depth = 10            # Maximum nesting depth

# Performance caching
[cache]
enabled = true
hot_cache_size = 100      # Number of frequently-accessed vars to cache
ttl = 300                 # Cache lifetime in seconds
```

---

## Supported Languages

The LSP uses tree-sitter for accurate pattern detection:

| Language   | Patterns Detected                                                             |
| ---------- | ----------------------------------------------------------------------------- |
| JavaScript | `process.env.VAR`, `process.env["VAR"]`, `import.meta.env.VAR`, destructuring |
| TypeScript | Same as JavaScript + type annotations                                         |
| Python     | `os.environ["VAR"]`, `os.environ.get("VAR")`, `os.getenv("VAR")`              |
| Rust       | `env!("VAR")`, `std::env::var("VAR")`                                         |
| Go         | `os.Getenv("VAR")`, `os.LookupEnv("VAR")`                                     |

**JavaScript/TypeScript examples:**

```javascript
// Direct access
process.env.API_KEY;
process.env["API_KEY"];
import.meta.env.VITE_API_URL;

// Destructuring
const { API_KEY, SECRET } = process.env;

// Aliased destructuring
const { API_KEY: apiKey } = process.env;

// Object binding
const env = process.env;
env.API_KEY;
```

**Python examples:**

```python
import os

os.environ["API_KEY"]
os.environ.get("API_KEY")
os.environ.get("API_KEY", "default")
os.getenv("API_KEY")
os.getenv("API_KEY", "default")
```

**Rust examples:**

```rust
// Compile-time
env!("API_KEY")

// Runtime
std::env::var("API_KEY")
std::env::var("API_KEY").unwrap()
```

**Go examples:**

```go
import "os"

os.Getenv("API_KEY")
os.LookupEnv("API_KEY")
```

---

## Health Check

Run the health check to diagnose issues:

```vim
:checkhealth ecolog
```

**Checks performed:**

- Neovim version (0.10+ required, 0.11+ recommended)
- ecolog-lsp binary availability (Mason, PATH, Cargo)
- LSP backend detection
- LSP running status
- Picker availability (optional)
- Configuration validity

---

## Troubleshooting

### LSP not starting

1. Check status: `:Ecolog info`
2. Verify binary is installed: `which ecolog-lsp`
3. Check LSP logs: `:LspInfo` or `:LspLog`
4. Ensure Neovim 0.10+ (0.11+ for native mode)

### No completions

1. Verify you're in a supported filetype (JS, TS, Python, Rust, Go)
2. Check File source is enabled: `:Ecolog files enable`
3. Verify `.env` file exists in workspace
4. Check completion is enabled in config: `lsp.features.completion = true`

### Variables not found

1. Check active file: `:Ecolog info`
2. Select correct file: `:Ecolog files select`
3. Refresh: `:Ecolog refresh`
4. Verify `.env` file is valid (no syntax errors)

### Wrong workspace root

1. Check current root: `:Ecolog info`
2. Set correct root: `:Ecolog root /path/to/project`
3. Or configure in setup: `lsp.root_dir = "/path/to/project"`

### Picker not working

1. Ensure a picker is installed (Telescope, fzf-lua, or snacks.nvim)
2. Force specific backend: `picker.backend = "telescope"`
3. Check health: `:checkhealth ecolog`

---

## Related Projects

- **[ecolog-lsp](https://github.com/ph1losof/ecolog-lsp)** - The Language Server providing all analysis
- **[shelter.nvim](https://github.com/ph1losof/shelter.nvim)** - Value masking to prevent accidental exposure in meetings
- **[korni](https://github.com/ph1losof/korni)** - Zero-copy `.env` file parser

---

## License

MIT
