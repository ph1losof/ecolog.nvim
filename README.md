# ecolog.nvim

A Neovim plugin for environment variable tooling, powered by [ecolog-lsp](https://github.com/ecolog/ecolog-lsp).

## Features

- **LSP-powered** - Hover, completion, go-to-definition, references, rename for env vars
- **Cross-language support** - JavaScript, TypeScript, Python, Rust, Go
- **Automatic LSP setup** - Works out of the box with zero configuration
- **Multiple backends** - Native vim.lsp.config (0.11+) or nvim-lspconfig
- **Pickers** - Browse env vars with Telescope, FZF-lua, or Snacks
- **Statusline** - Show active env file in your statusline
- **shelter.nvim integration** - Mask sensitive values via hooks

## Requirements

- Neovim 0.10+ (0.11+ recommended for native LSP support)
- `ecolog-lsp` binary (install via `cargo install ecolog-lsp` or Mason)
- Optional: nvim-lspconfig (required if Neovim < 0.11)
- Optional: telescope.nvim, fzf-lua, or snacks.nvim for pickers

## Installation

### lazy.nvim

```lua
{
  "ecolog/ecolog.nvim",
  dependencies = {
    -- Optional: for pickers
    "nvim-telescope/telescope.nvim",
    -- "ibhagwan/fzf-lua",
    -- "folke/snacks.nvim",
  },
  config = function()
    require("ecolog").setup({})
  end,
}
```

### Installing ecolog-lsp

```bash
# Via Cargo
cargo install ecolog-lsp

# Or build from source
cargo build --release -p ecolog-lsp
```

## Configuration

```lua
require("ecolog").setup({
  lsp = {
    -- LSP backend: "auto" | "native" | "lspconfig" | false
    -- "auto" (default): Use native on Neovim 0.11+, else lspconfig
    -- "native": Force vim.lsp.config (requires Neovim 0.11+)
    -- "lspconfig": Force nvim-lspconfig
    -- false: External management (you setup LSP, plugin just adds hooks)
    backend = "auto",

    -- Client name to match when backend = false
    client = "ecolog",

    -- Command to run (default: auto-detect from Mason, PATH, or Cargo)
    cmd = nil,

    -- Filetypes to attach LSP
    filetypes = {
      "javascript", "javascriptreact",
      "typescript", "typescriptreact",
      "python", "rust", "go", "lua",
      "dotenv", "sh", "conf",
    },

    -- Root directory markers
    root_markers = {
      "ecolog.toml", ".env", ".env.local",
      "package.json", "Cargo.toml", "go.mod", ".git",
    },

    -- LSP settings (sent to ecolog-lsp)
    settings = {},
  },

  keymaps = {
    enabled = true,
    mappings = {
      peek = "<leader>ep",
      select = "<leader>es",
      goto_definition = "<leader>eg",
      copy_name = "<leader>en",
      copy_value = "<leader>ev",
      list = "<leader>el",
    },
  },

  picker = {
    -- Force picker backend ("telescope", "fzf", "snacks")
    -- Default: auto-detect
    backend = nil,

    -- Picker keymaps (unified across all backends)
    -- Set to "" or false to disable a keymap
    keys = {
      copy_value = "<C-y>",    -- Copy variable value
      copy_name = "<C-u>",     -- Copy variable name
      append_value = "<C-a>",  -- Append value at cursor
      append_name = "<CR>",    -- Append name at cursor (default action)
      goto_source = "<C-g>",   -- Go to source file
    },
  },
})
```

### Backend Examples

**Zero Config (Recommended)**
```lua
require("ecolog").setup({})
-- Auto-detects best backend based on Neovim version
```

**Force Native (Neovim 0.11+)**
```lua
require("ecolog").setup({
  lsp = { backend = "native" },
})
```

**Force nvim-lspconfig**
```lua
require("ecolog").setup({
  lsp = { backend = "lspconfig" },
})
```

**External Management**
```lua
-- Your lspconfig setup
require("ecolog.lsp").register_lspconfig()  -- Optional: register server
require("lspconfig").ecolog.setup({})

-- ecolog.nvim setup
require("ecolog").setup({
  lsp = {
    backend = false,
    client = "ecolog",  -- Match your lspconfig name
  },
})
```

## Commands

| Command | Description |
|---------|-------------|
| `:Ecolog peek` | Show variable value at cursor in floating window |
| `:Ecolog select` | Open file picker to select active env file |
| `:Ecolog goto` | Go to definition (LSP) |
| `:Ecolog copy name` | Copy variable name at cursor |
| `:Ecolog copy value` | Copy variable value at cursor |
| `:Ecolog refresh` | Restart LSP (reload env files) |
| `:Ecolog list` | Open variable picker |
| `:Ecolog files` | Open file picker |
| `:Ecolog generate [output]` | Generate .env.example file |
| `:Ecolog info` | Show plugin status |
| `:checkhealth ecolog` | Health check diagnostics |

## Picker Keymaps

Default keymaps in the variable picker (configurable via `picker.keys`):

| Key | Action |
|-----|--------|
| `<CR>` | Append variable name at cursor |
| `<C-y>` | Copy variable value to clipboard |
| `<C-u>` | Copy variable name to clipboard |
| `<C-a>` | Append variable value at cursor |
| `<C-g>` | Go to source file |

These keymaps work consistently across all picker backends (Telescope, FZF-lua, Snacks).

## Statusline

### Generic

```lua
-- In your statusline configuration
local statusline = require("ecolog.statusline")

-- Get statusline string
statusline.get({ icon = "", show_file = true, show_count = false })

-- Check if LSP is running
statusline.is_running()

-- Get active file name
statusline.get_active_file()
```

### Lualine

```lua
require("lualine").setup({
  sections = {
    lualine_x = {
      -- Method 1: Use the create function
      require("ecolog.statusline.lualine").create({
        icon = "",
        show_file = true,
        show_count = false,
      }),

      -- Method 2: Just the active file
      require("ecolog.statusline.lualine").file(),

      -- Method 3: Just the count
      require("ecolog.statusline.lualine").count(),
    },
  },
})
```

## shelter.nvim Integration

ecolog.nvim provides a hooks system that shelter.nvim can use to mask sensitive values in pickers and hover.

### In shelter.nvim config:

```lua
require("shelter").setup({
  modules = {
    files = true,
    ecolog = true, -- Enable ecolog integration
  },

  -- Masking patterns
  patterns = {
    ["*_SECRET"] = "full",
    ["*_KEY"] = "partial",
    ["*_PASSWORD"] = "full",
  },

  default_mode = "full",
})
```

### How it works

- When `modules.ecolog = true`, shelter.nvim registers hooks with ecolog.nvim
- Values in pickers, hover, etc. are automatically masked
- The `:Ecolog peek` command shows the **unmasked** value (for authorized viewing)
- Pattern matching uses the same patterns configured in shelter.nvim

## Hooks API

For advanced integrations, ecolog.nvim exposes a hooks system:

```lua
local hooks = require("ecolog").hooks()

-- Register a hook
local id = hooks.register("on_variables_list", function(vars)
  -- Transform variables
  return vars
end, { id = "my_hook", priority = 100 })

-- Unregister
hooks.unregister("on_variables_list", id)
```

### Available hooks

| Hook | Signature | Description |
|------|-----------|-------------|
| `on_lsp_attach` | `(ctx: {client, bufnr})` | LSP attached to buffer |
| `on_variables_list` | `(vars) -> vars` | Transform variable list |
| `on_variable_hover` | `(var) -> var` | Transform hover variable |
| `on_variable_peek` | `(var) -> var` | Transform peek variable |
| `on_picker_entry` | `(entry) -> entry` | Transform picker entry |
| `on_active_file_changed` | `(ctx: {patterns, result})` | Active file changed |

## ecolog.toml

Configure ecolog-lsp with an `ecolog.toml` in your project root:

```toml
[workspace]
env_files = [".env", ".env.*", "config/.env*"]

[sources]
precedence = ["shell", "file"]

[sources.shell]
enabled = true

[interpolation]
enabled = true
max_depth = 64

[features]
hover = true
completion = true
diagnostics = true
definition = true
references = true
rename = true
```

## License

MIT
