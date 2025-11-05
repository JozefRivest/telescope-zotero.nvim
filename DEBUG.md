# Debugging Bibliography Location

If telescope-zotero still can't find your bibliography file, try this diagnostic:

## 1. Test in Neovim

Open your `.qmd` file and run this command in Neovim:

```vim
:lua print(require('zotero.bib').locate_quarto_bib())
```

This should print the path to your bibliography file. If it prints `nil`, the detection is failing.

## 2. Check for lspconfig

Run this command:

```vim
:lua print(vim.inspect(pcall(require, 'lspconfig.util')))
```

If the first value is `false`, you don't have lspconfig installed. The plugin now has a fallback, but lspconfig is recommended.

## 3. Manual Root Detection Test

Run this to see if the fallback search works:

```vim
:lua local fname = vim.api.nvim_buf_get_name(0); local current_dir = vim.fn.fnamemodify(fname, ':h'); for i = 1, 10 do if vim.fn.filereadable(current_dir .. '/_quarto.yml') == 1 then print('Found at: ' .. current_dir); break end; current_dir = vim.fn.fnamemodify(current_dir, ':h') end
```

## 4. Clear Cache

If you're still having issues, clear the bibliography cache:

```vim
:lua require('zotero.bib').clear_bib_cache()
```

Then try using telescope-zotero again.

## Common Issues

### Issue: "Empty original filetype, defaulting to 'quarto'"
This warning is harmless - it just means the plugin is using quarto as the default filetype.

### Issue: Bibliography not found even though _quarto.yml exists
- Make sure your _quarto.yml has proper YAML syntax
- Check that the path in `bibliography:` is relative to the project root, not the current file
- Restart Neovim after making changes to the plugin code

### Issue: Citations inserted but not added to bibliography file
- Check file permissions on your references.bib file
- Make sure the path resolved correctly with the diagnostic commands above
