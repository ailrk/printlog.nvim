-- printlog.lua
-- Insert a print/log line prefixed with "folder/file.c:24 function_name: ",
-- tagged with a trailing "@print" comment so it's easy to delete later.
--
-- INSTALL
--   Save as ~/.config/nvim/lua/printlog.lua, then in init.lua:
--     require("printlog").setup()
--
-- KEYS
--   <leader>lo   insert log line below
--   <leader>lO   insert log line above
--   <leader>ld   delete all @print lines in the buffer (:PrintLogClean)
--
-- Tagged lines also show as warnings via vim.diagnostic (diagnostics = false
-- to disable).
--
-- `path:line` works with `gF` (jump to file and line).
-- Function name comes from Treesitter. Haskell uses traceM (import Debug.Trace).

local M = {}

M.config = {
  -- how many trailing path components to show: 2 -> "folder/file.c"
  path_depth = 2,
  -- prefix layout. Placeholders: {path} {line} {func}
  -- "{path}:{line} {func}: " keeps `gF` working on the path.
  format = "{path}:{line} {func}: ",
  -- used when no function is found
  format_no_func = "{path}:{line}: ",
  -- keymaps (set to false to disable)
  keymap_below = "<leader>lo",
  keymap_above = "<leader>lO",
  keymap_clean = "<leader>ld",  -- delete all tagged lines in the current buffer
  -- marker appended as a trailing comment on every inserted line
  tag = "@print",
  -- show a diagnostic on every tagged line (like an LSP warning)
  diagnostics = true,
  diagnostic_severity = "WARN",   -- ERROR | WARN | INFO | HINT
  diagnostic_message = "debug print left in code (@print)",
  -- $P is replaced by the prefix; the cursor lands right after it
  templates = {
    c          = 'printf("$P");',
    cpp        = 'printf("$P");',
    cs         = 'Console.WriteLine("$P");',
    go         = 'fmt.Println("$P")',
    java       = 'System.out.println("$P");',
    javascript = 'console.log("$P");',
    typescript = 'console.log("$P");',
    javascriptreact = 'console.log("$P");',
    typescriptreact = 'console.log("$P");',
    lua        = 'print("$P")',
    python     = 'print(f"$P")',
    rust       = 'println!("$P");',
    sh         = 'echo "$P"',
    bash       = 'echo "$P"',
    zsh        = 'echo "$P"',
    php        = 'echo "$P";',
    ruby       = 'puts "$P"',
    vim        = 'echom "$P"',
    haskell    = 'traceM "$P"',  -- needs: import Debug.Trace
  },
  default_template = 'print("$P")',
}

-- Neovim's TSNode has no child_by_field_name; :field(name) returns a list.
local function field(node, name)
  local f = node:field(name)
  return f and f[1] or nil
end

-- Node types that count as "a function" across common grammars.
local FUNC_TYPES = {
  function_definition = true,   -- c, cpp, python, lua(ish), bash, php
  function_declaration = true,  -- js, ts, go, lua, c#
  function_item = true,         -- rust
  method_definition = true,     -- js, ts
  method_declaration = true,    -- go, java, c#
  constructor_declaration = true,
  function_statement = true,    -- lua
  function_declaration_statement = true,
  arrow_function = true,
  function_expression = true,
  ["function"] = true,
  function_signature = true,
  method = true,                -- ruby
  singleton_method = true,
  bind = true,                  -- haskell: `foo = ...` with no arguments
  -- haskell's `function` node is already covered by ["function"] above
}

-- Dig the identifier out of a (possibly nested) C-style declarator.
local function name_from_declarator(node, bufnr)
  while node do
    local t = node:type()
    if t == "identifier" or t == "field_identifier"
        or t == "qualified_identifier" or t == "destructor_name" then
      return vim.treesitter.get_node_text(node, bufnr)
    end
    local nxt = field(node, "declarator")
        or field(node, "name")
    if not nxt then
      -- fall back: first identifier-looking child
      for child in node:iter_children() do
        if child:type():find("identifier") then
          return vim.treesitter.get_node_text(child, bufnr)
        end
      end
      return nil
    end
    node = nxt
  end
end

local function find_function_name(bufnr, row, col)
  local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, pos = { row, col } })
  if not ok or not node then return nil end

  while node do
    if FUNC_TYPES[node:type()] then
      local name_node = field(node, "name")
      local name
      if name_node then
        name = vim.treesitter.get_node_text(name_node, bufnr)
      else
        local decl = field(node, "declarator")
        if decl then name = name_from_declarator(decl, bufnr) end
      end

      -- anonymous function assigned to a variable: const foo = () => {}
      if not name then
        local parent = node:parent()
        if parent and (parent:type() == "variable_declarator"
              or parent:type() == "pair"
              or parent:type() == "assignment_expression") then
          local n = field(parent, "name")
              or field(parent, "key")
              or field(parent, "left")
          if n then name = vim.treesitter.get_node_text(n, bufnr) end
        end
      end

      if name and name ~= "" then return name end
    end
    node = node:parent()
  end
  return nil
end

local function short_path(depth)
  local full = vim.api.nvim_buf_get_name(0)
  if full == "" then return "[No Name]" end
  local parts = vim.split(full, "/", { plain = true, trimempty = true })
  local from = math.max(1, #parts - depth + 1)
  return table.concat(vim.list_slice(parts, from, #parts), "/")
end

local function build_prefix(line_number, func)
  local cfg = M.config
  local fmt = func and cfg.format or cfg.format_no_func
  local out = fmt
      :gsub("{path}", function() return short_path(cfg.path_depth) end)
      :gsub("{line}", function() return tostring(line_number) end)
      :gsub("{func}", function() return func or "" end)
  return out
end

local ns = vim.api.nvim_create_namespace("printlog")

-- Mark every line containing the tag with a diagnostic.
local function refresh_diagnostics(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  local cfg = M.config
  if not cfg.diagnostics then
    vim.diagnostic.reset(ns, bufnr)
    return
  end
  local severity = vim.diagnostic.severity[cfg.diagnostic_severity] or vim.diagnostic.severity.WARN
  local diags = {}
  for i, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    local col = line:find(cfg.tag, 1, true)
    if col then
      diags[#diags + 1] = {
        lnum = i - 1,
        col = col - 1,
        end_col = col - 1 + #cfg.tag,
        severity = severity,
        source = "printlog",
        message = cfg.diagnostic_message,
      }
    end
  end
  vim.diagnostic.set(ns, bufnr, diags)
end

-- Build the comment, e.g. "// @print", "-- @print", "# @print".
local function tag_comment()
  local tag = M.config.tag
  local cs = vim.bo.commentstring
  local ft = vim.bo.filetype
  -- Prefer line comments for C-family, even if commentstring is "/* %s */".
  if cs == "" or ((ft == "c" or ft == "cpp") and cs:find("/*", 1, true)) then
    cs = "// %s"
  end
  return (cs:gsub("%%s", function() return tag end))
end

local function insert_log(above)
  local cfg = M.config
  local bufnr = vim.api.nvim_get_current_buf()
  local cur = vim.api.nvim_win_get_cursor(0) -- {1-based row, 0-based col}
  local cur_row = cur[1]
  local cur_line = vim.api.nvim_buf_get_lines(bufnr, cur_row - 1, cur_row, false)[1] or ""

  -- Line the new print statement will occupy (1-based).
  local new_line_number = above and cur_row or cur_row + 1

  -- Look up the function at the cursor (0-based row/col for treesitter).
  local first_nonblank = #(cur_line:match("^%s*") or "")
  local func = find_function_name(bufnr, cur_row - 1, math.max(cur[2], first_nonblank))

  local prefix = build_prefix(new_line_number, func)
  local template = cfg.templates[vim.bo.filetype] or cfg.default_template

  -- Indent like the current line. If the current line opens a block
  -- (ends with { or :) and we're going below, indent one extra level.
  local indent = cur_line:match("^%s*") or ""
  local opens_block = cur_line:match("[{:]%s*$")
  if vim.bo.filetype == "haskell" then
    opens_block = opens_block
        or cur_line:match("%f[%w_]do%s*$")
        or cur_line:match("%f[%w_]where%s*$")
        or cur_line:match("%f[%w_]of%s*$")
        or cur_line:match("%f[%w_]let%s*$")
  end
  if not above and opens_block then
    local sw = vim.fn.shiftwidth()
    indent = indent .. (vim.bo.expandtab and string.rep(" ", sw) or "\t")
  end

  local marker = template:find("$P", 1, true)
  local text = template:gsub("%$P", function() return prefix end)
  -- Trailing comment with the tag so the line is easy to find/delete later.
  local full = indent .. text .. "  " .. tag_comment()

  local insert_at = above and (cur_row - 1) or cur_row
  vim.api.nvim_buf_set_lines(bufnr, insert_at, insert_at, false, { full })

  -- Cursor: right after the prefix, still inside the string.
  local col = #indent + (marker - 1) + #prefix
  vim.api.nvim_win_set_cursor(0, { insert_at + 1, col })
  refresh_diagnostics(bufnr)
  vim.cmd("startinsert")
end

function M.below() insert_log(false) end
function M.above() insert_log(true) end

-- Delete every line in the current buffer that contains the tag.
function M.clean()
  local tag = M.config.tag
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local removed = 0
  for i = #lines, 1, -1 do
    if lines[i]:find(tag, 1, true) then
      vim.api.nvim_buf_set_lines(bufnr, i - 1, i, false, {})
      removed = removed + 1
    end
  end
  refresh_diagnostics(bufnr)
  vim.notify(("printlog: removed %d line(s) tagged %s"):format(removed, tag))
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  local cfg = M.config

  if cfg.keymap_below then
    vim.keymap.set("n", cfg.keymap_below, M.below, { desc = "Print log below (file:line func)" })
  end
  if cfg.keymap_above then
    vim.keymap.set("n", cfg.keymap_above, M.above, { desc = "Print log above (file:line func)" })
  end
  if cfg.keymap_clean then
    vim.keymap.set("n", cfg.keymap_clean, M.clean, { desc = "Delete all tagged print logs in buffer" })
  end
  vim.api.nvim_create_user_command("PrintLogClean", M.clean, {})

  -- Keep diagnostics up to date as buffers load and change.
  local group = vim.api.nvim_create_augroup("printlog", { clear = true })
  vim.api.nvim_create_autocmd(
    { "BufEnter", "BufReadPost", "TextChanged", "InsertLeave", "BufWritePost" },
    { group = group, callback = function(ev) refresh_diagnostics(ev.buf) end }
  )
  refresh_diagnostics(vim.api.nvim_get_current_buf())
end

return M
