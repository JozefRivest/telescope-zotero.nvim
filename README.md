# telescope-zotero.nvim

This is a forked version of the plugin from [jmbuhr](https://github.com/jmbuhr/telescope-zotero.nvim). It offers pretty much all the same functionalities with enhance citation style picker and Better BibTex formating. 

This does **not** provide autompletion in the document itself, as this is handled by https://github.com/jmbuhr/cmp-pandoc-references
for entries already in `references.bib`. The intended workflow separates already used references from new ones imported from Zotero
via this new plugin.

## Requirements

- [Zotero](https://www.zotero.org/)
- [Better Bib Tex](https://retorque.re/zotero-better-bibtex/)

## Features

- Search your Zotero library directly from Neovim
- Insert citations in the appropriate format for your filetype (LaTeX, Quarto, Typst)
- Preview all available citation formats in the telescope UI
- Select different citation formats directly with keyboard shortcuts
- Open PDFs and DOI links directly from the picker
- Automatically add references to your bibliography file

## Setup

Add to your telescope config, e.g. in lazy.nvim

```lua
{
  'nvim-telescope/telescope.nvim',
  dependencies = {
    -- your other telescope extensions
    -- ...
    {
      'JozefRivest/telescope-zotero.nvim',
      dependencies = {
        { 'kkharji/sqlite.lua' },
      },
      -- options:
      -- to use the default opts:
      opts = {},
      -- to configure manually:
      -- config = function
      --   require'zotero'.setup{ <your options> }
      -- end,
    },
  },
  config = function()
    local telescope = require 'telescope'
    -- other telescope setup
    -- ...
    telescope.load_extension 'zotero'
  end
},
```

<!--

## Key Mappings

When the telescope picker is open, the following key mappings are available:

| Key | Mode | Description |
|-----|------|-------------|
| `<CR>` | Normal/Insert | Show citation format options in the preview panel |
| `<C-o>` | Insert | Open attachment (PDF or DOI) |
| `o` | Normal | Open attachment (PDF or DOI) |
| `<C-h>` | Insert | Show help with available commands |
| `?` | Normal | Show help with available commands |

-->

### Format Selection

When you press Enter on a citation, a format selection menu will appear:

1. Select the desired citation format from the list
2. Press Enter to confirm, or Esc to cancel

Available formats by filetype:
- For Quarto/Markdown files: `@citekey` and `[@citekey]`
- For Typst files: `@citekey` and `#cite(<citekey>)`
- For LaTeX/TeX files: `\cite{citekey}`

## Inspiration

This extension is inspired by the following plugins that all do an amazing job, but not quite what I need.
Depending on your needs, you should have a look at those:

- [zotcite](https://github.com/jalvesaq/zotcite) provides omnicompletion for zotero items in Quarto, Rmarkdown etc., but requires additional dependencies and uses a custom pandoc lua filter instead of a references.bib file
- [zotex.nvim](https://github.com/tiagovla/zotex.nvim) is very close, but as a nvim-cmp completion source, which doesn't fit
  with the intended separation of concerns.
- [telescope-zotero](https://github.com/jmbuhr/telescope-zotero.nvim)

Special Thanks to @kkharji for the `sqlite.lua` extension!
