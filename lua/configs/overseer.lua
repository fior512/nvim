-- Overseer task templates for C/C++ (HPC) workflows.
--
-- Two kinds of defs:
--   compile/build tasks operate on the current buffer (ctx.file/.bin/.dir,
--   classic vim %, %:r, %:h expansions), require filetype cpp/c, and cwd to
--   the buffer's directory.
--   needs_bin = true tasks (perf, valgrind, mca, asm, ...) take an explicit
--   "binary" param instead, work without any C/C++ buffer open, and cwd to
--   Neovim's own cwd (project root).
--
-- This module does not `require("overseer")` at the top level: it is
-- required by mappings.lua to reach M.telescope_run(), and pulling in
-- overseer here would trigger lazy-load before M is returned, recursing
-- through the plugin's `config`. overseer is required lazily inside
-- M.setup() (run from the plugin `config`) and M.telescope_run().

local M = {}
M._names = {} -- template names, populated by M.setup(), consumed by the picker
-- name -> ordered list of { key, label, completion?, default? } prompts.
-- Every def that needs input from the user goes through the same chained
-- vim.ui.input flow in the custom telescope picker below: only the fields
-- asked differ (binary+args, a symbol, two file paths, ...), never the
-- mechanism.
M._prompts = {}

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

-- bat ships its own fixed palettes; none of them is this config's actual
-- colorscheme. Generates a bat .tmTheme from the *live* highlight groups
-- instead, so "codebase: find definition" (the only task piping through
-- bat) renders in the same colors as a normal code buffer, not an
-- approximation. Re-synced on every invocation of that task (cheap, and
-- picks up a mid-session :colorscheme change) rather than cached.
local BAT_THEME_NAME = "NvimSync"
local BAT_THEME_SCOPES = {
  { "comment", { "@comment", "Comment" } },
  { "string", { "@string", "String" } },
  { "constant.numeric", { "@number", "Number", "Constant" } },
  { "constant.language", { "@boolean", "Boolean", "Constant" } },
  { "keyword, keyword.control", { "@keyword", "Keyword", "Conditional", "Repeat", "Statement" } },
  { "keyword.operator", { "@operator", "Operator" } },
  { "storage.type, storage.modifier, entity.name.type, support.type", { "@type", "Type", "StorageClass", "Structure" } },
  { "entity.name.function", { "@function", "Function" } },
  { "variable, variable.parameter", { "@variable", "Identifier" } },
  { "meta.preprocessor, keyword.control.directive", { "Macro", "PreProc" } },
  { "punctuation", { "Delimiter", "Special" } },
}

local function hl_fg(name, depth)
  depth = depth or 0
  if depth > 6 then
    return nil
  end
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name })
  if not ok or not hl then
    return nil
  end
  if hl.fg then
    return string.format("#%06x", hl.fg)
  end
  if hl.link then
    return hl_fg(hl.link, depth + 1)
  end
  return nil
end

local function first_fg(names)
  for _, n in ipairs(names) do
    local c = hl_fg(n)
    if c then
      return c
    end
  end
  return nil
end

-- Writes the .tmTheme and rebuilds bat's cache; returns the theme name to
-- pass as --theme, or nil if bat isn't installed.
local function sync_bat_theme()
  if vim.fn.executable "bat" == 0 then
    return nil
  end
  local ok_hl, normal = pcall(vim.api.nvim_get_hl, 0, { name = "Normal" })
  local bg = (ok_hl and normal and normal.bg) and string.format("#%06x", normal.bg) or "#000000"
  local fg = (ok_hl and normal and normal.fg) and string.format("#%06x", normal.fg) or "#ffffff"

  local entries = {
    string.format(
      "<dict><key>settings</key><dict><key>background</key><string>%s</string>"
        .. "<key>foreground</key><string>%s</string></dict></dict>",
      bg,
      fg
    ),
  }
  for _, scope in ipairs(BAT_THEME_SCOPES) do
    local selector, groups = scope[1], scope[2]
    local color = first_fg(groups)
    if color then
      entries[#entries + 1] = string.format(
        "<dict><key>scope</key><string>%s</string><key>settings</key>"
          .. "<dict><key>foreground</key><string>%s</string></dict></dict>",
        selector,
        color
      )
    end
  end

  local xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    .. "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
    .. "<plist version=\"1.0\"><dict><key>name</key><string>"
    .. BAT_THEME_NAME
    .. "</string><key>settings</key><array>"
    .. table.concat(entries, "\n")
    .. "</array></dict></plist>\n"

  local theme_dir = vim.fn.expand "~/.config/bat/themes"
  vim.fn.mkdir(theme_dir, "p")
  vim.fn.writefile(vim.split(xml, "\n"), theme_dir .. "/" .. BAT_THEME_NAME .. ".tmTheme")
  vim.fn.system "bat cache --build"
  return BAT_THEME_NAME
end

-- Tools that operate on an already-built binary can't assume the current
-- buffer's "<file>:r" is the right executable: justfile/CMake/etc. projects
-- build elsewhere under a different name. defs with needs_bin = true get a
-- required "binary" param instead, independent of any open buffer.
local function resolve_bin(_, p)
  local bin = vim.fn.expand(p.bin)
  return bin, vim.fn.shellescape(bin)
end

-- defs with takes_args = true get an optional "args" param, appended
-- verbatim (unescaped: the user's own text is the shell's argv, quoting is
-- theirs to control) right after the binary. Blank means no arguments.
local function resolve_args(p)
  if p and p.args and p.args ~= "" then
    return " " .. p.args
  end
  return ""
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
local PERF_SNAP_DIR = "/tmp/perf-snap"
local OUTPUT_SNAP_DIR = "/tmp/output-snap"

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

-- git's own diff-highlight (ships with git, not always on PATH) turns a
-- normal line-per-line diff into full "-old line" / "+new line" pairs with
-- the actually-changed substring additionally reverse-video highlighted
-- within each: line-per-line context plus a pointer to what changed,
-- rather than git's --word-diff merging old/new into one line. Falls back
-- to --word-diff=plain (bracketed [-old-]/{+new+} markers, still readable
-- without color) if diff-highlight isn't found anywhere on this machine.
local function find_diff_highlight()
  if vim.fn.executable "diff-highlight" == 1 then
    return "diff-highlight"
  end
  local candidates = {
    "/usr/share/git/diff-highlight/diff-highlight",
    "/usr/share/git-core/contrib/diff-highlight/diff-highlight",
    "/usr/local/share/git-core/contrib/diff-highlight/diff-highlight",
  }
  for _, path in ipairs(candidates) do
    if vim.fn.filereadable(path) == 1 then
      return path
    end
  end
  return nil
end
local DIFF_HIGHLIGHT = find_diff_highlight()

-- --no-pager: git invokes $PAGER/less by default when stdout looks like a
-- tty, which overseer's task pane does, and it would otherwise hang
-- waiting for input (the same class of bug already hit and fixed for
-- perf elsewhere in this file). --no-index: works on any two files,
-- skips the repo requirement.
local function diff_cmd(old, new)
  local base = "git --no-pager diff --no-index --color=always -- " .. old .. " " .. new
  if DIFF_HIGHLIGHT then
    return base .. " | " .. DIFF_HIGHLIGHT
  end
  return "git --no-pager diff --no-index --color=always --word-diff=plain --word-diff-regex='\\S+' -- " .. old .. " " .. new
end

-- Extracts a whole function body given its ctags-reported signature line
-- (target): walks upward while the immediately preceding line is a
-- template<...> header, a requires clause, or an attribute like
-- [[nodiscard]] (stops at the first line that isn't one of those), then
-- walks forward from the signature counting braces to find the matching
-- close. Naive brace counting: a brace inside a string literal or comment
-- would throw it off, same class of limitation as SED_NORMALIZE/MCA_STRIP
-- above, not a full parser.
-- Computes the "first end" line range instead of printing the body itself,
-- so the caller can hand it to "bat --line-range" against the real file:
-- bat then shows real gutter line numbers, which piping extracted text
-- through bat via stdin can never do (bat has no way to know what line a
-- piped snippet started at).
local CTAGS_EXTRACT_RANGE_AWK = [==[{ lines[NR] = $0; last = NR } END { first = target; while (first > 1) { prev = lines[first - 1]; if (prev ~ /^[[:space:]]*template[[:space:]]*</ || prev ~ /^[[:space:]]*requires\y/ || prev ~ /^[[:space:]]*\[\[.*\]\][[:space:]]*$/) { first = first - 1 } else { break } } depth = 0; started = 0; for (i = first; i <= last; i++) { line = lines[i]; if (i >= target) { n = gsub(/{/, "{", line); m = gsub(/}/, "}", line); depth += n - m; if (depth > 0) started = 1; if (started && depth == 0) { print first" "i; exit } } } print first" "last }]==]

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

-- Flag presets for "C++: compile". Each entry is { mode name, extra
-- compiler flags, whether to emit -o <bin>, compiler override (default
-- g++) }. asm-dump skips -o since -S writes <file>.s next to the source.
-- pgo-generate/pgo-use stay separate modes: sequential two-step workflow,
-- not interchangeable options. opt-remarks needs clang++: its -Rpass
-- diagnostics are source-line annotated and more informative than gcc's
-- -fopt-info for missed-vectorize/missed-inline reasons.
local COMPILE_MODES = {
  { "debug", { "-g", "-O0", "-Wall", "-Wextra", "-Wconversion", "-Wsign-conversion" }, true },
  { "release", { "-O3", "-march=native" }, true },
  { "release+lto", { "-O3", "-march=native", "-flto" }, true },
  { "fast-math (breaks IEEE)", { "-O3", "-march=native", "-ffast-math" }, true },
  { "asan+ubsan", { "-g", "-O1", "-fsanitize=address,undefined", "-fno-omit-frame-pointer" }, true },
  { "tsan", { "-g", "-O1", "-fsanitize=thread" }, true },
  { "asm-dump (.s)", { "-O3", "-march=native", "-S", "-fverbose-asm" }, false },
  { "vec-report", { "-O3", "-march=native", "-fopt-info-vec", "-fopt-info-vec-missed" }, true },
  {
    "opt-remarks (clang, vec+inline)",
    {
      "-O3",
      "-march=native",
      "-Rpass=loop-vectorize,inline",
      "-Rpass-missed=loop-vectorize,inline",
      "-Rpass-analysis=loop-vectorize",
    },
    true,
    "clang++",
  },
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
    desc = "Pick a build mode: debug / release(+lto) / fast-math / sanitizers / asm-dump / vec-report / opt-remarks / pgo",
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
      local cmd = { m[4] or "g++" }
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
    takes_args = true,
    build = function(c, p)
      local _, ebin = resolve_bin(c, p)
      return { cmd = ebin .. resolve_args(p) }
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
  {
    -- For benchmark result/log files a run writes out: diff two of them
    -- directly, no snapshot slot involved (you already have both files on
    -- disk from separate runs).
    -- Executes the first binary and saves its stdout; "C++: diff output
    -- snapshot" below executes a second (possibly different) binary and
    -- diffs against it. Same snapshot/diff pairing already used for asm,
    -- bloaty, perf, just sourced from a run's actual output instead of a
    -- static file.
    name = "C++: create output snapshot",
    desc = "Run the binary, save its stdout for diffing against a second run",
    tags = { "RUN" },
    needs_bin = true,
    takes_args = true,
    build = function(c, p)
      local _, ebin = resolve_bin(c, p)
      return {
        cmd = string.format(
          "mkdir -p %s && %s%s > %s/output.txt && echo output: %s/output.txt",
          OUTPUT_SNAP_DIR,
          ebin,
          resolve_args(p),
          OUTPUT_SNAP_DIR,
          OUTPUT_SNAP_DIR
        ),
      }
    end,
  },
  {
    name = "C++: diff output snapshot",
    desc = "Run a (possibly different) binary, diff its stdout against the last output snapshot",
    tags = { "RUN" },
    needs_bin = true,
    takes_args = true,
    build = function(c, p)
      local _, ebin = resolve_bin(c, p)
      local snap_path = OUTPUT_SNAP_DIR .. "/output.txt"
      return {
        cmd = string.format(
          "%s%s > /tmp/output-diff-cur.txt && %s",
          ebin,
          resolve_args(p),
          diff_cmd(vim.fn.shellescape(snap_path), "/tmp/output-diff-cur.txt")
        ),
        info_lines = { "snapshot: " .. snap_path .. " created " .. human_age(vim.fn.getftime(snap_path)) },
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
    takes_args = true,
    build = function(c, p)
      local _, ebin = resolve_bin(c, p)
      -- perf's report goes to stderr; > /dev/null only silences the
      -- target binary's own stdout.
      return { cmd = string.format("perf stat -d -d -d %s%s > /dev/null", ebin, resolve_args(p)) }
    end,
  },
  {
    -- Fixed raw -e list, invisible in a normal profile: 4K aliasing, split
    -- loads/stores, failed store-forwarding, DSB fallout, denormal/FP
    -- assists, per-port dispatch pressure. Reads 0 on non-SIMD code.
    name = "perf: stat microarch",
    desc = "split/misaligned loads, op-cache fallout, FP fill/spill faults, vector-op count. SIMD-relevant, 0 on scalar code",
    needs_bin = true,
    takes_args = true,
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
      return { cmd = string.format("perf stat -e %s %s%s > /dev/null", events, ebin, resolve_args(p)) }
    end,
  },
  {
    -- Raw cache-miss surface, not a 4C (compulsory/capacity/conflict/
    -- coherence) classification: that needs a working-set-size sweep, not
    -- one run. Coherence misses specifically are covered by "perf: c2c".
    -- LLC-load-misses is unsupported on this AMD desktop part (no amd_l3
    -- uncore PMU exposed, verified via perf stat directly): the AMD path
    -- substitutes l2_request_g1 counters instead, since L3 isn't
    -- observable here at all.
    name = "perf: stat cache",
    desc = "Cache-miss surface across the hierarchy (not a 4C classification, see desc on each vendor path)",
    needs_bin = true,
    takes_args = true,
    build = function(c, p)
      local _, ebin = resolve_bin(c, p)
      local vendor = cpu_vendor()
      local event_list
      if vendor == "amd" then
        event_list = {
          "cache-references",
          "cache-misses",
          "L1-dcache-load-misses",
          "l2_request_g1.all",
          "l2_request_g1.all_dc",
          "dTLB-load-misses",
        }
      else
        event_list = {
          "cache-references",
          "cache-misses",
          "L1-dcache-load-misses",
          "LLC-loads",
          "LLC-load-misses",
          "dTLB-load-misses",
        }
      end
      local events = table.concat(event_list, ",")
      return { cmd = string.format("perf stat -e %s %s%s > /dev/null", events, ebin, resolve_args(p)) }
    end,
  },
  {
    -- Native L1 topdown (retiring/bad-speculation/frontend-bound/
    -- backend-bound), no toplev.py install needed. Verified working via
    -- "perf stat -M" on this AMD Zen4 (perf's --topdown flag itself only
    -- works with Intel's native TopdownL1+ groups and errors here).
    name = "perf: stat topdown",
    desc = "Level-1 topdown breakdown via perf's own -M metrics, works without toplev",
    needs_bin = true,
    takes_args = true,
    build = function(c, p)
      local _, ebin = resolve_bin(c, p)
      return {
        cmd = string.format(
          "perf stat -M retiring,bad_speculation,frontend_bound,backend_bound %s%s > /dev/null",
          ebin,
          resolve_args(p)
        ),
      }
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
    takes_args = true,
    build = function(c, p)
      local _, ebin = resolve_bin(c, p)
      return {
        cmd = string.format(
          "perf record -o /tmp/perf.data -- %s%s > /dev/null "
            .. "&& PAGER=cat perf report -i /tmp/perf.data --stdio --percent-limit 0.5",
          ebin,
          resolve_args(p)
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
    takes_args = true,
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
        cmd = string.format(
          "perf record -o /tmp/perf.data -- %s%s > /dev/null && PAGER=cat %s",
          ebin,
          resolve_args(p),
          annotate
        ),
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
    takes_args = true,
    build = function(c, p)
      local _, ebin = resolve_bin(c, p)
      -- PAGER=cat: perf script invokes $PAGER even with --stdio, and
      -- overseer's task pane looks like a real tty to it.
      return {
        cmd = string.format(
          "perf record -o /tmp/perf.data -- %s%s > /dev/null "
            .. "&& PAGER=cat perf script -i /tmp/perf.data > /tmp/perf-script.out "
            .. "&& echo \"output: /tmp/perf-script.out ($(wc -l < /tmp/perf-script.out) lines total, showing first 200)\" "
            .. "&& head -200 /tmp/perf-script.out",
          ebin,
          resolve_args(p)
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
    takes_args = true,
    build = function(c, p)
      local _, ebin = resolve_bin(c, p)
      return {
        cmd = string.format(
          "perf record -o /tmp/perf.data -- %s%s > /dev/null && PAGER=cat perf script -i /tmp/perf.data "
            .. "| stackcollapse-perf.pl | flamegraph.pl > /tmp/flame.svg && echo output: /tmp/flame.svg",
          ebin,
          resolve_args(p)
        ),
      }
    end,
  },
  {
    name = "perf: c2c",
    desc = "False-sharing / cache-line contention, record then report --stdio",
    needs_bin = true,
    takes_args = true,
    build = function(c, p)
      local _, ebin = resolve_bin(c, p)
      -- PAGER=cat: perf c2c report doesn't fully honor --stdio and still
      -- invokes $PAGER, which blocks waiting for a keypress overseer never
      -- sends. Tried the interactive ncurses browser instead: same
      -- hardcoded fixed-width table wrap, plus fragile to render inside
      -- overseer's pane. Kept --stdio.
      return {
        cmd = string.format(
          "PAGER=cat perf c2c record -- %s%s > /dev/null && PAGER=cat perf c2c report --stdio",
          ebin,
          resolve_args(p)
        ),
      }
    end,
  },
  {
    name = "perf: create snapshot",
    desc = "Capture the current binary's profile before an edit; diff after rebuild",
    needs_bin = true,
    takes_args = true,
    build = function(c, p)
      local _, ebin = resolve_bin(c, p)
      return {
        cmd = string.format(
          "perf record -o /tmp/perf.data -- %s%s > /dev/null && mkdir -p %s "
            .. "&& cp /tmp/perf.data %s/perf.data && echo output: %s/perf.data",
          ebin,
          resolve_args(p),
          PERF_SNAP_DIR,
          PERF_SNAP_DIR,
          PERF_SNAP_DIR
        ),
      }
    end,
  },
  {
    -- perf diff has no native size-limit flag (checked --help): same
    -- handling as "perf: script"'s inherently unbounded output, full diff
    -- written to a file, only a head sample shown here.
    name = "perf: diff snapshot",
    desc = "Record fresh, diff against the last snapshot. Full diff written to file, only a head sample shown",
    needs_bin = true,
    takes_args = true,
    build = function(c, p)
      local _, ebin = resolve_bin(c, p)
      local snap_path = PERF_SNAP_DIR .. "/perf.data"
      return {
        cmd = string.format(
          "perf record -o /tmp/perf.data -- %s%s > /dev/null "
            .. "&& perf diff %s /tmp/perf.data > /tmp/perf-diff.out "
            .. "&& echo \"output: /tmp/perf-diff.out ($(wc -l < /tmp/perf-diff.out) lines total, showing first 100)\" "
            .. "&& head -100 /tmp/perf-diff.out",
          ebin,
          resolve_args(p),
          vim.fn.shellescape(snap_path)
        ),
        info_lines = { "snapshot: " .. snap_path .. " created " .. human_age(vim.fn.getftime(snap_path)) },
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
          "%s | %s > /tmp/asm-diff-cur.txt && %s",
          objdump_cmd(ebin, sym),
          SED_NORMALIZE,
          diff_cmd(vim.fn.shellescape(snap_path), "/tmp/asm-diff-cur.txt")
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
  {
    -- True Compiler-Explorer style view: compiles the current TU straight to
    -- annotated asm, no link, no execute, no needs_bin. Distinct from "asm:
    -- disassemble"/"asm: dump" above, which read the already-linked binary
    -- (post-LTO/inlining across TUs) instead of one source file.
    name = "asm: compile view",
    desc = "Compile this TU straight to annotated asm (-S -fverbose-asm), no link/execute needed",
    build = function(c)
      local out = "/tmp/" .. vim.fn.fnamemodify(c.file, ":t:r") .. ".s"
      return {
        cmd = string.format(
          "g++ -S -O3 -march=native -fverbose-asm %s -o %s && cat %s",
          c.efile,
          vim.fn.shellescape(out),
          vim.fn.shellescape(out)
        ),
      }
    end,
  },

  -----------------------------------------------------------------------------
  -- codebase: batch structural/call-graph tools, project-wide (not tied to
  -- the current buffer or a built binary)
  -----------------------------------------------------------------------------
  {
    -- Whole-project HTML call/caller/include graph. GENERATE_HTML=YES
    -- (rather than just emitting raw .dot files) since doxygen only keeps
    -- the intermediate .dot graphs around long enough to render them into
    -- an image during HTML/LaTeX generation; the browsable HTML site is
    -- the actually-openable artifact. Verified working in a scratch test.
    -- Doxygen's DOT_COMMON_ATTR only reaches the node/edge attribute lists
    -- it emits (verified directly: splines is a graph-level graphviz
    -- attribute, silently ignored when set there), so there's no Doxyfile
    -- setting for edge routing. Worked around by keeping the intermediate
    -- .dot files (DOT_CLEANUP=NO), injecting "splines=ortho;" as a graph
    -- statement, and re-rendering each with dot ourselves, overwriting
    -- doxygen's own straight-line SVG under the same filename its HTML
    -- already links to. Orthogonal routing gives each edge a distinct
    -- right-angle path instead of overlapping diagonals. DOT_GRAPH_MAX_NODES
    -- lowered from doxygen's default (50) to 20: verified on a real 40+
    -- edge fan-out function that this is what actually shrinks the tangle
    -- (limiting call depth barely helped a wide-fanout graph in testing).
    name = "codebase: call graph",
    desc = "doxygen+dot call/caller/include graph (orthogonal routing, capped node count), HTML site to /tmp",
    condition_callback = function()
      return vim.fn.executable "doxygen" == 1 and vim.fn.executable "dot" == 1
    end,
    no_buffer = true,
    build = function()
      local out_dir = "/tmp/doxygen-callgraph"
      local doxyfile = out_dir .. "/Doxyfile.overseer"
      local html_dir = out_dir .. "/html"
      local config = {
        "INPUT = .",
        "RECURSIVE = YES",
        "OUTPUT_DIRECTORY = " .. out_dir,
        "GENERATE_HTML = YES",
        "GENERATE_LATEX = NO",
        "HAVE_DOT = YES",
        "CALL_GRAPH = YES",
        "CALLER_GRAPH = YES",
        "DOT_IMAGE_FORMAT = svg",
        "EXTRACT_ALL = YES",
        "QUIET = YES",
        "DOT_CLEANUP = NO",
        "DOT_GRAPH_MAX_NODES = 20",
      }
      local cmd = "mkdir -p "
        .. out_dir
        .. " && printf '%s\\n' "
        .. table.concat(vim.tbl_map(vim.fn.shellescape, config), " ")
        .. " > "
        .. doxyfile
        .. " && doxygen "
        .. doxyfile
        .. " && find "
        .. html_dir
        .. [[ -name '*.dot' -exec sed -i '0,/{/{s/{/{\n  splines=ortho;/}' {} \;]]
        .. " && find "
        .. html_dir
        .. [[ -name '*.dot' -print0 | xargs -0 -I{} sh -c 'dot -Tsvg "{}" -o "${0%.dot}.svg"' {}]]
        .. " && echo output: "
        .. html_dir
        .. "/index.html"
      return { cmd = cmd }
    end,
  },
  {
    -- rg's own --stats footer natively answers "how many calls" (no
    -- hand-rolled counting), -n gives "where" alongside it.
    name = "codebase: call sites",
    desc = "Grep call sites for a symbol project-wide, with a native match/file count summary",
    condition_callback = function()
      return vim.fn.executable "rg" == 1
    end,
    no_buffer = true,
    params = {
      symbol = { type = "string", name = "symbol", desc = "function/symbol name", optional = false },
    },
    prompts = { { key = "symbol", label = "Symbol: " } },
    build = function(_, p)
      -- --color=always rather than relying on rg's own tty auto-detection,
      -- so match highlighting is guaranteed regardless of how the pty
      -- overseer spawns this in gets detected.
      return {
        cmd = string.format("rg -n --stats --color=always %s", vim.fn.shellescape("\\b" .. p.symbol .. "\\s*\\(")),
      }
    end,
  },
  {
    name = "codebase: find definition",
    desc = "ctags lookup, prints the full function body including template/requires/attributes if present",
    condition_callback = function()
      return vim.fn.executable "ctags" == 1
    end,
    no_buffer = true,
    params = {
      symbol = { type = "string", name = "symbol", desc = "function/symbol name", optional = false },
    },
    prompts = { { key = "symbol", label = "Symbol: " } },
    build = function(_, p)
      local sym = vim.fn.shellescape(p.symbol)
      local cmd = "res=$(ctags -x -R --c-kinds=f --c++-kinds=f --languages=C,C++ . 2>/dev/null | awk -v s="
        .. sym
        .. " '$1==s{print $3\" \"$4; exit}'); "
        .. "if [ -z \"$res\" ]; then echo not found: "
        .. sym
        .. "; exit 1; fi; "
        .. "line=${res%% *}; file=${res#* }; "
        .. "range=$(awk -v target=\"$line\" '"
        .. CTAGS_EXTRACT_RANGE_AWK
        .. "' \"$file\"); "
        .. "start=${range%% *}; end=${range#* }; "
      -- bat reads the real file by --line-range instead of extracted text
      -- piped via stdin, so the gutter shows the code's actual line
      -- numbers, not 1-based numbering of just the snippet. bat is an
      -- enhancement, not a hard requirement: falls back to sed+nl (still
      -- shows real line numbers, just no syntax color) rather than hiding
      -- this whole task when bat isn't installed. --paging=never for the
      -- same reason --no-pager is forced elsewhere: overseer's task pane
      -- looks like a real tty and would otherwise hang waiting for a
      -- pager keypress. --theme is generated fresh from the live
      -- colorscheme (see sync_bat_theme above).
      if vim.fn.executable "bat" == 1 then
        local theme = sync_bat_theme()
        cmd = cmd .. 'bat --style=numbers --line-range="$start:$end" --language=cpp --color=always --paging=never'
        if theme then
          cmd = cmd .. " --theme=" .. theme
        end
        cmd = cmd .. ' "$file"'
      else
        cmd = cmd .. 'sed -n "${start},${end}p" "$file" | nl -ba -v"$start"'
      end
      return { cmd = cmd }
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
    takes_args = true,
    build = function(c, p)
      local _, ebin = resolve_bin(c, p)
      return {
        cmd = string.format(
          "valgrind --leak-check=full --show-leak-kinds=all --track-origins=yes %s%s > /dev/null",
          ebin,
          resolve_args(p)
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
    takes_args = true,
    build = function(c, p)
      local _, ebin = resolve_bin(c, p)
      -- Keeps output out of the project directory, same as every other
      -- tool here.
      return {
        cmd = string.format(
          "valgrind --tool=callgrind --callgrind-out-file=/tmp/callgrind.out.%%p %s%s > /dev/null "
            .. "&& echo output: $(ls -t /tmp/callgrind.out.* | head -1)",
          ebin,
          resolve_args(p)
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
    takes_args = true,
    build = function(c, p)
      local _, ebin = resolve_bin(c, p)
      return {
        cmd = string.format(
          "valgrind --tool=massif --massif-out-file=/tmp/massif.out.%%p %s%s > /dev/null "
            .. "&& echo output: $(ls -t /tmp/massif.out.* | head -1)",
          ebin,
          resolve_args(p)
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
    takes_args = true,
    build = function(c, p)
      local _, ebin = resolve_bin(c, p)
      return { cmd = string.format("valgrind --tool=helgrind %s%s > /dev/null", ebin, resolve_args(p)) }
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
    takes_args = true,
    build = function(c, p)
      local _, ebin = resolve_bin(c, p)
      local tool = pick { "toplev.py", "toplev" }
      return { cmd = string.format("%s -l3 --no-desc --single-thread -- %s%s", tool, ebin, resolve_args(p)) }
    end,
  },

  -----------------------------------------------------------------------------
  -- likwid: HPC-standard grouped hardware counters. MEM_DP is the roofline/
  -- ECM ingredient group (bandwidth + FLOPs); the ECM model itself (T_ECM =
  -- max(T_OL, T_nOL + T_data)) is an analytical hand-model applied against
  -- the loop kernel, not something one command outputs.
  -----------------------------------------------------------------------------
  {
    name = "likwid: perfctr",
    desc = "Grouped HPC counters (bandwidth/FLOPs/cache), feeds a roofline or ECM model by hand",
    condition_callback = function()
      return vim.fn.executable "likwid-perfctr" == 1
    end,
    needs_bin = true,
    takes_args = true,
    params = {
      group = {
        type = "enum",
        name = "group",
        choices = { "MEM_DP", "L2CACHE", "L3CACHE" },
        default = "MEM_DP",
      },
    },
    build = function(c, p)
      local _, ebin = resolve_bin(c, p)
      return {
        cmd = string.format("likwid-perfctr -C 0 -g %s -- %s%s", vim.fn.shellescape(p.group), ebin, resolve_args(p)),
      }
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
    takes_args = true,
    build = function(c, p)
      local _, ebin = resolve_bin(c, p)
      return {
        cmd = string.format(
          "sde64 -mix -omix /tmp/sde-mix.out -- %s%s > /dev/null && echo output: /tmp/sde-mix.out && cat /tmp/sde-mix.out",
          ebin,
          resolve_args(p)
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
    takes_args = true,
    build = function(c, p)
      local _, ebin = resolve_bin(c, p)
      -- -ast writes its report to a file, not stdout.
      return {
        cmd = string.format(
          "sde64 -ast -oast /tmp/sde-ast.out -- %s%s > /dev/null && echo output: /tmp/sde-ast.out && cat /tmp/sde-ast.out",
          ebin,
          resolve_args(p)
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
    takes_args = true,
    build = function(c, p)
      local _, ebin = resolve_bin(c, p)
      -- -odyn_mask_profile also writes to a file, same as -ast/-oast.
      return {
        cmd = string.format(
          "sde64 -dyn_mask_profile -odyn_mask_profile /tmp/sde-dyn-mask-profile.txt -- %s%s > /dev/null "
            .. "&& echo output: /tmp/sde-dyn-mask-profile.txt && cat /tmp/sde-dyn-mask-profile.txt",
          ebin,
          resolve_args(p)
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
    takes_args = true,
    params = {
      arch = { type = "string", name = "arch", desc = "sde64 target flag suffix, e.g. skx/spr/gnr", default = "spr" },
    },
    build = function(c, p)
      local _, ebin = resolve_bin(c, p)
      local arch = (p.arch and p.arch ~= "") and p.arch or "spr"
      return { cmd = string.format("sde64 -%s -- %s%s", arch, ebin, resolve_args(p)) }
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
  {
    -- Different static-analysis heuristics than clang-tidy above (array
    -- bounds, uninitialized use, portability), worth running both.
    name = "cppcheck: check",
    condition_callback = function()
      return vim.fn.executable "cppcheck" == 1
    end,
    build = function(c)
      return {
        cmd = {
          "cppcheck",
          "--enable=warning,performance,portability,style",
          "--std=c++20",
          "--language=c++",
          c.file,
        },
      }
    end,
  },

  -----------------------------------------------------------------------------
  -- rr
  -----------------------------------------------------------------------------
  {
    name = "rr: record",
    needs_bin = true,
    takes_args = true,
    build = function(c, p)
      local _, ebin = resolve_bin(c, p)
      return { cmd = string.format("rr record %s%s", ebin, resolve_args(p)) }
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
    -- needs_bin defs take an explicit binary path, and no_buffer defs
    -- (codebase-wide tools: call graph, call sites, ...) operate on the
    -- project tree, not the buffer, so neither needs a C/C++ file open.
    -- Only compile/build tasks (which read the buffer as source) require
    -- filetype cpp/c.
    local skip_buffer = def.needs_bin or def.no_buffer
    local condition = skip_buffer and {} or { filetype = { "cpp", "c" } }
    if def.condition_callback then
      condition.callback = def.condition_callback
    end

    -- needs_bin defs get a "binary" param, always required so overseer
    -- always prompts for it; no guess tied to the current buffer since one
    -- may not be open.
    local params = def.params or {}
    if def.needs_bin then
      params = function()
        local schema = {}
        for k, v in pairs(def.params or {}) do
          schema[k] = v
        end
        schema.bin = {
          type = "string",
          name = "binary",
          desc = "path to executable to run",
          optional = false,
        }
        if def.takes_args then
          schema.args = {
            type = "string",
            name = "args",
            desc = "arguments passed to the binary (blank = none)",
            optional = true,
          }
        end
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
        -- needs_bin/no_buffer defs never read the current buffer: ctx()
        -- would return blank paths with no file open, so cwd falls back to
        -- Neovim's own cwd instead (matches invoking the binary, or scanning
        -- the project tree, from the project root).
        local c = skip_buffer and {} or ctx()
        local task = def.build(c, params)
        task.name = task.name or def.name
        task.cwd = task.cwd or (skip_buffer and vim.fn.getcwd() or c.dir)
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
          local bin_path = vim.fn.expand(params.bin)
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

      -- needs_bin/takes_args auto-generate their prompts (binary path with
      -- file completion, then optional args); any def can also declare its
      -- own def.prompts (e.g. codebase: * asking for a symbol) which are
      -- appended after. Same chain, same vim.ui.input mechanism either way.
      local prompts = {}
      if def.needs_bin then
        prompts[#prompts + 1] =
          { key = "bin", label = "Binary to run: ", completion = "file", default = vim.fn.getcwd() .. "/" }
        if def.takes_args then
          prompts[#prompts + 1] = { key = "args", label = "Arguments (blank = none): ", required = false }
        end
      end
      if def.prompts then
        vim.list_extend(prompts, def.prompts)
      end
      if #prompts > 0 then
        M._prompts[def.name] = prompts
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

  -- Every def with M._prompts[name] set walks the same chained
  -- vim.ui.input flow, one field at a time (binary+args, a symbol, two
  -- file paths, ...): the mechanism is identical, only the fields differ.
  -- A blank required field cancels the whole task, same as before for a
  -- blank binary path.
  local function chain_prompts(overseer, name, prompts, idx, collected)
    local spec = prompts[idx]
    if not spec then
      overseer.run_task { name = name, params = collected }
      return
    end
    vim.ui.input({ prompt = spec.label, default = spec.default, completion = spec.completion }, function(value)
      if (not value or value == "") and spec.required ~= false then
        return
      end
      collected[spec.key] = value or ""
      chain_prompts(overseer, name, prompts, idx + 1, collected)
    end)
  end

  -- Size the picker to the longest template name plus padding, capped at
  -- 75% of the terminal width.
  local longest = 0
  for _, n in ipairs(M._names) do
    longest = math.max(longest, #n)
  end
  local width = math.min(longest + 30, math.floor(vim.o.columns * 0.75))

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
          local prompts = M._prompts[name]
          if prompts then
            chain_prompts(overseer, name, prompts, 1, {})
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
