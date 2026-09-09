return {
  {
    "gen740/SmoothCursor.nvim",
    event = "VeryLazy",
    opts = {
      type = "default", -- interpolated block movement, no trailing glyphs
      fancy = { enable = false }, -- no rainbow trail, matches minimalist palette
      cursor_color = "#d0918d", -- existing accent (Keyword/red)
      intervals = 35,
      flyin_effect = nil,
      speed = 25,
      autostart = true,
      disable_float_win = true,
    },
  },
  {
    "stevearc/conform.nvim",
    -- event = 'BufWritePre', -- uncomment for format on save
    opts = require "configs.conform",
  },

  -- auto-regenerates ./tags in the background; replaces manual <leader>ct
  {
    "ludovicchabant/vim-gutentags",
    event = { "BufReadPost", "BufNewFile" },
    init = function()
      vim.g.gutentags_add_default_project_roots = false
      vim.g.gutentags_project_root = { ".git", "Cargo.toml", "go.mod", "CMakeLists.txt" }
      vim.g.gutentags_ctags_tagfile = "tags"
      vim.g.gutentags_generate_on_new = true
      vim.g.gutentags_generate_on_missing = true
      vim.g.gutentags_generate_on_write = true
      vim.g.gutentags_generate_on_empty_buffer = false
      vim.g.gutentags_ctags_exclude = { ".git", "build", "target", "node_modules" }
    end,
  },

  {
    "neovim/nvim-lspconfig",
    event = { "BufReadPre", "BufNewFile" },
    config = function()
      require "configs.lspconfig"
    end,
  },

  -- replaced by blink.cmp below; kept disabled so lazy still resolves the
  -- NvChad base spec instead of erroring on an unknown plugin name
  { "hrsh7th/nvim-cmp", enabled = false },

  -- snippets still feed blink.cmp; kept detached from the old cmp glue
  {
    "L3MON4D3/LuaSnip",
    event = "InsertEnter",
    dependencies = "rafamadriz/friendly-snippets",
    opts = { history = true, updateevents = "TextChanged,TextChangedI" },
    config = function(_, opts)
      require("luasnip").config.set_config(opts)
      require "nvchad.configs.luasnip"
    end,
  },
  {
    "windwp/nvim-autopairs",
    event = "InsertEnter",
    opts = {},
  },

  -- cross-file suggestions via ctags, needs `tags` file
  -- two priority groups: lsp+snippets first, buffer+tags fallback
  {
    "saghen/blink.cmp",
    event = "InsertEnter",
    version = "1.*",
    dependencies = {
      "rafamadriz/friendly-snippets",
      "quangnguyen30192/cmp-nvim-tags",
      { "saghen/blink.compat", version = "2.*", lazy = true, opts = {} },
    },
    opts = {
      appearance = { nerd_font_variant = "mono" },
      completion = {
        -- lets clangd/gopls/rust-analyzer insert the missing import
        accept = { auto_brackets = { enabled = true } },
        menu = { auto_show = true },
        documentation = { auto_show = true },
        ghost_text = { enabled = true },
      },
      signature = { enabled = true },
      snippets = { preset = "luasnip" },
      sources = {
        default = { "lsp", "path", "snippets", "buffer", "tags" },
        providers = {
          tags = {
            name = "tags",
            module = "blink.compat.source",
            score_offset = -3,
          },
        },
      },
      -- Tab dismisses menu first, indents second; never jumps via snippet
      keymap = {
        preset = "none",
        ["<C-space>"] = { "show", "show_documentation", "hide_documentation" },
        ["<CR>"] = { "accept", "fallback" },
        ["<Tab>"] = { "hide", "fallback" },
        ["<S-Tab>"] = { "hide", "fallback" },
        ["<Up>"] = { "select_prev", "fallback" },
        ["<Down>"] = { "select_next", "fallback" },
        ["<C-e>"] = { "hide", "fallback" },
      },
    },
  },
  -- full document LaTeX preview: latexmk compiles, vimtex syncs okular
  {
    "lervag/vimtex",
    lazy = false, -- must load before the first .tex buffer opens
    init = function()
      require "configs.vimtex"
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
              completion = {
                autoimport = { enable = true }, -- import path on accept
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

  -- remaps teal-hued devicons to theme's soft-gold
  {
    "nvim-tree/nvim-web-devicons",
    opts = require "configs.devicons",
  },
  {
    "nvim-treesitter/nvim-treesitter",
    branch = "main",
    build = ":TSUpdate",
    -- main branch ignores ensure_installed, install explicitly
    config = function()
      require("nvim-treesitter").install {
        "vim", "lua", "vimdoc",
        "html", "css",
        "cpp", "c",
        "rust",
        "go", "gomod", "gosum", "gowork",
        "julia",
        "markdown", "markdown_inline",
        "typescript", "tsx",
        "cuda",
        "latex",
      }
    end,
  },

  -- split preview: source stays plain text, preview buffer gets rendering
  {
    "OXY2DEV/markview.nvim",
    lazy = false, -- already lazy-loads itself; see plugin README
    config = function()
      require("markview").setup(require "configs.markview")

      -- reapplied each tick: markview re-links heading bg on every render
      local function plain_headings()
        for i = 1, 6 do
          vim.api.nvim_set_hl(0, "MarkviewHeading" .. i, { fg = "#dcdcd4", bold = true })
        end
      end

      -- deferred: preview buffer is empty until splitview_render() finishes
      vim.api.nvim_create_autocmd("User", {
        pattern = "MarkviewSplitviewOpen",
        group = vim.api.nvim_create_augroup("markview_snacks_math", { clear = true }),
        callback = function(ev)
          vim.schedule(function()
            Snacks.image.doc.attach(ev.data.preview_buffer)
            plain_headings()
          end)
        end,
      })
    end,
  },
  {
    "folke/snacks.nvim",
    priority = 1000,
    lazy = false,
    opts = require "configs.snacks",
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
        -- explicit palette, avoids theme="auto" freezing stale colors
        theme = {
          normal = {
            a = { bg = "#ffbd5e", fg = "#040404", gui = "bold" }, -- orange (Keyword)
            b = { bg = "#090909", fg = "#ffbd5e" },
            c = { bg = "#141414", fg = "#dcdcd4" },
          },
          insert = {
            a = { bg = "#b5a494", fg = "#040404", gui = "bold" }, -- green (Type)
            b = { bg = "#090909", fg = "#b5a494" },
            c = { bg = "#141414", fg = "#dcdcd4" },
          },
          visual = {
            a = { bg = "#ecd3a0", fg = "#040404", gui = "bold" }, -- soft-gold
            b = { bg = "#090909", fg = "#ecd3a0" },
            c = { bg = "#141414", fg = "#dcdcd4" },
          },
          replace = {
            a = { bg = "#bd8c70", fg = "#040404", gui = "bold" }, -- rust-orange (String)
            b = { bg = "#090909", fg = "#bd8c70" },
            c = { bg = "#141414", fg = "#dcdcd4" },
          },
          command = {
            a = { bg = "#dcdcd4", fg = "#040404", gui = "bold" }, -- dimmed white
            b = { bg = "#090909", fg = "#dcdcd4" },
            c = { bg = "#141414", fg = "#dcdcd4" },
          },
          inactive = {
            a = { bg = "#090909", fg = "#4c4b3c" },
            b = { bg = "#090909", fg = "#4c4b3c" },
            c = { bg = "#090909", fg = "#4c4b3c" },
          },
        },
      },
    },
  },
  -- merges keymaps picker into NvChad's own telescope opts
  {
    "nvim-telescope/telescope.nvim",
    opts = function(_, opts)
      opts.pickers = opts.pickers or {}
      opts.pickers.keymaps = vim.tbl_deep_extend("force", opts.pickers.keymaps or {}, {
        entry_maker = require("configs.telescope").keymaps_entry_maker(),
      })
      return opts
    end,
  },

  {
    "danymat/neogen",
    event = "VeryLazy",
    config = function()
      require("neogen").setup {
        snippet_engine = "luasnip", -- NvChad ships LuaSnip: tab through [TODO:...] fields
      }
      -- neogen has no built-in keymaps, cg is conflict-free
      vim.keymap.set("n", "<leader>cg", function()
        require("neogen").generate()
      end, { desc = "Neogen annotate (doxygen-style for c/cpp)" })
    end,
  },

  -- full undo tree with diff preview, all branches
  {
    "jiaoshijie/undotree",
    url = "git@github.com:jiaoshijie/undotree.git", -- only ssh clones on this machine
    opts = {
      float_diff = true, -- diff preview in a floating window
      parser = "compact", -- compact tree style
    },
    keys = {
      { "<leader>ut", "<cmd>lua require('undotree').toggle()<cr>", desc = "Undo tree with diff preview" },
    },
  },

  -- adds border to preview_hunk float, NvChad leaves it borderless
  {
    "lewis6991/gitsigns.nvim",
    opts = function(_, opts)
      opts.preview_config = vim.tbl_deep_extend("force", opts.preview_config or {}, {
        border = "rounded",
      })
      return opts
    end,
  },

  -- floating per-project todo list, not code-comment-based
  {
    "pablopunk/todo.nvim",
    config = true,
    keys = {
      { "<leader>td", "<cmd>TodoToggle<cr>", desc = "Toggle project todo list" },
    },
  },

  -- sticky header shows enclosing function/struct signature
  {
    "nvim-treesitter/nvim-treesitter-context",
    event = { "BufReadPre", "BufNewFile" },
    opts = {
      max_lines = 3,
      multiline_threshold = 1,
    },
  },
}
