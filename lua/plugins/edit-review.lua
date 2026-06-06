-- Edit Review: in-neovim AI-edit / code-review workflow.
-- Design + decisions live in EDIT_VIEWER_SPEC.md; usage in lua/edit_review/.
--
-- The review flow uses neovim's NATIVE side-by-side :diff in your normal tab
-- (no separate UI). All logic lives in lua/edit_review/; the <leader>r* keymaps
-- are defined in lua/config/keymaps.lua (they lazily require the module).
-- This file only registers the which-key group label and keeps diffview.nvim
-- installed as an OPTIONAL standalone tool (handy for heavy branch/PR browsing
-- via :DiffviewOpen) — it is no longer part of the <leader>r flow.

return {
  -- which-key group label for the <leader>r ("review") prefix.
  {
    "folke/which-key.nvim",
    opts = {
      spec = {
        { "<leader>r", group = "review", icon = "󰊢" },
      },
    },
  },

  -- Optional: diffview.nvim, lazy-loaded only on its own commands. Not used by
  -- the <leader>r review flow; kept for ad-hoc `:DiffviewOpen`/file history.
  -- Safe to delete this block if you never use it.
  {
    "sindrets/diffview.nvim",
    cmd = {
      "DiffviewOpen",
      "DiffviewClose",
      "DiffviewFileHistory",
      "DiffviewToggleFiles",
      "DiffviewFocusFiles",
    },
    opts = {
      enhanced_diff_hl = true,
    },
  },
}
