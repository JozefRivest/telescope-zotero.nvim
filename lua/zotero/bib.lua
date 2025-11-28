-- (Crudely) Locates the bibliography

local M = {}

M.quarto = {}
M.markdown = {}
M.tex = {}
M.typst = {}
M.rnoweb = {}
M['quarto.cached_bib'] = nil

-- Function to clear bibliography cache (useful when file is modified)
M.clear_bib_cache = function()
  M['quarto.cached_bib'] = nil
  M['markdown.cached_bib'] = nil
end

M.locate_quarto_bib = function()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local in_yaml_frontmatter = false
  local yaml_end_count = 0

  for _, line in ipairs(lines) do
    -- Check for YAML frontmatter boundaries
    if line:match('^---+%s*$') then
      yaml_end_count = yaml_end_count + 1
      if yaml_end_count == 1 then
        in_yaml_frontmatter = true
      elseif yaml_end_count == 2 then
        in_yaml_frontmatter = false
        break -- End of YAML frontmatter
      end
      goto continue
    end

    -- Only process lines within YAML frontmatter
    if in_yaml_frontmatter then
      -- Handle various bibliography formats:
      -- bibliography: references.bib
      -- bibliography: "references.bib"
      -- bibliography: 'references.bib'
      -- bibliography: [references.bib]
      -- bibliography: ["references.bib"]

      local location = nil

      -- First try simple format: bibliography: filename
      location = line:match('^%s*bibliography:%s*([^%s"\'%[%]]+)')

      -- If not found, try quoted format: bibliography: "filename" or 'filename'
      if not location then
        location = line:match('^%s*bibliography:%s*["\']([^"\']+)["\']')
      end

      -- If not found, try array format: bibliography: [filename]
      if not location then
        location = line:match('^%s*bibliography:%s*%[%s*["\']?([^"\'%[%]]+)["\']?')
      end
      if location then
        -- Clean up the location string
        location = location:gsub('^%s+', ''):gsub('%s+$', '')

        -- Convert path to be relative to the current file's directory if it's not absolute
        if not location:match('^/') then
          local current_file = vim.api.nvim_buf_get_name(0)
          local current_dir = vim.fn.fnamemodify(current_file, ':h')
          location = current_dir .. '/' .. location
        end

        M['quarto.cached_bib'] = location
        return location
      end
    end

    ::continue::
  end
  -- no bib locally defined
  -- test for quarto project-wide definition
  local fname = vim.api.nvim_buf_get_name(0)

  -- Try to find project root with _quarto.yml
  local root = nil
  local ok, lspconfig = pcall(require, 'lspconfig.util')
  if ok then
    root = lspconfig.root_pattern('_quarto.yml')(fname)
  else
    -- Fallback: manually search up directory tree
    local current_dir = vim.fn.fnamemodify(fname, ':h')
    for _ = 1, 10 do -- max 10 levels up
      if vim.fn.filereadable(current_dir .. '/_quarto.yml') == 1 then
        root = current_dir
        break
      end
      local parent = vim.fn.fnamemodify(current_dir, ':h')
      if parent == current_dir then
        break -- reached filesystem root
      end
      current_dir = parent
    end
  end

  if root then
    local file = root .. '/_quarto.yml'
    -- Add error handling for file reading
    local ok, result = pcall(function()
      local in_bibliography_section = false
      for line in io.lines(file) do
        -- Check for single-line bibliography format: bibliography: path.bib
        local location = string.match(line, [[^%s*bibliography:[ "']*(.+)["' ]*$]])
        if location then
          -- Clean up the location string
          location = location:gsub('^%s+', ''):gsub('%s+$', '')
          location = location:gsub('["\']', '')
          location = location:gsub('^%-+%s*', '') -- Remove leading dash and spaces

          -- Convert path to be relative to the project root if it's not absolute
          if not location:match('^/') then
            location = root .. '/' .. location
          end

          M['quarto.cached_bib'] = location
          return location
        end

        -- Check for multi-line bibliography array format
        if line:match('^%s*bibliography:%s*$') then
          in_bibliography_section = true
        elseif in_bibliography_section then
          -- Match array item: - path.bib or - "path.bib"
          location = string.match(line, [[^%s*%-+%s*["']?([^"']+)["']?%s*$]])
          if location then
            -- Clean up the location string
            location = location:gsub('^%s+', ''):gsub('%s+$', '')
            location = location:gsub('["\']', '')

            -- Convert path to be relative to the project root if it's not absolute
            if not location:match('^/') then
              location = root .. '/' .. location
            end

            M['quarto.cached_bib'] = location
            return location
          elseif not line:match('^%s*%-') and not line:match('^%s*$') then
            -- Exit bibliography section if we hit a non-array line
            in_bibliography_section = false
          end
        end
      end
      return nil
    end)
    if ok and result then
      return result
    elseif not ok then
      vim.notify('Error reading _quarto.yml: ' .. tostring(result), vim.log.levels.WARN)
    end
  end
end

M.locate_markdown_bib = function()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local in_yaml_frontmatter = false
  local yaml_end_count = 0

  for _, line in ipairs(lines) do
    -- Check for YAML frontmatter boundaries
    if line:match('^---+%s*$') then
      yaml_end_count = yaml_end_count + 1
      if yaml_end_count == 1 then
        in_yaml_frontmatter = true
      elseif yaml_end_count == 2 then
        in_yaml_frontmatter = false
        break -- End of YAML frontmatter
      end
      goto continue
    end

    -- Only process lines within YAML frontmatter
    if in_yaml_frontmatter then
      local location = nil

      -- First try simple format: bibliography: filename
      location = line:match('^%s*bibliography:%s*([^%s"\'%[%]]+)')

      -- If not found, try quoted format: bibliography: "filename" or 'filename'
      if not location then
        location = line:match('^%s*bibliography:%s*["\']([^"\']+)["\']')
      end

      -- If not found, try array format: bibliography: [filename]
      if not location then
        location = line:match('^%s*bibliography:%s*%[%s*["\']?([^"\'%[%]]+)["\']?')
      end

      if location then
        -- Clean up the location string
        location = location:gsub('^%s+', ''):gsub('%s+$', '')

        -- Convert path to be relative to the current file's directory if it's not absolute
        if not location:match('^/') then
          local current_file = vim.api.nvim_buf_get_name(0)
          local current_dir = vim.fn.fnamemodify(current_file, ':h')
          location = current_dir .. '/' .. location
        end

        M['markdown.cached_bib'] = location
        return location
      end
    end

    ::continue::
  end
  -- no bib locally defined
  -- test for markdown project-wide definition
  local fname = vim.api.nvim_buf_get_name(0)

  -- Try to find project root with _markdown.yml
  local root = nil
  local ok, lspconfig = pcall(require, 'lspconfig.util')
  if ok then
    root = lspconfig.root_pattern('_markdown.yml')(fname)
  else
    -- Fallback: manually search up directory tree
    local current_dir = vim.fn.fnamemodify(fname, ':h')
    for _ = 1, 10 do -- max 10 levels up
      if vim.fn.filereadable(current_dir .. '/_markdown.yml') == 1 then
        root = current_dir
        break
      end
      local parent = vim.fn.fnamemodify(current_dir, ':h')
      if parent == current_dir then
        break -- reached filesystem root
      end
      current_dir = parent
    end
  end

  if root then
    local file = root .. '/_markdown.yml'
    -- Add error handling for file reading
    local ok, err = pcall(function()
      for line in io.lines(file) do
        local location = string.match(line, [[bibliography:[ "']*(.+)["' ]*]])
        if location then
          M['markdown.cached_bib'] = location
          return M['markdown.cached_bib']
        end
      end
    end)
    if not ok then
      vim.notify('Error reading _markdown.yml: ' .. tostring(err), vim.log.levels.WARN)
    end
  end
end

M.locate_typst_bib = function()
  local bufname = vim.api.nvim_buf_get_name(0) -- Get the current file path
  local dirname = vim.fn.fnamemodify(bufname, ':h') -- Get directory of the Typst file

  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  for _, line in ipairs(lines) do
    -- Adjust the pattern to capture only the first argument (the .bib file name)
    local location = string.match(line, '#bibliography%s*%([^"]*"([^"]+)"')

    if location then
      local expanded_path = vim.fn.expand(location)

      -- Try to find project root with typst.toml
      local root = nil
      local ok, lspconfig = pcall(require, 'lspconfig.util')
      if ok then
        root = lspconfig.root_pattern('typst.toml')(bufname)
      else
        -- Fallback: manually search up directory tree
        local current_dir = dirname
        for _ = 1, 10 do -- max 10 levels up
          if vim.fn.filereadable(current_dir .. '/typst.toml') == 1 then
            root = current_dir
            break
          end
          local parent = vim.fn.fnamemodify(current_dir, ':h')
          if parent == current_dir then
            break -- reached filesystem root
          end
          current_dir = parent
        end
      end

      -- In Typst, paths starting with "/" are relative to the project root (not filesystem root)
      -- All other paths are relative to the current file's directory
      if expanded_path:match '^/' then
        -- Path starting with "/" is project-relative in Typst
        if root then
          -- Remove the leading "/" and prepend the project root
          expanded_path = root .. expanded_path
        else
          -- No project root found, treat as relative to current file's directory
          expanded_path = dirname .. expanded_path
        end
      else
        -- Path is relative to current file's directory
        if root then
          expanded_path = root .. '/' .. expanded_path
        else
          expanded_path = dirname .. '/' .. expanded_path
        end
      end

      return expanded_path
    end
  end

  vim.notify('No Typst bibliography file found!', vim.log.levels.WARN)
  return nil
end

M.locate_tex_bib = function()
  local bufname = vim.api.nvim_buf_get_name(0)
  local dirname = vim.fn.fnamemodify(bufname, ':h')

  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  for _, line in ipairs(lines) do
    -- ignore commented bibliography
    local comment = string.match(line, '^%%')
    if not comment then
      local location = string.match(line, [[\bibliography{[ "']*([^'"\{\}]+)["' ]*}]])
      if location then
        local bib_path = location .. '.bib'
        -- Return absolute path for consistency
        if not bib_path:match '^/' then
          bib_path = dirname .. '/' .. bib_path
        end
        return bib_path
      end
      -- checking for biblatex
      location = string.match(line, [[\addbibresource{[ "']*([^'"\{\}]+)["' ]*}]])
      if location then
        -- addbibresource optionally allows you to add .bib
        if not location:match '%.bib$' then -- Fixed: removed unnecessary second parameter
          location = location .. '.bib'
        end
        -- Return absolute path for consistency
        if not location:match '^/' then
          location = dirname .. '/' .. location
        end
        return location
      end
    end
  end
end

M.locate_rnw_bib = function()
  local bufname = vim.api.nvim_buf_get_name(0)
  local dirname = vim.fn.fnamemodify(bufname, ':h')

  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  for _, line in ipairs(lines) do
    -- ignore commented bibliography
    local comment = string.match(line, '^%%')
    if not comment then
      local location = string.match(line, [[\bibliography{[ "']*([^'"\{\}]+)["' ]*}]])
      if location then
        local bib_path = location .. '.bib'
        -- Return absolute path for consistency
        if not bib_path:match '^/' then
          bib_path = dirname .. '/' .. bib_path
        end
        return bib_path
      end
      -- checking for biblatex
      location = string.match(line, [[\addbibresource{[ "']*([^'"\{\}]+)["' ]*}]])
      if location then
        -- addbibresource optionally allows you to add .bib
        if not location:match '%.bib$' then -- Fixed: removed unnecessary second parameter
          location = location .. '.bib'
        end
        -- Return absolute path for consistency
        if not location:match '^/' then
          location = dirname .. '/' .. location
        end
        return location
      end
    end
  end
end
-- BBT item type mappings
M.bbt_item_type_map = {
  journalArticle = 'article',
  book = 'book',
  bookSection = 'incollection',
  conferencePaper = 'inproceedings',
  thesis = 'phdthesis',
  webpage = 'misc',
  report = 'techreport',
  magazineArticle = 'article',
  newspaperArticle = 'article',
  manuscript = 'unpublished',
  patent = 'misc',
  software = 'misc',
}

-- BBT field mappings
M.bbt_field_map = {
  title = 'title',
  publicationTitle = 'journal',
  bookTitle = 'booktitle',
  year = 'year',
  DOI = 'doi',
  url = 'url',
  abstractNote = 'abstract',
  volume = 'volume',
  issue = 'number',
  pages = 'pages',
  publisher = 'publisher',
  place = 'address',
  ISBN = 'isbn',
  ISSN = 'issn',
  language = 'language',
  archive = 'archive',
  archiveLocation = 'archiveprefix',
  libraryCatalog = 'library',
  callNumber = 'call-number',
  rights = 'rights',
  extra = 'note',
  series = 'series',
  seriesNumber = 'number',
  edition = 'edition',
  numPages = 'pages',
  shortTitle = 'shorttitle',
}

-- Clean field values according to BBT standards
M.clean_field_value = function(value, field_type)
  if not value or value == '' then
    return ''
  end

  -- Remove HTML tags
  value = value:gsub('<[^>]+>', '')

  -- Handle specific field formatting
  if field_type == 'doi' then
    -- Remove URL prefix from DOI
    value = value:gsub('^https?://[^/]*/?', '')
    value = value:gsub('^doi:', '')
  elseif field_type == 'pages' then
    -- Format page ranges
    value = value:gsub('%-%-', '--')
    value = value:gsub('—', '--')
  elseif field_type == 'url' then
    -- Clean URL
    value = value:gsub('^%s+', ''):gsub('%s+$', '')
  end

  -- Improved escaping: only escape unescaped braces
  -- This preserves intentional LaTeX commands while escaping problematic braces
  value = value:gsub('([^\\])([{}])', '%1\\%2')
  value = value:gsub('^([{}])', '\\%1') -- Handle braces at start of string

  return value
end

-- Enhanced BBT-compatible entry generation
M.entry_to_bbt_entry = function(entry, bbt_db)
  local item = entry.value
  local citekey = item.citekey or ''

  -- First try to get from BBT cache if database available
  if bbt_db then
    local ok, database = pcall(require, 'zotero.database')
    if ok then
      local bbt_export = database.get_bbt_cached_entry(item.key)
      if bbt_export and bbt_export ~= '' then
        return bbt_export .. '\n'
      end
    end
  end

  -- Enhanced manual generation with BBT field mapping
  local item_type = M.bbt_item_type_map[item.itemType] or item.itemType or 'misc'
  local bib_entry = '@' .. item_type .. '{' .. citekey .. ',\n'

  -- Process creators with BBT-style formatting
  if item.creators then
    local seen_creators = {}
    local authors = {}
    local editors = {}
    local translators = {}

    for _, creator in ipairs(item.creators) do
      local creator_key = (creator.lastName or '') .. '|' .. (creator.firstName or '')
      if not seen_creators[creator_key] then
        seen_creators[creator_key] = true

        local name_parts = {}
        if creator.lastName then
          table.insert(name_parts, creator.lastName)
        end
        if creator.firstName then
          table.insert(name_parts, creator.firstName)
        end
        local full_name = table.concat(name_parts, ', ')

        if creator.creatorType == 'author' then
          table.insert(authors, full_name)
        elseif creator.creatorType == 'editor' then
          table.insert(editors, full_name)
        elseif creator.creatorType == 'translator' then
          table.insert(translators, full_name)
        end
      end
    end

    if #authors > 0 then
      bib_entry = bib_entry .. '  author = {' .. table.concat(authors, ' and ') .. '},\n'
    end
    if #editors > 0 then
      bib_entry = bib_entry .. '  editor = {' .. table.concat(editors, ' and ') .. '},\n'
    end
    if #translators > 0 then
      bib_entry = bib_entry .. '  translator = {' .. table.concat(translators, ' and ') .. '},\n'
    end
  end

  -- Process fields using BBT mapping
  for zotero_field, bbt_field in pairs(M.bbt_field_map) do
    local value = item[zotero_field]
    if value and type(value) == 'string' and value ~= '' then
      value = M.clean_field_value(value, bbt_field)
      if value ~= '' then
        bib_entry = bib_entry .. '  ' .. bbt_field .. ' = {' .. value .. '},\n'
      end
    end
  end

  -- Handle remaining fields not in mapping
  for k, v in pairs(item) do
    if
      k ~= 'citekey'
      and k ~= 'itemType'
      and k ~= 'creators'
      and k ~= 'attachment'
      and k ~= 'key'
      and k ~= 'date' -- Exclude date field since we only want year
      and not M.bbt_field_map[k]
      and type(v) == 'string'
      and v ~= ''
    then
      local cleaned_value = M.clean_field_value(v, k)
      if cleaned_value ~= '' then
        bib_entry = bib_entry .. '  ' .. k .. ' = {' .. cleaned_value .. '},\n'
      end
    end
  end

  -- Handle date/year extraction if year is not already present
  if not item.year and item.date then
    local year = string.match(item.date, '(%d%d%d%d)')
    if year then
      bib_entry = bib_entry .. '  year = {' .. year .. '},\n'
    end
  end

  bib_entry = bib_entry .. '}\n'
  return bib_entry
end

-- Legacy function for backward compatibility
M.entry_to_bib_entry = function(entry)
  return M.entry_to_bbt_entry(entry, nil)
end

return M
