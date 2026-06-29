-- Voice dictation (lua/whisper_dictation.lua) — local phrase-on-pause speech to
-- text. This file only registers the which-key group label and a lualine "● REC"
-- indicator; the engine logic lives in the module and the <leader>v* keymaps +
-- :Whisper* commands are defined in lua/config/keymaps.lua (lazy-require).

return {
  -- which-key group label for the <leader>v ("voice") prefix.
  {
    "folke/which-key.nvim",
    opts = {
      spec = {
        { "<leader>v", group = "voice", icon = "" },
      },
    },
  },

  -- Recording indicator in the statusline (red while a session is active).
  {
    "nvim-lualine/lualine.nvim",
    opts = function(_, opts)
      table.insert(opts.sections.lualine_x, 1, {
        function()
          return require("whisper_dictation").status()
        end,
        cond = function()
          return package.loaded.whisper_dictation ~= nil and require("whisper_dictation").is_active()
        end,
        color = { fg = "#ff5555", gui = "bold" },
      })
    end,
  },
}
