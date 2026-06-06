-- Options are automatically loaded before lazy.nvim startup
-- Default options that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/options.lua
-- Add any additional options here

-- Diff tuning for the edit-review workflow (see EDIT_VIEWER_SPEC.md).
-- These apply globally to ALL native diffs: gitsigns `:Gitsigns diffthis`,
-- diffview.nvim, and plain `:diffsplit` all share neovim's built-in engine.
--   algorithm:histogram -> cleaner, more human hunk boundaries than default Myers
--   linematch:60        -> re-aligns lines *within* a hunk so intra-line red/green
--                          highlighting is far sharper (neovim's newer feature; the
--                          closest native diff gets to difftastic's token-level clarity).
--                          60 is the max lines-per-hunk it will try to realign.
--   followwrap          -> don't force 'wrap' off when entering diff mode; respect
--                          whatever the window has. Lets Edit Review's both-panes
--                          word-wrap toggle (<leader>uw inside the diff) stick.
-- TRYING THIS OUT: evaluate whether linematch alone makes the diffs feel good
-- before deciding how much we still want difftastic. Tweak/revert freely.
vim.opt.diffopt:append({ "algorithm:histogram", "linematch:60", "followwrap" })
