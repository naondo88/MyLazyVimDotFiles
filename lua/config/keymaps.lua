-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

-- Select all
vim.keymap.set("n", "<leader>sa", "ggVG", { desc = "Select All" })

--- Build a markdown context snippet from the visual selection.
--- Format: [relpath:startline-endline](relpath)\n```ft\n<text>\n```\n\n
local function build_context_snippet()
  local start_line = vim.fn.line("v")
  local end_line = vim.fn.line(".")
  if start_line > end_line then
    start_line, end_line = end_line, start_line
  end

  local lines = vim.api.nvim_buf_get_lines(0, start_line - 1, end_line, false)
  local text = table.concat(lines, "\n")
  local filepath = vim.fn.expand("%:.")
  local ft = vim.bo.filetype

  return string.format("[%s:%d-%d](%s)\n```%s\n%s\n```\n\n", filepath, start_line, end_line, filepath, ft, text)
end

-- Yank visual selection as markdown context snippet to system clipboard
vim.keymap.set("v", "<leader>yc", function()
  local snippet = build_context_snippet()
  vim.fn.setreg("+", snippet)
  local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
  vim.api.nvim_feedkeys(esc, "nx", false)
  vim.notify("Yanked context to clipboard")
end, { desc = "Yank context snippet" })

-- Append visual selection as markdown context snippet to system clipboard
vim.keymap.set("v", "<leader>yC", function()
  local snippet = build_context_snippet()
  local current = vim.fn.getreg("+")
  vim.fn.setreg("+", current .. snippet)
  local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
  vim.api.nvim_feedkeys(esc, "nx", false)
  vim.notify("Appended context to clipboard")
end, { desc = "Append context snippet" })
