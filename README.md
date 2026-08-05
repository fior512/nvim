**This repo is supposed to be used as config by NvChad users!**

- The main nvchad repo (NvChad/NvChad) is used as a plugin by this repo.
- So you just import its modules , like `require "nvchad.options" , require "nvchad.mappings"`
- So you can delete the .git from this repo ( when you clone it locally ) or fork it :)


it is my config for c++ hpc daily work, and have zenbone-based theme (few changes)

<img width="2540" height="1382" alt="image" src="https://github.com/user-attachments/assets/a13714ad-98b4-4c0f-9c35-f2eaae4c7315" />

## Overseer tasks (`<leader>oo`)

C/C++ task templates in `lua/configs/overseer.lua`. Tasks marked "needs bin" prompt for the executable path (blank = guessed `<file>:r`). Some only appear if their tool is installed.

| Task | Goal |
|---|---|
| `C++: compile` | build with a chosen mode (debug/release/lto/asan+ubsan/tsan/asm-dump/vec-report/pgo) |
| `C++: run` | run an already-built binary |
| `C++: build+run` | compile release -O3 then run, in one step |
| `perf: stat` | default + max-detail hardware counters |
| `perf: stat microarch` | SIMD-relevant counters: split loads, op-cache fallout, FP faults |
| `perf: report` | record + symbol-level hotspot report |
| `perf: annotate` | record + line-level annotated hotspots |
| `perf: script` | record + raw event dump |
| `perf: flamegraph` | record + build a flamegraph SVG |
| `perf: c2c` | record + false-sharing/cache-line contention report |
| `bcc: funccount` | live call counts on functions in the binary |
| `bcc: funclatency` | live per-function latency histogram |
| `asm: disassemble` | source-interleaved disassembly of a symbol |
| `asm: create snapshot` | save normalized disassembly of a symbol |
| `asm: diff snapshot` | diff current disassembly against a saved snapshot |
| `asm: hazard scan` | grep disassembly for spills, width splits, gather/scatter, div/sqrt |
| `mca: throughput` | llvm-mca port-pressure/throughput model of a symbol |
| `uica: throughput` | uiCA uop-cache/frontend throughput model of a symbol |
| `pahole: layout` | struct/class padding, holes, cacheline boundaries |
| `valgrind: memcheck` | leak/invalid-memory detection |
| `valgrind: callgrind` | deterministic instruction-count profiling |
| `valgrind: callgrind annotate` | per-function breakdown of the latest callgrind run |
| `valgrind: massif` | heap profiling |
| `valgrind: massif print` | readable report of the latest massif run |
| `valgrind: helgrind` | thread race detection |
| `toplev: attribution` | top-down frontend/backend/speculation breakdown |
| `sde: mix` | dynamic instruction histogram by category/ISA extension |
| `sde: ast` | AVX/SSE transition stall detection |
| `sde: mask profile` | AVX-512 mask-register lane utilization |
| `sde: emulate` | run under an ISA level this machine lacks |
| `bloaty: sizes` | symbol/section size breakdown |
| `bloaty: create snapshot` | save a copy of the binary for size diffing |
| `bloaty: diff snapshot` | diff current binary size against a saved snapshot |
| `clang-tidy: check` | static analysis, standalone (no compile_commands.json needed) |
| `clang-tidy: fix` | static analysis with auto-fixes applied |
| `rr: record` | record an execution trace |
| `rr: replay` | replay the last recorded trace |
