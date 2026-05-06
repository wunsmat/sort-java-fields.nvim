local M = {}

local defaults = {
	group_static = true,
	group_separator = "",
	ignore_case = true,
}

M.options = vim.deepcopy(defaults)

function M.setup(opts)
	M.options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
end

local function separator_lines()
	local sep = M.options.group_separator
	if sep == false or sep == nil or type(sep) ~= "string" then
		return {}
	end
	local lines = {}
	for line in (sep .. "\n"):gmatch("([^\n]*)\n") do
		table.insert(lines, line)
	end
	return lines
end

local BODY_TYPES = {
	class_body = true,
	interface_body = true,
	enum_body = true,
	enum_body_declarations = true,
	record_body = true,
	annotation_type_body = true,
}

local function collect_bodies(node, acc)
	if BODY_TYPES[node:type()] then
		table.insert(acc, node)
	end
	for child in node:iter_children() do
		collect_bodies(child, acc)
	end
end

local function field_name(field_node, bufnr)
	for child in field_node:iter_children() do
		if child:type() == "variable_declarator" then
			local name_child = child:field("name")[1]
			if name_child then
				return vim.treesitter.get_node_text(name_child, bufnr)
			end
		end
	end
	return ""
end

local function is_static(field_node, bufnr)
	for child in field_node:iter_children() do
		if child:type() == "modifiers" then
			for word in vim.treesitter.get_node_text(child, bufnr):gmatch("%S+") do
				if word == "static" then
					return true
				end
			end
		end
	end
	return false
end

local function find_field_runs(body)
	local runs, current, pending = {}, {}, {}
	for child in body:iter_children() do
		local t = child:type()
		if t == "line_comment" or t == "block_comment" then
			table.insert(pending, child)
		elseif t == "field_declaration" then
			table.insert(current, { comments = pending, field = child })
			pending = {}
		else
			if #current > 1 then
				table.insert(runs, current)
			end
			current, pending = {}, {}
		end
	end
	if #current > 1 then
		table.insert(runs, current)
	end
	return runs
end

local function build_edit(run, bufnr)
	local first_node = run[1].comments[1] or run[1].field
	local last_node = run[#run].field
	local start_row = ({ first_node:range() })[1]
	local end_row = ({ last_node:range() })[3]

	local entries = {}
	for _, item in ipairs(run) do
		local s_node = item.comments[1] or item.field
		local s_row = ({ s_node:range() })[1]
		local e_row = ({ item.field:range() })[3]
		table.insert(entries, {
			name = field_name(item.field, bufnr),
			static = is_static(item.field, bufnr),
			lines = vim.api.nvim_buf_get_lines(bufnr, s_row, e_row + 1, false),
		})
	end

	table.sort(entries, function(a, b)
		if M.options.group_static and a.static ~= b.static then
			return a.static
		end
		local an = M.options.ignore_case and a.name:lower() or a.name
		local bn = M.options.ignore_case and b.name:lower() or b.name
		return an < bn
	end)

	local sep_lines = M.options.group_static and separator_lines() or {}
	local new_lines = {}
	local prev_static
	for _, e in ipairs(entries) do
		if M.options.group_static and prev_static ~= nil and prev_static ~= e.static then
			for _, sl in ipairs(sep_lines) do
				table.insert(new_lines, sl)
			end
		end
		for _, l in ipairs(e.lines) do
			table.insert(new_lines, l)
		end
		prev_static = e.static
	end

	return { start_row = start_row, end_row = end_row, new_lines = new_lines }
end

function M.sort_fields()
	local bufnr = vim.api.nvim_get_current_buf()
	if vim.bo[bufnr].filetype ~= "java" then
		vim.notify("SortJavaFields: not a Java buffer", vim.log.levels.WARN)
		return
	end

	local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "java")
	if not ok or not parser then
		ok, parser = pcall(vim.treesitter.get_parser, bufnr)
	end
	if not ok or not parser then
		vim.notify(
			"SortJavaFields: java treesitter parser unavailable: " .. tostring(parser),
			vim.log.levels.WARN
		)
		return
	end
	local trees = parser:parse()
	local tree = trees and trees[1]
	if not tree then
		vim.notify("SortJavaFields: failed to parse buffer", vim.log.levels.WARN)
		return
	end

	local bodies = {}
	collect_bodies(tree:root(), bodies)

	local edits = {}
	for _, body in ipairs(bodies) do
		for _, run in ipairs(find_field_runs(body)) do
			table.insert(edits, build_edit(run, bufnr))
		end
	end

	if #edits == 0 then
		vim.notify("SortJavaFields: no field block to sort", vim.log.levels.INFO)
		return
	end

	table.sort(edits, function(a, b)
		return a.start_row > b.start_row
	end)
	for _, e in ipairs(edits) do
		vim.api.nvim_buf_set_lines(bufnr, e.start_row, e.end_row + 1, false, e.new_lines)
	end

	vim.notify(("SortJavaFields: sorted %d block(s)"):format(#edits))
end

return M
