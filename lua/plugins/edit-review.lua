-- Edit Review: in-neovim AI-edit / code-review workflow.
-- Design + decisions live in EDIT_VIEWER_SPEC.md.
--
-- Foundation is diffview.nvim (the side-by-side red/green view + file panel),
-- driving neovim's native diff engine. The custom review-tracking layer
-- (reviewed flags, comments, report) lives in lua/edit_review/.

local function er(fn)
  return function()
    require("edit_review")[fn]()
  end
end

return {
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
    config = function(_, opts)
      require("diffview").setup(opts)
      require("edit_review").setup()
    end,
    keys = {
      { "<leader>r", "", desc = "+review" },
      { "<leader>ro", er("open_review"), desc = "Open review diff (HEAD vs working)" },
      { "<leader>rf", er("pick_files"), desc = "Changed files (picker)" },
      { "<leader>rn", er("next_unreviewed"), desc = "Next unreviewed file" },
      { "<leader>rp", er("prev_unreviewed"), desc = "Prev unreviewed file" },
      { "<leader>rm", er("toggle_current_reviewed"), desc = "Mark current file reviewed" },
      { "<leader>rc", er("comment"), desc = "Comment on hunk under cursor" },
      { "<leader>rC", er("finish_comment"), desc = "Finish comment (return to code)" },
      { "<leader>rg", er("report"), desc = "Open review report" },
      { "<leader>rd", er("difftastic"), desc = "difftastic structural view" },
      { "<leader>rq", er("quit"), desc = "Quit review (close diffview)" },
    },
  },

  -- which-key group label (loads even before diffview is triggered)
  {
    "folke/which-key.nvim",
    opts = {
      spec = {
        { "<leader>r", group = "review", icon = "󰊢" },
      },
    },
  },
}
