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
