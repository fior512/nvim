local options = {
  formatters = {
    min_blank_lines = {
      -- clang-format only caps blank lines (MaxEmptyLinesToKeep: 4); it has
      -- no "minimum" option, so pad the gap after every top-level closing
      -- brace up to 2 blank lines ourselves.
      format = function(self, ctx, lines, callback)
        local out = {}
        local depth = 0
        local i = 1
        while i <= #lines do
          local line = lines[i]
          table.insert(out, line)

          local depth_before = depth
          local _, opens = line:gsub("{", "")
          local _, closes = line:gsub("}", "")
          depth = depth + opens - closes

          -- Trigger once we return to top level (depth 0), either from a
          -- multi-line block or a Google-style single-line function body.
          if depth <= 0 and (depth_before > 0 or opens > 0) then
            depth = 0
            local j = i + 1
            local blanks = 0
            while j <= #lines and lines[j]:match("^%s*$") do
              blanks = blanks + 1
              j = j + 1
            end
            if j <= #lines then
              for _ = 1, math.max(2, blanks) do
                table.insert(out, "")
              end
              i = j - 1
            end
          end
          i = i + 1
        end
        callback(nil, out)
      end,
    },
  },
  formatters_by_ft = {
    lua = { "stylua" },
    c = { "clang-format", "min_blank_lines" },
    cpp = { "clang-format", "min_blank_lines" },
    rust = { "rustfmt" },
  },
}

return options
