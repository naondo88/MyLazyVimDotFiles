-- your-repo/.lazy.lua
local root = vim.uv.cwd() -- works best if you open nvim from the repo root (nvim .)

return {
  {
    "nvim-orgmode/orgmode",
    opts = {
      org_agenda_files = { root .. "/notes/**/*" },
      org_default_notes_file = root .. "/notes/inbox.org",
      org_startup_indented = true,
      org_adapt_indentation = false,
    },
  },
}
