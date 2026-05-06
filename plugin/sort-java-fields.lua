if vim.g.loaded_sort_java_fields then
	return
end
vim.g.loaded_sort_java_fields = true

vim.api.nvim_create_user_command("SortJavaFields", function()
	require("sort-java-fields").sort_fields()
end, { desc = "Sort Java member fields alphabetically (statics first)" })
