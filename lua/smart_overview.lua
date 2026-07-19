local M = {}

local states = {}
local caches = {}

local definition_types = {
  function_definition = true,
  class_definition = true,
}

local import_types = {
  import_statement = true,
  import_from_statement = true,
  future_import_statement = true,
}

local function named_children(node)
  local children = {}
  for child in node:iter_children() do
    if child:named() then
      children[#children + 1] = child
    end
  end
  return children
end

local function first_named_child(node)
  for child in node:iter_children() do
    if child:named() then
      return child
    end
  end
end

local function is_assignment_statement(node)
  if node:type() ~= "expression_statement" then
    return false
  end

  local child = first_named_child(node)
  return child and child:type() == "assignment"
end

local function mark_rows(keep, first_row, last_row)
  for row = first_row, last_row do
    keep[row + 1] = true
  end
end

local function mark_preceding_blank_lines(bufnr, node, keep, limit)
  local start_row = select(1, node:range())
  local first_row = math.max(0, start_row - limit)
  local lines = vim.api.nvim_buf_get_lines(bufnr, first_row, start_row, false)

  for offset = #lines, 1, -1 do
    if lines[offset]:match("%S") then
      break
    end
    keep[first_row + offset] = true
  end
end

local function string_content_node(node)
  for child in node:iter_children() do
    if child:named() then
      if child:type() == "string_content" then
        return child
      end
      local content = string_content_node(child)
      if content then
        return content
      end
    end
  end
end

local function mark_docstring(bufnr, container, keep)
  local first_statement
  for _, child in ipairs(named_children(container)) do
    if child:type() ~= "comment" then
      first_statement = child
      break
    end
  end

  if not first_statement or first_statement:type() ~= "expression_statement" then
    return
  end

  local string = first_named_child(first_statement)
  if not string or string:type() ~= "string" then
    return
  end

  local content = string_content_node(string)
  if not content then
    return
  end

  local start_row, start_col, end_row, end_col = content:range()
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row + 1, false)

  for offset, line in ipairs(lines) do
    local row = start_row + offset - 1
    local text = line
    if row == start_row then
      text = text:sub(start_col + 1)
    end
    if row == end_row then
      text = text:sub(1, math.max(0, end_col - (row == start_row and start_col or 0)))
    end
    if text:match("%S") then
      keep[row + 1] = true
      return
    end
  end
end

local function mark_definition(bufnr, node, keep)
  local start_row = select(1, node:range())
  local body = node:field("body")[1]

  if body then
    local body_row = select(1, body:range())
    mark_rows(keep, start_row, math.max(start_row, body_row - 1))
    mark_docstring(bufnr, body, keep)
  else
    keep[start_row + 1] = true
  end
end

local function walk_definitions(bufnr, node, keep)
  local node_type = node:type()
  if definition_types[node_type] then
    mark_definition(bufnr, node, keep)
  elseif node_type == "decorator" then
    local row = select(1, node:range())
    keep[row + 1] = true
  end

  for child in node:iter_children() do
    if child:named() then
      walk_definitions(bufnr, child, keep)
    end
  end
end

local function mark_top_level(bufnr, root, keep)
  mark_docstring(bufnr, root, keep)

  for _, child in ipairs(named_children(root)) do
    local child_type = child:type()
    local structural = import_types[child_type]
      or is_assignment_statement(child)
      or definition_types[child_type]
      or child_type == "decorated_definition"

    if structural then
      mark_preceding_blank_lines(bufnr, child, keep, 2)
    end

    if import_types[child_type] or is_assignment_statement(child) then
      local row = select(1, child:range())
      keep[row + 1] = true
    elseif child_type == "class_definition" then
      local body = child:field("body")[1]
      if body then
        for _, member in ipairs(named_children(body)) do
          if is_assignment_statement(member) then
            local row = select(1, member:range())
            keep[row + 1] = true
          end
        end
      end
    end
  end
end

local function mark_class_members(bufnr, node, keep)
  if node:type() == "class_definition" then
    local body = node:field("body")[1]
    if body then
      for _, member in ipairs(named_children(body)) do
        local member_type = member:type()
        local structural = is_assignment_statement(member)
          or definition_types[member_type]
          or member_type == "decorated_definition"

        if structural then
          mark_preceding_blank_lines(bufnr, member, keep, 1)
        end

        if is_assignment_statement(member) then
          local row = select(1, member:range())
          keep[row + 1] = true
        end
      end
    end
  end

  for child in node:iter_children() do
    if child:named() then
      mark_class_members(bufnr, child, keep)
    end
  end
end

local function levels_from_keep(line_count, keep)
  local levels = {}
  for line = 1, line_count do
    levels[line] = 0
  end

  local line = 1
  while line <= line_count do
    if keep[line] then
      line = line + 1
    else
      local hidden_start = line
      while line <= line_count and not keep[line] do
        line = line + 1
      end
      local hidden_end = line - 1
      local fold_start = hidden_start == 1 and 1 or hidden_start - 1
      if hidden_end > fold_start then
        -- Explicitly start each fold so adjacent "anchor + hidden gap" ranges
        -- remain separate folds instead of merging into one level-one fold.
        levels[fold_start] = ">1"
        for folded_line = fold_start + 1, hidden_end do
          levels[folded_line] = 1
        end
      end
    end
  end

  return levels
end

local function build_cache(bufnr)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "python")
  if not ok or not parser then
    return nil, "Python Treesitter parser is unavailable"
  end

  local trees = parser:parse()
  local root = trees[1] and trees[1]:root()
  if not root then
    return nil, "Python Treesitter parser returned no syntax tree"
  end

  local keep = {}
  mark_top_level(bufnr, root, keep)
  mark_class_members(bufnr, root, keep)
  walk_definitions(bufnr, root, keep)

  local cache = {
    changedtick = vim.api.nvim_buf_get_changedtick(bufnr),
    levels = levels_from_keep(line_count, keep),
  }
  caches[bufnr] = cache
  return cache
end

function M.foldexpr()
  local bufnr = vim.api.nvim_get_current_buf()
  local cache = caches[bufnr]
  local changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
  if not cache or cache.changedtick ~= changedtick then
    cache = build_cache(bufnr)
  end
  return cache and cache.levels[vim.v.lnum] or 0
end

local function restore(winid)
  local state = states[winid]
  if not state then
    return
  end
  states[winid] = nil

  if not vim.api.nvim_win_is_valid(winid) then
    return
  end

  vim.api.nvim_win_call(winid, function()
    vim.wo.foldmethod = state.foldmethod
    vim.wo.foldexpr = state.foldexpr
    vim.wo.foldtext = state.foldtext
    vim.wo.foldlevel = state.foldlevel
    vim.wo.foldenable = state.foldenable
    pcall(vim.cmd, "silent! normal! zX")
    vim.fn.winrestview(state.view)
  end)
end

function M.toggle()
  local winid = vim.api.nvim_get_current_win()
  if states[winid] then
    restore(winid)
    return
  end

  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].filetype ~= "python" then
    vim.notify("Smart Overview currently supports Python buffers only", vim.log.levels.WARN)
    return
  end

  local cache, err = build_cache(bufnr)
  if not cache then
    vim.notify(err, vim.log.levels.WARN)
    return
  end

  states[winid] = {
    bufnr = bufnr,
    foldmethod = vim.wo.foldmethod,
    foldexpr = vim.wo.foldexpr,
    foldtext = vim.wo.foldtext,
    foldlevel = vim.wo.foldlevel,
    foldenable = vim.wo.foldenable,
    view = vim.fn.winsaveview(),
  }

  vim.wo.foldmethod = "expr"
  vim.wo.foldexpr = "v:lua.require('smart_overview').foldexpr()"
  vim.wo.foldtext = ""
  vim.wo.foldenable = true
  vim.wo.foldlevel = 0
  vim.cmd("silent! normal! zX")
end

function M.setup()
  vim.api.nvim_create_user_command("SmartOverview", M.toggle, {
    desc = "Toggle the Python smart structural overview",
  })

  local group = vim.api.nvim_create_augroup("SmartOverview", { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = "python",
    callback = function(event)
      vim.keymap.set("n", "zS", M.toggle, {
        buffer = event.buf,
        desc = "Toggle smart structural overview",
      })
    end,
  })

  vim.api.nvim_create_autocmd("BufWinLeave", {
    group = group,
    callback = function(event)
      local winid = vim.api.nvim_get_current_win()
      local state = states[winid]
      if state and state.bufnr == event.buf then
        restore(winid)
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(event)
      caches[event.buf] = nil
    end,
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(event)
      states[tonumber(event.match)] = nil
    end,
  })

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].filetype == "python" then
      vim.keymap.set("n", "zS", M.toggle, {
        buffer = bufnr,
        desc = "Toggle smart structural overview",
      })
    end
  end
end

return M
