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
	if filetype == "bash" or filetype == "sh" then
		if pos == 1 and line:sub(1, 2) == "#!" then
			return true
		end
		local before = line:sub(1, pos - 1)
		local after = line:sub(pos)

		if before:match("%${[^}]*$") and after:match("^[#%%]") then
			return true
		end

		if before:match("%${$") and after:match("^#[^}]*}") then
			return true
		end
	end

	if filetype == "nix" and line:match("^%s*#!%/bin%/sh%s*$") then
		return true
	end

	if filetype == "elixir" then
		local hash_pos = line:find("#", 1, true)
		if hash_pos and line:sub(hash_pos + 1, hash_pos + 1) == "{" then
			return true
		end

		local first_nonspace = line:match("^%s*(.)")
		if first_nonspace == '"' then
			return true
		end
	end

	local in_string_single = false
	local in_string_double = false
	local in_backtick = false
	local in_regex = false
	local in_percent_string = false
	local percent_char = nil

	for i = 1, pos do
		local char = line:sub(i, i)
		local prev_char = i > 1 and line:sub(i - 1, i - 1) or ""

		if not in_percent_string then
			if char == "'" and prev_char ~= "\\" and not in_string_double and not in_backtick then
				in_string_single = not in_string_single
			elseif char == '"' and prev_char ~= "\\" and not in_string_single and not in_backtick then
				in_string_double = not in_string_double
			elseif char == "`" and prev_char ~= "\\" and not in_string_single and not in_string_double then -- NEW
				in_backtick = not in_backtick
			elseif
				filetype == "ruby"
				and char == "/"
				and not in_string_single
				and not in_string_double
				and not in_backtick
				and prev_char ~= "\\"
			then
				in_regex = not in_regex
			end
		end

		if not in_percent_string and char == "%" then
			local next_char = line:sub(i + 1, i + 1)
			if next_char == "q" or next_char == "Q" then
				local delim = line:sub(i + 2, i + 2)
				if delim == "{" then
					in_percent_string = true
					percent_char = "}"
				elseif delim == "(" then
					in_percent_string = true
					percent_char = ")"
				elseif delim == "[" then
					in_percent_string = true
					percent_char = "]"
				elseif delim == "<" then
					in_percent_string = true
					percent_char = ">"
				end
			end
		elseif in_percent_string and char == percent_char and prev_char ~= "\\" then
			in_percent_string = false
		end
	end

	for _, h in ipairs(heredocs) do
		if line:find(h.delim, 1, true) then
			return true
		end
	end

	return in_string_single or in_string_double or in_backtick or in_regex or in_percent_string
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
