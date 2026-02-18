local sqlite = require 'sqlite.db'

local M = {}

local function connect(path, optional)
  path = vim.fn.expand(path)
  local ok, db = pcall(sqlite.open, sqlite, 'file:' .. path .. '?immutable=1', { open_mode = 'ro' })
  if ok then
    return db
  else
    if not optional then
      vim.notify_once(('[zotero] could not open database at %s.'):format(path))
    end
    return nil
  end
end

M.connect = function(opts)
  -- Just validate paths and store config; connections are opened fresh in get_items().
  local zotero_path = vim.fn.expand(opts.zotero_db_path)
  if vim.fn.filereadable(zotero_path) == 0 then
    vim.notify_once(('[zotero] could not open database at %s.'):format(zotero_path))
    return false
  end

  M.opts = opts
  M.zotero8_mode = false

  -- Detect Zotero 8 mode: better-bibtex.sqlite is missing but .migrated exists.
  local bbt_path = vim.fn.expand(opts.better_bibtex_db_path)
  if vim.fn.filereadable(bbt_path) == 0 then
    local migrated_path = bbt_path:gsub('%.sqlite$', '.migrated')
    if vim.fn.filereadable(migrated_path) == 1 then
      M.zotero8_mode = true
    end
  end

  return true
end

-- Open fresh read-only connections to both databases for a single get_items() call.
local function open_connections()
  local zotero_db = connect(M.opts.zotero_db_path)
  if zotero_db == nil then return nil, nil end

  local bbt_db = connect(M.opts.better_bibtex_db_path, true)
  if bbt_db == nil then
    local migrated_path = vim.fn.expand(M.opts.better_bibtex_db_path):gsub('%.sqlite$', '.migrated')
    bbt_db = connect(migrated_path, true)
  end

  return zotero_db, bbt_db
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
  local _, bbt = open_connections()
  if not bbt then return nil end

  local table_check = [[SELECT name FROM sqlite_master WHERE type='table' AND name='cache']]
  local ok, table_exists = pcall(bbt.eval, bbt, table_check)
  if not ok or not table_exists or type(table_exists) ~= 'table' or #table_exists == 0 then
    return nil
  end

  local queries = {
    [[SELECT bibTeX FROM cache WHERE itemKey = ? AND exportNotes = 0 ORDER BY dateModified DESC LIMIT 1]],
    [[SELECT bibTeX FROM cache WHERE itemKey = ? ORDER BY dateModified DESC LIMIT 1]],
    [[SELECT bibtex FROM cache WHERE itemKey = ? ORDER BY dateModified DESC LIMIT 1]],
  }

  for _, query in ipairs(queries) do
    local query_ok, results = pcall(bbt.eval, bbt, query, { item_key })
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
  local _, bbt = open_connections()
  if not bbt then return {} end

  local ok, results = pcall(bbt.eval, bbt, [[SELECT name FROM sqlite_master WHERE type='table']])
  if ok and results and type(results) == 'table' then
    local tables = {}
    for _, row in ipairs(results) do
      if row and row.name then table.insert(tables, row.name) end
    end
    return tables
  end
  return {}
end

-- Get BBT preferences
M.get_bbt_preferences = function()
  local _, bbt = open_connections()
  if not bbt then return {} end

  local query = [[
    SELECT name, value FROM 'better-bibtex'
    WHERE name IN ('citeKeyFormat', 'exportTitleCase', 'exportBraceProtection')
  ]]

  local prefs = {}
  local ok, results = pcall(bbt.eval, bbt, query)
  if ok and results and type(results) == 'table' then
    for _, row in ipairs(results) do
      if row and row.name and row.value then
        prefs[row.name] = row.value
      end
    end
  end
  return prefs
end

local BBT_API_URL = 'http://localhost:23119/better-bibtex/json-rpc'
local BBT_BATCH_SIZE = 500

-- Fetch citation keys from the BBT HTTP API (Zotero 8+).
-- BBT 8 generates new-format keys lazily; this returns only items BBT has processed.
-- Returns a table mapping itemKey -> citationKey.
local function get_citekeys_from_api(db)
  local query_item_keys = [[
    SELECT items.key, items.libraryID
    FROM items
    JOIN itemTypes ON items.itemTypeID = itemTypes.itemTypeID
    WHERE itemTypes.typeName NOT IN ('attachment', 'note', 'annotation')
  ]]
  local ok, rows = pcall(db.eval, db, query_item_keys)
  if not ok or not rows or type(rows) ~= 'table' then return {} end

  local all_keys = {}
  for _, row in ipairs(rows) do
    table.insert(all_keys, tostring(row.libraryID) .. ':' .. row.key)
  end

  local citekeys = {}
  for i = 1, #all_keys, BBT_BATCH_SIZE do
    local batch = {}
    for j = i, math.min(i + BBT_BATCH_SIZE - 1, #all_keys) do
      table.insert(batch, all_keys[j])
    end

    local payload = vim.json.encode {
      jsonrpc = '2.0',
      method = 'item.citationkey',
      params = { batch },
      id = 1,
    }
    local cmd = 'curl -s --max-time 5 '
      .. BBT_API_URL
      .. ' -X POST -H "Content-Type: application/json" -d '
      .. vim.fn.shellescape(payload)

    local result = vim.fn.system(cmd)
    if vim.v.shell_error ~= 0 then break end

    local decode_ok, data = pcall(vim.json.decode, result)
    if decode_ok and data and data.result then
      for prefixed_key, citekey in pairs(data.result) do
        if type(citekey) == 'string' then
          local item_key = prefixed_key:match(':(.+)$') or prefixed_key
          citekeys[item_key] = citekey
        end
      end
    end
  end

  return citekeys
end

-- Query to get citation keys from the extra field in zotero.sqlite.
-- BBT stores the current-format key as "Citation Key: <key>" in the extra field.
-- These override any keys from the BBT SQLite database.
local query_citekeys_from_extra = [[
  SELECT
    items.key AS itemKey,
    TRIM(SUBSTR(
      idv.value,
      INSTR(idv.value, 'Citation Key:') + LENGTH('Citation Key:'),
      CASE
        WHEN INSTR(SUBSTR(idv.value, INSTR(idv.value, 'Citation Key:') + LENGTH('Citation Key:')), CHAR(10)) = 0
        THEN LENGTH(idv.value)
        ELSE INSTR(SUBSTR(idv.value, INSTR(idv.value, 'Citation Key:') + LENGTH('Citation Key:')), CHAR(10)) - 1
      END
    )) AS citationKey
  FROM items
  JOIN itemData id ON items.itemID = id.itemID
  JOIN itemDataValues idv ON id.valueID = idv.valueID
  JOIN fields f ON id.fieldID = f.fieldID
  WHERE f.fieldName = 'extra' AND idv.value LIKE '%Citation Key:%'
]]

function M.get_items()
  local items = {}
  local raw_items = {}

  -- Open fresh connections on every call to avoid stale handles while Zotero writes.
  local db, bbt = open_connections()
  if db == nil then
    vim.notify_once('[zotero] could not open zotero.sqlite.', vim.log.levels.WARN, {})
    return {}
  end

  local sql_items = db:eval(query_items)
  local sql_creators = db:eval(query_creators)

  if sql_items == nil or sql_creators == nil then
    vim.notify_once('[zotero] could not query database.', vim.log.levels.WARN, {})
    return {}
  end

  local bbt_citekeys = {}

  -- Base layer: keys from better-bibtex.sqlite or better-bibtex.migrated
  if bbt then
    local sql_bbt = bbt:eval(query_bbt)
    if sql_bbt then
      for _, v in pairs(sql_bbt) do
        bbt_citekeys[v.itemKey] = v.citationKey
      end
    end
  end

  -- Override layer 1: BBT HTTP API keys (Zotero 8 mode).
  -- BBT 8 generates new-format keys lazily as items are touched in Zotero.
  -- These override migrated keys for items BBT has already processed.
  if M.zotero8_mode then
    local api_keys = get_citekeys_from_api(db)
    if api_keys then
      for item_key, citekey in pairs(api_keys) do
        bbt_citekeys[item_key] = citekey
      end
    end
  end

  -- Override layer 2: keys in the extra field (manually pinned, always current format).
  local sql_extra = db:eval(query_citekeys_from_extra)
  if sql_extra then
    for _, v in pairs(sql_extra) do
      if type(v.citationKey) == 'string' and v.citationKey ~= '' then
        bbt_citekeys[v.itemKey] = v.citationKey
      end
    end
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
