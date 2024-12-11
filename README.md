# 🌲 ecolog.nvim (WIP)

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
  lazy = false,
  opts = {
    -- Enables shelter mode for sensitive values
    shelter = {
        configuration = {
            partial_mode = false, -- Disables partial mode see shelter configuration below
            mask_char = "*",   -- Character used for masking
        },
        modules = {
            cmp = true,       -- Mask values in completion
            peek = false,      -- Mask values in peek view
            files = false,     -- Mask values in files
            telescope = false  -- Mask values in telescope
        }
    },
    path = vim.fn.getcwd(), -- Path to search for .env files
    preferred_environment = "development", -- Optional: prioritize specific env files
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

### Telescope Integration

First, load the extension:

```lua
require('telescope').load_extension('ecolog')
```

Then configure it in your Telescope setup (optional):

```lua
require('telescope').setup({
  extensions = {
    ecolog = {
      shelter = {
        -- Whether to show masked values when copying to clipboard
        mask_on_copy = false,
      },
      -- Default keybindings
      mappings = {
        -- Key to copy value to clipboard
        copy_value = "<C-y>",
        -- Key to copy name to clipboard
        copy_name = "<C-n>",
        -- Key to append value to buffer
        append_value = "<C-a>",
        -- Key to append name to buffer (defaults to <CR>)
        append_name = "<CR>",
      },
    }
  }
})
```

## ⚡ Performance

Ecolog is designed with performance in mind:

- Minimal impact on startup time through lazy loading of heavy dependencies
- Smart caching of environment variables and file contents
- Efficient file watching with debounced updates
- On-demand loading of language providers and completion features
- Optimized code path for frequently used operations

## ✨ Features

🔍 **Environment Variable Peeking**

- Quick peek at environment variable values and metadata
- Intelligent context detection
- Type-aware value display
- Preview inline comments directly in your code

🤖 **Smart Autocompletion**

- Integration with nvim-cmp
- Context-aware suggestions
- Type-safe completions
- Intelligent provider detection

🛡️ **Shelter Mode Protection**

- Mask sensitive values in completion menu
- Visual protection for .env file content
- Secure value peeking with masking
- Flexible per-feature control
- Real-time visual masking

🔄 **Real-time Updates**

- Automatic cache management
- Live environment file monitoring
- Instant mask updates
- File change detection

📁 **Multi-Environment Support**

- Multiple .env file handling
- Priority-based file loading
- Environment-specific configurations
- Smart file selection

💡 **Intelligent Type System**

- Automatic type inference
- Type validation and checking
- Smart type suggestions
- Context-based type detection

## 🚀 Usage

### Available Commands

| Command                                    | Description                                                               |
| ------------------------------------------ | ------------------------------------------------------------------------- |
| `:EcologPeek [variable_name]`              | Peek at environment variable value and metadata                           |
| `:EcologPeek`                              | Peek at environment variable under cursor                                 |
| `:EcologRefresh`                           | Refresh environment variable cache                                        |
| `:EcologSelect`                            | Open a selection window to choose environment file                        |
| `:EcologGoto`                              | Open selected environment file in buffer                                  |
| `:EcologGotoVar`                           | Go to specific variable definition in env file                            |
| `:EcologGotoVar [variable_name]`           | Go to specific variable definition in env file with variable under cursor |
| `:EcologShelterToggle [command] [feature]` | Control shelter mode for masking sensitive values                         |
| `:EcologShelterLinePeek`                   | Temporarily reveal value on current line in env file                      |

### 📝 Environment File Priority

Files are loaded in the following priority order:

1. `.env.{preferred_environment}` (if preferred_environment is set)
2. `.env`
3. Other `.env.*` files (alphabetically)

### 🔧 Language Support

#### 🟢 Currently Supported (have only tested JavaScript/TypeScript/React)

| Language         | Environment Access & Autocompletion trigger | Description                                                      |
| ---------------- | ------------------------------------------- | ---------------------------------------------------------------- |
| TypeScript/React | `process.env.*`<br>`import.meta.env.*`      | Full support for Node.js, Vite environment variables             |
| JavaScript/React | `process.env.*`<br>`import.meta.env.*`      | Complete support for both Node.js and modern frontend frameworks |
| Python           | `os.environ.get()`                          | Native Python environment variable access                        |
| PHP              | `getenv()`<br>`_ENV[]`                      | Support for both modern and legacy PHP env access                |
| Lua              | `os.getenv()`                               | Native Lua environment variable access                           |
| Go               | `os.Getenv()`                               | Go standard library environment access                           |
| Rust             | `std::env::var()`<br>`env::var()`           | Rust standard library environment access                         |

#### 🚧 Coming Soon

| Language | Planned Support                        | Status         |
| -------- | -------------------------------------- | -------------- |
| Deno     | `Deno.env.get()`                       | In Development |
| Ruby     | `ENV[]`                                | Planned        |
| C#       | `Environment.GetEnvironmentVariable()` | Planned        |
| Shell    | `$VAR`, `${VAR}`                       | Planned        |
| Docker   | `ARG`, `ENV`                           | Planned        |
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

## 🛡️ Shelter Mode

Shelter mode provides a secure way to work with sensitive environment variables by masking their values in different contexts. This feature helps prevent accidental exposure of sensitive data like API keys, passwords, tokens, and other credentials.

### 🔧 Configuration

```lua
require('ecolog').setup({
    shelter = {
        configuration = {
            -- Partial mode configuration:
            -- false: completely mask values (default)
            -- true: use default partial masking settings
            -- table: customize partial masking
            -- partial_mode = false,
            -- or with custom settings:
            partial_mode = {
                show_start = 3,    -- Show first 3 characters
                show_end = 3,      -- Show last 3 characters
                min_mask = 3,      -- Minimum masked characters
            },
            mask_char = "*",   -- Character used for masking
        },
        modules = {
            cmp = false,       -- Mask values in completion
            peek = false,      -- Mask values in peek view
            files = false,     -- Mask values in files
            telescope = false  -- Mask values in telescope
        }
    },
    path = vim.fn.getcwd(), -- Path to search for .env files
    preferred_environment = "development", -- Optional: prioritize specific env files
})
```

### 🎯 Features

#### Partial Masking

Three modes of operation:

1. **Full Masking (Default)**

   ```lua
   partial_mode = false
   -- Example: "my-secret-key" -> "************"
   ```

2. **Default Partial Masking**

   ```lua
   partial_mode = true
   -- Example: "my-secret-key" -> "my-***-key"
   ```

3. **Custom Partial Masking**
   ```lua
   partial_mode = {
       show_start = 4,    -- Show more start characters
       show_end = 2,      -- Show fewer end characters
       min_mask = 3,      -- Minimum mask length
   }
   -- Example: "my-secret-key" -> "my-s***ey"
   ```

#### 1. Completion Protection (cmp)

- Masks sensitive values in the completion menu
- Preserves variable names and types for context
- Integrates seamlessly with nvim-cmp
- Example completion item:
  ```
  DB_PASSWORD  Type: string
  Value: ********
  ```

#### 2. Peek Window Protection

- Masks values when using `:EcologPeek`
- Shows metadata (type, source) while protecting the value
- Example peek window:
  ```
  Name     : DB_PASSWORD
  Type     : string
  Source   : .env.development
  Value    : ********
  Comment  : Very important value
  ```

#### 3. File Content Protection

- Visually masks values in .env files
- Preserves the actual file content (masks are display-only)
- Updates automatically on file changes
- Maintains file structure and comments
- Only masks the value portion after `=`
- Supports quoted and unquoted values

### 🎮 Commands

`:EcologShelterToggle` provides flexible control over shelter mode:

1. Basic Usage:

   ```vim
   :EcologShelterToggle              " Toggle between all-off and initial settings
   ```

2. Global Control:

   ```vim
   :EcologShelterToggle enable       " Enable all shelter modes
   :EcologShelterToggle disable      " Disable all shelter modes
   ```

3. Feature-Specific Control:

   ```vim
   :EcologShelterToggle enable cmp   " Enable shelter for completion only
   :EcologShelterToggle disable peek " Disable shelter for peek only
   :EcologShelterToggle enable files " Enable shelter for file display
   ```

4. Quick Value Reveal:
   ```vim
   :EcologShelterLinePeek           " Temporarily reveal value on current line
   ```
   - Shows the actual value for the current line
   - Value is hidden again when cursor moves away
   - Only works when shelter mode is enabled for files

### 📝 Example

Original `.env` file:

```env
# Authentication
JWT_SECRET=my-super-secret-key
AUTH_TOKEN="bearer 1234567890"

# Database Configuration
DB_HOST=localhost
DB_USER=admin
DB_PASS=secure_password123
```

With full masking (partial_mode = false):

```env
# Authentication
JWT_SECRET=********************
AUTH_TOKEN=******************

# Database Configuration
DB_HOST=*********
DB_USER=*****
DB_PASS=******************
```

#### Partial Masking Examples

With default settings (show_start=3, show_end=3, min_mask=3):

```
"mysecretkey"     -> "mys***key"    # Enough space for min_mask (3) characters
"secret"          -> "******"        # Not enough space for min_mask between shown parts
"api_key"         -> "*******"       # Would only have 1 char for masking, less than min_mask
"very_long_key"   -> "ver*****key"   # Plenty of space for masking
```

The min_mask setting ensures that sensitive values are properly protected by requiring
a minimum number of masked characters between the visible parts. If this minimum
cannot be met, the entire value is masked for security.

### Telescope Integration

The plugin provides a Telescope extension for searching and managing environment variables.

#### Usage

Open the environment variables picker:

```vim
:Telescope ecolog env
```

#### Features

- 🔍 Search through all environment variables
- 📋 Copy variable names or values to clipboard
- ⌨️ Insert variables into your code
- 🛡️ Integrated with shelter mode for sensitive data protection
- 📝 Shows variable metadata (type, source file)

#### Default Keymaps

| Key     | Action                  |
| ------- | ----------------------- |
| `<CR>`  | Insert variable name    |
| `<C-y>` | Copy value to clipboard |
| `<C-n>` | Copy name to clipboard  |
| `<C-a>` | Append value to buffer  |

All keymaps are customizable through the configuration.

### 💡 Tips

1. **Selective Protection**: Enable shelter mode only for sensitive environments:

   ```lua
   -- In your config
   if vim.fn.getcwd():match("production") then
     require('ecolog').setup({
       shelter = {
           configuration = {
               partial_mode = {
                   show_start = 3,    -- Number of characters to show at start
                   show_end = 3,      -- Number of characters to show at end
                   min_mask = 3,      -- Minimum number of mask characters
               }
              mask_char = "*",   -- Character used for masking
           },
           modules = {
               cmp = true,       -- Mask values in completion
               peek = true,      -- Mask values in peek view
               files = true,     -- Mask values in files
               telescope = false -- Mask values in telescope
           }
       },
       path = vim.fn.getcwd(), -- Path to search for .env files
       preferred_environment = "development", -- Optional: prioritize specific env files
     })
   end
   ```

2. **Custom Masking**: Use different characters for masking:

   ```lua
   shelter = {
       configuration = {
          mask_char = "•"  -- Use dots
       }
   }
   -- or
   shelter = {
       configuration = {
          mask_char = "█"  -- Use blocks
       }
   }
   ```

3. **Temporary Viewing**: Use `:EcologShelterToggle disable` temporarily when you need to view values, then re-enable with `:EcologShelterToggle enable`

4. **Security Best Practices**:
   - Enable shelter mode by default for production environments
   - Use file shelter mode during screen sharing or pair programming
   - Enable completion shelter mode to prevent accidental exposure in screenshots

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
