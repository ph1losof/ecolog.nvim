# 🌲 ecolog.nvim (VERY WIP)

A Neovim plugin for seamless environment variable integration and management. Provides intelligent autocompletion, type checking, and value peeking for environment variables in your projects.

## ✨ Features

- 🔍 **Environment Variable Peeking**: Quickly peek at environment variable values and metadata
- 🤖 **Intelligent Autocompletion**: Integration with nvim-cmp for smart environment variable completion
- 🔒 **Secure Value Display**: Option to hide sensitive environment variable values
- 🔄 **Auto-refresh**: Automatic cache management for environment files
- 📁 **Multiple Env File Support**: Handles multiple .env files with priority management
- 💡 **Type Detection**: Automatic type inference for environment variables

## 📦 Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

### Plugin setup

```lua
{
  'philosofonusus/ecolog.nvim',
  dependencies = {
    'hrsh7th/nvim-cmp', -- Optional, for autocompletion support
  },
  opts = {
    hide_cmp_values = true, -- Hide sensitive values in completion
    path = vim.fn.getcwd(), -- Path to search for .env files
    preferred_environment = "development" -- Optional: prioritize specific env files
  },
}
```

### Completion Setup

Add 'ecolog' to your nvim-cmp sources:

```lua
require('cmp').setup({
  sources = {
    { name = 'ecolog' },
    -- your other sources...
  },
})
```

## 🚀 Usage

### Commands

- `:EnvPeek [variable_name]` - Peek at environment variable value and metadata
- `:EnvPeek` - Peek at enviroment variable under cursor
- `:EnvRefresh` - Refresh environment variable cache
- `:EnvSelect` - Open a selection window to choose environment file

### Environment File Priority

Files are loaded in the following priority:

1. `.env.{preferred_environment}` (if preferred_environment is set)
2. `.env`
3. Other `.env.*` files (alphabetically)

### Supported File Types

Currently supports:

- ⌨️ TypeScript/TypeScriptReact support for `process.env` completions
- ⌨️ JavaScript/React support for `process.env` and `import.meta.env` completions
- ⌨️ Python support for `os.environ.get`
- ⌨️ PHP support for `getenv()` and `_ENV[]`
- ⌨️ Deno support coming soon
- ⌨️ Rust support coming soon
- ... and more!

### Autocompletion

In TypeScript/TypeScriptReact files, autocompletion triggers when typing:

- `process.env.`

In JavaScript/React files, autocompletion triggers when typing:

- `process.env.`
- `import.meta.env.` (for Vite and other modern frameworks)

In Python files, autocompletion triggers when typing:

- `os.environ.get(`

In PHP files, autocompletion triggers when typing:

- `getenv('`
- `_ENV['`

## 🔌 Custom Providers

You can add support for additional languages by registering custom providers. Each provider defines how environment variables are detected and extracted in specific file types.

### Example: Adding Ruby Support

```lua
require('ecolog').setup({
  providers = {
    {
      -- Pattern to match environment variable access
      pattern = "ENV%[['\"]%w['\"]%]",
      -- Filetype(s) this provider supports (string or table)
      filetype = "ruby",
      -- Function to extract variable name from the line
      extract_var = function(line, col)
        local before_cursor = line:sub(1, col + 1)
        return before_cursor:match("ENV%['\"['\"]%]$")
      end,
      -- Function to return completion trigger pattern
      get_completion_trigger = function()
        return "ENV['"
      end
    }
  }
})
```

## 🎨 Appearance

The plugin uses your current colorscheme's colors for a consistent look:

- Variable names use Identifier colors
- Types use Type colors
- Values use String colors
- Sources use Directory colors

## 🤝 Contributing

Contributions are welcome! Feel free to submit issues and pull requests on GitHub.

## 📄 License

MIT License - See [LICENSE](./LICENSE) for details.
