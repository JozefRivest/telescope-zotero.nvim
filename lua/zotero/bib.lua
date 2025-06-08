-- (Crudely) Locates the bibliography

local M = {}

M.quarto = {}
M.tex = {}
M.typst = {}
M['quarto.cached_bib'] = nil

M.locate_quarto_bib = function()
  if M['quarto.cached_bib'] then
    return M['quarto.cached_bib']
  end
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  for _, line in ipairs(lines) do
    local location = string.match(line, [[bibliography:[ "']*(.+)["' ]*]])
    if location then
      M['quarto.cached_bib'] = location
      return M['quarto.cached_bib']
    end
  end
  -- no bib locally defined
  -- test for quarto project-wide definition
  local fname = vim.api.nvim_buf_get_name(0)
  local root = require('lspconfig.util').root_pattern '_quarto.yml'(fname)
  if root then
    local file = root .. '/_quarto.yml'
    for line in io.lines(file) do
      local location = string.match(line, [[bibliography:[ "']*(.+)["' ]*]])
      if location then
        M['quarto.cached_bib'] = location
        return M['quarto.cached_bib']
      end
    end
  end
end

M.locate_typst_bib = function()
  local bufname = vim.api.nvim_buf_get_name(0) -- Get the current file path
  local dirname = vim.fn.fnamemodify(bufname, ':h') -- Get directory of the Typst file

  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  for _, line in ipairs(lines) do
    -- Adjust the pattern to capture only the first argument (the .bib file name)
    local location = string.match(line, '#bibliography%s*%(%s*"([^"]+)"')

    if location then
      local expanded_path = vim.fn.expand(location)

      -- If the path is relative, convert it to an absolute path
      if not expanded_path:match '^/' then
        expanded_path = dirname .. '/' .. expanded_path
      end

      return expanded_path
    end
  end

  vim.notify('No Typst bibliography file found!', vim.log.levels.WARN)
  return nil
end

M.locate_tex_bib = function()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  for _, line in ipairs(lines) do
    -- ignore commented bibliography
    local comment = string.match(line, '^%%')
    if not comment then
      local location = string.match(line, [[\bibliography{[ "']*([^'"\{\}]+)["' ]*}]])
      if location then
        return location .. '.bib'
      end
      -- checking for biblatex
      location = string.match(line, [[\addbibresource{[ "']*([^'"\{\}]+)["' ]*}]])
      if location then
        -- addbibresource optionally allows you to add .bib
        return location:gsub('.bib', '') .. '.bib'
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

  -- Escape special BibTeX characters but preserve LaTeX commands
  value = value:gsub('([{}])', '\\%1')
  value = value:gsub('\\\\', '\\')

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
      and k ~= 'date'  -- Exclude date field since we only want year
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

  -- Handle date/year with BBT preferences
  -- Only add year if we don't already have it from item.year
  -- if item.date and not item.year then
  --   local year = string.match(item.date, '(%d%d%d%d)')
  --   if year then
  --     bib_entry = bib_entry .. '  year = {' .. year .. '},\n'
  --   end
  -- end

  bib_entry = bib_entry .. '}\n'
  return bib_entry
end

-- Legacy function for backward compatibility
M.entry_to_bib_entry = function(entry)
  return M.entry_to_bbt_entry(entry, nil)
end

return M
