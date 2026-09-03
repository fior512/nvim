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

  {
    "neovim/nvim-lspconfig",
    event = { "BufReadPre", "BufNewFile" },
    config = function()
      require "configs.lspconfig"
    end,
  },

  -- cross-file suggestions via ctags, needs `tags` file
  -- two priority groups: lsp+snippets first, buffer+tags fallback
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

      -- Tab dismisses menu first, indents second; never jumps via luasnip
      opts.mapping["<Tab>"] = cmp.mapping(function(fallback)
        if cmp.visible() then
          cmp.abort()
        else
          fallback()
        end
      end, { "i", "s" })

      opts.mapping["<S-Tab>"] = cmp.mapping(function(fallback)
        if cmp.visible() then
          cmp.abort()
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

      -- markdown only; tex handled separately by vimtex
      vim.api.nvim_create_autocmd("FileType", {
        pattern = { "markdown" },
        group = vim.api.nvim_create_augroup("markview_autosplit", { clear = true }),
        callback = function(ev)
          if vim.bo[ev.buf].buftype ~= "" then
            return -- real file buffers only, skip floats/scratch/previews
          end
          require("markview.actions").splitOpen(ev.buf)
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
      { "<leader>u", "<cmd>lua require('undotree').toggle()<cr>", desc = "Undo tree with diff preview" },
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
