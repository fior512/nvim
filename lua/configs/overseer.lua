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

local overseer = require "overseer"

overseer.setup {
  templates = {}, -- we register our own below, skip the bundled defaults
  task_list = {
    direction = "bottom",
    default_detail = 1,
  },
}

local TAG = require("overseer.constants").TAG
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

-- Each def: { name, desc?, tags?, quickfix?, params?, build = fn(ctx, params) -> task }
-- build() returns a task-opts table; `cmd` may be a list (exec directly) or a
-- string (run through the shell, so pipes/globs/`&&` work).
local defs = {
  -----------------------------------------------------------------------------
  -- Compile variants
  -----------------------------------------------------------------------------
  {
    name = "C++: compile debug",
    desc = "-g -O0 with the full warning set",
    tags = { TAG.BUILD },
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
    tags = { TAG.BUILD },
    quickfix = true,
    build = function(c)
      return { cmd = { "g++", "-O3", "-march=native", STD, c.file, "-o", c.bin } }
    end,
  },
  {
    name = "C++: compile release O3 + LTO",
    tags = { TAG.BUILD },
    quickfix = true,
    build = function(c)
      return { cmd = { "g++", "-O3", "-march=native", "-flto", STD, c.file, "-o", c.bin } }
    end,
  },
  {
    name = "C++: compile fast-math (opt-in, breaks IEEE)",
    desc = "-ffast-math: HPC-only, keep separate since it breaks IEEE compliance",
    tags = { TAG.BUILD },
    quickfix = true,
    build = function(c)
      return { cmd = { "g++", "-O3", "-march=native", "-ffast-math", STD, c.file, "-o", c.bin } }
    end,
  },
  {
    name = "C++: compile asan+ubsan",
    tags = { TAG.BUILD },
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
    tags = { TAG.BUILD },
    quickfix = true,
    build = function(c)
      return { cmd = { "g++", "-g", "-O1", "-fsanitize=thread", STD, c.file, "-o", c.bin } }
    end,
  },
  {
    name = "C++: compile assembly (.s dump)",
    desc = "-S -fverbose-asm, writes <file>.s next to the source",
    tags = { TAG.BUILD },
    build = function(c)
      return { cmd = { "g++", "-O3", "-march=native", "-S", "-fverbose-asm", STD, c.file } }
    end,
  },
  {
    name = "C++: compile vectorization report",
    desc = "-fopt-info-vec[-missed]: what got vectorized and what didn't",
    tags = { TAG.BUILD },
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
    tags = { TAG.BUILD },
    quickfix = true,
    build = function(c)
      return { cmd = { "g++", "-O3", "-fprofile-generate", STD, c.file, "-o", c.bin } }
    end,
  },
  {
    name = "C++: compile PGO optimized",
    desc = "-fprofile-use: rebuild using the collected profile",
    tags = { TAG.BUILD },
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
    tags = { TAG.RUN },
    build = function(c)
      return { cmd = { c.bin } }
    end,
  },
  {
    name = "C++: build and run (release O3)",
    desc = "Chain release-O3 compile + run in one task",
    tags = { TAG.RUN },
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

for _, def in ipairs(defs) do
  overseer.register_template {
    name = def.name,
    desc = def.desc,
    tags = def.tags,
    params = def.params or {},
    condition = { filetype = { "cpp", "c" } },
    builder = function(params)
      local c = ctx()
      local task = def.build(c, params)
      task.name = task.name or def.name
      task.cwd = task.cwd or c.dir
      if def.quickfix then
        -- route compiler diagnostics into the quickfix list, open on error
        task.components = task.components or { { "on_output_quickfix", open_on_error = true }, "default" }
      end
      return task
    end,
  }
end
