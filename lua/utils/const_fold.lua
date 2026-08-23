-- Shows the compile-time value of constant integer expressions (e.g.
-- `512 / (8*5)`) as virtual text right after the expression, so integer
-- truncation/overflow surprises are visible while typing instead of only
-- at runtime.
local M = {}

local ns = vim.api.nvim_create_namespace "const_fold"
local timers = {}

local BIN_OPS = { "+", "-", "*", "/", "%", "<<", ">>", "&", "|", "^" }
local IS_BIN_OP = {}
for _, op in ipairs(BIN_OPS) do
  IS_BIN_OP[op] = true
end

-- Nodes whose *own* successful fold would already cover a folded child, so
-- the child shouldn't get a redundant hint of its own.
local FOLDABLE_PARENT = {
  binary_expression = true,
  unary_expression = true,
  parenthesized_expression = true,
}

local function parse_int(text)
  -- strip integer-literal suffixes (u/U/l/L in any combination)
  local clean = text:gsub("[uUlL]+$", "")
  if clean:match "%." or clean:match "[eE][%+%-]?%d" then
    return nil -- floating point, not handled
  end
  return tonumber(clean)
end

local function trunc_div(lv, rv)
  local q = lv / rv
  return q >= 0 and math.floor(q) or math.ceil(q)
end

local eval

local function eval_binary(node, buf)
  local left = node:field "left"[1]
  local right = node:field "right"[1]
  local opnode = node:field "operator"[1]
  if not (left and right and opnode) then
    return nil
  end
  local op = vim.treesitter.get_node_text(opnode, buf)
  if not IS_BIN_OP[op] then
    return nil
  end
  local lv, rv = eval(left, buf), eval(right, buf)
  if not lv or not rv then
    return nil
  end
  if op == "+" then
    return lv + rv
  elseif op == "-" then
    return lv - rv
  elseif op == "*" then
    return lv * rv
  elseif op == "/" then
    if rv == 0 then
      return nil
    end
    return trunc_div(lv, rv)
  elseif op == "%" then
    if rv == 0 then
      return nil
    end
    return lv - rv * trunc_div(lv, rv)
  elseif op == "<<" then
    return lv << rv
  elseif op == ">>" then
    return lv >> rv
  elseif op == "&" then
    return lv & rv
  elseif op == "|" then
    return lv | rv
  elseif op == "^" then
    return lv ~ rv
  end
end

local function eval_unary(node, buf)
  local arg = node:field "argument"[1]
  local opnode = node:field "operator"[1]
  if not (arg and opnode) then
    return nil
  end
  local op = vim.treesitter.get_node_text(opnode, buf)
  local v = eval(arg, buf)
  if not v then
    return nil
  end
  if op == "-" then
    return -v
  elseif op == "+" then
    return v
  elseif op == "~" then
    return ~v
  end
end

eval = function(node, buf)
  local t = node:type()
  if t == "number_literal" then
    return parse_int(vim.treesitter.get_node_text(node, buf))
  elseif t == "parenthesized_expression" then
    local inner = node:named_child(0)
    return inner and eval(inner, buf) or nil
  elseif t == "binary_expression" then
    return eval_binary(node, buf)
  elseif t == "unary_expression" then
    return eval_unary(node, buf)
  end
  return nil
end

function M.refresh(buf)
  buf = buf or 0
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

  local ok_lang, lang = pcall(vim.treesitter.language.get_lang, vim.bo[buf].filetype)
  if not ok_lang or not lang then
    return
  end
  local ok_parser, parser = pcall(vim.treesitter.get_parser, buf, lang)
  if not ok_parser or not parser then
    return
  end
  local tree = parser:parse()[1]
  if not tree then
    return
  end

  local ok_query, query = pcall(vim.treesitter.query.parse, lang, "(binary_expression) @e")
  if not ok_query then
    return
  end

  for _, node in query:iter_captures(tree:root(), buf) do
    local value = eval(node, buf)
    if value then
      local parent = node:parent()
      local shadowed = parent and FOLDABLE_PARENT[parent:type()] and eval(parent, buf) ~= nil
      if not shadowed then
        local end_row, end_col = node:end_()
        vim.api.nvim_buf_set_extmark(buf, ns, end_row, end_col, {
          -- "@lsp.type.comment" is the dimmed color autocmds.lua assigns to
          -- inactive #if/#else branches -- reuse it so folded-constant hints
          -- read as "compile-time known" the same way those branches do.
          virt_text = { { " = " .. tostring(value), "@lsp.type.comment" } },
          virt_text_pos = "inline",
        })
      end
    end
  end
end

local function refresh_debounced(buf)
  if timers[buf] then
    timers[buf]:stop()
  end
  timers[buf] = vim.defer_fn(function()
    timers[buf] = nil
    if vim.api.nvim_buf_is_valid(buf) then
      M.refresh(buf)
    end
  end, 150)
end

function M.enable(buf)
  buf = buf or 0
  if vim.b[buf].const_fold_enabled then
    return
  end
  vim.b[buf].const_fold_enabled = true
  refresh_debounced(buf)
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave" }, {
    buffer = buf,
    group = vim.api.nvim_create_augroup("const_fold_" .. buf, { clear = true }),
    callback = function()
      refresh_debounced(buf)
    end,
  })
end

function M.disable(buf)
  buf = buf or 0
  vim.b[buf].const_fold_enabled = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  pcall(vim.api.nvim_del_augroup_by_name, "const_fold_" .. buf)
end

function M.toggle(buf)
  buf = buf or 0
  if vim.b[buf].const_fold_enabled then
    M.disable(buf)
  else
    M.enable(buf)
  end
end

return M
