local finders = require 'telescope.finders'
local pickers = require 'telescope.pickers'
local previewers = require 'telescope.previewers'
local conf = require('telescope.config').values
local Popup = require 'nui.popup'
local action_state = require 'telescope.actions.state'
local actions = require 'telescope.actions'
local bib = require 'zotero.bib'
local database = require 'zotero.database'

local M = {}

local default_opts = {
  zotero_db_path = '~/Zotero/zotero.sqlite',
  better_bibtex_db_path = '~/Zotero/better-bibtex.sqlite',
  zotero_storage_path = '~/Zotero/storage',
  pdf_opener = nil,
  -- specify options for different filetypes
  -- locate_bib can be a string or a function
  ft = {
    quarto = {
      -- Default formatter (now returns a string rather than using vim.ui.select)
      insert_key_formatter = function(citekey)
        return '@' .. citekey
      end,
      locate_bib = bib.locate_quarto_bib,
    },
    typst = {
      -- Default formatter (now returns a string rather than using vim.ui.select)
      insert_key_formatter = function(citekey)
        return '@' .. citekey
      end,
      locate_bib = bib.locate_typst_bib,
    },
    tex = {
      insert_key_formatter = function(citekey)
        return '\\cite{' .. citekey .. '}'
      end,
      locate_bib = bib.locate_tex_bib,
    },
    plaintex = {
      insert_key_formatter = function(citekey)
        return '\\cite{' .. citekey .. '}'
      end,
      locate_bib = bib.locate_tex_bib,
    },
    -- fallback for unlisted filetypes
    default = {
      insert_key_formatter = function(citekey)
        return '@' .. citekey
      end,
      locate_bib = bib.locate_quarto_bib,
    },
  },
}
M.config = default_opts

M.setup = function(opts)
  M.config = vim.tbl_extend('force', default_opts, opts or {})
end

local function get_attachment_options(item)
  local options = {}
  if item.attachment and item.attachment.path then
    table.insert(options, {
      type = 'pdf',
      path = item.attachment.path,
      link_mode = item.attachment.link_mode,
    })
  end
  if item.DOI then
    table.insert(options, { type = 'doi', url = 'https://doi.org/' .. item.DOI })
  end
  -- Add option to open in Zotero
  table.insert(options, { type = 'zotero', key = item.key })
  return options
end

local function open_url(url, file_type)
  local open_cmd
  if file_type == 'pdf' and M.config.pdf_opener then
    -- Use the custom PDF opener if specified
    vim.notify('Opening PDF with: ' .. M.config.pdf_opener .. ' ' .. vim.fn.shellescape(url), vim.log.levels.INFO)
    vim.fn.jobstart({ M.config.pdf_opener, url }, { detach = true })
  elseif vim.fn.has 'win32' == 1 then
    open_cmd = 'start'
  elseif vim.fn.has 'macunix' == 1 then
    open_cmd = 'open'
  else -- Assume Unix
    open_cmd = 'xdg-open'
  end
  vim.notify('Opening URL with: ' .. open_cmd .. ' ' .. vim.fn.shellescape(url), vim.log.levels.INFO)
  vim.fn.jobstart({ open_cmd, url }, { detach = true })
end

local function open_in_zotero(item_key)
  local zotero_url = 'zotero://select/library/items/' .. item_key
  open_url(zotero_url)
end

local function open_attachment(item)
  local options = get_attachment_options(item)
  local function execute_option(choice)
    if choice.type == 'pdf' then
      local file_path = choice.path
      if choice.link_mode == 1 then -- 1 typically means stored file
        local zotero_storage = vim.fn.expand(M.config.zotero_storage_path)
        -- Remove the ':storage' prefix from the path
        file_path = file_path:gsub('^storage:', '')
        -- Use a wildcard to search for the PDF file in subdirectories
        local search_path = zotero_storage .. '/*/' .. file_path
        local matches = vim.fn.glob(search_path, true, true) -- Returns a list of matching files
        if #matches > 0 then
          file_path = matches[1] -- Use the first match
        else
          vim.notify('File not found: ' .. search_path, vim.log.levels.ERROR)
          return
        end
      end
      -- Debug: Print the full path
      vim.notify('Attempting to open PDF: ' .. file_path, vim.log.levels.INFO)
      if file_path ~= 0 then
        open_url(file_path, 'pdf')
      else
        vim.notify('File not found: ' .. file_path, vim.log.levels.ERROR)
      end
    elseif choice.type == 'doi' then
      vim.ui.open(choice.url)
    elseif choice.type == 'zotero' then
      open_in_zotero(choice.key)
    end
  end

  if #options == 1 then
    -- If there's only one option, execute it immediately
    execute_option(options[1])
  elseif #options > 1 then
    -- If there are multiple options, use ui.select
    vim.ui.select(options, {
      prompt = 'Choose action:',
      format_item = function(option)
        if option.type == 'pdf' then
          return 'Open PDF'
        elseif option.type == 'doi' then
          return 'Open DOI link'
        elseif option.type == 'zotero' then
          return 'Open in Zotero'
        end
      end,
    }, function(choice)
      if choice then
        execute_option(choice)
      end
    end)
  else
    -- If there are no options, notify the user
    vim.notify('No attachments or links available for this item', vim.log.levels.INFO)
  end
end

local get_items = function()
  local success = database.connect(M.config)
  if success then
    return database.get_items()
  else
    return {}
  end
end

local function append_to_bib(entry, locate_bib_fn)
  local citekey = entry.value.citekey
  local bib_path = nil

  if type(locate_bib_fn) == 'string' then
    bib_path = locate_bib_fn
  elseif type(locate_bib_fn) == 'function' then
    bib_path = locate_bib_fn()
  end

  if bib_path == nil then
    vim.notify_once('Could not find a bibliography file', vim.log.levels.WARN)
    return
  end

  bib_path = vim.fn.expand(bib_path)

  -- check if is already in the bib file
  for line in io.lines(bib_path) do
    if string.match(line, '^@') and string.match(line, citekey) then
      return
    end
  end

  local bib_entry = bib.entry_to_bib_entry(entry)

  -- otherwise append the entry to the bib file at bib_path
  local file = io.open(bib_path, 'a')
  if file == nil then
    vim.notify('Could not open ' .. bib_path .. ' for appending', vim.log.levels.ERROR)
    return
  end
  file:write(bib_entry)
  file:close()
  vim.print('wrote ' .. citekey .. ' to ' .. bib_path)
end

-- This function gets the available citation formats for the given filetype
local function get_available_formats(citekey, filetype)
  local formats = {}

  if filetype == 'quarto' or filetype == 'markdown' then
    formats = {
      { label = '@citation', format = '@' .. citekey },
      { label = '[@citation]', format = '[@' .. citekey .. ']' },
    }
  elseif filetype == 'typst' then
    formats = {
      { label = '@citation', format = '@' .. citekey },
      { label = '#cite(<citation>)', format = '#cite(<' .. citekey .. '>)' },
    }
  elseif filetype == 'tex' or filetype == 'plaintex' then
    formats = {
      { label = '\\cite{citation}', format = '\\cite{' .. citekey .. '}' },
    }
  else
    formats = {
      { label = '@citation', format = '@' .. citekey },
    }
  end

  return formats
end

-- Insert citation with the given format
local function insert_citation(format, entry, locate_bib_fn)
  vim.api.nvim_put({ format }, '', false, true)
  append_to_bib(entry, locate_bib_fn)
end

local function extract_year(date)
  local year = date:match '(%d%d%d%d)'
  if year ~= nil then
    return year
  else
    return 'NA'
  end
end

local function make_entry(pre_entry)
  local creators = pre_entry.creators or {}
  local author = creators[1] or {}
  local last_name = author.lastName or 'NA'
  local year = pre_entry.year or pre_entry.date or 'NA'
  year = extract_year(year)
  pre_entry.year = year

  local options = get_attachment_options(pre_entry)
  local icon = ''
  if #options > 2 then
    icon = ' ' -- Icon for both PDF and DOI available
  elseif #options == 2 then
    icon = options[1].type == 'pdf' and '󰈙 ' or '󰖟 '
  else
    icon = ' ' -- Two spaces for blank icon
  end
  local display_value = string.format('%s%s, %s) %s', icon, last_name, year, pre_entry.title)
  local highlight = {
    { { 0, #icon }, 'SpecialChar' },
    { { #icon, #icon + #last_name + #year + 3 }, 'Comment' },
    { { #icon + #last_name + 2, #icon + #year + #last_name + 2 }, '@markup.underline' },
  }

  local function make_display(_)
    return display_value, highlight
  end
  return {
    value = pre_entry,
    display = make_display,
    ordinal = display_value,
    preview_command = function(entry, bufnr)
      -- Get the current filetype options for formatting
      local ft_options = M.config.ft[vim.bo.filetype] or M.config.ft.default
      local citekey = entry.value.citekey

      -- Gather all available citation formats
      local formats = {
        -- Add header line for citation formats section
        'Available Citation Formats:',
        '------------------------',
        '',
        'Press ENTER to select from the following formats:',
      }

      -- Add formats for all supported filetypes
      local ft_names = {
        quarto = 'Quarto',
        typst = 'Typst',
        tex = 'LaTeX/TeX',
        plaintex = 'PlainTeX',
        default = 'Default',
      }

      -- Collect and display formats for each filetype
      for ft_name, ft_config in pairs(M.config.ft) do
        local format_line = ft_names[ft_name] .. ': '

        -- Handle formatter functions that return UI selectors
        if ft_name == 'quarto' then
          format_line = format_line .. '@' .. citekey .. ' or [@' .. citekey .. ']'
        elseif ft_name == 'typst' then
          format_line = format_line .. '@' .. citekey .. ' or #cite(<' .. citekey .. '>)'
        else
          -- For simple formatters, just call the function
          local formatter = ft_config.insert_key_formatter
          if type(formatter) == 'function' then
            local result = formatter(citekey)
            if type(result) == 'string' then
              format_line = format_line .. result
            end
          end
        end

        table.insert(formats, format_line)
      end

      -- Add some spacing before the BibTeX entry
      table.insert(formats, '')
      table.insert(formats, 'BibTeX Entry:')
      table.insert(formats, '-------------')

      -- Add the BibTeX entry
      local bib_entry = bib.entry_to_bib_entry(entry)
      local bib_lines = vim.split(bib_entry, '\n')

      -- Combine formats and BibTeX entry
      local lines = vim.list_extend(formats, bib_lines)

      -- Update the buffer
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

      -- Set custom highlighting for the preview buffer
      vim.api.nvim_set_option_value('filetype', 'markdown', { buf = bufnr })

      -- Apply custom syntax highlighting for the BibTeX part
      local ns_id = vim.api.nvim_create_namespace 'zotero_preview'
      for i, line in ipairs(lines) do
        if i > #formats then
          vim.api.nvim_buf_add_highlight(bufnr, ns_id, 'Comment', i - 1, 0, -1)
        elseif i <= 2 or i == #formats - 2 or i == #formats - 1 then
          vim.api.nvim_buf_add_highlight(bufnr, ns_id, 'Title', i - 1, 0, -1)
        elseif line:match '^%w+:' then
          local colon_pos = line:find ':'
          if colon_pos then
            vim.api.nvim_buf_add_highlight(bufnr, ns_id, 'Identifier', i - 1, 0, colon_pos)
          end
        end
      end
    end,
  }
end

-- Create a custom previewer for the format selection
local FormatSelectionPopup = {}
FormatSelectionPopup.__index = FormatSelectionPopup

function FormatSelectionPopup.new(_, formats, on_select, parent_win)
  local popup_options = {
    relative = 'win',
    win = parent_win,
    position = '50%',
    size = {
      width = 50,
      height = #formats + 6,
    },
    border = {
      style = 'rounded',
      text = {
        top = ' Select Citation Format ',
        top_align = 'center',
      },
    },
    enter = true,
    focusable = true,
    zindex = 50,
  }

  local popup = Popup(popup_options)

  -- Set up the popup content
  popup:mount()

  local bufnr = popup.bufnr
  local lines = {
    'Press the number key to insert the selected format:',
    '',
  }

  -- Add each format option
  for i, format in ipairs(formats) do
    table.insert(lines, string.format('%d. %s → %s', i, format.label, format.format))
  end

  -- Add footer
  table.insert(lines, '')
  table.insert(lines, 'Press <Esc> to cancel')

  -- Set content
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

  -- Add highlighting
  vim.api.nvim_set_option_value('filetype', 'markdown', { buf = bufnr })
  local ns_id = vim.api.nvim_create_namespace 'zotero_format_selection'

  -- Highlight the instructions
  vim.api.nvim_buf_add_highlight(bufnr, ns_id, 'Comment', 0, 0, -1)

  -- Highlight each format option
  for i = 2, 1 + #formats do
    -- Number highlight
    local line_idx = i
    if lines[line_idx + 1] then
      vim.api.nvim_buf_add_highlight(bufnr, ns_id, 'Number', line_idx, 0, 3)
      -- Format highlight
      local format_text = lines[line_idx + 1]
      local arrow_pos = format_text and format_text:find '→'
      if arrow_pos then
        vim.api.nvim_buf_add_highlight(bufnr, ns_id, 'Operator', line_idx, arrow_pos - 1, arrow_pos + 1)
        vim.api.nvim_buf_add_highlight(bufnr, ns_id, 'String', line_idx, arrow_pos + 2, -1)
      end
    end
  end

  -- Highlight footer
  vim.api.nvim_buf_add_highlight(bufnr, ns_id, 'Comment', #lines - 1, 0, -1)

  -- Setup mappings
  for i, format in ipairs(formats) do
    local key = tostring(i)
    vim.keymap.set('n', key, function()
      popup:unmount()
      on_select(format.format)
    end, { buffer = bufnr, noremap = true, silent = true })
  end

  -- Cancel mapping
  vim.keymap.set('n', '<Esc>', function()
    popup:unmount()
  end, { buffer = bufnr, noremap = true, silent = true })

  return popup
end

-- Function to directly insert a citation outside of the picker context
-- This function can be exposed as part of the module API
M.insert_citation_at_cursor = function(citekey, locate_bib_fn)
  local filetype = vim.bo.filetype
  local formats = get_available_formats(citekey, filetype)

  -- Always show format selection for Quarto and Typst, or when multiple formats exist
  if filetype == 'quarto' or filetype == 'typst' or #formats > 1 then
    -- Show selection UI
    vim.ui.select(formats, {
      prompt = 'Choose citation format:',
      format_item = function(item)
        return item.label .. ' → ' .. item.format
      end,
    }, function(selected)
      if selected then
        vim.api.nvim_put({ selected.format }, '', false, true)
        -- Create a dummy entry with just the citekey to append to bib
        local entry = { value = { citekey = citekey } }
        append_to_bib(entry, locate_bib_fn)
      end
    end)
  else
    -- For other filetypes with only one format, use it directly
    vim.api.nvim_put({ formats[1].format }, '', false, true)
    -- Create a dummy entry with just the citekey to append to bib
    local entry = { value = { citekey = citekey } }
    append_to_bib(entry, locate_bib_fn)
  end
end

--- Main entry point of the picker
--- @param opts any
M.picker = function(opts)
  opts = opts or {}
  local ft_options = M.config.ft[vim.bo.filetype] or M.config.ft.default

  pickers
    .new(opts, {
      prompt_title = 'Zotero library',
      finder = finders.new_table {
        results = get_items(),
        entry_maker = make_entry,
      },
      sorter = conf.generic_sorter(opts),
      previewer = previewers.display_content.new(opts),
      attach_mappings = function(prompt_bufnr, map)
        -- Default action: show format selection popup
        actions.select_default:replace(function()
          local entry = action_state.get_selected_entry()
          local citekey = entry.value.citekey
          local filetype = vim.bo.filetype
          local formats = get_available_formats(citekey, filetype)

          -- Always show the format selection for Quarto and Typst
          if filetype == 'quarto' or filetype == 'typst' or #formats > 1 then
            -- Close the picker before showing the format popup
            actions.close(prompt_bufnr)

            -- Create the format selection popup
            local current_win = vim.api.nvim_get_current_win()
            local popup = FormatSelectionPopup.new(nil, formats, function(format)
              insert_citation(format, entry, ft_options.locate_bib)
            end, current_win)
          else
            -- For other filetypes with only one format, use it directly
            actions.close(prompt_bufnr)
            insert_citation(formats[1].format, entry, ft_options.locate_bib)
          end
        end)

        -- Update the mapping to open PDF or DOI
        map('i', '<C-o>', function()
          local entry = action_state.get_selected_entry()
          open_attachment(entry.value)
        end)
        map('n', 'o', function()
          local entry = action_state.get_selected_entry()
          open_attachment(entry.value)
        end)

        -- Add help mapping to show available commands
        map('i', '<C-h>', function()
          vim.api.nvim_echo({
            { 'Available Commands:', 'Title' },
            { ' <CR>: Select citation | <C-o>: Open attachment', 'None' },
          }, false, {})
        end)
        map('n', '?', function()
          vim.api.nvim_echo({
            { 'Available Commands:', 'Title' },
            { ' <CR>: Select citation | o: Open attachment', 'None' },
          }, false, {})
        end)

        return true
      end,
    })
    :find()
end

return M
