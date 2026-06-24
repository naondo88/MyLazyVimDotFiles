-- Autocmds are automatically loaded on the VeryLazy event
-- Default autocmds that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/autocmds.lua
--
-- Add any additional autocmds here
-- with `vim.api.nvim_create_autocmd`
--
-- Or remove existing autocmds by their group name (which is prefixed with `lazyvim_` for the defaults)
-- e.g. vim.api.nvim_del_augroup_by_name("lazyvim_wrap_spell")

vim.api.nvim_create_autocmd({ "FileType" }, {
  pattern = { "markdown" },
  callback = function()
    vim.wo.conceallevel = 0
  end,
})

vim.api.nvim_create_autocmd("BufWritePre", {
  group = vim.api.nvim_create_augroup("StripCarriageReturns", { clear = true }),
  pattern = { "*" },
  callback = function()
    local curpos = vim.api.nvim_win_get_cursor(0)

    vim.cmd([[keeppatterns %s/\r//e]])

    vim.api.nvim_win_set_cursor(0, curpos)
  end,
  desc = "Strip carriage returns on save",
})

-- Louder native-diff colors (global). Many themes — catppuccin included — paint
-- DiffChange / DiffText so faintly that a one-word edit is nearly invisible
-- against the background. These overrides make added/deleted lines clearly
-- green/red and the *changed word* (DiffText) pop with a vivid amber block.
-- Applied on every ColorScheme so it survives theme switches, and once now.
local function override_diff_colors()
  -- whole added line (exists on the new side)
  vim.api.nvim_set_hl(0, "DiffAdd", { bg = "#284b2e", fg = "NONE" })
  -- whole changed line — kept subtle on purpose; DiffText carries the emphasis
  vim.api.nvim_set_hl(0, "DiffChange", { bg = "#33384a", fg = "NONE" })
  -- deleted line / filler (a tinted fg keeps the removed text readable on red)
  vim.api.nvim_set_hl(0, "DiffDelete", { bg = "#4b2730", fg = "#a36a74" })
  -- the exact changed characters within a changed line — vivid amber, bold
  vim.api.nvim_set_hl(0, "DiffText", { bg = "#e0a83a", fg = "#1e1e2e", bold = true })
end

vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("EditReviewDiffColors", { clear = true }),
  pattern = "*",
  callback = override_diff_colors,
  desc = "Brighten native diff highlights (DiffAdd/Change/Delete/Text)",
})
override_diff_colors() -- apply to the already-loaded colorscheme

-- Force colored UNDERCURLS (not plain underlines) for LSP diagnostics.
-- catppuccin compiles its highlights to a cache, and a recompile that happens
-- during plugin setup() bakes `underline` instead of the configured `undercurl`
-- (a compile-timing bug — a post-init recompile gets it right, so the result
-- flip-flops across restarts). Rather than depend on that cache, re-assert
-- undercurl on every ColorScheme, preserving whatever underline color (`sp`)
-- the theme chose. Pairs with the tmux Setulc fix that lets SGR 58 reach the
-- terminal so the curl actually renders red inside tmux.
local function diagnostic_undercurls()
  for _, sev in ipairs({ "Error", "Warn", "Info", "Hint", "Ok" }) do
    local name = "DiagnosticUnderline" .. sev
    local hl = vim.api.nvim_get_hl(0, { name = name })
    hl.underline = nil
    hl.undercurl = true
    if type(hl.cterm) == "table" then
      hl.cterm.underline = nil
      hl.cterm.undercurl = true
    else
      hl.cterm = { undercurl = true }
    end
    vim.api.nvim_set_hl(0, name, hl)
  end
end

vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("DiagnosticUndercurls", { clear = true }),
  pattern = "*",
  callback = diagnostic_undercurls,
  desc = "Force undercurl (not underline) for DiagnosticUnderline* groups",
})
diagnostic_undercurls() -- apply to the already-loaded colorscheme
