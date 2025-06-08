local sqlite = require 'sqlite.db'

local M = {}

local function connect(path)
  path = vim.fn.expand(path)
  local ok, db = pcall(sqlite.open, sqlite, 'file:' .. path .. '?immutable=1', { open_mode = 'ro' })
  if ok then
    return db
  else
    vim.notify_once(('[zotero] could not open database at %s.'):format(path))
    return nil
  end
end

M.connect = function(opts)
  M.db = connect(opts.zotero_db_path)
  M.bbt = connect(opts.better_bibtex_db_path)
  if M.db == nil or M.bbt == nil then
    return false
  end
  return true
end

local query_bbt = [[
  SELECT
    itemKey, citationKey
  FROM
    citationkey
]]

local query_items = [[
    SELECT
      DISTINCT items.key, items.itemID,
      fields.fieldName,
      parentItemDataValues.value,
      itemTypes.typeName,
      itemAttachments.path AS attachment_path,
      itemAttachments.contentType AS attachment_content_type,
      itemAttachments.linkMode AS attachment_link_mode,
      -- Fetch the folder name from the itemAttachments table
      SUBSTR(itemAttachments.path, INSTR(itemAttachments.path, ':') + 1) AS folder_name
    FROM
      items
      INNER JOIN itemData ON itemData.itemID = items.itemID
      INNER JOIN itemDataValues ON itemData.valueID = itemDataValues.valueID
      INNER JOIN itemData as parentItemData ON parentItemData.itemID = items.itemID
      INNER JOIN itemDataValues as parentItemDataValues ON parentItemDataValues.valueID = parentItemData.valueID
      INNER JOIN fields ON fields.fieldID = parentItemData.fieldID
      INNER JOIN itemTypes ON itemTypes.itemTypeID = items.itemTypeID
      LEFT JOIN itemAttachments ON items.itemID = itemAttachments.parentItemID AND itemAttachments.contentType = 'application/pdf'
]]
local query_creators = [[
    SELECT
      DISTINCT items.key,
      creators.firstName,
      creators.lastName,
      itemCreators.orderIndex,
      creatorTypes.creatorType
    FROM
      items
      INNER JOIN itemData ON itemData.itemID = items.itemID
      INNER JOIN itemCreators ON itemCreators.itemID = items.itemID
      INNER JOIN creators ON creators.creatorID = itemCreators.creatorID
      INNER JOIN creatorTypes ON itemCreators.creatorTypeID = creatorTypes.creatorTypeID
    ]]

-- Get BBT cached export for a specific item
M.get_bbt_cached_entry = function(item_key)
  if not M.bbt then return nil end
  
  -- First check if cache table exists with proper error handling
  local table_check = [[
    SELECT name FROM sqlite_master WHERE type='table' AND name='cache'
  ]]
  
  local ok, table_exists = pcall(M.bbt.eval, M.bbt, table_check)
  if not ok or not table_exists or type(table_exists) ~= 'table' or #table_exists == 0 then
    -- Table doesn't exist or query failed, return nil to fall back to manual generation
    return nil
  end
  
  -- Try different possible cache table structures
  local queries = {
    -- Original attempt
    [[
      SELECT bibTeX FROM cache 
      WHERE itemKey = ? AND exportNotes = 0
      ORDER BY dateModified DESC 
      LIMIT 1
    ]],
    -- Alternative without exportNotes filter
    [[
      SELECT bibTeX FROM cache 
      WHERE itemKey = ?
      ORDER BY dateModified DESC 
      LIMIT 1
    ]],
    -- Check if it's called bibtex instead of bibTeX
    [[
      SELECT bibtex FROM cache 
      WHERE itemKey = ?
      ORDER BY dateModified DESC 
      LIMIT 1
    ]]
  }
  
  for _, query in ipairs(queries) do
    local query_ok, results = pcall(M.bbt.eval, M.bbt, query, {item_key})
    if query_ok and results and type(results) == 'table' and results[1] then
      local entry = results[1].bibTeX or results[1].bibtex
      if entry and entry ~= '' then
        return entry
      end
    end
  end
  
  return nil
end

-- Debug function to list BBT database tables
M.list_bbt_tables = function()
  if not M.bbt then return {} end
  
  local query = [[
    SELECT name FROM sqlite_master WHERE type='table'
  ]]
  
  local ok, results = pcall(M.bbt.eval, M.bbt, query)
  if ok and results and type(results) == 'table' then
    local tables = {}
    for _, row in ipairs(results) do
      if row and row.name then
        table.insert(tables, row.name)
      end
    end
    return tables
  end
  
  return {}
end

-- Get BBT preferences
M.get_bbt_preferences = function()
  if not M.bbt then return {} end
  
  local query = [[
    SELECT name, value FROM 'better-bibtex' 
    WHERE name IN ('citeKeyFormat', 'exportTitleCase', 'exportBraceProtection')
  ]]
  
  local prefs = {}
  local ok, results = pcall(M.bbt.eval, M.bbt, query)
  if ok and results and type(results) == 'table' then
    for _, row in ipairs(results) do
      if row and row.name and row.value then
        prefs[row.name] = row.value
      end
    end
  end
  
  return prefs
end

function M.get_items()
  local items = {}
  local raw_items = {}
  local sql_items = M.db:eval(query_items)
  local sql_creators = M.db:eval(query_creators)
  local sql_bbt = M.bbt:eval(query_bbt)

  if sql_items == nil or sql_creators == nil or sql_bbt == nil then
    vim.notify_once('[zotero] could not query database.', vim.log.levels.WARN, {})
    return {}
  end
  local bbt_citekeys = {}
  for _, v in pairs(sql_bbt) do
    bbt_citekeys[v.itemKey] = v.citationKey
  end

  for _, v in pairs(sql_items) do
    if raw_items[v.key] == nil then
      raw_items[v.key] = { creators = {}, attachment = {}, key = v.key }
    end
    raw_items[v.key][v.fieldName] = v.value
    raw_items[v.key].itemType = v.typeName
    if v.attachment_path then
      raw_items[v.key].attachment.path = v.attachment_path
      raw_items[v.key].attachment.content_type = v.attachment_content_type
      raw_items[v.key].attachment.link_mode = v.attachment_link_mode
    end
    if v.fieldName == 'DOI' then
      raw_items[v.key].DOI = v.value
    end
  end

  for _, v in pairs(sql_creators) do
    if raw_items[v.key] ~= nil then
      raw_items[v.key].creators[v.orderIndex + 1] = {
        firstName = v.firstName,
        lastName = v.lastName,
        creatorType = v.creatorType,
      }
    end
  end

  for key, item in pairs(raw_items) do
    local citekey = bbt_citekeys[key]
    if citekey ~= nil then
      item.citekey = citekey
      table.insert(items, item)
    end
  end
  return items
end

return M
