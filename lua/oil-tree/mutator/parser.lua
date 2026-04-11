local cache = require("oil-tree.cache")
local columns = require("oil-tree.columns")
local config = require("oil-tree.config")
local constants = require("oil-tree.constants")
local fs = require("oil-tree.fs")
local util = require("oil-tree.util")
local view = require("oil-tree.view")
local M = {}

local FIELD_ID = constants.FIELD_ID
local FIELD_NAME = constants.FIELD_NAME
local FIELD_TYPE = constants.FIELD_TYPE
local FIELD_META = constants.FIELD_META

---@alias oil.Diff oil.DiffNew|oil.DiffDelete|oil.DiffChange

---@class (exact) oil.DiffNew
---@field type "new"
---@field name string
---@field entry_type oil.EntryType
---@field id nil|integer
---@field link nil|string

---@class (exact) oil.DiffDelete
---@field type "delete"
---@field name string
---@field id integer

---@class (exact) oil.DiffChange
---@field type "change"
---@field entry_type oil.EntryType
---@field name string
---@field column string
---@field value any

---@param name string
---@return string
---@return boolean
local function parsedir(name)
  local isdir = vim.endswith(name, "/") or (fs.is_windows and vim.endswith(name, "\\"))
  if isdir then
    name = name:sub(1, name:len() - 1)
  end
  return name, isdir
end

---@param meta nil|table
---@param parsed_entry table
---@return boolean True if metadata and parsed entry have the same link target
local function compare_link_target(meta, parsed_entry)
  if not meta or not meta.link then
    return false
  end
  -- Make sure we trim off any trailing path slashes from both sources
  local meta_name = meta.link:gsub("[/\\]$", "")
  local parsed_name = parsed_entry.link_target:gsub("[/\\]$", "")
  return meta_name == parsed_name
end

---@class (exact) oil.ParseResult
---@field data table Parsed entry data
---@field ranges table<string, integer[]> Locations of the various columns
---@field entry nil|oil.InternalEntry If the entry already exists

---Parse a single line in a buffer
---@param adapter oil.Adapter
---@param line string
---@param column_defs oil.ColumnSpec[]
---@return nil|oil.ParseResult
---@return nil|string Error
M.parse_line = function(adapter, line, column_defs)
  local ret = {}
  local ranges = {}
  local start = 1
  local value, rem = line:match("^/(%d+) (.+)$")
  if not value then
    return nil, "Malformed ID at start of line"
  end
  ranges.id = { start, value:len() + 1 }
  start = ranges.id[2] + 1
  ret.id = tonumber(value)

  -- Right after a mutation and we reset the cache, the parent url may not be available
  local ok, parent_url = pcall(cache.get_parent_url, ret.id)
  if ok then
    -- If this line was pasted from another adapter, it may have different columns
    local line_adapter = assert(config.get_adapter_by_scheme(parent_url))
    if adapter ~= line_adapter then
      adapter = line_adapter
      column_defs = columns.get_supported_columns(adapter)
    end
  end

  for _, def in ipairs(column_defs) do
    local name = util.split_config(def)
    local range = { start }
    local start_len = string.len(rem)
    value, rem = columns.parse_col(adapter, assert(rem), def)
    if not rem then
      return nil, string.format("Parsing %s failed", name)
    end
    ret[name] = value
    range[2] = range[1] + start_len - string.len(rem) - 1
    ranges[name] = range
    start = range[2] + 1
  end
  local name = rem
  if name then
    local isdir
    name, isdir = parsedir(vim.trim(name))
    if name ~= "" then
      ret.name = name
    end
    ret._type = isdir and "directory" or "file"
  end
  local entry = cache.get_entry_by_id(ret.id)
  ranges.name = { start, start + string.len(rem) - 1 }
  if not entry then
    return { data = ret, ranges = ranges }
  end

  -- Parse the symlink syntax
  local meta = entry[FIELD_META]
  local entry_type = entry[FIELD_TYPE]
  if entry_type == "link" and meta and meta.link then
    local name_pieces = vim.split(ret.name, " -> ", { plain = true })
    if #name_pieces ~= 2 then
      ret.name = ""
      return { data = ret, ranges = ranges }
    end
    ranges.name = { start, start + string.len(name_pieces[1]) - 1 }
    ret.name = parsedir(vim.trim(name_pieces[1]))
    ret.link_target = name_pieces[2]
    ret._type = "link"
  end

  -- Try to keep the same file type
  if entry_type ~= "directory" and entry_type ~= "file" and ret._type ~= "directory" then
    ret._type = entry[FIELD_TYPE]
  end

  return { data = ret, entry = entry, ranges = ranges }
end

---@class (exact) oil.ParseError
---@field lnum integer
---@field col integer
---@field message string

---@param bufnr integer
---@return oil.Diff[] diffs
---@return oil.ParseError[] errors Parsing errors
M.parse = function(bufnr)
  ---@type oil.Diff[]
  local diffs = {}
  ---@type oil.ParseError[]
  local errors = {}
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  local adapter = util.get_adapter(bufnr, true)
  if not adapter then
    table.insert(errors, {
      lnum = 0,
      col = 0,
      message = string.format("Cannot parse buffer '%s': No adapter", bufname),
    })
    return diffs, errors
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, true)
  local scheme, path = util.parse_url(bufname)
  local column_defs = columns.get_supported_columns(adapter)
  local parent_url = scheme .. path
  local children = cache.list_url(parent_url)
  -- map from name to entry ID for all entries previously in the buffer
  ---@type table<string, integer>
  local original_entries = {}
  for _, child in pairs(children) do
    local name = child[FIELD_NAME]
    if view.should_display(name, bufnr) then
      original_entries[name] = child[FIELD_ID]
    end
  end
  local seen_names = {}
  local function check_dupe(name, i)
    if fs.is_mac or fs.is_windows then
      -- mac and windows use case-insensitive filesystems
      name = name:lower()
    end
    if seen_names[name] then
      table.insert(errors, { message = "Duplicate filename", lnum = i - 1, end_lnum = i, col = 0 })
    else
      seen_names[name] = true
    end
  end

  for i, line in ipairs(lines) do
    -- hack to be compatible with Lua 5.1
    -- use return instead of goto
    (function()
      if line:match("^/%d+") then
        -- Parse the line for an existing entry
        local result, err = M.parse_line(adapter, line, column_defs)
        if not result or err then
          table.insert(errors, {
            message = err,
            lnum = i - 1,
            end_lnum = i,
            col = 0,
          })
          return
        elseif result.data.id == 0 then
          -- Ignore entries with ID 0 (typically the "../" entry)
          return
        end
        local parsed_entry = result.data
        local entry = result.entry

        local err_message
        if not parsed_entry.name then
          err_message = "No filename found"
        elseif not entry then
          err_message = "Could not find existing entry (was the ID changed?)"
        elseif parsed_entry.name:match("/") or parsed_entry.name:match(fs.sep) then
          err_message = "Filename cannot contain path separator"
        end
        if err_message then
          table.insert(errors, {
            message = err_message,
            lnum = i - 1,
            end_lnum = i,
            col = 0,
          })
          return
        end
        assert(entry)

        check_dupe(parsed_entry.name, i)
        local meta = entry[FIELD_META]
        if original_entries[parsed_entry.name] == parsed_entry.id then
          if entry[FIELD_TYPE] == "link" and not compare_link_target(meta, parsed_entry) then
            table.insert(diffs, {
              type = "new",
              name = parsed_entry.name,
              entry_type = "link",
              link = parsed_entry.link_target,
            })
          elseif entry[FIELD_TYPE] ~= parsed_entry._type then
            table.insert(diffs, {
              type = "new",
              name = parsed_entry.name,
              entry_type = parsed_entry._type,
            })
          else
            original_entries[parsed_entry.name] = nil
          end
        else
          table.insert(diffs, {
            type = "new",
            name = parsed_entry.name,
            entry_type = parsed_entry._type,
            id = parsed_entry.id,
            link = parsed_entry.link_target,
          })
        end

        for _, col_def in ipairs(column_defs) do
          local col_name = util.split_config(col_def)
          if columns.compare(adapter, col_name, entry, parsed_entry[col_name]) then
            table.insert(diffs, {
              type = "change",
              name = parsed_entry.name,
              entry_type = entry[FIELD_TYPE],
              column = col_name,
              value = parsed_entry[col_name],
            })
          end
        end
      else
        -- Parse a new entry
        local name, isdir = parsedir(vim.trim(line))
        if vim.startswith(name, "/") then
          table.insert(errors, {
            message = "Paths cannot start with '/'",
            lnum = i - 1,
            end_lnum = i,
            col = 0,
          })
          return
        end
        if name ~= "" then
          local link_pieces = vim.split(name, " -> ", { plain = true })
          local entry_type = isdir and "directory" or "file"
          local link
          if #link_pieces == 2 then
            entry_type = "link"
            name, link = unpack(link_pieces)
          end
          check_dupe(name, i)
          table.insert(diffs, {
            type = "new",
            name = name,
            entry_type = entry_type,
            link = link,
          })
        end
      end
    end)()
  end

  for name, child_id in pairs(original_entries) do
    table.insert(diffs, {
      type = "delete",
      name = name,
      id = child_id,
    })
  end

  return diffs, errors
end

---Parse a tree view buffer into diffs grouped by parent URL.
---@param bufnr integer
---@return table<string, oil.Diff[]> diffs_by_url
---@return oil.ParseError[] errors
M.parse_tree = function(bufnr)
  local tree = require("oil-tree.tree")
  ---@type table<string, oil.Diff[]>
  local diffs_by_url = {}
  ---@type oil.ParseError[]
  local errors = {}

  local bufname = vim.api.nvim_buf_get_name(bufnr)
  local adapter = util.get_adapter(bufnr, true)
  if not adapter then
    table.insert(errors, {
      lnum = 0,
      col = 0,
      message = string.format("Cannot parse buffer '%s': No adapter", bufname),
    })
    return diffs_by_url, errors
  end

  local state = tree.get_state(bufnr)
  if not state then
    table.insert(errors, {
      lnum = 0,
      col = 0,
      message = "Buffer is not in tree view mode",
    })
    return diffs_by_url, errors
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, true)
  local column_defs = columns.get_supported_columns(adapter)
  local indent_width = config.tree.indent

  -- Depth stack for reconstructing the tree from indentation.
  -- Each entry is {url=parent_url, depth=depth_level}
  local depth_stack = { { url = state.root_url, depth = -1 } }

  -- Per-directory tracking: original entries and seen names
  ---@type table<string, table<string, integer>>
  local original_entries_by_url = {}
  ---@type table<string, table<string, boolean>>
  local seen_names_by_url = {}

  -- Pre-populate original entries for all expanded directories
  for url in pairs(state.expanded) do
    local children = cache.list_url(url)
    local orig = {}
    for _, child in pairs(children) do
      local name = child[FIELD_NAME]
      if view.should_display(name, bufnr) then
        orig[name] = child[FIELD_ID]
      end
    end
    original_entries_by_url[url] = orig
    seen_names_by_url[url] = {}
  end

  local function get_diffs(url)
    if not diffs_by_url[url] then
      diffs_by_url[url] = {}
    end
    return diffs_by_url[url]
  end

  local function check_dupe(url, name, i)
    local seen = seen_names_by_url[url]
    if not seen then
      seen = {}
      seen_names_by_url[url] = seen
    end
    local check_name = name
    if fs.is_mac or fs.is_windows then
      check_name = name:lower()
    end
    if seen[check_name] then
      table.insert(errors, { message = "Duplicate filename", lnum = i - 1, end_lnum = i, col = 0 })
    else
      seen[check_name] = true
    end
  end

  for i, line in ipairs(lines) do
    -- hack to be compatible with Lua 5.1
    -- use return instead of goto
    (function()
      if line:match("^/%d+") then
        -- Parse an existing entry line
        local result, err = M.parse_line(adapter, line, column_defs)
        if not result or err then
          table.insert(errors, {
            message = err,
            lnum = i - 1,
            end_lnum = i,
            col = 0,
          })
          return
        elseif result.data.id == 0 then
          return
        end
        local parsed_entry = result.data
        local entry = result.entry

        local err_message
        if not parsed_entry.name then
          err_message = "No filename found"
        elseif not entry then
          err_message = "Could not find existing entry (was the ID changed?)"
        end
        if err_message then
          table.insert(errors, {
            message = err_message,
            lnum = i - 1,
            end_lnum = i,
            col = 0,
          })
          return
        end
        assert(entry)

        -- Extract depth from leading whitespace after the ID prefix
        -- (indentation is on the icon column, not the name column)
        local after_id = line:match("^/%d+%s(.*)$")
        local lead_ws = after_id and after_id:match("^(%s*)") or ""
        local depth = math.floor(#lead_ws / indent_width)
        local trimmed_name = parsed_entry.name

        -- Check for path separators in the trimmed name
        if trimmed_name:match("/") or trimmed_name:match(fs.sep) then
          table.insert(errors, {
            message = "Filename cannot contain path separator",
            lnum = i - 1,
            end_lnum = i,
            col = 0,
          })
          return
        end

        -- Determine parent URL from depth stack
        while #depth_stack > 1 and depth_stack[#depth_stack].depth >= depth do
          table.remove(depth_stack)
        end
        local parent_url = depth_stack[#depth_stack].url

        -- If this is an expanded directory, push onto depth stack
        local is_dir = parsed_entry._type == "directory"
        if is_dir then
          local child_url = util.addslash(parent_url .. trimmed_name .. "/")
          if state.expanded[child_url] then
            table.insert(depth_stack, { url = child_url, depth = depth })
          end
        end

        check_dupe(parent_url, trimmed_name, i)

        -- Determine the original parent URL for this entry
        local ok, orig_parent_url = pcall(cache.get_parent_url, parsed_entry.id)
        local original_entries = original_entries_by_url[parent_url] or {}
        local diffs = get_diffs(parent_url)

        if ok and orig_parent_url ~= parent_url then
          -- Cross-directory move: entry moved from orig_parent_url to parent_url
          -- Leave the entry in original_entries so that the end-of-function loop
          -- generates a delete diff. The mutator needs both delete + new (with id)
          -- to recognize this as a move rather than a copy.

          -- Generate a new entry in the target directory
          table.insert(diffs, {
            type = "new",
            name = trimmed_name,
            entry_type = parsed_entry._type,
            id = parsed_entry.id,
            link = parsed_entry.link_target,
          })
        elseif original_entries[trimmed_name] == parsed_entry.id then
          -- Entry unchanged in its directory (or only columns changed)
          if entry[FIELD_TYPE] == "link" and not compare_link_target(entry[FIELD_META], parsed_entry) then
            table.insert(diffs, {
              type = "new",
              name = trimmed_name,
              entry_type = "link",
              link = parsed_entry.link_target,
            })
          elseif entry[FIELD_TYPE] ~= parsed_entry._type then
            table.insert(diffs, {
              type = "new",
              name = trimmed_name,
              entry_type = parsed_entry._type,
            })
          else
            original_entries[trimmed_name] = nil
          end
        else
          -- Same directory but different name or ID mismatch: rename/move/copy
          table.insert(diffs, {
            type = "new",
            name = trimmed_name,
            entry_type = parsed_entry._type,
            id = parsed_entry.id,
            link = parsed_entry.link_target,
          })
        end

        -- Check for column changes
        for _, col_def in ipairs(column_defs) do
          local col_name = util.split_config(col_def)
          if columns.compare(adapter, col_name, entry, parsed_entry[col_name]) then
            table.insert(diffs, {
              type = "change",
              name = trimmed_name,
              entry_type = entry[FIELD_TYPE],
              column = col_name,
              value = parsed_entry[col_name],
            })
          end
        end
      else
        -- Parse a new entry line
        local raw_name = vim.trim(line)
        if raw_name == "" then
          return
        end

        -- Extract indentation
        local indent_str = line:match("^(%s*)")
        local depth = math.floor(#indent_str / indent_width)

        -- Determine parent URL from depth stack
        while #depth_stack > 1 and depth_stack[#depth_stack].depth >= depth do
          table.remove(depth_stack)
        end
        local parent_url = depth_stack[#depth_stack].url

        local name, isdir = parsedir(raw_name)
        if vim.startswith(name, "/") then
          table.insert(errors, {
            message = "Paths cannot start with '/'",
            lnum = i - 1,
            end_lnum = i,
            col = 0,
          })
          return
        end
        if name ~= "" then
          local link_pieces = vim.split(name, " -> ", { plain = true })
          local entry_type = isdir and "directory" or "file"
          local link
          if #link_pieces == 2 then
            entry_type = "link"
            name, link = unpack(link_pieces)
          end
          check_dupe(parent_url, name, i)
          local diffs = get_diffs(parent_url)
          table.insert(diffs, {
            type = "new",
            name = name,
            entry_type = entry_type,
            link = link,
          })
        end
      end
    end)()
  end

  -- Generate delete diffs for entries that were in the original but not in the buffer
  for url, original_entries in pairs(original_entries_by_url) do
    local diffs = get_diffs(url)
    for name, child_id in pairs(original_entries) do
      table.insert(diffs, {
        type = "delete",
        name = name,
        id = child_id,
      })
    end
  end

  return diffs_by_url, errors
end

return M
