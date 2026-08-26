-- Overseer task templates for C/C++ (HPC) workflows.
--
-- Two kinds of defs: buffer-based (compile/build) use ctx.file/.bin/.dir,
-- require filetype cpp/c, cwd to the buffer's dir. needs_bin = true tasks
-- (perf, valgrind, mca, asm, ...) take an explicit "binary" param instead,
-- work without a C/C++ buffer, cwd to Neovim's own cwd.
--
-- No top-level require("overseer"): mappings.lua requires this module to
-- reach M.telescope_run(), and requiring overseer here would trigger
-- lazy-load before M is returned. Required lazily inside M.setup()/M.telescope_run().

local M = {}
M._names = {} -- template names, populated by M.setup(), consumed by the picker
-- name -> ordered list of { key, label, completion?, default? } prompts,
-- consumed by the chained vim.ui.input flow in the telescope picker below.
M._prompts = {}
-- name -> { key, title, choices = fn-or-list } for templates that get a
-- third telescope level: an enum param picked in a picker instead of via
-- vim.ui.input. Only likwid-perfctr registers one today.
M._enum_picks = {}
-- Every def.name is "Group: action" (e.g. "perf: stat"); the two-level
-- telescope picker groups by the part before ": " so the top-level list
-- shows one entry per tool instead of every action flattened together.
-- M._group_order: tool names in first-seen order.
-- M._by_group[tool] = ordered list of { name = full template name, action = label after ": " }.
M._group_order = {}
M._by_group = {}

local STD = "-std=c++20"
-- performance-avoid-endl: "do not use 'std::endl' with streams" (clang-tidy >= 20)
-- bugprone-easily-swappable-parameters: "N adjacent parameters of similar type are easily swapped by accident"

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

-- PMU raw event names are vendor-specific; picks the event list for
-- "perf: stat microarch".
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

-- bat's bundled palettes don't match this colorscheme, so generate a
-- .tmTheme from the live highlight groups instead. Re-synced on every call
-- (cheap, picks up mid-session :colorscheme changes) rather than cached.
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

-- Build systems (justfile/CMake/etc.) may not name the binary "<file>:r",
-- so needs_bin defs take an explicit required "binary" param instead.
local function resolve_bin(_, p)
  local bin = vim.fn.expand(p.bin)
  return bin, vim.fn.shellescape(bin)
end

-- takes_args = true defs get an optional "args" param, appended unescaped
-- (quoting is the user's to control) right after the binary.
local function resolve_args(p)
  if p and p.args and p.args ~= "" then
    return " " .. p.args
  end
  return ""
end

-- "<date> (<age> ago)" for a file's mtime, or "not found" - surfaces stale
-- binaries/snapshots before a task reads them.
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
-- actually runs) relative to the cwd Neovim started in, then home. Also
-- drops the single-quote shell-escaping around any token that doesn't
-- actually need it (no space/quote inside) - shellescape wraps every arg
-- for a table-form cmd regardless, which is correct for execution but
-- leaves the echoed line full of 'foo' 'bar' quoting that's annoying to
-- select/copy out of the task pane. task.cmd itself (what actually runs)
-- is built from the unmodified shell_cmd elsewhere, so this is display-only.
local function shorten_display(str)
  local cwd = vim.fn.getcwd()
  local out = str
  if cwd ~= "" then
    out = out:gsub(vim.pesc(cwd .. "/"), "")
  end
  out = out:gsub("'([^'%s]+)'", "%1")
  local home = vim.fn.expand "$HOME"
  if home ~= "" and home ~= "$HOME" then
    out = out:gsub(vim.pesc(home), "~")
  end
  return out
end

-- asm/mca/uica/pahole/bloaty read the already-linked binary via the same
-- needs_bin/resolve_bin mechanism as perf/valgrind/rr. Plain text, no TUI/pager.
local ASM_SNAP_DIR = "/tmp/asm-snap"
local BLOATY_SNAP_DIR = "/tmp/bloaty-snap"
local PERF_SNAP_DIR = "/tmp/perf-snap"
local OUTPUT_SNAP_DIR = "/tmp/output-snap"

-- Dropped the custom /proc/stat IQR core-picker: guessing "quiet" from tick
-- counts was a weak proxy. likwid-perfctr already does this properly when
-- given a core range instead of one core - it runs/measures on every core
-- in the range and prints a Sum/Min/Max/Avg row per metric, so cross-core
-- spread (the real noise signal) comes straight from likwid, no separate
-- sampler needed. Default: every core but the last one, leaving it free for
-- the OS/IRQs rather than pinning onto all of them.
local function likwid_default_core_range()
  local n = tonumber(vim.fn.system "nproc")
  if not n or n <= 1 then
    return "0"
  end
  return "0-" .. (n - 2)
end

-- likwid-perfctr -a prints a tab-aligned "name<tab>description" table; read
-- it live so the group list always matches the installed likwid. The old
-- hardcoded list drifted from 5.x reality (MEM_DP/CACHES no longer exist:
-- memory groups are MEM/MEMREAD/MEMWRITE now). Feeds both the enum schema
-- and the Level-3 group picker.
--
-- likwid prints its table in a fixed, unsorted order (L2 and L2CACHE end up
-- far apart), so sort the groups by meaning: roofline/ECM ingredients first
-- (memory bandwidth, FLOP/s), then cache/TLB, pipeline ratios, interconnect,
-- power. Groups a newer likwid adds that aren't in GROUP_ORDER fall back to
-- alphabetical at the end instead of breaking.
local GROUP_ORDER = {}
for i, name in ipairs {
  "MEM", "MEMREAD", "MEMWRITE", -- main memory bandwidth (roofline)
  "FLOPS_DP", "FLOPS_SP", -- FLOP/s (roofline)
  "L2", "L2CACHE", "L3", "L3CACHE", "CACHE", "ICACHE", -- cache bandwidth + miss rates
  "TLB", -- TLB miss rate/ratio
  "CLOCK", "CPI", "DATA", "BRANCH", "DIVIDE", -- cycles/ratio/exec ports
  "NUMA", -- socket interconnect
  "ENERGY", -- power and energy
} do
  GROUP_ORDER[name] = i
end

local function likwid_groups()
  if vim.fn.executable "likwid-perfctr" == 0 then
    return {}
  end
  local groups = {}
  for _, line in ipairs(vim.fn.systemlist { "likwid-perfctr", "-a" }) do
    local value, desc = line:match("^%s*(%S+)%s*\t%s*(.-)%s*$")
    if value and value ~= "Group" and desc then
      groups[#groups + 1] = { value = value, desc = desc }
    end
  end
  table.sort(groups, function(a, b)
    local ra, rb = GROUP_ORDER[a.value], GROUP_ORDER[b.value]
    ra = ra or math.huge
    rb = rb or math.huge
    if ra ~= rb then
      return ra < rb
    end
    return a.value < b.value
  end)
  return groups
end

-- watchcub (github.com/fior512/bash) puts the box into a known state for
-- benchmarking - governor/boost/C-states/THP - and samples freq/temp/thread
-- placement while a binary runs, so this file doesn't have to re-implement
-- any of that itself. Not on PATH by default (see its README), hence the
-- absolute path instead of relying on `executable("watchcub")`.
local WATCHCUB = "/home/moonfloww/Projects/codebase/scripts/watchcub/watchcub.sh"
local function watchcub_available()
  return vim.fn.executable(WATCHCUB) == 1
end

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

-- diff-highlight (ships with git, not always on PATH) highlights just the
-- changed substring within each -old/+new line pair. Falls back to
-- --word-diff=plain if not found anywhere on this machine.
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

-- --no-pager: overseer's task pane looks like a tty to git, which would
-- otherwise invoke $PAGER and hang. --no-index: diff any two files, no repo needed.
local function diff_cmd(old, new)
  local base = "git --no-pager diff --no-index --color=always -- " .. old .. " " .. new
  if DIFF_HIGHLIGHT then
    return base .. " | " .. DIFF_HIGHLIGHT
  end
  return "git --no-pager diff --no-index --color=always --word-diff=plain --word-diff-regex='\\S+' -- " .. old .. " " .. new
end

-- Given a ctags signature line: walks up past template<>/requires/attribute
-- lines, then counts braces forward to the matching close. Naive brace
-- counting (breaks on braces in strings/comments), not a full parser.
-- Returns a "first end" line range (not the body text) so the caller can
-- bat --line-range the real file, keeping bat's gutter numbers accurate.
local CTAGS_EXTRACT_RANGE_AWK = [==[{ lines[NR] = $0; last = NR } END { first = target; while (first > 1) { prev = lines[first - 1]; if (prev ~ /^[[:space:]]*template[[:space:]]*</ || prev ~ /^[[:space:]]*requires\y/ || prev ~ /^[[:space:]]*\[\[.*\]\][[:space:]]*$/) { first = first - 1 } else { break } } depth = 0; started = 0; for (i = first; i <= last; i++) { line = lines[i]; if (i >= target) { n = gsub(/{/, "{", line); m = gsub(/}/, "}", line); depth += n - m; if (depth > 0) started = 1; if (started && depth == 0) { print first" "i; exit } } } print first" "last }]==]

-- bcc reads the ELF symbol table directly (no demangling), so a readable
-- C++ name like SIMD_fnv1a_Search must resolve to its mangled symbol first.
-- Matches T/t/W/w symbols (t covers static) via nm -C, word-boundary only
-- (a substring match once silently resolved "fnv1a" to the wrong function
-- inside SIMD_fnv1a_Search). No exact match: lists substring hints instead
-- of guessing (small statics are often inlined away with no symbol at all).
-- Expects $bin/$func set by caller; sets $mangled or exits with an explanation.
local RESOLVE_SYMBOL_SH = [==[addr=$(nm -C "$bin" 2>/dev/null | awk -v f="$func" '$2 ~ /^[TtWw]$/ { name=$0; sub(/^[0-9a-f]+ +[A-Za-z] +/, "", name); if (name ~ ("\\<" f "\\>")) { print $1; exit } }'); if [ -z "$addr" ]; then echo "no function named exactly '$func' found in $bin (it may have been inlined away at this optimization level, especially if it's a small 'static' function)"; hint=$(nm -C "$bin" 2>/dev/null | awk -v f="$func" '$2 ~ /^[TtWw]$/ { name=$0; sub(/^[0-9a-f]+ +[A-Za-z] +/, "", name); if (index(name, f) > 0) print name }' | head -3); if [ -n "$hint" ]; then echo "closest matches (not used automatically):"; echo "$hint"; else echo "try: nm -C $bin | grep -i '$func'"; fi; exit 1; fi; mangled=$(nm "$bin" 2>/dev/null | awk -v a="$addr" '$1==a { print $3; exit }'); if [ -z "$mangled" ]; then echo "resolved address $addr for '$func' but found no matching raw symbol (unexpected)"; exit 1; fi]==]

-- For diffing/snapshots: strips address/byte-offset prefixes, collapses
-- compiler-generated .L labels, drops .cfi_ directives and padding nops,
-- and blurs long literal addresses so diffs stay quiet across rebuilds.
local SED_NORMALIZE =
  "sed -E 's/^[[:space:]]*[0-9a-f]+:[[:space:]]*//; s/\\.L[A-Za-z]+[0-9_]+/.L/g; /\\.cfi_/d; /^[[:space:]]*nop/d; s/0x[0-9a-f]{6,}/0xADDR/g'"

-- Must stay valid assembly for llvm-mca/uiCA, so unlike SED_NORMALIZE it
-- can't blur addresses. Drops branch/call/ret/loop (targets undefined in
-- this snippet) - lossy on branchy code, but mca only models straight-line
-- port/latency pressure anyway.
local MCA_STRIP = "sed -E "
  .. "-e '/^[[:space:]]*$/d' "
  .. "-e '/: *file format/d' "
  .. "-e '/^Disassembly of section/d' "
  .. "-e '/^[0-9a-f]+ <.*>:$/d' "
  .. "-e 's/^[[:space:]]*[0-9a-f]+:[[:space:]]*//' "
  .. "-e '/\\.cfi_/d' "
  .. "-e '/^[[:space:]]*nop/d' "
  .. "-e '/^[[:space:]]*(j[a-z]*|call|ret[a-z]*|loop[a-z]*)([[:space:]]|$)/d'"

-- llvm-mca's critical-sequence table sits between the summary and the
-- -all-stats tables, so mca is split into two tasks. Drops the table for
-- "mca: throughput" by indentation: rows are blank/indented/"+----", the
-- next section header starts at column 0.
local MCA_DROP_CRITSEQ = "awk '"
  .. "/^Critical sequence/ { skip = 1; next } "
  .. "skip && ($0 ~ /^[[:space:]]/ || $0 ~ /^$/ || $0 ~ /\\+----/) { next } "
  .. "{ skip = 0; print }'"

-- Only "+----"-marked rows explain a stall; used by "mca: critical path",
-- which drops -all-stats so nothing follows the table (safe to filter to end).
local MCA_CRITSEQ_ONLY = "awk '/^Critical sequence/{in_seq=1} "
  .. "{ if (!in_seq) { print; next } "
  .. "if ($0 ~ /\\+----/ || $0 ~ /Dependency Information/ || $0 ~ /^Critical sequence/ || $0 ~ /^$/) print }'"

-- Flag presets for "C++: compile": { mode name, flags, emit -o?, compiler }.
-- asm-dump skips -o (-S writes <file>.s next to source). pgo-generate/-use
-- are a sequential two-step workflow, not interchangeable. opt-remarks needs
-- clang++: its -Rpass diagnostics beat gcc's -fopt-info for vectorize/inline.
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

-- clang-tidy only reports warnings/errors in the file it was asked to check
-- (--header-filter defaults to matching nothing), but a "note:" attached to
-- one of those warnings - e.g. an analyzer's exception-path trace - can
-- still point into any transitively-included header, including fully
-- external ones like /usr/include/ROOT/*.hxx. That's just noise for a
-- single-file check: keeps every warning/error, drops a note only when its
-- own location isn't this file. Colors afterward, by hand, on the plain
-- (--use-color-less) output: clang-tidy's own --use-color puts ANSI codes
-- between "file:line:col: " and "warning:"/"note:", which breaks the exact
-- plain-text match this filter depends on - so color has to be added here,
-- after filtering, not requested from clang-tidy itself.
local function tidy_note_filter(target_efile)
  return "awk -v target="
    .. target_efile
    .. [==[ '
BEGIN {
  keep = 1
  ESC = sprintf("%c", 27)
  BOLD = ESC "[1m"; RED = ESC "[1;31m"; MAG = ESC "[1;35m"; CYAN = ESC "[1;36m"; GRN = ESC "[1;32m"; RST = ESC "[0m"
}
{
  line = $0
  if (match(line, /:[0-9]+:[0-9]+: (error|warning|note):/)) {
    prefix = substr(line, 1, RSTART - 1)
    tag = substr(line, RSTART, RLENGTH)
    suffix = substr(line, RSTART + RLENGTH)
    keep = !(tag ~ /note:/ && prefix != target)
    if (keep) {
      color = (tag ~ /error:/) ? RED : (tag ~ /warning:/) ? MAG : CYAN
      line = BOLD prefix RST color tag RST suffix
    }
  } else if (keep && line ~ /\|.*\^/) {
    line = GRN line RST
  }
  if (keep) print line
}
']==]
end

-- One "tidy: <category>" def. checks is a clang-tidy --checks value (comma
-- list, "-name" entries excluded). --header-filter='': explicit, don't rely
-- on the implicit default. -quiet: drop the "N warnings generated" banner.
local function tidy_def(category, checks, desc)
  return {
    name = "tidy: " .. category,
    desc = desc,
    build = function(c)
      return {
        cmd = string.format(
          "clang-tidy --checks=%s --quiet --header-filter='' %s -- %s | %s",
          vim.fn.shellescape(checks),
          c.efile,
          STD,
          tidy_note_filter(c.efile)
        ),
      }
    end,
  }
end

-- One "cppcheck: <category>" def. enable is a cppcheck --enable value.
local function cppcheck_def(category, enable, desc)
  return {
    name = "cppcheck: " .. category,
    desc = desc,
    condition_callback = function()
      return vim.fn.executable "cppcheck" == 1
    end,
    build = function(c)
      return { cmd = string.format("cppcheck --enable=%s --std=c++20 --language=c++ %s", enable, c.efile) }
    end,
  }
end

-- Each def: { name, desc?, tags?, quickfix?, needs_bin?, condition_callback?,
--             params?, build = fn(ctx, params) -> task }
-- build() returns a task-opts table; cmd may be a list (exec directly) or a
-- shell string (pipes/globs/&& work). info_lines (array of strings) adds
-- extra facts the shared builder echoes before running.
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
    -- Saves this run's stdout; "C++: diff output snapshot" below runs a
    -- (possibly different) binary and diffs against it. Same snapshot/diff
    -- pairing as asm/bloaty/perf, sourced from stdout instead of a static file.
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
    -- -ddd adds counters onto perf's default group; an explicit -e list would
    -- replace it instead (why the old "stat detailed" showed less than "stat").
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
    -- Raw cache-miss surface, not a 4C classification (needs a working-set
    -- sweep). Coherence misses are "perf: c2c"'s job. AMD path substitutes
    -- l2_request_g1 for LLC-load-misses: no amd_l3 uncore PMU on this part.
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
    -- Native L1 topdown via perf's own -M metrics, no toplev.py needed.
    -- perf's --topdown flag only works with Intel's TopdownL1+ groups and
    -- errors on this AMD Zen4.
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
    -- Self-contained: records fresh into /tmp/perf.data each run. Without
    -- --percent-limit, perf report lists every symbol ever sampled (700+
    -- entries of kernel/library noise), only the top ~20 carry any signal.
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
    -- A symbol shows one full function, in sequence. Without one,
    -- --percent-limit is perf's function-selection cutoff (which functions
    -- get annotated), not a line-level filter - neither path strips lines
    -- out of a function's middle.
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
    -- One line per sampled event (flamegraph feedstock, not meant to be read
    -- directly): 20K+ lines on a real run. Full output goes to a file, only
    -- a head sample is shown here.
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
      -- PAGER=cat: c2c report doesn't fully honor --stdio, still invokes
      -- $PAGER and blocks. Tried the ncurses browser instead: same
      -- fixed-width wrap, plus fragile inside overseer's pane. Kept --stdio.
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
    -- perf diff has no size-limit flag; same handling as "perf: script"'s
    -- unbounded output - full diff to a file, only a head sample shown here.
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
    -- Without a duration, bcc tools run until Ctrl-C and print only on exit,
    -- which looks like a stuck task. funccount only attaches uprobes/counts,
    -- so it sees nothing unless the target runs during the window. "sudo -v"
    -- is its own statement (";" not "&&"): it must block on the password
    -- prompt before the rest races ahead (verified this race with "&&").
    --
    -- Stops as soon as the binary exits rather than making the user guess a
    -- duration; -d/duration is just a safety ceiling for a hung binary. sudo
    -- relays SIGINT to its child over a pty (man sudo); verified a backgrounded
    -- job does receive kill -INT immediately from a non-interactive script.
    name = "bcc: funccount",
    desc = "Runs the binary while attached, stops as soon as it exits: bcc funccount over its functions (needs root/bcc)",
    condition_callback = function()
      return has_bcc "funccount"
    end,
    needs_bin = true,
    takes_args = true,
    params = {
      pattern = {
        type = "string",
        name = "pattern",
        desc = "function name or glob within the binary; a plain name (no * or ?) is resolved from its readable form to the binary's real symbol automatically",
        default = "*",
        optional = true,
      },
      duration = {
        type = "string",
        name = "duration",
        desc = "safety ceiling in seconds in case the binary hangs; the trace normally stops right when the binary exits, this rarely needs changing",
        default = "300",
        optional = true,
      },
    },
    prompts = {
      { key = "pattern", label = "Function name or glob (blank = *): ", required = false },
    },
    build = function(c, p)
      local tool = pick { "funccount-bpfcc", "funccount" }
      local pat = (p.pattern and p.pattern ~= "") and p.pattern or "*"
      local ceiling = (p.duration and p.duration ~= "") and p.duration or "300"
      local bin, ebin = resolve_bin(c, p)
      -- A glob (*/?) passes through to bcc as-is; a plain name resolves via
      -- RESOLVE_SYMBOL_SH like funclatency, since bcc can't match a readable
      -- C++ name against the mangled symbol table otherwise.
      local target_expr
      if pat:find "[*?]" then
        target_expr = "mangled=" .. vim.fn.shellescape(pat)
      else
        target_expr = "func=" .. vim.fn.shellescape(pat) .. "; " .. RESOLVE_SYMBOL_SH
      end
      -- uprobe pattern: '<binary>:<glob-or-symbol>'. sudo: eBPF loading needs
      -- CAP_BPF/CAP_SYS_ADMIN + raised RLIMIT_MEMLOCK; overseer's pane is a
      -- real pty so sudo can prompt there.
      return {
        cmd = string.format(
          "sudo -v; bin=%s; %s; sudo %s \"$bin:$mangled\" %s & FLPID=$!; sleep 0.3; %s%s > /dev/null 2>&1; bin_status=$?; "
            .. "echo \"binary finished (exit $bin_status), stopping tracer...\"; sleep 0.2; "
            .. "sudo kill -INT \"$FLPID\" 2>/dev/null; wait \"$FLPID\"",
          vim.fn.shellescape(bin),
          target_expr,
          tool,
          vim.fn.shellescape(ceiling),
          ebin,
          resolve_args(p)
        ),
      }
    end,
  },
  {
    -- Same "runs the binary while attached, stops when it exits" fix as
    -- funccount above.
    name = "bcc: funclatency",
    desc = "Runs the binary while attached, stops as soon as it exits: bcc funclatency histogram for one function (needs root/bcc)",
    condition_callback = function()
      return has_bcc "funclatency"
    end,
    needs_bin = true,
    takes_args = true,
    params = {
      -- libbpf-tools rewrite (bcc-libbpf-tools on Arch/EndeavourOS) takes a
      -- single exact PROGRAM:FUNCTION, no glob, duration via -d - different
      -- syntax than the old bcc-python funclatency-bpfcc.
      func = {
        type = "string",
        name = "function",
        desc = "function name (readable form is fine, e.g. SIMD_fnv1a_Search: resolved to the binary's real symbol automatically)",
        default = "main",
        optional = true,
      },
      duration = {
        type = "string",
        name = "duration",
        desc = "safety ceiling in seconds in case the binary hangs; the trace normally stops right when the binary exits, this rarely needs changing",
        default = "300",
        optional = true,
      },
    },
    prompts = {
      { key = "func", label = "Function to trace (blank = main): ", required = false },
    },
    build = function(c, p)
      local tool = pick { "funclatency-bpfcc", "funclatency" }
      local f = (p.func and p.func ~= "") and p.func or "main"
      local ceiling = (p.duration and p.duration ~= "") and p.duration or "300"
      local bin, ebin = resolve_bin(c, p)
      -- $bin_status: see "bcc: funccount" above for why this is captured
      -- and surfaced rather than run silently.
      return {
        cmd = string.format(
          "sudo -v; bin=%s; func=%s; %s; sudo %s -d %s \"$bin:$mangled\" & FLPID=$!; sleep 0.3; %s%s > /dev/null 2>&1; bin_status=$?; "
            .. "echo \"binary finished (exit $bin_status), stopping tracer...\"; sleep 0.2; "
            .. "sudo kill -INT \"$FLPID\" 2>/dev/null; wait \"$FLPID\"",
          vim.fn.shellescape(bin),
          vim.fn.shellescape(f),
          RESOLVE_SYMBOL_SH,
          tool,
          vim.fn.shellescape(ceiling),
          ebin,
          resolve_args(p)
        ),
      }
    end,
  },

  -----------------------------------------------------------------------------
  -- asm: static disassembly, read directly off the linked binary
  -----------------------------------------------------------------------------
  {
    -- gdb's disassemble /s interleaves source more reliably on optimized
    -- code than objdump -dS, degrades to address-only without -g.
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
    -- Fast raw dump: no gdb, no -g needed, no interleaving/normalization.
    -- Distinct from "asm: disassemble" above (gdb, source-interleaved, needs debug info).
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
    -- Compiler-Explorer style: compiles this TU straight to asm, no
    -- link/execute. Distinct from "asm: disassemble"/"dump" above, which
    -- read the already-linked (post-LTO/cross-TU-inlined) binary.
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
    -- GENERATE_HTML=YES since doxygen only keeps intermediate .dot graphs
    -- around long enough to render them; the HTML site is the real artifact.
    -- No Doxyfile setting exists for edge routing (DOT_COMMON_ATTR doesn't
    -- reach graph-level attrs like splines), so DOT_CLEANUP=NO keeps the
    -- .dot files, injects "splines=ortho;", and re-renders each with dot,
    -- overwriting doxygen's straight-line SVG under the same filename.
    -- DOT_GRAPH_MAX_NODES lowered 50->20: this, not limiting call depth,
    -- is what actually shrinks a wide fan-out tangle.
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
    -- rg's own --stats footer natively answers "how many" (no hand-rolled
    -- counting), -n gives "where" alongside it. Word-boundary only, no
    -- trailing "(" -- catches calls, definitions, and non-call references
    -- (e.g. taking a function's address) alike.
    name = "codebase: call sites",
    desc = "Grep all occurrences of a symbol project-wide, with a native match/file count summary",
    condition_callback = function()
      return vim.fn.executable "rg" == 1
    end,
    no_buffer = true,
    params = {
      symbol = { type = "string", name = "symbol", desc = "function/symbol name", optional = false },
    },
    prompts = { { key = "symbol", label = "Symbol: " } },
    build = function(_, p)
      -- --color=always: rg's own tty auto-detection is unreliable in
      -- overseer's spawned pty.
      return {
        cmd = string.format("rg -n --stats --color=always %s", vim.fn.shellescape("\\b" .. p.symbol .. "\\b")),
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
      -- bat reads the real file via --line-range so the gutter shows actual
      -- line numbers, not the snippet's own. Falls back to sed+nl (no syntax
      -- color) if bat isn't installed. --paging=never: same tty-hang risk as
      -- --no-pager elsewhere. --theme from sync_bat_theme above.
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
    -- Split from the critical-path view below: aggregate stats and a
    -- per-instruction trace don't read well mixed, and need different flags.
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
      -- No -timeline/-instruction-info/-resource-pressure: each is a
      -- thousands-of-lines per-instruction listing. MCA_DROP_CRITSEQ also
      -- strips the critical-sequence table, leaving just summary + -all-stats.
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
  -- pahole: struct/class layout (needs -g)
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
    -- cachegrind cut: it simulates a cache model, not real hardware.
    -- "perf: stat microarch" covers actual cache/memory behavior; callgrind
    -- gives deterministic instruction counts instead.
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
    -- auto-annotation noise. Noise-immune before/after with no benchmark
    -- harness or core pinning needed - slow but exact.
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
  -- likwid: HPC-standard grouped hardware counters (MEM/MEMREAD/MEMWRITE +
  -- FLOPS_DP = roofline/ECM ingredients; the ECM model itself is a
  -- hand-applied analytical formula).
  -----------------------------------------------------------------------------
  {
    -- Pass a core RANGE, not one core: likwid-perfctr then runs/measures on
    -- every core in it and appends a Sum/Min/Max/Avg row per metric, so
    -- cross-core spread - the actual noise - comes straight from likwid
    -- instead of a guess made beforehand. Default excludes the last core
    -- (see likwid_default_core_range), matching "most cores, not all".
    name = "likwid: perfctr",
    desc = "Grouped HPC counters (bandwidth/FLOPs/cache/energy) over a core range; the Sum/Min/Max/Avg row shows noise",
    condition_callback = function()
      return vim.fn.executable "likwid-perfctr" == 1
    end,
    needs_bin = true,
    takes_args = true,
    -- group's choices come from `likwid-perfctr -a` at build time (same
    -- pattern as likwid: bench reading its kernel list), so they always
    -- match the installed likwid instead of a frozen list.
    params = function()
      local choices = {}
      for _, g in ipairs(likwid_groups()) do
        choices[#choices + 1] = g.value
      end
      return {
        group = {
          type = "enum",
          name = "group",
          choices = choices,
          default = choices[1],
        },
      }
    end,
    -- Third telescope level for this template: pick the -g group in a
    -- picker (name + description) before the binary/args/cores input chain.
    enum_pick = {
      key = "group",
      title = "Overseer: likwid-perfctr - group",
      choices = likwid_groups,
    },
    prompts = {
      { key = "core", label = "Cores to pin (-C, e.g. 0-10 or 0,2,4): ", default = likwid_default_core_range },
    },
    build = function(c, p)
      local _, ebin = resolve_bin(c, p)
      return {
        cmd = string.format(
          "likwid-perfctr -C %s -g %s -- %s%s",
          vim.fn.shellescape(p.core),
          vim.fn.shellescape(p.group),
          ebin,
          resolve_args(p)
        ),
      }
    end,
  },
  {
    name = "likwid: topology",
    desc = "CPU/cache/NUMA topology (likwid-topology -g)",
    condition_callback = function()
      return vim.fn.executable "likwid-topology" == 1
    end,
    no_buffer = true,
    build = function()
      return { cmd = { "likwid-topology", "-g" } }
    end,
  },
  {
    name = "likwid: features",
    desc = "CPU-level features (prefetchers, etc.), likwid-features -l",
    condition_callback = function()
      return vim.fn.executable "likwid-features" == 1
    end,
    no_buffer = true,
    build = function()
      return { cmd = { "likwid-features", "-l" } }
    end,
  },
  {
    -- "-a" lists kernels/workgroups only when kernel is left blank, so a
    -- benchmark run and a "what's available" listing share one action.
    -- ~140 kernels (clcopy/copy_avx512/daxpy_sse_fma/stream_mem_avx512/...);
    -- typing one exactly from memory isn't realistic, so kernel is an enum
    -- read from `likwid-bench -a` itself (not hardcoded - tracks whatever
    -- version is actually installed) instead of a free-text field.
    name = "likwid: bench",
    desc = "Microbenchmark kernel, picked from likwid-bench -a's own list",
    condition_callback = function()
      return vim.fn.executable "likwid-bench" == 1
    end,
    no_buffer = true,
    params = function()
      local choices = {}
      for _, line in ipairs(vim.fn.systemlist { "likwid-bench", "-a" }) do
        local name = line:match "^(%S+)%s+%-"
        if name then
          choices[#choices + 1] = name
        end
      end
      return {
        kernel = { type = "enum", name = "kernel", choices = choices, default = choices[1] },
        workgroup = {
          type = "string",
          name = "workgroup",
          desc = "domain:size:threads, e.g. S0:100MB:1",
          default = "S0:100MB:1",
        },
      }
    end,
    build = function(_, p)
      return { cmd = { "likwid-bench", "-t", p.kernel, "-w", p.workgroup } }
    end,
  },
  {
    name = "likwid: pin",
    desc = "Run the binary pinned to a core (likwid-pin), no counters collected",
    condition_callback = function()
      return vim.fn.executable "likwid-pin" == 1
    end,
    needs_bin = true,
    takes_args = true,
    prompts = {
      { key = "core", label = "Core to pin (-c): ", default = "0" },
    },
    build = function(c, p)
      local _, ebin = resolve_bin(c, p)
      return {
        cmd = string.format("likwid-pin -c %s %s%s", vim.fn.shellescape(p.core), ebin, resolve_args(p)),
      }
    end,
  },
  {
    -- -c is a SOCKET id here, not a core (RAPL power domains are per-package,
    -- not per-thread) - likwid-pin/-perfctr's -c is cores, this one isn't.
    -- Single-socket boxes: always 0.
    name = "likwid: powermeter",
    desc = "RAPL energy/power for the run (needs RAPL access)",
    condition_callback = function()
      return vim.fn.executable "likwid-powermeter" == 1
    end,
    needs_bin = true,
    takes_args = true,
    prompts = {
      { key = "socket", label = "Socket to measure (-c, not a core - 0 on single-socket boxes): ", default = "0" },
    },
    build = function(c, p)
      local _, ebin = resolve_bin(c, p)
      return {
        cmd = string.format("likwid-powermeter -c %s %s%s", vim.fn.shellescape(p.socket), ebin, resolve_args(p)),
      }
    end,
  },
  {
    name = "likwid: memsweeper",
    desc = "Evict this process's data from cache/NUMA-local memory before a clean-state benchmark run",
    condition_callback = function()
      return vim.fn.executable "likwid-memsweeper" == 1
    end,
    no_buffer = true,
    build = function()
      return { cmd = { "likwid-memsweeper" } }
    end,
  },

  -----------------------------------------------------------------------------
  -- watchcub: sets/reverts machine state for benchmarking (governor, boost,
  -- C-states, THP, ...) and samples freq/temp/thread placement during a run.
  -----------------------------------------------------------------------------
  {
    name = "watchcub: status",
    desc = "Dump current CPU/kernel/GPU/thermal settings (read-only, no root)",
    condition_callback = watchcub_available,
    no_buffer = true,
    build = function()
      return { cmd = { WATCHCUB, "status" } }
    end,
  },
  {
    -- Root-readable RAPL power line is skipped (not printed, not an error)
    -- without sudo - everything else (usage/freq/governor per thread) works
    -- either way.
    name = "watchcub: core",
    desc = "Per-thread usage%/freq/governor snapshot, plus package temp/power if run as root",
    condition_callback = watchcub_available,
    no_buffer = true,
    build = function()
      return { cmd = { WATCHCUB, "core" } }
    end,
  },
  {
    name = "watchcub: verify",
    desc = "Pre-flight: governor, load, RAM, swap, temp, steal, dirty pages (no root)",
    condition_callback = watchcub_available,
    no_buffer = true,
    params = {
      flags = { type = "string", name = "flags", desc = "extra flags, e.g. --temp-warn=70 (blank = defaults)", optional = true },
    },
    build = function(_, p)
      local flags = (p.flags and p.flags ~= "") and (" " .. p.flags) or ""
      return { cmd = string.format("%s verify%s", WATCHCUB, flags) }
    end,
  },
  {
    name = "watchcub: bench",
    desc = "Save current state, apply the performance profile (root; refuses to double-apply)",
    condition_callback = watchcub_available,
    no_buffer = true,
    params = {
      flags = { type = "string", name = "flags", desc = "extra flags, e.g. --turbo=off --smt=off (blank = defaults)", optional = true },
    },
    build = function(_, p)
      local flags = (p.flags and p.flags ~= "") and (" " .. p.flags) or ""
      return { cmd = string.format("sudo -v; sudo %s bench%s", WATCHCUB, flags) }
    end,
  },
  {
    name = "watchcub: run",
    desc = "Run the binary, sampling per-core frequency/temperature/thread placement",
    condition_callback = watchcub_available,
    needs_bin = true,
    takes_args = true,
    build = function(c, p)
      local _, ebin = resolve_bin(c, p)
      return { cmd = string.format("%s run -- %s%s", WATCHCUB, ebin, resolve_args(p)) }
    end,
  },
  {
    name = "watchcub: restore",
    desc = "Revert every value bench/trace-unlock changed, delete the state dir (root)",
    condition_callback = watchcub_available,
    no_buffer = true,
    build = function()
      return { cmd = string.format("sudo -v; sudo %s restore", WATCHCUB) }
    end,
  },
  {
    name = "watchcub: trace-unlock",
    desc = "Loosen perf_event_paranoid/kptr_restrict/ptrace scope/eBPF JIT for perf/VTune sessions (root)",
    condition_callback = watchcub_available,
    no_buffer = true,
    build = function()
      return { cmd = string.format("sudo -v; sudo %s trace-unlock", WATCHCUB) }
    end,
  },
  {
    name = "watchcub: trace-lock",
    desc = "Re-tighten what trace-unlock loosened (root)",
    condition_callback = watchcub_available,
    no_buffer = true,
    build = function()
      return { cmd = string.format("sudo -v; sudo %s trace-lock", WATCHCUB) }
    end,
  },

  -----------------------------------------------------------------------------
  -- sde: Intel Software Development Emulator
  -----------------------------------------------------------------------------
  {
    -- Deterministic instruction histogram by category/ISA extension: a
    -- noise-free A/B metric for "did the rewrite remove shuffles".
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
  -- tidy: clang-tidy split into categories (standalone file, no
  -- compile_commands.json). Each is check-only (no --fix): findings are
  -- reviewed, not auto-applied, and every task below runs on this one file
  -- only - never a project-wide/header-expanding sweep. See tidy_def above
  -- for the shared command (the --header-filter/note-filtering that keeps
  -- output scoped to this file even when it includes outside headers).
  -----------------------------------------------------------------------------
  -- UB/lifetime/bug-prone patterns: static analyzer, bugprone-*, plus the
  -- CERT and Core Guidelines alias groups (mostly re-point at bugprone/
  -- cppcoreguidelines checks already covered elsewhere, so overlap with
  -- the other tidy categories is expected).
  tidy_def(
    "safety",
    "clang-analyzer-*,bugprone-*,cert-*,cppcoreguidelines-*,-bugprone-easily-swappable-parameters",
    "clang-analyzer-*, bugprone-*, cert-*, cppcoreguidelines-*"
  ),
  tidy_def("performance", "performance-*,-performance-avoid-endl", "performance-*"),
  tidy_def("readability", "readability-*", "readability-*"),
  tidy_def("modernize", "modernize-*", "modernize-*"),

  -----------------------------------------------------------------------------
  -- cppcheck: different static-analysis heuristics than clang-tidy (array
  -- bounds, uninitialized use, portability) - worth running both. Same
  -- category split and single-file scope as the tidy group above.
  -----------------------------------------------------------------------------
  cppcheck_def("safety", "warning,portability", "--enable=warning,portability (UB, likely bugs, non-portable constructs)"),
  cppcheck_def("performance", "performance", "--enable=performance"),
  cppcheck_def("style", "style", "--enable=style"),

  -----------------------------------------------------------------------------
  -- lint: other single-purpose C++ static-analysis/lint tools, each its own
  -- action, shown only when installed
  -----------------------------------------------------------------------------
  {
    -- Reports headers this TU actually uses vs. what it #includes; needs a
    -- compile command, standalone -std flag is enough for a single TU.
    name = "lint: iwyu",
    desc = "Over-/under-included headers for this TU (iwyu)",
    condition_callback = function()
      return vim.fn.executable "include-what-you-use" == 1 or vim.fn.executable "iwyu" == 1
    end,
    build = function(c)
      local tool = pick { "include-what-you-use", "iwyu" }
      return { cmd = { tool, "-std=c++20", c.file } }
    end,
  },
  {
    -- The include-fixer script ships alongside iwyu, named fix_includes.py
    -- upstream but packaged as iwyu-fix-includes on Arch/EndeavourOS; pick()
    -- covers both. It parses iwyu's own diagnostic text (printed on stderr,
    -- hence 2>&1) to rewrite the file's #includes in place. --nocomments
    -- is already its default (no "why" comment after each added #include);
    -- passed explicitly since that's the point of this task, not an
    -- incidental default. Same std flag as the report-only task above so
    -- its analysis matches. The buffer isn't reloaded automatically
    -- (overseer can't reach back into the editing session), so the echo
    -- afterward is a reminder, not a no-op.
    name = "lint: iwyu auto-apply",
    desc = "Runs iwyu, then rewrites this file's #includes on disk (no why-comments)",
    condition_callback = function()
      return (vim.fn.executable "include-what-you-use" == 1 or vim.fn.executable "iwyu" == 1)
        and (vim.fn.executable "fix_includes.py" == 1 or vim.fn.executable "iwyu-fix-includes" == 1)
    end,
    build = function(c)
      local tool = pick { "include-what-you-use", "iwyu" }
      local fixer = pick { "fix_includes.py", "iwyu-fix-includes" }
      return {
        cmd = string.format(
          "%s -std=c++20 %s 2>&1 | %s --nocomments %s; "
            .. "echo; echo 'includes rewritten on disk -- run :checktime (or :e!) to reload the buffer'",
          tool,
          c.efile,
          fixer,
          c.efile
        ),
      }
    end,
  },
  {
    name = "lint: cpplint",
    desc = "Google C++ style checker",
    condition_callback = function()
      return vim.fn.executable "cpplint" == 1
    end,
    build = function(c)
      return { cmd = { "cpplint", c.file } }
    end,
  },
  {
    name = "lint: cppclean",
    desc = "Unused/dead declarations, unnecessary includes",
    condition_callback = function()
      return vim.fn.executable "cppclean" == 1
    end,
    build = function(c)
      return { cmd = { "cppclean", c.file } }
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

  -- Task output can be wider than any window (perf c2c tables, sde -mix
  -- histograms); default wrap mangles rows. nowrap + horizontal scroll
  -- (zl/zL) keeps them intact.
  vim.api.nvim_create_autocmd("FileType", {
    pattern = "OverseerOutput",
    desc = "Don't wrap wide task output (perf c2c, sde -mix, ...)",
    callback = function()
      vim.wo[0].wrap = false
      vim.wo[0].sidescrolloff = 4
    end,
  })

  for _, def in ipairs(defs) do
    -- needs_bin/no_buffer defs (codebase-wide tools, or ones taking an
    -- explicit binary) don't need a C/C++ buffer open; only compile/build
    -- tasks reading the buffer as source require filetype cpp/c.
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
      -- def.params may be a table or a function (likwid: perfctr reads its
      -- group choices from `likwid-perfctr -a`); eval it either way, then
      -- tack on the auto bin/args params.
      local base = def.params
      params = function()
        local schema = {}
        if type(base) == "function" then
          schema = base() or {}
        else
          for k, v in pairs(base or {}) do
            schema[k] = v
          end
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
        -- needs_bin/no_buffer defs skip ctx() (blank paths with no file
        -- open); cwd falls back to Neovim's own cwd instead.
        local c = skip_buffer and {} or ctx()
        local task = def.build(c, params)
        task.name = task.name or def.name
        task.cwd = task.cwd or (skip_buffer and vim.fn.getcwd() or c.dir)
        if def.quickfix then
          task.components = task.components
            or { { "on_output_quickfix", open_on_error = true }, "default" }
        end

        -- First output line is the literal command; a needs_bin task also
        -- shows the binary's build age (defs can add more via info_lines,
        -- e.g. a snapshot's own age) so a stale artifact is obvious upfront.
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

      local group, action = def.name:match "^(.-): (.+)$"
      group = group or def.name
      action = action or def.name
      if not M._by_group[group] then
        M._by_group[group] = {}
        M._group_order[#M._group_order + 1] = group
      end
      local group_list = M._by_group[group]
      group_list[#group_list + 1] = { name = def.name, action = action }

      -- Templates with an enum_pick get the third telescope level (see
      -- open_enum_pick in telescope_run): the choice is passed as a preset
      -- param, so it never goes through the vim.ui.input chain below.
      if def.enum_pick then
        M._enum_picks[def.name] = def.enum_pick
      end

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

  -- Chains vim.ui.input one field at a time; a blank required field
  -- cancels the whole task.
  local function chain_prompts(overseer, name, prompts, idx, collected)
    local spec = prompts[idx]
    if not spec then
      overseer.run_task { name = name, params = collected }
      return
    end
    -- spec.default may be a function (e.g. likwid's quiet-core pick, which
    -- must be re-read fresh each time rather than baked in at setup()).
    local default = spec.default
    if type(default) == "function" then
      default = default()
    end
    vim.ui.input({ prompt = spec.label, default = default, completion = spec.completion }, function(value)
      if (not value or value == "") and spec.required ~= false then
        return
      end
      collected[spec.key] = value or ""
      chain_prompts(overseer, name, prompts, idx + 1, collected)
    end)
  end

  -- Size a picker to its longest entry plus padding, capped at 75% of the
  -- terminal width. Shared by both the tool-level and action-level pickers.
  local function width_for(strs)
    local longest = 0
    for _, s in ipairs(strs) do
      longest = math.max(longest, #s)
    end
    return math.min(longest + 30, math.floor(vim.o.columns * 0.75))
  end

  -- run_selected(name[, preset]): preset pre-fills params chosen in a
  -- higher telescope level (e.g. likwid-perfctr's group), skipping the
  -- vim.ui.input chain for them.
  local function run_selected(name, preset)
    if vim.api.nvim_buf_is_valid(src_buf) then
      vim.api.nvim_set_current_buf(src_buf)
    end
    local prompts = M._prompts[name]
    if prompts then
      chain_prompts(overseer, name, prompts, 1, preset or {})
    else
      overseer.run_task { name = name, params = preset or {} }
    end
  end

  local open_actions -- forward decl: open_enum_pick's <BS> handler reopens it

  -- Third level (optional, per-template): pick one enum param in a picker
  -- instead of vim.ui.input. Only likwid-perfctr registers one today (its
  -- -g group, via def.enum_pick), but the machinery is generic. <BS> on an
  -- empty prompt backs out to the action list, like action -> tool above.
  local function open_enum_pick(name, enum, group)
    local choices = type(enum.choices) == "function" and enum.choices() or enum.choices
    if not choices or #choices == 0 then
      -- No list available (likwid-perfctr missing or empty -a): skip the
      -- picker; overseer's own schema default fills the param.
      run_selected(name)
      return
    end
    local labels = {}
    local by_label = {}
    for _, c in ipairs(choices) do
      local label = (c.desc and c.desc ~= "") and (c.value .. ": " .. c.desc) or c.value
      labels[#labels + 1] = label
      by_label[label] = c.value
    end

    pickers
      .new(themes.get_dropdown { layout_config = { width = width_for(labels), height = 0.6 } }, {
        prompt_title = enum.title,
        finder = finders.new_table { results = labels },
        sorter = conf.generic_sorter {},
        attach_mappings = function(prompt_bufnr, map)
          actions.select_default:replace(function()
            local entry = action_state.get_selected_entry()
            actions.close(prompt_bufnr)
            if not entry then
              return
            end
            run_selected(name, { [enum.key] = by_label[entry[1]] })
          end)
          map({ "i", "n" }, "<bs>", function()
            if action_state.get_current_line() == "" then
              actions.close(prompt_bufnr)
              open_actions(group)
            else
              vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<bs>", true, false, true), "n", true)
            end
          end)
          return true
        end,
      })
      :find()
  end

  -- Second level: scrollable list of actions for one tool. <BS> on an
  -- empty prompt backs out to the tool list instead of closing outright.
  open_actions = function(group)
    local entries = M._by_group[group]
    local labels = {}
    for _, e in ipairs(entries) do
      labels[#labels + 1] = e.action
    end
    local by_label = {}
    for _, e in ipairs(entries) do
      by_label[e.action] = e.name
    end

    pickers
      .new(themes.get_dropdown { layout_config = { width = width_for(labels), height = 0.6 } }, {
        prompt_title = "Overseer: " .. group,
        finder = finders.new_table { results = labels },
        sorter = conf.generic_sorter {},
        attach_mappings = function(prompt_bufnr, map)
          actions.select_default:replace(function()
            local entry = action_state.get_selected_entry()
            actions.close(prompt_bufnr)
            if not entry then
              return
            end
            local name = by_label[entry[1]]
            local enum = M._enum_picks[name]
            if enum then
              open_enum_pick(name, enum, group)
            else
              run_selected(name)
            end
          end)
          map({ "i", "n" }, "<bs>", function()
            if action_state.get_current_line() == "" then
              actions.close(prompt_bufnr)
              M._open_tools()
            else
              vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<bs>", true, false, true), "n", true)
            end
          end)
          return true
        end,
      })
      :find()
  end

  -- First level: one entry per tool (perf, asm, valgrind, ...).
  function M._open_tools()
    pickers
      .new(themes.get_dropdown { layout_config = { width = width_for(M._group_order), height = 0.6 } }, {
        prompt_title = "Overseer: tools",
        finder = finders.new_table { results = M._group_order },
        sorter = conf.generic_sorter {},
        attach_mappings = function(prompt_bufnr)
          actions.select_default:replace(function()
            local entry = action_state.get_selected_entry()
            actions.close(prompt_bufnr)
            if not entry then
              return
            end
            open_actions(entry[1])
          end)
          return true
        end,
      })
      :find()
  end

  M._open_tools()
end

return M
