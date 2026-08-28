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
  -- Requires universal-ctags + a `tags` file in the project root
  -- (generate with `ctags -R .` or <leader>ct).
  --
  -- `tags` and `buffer` do plain fuzzy TEXT matching (any word from ctags /
  -- open buffers), with no idea what scope/type you're in. Left ungrouped
  -- with nvim_lsp, their hits rank in the same merged list as clangd's
  -- semantic completions -- that's the "suggests random words" symptom.
  -- Fix: two groups. Group 1 (lsp+snippets) is tried first; group 2
  -- (buffer+tags) only kicks in when group 1 returns nothing.
  {
    "hrsh7th/nvim-cmp",
    dependencies = {
      "quangnguyen30192/cmp-nvim-tags",
    },
    opts = function(_, opts)
      local cmp = require "cmp"
      opts.sources = cmp.config.sources({
        { name = "nvim_lsp" },
        { name = "luasnip" },
        { name = "nvim_lua" },
        { name = "async_path" },
      }, {
        { name = "buffer" },
        { name = "tags" },
      })

      -- NvChad's default <Tab> steals the key the moment the menu is merely
      -- VISIBLE (cmp.visible()), not when you've actually picked an item --
      -- so moving the cursor away and hitting Tab to indent selects/confirms
      -- a stale suggestion instead.
      --
      -- Wanted behavior: Enter accepts, arrows navigate, Tab dismisses the
      -- menu (first press) and only then falls through to a real tab/snippet
      -- jump (second press, menu already closed).
      opts.mapping["<Tab>"] = cmp.mapping(function(fallback)
        if cmp.visible() then
          cmp.abort()
        elseif require("luasnip").expand_or_jumpable() then
          require("luasnip").expand_or_jump()
        else
          fallback()
        end
      end, { "i", "s" })

      opts.mapping["<S-Tab>"] = cmp.mapping(function(fallback)
        if cmp.visible() then
          cmp.abort()
        elseif require("luasnip").jumpable(-1) then
          require("luasnip").jump(-1)
        else
          fallback()
        end
      end, { "i", "s" })

      opts.mapping["<Up>"] = cmp.mapping(function(fallback)
        if cmp.visible() then
          cmp.select_prev_item()
        else
          fallback()
        end
      end, { "i" })

      opts.mapping["<Down>"] = cmp.mapping(function(fallback)
        if cmp.visible() then
          cmp.select_next_item()
        else
          fallback()
        end
      end, { "i" })

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
