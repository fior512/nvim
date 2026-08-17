return {
  {
    "stevearc/conform.nvim",
    -- event = 'BufWritePre', -- uncomment for format on save
    opts = require "configs.conform",
  },

  {
    "neovim/nvim-lspconfig",
    event = { "BufReadPre", "BufNewFile" },
    config = function()
      require "configs.lspconfig"
    end,
  },

  -- Cross-file function suggestions: merges into NvChad's nvim-cmp spec.
  -- lazy.nvim hands us NvChad's opts table, so we only append the new source.
  -- Requires universal-ctags + a `tags` file in the project root
  -- (generate with `ctags -R .` or <leader>ct).
  {
    "hrsh7th/nvim-cmp",
    dependencies = {
      "quangnguyen30192/cmp-nvim-tags",
    },
    opts = function(_, opts)
      opts.sources = vim.list_extend(opts.sources, {
        { name = "tags" }, -- functions/defs from ALL files in the directory
      })
      return opts
    end,
  },
  {
    'mrcjkb/rustaceanvim',
    version = '^9',
    lazy = false,
    ft = "rust",
    config = function()
      vim.g.rustaceanvim = {
        server = {
          default_settings = {
            ["rust-analyzer"] = {
              check = {
                command = "clippy", -- runs clippy instead of cargo check on save
              },
              inlayHints = {
                bindingModeHints = { enable = true },
                closureReturnTypeHints = { enable = "always" },
                lifetimeElisionHints = { enable = "always" },
                parameterHints = { enable = true },
                typeHints = { enable = true },
              },
            },
          },
        },
      }
    end
  },

  {
    "nvim-treesitter/nvim-treesitter",
    opts = {
      ensure_installed = {
        "vim", "lua", "vimdoc",
        "html", "css",
        "cpp", "c",
        "rust",
        "julia",
        "markdown", "markdown_inline",
        "typescript", "tsx",
        "cuda",
      },
    },
  },
  {
    "stevearc/overseer.nvim",
    cmd = {
      "OverseerRun", "OverseerToggle", "OverseerTaskAction",
      "OverseerInfo", "OverseerBuild", "OverseerRunCmd", "OverseerClearCache",
    },
    config = function()
      require("configs.overseer").setup()
    end,
  },
  {
    "nvim-lualine/lualine.nvim",
    event = "VeryLazy",
    opts = {
      options = {
        theme = "auto", -- reads live from whatever colorscheme is active
      },
    },
  },
  {
    "danymat/neogen",
    event = "VeryLazy",
    config = function()
      require("neogen").setup {
        snippet_engine = "luasnip", -- NvChad ships LuaSnip: tab through [TODO:...] fields
      }
      -- neogen has no built-in keymaps (since v2.x), so we set our own:
      -- <leader>c is only used by NvChad for ch/cheatsheet and cm/git-commits,
      -- so "cg" ("c"omment "g"enerate) is conflict-free.
      vim.keymap.set("n", "<leader>cg", function()
        require("neogen").generate()
      end, { desc = "Neogen annotate" })
    end,
  },

  -- Undo tree with diff preview: what `:undolist` wants to be. Shows the full
  -- undo tree (all branches, not just the linear list) and, while you move
  -- j/k over nodes, a preview of the file at that state with the exact lines
  -- that differ from the current buffer marked +/- (UndotreeDiffAdded/Deleted).
  -- <leader>u toggles the panel; <leader>uh (inlay hints) still works.
  {
    "jiaoshijie/undotree",
    url = "git@github.com:jiaoshijie/undotree.git", -- only ssh clones on this machine
    opts = {
      float_diff = true, -- diff preview in a floating window
      parser = "compact", -- compact tree style
    },
    keys = {
      { "<leader>u", "<cmd>lua require('undotree').toggle()<cr>", desc = "Undo tree with diff preview" },
    },
  },
}
