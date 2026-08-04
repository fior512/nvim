-- Overseer task templates for single-file C/C++ (HPC-flavoured) workflows.
--
-- Placeholder equivalence with the classic vim expansions:
--   %    -> ctx.file  (absolute path to the current buffer)
--   %:r  -> ctx.bin   (absolute path with the extension stripped)
--   %:h  -> ctx.dir   (directory holding the current buffer)
--
-- Every task runs with cwd set to the file's directory so that generated
-- artifacts (binaries, .s dumps, cachegrind.out.*, profile data, ...) land
-- next to the source, matching what `%:r` / `%:e` would produce natively.
--
-- NOTE: this module intentionally does *not* `require("overseer")` at the top
-- level. It is required by mappings.lua to reach M.telescope_run(); pulling in
-- overseer here would trigger lazy-load before M is returned and recurse
-- through the plugin's `config`. overseer is required lazily inside M.setup()
-- (run from the plugin `config`) and M.telescope_run() instead.

local M = {}
M._names = {} -- template names, populated by M.setup(), consumed by the picker

local STD = "-std=c++20"

-- Paths derived from the *current* buffer, resolved at task-build time.
local function ctx()
  local file = vim.fn.expand "%:p"
  return {
    file = file,
    bin = vim.fn.expand "%:p:r",
    dir = vim.fn.expand "%:p:h",
    -- shell-escaped variants for use inside string commands (pipes/globs)
    efile = vim.fn.shellescape(file),
    ebin = vim.fn.shellescape(vim.fn.expand "%:p:r"),
  }
end

-- First executable name that actually exists on PATH (falls back to names[1]).
local function pick(names)
  for _, n in ipairs(names) do
    if vim.fn.executable(n) == 1 then
      return n
    end
  end
  return names[1]
end

-- bcc tools ship as either `<name>-bpfcc` (Debian/Ubuntu) or `<name>`.
local function has_bcc(base)
  return vim.fn.executable(base .. "-bpfcc") == 1 or vim.fn.executable(base) == 1
end

-- Each def: { name, desc?, tags?, quickfix?, condition_callback?, params?,
--             build = fn(ctx, params) -> task }
-- build() returns a task-opts table; `cmd` may be a list (exec directly) or a
-- string (run through the shell, so pipes/globs/`&&` work).
local defs = {
  -----------------------------------------------------------------------------
  -- Compile variants
  -----------------------------------------------------------------------------
  {
    name = "C++: compile debug",
    desc = "-g -O0 with the full warning set",
    tags = { "BUILD" },
    quickfix = true,
    build = function(c)
      return {
        cmd = {
          "g++", "-g", "-O0", "-Wall", "-Wextra", "-Wconversion", "-Wsign-conversion",
          STD, c.file, "-o", c.bin,
        },
      }
    end,
  },
  {
    name = "C++: compile release O3",
    tags = { "BUILD" },
    quickfix = true,
    build = function(c)
      return { cmd = { "g++", "-O3", "-march=native", STD, c.file, "-o", c.bin } }
    end,
  },
  {
    name = "C++: compile release O3 + LTO",
    tags = { "BUILD" },
    quickfix = true,
    build = function(c)
      return { cmd = { "g++", "-O3", "-march=native", "-flto", STD, c.file, "-o", c.bin } }
    end,
  },
  {
    name = "C++: compile fast-math (opt-in, breaks IEEE)",
    desc = "-ffast-math: HPC-only, keep separate since it breaks IEEE compliance",
    tags = { "BUILD" },
    quickfix = true,
    build = function(c)
      return { cmd = { "g++", "-O3", "-march=native", "-ffast-math", STD, c.file, "-o", c.bin } }
    end,
  },
  {
    name = "C++: compile asan+ubsan",
    tags = { "BUILD" },
    quickfix = true,
    build = function(c)
      return {
        cmd = {
          "g++", "-g", "-O1", "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
          STD, c.file, "-o", c.bin,
        },
      }
    end,
  },
  {
    name = "C++: compile tsan",
    tags = { "BUILD" },
    quickfix = true,
    build = function(c)
      return { cmd = { "g++", "-g", "-O1", "-fsanitize=thread", STD, c.file, "-o", c.bin } }
    end,
  },
  {
    name = "C++: compile assembly (.s dump)",
    desc = "-S -fverbose-asm, writes <file>.s next to the source",
    tags = { "BUILD" },
    build = function(c)
      return { cmd = { "g++", "-O3", "-march=native", "-S", "-fverbose-asm", STD, c.file } }
    end,
  },
  {
    name = "C++: compile vectorization report",
    desc = "-fopt-info-vec[-missed]: what got vectorized and what didn't",
    tags = { "BUILD" },
    quickfix = true,
    build = function(c)
      return {
        cmd = {
          "g++", "-O3", "-march=native", "-fopt-info-vec", "-fopt-info-vec-missed",
          STD, c.file, "-o", c.bin,
        },
      }
    end,
  },
  {
    name = "C++: compile PGO instrument",
    desc = "-fprofile-generate: build, then run to collect a profile",
    tags = { "BUILD" },
    quickfix = true,
    build = function(c)
      return { cmd = { "g++", "-O3", "-fprofile-generate", STD, c.file, "-o", c.bin } }
    end,
  },
  {
    name = "C++: compile PGO optimized",
    desc = "-fprofile-use: rebuild using the collected profile",
    tags = { "BUILD" },
    quickfix = true,
    build = function(c)
      return {
        cmd = { "g++", "-O3", "-fprofile-use", "-fprofile-correction", STD, c.file, "-o", c.bin },
      }
    end,
  },

  -----------------------------------------------------------------------------
  -- Run
  -----------------------------------------------------------------------------
  {
    name = "C++: run",
    tags = { "RUN" },
    build = function(c)
      return { cmd = { c.bin } }
    end,
  },
  {
    name = "C++: build and run (release O3)",
    desc = "Chain release-O3 compile + run in one task",
    tags = { "RUN" },
    build = function(c)
      return {
        cmd = string.format("g++ -O3 -march=native %s %s -o %s && %s", STD, c.efile, c.ebin, c.ebin),
      }
    end,
  },

  -----------------------------------------------------------------------------
  -- perf
  -----------------------------------------------------------------------------
  {
    -- Added so the report/annotate/script tasks below have data to read.
    name = "perf: record (-> /tmp/perf.data)",
    desc = "perf record -o /tmp/perf.data, feeds the report/annotate/script tasks",
    build = function(c)
      return { cmd = { "perf", "record", "-o", "/tmp/perf.data", c.bin } }
    end,
  },
  {
    name = "perf: stat",
    build = function(c)
      return { cmd = { "perf", "stat", c.bin } }
    end,
  },
  {
    name = "perf: stat detailed",
    build = function(c)
      return {
        cmd = {
          "perf", "stat", "-e",
          "cycles,instructions,cache-references,cache-misses,branches,branch-misses",
          c.bin,
        },
      }
    end,
  },
  {
    name = "perf: report (stdio)",
    build = function()
      return { cmd = { "perf", "report", "-i", "/tmp/perf.data", "--stdio" } }
    end,
  },
  {
    name = "perf: annotate (stdio)",
    desc = "Optionally focus a single symbol",
    params = {
      symbol = { type = "string", name = "symbol", desc = "function symbol (blank = all)", optional = true },
    },
    build = function(_, p)
      local cmd = "perf annotate -i /tmp/perf.data"
      if p.symbol and p.symbol ~= "" then
        cmd = cmd .. " " .. vim.fn.shellescape(p.symbol)
      end
      return { cmd = cmd .. " --stdio" }
    end,
  },
  {
    name = "perf: script (raw event dump)",
    desc = "Raw dump, feeds flamegraph tooling",
    build = function()
      return { cmd = { "perf", "script", "-i", "/tmp/perf.data" } }
    end,
  },
  {
    name = "perf: flamegraph (-> /tmp/flame.svg)",
    build = function()
      return {
        cmd = "perf script -i /tmp/perf.data | stackcollapse-perf.pl | flamegraph.pl > /tmp/flame.svg",
      }
    end,
  },
  {
    name = "perf: c2c (record + report)",
    desc = "False-sharing / cache-line contention, record then report --stdio",
    build = function(c)
      return { cmd = string.format("perf c2c record -- %s && perf c2c report --stdio", c.ebin) }
    end,
  },
  {
    -- Non-TUI live profiler: --stdio drops the ncurses UI, `| cat` guarantees
    -- no TTY interactivity, and the (optional) timeout makes it terminate.
    name = "perf: top (stdio, live)",
    desc = "perf top --stdio | cat, bounded by a duration so it self-terminates",
    params = {
      pid = { type = "string", name = "pid", desc = "attach to PID (blank = system-wide)", optional = true },
      duration = {
        type = "string",
        name = "duration",
        desc = "seconds before it stops (blank = run until stopped)",
        default = "5",
        optional = true,
      },
    },
    build = function(_, p)
      local top = "perf top --stdio"
      if p.pid and p.pid ~= "" then
        top = top .. " -p " .. vim.fn.shellescape(p.pid)
      end
      top = top .. " | cat"
      if p.duration and p.duration ~= "" then
        top = "timeout " .. vim.fn.shellescape(p.duration) .. " " .. top
      end
      return { cmd = top }
    end,
  },

  -----------------------------------------------------------------------------
  -- perf-tools (Brendan Gregg's bcc scripts) -- shown only when installed
  -----------------------------------------------------------------------------
  {
    name = "perf-tools: funccount (call counts)",
    desc = "bcc funccount over the binary's user functions (needs root/bcc)",
    condition_callback = function()
      return has_bcc "funccount"
    end,
    params = {
      pattern = {
        type = "string",
        name = "pattern",
        desc = "function glob within the binary",
        default = "*",
        optional = true,
      },
    },
    build = function(c, p)
      local tool = pick { "funccount-bpfcc", "funccount" }
      local pat = (p.pattern and p.pattern ~= "") and p.pattern or "*"
      -- uprobe pattern form: '<binary>:<glob>'
      return { cmd = { tool, c.bin .. ":" .. pat } }
    end,
  },
  {
    name = "perf-tools: funclatency (latency histogram)",
    desc = "bcc funclatency: per-function latency for the binary (needs root/bcc)",
    condition_callback = function()
      return has_bcc "funclatency"
    end,
    params = {
      func = {
        type = "string",
        name = "function",
        desc = "function glob within the binary",
        default = "*",
        optional = true,
      },
    },
    build = function(c, p)
      local tool = pick { "funclatency-bpfcc", "funclatency" }
      local f = (p.func and p.func ~= "") and p.func or "*"
      return { cmd = { tool, c.bin .. ":" .. f } }
    end,
  },

  -----------------------------------------------------------------------------
  -- valgrind
  -----------------------------------------------------------------------------
  {
    name = "valgrind: memcheck",
    desc = "Default tool: leak + invalid-access checking",
    build = function(c)
      return { cmd = { "valgrind", c.bin } }
    end,
  },
  {
    name = "valgrind: memcheck full",
    build = function(c)
      return {
        cmd = {
          "valgrind", "--leak-check=full", "--show-leak-kinds=all", "--track-origins=yes", c.bin,
        },
      }
    end,
  },
  {
    name = "valgrind: cachegrind",
    build = function(c)
      return { cmd = { "valgrind", "--tool=cachegrind", c.bin } }
    end,
  },
  {
    name = "valgrind: cachegrind annotate (latest out)",
    desc = "cg_annotate on the most recent cachegrind.out.* in the file's dir",
    build = function()
      return { cmd = "cg_annotate $(ls -t cachegrind.out.* | head -1)" }
    end,
  },
  {
    name = "valgrind: callgrind",
    build = function(c)
      return { cmd = { "valgrind", "--tool=callgrind", c.bin } }
    end,
  },
  {
    name = "valgrind: callgrind annotate (latest out)",
    build = function()
      return { cmd = "callgrind_annotate $(ls -t callgrind.out.* | head -1)" }
    end,
  },
  {
    name = "valgrind: massif (heap profile)",
    build = function(c)
      return { cmd = { "valgrind", "--tool=massif", c.bin } }
    end,
  },
  {
    name = "valgrind: massif print (latest out)",
    build = function()
      return { cmd = "ms_print $(ls -t massif.out.* | head -1)" }
    end,
  },
  {
    name = "valgrind: helgrind (thread races)",
    desc = "Thread race detection, alternative to tsan",
    build = function(c)
      return { cmd = { "valgrind", "--tool=helgrind", c.bin } }
    end,
  },

  -----------------------------------------------------------------------------
  -- clang-tidy / static analysis (standalone file, no compile_commands.json)
  -----------------------------------------------------------------------------
  {
    name = "clang-tidy: check",
    build = function(c)
      return { cmd = { "clang-tidy", c.file, "--", STD } }
    end,
  },
  {
    name = "clang-tidy: fix",
    build = function(c)
      return { cmd = { "clang-tidy", c.file, "--fix", "--", STD } }
    end,
  },

  -----------------------------------------------------------------------------
  -- rr
  -----------------------------------------------------------------------------
  {
    name = "rr: record",
    build = function(c)
      return { cmd = { "rr", "record", c.bin } }
    end,
  },
  {
    name = "rr: replay",
    build = function()
      return { cmd = { "rr", "replay" } }
    end,
  },
}

-- Run from the plugin `config` (see lua/plugins/init.lua). Registers every
-- template and records its name for the telescope picker.
function M.setup()
  local overseer = require "overseer"

  overseer.setup {
    templates = {}, -- we register our own below, skip the bundled defaults
    task_list = {
      direction = "bottom",
      default_detail = 1,
    },
  }

  for _, def in ipairs(defs) do
    local condition = { filetype = { "cpp", "c" } }
    if def.condition_callback then
      condition.callback = def.condition_callback
    end

    overseer.register_template {
      name = def.name,
      desc = def.desc,
      tags = def.tags,
      params = def.params or {},
      condition = condition,
      builder = function(params)
        local c = ctx()
        local task = def.build(c, params)
        task.name = task.name or def.name
        task.cwd = task.cwd or c.dir
        if def.quickfix then
          -- route compiler diagnostics into the quickfix list, open on error
          task.components = task.components
            or { { "on_output_quickfix", open_on_error = true }, "default" }
        end
        return task
      end,
    }

    M._names[#M._names + 1] = def.name
  end
end

-- <leader>oo entry point: fuzzy-search the C/C++ templates in a Telescope
-- picker and run the chosen one (overseer prompts for any params). Requiring
-- overseer here lazy-loads the plugin, which runs M.setup() and fills _names.
function M.telescope_run()
  local ok_overseer, overseer = pcall(require, "overseer")
  if not ok_overseer then
    vim.notify("overseer.nvim is not available", vim.log.levels.ERROR)
    return
  end

  local ok_telescope, pickers = pcall(require, "telescope.pickers")
  if not ok_telescope then
    -- No telescope: fall back to overseer's built-in vim.ui.select picker.
    vim.notify("telescope not found, falling back to :OverseerRun", vim.log.levels.WARN)
    vim.cmd "OverseerRun"
    return
  end

  local finders = require "telescope.finders"
  local conf = require("telescope.config").values
  local actions = require "telescope.actions"
  local action_state = require "telescope.actions.state"
  local themes = require "telescope.themes"

  -- Remember the buffer we launched from so the template builds against it,
  -- not against telescope's prompt buffer.
  local src_buf = vim.api.nvim_get_current_buf()

  pickers
    .new(themes.get_dropdown { layout_config = { width = 0.7, height = 0.6 } }, {
      prompt_title = "Overseer · C/C++ tasks",
      finder = finders.new_table { results = M._names },
      sorter = conf.generic_sorter {},
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          local entry = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if not entry then
            return
          end
          if vim.api.nvim_buf_is_valid(src_buf) then
            vim.api.nvim_set_current_buf(src_buf)
          end
          overseer.run_task { name = entry[1] }
        end)
        return true
      end,
    })
    :find()
end

return M
