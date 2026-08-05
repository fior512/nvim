-- Overseer task templates for single-file C/C++ (HPC) workflows.
--
-- Placeholder equivalence with classic vim expansions:
--   %    = ctx.file (absolute path to the current buffer)
--   %:r  = ctx.bin  (absolute path with the extension stripped)
--   %:h  = ctx.dir  (directory holding the current buffer)
--
-- Every task runs with cwd set to the file's directory so generated
-- artifacts (binaries, .s dumps, profile data) land next to the source.
--
-- This module does not `require("overseer")` at the top level: it is
-- required by mappings.lua to reach M.telescope_run(), and pulling in
-- overseer here would trigger lazy-load before M is returned, recursing
-- through the plugin's `config`. overseer is required lazily inside
-- M.setup() (run from the plugin `config`) and M.telescope_run().

local M = {}
M._names = {} -- template names, populated by M.setup(), consumed by the picker
M._needs_bin = {} -- name -> true for defs that need a "binary" param

local STD = "-std=c++20"
local CLANG_TIDY_CHECKS = "clang-diagnostic-*,clang-analyzer-*,bugprone-*,performance-*,modernize-*"

-- Paths derived from the current buffer, resolved at task-build time.
local function ctx()
  local file = vim.fn.expand "%:p"
  return {
    file = file,
    bin = vim.fn.expand "%:p:r",
    dir = vim.fn.expand "%:p:h",
    efile = vim.fn.shellescape(file),
    ebin = vim.fn.shellescape(vim.fn.expand "%:p:r"),
  }
end

-- First executable that exists on PATH, falls back to names[1].
local function pick(names)
  for _, n in ipairs(names) do
    if vim.fn.executable(n) == 1 then
      return n
    end
  end
  return names[1]
end

-- bcc tools ship as either "<name>-bpfcc" (Debian/Ubuntu) or "<name>".
local function has_bcc(base)
  return vim.fn.executable(base .. "-bpfcc") == 1 or vim.fn.executable(base) == 1
end

-- PMU raw event names are vendor specific (Intel and AMD use different
-- names for analogous counters). "perf: stat microarch" uses this to pick
-- its event list.
local function cpu_vendor()
  local ok, lines = pcall(vim.fn.readfile, "/proc/cpuinfo", "", 30)
  if ok then
    for _, line in ipairs(lines) do
      if line:find "AuthenticAMD" then
        return "amd"
      elseif line:find "GenuineIntel" then
        return "intel"
      end
    end
  end
  return "unknown"
end

-- Tools that operate on an already-built binary can't assume "<file>:r" is
-- the right executable: justfile/CMake/etc. projects build elsewhere under
-- a different name. defs with needs_bin = true get a required "binary"
-- param so overseer always prompts for the real path; blank falls back to
-- the "<file>:r" guess.
local function resolve_bin(c, p)
  local bin = c.bin
  if p and p.bin and p.bin ~= "" then
    bin = vim.fn.expand(p.bin)
  end
  return bin, vim.fn.shellescape(bin)
end

-- "<date> (<age> ago)" for a file's mtime, or "not found". Shows how old a
-- binary or snapshot is before a task reads it, so a stale artifact is
-- obvious.
local function human_age(mtime)
  if not mtime or mtime <= 0 then
    return "not found"
  end
  local secs = os.time() - mtime
  local age
  if secs < 60 then
    age = string.format("%ds", secs)
  elseif secs < 3600 then
    age = string.format("%dm", math.floor(secs / 60))
  elseif secs < 86400 then
    age = string.format("%dh%dm", math.floor(secs / 3600), math.floor((secs % 3600) / 60))
  else
    age = string.format("%dd%dh", math.floor(secs / 86400), math.floor((secs % 86400) / 3600))
  end
  return os.date("%Y-%m-%d %H:%M:%S", mtime) .. " (" .. age .. " ago)"
end

-- Flattens a table-form cmd into a shell string, each element escaped, so
-- the shared builder can echo what it's about to run for either form.
local function to_shell_str(cmd)
  if type(cmd) == "table" then
    local parts = {}
    for _, a in ipairs(cmd) do
      parts[#parts + 1] = vim.fn.shellescape(a)
    end
    return table.concat(parts, " ")
  end
  return cmd
end

-- Shortens absolute paths in the echoed preamble (never the command that
-- actually runs) relative to the cwd Neovim started in, then home.
local function shorten_display(str)
  local cwd = vim.fn.getcwd()
  local out = str
  if cwd ~= "" then
    out = out:gsub(vim.pesc(cwd .. "/"), "")
  end
  local home = vim.fn.expand "$HOME"
  if home ~= "" and home ~= "$HOME" then
    out = out:gsub(vim.pesc(home), "~")
  end
  return out
end

-- asm/mca/uica/pahole/bloaty all read an artifact the build already
-- produced (the linked binary) via the same needs_bin/resolve_bin
-- mechanism as perf/valgrind/rr, instead of reproducing a build to get an
-- intermediate .o with the right flags. All output is plain text, no TUI
-- or pager.
local ASM_SNAP_DIR = "/tmp/asm-snap"
local BLOATY_SNAP_DIR = "/tmp/bloaty-snap"

local SYMBOL_PARAM = {
  symbol = { type = "string", name = "symbol", desc = "function symbol (blank = whole binary)", optional = true },
}
local TYPE_PARAM = {
  type_name = {
    type = "string",
    name = "type",
    desc = "C/C++ type name (blank = whole-binary padding sweep)",
    optional = true,
  },
}

local function objdump_cmd(ebin, sym)
  local cmd = "objdump -d -M intel -C --no-show-raw-insn"
  if sym and sym ~= "" then
    cmd = cmd .. " --disassemble=" .. vim.fn.shellescape(sym)
  end
  return cmd .. " " .. ebin
end

-- For diffing/snapshots: strips address/byte-offset prefixes, collapses
-- compiler-generated .L labels, drops .cfi_ directives and padding nops,
-- and blurs long literal addresses so diffs stay quiet across rebuilds.
local SED_NORMALIZE =
  "sed -E 's/^[[:space:]]*[0-9a-f]+:[[:space:]]*//; s/\\.L[A-Za-z]+[0-9_]+/.L/g; /\\.cfi_/d; /^[[:space:]]*nop/d; s/0x[0-9a-f]{6,}/0xADDR/g'"

-- For llvm-mca/uiCA: must stay valid assembly, so it can't blur addresses
-- like SED_NORMALIZE does. Drops objdump's headers, function-label lines,
-- and branch/call/ret/loop instructions (their targets reference symbols
-- undefined in this snippet). Lossy on branchy code, but mca models
-- straight-line port/latency pressure, not control flow.
local MCA_STRIP = "sed -E "
  .. "-e '/^[[:space:]]*$/d' "
  .. "-e '/: *file format/d' "
  .. "-e '/^Disassembly of section/d' "
  .. "-e '/^[0-9a-f]+ <.*>:$/d' "
  .. "-e 's/^[[:space:]]*[0-9a-f]+:[[:space:]]*//' "
  .. "-e '/\\.cfi_/d' "
  .. "-e '/^[[:space:]]*nop/d' "
  .. "-e '/^[[:space:]]*(j[a-z]*|call|ret[a-z]*|loop[a-z]*)([[:space:]]|$)/d'"

-- llvm-mca's "Critical sequence" view sits between the summary/bottleneck
-- section and the -all-stats aggregate tables (Dispatch/Scheduler/Retire/
-- Register File stats), so mca is split into two tasks instead of one
-- mixed dump. MCA_DROP_CRITSEQ removes the whole critical-sequence table
-- (used by "mca: throughput", which keeps the aggregate stats). Detects
-- the table by indentation: every row in it is either blank, indented, or
-- a "+----" connector; the next real section header starts at column 0.
local MCA_DROP_CRITSEQ = "awk '"
  .. "/^Critical sequence/ { skip = 1; next } "
  .. "skip && ($0 ~ /^[[:space:]]/ || $0 ~ /^$/ || $0 ~ /\\+----/) { next } "
  .. "{ skip = 0; print }'"

-- Most critical-sequence rows carry no annotation at all: only the ones
-- marked with a "+----" connector explain a stall (register or resource
-- dependency). Used by "mca: critical path", which drops -all-stats so
-- nothing follows the critical-sequence table (safe to filter to end).
local MCA_CRITSEQ_ONLY = "awk '/^Critical sequence/{in_seq=1} "
  .. "{ if (!in_seq) { print; next } "
  .. "if ($0 ~ /\\+----/ || $0 ~ /Dependency Information/ || $0 ~ /^Critical sequence/ || $0 ~ /^$/) print }'"

-- Flag presets for "C++: compile". Each entry is { mode name, extra g++
-- flags, whether to emit -o <bin> }. asm-dump skips -o since -S writes
-- <file>.s next to the source. pgo-generate/pgo-use stay separate modes:
-- sequential two-step workflow, not interchangeable options.
local COMPILE_MODES = {
  { "debug", { "-g", "-O0", "-Wall", "-Wextra", "-Wconversion", "-Wsign-conversion" }, true },
  { "release", { "-O3", "-march=native" }, true },
  { "release+lto", { "-O3", "-march=native", "-flto" }, true },
  { "fast-math (breaks IEEE)", { "-O3", "-march=native", "-ffast-math" }, true },
  { "asan+ubsan", { "-g", "-O1", "-fsanitize=address,undefined", "-fno-omit-frame-pointer" }, true },
  { "tsan", { "-g", "-O1", "-fsanitize=thread" }, true },
  { "asm-dump (.s)", { "-O3", "-march=native", "-S", "-fverbose-asm" }, false },
  { "vec-report", { "-O3", "-march=native", "-fopt-info-vec", "-fopt-info-vec-missed" }, true },
  { "pgo-generate", { "-O3", "-fprofile-generate" }, true },
  { "pgo-use", { "-O3", "-fprofile-use", "-fprofile-correction" }, true },
}
local COMPILE_MODE_CHOICES = {}
local COMPILE_MODE_BY_NAME = {}
for _, m in ipairs(COMPILE_MODES) do
  COMPILE_MODE_CHOICES[#COMPILE_MODE_CHOICES + 1] = m[1]
  COMPILE_MODE_BY_NAME[m[1]] = m
end

-- Each def: { name, desc?, tags?, quickfix?, needs_bin?, condition_callback?,
--             params?, build = fn(ctx, params) -> task }
-- build() returns a task-opts table; cmd may be a list (exec directly) or a
-- string (run through the shell, so pipes/globs/&& work). It may also set
-- info_lines (array of strings), extra facts the shared builder echoes
-- before running (e.g. a snapshot's age, alongside the binary's).
local defs = {
  -----------------------------------------------------------------------------
  -- Compile (single template, "mode" param picks the flag preset)
  -----------------------------------------------------------------------------
  {
    name = "C++: compile",
    desc = "Pick a build mode: debug / release(+lto) / fast-math / sanitizers / asm-dump / vec-report / pgo",
    tags = { "BUILD" },
    quickfix = true,
    params = {
      mode = {
        type = "enum",
        name = "mode",
        choices = COMPILE_MODE_CHOICES,
        default = "debug",
      },
    },
    build = function(c, p)
      local m = COMPILE_MODE_BY_NAME[p.mode] or COMPILE_MODE_BY_NAME["debug"]
      local cmd = { "g++" }
      vim.list_extend(cmd, m[2])
      cmd[#cmd + 1] = STD
      cmd[#cmd + 1] = c.file
      if m[3] then
        cmd[#cmd + 1] = "-o"
        cmd[#cmd + 1] = c.bin
      end
      return { cmd = cmd }
    end,
  },

  -----------------------------------------------------------------------------
  -- Run
  -----------------------------------------------------------------------------
  {
    name = "C++: run",
    tags = { "RUN" },
    needs_bin = true,
    build = function(c, p)
      local bin = resolve_bin(c, p)
      return { cmd = { bin } }
    end,
  },
  {
    name = "C++: build+run",
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
    -- -ddd adds counters on top of perf's default metric group; an
    -- explicit -e list replaces that group instead, which is why the old
    -- "stat detailed" showed less info than plain "stat".
    name = "perf: stat",
    desc = "-ddd: max detail (adds counters on top of perf's default metrics)",
    needs_bin = true,
    build = function(c, p)
      local _, ebin = resolve_bin(c, p)
      -- perf's report goes to stderr; > /dev/null only silences the
      -- target binary's own stdout.
      return { cmd = string.format("perf stat -d -d -d %s > /dev/null", ebin) }
    end,
  },
  {
    -- Fixed raw -e list, invisible in a normal profile: 4K aliasing, split
    -- loads/stores, failed store-forwarding, DSB fallout, denormal/FP
    -- assists, per-port dispatch pressure. Reads 0 on non-SIMD code.
    name = "perf: stat microarch",
    desc = "split/misaligned loads, op-cache fallout, FP fill/spill faults, vector-op count. SIMD-relevant, 0 on scalar code",
    needs_bin = true,
    build = function(c, p)
      local _, ebin = resolve_bin(c, p)
      local vendor = cpu_vendor()
      local event_list
      if vendor == "amd" then
        -- Zen has no DSB/per-port-dispatch equivalent as simple named
        -- events; op_cache_hit_miss approximates DSB fallout,
        -- fp_disp_faults approximates FP assists, ls_misal_loads
        -- approximates split/4K-alias.
        event_list = {
          "ls_misal_loads.ma4k",
          "ls_misal_loads.ma64",
          "ls_mab_alloc.load_store_allocations",
          "op_cache_hit_miss.op_cache_hit",
          "op_cache_hit_miss.op_cache_miss",
          "fp_disp_faults.sse_avx_all",
          "fp_ret_sse_avx_ops.all",
          "cycles",
          "instructions",
          "branch-misses",
        }
      else
        -- Intel default, also the fallback for "unknown".
        event_list = {
          "mem_inst_retired.split_loads",
          "mem_inst_retired.split_stores",
          "ld_blocks_partial.address_alias",
          "ld_blocks.store_forward",
          "idq.dsb_uops",
          "idq.mite_uops",
          "uops_dispatched.port_0",
          "uops_dispatched.port_1",
          "uops_dispatched.port_5",
          "uops_dispatched.port_6",
          "fp_arith_inst_retired.256b_packed_single",
          "fp_arith_inst_retired.512b_packed_single",
          "fp_assist.any",
          "cycles",
          "instructions",
          "branch-misses",
        }
      end
      local events = table.concat(event_list, ",")
      return { cmd = string.format("perf stat -e %s %s > /dev/null", events, ebin) }
    end,
  },
  {
    -- Self-contained like c2c below: records fresh into /tmp/perf.data
    -- each run instead of depending on a separate record task.
    -- Without --percent-limit, perf report lists every symbol it ever
    -- saw a sample for, including kernel/library noise at 0.00% overhead:
    -- 700+ entries on a real run, only the top ~20 carrying any signal.
    name = "perf: report",
    needs_bin = true,
    build = function(c, p)
      local _, ebin = resolve_bin(c, p)
      return {
        cmd = string.format(
          "perf record -o /tmp/perf.data -- %s > /dev/null "
            .. "&& PAGER=cat perf report -i /tmp/perf.data --stdio --percent-limit 0.5",
          ebin
        ),
      }
    end,
  },
  {
    -- A symbol narrows perf annotate to one function, shown in full: a
    -- single function is naturally bounded, and every line stays in its
    -- real sequence so the surrounding code still explains why a hot
    -- instruction is hot. Without a symbol, --percent-limit is perf's own
    -- function-selection cutoff: which functions get annotated at all,
    -- not which lines inside a function survive. Neither path strips
    -- lines out of a function's middle the way a line-level percent
    -- filter would.
    name = "perf: annotate",
    desc = "Give a symbol for one full function, or set min-percent to cap which functions get annotated",
    needs_bin = true,
    params = {
      symbol = { type = "string", name = "symbol", desc = "function symbol (blank = all functions above min-percent)", optional = true },
      min_percent = {
        type = "string",
        name = "min-percent",
        desc = "skip functions under this overhead percent (ignored if symbol is set)",
        default = "2",
        optional = true,
      },
    },
    build = function(c, p)
      local _, ebin = resolve_bin(c, p)
      local annotate = "perf annotate -i /tmp/perf.data"
      if p.symbol and p.symbol ~= "" then
        annotate = annotate .. " " .. vim.fn.shellescape(p.symbol)
      else
        local limit = (p.min_percent and p.min_percent ~= "") and p.min_percent or "2"
        annotate = annotate .. " --percent-limit " .. vim.fn.shellescape(limit)
      end
      annotate = annotate .. " --stdio"
      return {
        cmd = string.format("perf record -o /tmp/perf.data -- %s > /dev/null && PAGER=cat %s", ebin, annotate),
      }
    end,
  },
  {
    -- One line per sampled event by design (this is the flamegraph
    -- feedstock, not meant to be read directly): 20K+ lines on a real
    -- run. Full output still goes to a file for actual tool use; only a
    -- head sample is shown here.
    name = "perf: script",
    desc = "Raw dump, feeds flamegraph tooling. Full output written to file, only a head sample shown",
    needs_bin = true,
    build = function(c, p)
      local _, ebin = resolve_bin(c, p)
      -- PAGER=cat: perf script invokes $PAGER even with --stdio, and
      -- overseer's task pane looks like a real tty to it.
      return {
        cmd = string.format(
          "perf record -o /tmp/perf.data -- %s > /dev/null "
            .. "&& PAGER=cat perf script -i /tmp/perf.data > /tmp/perf-script.out "
            .. "&& echo \"output: /tmp/perf-script.out ($(wc -l < /tmp/perf-script.out) lines total, showing first 200)\" "
            .. "&& head -200 /tmp/perf-script.out",
          ebin
        ),
      }
    end,
  },
  {
    name = "perf: flamegraph",
    desc = "Needs Brendan Gregg's FlameGraph scripts on PATH (stackcollapse-perf.pl, flamegraph.pl)",
    condition_callback = function()
      return vim.fn.executable "stackcollapse-perf.pl" == 1 and vim.fn.executable "flamegraph.pl" == 1
    end,
    needs_bin = true,
    build = function(c, p)
      local _, ebin = resolve_bin(c, p)
      return {
        cmd = string.format(
          "perf record -o /tmp/perf.data -- %s > /dev/null && PAGER=cat perf script -i /tmp/perf.data "
            .. "| stackcollapse-perf.pl | flamegraph.pl > /tmp/flame.svg && echo output: /tmp/flame.svg",
          ebin
        ),
      }
    end,
  },
  {
    name = "perf: c2c",
    desc = "False-sharing / cache-line contention, record then report --stdio",
    needs_bin = true,
    build = function(c, p)
      local _, ebin = resolve_bin(c, p)
      -- PAGER=cat: perf c2c report doesn't fully honor --stdio and still
      -- invokes $PAGER, which blocks waiting for a keypress overseer never
      -- sends. Tried the interactive ncurses browser instead: same
      -- hardcoded fixed-width table wrap, plus fragile to render inside
      -- overseer's pane. Kept --stdio.
      return {
        cmd = string.format(
          "PAGER=cat perf c2c record -- %s > /dev/null && PAGER=cat perf c2c report --stdio",
          ebin
        ),
      }
    end,
  },

  -----------------------------------------------------------------------------
  -- bcc (Brendan Gregg's bpf tracing scripts), shown only when installed
  -----------------------------------------------------------------------------
  {
    -- Without a trailing duration, bcc tools run until Ctrl-C and only
    -- print on exit, which looks like a stuck "pending" task in overseer.
    name = "bcc: funccount",
    desc = "bcc funccount over the binary's user functions (needs root/bcc)",
    condition_callback = function()
      return has_bcc "funccount"
    end,
    needs_bin = true,
    params = {
      pattern = {
        type = "string",
        name = "pattern",
        desc = "function glob within the binary",
        default = "*",
        optional = true,
      },
      duration = {
        type = "string",
        name = "duration",
        desc = "seconds before it self-terminates and prints",
        default = "5",
        optional = true,
      },
    },
    build = function(c, p)
      local tool = pick { "funccount-bpfcc", "funccount" }
      local pat = (p.pattern and p.pattern ~= "") and p.pattern or "*"
      local dur = (p.duration and p.duration ~= "") and p.duration or "5"
      local bin = resolve_bin(c, p)
      -- uprobe pattern form: '<binary>:<glob>'.
      -- sudo: eBPF loading needs CAP_BPF/CAP_SYS_ADMIN and a raised
      -- RLIMIT_MEMLOCK; overseer's task pane is a real pty so sudo can
      -- prompt for the password there.
      return { cmd = { "sudo", tool, bin .. ":" .. pat, dur } }
    end,
  },
  {
    -- funclatency only attaches a uprobe and waits, it never launches the
    -- target. "no data returned" usually means the traced function was
    -- never called during the window: run the binary elsewhere while this
    -- task is active.
    name = "bcc: funclatency",
    desc = "bcc funclatency: attaches + waits, run the binary yourself elsewhere during the window (needs root/bcc)",
    condition_callback = function()
      return has_bcc "funclatency"
    end,
    needs_bin = true,
    params = {
      -- The libbpf-tools rewrite of funclatency (bcc-libbpf-tools on
      -- Arch/EndeavourOS) takes a single exact PROGRAM:FUNCTION symbol, no
      -- glob wildcards, and duration is -d, not a positional. Doesn't
      -- match the old bcc-python funccount/funclatency-bpfcc syntax.
      func = {
        type = "string",
        name = "function",
        desc = "exact function symbol within the binary (no globs)",
        default = "main",
        optional = true,
      },
      duration = {
        type = "string",
        name = "duration",
        desc = "seconds before it self-terminates and prints",
        default = "5",
        optional = true,
      },
    },
    build = function(c, p)
      local tool = pick { "funclatency-bpfcc", "funclatency" }
      local f = (p.func and p.func ~= "") and p.func or "main"
      local dur = (p.duration and p.duration ~= "") and p.duration or "5"
      local bin = resolve_bin(c, p)
      return { cmd = { "sudo", tool, "-d", dur, bin .. ":" .. f } }
    end,
  },

  -----------------------------------------------------------------------------
  -- asm: static disassembly, read directly off the linked binary
  -----------------------------------------------------------------------------
  {
    -- gdb's disassemble /s interleaves source more reliably on optimized
    -- code than objdump -dS, and degrades to address-only output when the
    -- binary lacks -g.
    name = "asm: disassemble",
    desc = "gdb disassemble /s. Reliable source interleaving even on optimized/SIMD code",
    needs_bin = true,
    params = SYMBOL_PARAM,
    build = function(c, p)
      local _, ebin = resolve_bin(c, p)
      local sym = (p.symbol and p.symbol ~= "") and p.symbol or "main"
      return {
        cmd = string.format(
          "gdb -batch -q -ex 'set disassembly-flavor intel' -ex %s %s",
          vim.fn.shellescape("disassemble /s " .. sym),
          ebin
        ),
      }
    end,
  },
  {
    -- Plain objdump listing of one symbol: no gdb, no -g needed, no
    -- source interleaving, no normalization. Distinct from "asm:
    -- disassemble" above (gdb, source-interleaved, needs debug info): this
    -- is the fast raw dump, addresses and mnemonics only.
    name = "asm: dump",
    desc = "Raw objdump listing of one symbol, addresses + mnemonics only",
    needs_bin = true,
    params = SYMBOL_PARAM,
    build = function(c, p)
      local _, ebin = resolve_bin(c, p)
      local sym = (p.symbol and p.symbol ~= "") and p.symbol or "main"
      return { cmd = objdump_cmd(ebin, sym) }
    end,
  },
  {
    name = "asm: create snapshot",
    desc = "Capture normalized disassembly before an edit; diff after rebuild instead of reproducing build flags",
    needs_bin = true,
    params = SYMBOL_PARAM,
    build = function(c, p)
      local _, ebin = resolve_bin(c, p)
      local sym = (p.symbol and p.symbol ~= "") and p.symbol or "main"
      return {
        cmd = string.format(
          "mkdir -p %s && %s | %s > %s/%s.txt && echo output: %s/%s.txt",
          ASM_SNAP_DIR,
          objdump_cmd(ebin, sym),
          SED_NORMALIZE,
          ASM_SNAP_DIR,
          sym,
          ASM_SNAP_DIR,
          sym
        ),
      }
    end,
  },
  {
    name = "asm: diff snapshot",
    needs_bin = true,
    params = SYMBOL_PARAM,
    build = function(c, p)
      local _, ebin = resolve_bin(c, p)
      local sym = (p.symbol and p.symbol ~= "") and p.symbol or "main"
      local snap_path = ASM_SNAP_DIR .. "/" .. sym .. ".txt"
      return {
        cmd = string.format(
          "%s | %s > /tmp/asm-diff-cur.txt && diff -u %s /tmp/asm-diff-cur.txt",
          objdump_cmd(ebin, sym),
          SED_NORMALIZE,
          vim.fn.shellescape(snap_path)
        ),
        info_lines = { "snapshot: " .. snap_path .. " created " .. human_age(vim.fn.getftime(snap_path)) },
      }
    end,
  },
  {
    -- Canned grep report over the raw disassembly, catches most SIMD
    -- regressions before a full diff is worth reading. Vector-only greps
    -- read 0 on scalar code.
    name = "asm: hazard scan",
    desc = "spills, xmm/ymm/zmm width splits, stray vzeroupper, gather/scatter, unfolded loads, div/sqrt, loop count",
    needs_bin = true,
    params = SYMBOL_PARAM,
    build = function(c, p)
      local _, ebin = resolve_bin(c, p)
      local sym = (p.symbol and p.symbol ~= "") and p.symbol or "main"
      local dump = objdump_cmd(ebin, sym) .. " > /tmp/asm-hazard-body.txt"
      local checks = {
        { "spills (vector op touching stack)", [[vmov[a-z]+ .*\[r[sb]p]] },
        { "xmm (128-bit) operands", "%xmm" },
        { "ymm (256-bit) operands", "%ymm" },
        { "zmm (512-bit) operands", "%zmm" },
        { "128/256-bit insert/extract (compiler split a wider op)", [[vinsert[fi]128|vextract[fi]128]] },
        { "vzeroupper (should cluster at exit, not in the body)", "vzeroupper" },
        { "gather/scatter (expected contiguous access?)", [[vgather|vscatter]] },
        { "div/sqrt (long-latency)", [[\bdiv|\bsqrt]] },
        { "fp_assist-prone convert chains", "vcvt" },
      }
      local parts = { "mkdir -p /tmp && " .. dump }
      for _, chk in ipairs(checks) do
        parts[#parts + 1] = string.format(
          "echo '== %s ==' && grep -Ec %s /tmp/asm-hazard-body.txt",
          chk[1],
          vim.fn.shellescape(chk[2])
        )
      end
      parts[#parts + 1] = "echo '== loop back-edges (unroll factor hint) ==' && grep -Ec '^\\s*[0-9a-f]+:\\s*j' /tmp/asm-hazard-body.txt"
      return { cmd = table.concat(parts, " ; ") }
    end,
  },

  -----------------------------------------------------------------------------
  -- mca / uica: static throughput modeling on a disassembled symbol
  -----------------------------------------------------------------------------
  {
    -- Split from the critical-path view below for readability: aggregate
    -- stats and a per-instruction critical-path trace don't read well
    -- mixed in one dump, and each needs different mca flags to stay small.
    name = "mca: throughput",
    desc = "Port pressure, dispatch/scheduler/retire stats. llvm-mca on the normalized disassembly",
    condition_callback = function()
      return vim.fn.executable "llvm-mca" == 1
    end,
    needs_bin = true,
    params = SYMBOL_PARAM,
    build = function(c, p)
      local _, ebin = resolve_bin(c, p)
      local sym = (p.symbol and p.symbol ~= "") and p.symbol or "main"
      -- No -timeline, -instruction-info=false, -resource-pressure=false:
      -- each is a per-instruction listing (thousands of lines on a whole
      -- function). MCA_DROP_CRITSEQ removes the critical-sequence table
      -- too (its own task below), leaving just the summary and the
      -- -all-stats aggregate tables.
      return {
        cmd = string.format(
          "%s | %s | { echo '.intel_syntax noprefix'; cat -; } | "
            .. "llvm-mca -mcpu=native -iterations=100 -bottleneck-analysis -all-stats "
            .. "-instruction-info=false -resource-pressure=false | %s",
          objdump_cmd(ebin, sym),
          MCA_STRIP,
          MCA_DROP_CRITSEQ
        ),
      }
    end,
  },
  {
    -- No -all-stats: with it off, nothing follows the critical-sequence
    -- table, so MCA_CRITSEQ_ONLY can safely filter to end of output.
    name = "mca: critical path",
    desc = "Dependency chain that bounds throughput. llvm-mca critical-sequence view, annotated rows only",
    condition_callback = function()
      return vim.fn.executable "llvm-mca" == 1
    end,
    needs_bin = true,
    params = SYMBOL_PARAM,
    build = function(c, p)
      local _, ebin = resolve_bin(c, p)
      local sym = (p.symbol and p.symbol ~= "") and p.symbol or "main"
      return {
        cmd = string.format(
          "%s | %s | { echo '.intel_syntax noprefix'; cat -; } | "
            .. "llvm-mca -mcpu=native -iterations=100 -bottleneck-analysis "
            .. "-instruction-info=false -resource-pressure=false | %s",
          objdump_cmd(ebin, sym),
          MCA_STRIP,
          MCA_CRITSEQ_ONLY
        ),
      }
    end,
  },
  {
    -- Models the uop cache (DSB/MITE/LSD) and 32-byte fetch boundaries,
    -- which llvm-mca does not. Unrolled vector loops routinely lose
    -- 20-30% there.
    name = "uica: throughput",
    desc = "uiCA on the normalized disassembly, catches DSB/fetch-boundary losses mca can't see",
    condition_callback = function()
      return vim.fn.executable "uiCA.py" == 1 or vim.fn.executable "uica" == 1
    end,
    needs_bin = true,
    params = vim.tbl_extend("force", SYMBOL_PARAM, {
      arch = { type = "string", name = "arch", desc = "uiCA -arch code, e.g. SKX/ICL/SPR", default = "SKX" },
    }),
    build = function(c, p)
      local _, ebin = resolve_bin(c, p)
      local sym = (p.symbol and p.symbol ~= "") and p.symbol or "main"
      local tool = pick { "uiCA.py", "uica" }
      return {
        cmd = string.format(
          "%s | %s | %s -arch %s -TP",
          objdump_cmd(ebin, sym),
          MCA_STRIP,
          tool,
          vim.fn.shellescape(p.arch)
        ),
      }
    end,
  },

  -----------------------------------------------------------------------------
  -- pahole: struct/class layout (needs -g in the binary)
  -----------------------------------------------------------------------------
  {
    name = "pahole: layout",
    desc = "Padding/holes/cacheline boundaries for a type; blank type = whole-binary padding sweep",
    condition_callback = function()
      return vim.fn.executable "pahole" == 1
    end,
    needs_bin = true,
    params = TYPE_PARAM,
    build = function(c, p)
      local _, ebin = resolve_bin(c, p)
      -- -F dwarf: recent pahole tries BTF first and can misreport types on
      -- a mixed-info ELF. Still needs the binary built with -g.
      if p.type_name and p.type_name ~= "" then
        local t = vim.fn.shellescape(p.type_name)
        return {
          cmd = string.format(
            "pahole -F dwarf -C %s %s && echo '--- reorganized ---' && pahole -F dwarf -C %s --reorganize %s",
            t, ebin, t, ebin
          ),
        }
      end
      return { cmd = string.format("pahole -F dwarf --hole_size_ge=8 %s", ebin) }
    end,
  },

  -----------------------------------------------------------------------------
  -- valgrind
  -----------------------------------------------------------------------------
  {
    -- valgrind's report goes to stderr; > /dev/null silences only the
    -- target binary's own stdout.
    name = "valgrind: memcheck",
    desc = "--leak-check=full --show-leak-kinds=all --track-origins=yes",
    needs_bin = true,
    build = function(c, p)
      local _, ebin = resolve_bin(c, p)
      return {
        cmd = string.format(
          "valgrind --leak-check=full --show-leak-kinds=all --track-origins=yes %s > /dev/null",
          ebin
        ),
      }
    end,
  },
  {
    -- cachegrind is cut: it simulates a cache model that isn't the actual
    -- hardware. "perf: stat microarch" measures the real cache/memory
    -- behavior instead; callgrind gives deterministic instruction counts a
    -- simulated cache model can't improve on.
    name = "valgrind: callgrind",
    needs_bin = true,
    build = function(c, p)
      local _, ebin = resolve_bin(c, p)
      -- Keeps output out of the project directory, same as every other
      -- tool here.
      return {
        cmd = string.format(
          "valgrind --tool=callgrind --callgrind-out-file=/tmp/callgrind.out.%%p %s > /dev/null "
            .. "&& echo output: $(ls -t /tmp/callgrind.out.* | head -1)",
          ebin
        ),
      }
    end,
  },
  {
    -- --threshold=100 --auto=no: deterministic per-function Ir counts, no
    -- auto-annotation noise. Snapshot + diff gives a noise-immune
    -- before/after with no benchmark harness or core pinning. Slow but
    -- exact.
    name = "valgrind: callgrind annotate",
    build = function()
      return { cmd = "callgrind_annotate --threshold=100 --auto=no $(ls -t /tmp/callgrind.out.* | head -1)" }
    end,
  },
  {
    name = "valgrind: massif",
    needs_bin = true,
    build = function(c, p)
      local _, ebin = resolve_bin(c, p)
      return {
        cmd = string.format(
          "valgrind --tool=massif --massif-out-file=/tmp/massif.out.%%p %s > /dev/null "
            .. "&& echo output: $(ls -t /tmp/massif.out.* | head -1)",
          ebin
        ),
      }
    end,
  },
  {
    name = "valgrind: massif print",
    build = function()
      return { cmd = "ms_print $(ls -t /tmp/massif.out.* | head -1)" }
    end,
  },
  {
    name = "valgrind: helgrind",
    desc = "Thread race detection, alternative to tsan",
    needs_bin = true,
    build = function(c, p)
      local _, ebin = resolve_bin(c, p)
      return { cmd = string.format("valgrind --tool=helgrind %s > /dev/null", ebin) }
    end,
  },

  -----------------------------------------------------------------------------
  -- toplev (pmu-tools): top-down microarchitecture attribution
  -----------------------------------------------------------------------------
  {
    name = "toplev: attribution",
    desc = "Frontend/backend/bad-speculation/retiring breakdown, wraps the binary as the run command",
    condition_callback = function()
      return vim.fn.executable "toplev.py" == 1 or vim.fn.executable "toplev" == 1
    end,
    needs_bin = true,
    build = function(c, p)
      local _, ebin = resolve_bin(c, p)
      local tool = pick { "toplev.py", "toplev" }
      return { cmd = string.format("%s -l3 --no-desc --single-thread -- %s", tool, ebin) }
    end,
  },

  -----------------------------------------------------------------------------
  -- sde: Intel Software Development Emulator
  -----------------------------------------------------------------------------
  {
    -- Deterministic dynamic instruction histogram by category/ISA
    -- extension: a noise-free A/B metric. Snapshot + diff answers "did the
    -- rewrite remove shuffles" with no benchmark harness or timing
    -- discipline.
    name = "sde: mix",
    condition_callback = function()
      return vim.fn.executable "sde64" == 1
    end,
    needs_bin = true,
    build = function(c, p)
      local _, ebin = resolve_bin(c, p)
      return {
        cmd = string.format(
          "sde64 -mix -omix /tmp/sde-mix.out -- %s > /dev/null && echo output: /tmp/sde-mix.out && cat /tmp/sde-mix.out",
          ebin
        ),
      }
    end,
  },
  {
    name = "sde: ast",
    desc = "Detects ~70-cycle stalls from dirty upper-register state on AVX/SSE transitions",
    condition_callback = function()
      return vim.fn.executable "sde64" == 1
    end,
    needs_bin = true,
    build = function(c, p)
      local _, ebin = resolve_bin(c, p)
      -- -ast writes its report to a file, not stdout.
      return {
        cmd = string.format(
          "sde64 -ast -oast /tmp/sde-ast.out -- %s > /dev/null && echo output: /tmp/sde-ast.out && cat /tmp/sde-ast.out",
          ebin
        ),
      }
    end,
  },
  {
    name = "sde: mask profile",
    desc = "Shows lanes you compute and discard under a mask, 0/no-op on non-AVX-512 code",
    condition_callback = function()
      return vim.fn.executable "sde64" == 1
    end,
    needs_bin = true,
    build = function(c, p)
      local _, ebin = resolve_bin(c, p)
      -- -odyn_mask_profile also writes to a file, same as -ast/-oast.
      return {
        cmd = string.format(
          "sde64 -dyn_mask_profile -odyn_mask_profile /tmp/sde-dyn-mask-profile.txt -- %s > /dev/null "
            .. "&& echo output: /tmp/sde-dyn-mask-profile.txt && cat /tmp/sde-dyn-mask-profile.txt",
          ebin
        ),
      }
    end,
  },
  {
    name = "sde: emulate",
    desc = "Run on an ISA level this machine lacks (SKX/SPR/GNR/...)",
    condition_callback = function()
      return vim.fn.executable "sde64" == 1
    end,
    needs_bin = true,
    params = {
      arch = { type = "string", name = "arch", desc = "sde64 target flag suffix, e.g. skx/spr/gnr", default = "spr" },
    },
    build = function(c, p)
      local _, ebin = resolve_bin(c, p)
      local arch = (p.arch and p.arch ~= "") and p.arch or "spr"
      return { cmd = string.format("sde64 -%s -- %s", arch, ebin) }
    end,
  },

  -----------------------------------------------------------------------------
  -- bloaty: binary size, icache pressure, unintended inlining
  -----------------------------------------------------------------------------
  {
    -- "symbols" works off the ELF symbol table, no debug info needed.
    -- "compileunits" also requires DWARF and fails outright without -g,
    -- which most binaries here lack (see the justfile hpc flags).
    name = "bloaty: sizes",
    condition_callback = function()
      return vim.fn.executable "bloaty" == 1
    end,
    needs_bin = true,
    build = function(c, p)
      local _, ebin = resolve_bin(c, p)
      return { cmd = string.format("bloaty -d symbols -n 40 %s", ebin) }
    end,
  },
  {
    name = "bloaty: create snapshot",
    desc = "Capture the current binary before a rebuild, for the diff task below",
    condition_callback = function()
      return vim.fn.executable "bloaty" == 1
    end,
    needs_bin = true,
    build = function(c, p)
      local bin, ebin = resolve_bin(c, p)
      local snap_name = vim.fn.fnamemodify(bin, ":t")
      return {
        cmd = string.format(
          "mkdir -p %s && cp %s %s/%s && echo output: %s/%s",
          BLOATY_SNAP_DIR,
          ebin,
          BLOATY_SNAP_DIR,
          snap_name,
          BLOATY_SNAP_DIR,
          snap_name
        ),
      }
    end,
  },
  {
    name = "bloaty: diff snapshot",
    condition_callback = function()
      return vim.fn.executable "bloaty" == 1
    end,
    needs_bin = true,
    build = function(c, p)
      local bin, ebin = resolve_bin(c, p)
      local snap_name = vim.fn.fnamemodify(bin, ":t")
      local snap_path = BLOATY_SNAP_DIR .. "/" .. snap_name
      return {
        cmd = string.format("bloaty %s -- %s -d symbols -n 40", ebin, vim.fn.shellescape(snap_path)),
        info_lines = { "snapshot: " .. snap_path .. " created " .. human_age(vim.fn.getftime(snap_path)) },
      }
    end,
  },

  -----------------------------------------------------------------------------
  -- clang-tidy / static analysis (standalone file, no compile_commands.json)
  -----------------------------------------------------------------------------
  {
    -- clang-tidy enables no checks by default; without a project
    -- .clang-tidy file it just errors. Forces a default set so it works
    -- standalone.
    name = "clang-tidy: check",
    build = function(c)
      return { cmd = { "clang-tidy", "--checks=" .. CLANG_TIDY_CHECKS, c.file, "--", STD } }
    end,
  },
  {
    name = "clang-tidy: fix",
    build = function(c)
      return { cmd = { "clang-tidy", "--checks=" .. CLANG_TIDY_CHECKS, c.file, "--fix", "--", STD } }
    end,
  },

  -----------------------------------------------------------------------------
  -- rr
  -----------------------------------------------------------------------------
  {
    name = "rr: record",
    needs_bin = true,
    build = function(c, p)
      local bin = resolve_bin(c, p)
      return { cmd = { "rr", "record", bin } }
    end,
  },
  {
    name = "rr: replay",
    build = function()
      return { cmd = { "rr", "replay" } }
    end,
  },
}

-- Run from the plugin config (see lua/plugins/init.lua). Registers every
-- template and records its name for the telescope picker.
function M.setup()
  local overseer = require "overseer"

  overseer.setup {
    templates = {}, -- registered below, skip the bundled defaults
    task_list = {
      direction = "bottom",
      default_detail = 1,
    },
  }

  -- Every task's output buffer gets filetype "OverseerOutput". Some output
  -- (perf c2c's cacheline tables, sde -mix histograms) is wider than any
  -- reasonable window; default wrap mangles it into ragged lines
  -- regardless of window width. nowrap plus horizontal scroll (zl/zL, or
  -- mouse sideways scroll) keeps rows intact.
  vim.api.nvim_create_autocmd("FileType", {
    pattern = "OverseerOutput",
    desc = "Don't wrap wide task output (perf c2c, sde -mix, ...)",
    callback = function()
      vim.wo[0].wrap = false
      vim.wo[0].sidescrolloff = 4
    end,
  })

  for _, def in ipairs(defs) do
    local condition = { filetype = { "cpp", "c" } }
    if def.condition_callback then
      condition.callback = def.condition_callback
    end

    -- needs_bin defs get a fresh "binary" param each build (never cached)
    -- so the desc hint reflects this buffer's guessed path, and the param
    -- stays required so overseer always prompts for it.
    local params = def.params or {}
    if def.needs_bin then
      params = function()
        local c = ctx()
        local guess = vim.fn.fnamemodify(c.bin, ":~")
        local schema = {}
        for k, v in pairs(def.params or {}) do
          schema[k] = v
        end
        schema.bin = {
          type = "string",
          name = "binary",
          desc = "path to executable to run (blank = " .. guess .. ")",
          optional = false,
        }
        return schema
      end
    end

    overseer.register_template {
      name = def.name,
      desc = def.desc,
      tags = def.tags,
      params = params,
      condition = condition,
      builder = function(params)
        local c = ctx()
        local task = def.build(c, params)
        task.name = task.name or def.name
        task.cwd = task.cwd or c.dir
        if def.quickfix then
          task.components = task.components
            or { { "on_output_quickfix", open_on_error = true }, "default" }
        end

        -- Every task's first output line is the literal command it's
        -- running, and every task wrapping a binary shows that binary's
        -- build age (defs can add more info_lines, e.g. a snapshot's own
        -- age for the diff tasks) so a stale artifact is obvious upfront.
        local shell_cmd = to_shell_str(task.cmd)
        local info = { "+ " .. shorten_display(shell_cmd) }
        if def.needs_bin then
          local bin_path = (params and params.bin and params.bin ~= "") and vim.fn.expand(params.bin) or c.bin
          info[#info + 1] = "bin: " .. shorten_display(bin_path) .. " built " .. human_age(vim.fn.getftime(bin_path))
        end
        if task.info_lines then
          for _, l in ipairs(task.info_lines) do
            info[#info + 1] = shorten_display(l)
          end
        end
        -- %s\n\n: a blank line after each preamble line (command, bin
        -- age, any info_lines) and one more before the command's own
        -- output starts, so the sections don't run together.
        local preamble = "printf '%s\\n\\n' " .. table.concat(vim.tbl_map(vim.fn.shellescape, info), " ")
        task.cmd = preamble .. " && " .. shell_cmd

        return task
      end,
    }

    -- condition_callback gates overseer's own picker/:OverseerRun, but the
    -- custom telescope picker below reads M._names directly. Without this
    -- check, tools that aren't installed still showed up and failed with
    -- "command not found" when picked.
    if not def.condition_callback or def.condition_callback() then
      M._names[#M._names + 1] = def.name
      if def.needs_bin then
        M._needs_bin[def.name] = true
      end
    end
  end
end

-- <leader>oo entry point: fuzzy-search the C/C++ templates in a Telescope
-- picker and run the chosen one. Requiring overseer here lazy-loads the
-- plugin, which runs M.setup() and fills _names.
function M.telescope_run()
  local ok_overseer, overseer = pcall(require, "overseer")
  if not ok_overseer then
    vim.notify("overseer.nvim is not available", vim.log.levels.ERROR)
    return
  end

  local ok_telescope, pickers = pcall(require, "telescope.pickers")
  if not ok_telescope then
    vim.notify("telescope not found, falling back to :OverseerRun", vim.log.levels.WARN)
    vim.cmd "OverseerRun"
    return
  end

  local finders = require "telescope.finders"
  local conf = require("telescope.config").values
  local actions = require "telescope.actions"
  local action_state = require "telescope.actions.state"
  local themes = require "telescope.themes"

  -- Remember the buffer we launched from so the template builds against
  -- it, not telescope's prompt buffer.
  local src_buf = vim.api.nvim_get_current_buf()

  -- Size the picker to the longest template name plus padding, capped at
  -- 70% of the terminal width.
  local longest = 0
  for _, n in ipairs(M._names) do
    longest = math.max(longest, #n)
  end
  local width = math.min(longest + 10, math.floor(vim.o.columns * 0.7))

  pickers
    .new(themes.get_dropdown { layout_config = { width = width, height = 0.6 } }, {
      prompt_title = "Overseer: C/C++ tasks",
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
          local name = entry[1]
          if M._needs_bin[name] then
            -- Bypasses overseer's own text-only param form: vim.ui.input
            -- gives real file-path completion, rooted at the cwd Neovim
            -- started in.
            vim.ui.input({
              prompt = "Binary to run: ",
              default = vim.fn.getcwd() .. "/",
              completion = "file",
            }, function(path)
              if not path or path == "" then
                return
              end
              overseer.run_task { name = name, params = { bin = path } }
            end)
          else
            overseer.run_task { name = name }
          end
        end)
        return true
      end,
    })
    :find()
end

return M
