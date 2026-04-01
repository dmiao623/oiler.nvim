local cache = require("oil.cache")
local constants = require("oil.constants")
local util = require("oil.util")
local M = {}

local FIELD_ID = constants.FIELD_ID
local FIELD_NAME = constants.FIELD_NAME
local FIELD_TYPE = constants.FIELD_TYPE
local FIELD_META = constants.FIELD_META

---@class oil.TreeState
---@field root_url string
---@field expanded table<string, boolean>

---@type table<integer, oil.TreeState>
local tree_state = {}

---Check if a buffer is in tree view mode
---@param bufnr integer
---@return boolean
M.is_tree_buffer = function(bufnr)
  if bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  return tree_state[bufnr] ~= nil
end

---Get tree state for a buffer
---@param bufnr integer
---@return oil.TreeState|nil
M.get_state = function(bufnr)
  if bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  return tree_state[bufnr]
end

---Initialize tree state for a buffer. Root is always expanded.
---@param bufnr integer
---@param root_url string
M.init_state = function(bufnr, root_url)
  if bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  root_url = util.addslash(root_url)
  tree_state[bufnr] = {
    root_url = root_url,
    expanded = { [root_url] = true },
  }
end

---Clear tree state for a buffer (switch back to flat view)
---@param bufnr integer
M.clear_state = function(bufnr)
  if bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  tree_state[bufnr] = nil
end

---Check if a directory URL is expanded in the tree
---@param bufnr integer
---@param url string
---@return boolean
M.is_expanded = function(bufnr, url)
  if bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  local state = tree_state[bufnr]
  if not state then
    return false
  end
  return state.expanded[url] == true
end

---Expand a directory in the tree view. Fetches entries via adapter if not cached.
---@param bufnr integer
---@param url string
M.expand = function(bufnr, url)
  if bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  local state = tree_state[bufnr]
  if not state then
    return
  end
  url = util.addslash(url)
  state.expanded[url] = true

  local entries = cache.list_url(url)
  if vim.tbl_isempty(entries) then
    -- Need to fetch from adapter
    local adapter = util.get_adapter(bufnr, true)
    if not adapter then
      return
    end
    local columns = require("oil.columns")
    local config = require("oil.config")
    local cols = {}
    for _, def in ipairs(config.columns) do
      local name = util.split_config(def)
      table.insert(cols, name)
    end
    for _, sort_pair in ipairs(config.view_options.sort) do
      table.insert(cols, sort_pair[1])
    end

    cache.begin_update_url(url)
    adapter.list(url, cols, function(err, fetched, fetch_more)
      if err then
        cache.end_update_url(url)
        vim.schedule(function()
          vim.notify(string.format("[oil] Error listing %s: %s", url, err), vim.log.levels.ERROR)
        end)
        return
      end
      if fetched then
        for _, entry in ipairs(fetched) do
          cache.store_entry(url, entry)
        end
      end
      if fetch_more then
        vim.defer_fn(fetch_more, 4)
      else
        cache.end_update_url(url)
        vim.schedule(function()
          if vim.api.nvim_buf_is_valid(bufnr) then
            local view = require("oil.view")
            view.render_buffer_async(bufnr, { refetch = false })
          end
        end)
      end
    end)
  else
    local view = require("oil.view")
    view.render_buffer_async(bufnr, { refetch = false })
  end
end

---Collapse a directory in the tree view.
---@param bufnr integer
---@param url string
M.collapse = function(bufnr, url)
  if bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  local state = tree_state[bufnr]
  if not state then
    return
  end
  url = util.addslash(url)
  -- Don't allow collapsing the root
  if url == state.root_url then
    return
  end
  state.expanded[url] = nil

  -- Also collapse any children that were expanded under this URL
  for expanded_url in pairs(state.expanded) do
    if vim.startswith(expanded_url, url) and expanded_url ~= url then
      state.expanded[expanded_url] = nil
    end
  end

  local view = require("oil.view")
  view.render_buffer_async(bufnr, { refetch = false })
end

---Toggle expand/collapse for a directory.
---@param bufnr integer
---@param url string
M.toggle_expand = function(bufnr, url)
  if bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  url = util.addslash(url)
  if M.is_expanded(bufnr, url) then
    M.collapse(bufnr, url)
  else
    M.expand(bufnr, url)
  end
end

---Expand all directories recursively up to a depth limit.
---@param bufnr integer
---@param max_depth? integer Defaults to 5
M.expand_all = function(bufnr, max_depth)
  if bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  max_depth = max_depth or 5
  local state = tree_state[bufnr]
  if not state then
    return
  end

  -- Collect all directory URLs that need expanding by walking the cache
  local to_expand = {}
  local function collect_dirs(url, depth)
    if depth > max_depth then
      return
    end
    local entries = cache.list_url(url)
    for _, entry in pairs(entries) do
      if entry[FIELD_TYPE] == "directory" then
        local child_url = util.addslash(url .. entry[FIELD_NAME] .. "/")
        if not state.expanded[child_url] then
          table.insert(to_expand, child_url)
        end
        state.expanded[child_url] = true
        collect_dirs(child_url, depth + 1)
      elseif entry[FIELD_TYPE] == "link" then
        local meta = entry[FIELD_META]
        if meta and meta.link_stat and meta.link_stat.type == "directory" then
          local child_url = util.addslash(url .. entry[FIELD_NAME] .. "/")
          if not state.expanded[child_url] then
            table.insert(to_expand, child_url)
          end
          state.expanded[child_url] = true
          collect_dirs(child_url, depth + 1)
        end
      end
    end
  end
  collect_dirs(state.root_url, 1)

  -- For any newly expanded dirs not in cache, fetch them
  local adapter = util.get_adapter(bufnr, true)
  if not adapter then
    return
  end
  local config = require("oil.config")
  local cols = {}
  for _, def in ipairs(config.columns) do
    local name = util.split_config(def)
    table.insert(cols, name)
  end
  for _, sort_pair in ipairs(config.view_options.sort) do
    table.insert(cols, sort_pair[1])
  end

  local pending = 0
  local function check_done()
    if pending == 0 then
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(bufnr) then
          -- Recurse to expand newly-fetched directories at deeper levels
          M.expand_all(bufnr, max_depth)
        end
      end)
    end
  end

  for _, url in ipairs(to_expand) do
    local entries = cache.list_url(url)
    if vim.tbl_isempty(entries) then
      pending = pending + 1
      cache.begin_update_url(url)
      adapter.list(url, cols, function(err, fetched, fetch_more)
        if err then
          cache.end_update_url(url)
          pending = pending - 1
          check_done()
          return
        end
        if fetched then
          for _, entry in ipairs(fetched) do
            cache.store_entry(url, entry)
          end
        end
        if fetch_more then
          vim.defer_fn(fetch_more, 4)
        else
          cache.end_update_url(url)
          pending = pending - 1
          check_done()
        end
      end)
    end
  end

  if pending == 0 then
    local view = require("oil.view")
    view.render_buffer_async(bufnr, { refetch = false })
  end
end

---Collapse all directories except the root.
---@param bufnr integer
M.collapse_all = function(bufnr)
  if bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  local state = tree_state[bufnr]
  if not state then
    return
  end
  state.expanded = { [state.root_url] = true }
  local view = require("oil.view")
  view.render_buffer_async(bufnr, { refetch = false })
end

---Walk all entries in the tree in display order.
---Returns a list of {entry, depth, parent_url} tuples.
---@param bufnr integer
---@return {entry: oil.InternalEntry, depth: integer, parent_url: string}[]
M.walk_entries = function(bufnr)
  if bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  local state = tree_state[bufnr]
  if not state then
    return {}
  end

  local view = require("oil.view")
  local columns_mod = require("oil.columns")
  local adapter = util.get_adapter(bufnr, true)
  if not adapter then
    return {}
  end

  local sort_fn = nil
  -- We need to get the sort function - replicate the logic from view
  local config = require("oil.config")
  local sort_config = config.view_options.sort
  if vim.tbl_isempty(sort_config) then
    sort_config = { { "type", "asc" }, { "name", "asc" } }
  end

  local result = {}

  local function walk(url, depth)
    local entries = cache.list_url(url)
    local entry_list = vim.tbl_values(entries)

    -- Sort entries using the same sort logic as flat view
    if not sort_fn then
      local idx_funs = {}
      for _, sort_pair in ipairs(sort_config) do
        local col_name, order = unpack(sort_pair)
        local col = columns_mod.get_column(adapter, col_name)
        if col and col.create_sort_value_factory then
          table.insert(idx_funs, { col.create_sort_value_factory(#entry_list), order })
        elseif col and col.get_sort_value then
          table.insert(idx_funs, { col.get_sort_value, order })
        end
      end
      sort_fn = function(a, b)
        for _, sf in ipairs(idx_funs) do
          local get_sort_value, order = sf[1], sf[2]
          local a_val = get_sort_value(a)
          local b_val = get_sort_value(b)
          if a_val ~= b_val then
            if order == "desc" then
              return a_val > b_val
            else
              return a_val < b_val
            end
          end
        end
        return a[FIELD_NAME] < b[FIELD_NAME]
      end
    end

    table.sort(entry_list, sort_fn)

    for _, entry in ipairs(entry_list) do
      local name = entry[FIELD_NAME]
      local should_display = view.should_display(name, bufnr)
      if should_display then
        table.insert(result, { entry = entry, depth = depth, parent_url = url })
        -- Check if this is an expanded directory
        local is_dir = entry[FIELD_TYPE] == "directory"
        if not is_dir and entry[FIELD_TYPE] == "link" then
          local meta = entry[FIELD_META]
          is_dir = meta and meta.link_stat and meta.link_stat.type == "directory"
        end
        if is_dir then
          local child_url = util.addslash(url .. name .. "/")
          if state.expanded[child_url] then
            walk(child_url, depth + 1)
          end
        end
      end
    end
  end

  walk(state.root_url, 0)
  return result
end

---Set the root URL for a tree buffer (zoom into a directory).
---@param bufnr integer
---@param new_root_url string
M.set_root = function(bufnr, new_root_url)
  if bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  local state = tree_state[bufnr]
  if not state then
    return
  end
  new_root_url = util.addslash(new_root_url)
  -- Keep expanded entries that are under the new root
  local new_expanded = { [new_root_url] = true }
  for url in pairs(state.expanded) do
    if vim.startswith(url, new_root_url) then
      new_expanded[url] = true
    end
  end
  state.root_url = new_root_url
  state.expanded = new_expanded
end

---Get all expanded URLs for a tree buffer
---@param bufnr integer
---@return string[]
M.get_expanded_urls = function(bufnr)
  if bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  local state = tree_state[bufnr]
  if not state then
    return {}
  end
  return vim.tbl_keys(state.expanded)
end

return M
