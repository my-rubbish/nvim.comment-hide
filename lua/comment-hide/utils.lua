local M = {}

local single_patterns = {
  ["slash"] = { single = "//" },
  ["hash"] = { single = "#" },
  ["dash"] = { single = "--" },
  ["percent"] = { single = "%" },
  semicolon = { single = ";" }
}

local multi_patterns = {
  ["c"] = { multi_start = "/*", multi_end = "*/" },
  ["lua"] = { multi_start = "--[[", multi_end = "]]" },
  ["html"] = { multi_start = "<!--", multi_end = "-->" },
  ["python3"] = { multi_start = '"""', multi_end = '"""' },
  ["python1"] = { multi_start = "'''", multi_end = "'''" },
  ["ruby"] = { multi_start = "=begin", multi_end = "=end" },
  ["scala"] = { multi_start = "/**", multi_end = "*/" },
}

local comment_patterns = {
  c = { single_patterns.slash, multi_patterns.c },
  cpp = { single_patterns.slash, multi_patterns.c },
  cs = { single_patterns.slash, multi_patterns.c },
  css = { single_patterns.slash, multi_patterns.c },
  go = { single_patterns.slash, multi_patterns.c },
  java = { single_patterns.slash, multi_patterns.c },
  javascript = { single_patterns.slash, multi_patterns.c },
  javascriptreact = { single_patterns.slash, multi_patterns.c },
  typescript = { single_patterns.slash, multi_patterns.c },
  typescriptreact = { single_patterns.slash, multi_patterns.c },
  scala = { single_patterns.slash, multi_patterns.c, multi_patterns.scala },
  lua = { single_patterns.dash, multi_patterns.lua },
  python = {
    single_patterns.hash,
    multi_patterns.python3,
    multi_patterns.python1,
    single_patterns.slash,
    multi_patterns.c,
  },
  ruby = { single_patterns.hash, multi_patterns.ruby },
  r = { single_patterns.hash },
  nim = { single_patterns.hash },
  zsh = { single_patterns.hash },
  rust = { single_patterns.slash, multi_patterns.c },
  sh = { single_patterns.hash },
  html = { multi_patterns.html, single_patterns.slash, multi_patterns.c },
  markdown = { multi_patterns.html },
  php = { single_patterns.slash, single_patterns.hash, multi_patterns.c },
  scss = { single_patterns.slash, multi_patterns.c },
  vue = { multi_patterns.html, single_patterns.slash, multi_patterns.c },
  svelte = { multi_patterns.html, single_patterns.slash, multi_patterns.c },
  elixir = { single_patterns.hash },
  erlang = { single_patterns.percent },
  ["html.handlebars"] = { multi_patterns.html, single_patterns.slash, multi_patterns.c },
  nix = { single_patterns.hash },
  yaml = { single_patterns.hash },
  clojure = { single_patterns.semicolon },
  bitbake = { single_patterns.semicolon },
  cljc = { single_patterns.semicolon },
  haskell = { single_patterns.dash },
}

local function extract_heredocs(content, filetype)
  if filetype ~= "ruby" then
    return {}, content
  end

  local heredocs = {}
  local processed = content
  local i = 1

  processed = processed:gsub(
    "(<<[-~]?%s*['\"]?([%w_]+)['\"]?[\r\n])(.-)(\n%s*%2)",
    function(start, delim, content, ending)
      heredocs[i] = {
        delim = delim,
        content = start .. content .. ending,
        placeholder = "HEREDOC_" .. i .. "_",
      }
      i = i + 1
      return heredocs[i - 1].placeholder
    end
  )

  return heredocs, processed
end

local function restore_heredocs(content, heredocs)
  for _, h in ipairs(heredocs) do
    content = content:gsub(h.placeholder, h.content)
  end
  return content
end

local function is_in_string_or_special(line, pos, filetype, heredocs)
  --- shebang
  if (filetype == "bash" or filetype == "sh" or filetype == "zsh")
     and pos == 1 and line:sub(1, 2) == "#!" then
    return true
  end

  local in_sq = false      -- '
  local in_dq = false      -- "
  local in_bt = false      -- `
  local in_param = false  -- ${}
  local param_depth = 0
  local in_cmd = false    -- $()
  local cmd_depth = 0
  local in_arith = false  -- $(())
  local arith_depth = 0

  for i = 1, pos do
    local c = line:sub(i, i)
    local p = i > 1 and line:sub(i - 1, i - 1) or ""
    local n = line:sub(i + 1, i + 1)
    local nn = line:sub(i + 2, i + 2)

    -- backticks
    if not in_sq and not in_dq and c == "`" and p ~= "\\" then
      in_bt = not in_bt
    end

    if not in_bt then
      -- single quote
      if c == "'" and not in_dq and p ~= "\\" then
        in_sq = not in_sq

      -- double quote
      elseif c == '"' and not in_sq and p ~= "\\" then
        in_dq = not in_dq
      end
    end

    if not in_sq and not in_dq and not in_bt then
      -- ${ ... }
      if not in_param and c == "$" and n == "{" then
        in_param = true
        param_depth = 1
      elseif in_param then
        if c == "{" then
          param_depth = param_depth + 1
        elseif c == "}" then
          param_depth = param_depth - 1
          if param_depth == 0 then
            in_param = false
          end
        end
      end

      -- $(())
      if not in_arith and c == "$" and n == "(" and nn == "(" then
        in_arith = true
        arith_depth = 1
      elseif in_arith then
        if c == "(" then
          arith_depth = arith_depth + 1
        elseif c == ")" then
          arith_depth = arith_depth - 1
          if arith_depth == 0 then
            in_arith = false
          end
        end
      end

      -- $()
      if not in_cmd and not in_arith and c == "$" and n == "(" then
        in_cmd = true
        cmd_depth = 1
      elseif in_cmd then
        if c == "(" then
          cmd_depth = cmd_depth + 1
        elseif c == ")" then
          cmd_depth = cmd_depth - 1
          if cmd_depth == 0 then
            in_cmd = false
          end
        end
      end
    end
  end

  return
    in_sq
    or in_dq
    or in_bt
    or in_param
    or in_cmd
    or in_arith
end

function M.extract_comments(content, filetype)
  local comments = {}
  local uncommented = content

  local heredocs, processed_content = extract_heredocs(content, filetype)
  uncommented = processed_content

  local protected = {}
  uncommented = uncommented:gsub("/%*%s*>>>.-[^%*/]-*/", function(match)
    table.insert(protected, match)
    return "PROTECTED_" .. #protected .. "_"
  end)

  local patterns = comment_patterns[filetype] or {}
  for _, pattern in ipairs(patterns) do
    if pattern.multi_start and pattern.multi_end then
      if filetype == "python" and (pattern.multi_start == '"""' or pattern.multi_start == "'''") then
        local content_lines = vim.split(uncommented, "\n")
        local new_lines = {}
        local in_comment = false
        local comment_start_line = 1
        local comment_content = {}

        for i, line in ipairs(content_lines) do
          if not in_comment then
            local trimmed = line:match("^%s*(.-)%s*$")
            if trimmed == pattern.multi_start then
              in_comment = true
              comment_start_line = i
              table.insert(comment_content, line)
            else
              table.insert(new_lines, line)
            end
          else
            table.insert(comment_content, line)
            local trimmed = line:match("^%s*(.-)%s*$")
            if trimmed == pattern.multi_end then
              in_comment = false
              table.insert(comments, {
                text = table.concat(comment_content, "\n"),
                multi = true,
              })
              comment_content = {}
            end
          end
        end

        if in_comment then
          for _, l in ipairs(comment_content) do
            table.insert(new_lines, l)
          end
        end

        uncommented = table.concat(new_lines, "\n")
      else
        local lines = vim.split(uncommented, "\n")
        local new_lines = {}
        local inside_multi = false
        local comment_buf = {}
        local start_pat = pattern.multi_start
        local end_pat = pattern.multi_end
        local current_line_idx = 1

        while current_line_idx <= #lines do
          local line = lines[current_line_idx]
          local i = 1
          local output_line = ""

          while i <= #line do
            if not inside_multi then
              local s, e = line:find(vim.pesc(start_pat), i)
              if s then
                if is_in_string_or_special(line, s, filetype, {}) then
                  output_line = output_line .. line:sub(i, e)
                  i = e + 1
                else
                  inside_multi = true
                  comment_buf = { line:sub(s) }
                  output_line = output_line .. line:sub(i, s - 1)
                  i = e + 1
                end
              else
                output_line = output_line .. line:sub(i)
                break
              end
            else
              table.insert(comment_buf, line)
              local s, e = line:find(vim.pesc(end_pat), i)
              if s then
                inside_multi = false
                local comment = table.concat(comment_buf, "\n")
                table.insert(comments, { text = comment, multi = true })
                i = e + 1
                comment_buf = {}
              else
                break
              end
            end
          end

          if not inside_multi then
            table.insert(new_lines, output_line)
          end

          current_line_idx = current_line_idx + 1
        end

        uncommented = table.concat(new_lines, "\n")
      end
    end

    if pattern.single then
      local lines = vim.split(uncommented, "\n")
      local new_lines = {}

      for line_num, line in ipairs(lines) do
        local new_line = ""
        local comment_start = nil

        for i = 1, #line do
          if line:sub(i, i + #pattern.single - 1) == pattern.single then
            if not is_in_string_or_special(line, i, filetype, heredocs) then
              comment_start = i
              break
            end
          end
        end

        if comment_start then
          table.insert(comments, { text = line:sub(comment_start) })
          new_line = line:sub(1, comment_start - 1)
        else
          new_line = line
        end

        table.insert(new_lines, new_line)
      end

      uncommented = table.concat(new_lines, "\n")
    end
  end

  for i, match in ipairs(protected) do
    uncommented = uncommented:gsub("PROTECTED_" .. i .. "_", match)
  end

  uncommented = restore_heredocs(uncommented, heredocs)

  local lines = vim.split(uncommented, "\n")
  local cleaned_lines = {}
  local last_was_empty = false

  for _, line in ipairs(lines) do
    local trimmed = line:match("^%s*(.-)%s*$")
    if trimmed ~= "" then
      table.insert(cleaned_lines, line)
      last_was_empty = false
    elseif not last_was_empty then
      table.insert(cleaned_lines, "")
      last_was_empty = true
    end
  end

  while #cleaned_lines > 0 and cleaned_lines[1]:match("^%s*$") do
    table.remove(cleaned_lines, 1)
  end
  while #cleaned_lines > 0 and cleaned_lines[#cleaned_lines]:match("^%s*$") do
    table.remove(cleaned_lines)
  end

  return comments, table.concat(cleaned_lines, "\n")
end

return M
