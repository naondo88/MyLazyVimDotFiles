local M = {}

local states = {}
local caches = {}

local supported_filetypes = {
  c = "c",
  cpp = "cpp",
  python = "python",
  rust = "rust",
}

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

local function start_row(node)
  return select(1, node:range())
end

local function first_child_of_type(node, types)
  for child in node:iter_children() do
    if child:named() and types[child:type()] then
      return child
    end
  end
end

local function has_descendant(node, types)
  for child in node:iter_children() do
    if child:named() then
      if types[child:type()] or has_descendant(child, types) then
        return true
      end
    end
  end
  return false
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

local function meaningful_doc_text(line)
  local text = line
    :gsub("^%s*//[/!]%s?", "")
    :gsub("^%s*/%*+!?%s?", "")
    :gsub("^%s*%*%s?", "")
    :gsub("%s*%*/%s*$", "")
  return text:match("%S") ~= nil
end

local function is_line_doc(line)
  return line:match("^%s*//[/!]") ~= nil
end

local function mark_leading_doc_comment(bufnr, node, keep)
  local row = start_row(node)
  if row == 0 then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, row, false)
  local previous = lines[row]
  if is_line_doc(previous) then
    local first = row
    while first > 1 and is_line_doc(lines[first - 1]) do
      first = first - 1
    end
    for line = first, row do
      if meaningful_doc_text(lines[line]) then
        keep[line] = true
        return
      end
    end
    return
  end

  if not previous:match("%*/%s*$") then
    return
  end

  local first = row
  while first >= 1 and not lines[first]:match("^%s*/%*[%*!]") do
    first = first - 1
  end
  if first < 1 then
    return
  end

  for line = first, row do
    if meaningful_doc_text(lines[line]) then
      keep[line] = true
      return
    end
  end
end

local attribute_types = {
  attribute_declaration = true,
  attribute_item = true,
  attribute_specifier = true,
  inner_attribute_item = true,
}

local function mark_attributes(bufnr, node, keep)
  if attribute_types[node:type()] then
    keep[start_row(node) + 1] = true
    mark_leading_doc_comment(bufnr, node, keep)
  end
  for child in node:iter_children() do
    if child:named() then
      mark_attributes(bufnr, child, keep)
    end
  end
end

local function mark_module_doc(bufnr, keep)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for line, text in ipairs(lines) do
    if is_line_doc(text) then
      if meaningful_doc_text(text) then
        keep[line] = true
        return
      end
    elseif text:match("^%s*$") then
      -- Module documentation may be followed by a blank line.
    elseif text:match("^%s*/%*[%*!]") then
      for block_line = line, #lines do
        if meaningful_doc_text(lines[block_line]) then
          keep[block_line] = true
          return
        end
        if lines[block_line]:match("%*/") then
          return
        end
      end
      return
    else
      return
    end
  end
end

local function node_is_doc_comment(bufnr, node)
  if node:type() ~= "comment" and node:type() ~= "line_comment" and node:type() ~= "block_comment" then
    return false
  end
  local row = start_row(node)
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  return is_line_doc(line) or line:match("^%s*/%*[%*!]") ~= nil
end

local function mark_scope_spacing(bufnr, children, index, keep, limit)
  local anchor = children[index]
  local previous = index - 1
  while previous >= 1 do
    local node = children[previous]
    local _, _, previous_end = node:range()
    local gap = vim.api.nvim_buf_get_lines(bufnr, previous_end, start_row(anchor), false)
    local adjacent = true
    for _, line in ipairs(gap) do
      if not line:match("%S") then
        adjacent = false
        break
      end
    end
    if adjacent and (attribute_types[node:type()] or node_is_doc_comment(bufnr, node)) then
      anchor = node
      previous = previous - 1
    else
      break
    end
  end
  mark_preceding_blank_lines(bufnr, anchor, keep, limit)
end

local rust_definition_types = {
  enum_item = true,
  foreign_mod_item = true,
  function_item = true,
  impl_item = true,
  mod_item = true,
  struct_item = true,
  trait_item = true,
  union_item = true,
}

local rust_body_types = {
  block = true,
  declaration_list = true,
  enum_variant_list = true,
  field_declaration_list = true,
  ordered_field_declaration_list = true,
}

local rust_top_line_types = {
  const_item = true,
  extern_crate_declaration = true,
  static_item = true,
  type_item = true,
  use_declaration = true,
}

local rust_member_line_types = {
  associated_type = true,
  const_item = true,
  enum_variant = true,
  field_declaration = true,
  static_item = true,
  type_item = true,
}

local rust_signature_types = {
  function_signature_item = true,
}

local function rust_body(node)
  return node:field("body")[1] or first_child_of_type(node, rust_body_types)
end

local function mark_braced_header(node, body, keep)
  local first = start_row(node)
  if body then
    mark_rows(keep, first, start_row(body))
  else
    keep[first + 1] = true
  end
end

local function walk_rust(bufnr, node, keep)
  local node_type = node:type()
  if rust_definition_types[node_type] then
    mark_braced_header(node, rust_body(node), keep)
    mark_leading_doc_comment(bufnr, node, keep)
  elseif rust_signature_types[node_type] then
    local first, _, last = node:range()
    mark_rows(keep, first, last)
    mark_leading_doc_comment(bufnr, node, keep)
  end

  for child in node:iter_children() do
    if child:named() then
      walk_rust(bufnr, child, keep)
    end
  end
end

local function mark_rust_structure(bufnr, root, keep)
  local function scope(container, line_types, spacing)
    local children = named_children(container)
    for index, child in ipairs(children) do
      local node_type = child:type()
      if line_types[node_type] or rust_definition_types[node_type] or rust_signature_types[node_type] then
        mark_scope_spacing(bufnr, children, index, keep, spacing)
        if line_types[node_type] then
          keep[start_row(child) + 1] = true
          mark_leading_doc_comment(bufnr, child, keep)
        end
      end
    end

    if container:type() == "ordered_field_declaration_list" then
      local previous_row
      for index, child in ipairs(children) do
        local row = start_row(child)
        if not node_is_doc_comment(bufnr, child) and row ~= previous_row then
          mark_scope_spacing(bufnr, children, index, keep, spacing)
          keep[row + 1] = true
          mark_leading_doc_comment(bufnr, child, keep)
          previous_row = row
        end
      end
    end
  end

  scope(root, rust_top_line_types, 2)

  local function nested_scopes(node)
    if node:type() == "mod_item" then
      local body = rust_body(node)
      if body then
        scope(body, rust_top_line_types, 2)
      end
    elseif rust_definition_types[node:type()] then
      local body = rust_body(node)
      if body then
        scope(body, rust_member_line_types, 1)
      end
    end
    for child in node:iter_children() do
      if child:named() then
        nested_scopes(child)
      end
    end
  end

  nested_scopes(root)
  walk_rust(bufnr, root, keep)
  mark_attributes(bufnr, root, keep)
  mark_module_doc(bufnr, keep)
end

local cpp_definition_types = {
  class_specifier = true,
  enum_specifier = true,
  function_definition = true,
  namespace_definition = true,
}

local cpp_body_types = {
  compound_statement = true,
  declaration_list = true,
  enumerator_list = true,
  field_declaration_list = true,
}

local cpp_top_line_types = {
  alias_declaration = true,
  declaration = true,
  import_declaration = true,
  namespace_alias_definition = true,
  preproc_def = true,
  preproc_function_def = true,
  preproc_include = true,
  static_assert_declaration = true,
  type_definition = true,
  using_declaration = true,
}

local cpp_member_line_types = {
  access_specifier = true,
  alias_declaration = true,
  declaration = true,
  enumerator = true,
  field_declaration = true,
  static_assert_declaration = true,
  type_definition = true,
  using_declaration = true,
}

local function cpp_body(node)
  return node:field("body")[1] or first_child_of_type(node, cpp_body_types)
end

local function cpp_signature_start(node)
  for child in node:iter_children() do
    if child:named() and not attribute_types[child:type()] then
      return start_row(child)
    end
  end
  return start_row(node)
end

local function cpp_is_method_declaration(node)
  return (node:type() == "field_declaration" or node:type() == "declaration")
    and has_descendant(node, { function_declarator = true })
end

local function mark_cpp_line_or_signature(node, keep)
  local _, _, last = node:range()
  local first = cpp_signature_start(node)
  if cpp_is_method_declaration(node) then
    mark_rows(keep, first, last)
  else
    keep[first + 1] = true
  end
end

local function walk_cpp(bufnr, node, keep)
  local node_type = node:type()
  if cpp_definition_types[node_type] then
    local body = cpp_body(node)
    local first = cpp_signature_start(node)
    if body then
      mark_rows(keep, first, start_row(body))
    else
      keep[first + 1] = true
    end
    mark_leading_doc_comment(bufnr, node, keep)
  elseif node_type == "template_declaration" then
    local declaration
    for child in node:iter_children() do
      if child:named() and (cpp_definition_types[child:type()] or cpp_top_line_types[child:type()]) then
        declaration = child
        break
      end
    end
    if declaration then
      mark_rows(keep, start_row(node), math.max(start_row(node), start_row(declaration) - 1))
    else
      keep[start_row(node) + 1] = true
    end
    mark_leading_doc_comment(bufnr, node, keep)
  end

  for child in node:iter_children() do
    if child:named() then
      walk_cpp(bufnr, child, keep)
    end
  end
end

local function mark_cpp_structure(bufnr, root, keep)
  local function scope(container, line_types, spacing)
    local children = named_children(container)
    for index, child in ipairs(children) do
      local node_type = child:type()
      if
        line_types[node_type]
        or cpp_definition_types[node_type]
        or node_type == "template_declaration"
      then
        mark_scope_spacing(bufnr, children, index, keep, spacing)
        if line_types[node_type] then
          mark_cpp_line_or_signature(child, keep)
          mark_leading_doc_comment(bufnr, child, keep)
        end
      end
    end
  end

  scope(root, cpp_top_line_types, 2)

  local function nested_scopes(node)
    if node:type() == "class_specifier" or node:type() == "enum_specifier" then
      local body = cpp_body(node)
      if body then
        scope(body, cpp_member_line_types, 1)
      end
    elseif node:type() == "namespace_definition" then
      local body = cpp_body(node)
      if body then
        scope(body, cpp_top_line_types, 2)
      end
    end
    for child in node:iter_children() do
      if child:named() then
        nested_scopes(child)
      end
    end
  end

  nested_scopes(root)
  walk_cpp(bufnr, root, keep)
  mark_attributes(bufnr, root, keep)
  mark_module_doc(bufnr, keep)
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
  local filetype = vim.bo[bufnr].filetype
  local language = supported_filetypes[filetype]
  if not language then
    return nil, ("Smart Overview does not support %s files"):format(filetype ~= "" and filetype or "untyped")
  end

  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, language)
  if not ok or not parser then
    return nil, ("%s Tree-sitter parser is unavailable"):format(language)
  end

  local trees = parser:parse()
  local root = trees[1] and trees[1]:root()
  if not root then
    return nil, ("%s Tree-sitter parser returned no syntax tree"):format(language)
  end

  local keep = {}
  if language == "python" then
    mark_top_level(bufnr, root, keep)
    mark_class_members(bufnr, root, keep)
    walk_definitions(bufnr, root, keep)
  elseif language == "rust" then
    mark_rust_structure(bufnr, root, keep)
  elseif language == "c" or language == "cpp" then
    mark_cpp_structure(bufnr, root, keep)
  end

  local cache = {
    changedtick = vim.api.nvim_buf_get_changedtick(bufnr),
    language = language,
    levels = levels_from_keep(line_count, keep),
  }
  caches[bufnr] = cache
  return cache
end

function M.foldexpr()
  local bufnr = vim.api.nvim_get_current_buf()
  local cache = caches[bufnr]
  local changedtick = vim.api.nvim_buf_get_changedtick(bufnr)
  local language = supported_filetypes[vim.bo[bufnr].filetype]
  if not cache or cache.changedtick ~= changedtick or cache.language ~= language then
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
  if not supported_filetypes[vim.bo[bufnr].filetype] then
    local filetype = vim.bo[bufnr].filetype
    vim.notify(
      ("Smart Overview supports Python, Rust, C, and C++; got %s"):format(
        filetype ~= "" and filetype or "an untyped buffer"
      ),
      vim.log.levels.WARN
    )
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
    desc = "Toggle the smart structural overview",
  })

  local group = vim.api.nvim_create_augroup("SmartOverview", { clear = true })
  vim.keymap.set("n", "zS", M.toggle, { desc = "Toggle smart structural overview" })

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
end

return M
