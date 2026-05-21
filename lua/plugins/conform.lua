return {
  "stevearc/conform.nvim",
  opts = {
    formatters_by_ft = {
      python = { "ruff_format", "docformatter" },
      rust = { "rustfmt" },
      c = { "clang_format" },
      cpp = { "clang_format" },
      lua = { "stylua" },
    },
    formatters = {
      docformatter = {
        -- Match ruff's default line-length (88) so the two formatters agree.
        prepend_args = { "--wrap-summaries", "88", "--wrap-descriptions", "88" },
      },
    },
  },
}
