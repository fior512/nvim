local MIN_BLANK_LINES = 3

-- pads blank lines after each closer to MIN_BLANK_LINES
local function min_blank_lines(is_closer)
  return function(_, _, lines, callback)
    local out = {}
    local i = 1
    while i <= #lines do
      local line = lines[i]
      table.insert(out, line)
      if is_closer(line) then
        local j = i + 1
        local blanks = 0
        while j <= #lines and lines[j]:match "^%s*$" do
          blanks = blanks + 1
          j = j + 1
        end
        if j <= #lines then
          for _ = 1, math.max(MIN_BLANK_LINES, blanks) do
            table.insert(out, "")
          end
          i = j - 1
        end
      end
      i = i + 1
    end
    callback(nil, out)
  end
end

-- brace-style declaration end
local function brace_closer(line)
  return line:match "^}" ~= nil or line:match "^%S.*{.*}%s*$" ~= nil
end

-- stylua block end
local function lua_closer(line)
  return line:match "^end%s*$" ~= nil
end

local options = {
  formatters = {
    min_blank_lines_brace = { format = min_blank_lines(brace_closer) },
    min_blank_lines_lua = { format = min_blank_lines(lua_closer) },
  },
  formatters_by_ft = {
    lua = { "stylua", "min_blank_lines_lua" },
    c = { "clang-format", "min_blank_lines_brace" },
    cpp = { "clang-format", "min_blank_lines_brace" },
    rust = { "rustfmt", "min_blank_lines_brace" },
    go = { "gofumpt", "min_blank_lines_brace" },
  },
}

return options
