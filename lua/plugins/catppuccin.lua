return {
  {
    "catppuccin/nvim",
    opts = {
      flavour = "mocha",
      -- NOTE: this `native_lsp` block is INERT. This version of catppuccin has
      -- no `native_lsp` integration; diagnostic underline styles come only from
      -- the top-level `lsp_styles.underlines`, which LazyVim already sets to
      -- `undercurl`. Undercurl rendering is actually *enforced* by the
      -- `DiagnosticUndercurls` autocmd in lua/config/autocmds.lua, because
      -- catppuccin's compiled cache can otherwise bake a flat `underline`.
      -- See MODS.md. Kept only as a breadcrumb; safe to delete.
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
