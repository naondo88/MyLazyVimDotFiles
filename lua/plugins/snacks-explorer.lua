return {
  {
    "folke/snacks.nvim",
    opts = function(_, opts)
      opts.picker = opts.picker or {}
      opts.picker.sources = opts.picker.sources or {}
      opts.picker.sources.explorer = opts.picker.sources.explorer or {}

      local explorer = opts.picker.sources.explorer
      explorer.actions = explorer.actions or {}
      explorer.actions.diff_selected_with_current = function(picker)
        require("edit_review").diff_snacks_explorer_selection(picker)
      end

      explorer.win = explorer.win or {}
      explorer.win.list = explorer.win.list or {}
      explorer.win.list.keys = explorer.win.list.keys or {}
      explorer.win.list.keys["<leader>fD"] = "diff_selected_with_current"
    end,
  },
}
