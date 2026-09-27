-- Obsidian-style literature notes (zotlit-like) created from Zotero items.
local database = require 'zotero.database'

local M = {}

local builtin_templates = {
  literature = [[
## Research question
## Claim
## Argument
## Data
## Design
## Empirical findings
## Critique
## Future research
## Connections
Related:
]],
  method = [[
## Problem
<!-- What methodological gap does this address? Why do existing approaches fall short? -->

## Solution
<!-- The solution proposed by the authors -->

## Method
<!-- The measure / estimator / algorithm itself, stated plainly. -->

## Assumptions
<!-- Identifying assumptions; what has to hold for this to be valid. -->

## Inputs
<!-- Data requirements: unit of analysis, coverage, scale, preprocessing. -->

## Procedure
<!-- Steps, in order. -->

## Validation
<!-- Simulations, benchmarks, ground truth, robustness checks. -->

## Comparison
<!-- Versus existing methods. When does it win, when does it not? -->

## Limitations
<!-- Failure modes, sensitivity, computational cost. -->

## Implementation
<!-- Package / code / replication materials. -->

## Applications
<!-- Empirical applications shown in the paper. -->

## Use in my work
<!-- Where this would plug into my own projects. -->

## Critique
## Connections
Related:
]],
}

M.default_opts = {
  -- Folder where literature notes are written (required).
  dir = nil,
  -- Returns the note's file name (without .md).
  filename = function(item)
    return item.citekey or item.key
  end,
  -- Body templates. Each is { file = path } (plain markdown) or { body = string }.
  -- Bodies may use {{field}} placeholders, e.g. {{title}}, {{citekey}}, {{year}}.
  templates = {
    { name = 'literature', body = builtin_templates.literature },
    { name = 'method', body = builtin_templates.method, tag = 'method' },
  },
  -- Returns an ordered list of { key, value } pairs for the YAML frontmatter.
  frontmatter = nil,
  -- Insert a [[link]] to the note in the current buffer after creating it.
  insert_link = false,
}

local query_details = [[
  SELECT 'tag' AS kind, tags.name AS value, NULL AS extra
    FROM itemTags JOIN tags ON tags.tagID = itemTags.tagID
    WHERE itemTags.itemID = :id
  UNION ALL
  SELECT 'collection', collectionItems.collectionID, NULL
    FROM collectionItems WHERE collectionItems.itemID = :id
  UNION ALL
  SELECT 'attachment', itemAttachments.itemID, items.key
    FROM itemAttachments JOIN items ON items.itemID = itemAttachments.itemID
    WHERE itemAttachments.parentItemID = :id AND itemAttachments.contentType = 'application/pdf'
  UNION ALL
  SELECT 'related', itemRelations.object, NULL
    FROM itemRelations JOIN relationPredicates ON relationPredicates.predicateID = itemRelations.predicateID
    WHERE itemRelations.itemID = :id AND relationPredicates.predicate = 'dc:relation'
]]

local query_collections = [[
  SELECT collectionID, collectionName, parentCollectionID FROM collections
]]

local function rows(result)
  -- sqlite.lua's eval returns `true` when a query yields no rows.
  return type(result) == 'table' and result or {}
end

-- Adds tags, collection paths, PDF attachments and related item keys to `item`.
M.load_details = function(item)
  local db = database.open_zotero()
  if db == nil or item.itemID == nil then
    return item
  end

  local collections = {}
  for _, c in ipairs(rows(db:eval(query_collections))) do
    collections[c.collectionID] = c
  end
  local function collection_path(id)
    local parts = {}
    local c = collections[id]
    while c do
      table.insert(parts, 1, c.collectionName)
      c = collections[c.parentCollectionID]
    end
    return table.concat(parts, '/')
  end

  item.tags, item.collections, item.attachments, item.related = {}, {}, {}, {}
  for _, row in ipairs(rows(db:eval(query_details, { id = item.itemID }))) do
    if row.kind == 'tag' then
      table.insert(item.tags, row.value)
    elseif row.kind == 'collection' then
      table.insert(item.collections, collection_path(tonumber(row.value)))
    elseif row.kind == 'attachment' then
      table.insert(item.attachments, { itemID = tostring(row.value), key = row.extra })
    elseif row.kind == 'related' then
      local key = tostring(row.value):match '/items/(%w+)$'
      if key then
        table.insert(item.related, key)
      end
    end
  end
  table.sort(item.collections)
  return item
end

local function year_of(item)
  return (item.date or ''):match '(%d%d%d%d)' or ''
end

local function author_names(item)
  local names = {}
  for _, c in pairs(item.creators or {}) do
    if c.creatorType == 'author' or c.creatorType == nil then
      if c.firstName and c.firstName ~= '' then
        table.insert(names, c.lastName .. ', ' .. c.firstName)
      else
        table.insert(names, c.lastName)
      end
    end
  end
  return names
end

local function container_title(item)
  return item.publicationTitle or item.bookTitle or item.proceedingsTitle or item.websiteTitle or item.blogTitle
end

-- `citekeys` maps Zotero item keys to citation keys (used for related-item links).
M.default_frontmatter = function(item, citekeys)
  local attachment_ids = vim.tbl_map(function(a) return a.itemID end, item.attachments or {})
  local related = {}
  for _, key in ipairs(item.related or {}) do
    local citekey = citekeys[key]
    if citekey then
      table.insert(related, '[[' .. citekey .. ']]')
    end
  end
  return {
    -- zotero-key / zt-attachments let zotlit in Obsidian recognize these notes.
    { 'zotero-key', item.key },
    { 'zt-attachments', attachment_ids },
    { 'title', item.title },
    { 'authors', author_names(item) },
    { 'date', year_of(item) },
    { 'journal', container_title(item) },
    { 'doi', item.DOI },
    { 'citekey', item.citekey },
    { 'related', related },
    { 'collections', item.collections or {} },
    { 'tags', { 'lit' } },
    { 'status', 'unread' },
    { 'claim', '' },
    { 'added', os.date '%Y-%m-%d' },
  }
end

local function yaml_scalar(v)
  v = tostring(v)
  return '"' .. v:gsub('\\', '\\\\'):gsub('"', '\\"') .. '"'
end

local function to_yaml(fields)
  local lines = { '---' }
  for _, field in ipairs(fields) do
    local key, value = field[1], field[2]
    if type(value) == 'table' then
      if #value == 0 then
        table.insert(lines, key .. ': []')
      else
        table.insert(lines, key .. ':')
        for _, v in ipairs(value) do
          table.insert(lines, '  - ' .. yaml_scalar(v))
        end
      end
    elseif value == nil then
      table.insert(lines, key .. ':')
    else
      table.insert(lines, key .. ': ' .. yaml_scalar(value))
    end
  end
  table.insert(lines, '---')
  return lines
end

local function read_template(template)
  if template.body then
    return template.body
  end
  local path = vim.fn.expand(template.file)
  local f = io.open(path, 'r')
  if f == nil then
    vim.notify('[zotero] could not read template ' .. path, vim.log.levels.ERROR)
    return ''
  end
  local body = f:read '*a'
  f:close()
  return body
end

local function render_body(template, item)
  local vars = {
    title = item.title or '',
    citekey = item.citekey or '',
    key = item.key or '',
    year = year_of(item),
    authors = table.concat(author_names(item), '; '),
    journal = container_title(item) or '',
    doi = item.DOI or '',
  }
  return (read_template(template):gsub('{{%s*([%w_]+)%s*}}', function(name)
    return vars[name]
  end))
end

M.render = function(item, template, opts, citekeys)
  local fields = (opts.frontmatter or M.default_frontmatter)(item, citekeys)
  local lines = to_yaml(fields)

  local links = { '[Zotero](zotero://select/library/items/' .. item.key .. ')' }
  for _, a in ipairs(item.attachments or {}) do
    table.insert(links, '[PDF](zotero://open-pdf/library/items/' .. a.key .. ')')
  end
  vim.list_extend(lines, { '# ' .. (item.title or item.citekey), '', table.concat(links, ' '), '' })
  vim.list_extend(lines, vim.split(render_body(template, item), '\n', { plain = true }))
  return lines
end

-- Maps Zotero item keys to existing notes (via their `zotero-key` frontmatter),
-- so notes are found even when their file name differs from the current citekey.
M.index = nil

M.build_index = function(opts)
  M.index = {}
  for _, path in ipairs(vim.fn.globpath(vim.fn.expand(opts.dir), '**/*.md', false, true)) do
    local ok, head = pcall(vim.fn.readfile, path, '', 20)
    if ok then
      for _, line in ipairs(head) do
        local key = line:match '^zotero%-key:%s*"?([%w]+)"?'
        if key then
          M.index[key] = path
          break
        end
      end
    end
  end
end

M.note_path = function(item, opts)
  if M.index and M.index[item.key] then
    return M.index[item.key]
  end
  return vim.fn.expand(opts.dir) .. '/' .. opts.filename(item) .. '.md'
end

-- Returns the template whose `tag` matches one of the item's Zotero tags.
M.suggest_template = function(item, opts)
  local tags = {}
  for _, t in ipairs(item.tags or {}) do
    tags[vim.trim(t):lower()] = true
  end
  for _, template in ipairs(opts.templates) do
    if template.tag and tags[template.tag:lower()] then
      return template
    end
  end
  return opts.templates[1]
end

-- Writes the note if it doesn't exist yet. Returns the path, or nil on failure.
M.create = function(item, template, opts, citekeys)
  local path = M.note_path(item, opts)
  if vim.fn.filereadable(path) == 1 then
    return path, false
  end
  vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
  if vim.fn.writefile(M.render(item, template, opts, citekeys), path) ~= 0 then
    vim.notify('[zotero] could not write ' .. path, vim.log.levels.ERROR)
    return nil
  end
  return path, true
end

return M
