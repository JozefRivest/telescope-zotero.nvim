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
  local bib_entry = '@'
  local item = entry.value
  local citekey = item.citekey or ''
  bib_entry = bib_entry .. (item.itemType or '') .. '{' .. citekey .. ',\n'

  -- Process creators with deduplication
  if item.creators then
    local seen_creators = {}
    local author_list = {}

    for _, creator in ipairs(item.creators) do
      local creator_key = (creator.lastName or '') .. '|' .. (creator.firstName or '')
      if not seen_creators[creator_key] then
        seen_creators[creator_key] = true
        table.insert(author_list, (creator.lastName or '') .. ', ' .. (creator.firstName or ''))
      end
    end

    -- Process authors
    if creators_by_type['author'] and #creators_by_type['author'] > 0 then
      local author_list = {}
      for _, creator_key in ipairs(creators_by_type['author']) do
        local lastName, firstName = creator_key:match '([^|]+)|(.+)'
        if lastName and firstName then
          table.insert(author_list, lastName .. ', ' .. firstName)
        elseif lastName then
          table.insert(author_list, lastName)
        end
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
        if lastName and firstName then
          table.insert(editor_list, lastName .. ', ' .. firstName)
        elseif lastName then
          table.insert(editor_list, lastName)
        end
      end

      if #editor_list > 0 then
        bib_entry = bib_entry .. '  editor = {' .. table.concat(editor_list, ' and ') .. '},\n'
      end
    if #author_list > 0 then
      bib_entry = bib_entry .. '  author = {' .. table.concat(author_list, ' and ') .. '},\n'
    end
  end

  -- Process all other fields
  for k, v in pairs(item) do
    if k ~= 'citekey' and k ~= 'itemType' and k ~= 'creators' and k ~= 'attachment' and k ~= 'date' and type(v) == 'string' then
      -- Format the field based on Better BibTeX expectations
      local field_name = k

      -- Handle special fields that BBT might format differently
      if k == 'url' then
        -- Keep URL as is
        bib_entry = bib_entry .. '  ' .. field_name .. ' = {' .. v .. '},\n'
      elseif k == 'DOI' then
        -- Format DOI without the URL part
        bib_entry = bib_entry .. '  doi = {' .. v .. '},\n'
      elseif k == 'abstractNote' then
        -- Rename to abstract as used in BBT
        bib_entry = bib_entry .. '  abstract = {' .. v .. '},\n'
      else
        bib_entry = bib_entry .. '  ' .. field_name .. ' = {' .. v .. '},\n'
      end
    end
  end

  -- Handle date/year properly
  if item.date then
    -- Extract year from date field if not already present
    if not item.year then
      local year = string.match(item.date, '(%d%d%d%d)')
      if year then
        bib_entry = bib_entry .. '  year = {' .. year .. '},\n'
      end
    end

    -- Add date field in ISO format
    local iso_date = string.match(item.date, '(%d%d%d%d%-%d%d%-%d%d)')
    if iso_date then
      bib_entry = bib_entry .. '  date = {' .. iso_date .. '},\n'
    end
  end

  bib_entry = bib_entry .. '}\n'
  return bib_entry
end

return M
