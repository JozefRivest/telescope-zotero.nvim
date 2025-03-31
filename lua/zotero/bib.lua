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

M.entry_to_bib_entry = function(entry)
  local item = entry.value
  local citekey = item.citekey or ''

  -- Map Zotero item types to BibTeX entry types
  local type_mapping = {
    journalArticle = 'article',
    book = 'book',
    bookSection = 'incollection',
    conferencePaper = 'inproceedings',
    report = 'techreport',
    thesis = 'phdthesis',
    manuscript = 'unpublished',
    webpage = 'misc',
    magazineArticle = 'article',
    newspaperArticle = 'article',
    -- Add more mappings as needed
  }

  -- Get the BibTeX entry type based on the Zotero item type
  local entry_type = type_mapping[item.itemType] or item.itemType or 'misc'

  -- Start building the BibTeX entry
  local bib_entry = '@' .. entry_type .. '{' .. citekey .. ',\n'

  -- Define field order based on entry type
  local common_fields = { 'title', 'author', 'editor', 'year', 'month', 'doi', 'url', 'urldate', 'abstract', 'langid', 'keywords' }

  local type_specific_fields = {
    article = { 'journal', 'volume', 'number', 'pages', 'issn' },
    book = { 'publisher', 'address', 'edition', 'isbn', 'series', 'volume', 'number' },
    incollection = { 'booktitle', 'publisher', 'address', 'chapter', 'pages', 'isbn', 'editor' },
    inproceedings = { 'booktitle', 'series', 'pages', 'organization', 'publisher', 'address' },
    techreport = { 'institution', 'number', 'address', 'type' },
    phdthesis = { 'school', 'address', 'type' },
    unpublished = { 'note' },
    misc = {},
  }

  -- Create the combined field order for this entry type
  local field_order = common_fields
  local specific_fields = type_specific_fields[entry_type] or {}
  for _, field in ipairs(specific_fields) do
    if not vim.tbl_contains(field_order, field) then
      table.insert(field_order, field)
    end
  end

  -- Field mapping from Zotero fields to BibTeX fields
  local field_mapping = {
    accessDate = 'urldate',
    abstractNote = 'abstract',
    DOI = 'doi',
    ISBN = 'isbn',
    ISSN = 'issn',
    publicationTitle = 'journal',
    bookTitle = 'booktitle',
    publisher = 'publisher',
    place = 'address',
    pages = 'pages',
    series = 'series',
    seriesNumber = 'number',
    institution = 'institution',
    university = 'school',
    language = 'langid',
    -- Add more mappings as needed
  }

  -- Process creators with deduplication (authors are high priority)
  if item.creators then
    -- Group creators by type (author, editor, etc.)
    local creators_by_type = {}

    for _, creator in ipairs(item.creators) do
      local creator_type = creator.creatorType or 'author'
      if not creators_by_type[creator_type] then
        creators_by_type[creator_type] = {}
      end

      local creator_key = (creator.lastName or '') .. '|' .. (creator.firstName or '')
      local seen_creator = false

      -- Check if this creator is already in the list
      for _, existing in ipairs(creators_by_type[creator_type]) do
        if existing == creator_key then
          seen_creator = true
          break
        end
      end

      if not seen_creator and creator.firstName and creator.lastName then
        table.insert(creators_by_type[creator_type], creator_key)
      end
    end

    -- Process authors
    if creators_by_type['author'] and #creators_by_type['author'] > 0 then
      local author_list = {}
      for _, creator_key in ipairs(creators_by_type['author']) do
        local lastName, firstName = creator_key:match '([^|]+)|(.+)'
        table.insert(author_list, lastName .. ', ' .. firstName)
      end

      if #author_list > 0 then
        bib_entry = bib_entry .. '  author = {' .. table.concat(author_list, ' and ') .. '},\n'
      end
    end

    -- Process editors
    if creators_by_type['editor'] and #creators_by_type['editor'] > 0 then
      local editor_list = {}
      for _, creator_key in ipairs(creators_by_type['editor']) do
        local lastName, firstName = creator_key:match '([^|]+)|(.+)'
        table.insert(editor_list, lastName .. ', ' .. firstName)
      end

      if #editor_list > 0 then
        bib_entry = bib_entry .. '  editor = {' .. table.concat(editor_list, ' and ') .. '},\n'
      end
    end
  end

  -- Helper function for month formatting
  local function format_month(date_str)
    if not date_str then
      return nil
    end

    -- Extract month from date string (assuming format like YYYY-MM-DD)
    local _, _, year, month, day = date_str:find '(%d%d%d%d)-?(%d?%d?)-?(%d?%d?)'

    if month then
      local month_num = tonumber(month)
      if month_num then
        local month_abbr = { 'jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec' }
        return month_abbr[month_num]
      end
    end
    return nil
  end

  -- Extract date components if available
  if item.date then
    local year = string.match(item.date, '(%d%d%d%d)')
    if year then
      item.year = year
    end

    local month_abbr = format_month(item.date)
    if month_abbr then
      item.month = month_abbr
    end
  end

  -- Format urldate in YYYY-MM-DD format if accessDate exists
  if item.accessDate then
    local y, m, d = item.accessDate:match '(%d%d%d%d)-(%d%d)-(%d%d)'
    if y and m and d then
      item.urldate = y .. '-' .. m .. '-' .. d
    end
  end

  -- Create a table of all available fields
  local available_fields = {}
  for k, v in pairs(item) do
    if
      type(v) == 'string'
      and k ~= 'citekey'
      and k ~= 'itemType'
      and k ~= 'attachment'
      and k ~= 'creators'
      and k ~= 'date' -- Skip date since we extract year and month separately
      and k ~= 'accessDate'
    then -- Skip accessDate since we format it as urldate
      -- Use the mapped field name if available
      local field_name = field_mapping[k] or k
      available_fields[field_name] = v
    end
  end

  -- Specially format title with double braces for capitalization preservation
  if available_fields.title then
    available_fields.title = '{{' .. available_fields.title .. '}}'
  end

  -- Also format booktitle with double braces if it exists
  if available_fields.booktitle then
    available_fields.booktitle = '{{' .. available_fields.booktitle .. '}}'
  end

  -- Add fields in the specified order
  for _, field in ipairs(field_order) do
    if available_fields[field] then
      bib_entry = bib_entry .. '  ' .. field .. ' = {' .. available_fields[field] .. '},\n'
    end
  end

  -- End the entry
  bib_entry = bib_entry:sub(1, -3) .. '\n}\n' -- Remove trailing comma and newline

  return bib_entry
end

return M
