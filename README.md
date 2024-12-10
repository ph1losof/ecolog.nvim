# 🌲 ecolog.nvim

<div align="center">

![Neovim](https://img.shields.io/badge/NeoVim-%2357A143.svg?&style=for-the-badge&logo=neovim&logoColor=white)
![Lua](https://img.shields.io/badge/lua-%232C2D72.svg?style=for-the-badge&logo=lua&logoColor=white)

A Neovim plugin for seamless environment variable integration and management. Provides intelligent autocompletion, type checking, and value peeking for environment variables in your projects. All in one place.

</div>

## 📦 Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

### Plugin Setup

```lua
{
  'philosofonusus/ecolog.nvim',
  dependencies = {
    'hrsh7th/nvim-cmp', -- Optional, for autocompletion support
  },
  -- Optionally reccommend adding keybinds (I use them personally)
  keys = {
    { '<leader>ge', '<cmd>EcologGoto<cr>', desc = 'Go to env file' },
    { '<leader>es', '<cmd>EcologSelect<cr>', desc = 'Switch env file' },
    { '<leader>ep', '<cmd>EcologPeek<cr>', desc = 'Ecolog peek variable' },
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

## ✨ Features

🔍 **Environment Variable Peeking**

- Quick peek at environment variable values and metadata
- Intelligent context detection

🤖 **Smart Autocompletion**

- Integration with nvim-cmp
- Context-aware suggestions
- Type-safe completions

🔒 **Security First**

- Optional sensitive value masking
- Secure value display options

🔄 **Real-time Updates**

- Automatic cache management
- Live environment file monitoring

📁 **Multi-Environment Support**

- Multiple .env file handling
- Priority-based file loading
- Environment-specific configurations

💡 **Intelligent Type System**

- Automatic type inference
- Type validation and checking
- Smart type suggestions

## 🚀 Usage

### Available Commands

| Command                       | Description                                        |
| ----------------------------- | -------------------------------------------------- |
| `:EcologPeek [variable_name]` | Peek at environment variable value and metadata    |
| `:EcologPeek`                 | Peek at environment variable under cursor          |
| `:EcologRefresh`              | Refresh environment variable cache                 |
| `:EcologSelect`               | Open a selection window to choose environment file |
| `:EcologGoto`                 | Open selected environment file in buffer           |

### 📝 Environment File Priority

Files are loaded in the following priority order:

1. `.env.{preferred_environment}` (if preferred_environment is set)
2. `.env`
3. Other `.env.*` files (alphabetically)

### 🔧 Language Support

#### 🟢 Currently Supported

| Language         | Environment Access & Autocompletion trigger | Description                                                      |
| ---------------- | ------------------------------------------- | ---------------------------------------------------------------- |
| TypeScript/React | `process.env.*`<br>`import.meta.env.*`      | Full support for Node.js, Vite environment variables             |
| JavaScript/React | `process.env.*`<br>`import.meta.env.*`      | Complete support for both Node.js and modern frontend frameworks |
| Python           | `os.environ.get()`                          | Native Python environment variable access                        |
| PHP              | `getenv()`<br>`_ENV[]`                      | Support for both modern and legacy PHP env access                |

#### 🚧 Coming Soon

| Language | Planned Support                        | Status         |
| -------- | -------------------------------------- | -------------- |
| Deno     | `Deno.env.get()`                       | In Development |
| Rust     | `std::env::var()`                      | Planned        |
| Go       | `os.Getenv()`                          | Planned        |
| Ruby     | `ENV[]`                                | Planned        |
| C#       | `Environment.GetEnvironmentVariable()` | Planned        |
| Shell    | `$VAR`, `${VAR}`                       | Planned        |
| Docker   | `ARG`, `ENV`                           | Planned        |
| Lua      | `os.getenv()`                          | Planned        |
| Kotlin   | `System.getenv()`                      | Planned        |

> 💡 **Want support for another language?**  
> Feel free to contribute by adding a new provider! Or just check out the [Custom Providers](#-custom-providers) section.

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

## 🎨 Theme Integration

The plugin seamlessly integrates with your current colorscheme:

| Element        | Color Source |
| -------------- | ------------ |
| Variable names | `Identifier` |
| Types          | `Type`       |
| Values         | `String`     |
| Sources        | `Directory`  |

## 🤝 Contributing

Contributions are welcome! Feel free to:

- 🐛 Report bugs
- 💡 Suggest features
- 🔧 Submit pull requests

## 📄 License

MIT License - See [LICENSE](./LICENSE) for details.

---

<div align="center">
Made with ❤️ by <a href="https://github.com/philosofonusus">TENTACLE</a>
</div>
