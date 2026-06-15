-- Keymaps are automatically loaded on the VeryLazy event
-- Default keymaps that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/keymaps.lua
-- Add any additional keymaps here

-- Select all
vim.keymap.set("n", "<leader>sa", "ggVG", { desc = "Select All" })

-- Yank the current buffer's absolute path to the system clipboard
vim.keymap.set("n", "<leader>yp", function()
  local path = vim.api.nvim_buf_get_name(0)
  if path == "" then
    vim.notify("Current buffer has no file path", vim.log.levels.WARN)
    return
  end

  vim.fn.setreg("+", path)
  vim.notify("Yanked path: " .. path)
end, { desc = "Yank buffer path" })

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

-- Edit Review (lua/edit_review) — in-nvim AI-edit / code-review workflow.
-- The module is required lazily (only on first keypress). See its README and
-- EDIT_VIEWER_SPEC.md. The <leader>r group label is registered in
-- lua/plugins/edit-review.lua.
local function er(fn)
  return function()
    require("edit_review")[fn]()
  end
end
-- stylua: ignore start
vim.keymap.set("n", "<leader>ro", er("choose_base"),             { desc = "Open review (choose base)" })
vim.keymap.set("n", "<leader>rl", er("pick_commits"),            { desc = "Review: pick two commits" })
vim.keymap.set("n", "<leader>rf", er("pick_files"),              { desc = "Review: changed files (picker)" })
vim.keymap.set("n", "<leader>rn", er("next_unreviewed"),         { desc = "Review: next unreviewed file" })
vim.keymap.set("n", "<leader>rN", er("prev_unreviewed"),         { desc = "Review: prev unreviewed file" })
vim.keymap.set("n", "<leader>rm", er("toggle_current_reviewed"), { desc = "Review: mark current file reviewed" })
vim.keymap.set("n", "<leader>rh", er("toggle_hunk_reviewed"),     { desc = "Review: mark hunk under cursor reviewed" })
vim.keymap.set("n", "<leader>rc", er("comment"),                 { desc = "Review: comment on hunk under cursor" })
vim.keymap.set("n", "<leader>rC", er("finish_comment"),          { desc = "Review: finish comment (return to code)" })
vim.keymap.set("n", "<leader>rg", er("report"),                  { desc = "Review: open report" })
vim.keymap.set("n", "<leader>rd", er("difftastic"),             { desc = "Review: difftastic structural view" })
vim.keymap.set("n", "<leader>rq", er("quit"),                    { desc = "Review: quit (close diff split)" })
-- stylua: ignore end
