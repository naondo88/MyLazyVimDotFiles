return {
  {
    "catppuccin/nvim",
    opts = {
      flavour = "mocha",
      integrations = {
        native_lsp = {
          enabled = true,
          underlines = {
            errors = { "undercurl" },
            warnings = { "undercurl" },
            information = { "undercurl" },
            hints = { "undercurl" },
            ok = { "undercurl" },
          },
        },
      },
    },
  },
  {
    "LazyVim/LazyVim",
    opts = {
      colorscheme = "catppuccin",
    },
  },
}
