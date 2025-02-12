# coc-ecolog

Environment variable completion extension for [coc.nvim](https://github.com/neoclide/coc.nvim), powered by [ecolog.nvim](https://github.com/tentacles/ecolog.nvim).

## Features

- Environment variable completion with type information
- Support for multiple environment file formats
- Integration with ecolog.nvim's shelter mode for sensitive data protection
- Smart completion triggers based on file type and context
- Markdown documentation in completion items

## Installation

```vim
:CocInstall coc-ecolog
```

## Configuration

Add these configurations to your `coc-settings.json`:

```json
{
  "ecolog.enable": true
}
```

## Requirements

- [coc.nvim](https://github.com/neoclide/coc.nvim)
- [ecolog.nvim](https://github.com/tentacles/ecolog.nvim)

## Development

1. Clone this repository
2. Install dependencies
   ```bash
   cd coc
   npm install
   ```
3. Build the extension
   ```bash
   npm run build
   ```
4. Create a symbolic link in your coc extensions directory
   ```bash
   ln -s /path/to/coc-ecolog ~/.config/coc/extensions/node_modules/
   ```
5. Restart coc.nvim

## License

MIT 