local M = {}

local defaults = {
	group_by = { "static" },
	group_separator = "",
	ignore_case = true,
	format_on_save = false,
}

M.options = vim.deepcopy(defaults)

local format_on_save_group = vim.api.nvim_create_augroup("SortJavaFieldsFormatOnSave", { clear = true })

function M.setup(opts)
	M.options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})

	vim.api.nvim_clear_autocmds({ group = format_on_save_group })
	if M.options.format_on_save then
		vim.api.nvim_create_autocmd("BufWritePre", {
			group = format_on_save_group,
			pattern = "*.java",
			callback = function()
				M.sort_fields()
			end,
		})
	end
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

local function get_modifiers(field_node, bufnr)
	local mods = {}
	for child in field_node:iter_children() do
		if child:type() == "modifiers" then
			for word in vim.treesitter.get_node_text(child, bufnr):gmatch("%S+") do
				mods[word] = true
			end
		end
	end
	return mods
end

local function visibility_rank(mods)
	if mods.public then
		return 0
	end
	if mods.protected then
		return 1
	end
	if mods.private then
		return 3
	end
	return 2
end

local function group_key(mods)
	local key = {}
	for _, by in ipairs(M.options.group_by or {}) do
		if by == "static" then
			table.insert(key, mods.static and 0 or 1)
		elseif by == "final" then
			table.insert(key, mods.final and 0 or 1)
		elseif by == "visibility" then
			table.insert(key, visibility_rank(mods))
		end
	end
	return key
end

local function compare_keys(a, b)
	for i = 1, math.max(#a, #b) do
		local av, bv = a[i] or 0, b[i] or 0
		if av ~= bv then
			return av < bv
		end
	end
	return false
end

local function keys_equal(a, b)
	if #a ~= #b then
		return false
	end
	for i = 1, #a do
		if a[i] ~= b[i] then
			return false
		end
	end
	return true
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
		local mods = get_modifiers(item.field, bufnr)
		table.insert(entries, {
			name = field_name(item.field, bufnr),
			group_key = group_key(mods),
			lines = vim.api.nvim_buf_get_lines(bufnr, s_row, e_row + 1, false),
		})
	end

	table.sort(entries, function(a, b)
		if not keys_equal(a.group_key, b.group_key) then
			return compare_keys(a.group_key, b.group_key)
		end
		local an = M.options.ignore_case and a.name:lower() or a.name
		local bn = M.options.ignore_case and b.name:lower() or b.name
		return an < bn
	end)

	local sep_lines = separator_lines()
	local new_lines = {}
	local prev_key
	for _, e in ipairs(entries) do
		if prev_key and not keys_equal(prev_key, e.group_key) then
			for _, sl in ipairs(sep_lines) do
				table.insert(new_lines, sl)
			end
		end
		for _, l in ipairs(e.lines) do
			table.insert(new_lines, l)
		end
		prev_key = e.group_key
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
