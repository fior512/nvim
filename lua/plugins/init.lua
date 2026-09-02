return {
  {
    "scottmckendry/cyberdream.nvim",
    lazy = false,
    priority = 1000, -- load before other UI plugins reference highlight groups
    config = function()
      require("cyberdream").setup {
        colors = {
          -- darker bg to match the hardcoded zenbones_custom theme instead
          -- of cyberdream's default #16181a
          bg = "#040403",
          bg_alt = "#0a0908",
          bg_highlight = "#161412",
          -- pure #ffffff was too bright against the dark bg
          fg = "#dcdcd4",
          -- no pink/purple anywhere: purple/magenta go to the actual
          -- zenbones_custom green (#b5a494, the same "green" your hardcoded
          -- nvim theme already renders -- not hypr's window-border accent,
          -- that's a different, unrelated color); pink goes soft-gold
          purple = "#b5a494",
          magenta = "#b5a494",
          pink = "#ecd3a0",
          -- cyan was the last teal-family color left (it's what Boolean,
          -- PreProc, search-highlight etc. actually pull from) -- retire it
          -- to the same soft-gold instead of patching each group piecemeal
          cyan = "#ecd3a0",
        },
        highlights = {
          -- Rust's own brand orange for strings, darkened a touch so it
          -- doesn't read as bright against the dark bg
          String = { fg = "#bd8c70" },
          Character = { fg = "#bd8c70" },
          -- hardcoded/literal values (numbers, consts) match strings now
          -- instead of the soft-gold they inherited from `pink`
          Constant = { fg = "#bd8c70" },
          Number = { fg = "#bd8c70" },
          -- println!/macros: was landing on a rusty tone via Macro->PreProc;
          -- pin it to the soft-gold accent instead, explicitly, on every
          -- path that can resolve a macro (plain syntax, treesitter,
          -- rust-analyzer semantic tokens)
          Macro = { fg = "#ecd3a0" },
          ["@function.macro"] = { fg = "#ecd3a0" },
          ["@lsp.type.macro"] = { fg = "#ecd3a0" },
          -- for/in/while/loop/match/else etc. fall back to Statement by
          -- default (would've picked up the green from purple/magenta) --
          -- pin them to Keyword's orange instead, same as `let`/`fn`
          Conditional = { fg = "#ffbd5e" },
          Repeat = { fg = "#ffbd5e" },
          Label = { fg = "#ffbd5e" },
          Exception = { fg = "#ffbd5e" },
          ["@keyword.conditional"] = { fg = "#ffbd5e" },
          ["@keyword.repeat"] = { fg = "#ffbd5e" },
          ["@keyword.exception"] = { fg = "#ffbd5e" },
          ["@label"] = { fg = "#ffbd5e" },

          -- dimmed, not eye-catching, but still legible against #040403
          Comment = { fg = "#4c4b3c", italic = true },
          ["@comment"] = { fg = "#4c4b3c", italic = true },
          -- doc comments (///, //!, /** */) a touch brighter than plain //
          -- comments, but only slightly -- not a hard contrast jump
          SpecialComment = { fg = "#5c5a46", italic = true },
          ["@comment.documentation"] = { fg = "#5c5a46", italic = true },

          -- inline "cues" (inlay hints, virtual diagnostics) as dark/muted
          -- as the hardcoded zenbones_custom theme's -- signs/underlines on
          -- actual errors stay full-strength (untouched) so real problems
          -- still stand out
          LspInlayHint = { fg = "#3a3833", italic = true },
          DiagnosticVirtualTextError = { fg = "#604341", italic = true },
          DiagnosticVirtualTextWarn = { fg = "#544c3e", italic = true },
          DiagnosticVirtualTextInfo = { fg = "#544c44", italic = true },
          DiagnosticVirtualTextHint = { fg = "#4c4953", italic = true },
        },
      }
      -- init.lua re-applies NvChad's base46 "defaults"/"statusline" cache
      -- *after* lazy.setup() returns, which would stomp these highlights
      -- if set synchronously here -- defer to the next event loop tick so
      -- this runs last and is the startup default. <leader>tc (mappings.lua)
      -- still flips back to the hardcoded zenbones_custom theme and back.
      vim.schedule(function()
        require("cyberdream").load()
      end)
    end,
  },
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
        "latex",
      },
    },
  },

  -- Markdown/LaTeX visualizer: real split window (source left, rendered
  -- preview right), autodetected by filetype. configs.markview turns off
  -- markview's own inline/conceal rendering (preview.enable = false) so the
  -- SOURCE buffer stays plain, editable text -- only markview's `splitOpen`
  -- preview buffer gets rendered. On every markdown/tex buffer we open that
  -- split automatically, and on `MarkviewSplitviewOpen` we attach
  -- snacks.image (real pdflatex-compiled math, see configs.snacks) to the
  -- preview buffer only, so math images never land in the editable side.
  {
    "OXY2DEV/markview.nvim",
    lazy = false, -- already lazy-loads itself; see plugin README
    config = function()
      require("markview").setup(require "configs.markview")

      vim.api.nvim_create_autocmd("User", {
        pattern = "MarkviewSplitviewOpen",
        group = vim.api.nvim_create_augroup("markview_snacks_math", { clear = true }),
        callback = function(ev)
          Snacks.image.doc.attach(ev.data.preview_buffer)
        end,
      })

      vim.api.nvim_create_autocmd("FileType", {
        pattern = { "markdown", "tex" },
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
        -- theme = "auto" samples highlight groups (PmenuSel, String,
        -- Special/Boolean, ...) once at lualine's own load time via a
        -- require()-cached module -- racy against cyberdream's own load
        -- (deferred with vim.schedule in this config), so it can freeze in
        -- cyberdream's raw defaults (teal/pink) instead of our overrides.
        -- An explicit theme built from the same palette can't drift.
        theme = {
          normal = {
            a = { bg = "#ffbd5e", fg = "#040403", gui = "bold" }, -- orange (Keyword)
            b = { bg = "#0a0908", fg = "#ffbd5e" },
            c = { bg = "#161412", fg = "#dcdcd4" },
          },
          insert = {
            a = { bg = "#b5a494", fg = "#040403", gui = "bold" }, -- green (Type)
            b = { bg = "#0a0908", fg = "#b5a494" },
            c = { bg = "#161412", fg = "#dcdcd4" },
          },
          visual = {
            a = { bg = "#ecd3a0", fg = "#040403", gui = "bold" }, -- soft-gold
            b = { bg = "#0a0908", fg = "#ecd3a0" },
            c = { bg = "#161412", fg = "#dcdcd4" },
          },
          replace = {
            a = { bg = "#bd8c70", fg = "#040403", gui = "bold" }, -- rust-orange (String)
            b = { bg = "#0a0908", fg = "#bd8c70" },
            c = { bg = "#161412", fg = "#dcdcd4" },
          },
          command = {
            a = { bg = "#dcdcd4", fg = "#040403", gui = "bold" }, -- dimmed white
            b = { bg = "#0a0908", fg = "#dcdcd4" },
            c = { bg = "#161412", fg = "#dcdcd4" },
          },
          inactive = {
            a = { bg = "#0a0908", fg = "#4c4b3c" },
            b = { bg = "#0a0908", fg = "#4c4b3c" },
            c = { bg = "#0a0908", fg = "#4c4b3c" },
          },
        },
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
