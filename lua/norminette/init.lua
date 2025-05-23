local M = {}

M.version = "0.6"

M.dependencies = { "nvim-lua/plenary.nvim", "echasnovski/mini.icons" }
M.namespace = vim.api.nvim_create_namespace("norminette")
M.toggle_state = false
M.quickfix = false
M.show_size = true

local has_plenary, async = pcall(require, "plenary.async")
if not has_plenary then
	error("This plugin requires plenary.nvim. Please install it to use this plugin.")
end

local function parse_norminette_output(output)
	local diagnostics = {}
	local current_file = nil
	for line in output:gmatch("[^\r\n]+") do
		if line:match(": Error!$") then
			current_file = line:match("^(.+): Error!$")
		elseif line:match("^Error:") then
			local error_type, line_num, col_num, message =
				line:match("^Error:%s+([A-Z_]*)%s*%pline:%s*(%d+), col:%s+(%d+)%p:(.*)") -- FUCK REGEX
			if error_type and line_num and col_num and message then
				local diagnostic = {
					bufnr = vim.fn.bufnr(current_file),
					lnum = tonumber(line_num) - 1,
					col = tonumber(col_num) - 4,
					severity = vim.diagnostic.severity.ERROR,
					source = "norminette",
					message = error_type .. " : " .. message:gsub("^%s*", ""),
				}
				table.insert(diagnostics, diagnostic)
			else
				print("Failed to parse error line:", line)
			end
		end
	end
	return diagnostics
end

local function clear_diagnostics(namespace, bufnr)
	vim.diagnostic.reset(namespace, bufnr)
end

local function run_norminette_check(bufnr, namespace)
	if vim.bo.modified and not vim.bo.readonly and vim.fn.expand("%") ~= "" and vim.bo.buftype == "" then
		vim.api.nvim_command("silent update")
	end
	local filename = vim.api.nvim_buf_get_name(bufnr)
	async.run(function()
		local output = vim.fn.system("norminette " .. vim.fn.shellescape(filename))
		return output
	end, function(output)
			local diagnostics = parse_norminette_output(output)
			vim.schedule(function()
				vim.diagnostic.reset(namespace, bufnr)
				vim.diagnostic.set(namespace, bufnr, diagnostics)
			end)
		end)
end

local function update_status()
	local icons_ok, icons = pcall(require, "mini.icons")
	if not icons_ok then
		error("This plugin requires mini.icons. Please install it to use this plugin.")
		return
	end

	local icon = icons.get("filetype", "nginx")
	if M.toggle_state then
		vim.api.nvim_set_hl(0, "NorminetteStatus", { fg = "#00ff00", bold = true })
		vim.opt.statusline:append("%#NorminetteStatus#")
		vim.opt.statusline:append(" " .. icon .. " ")
		vim.opt.statusline:append("%*")
	else
		vim.opt.statusline = vim.opt.statusline:get():gsub("%#NorminetteStatus#%s*%" .. icon .. "%s*%%*", "")
	end
end

local function correct_filetype()
	local file_type = vim.bo.filetype
	return file_type == "c" or file_type == "cpp" -- h is identified with cpp... idk why
end

local function update_function_sizes(bufnr)
	vim.api.nvim_buf_clear_namespace(bufnr, M.namespace, 0, -1)
	local parser = vim.treesitter.get_parser(bufnr, "c")
	if not parser then
		print("Failed Parsing")
		return
	end
	local tree = parser:parse()[1]
	local root = tree:root()

	local query = vim.treesitter.query.parse(
		"c",
		[[
        (function_definition) @declaration
    ]]
	)
	for _, node in query:iter_captures(root, bufnr, 0, -1) do
		local start_row, _, end_row, _ = node:range()
		local size = end_row - start_row - 2

		vim.api.nvim_buf_set_extmark(bufnr, M.namespace, start_row, 0, {
			virt_text = { { "Size: " .. size .. " lines", "Comment" } },
			virt_text_pos = "eol",
		})
	end
end

local function setup_autocmds_and_run(bufnr)
	-- vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufEnter", "BufWritePost" }, {
	vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost" }, {
		pattern = { "*.c", "*.h" },
		callback = function()
			run_norminette_check(bufnr, M.namespace)
		end,
		group = vim.api.nvim_create_augroup("NorminetteAutoCheck", { clear = true }),
	})
end

local function setup_size_autocmd(bufnr)
	update_function_sizes(bufnr)
	run_norminette_check(bufnr, M.namespace)
	-- vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufEnter", "BufWritePost" }, {
	vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost" }, {
		pattern = { "*.c", ".h" },
		callback = function()
			update_function_sizes(bufnr)
		end,
		group = vim.api.nvim_create_augroup("NorminetteFunctionSize", { clear = true }),
	})
end

local function clear_autocmds_and_messages(bufnr)
	vim.api.nvim_clear_autocmds({ group = "NorminetteAutoCheck" })
	clear_diagnostics(M.namespace, bufnr)
end

local function clear_function_sizes(bufnr)
	if pcall(vim.api.nvim_get_autocmds, { group = "NorminetteFunctionSize" }) then
		vim.api.nvim_clear_autocmds({ group = "NorminetteFunctionSize" })
	end
	vim.api.nvim_buf_clear_namespace(bufnr, M.namespace, 0, -1)
end

local function toggle_norminette_quick()
	if not correct_filetype() then
		print("Norminette only runs in .c or .h files")
		return
	end
	local bufnr = vim.api.nvim_get_current_buf()
	M.quickfix = not M.quickfix
	if M.quickfix then
		run_norminette_check(bufnr, M.namespace)
		update_status()
		vim.diagnostic.setqflist()
	end
end


local function update_quickfix(bufnr, namespace)
	if vim.bo.modified and not vim.bo.readonly and vim.fn.expand("%") ~= "" and vim.bo.buftype == "" then
		vim.api.nvim_command("silent update")
	end
	local filename = vim.api.nvim_buf_get_name(bufnr)
	local output = vim.fn.system("norminette " .. vim.fn.shellescape(filename))
	local diagnostics = parse_norminette_output(output)
	if next(diagnostics) == nil then
		print("🥳 normi is happy 🥳")
	end
	vim.diagnostic.reset(namespace, bufnr)
	-- vim.diagnostic.reset()
	-- vim.fn.setqflist({}, 'r')
	vim.diagnostic.set(namespace, bufnr, diagnostics)
	vim.diagnostic.setqflist({namespace = namespace, open = true, title = "normi"})
end

local function setup_bufferlocal_aucmd(bufnr, namespace)
  local group = vim.api.nvim_create_augroup("NormiBufferLocalAutocmd" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd({ "BufWritePost" }, {
    group = group,
    buffer = bufnr,
    callback = function()
			print("✨ Updating normi... ✨")
			update_quickfix(bufnr, namespace)
    end,
  })

	-- remove all autocmds for a buffer on Leave, Delete
  -- vim.api.nvim_create_autocmd({"BufLeave", "BufDelete"}, {
  vim.api.nvim_create_autocmd({"BufDelete"}, {
    group = group,
    buffer = bufnr,
    callback = function()
      vim.api.nvim_del_augroup_by_name("NormiBufferLocalAutocmd" .. bufnr)
      -- print("Buffer-local autocommands cleared for buffer " .. bufnr)
    end,
  })
end

-- My normi oneshot user function.
-- 
-- Creates a new namespace for storing the buffer-local norminette diagnostics.
local function oneshot()
	if M.toggle_state then
		return
	end
	if not correct_filetype() then
		print("Norminette only runs in .c or .h files")
		return
	end
	print("🔫 NorminetteOneshot 🔫")
	local bufnr = vim.api.nvim_get_current_buf()
	local namespace = vim.api.nvim_create_namespace("normi" .. bufnr)
	setup_bufferlocal_aucmd(bufnr, namespace)
	update_quickfix(bufnr, namespace)
end


local function toggle_norminette()
	if not correct_filetype() then
		print("Norminette only runs in .c or .h files")
		return
	end
	local bufnr = vim.api.nvim_get_current_buf()
	M.toggle_state = not M.toggle_state
	if M.toggle_state then
		setup_autocmds_and_run(bufnr)
		print("NorminetteAutoCheck enable")
		run_norminette_check(bufnr, M.namespace)
	else
		clear_autocmds_and_messages(bufnr)
		print("NorminetteAutoCheck disable")
	end
	update_status()
end

local function toggle_size()
	if not correct_filetype() then
		print("Norminette only runs in .c or .h files")
		return
	end
	local bufnr = vim.api.nvim_get_current_buf()
	M.show_size = not M.show_size
	if M.show_size then
		setup_size_autocmd(bufnr)
		print("Norminette show_size enable")
	else
		clear_function_sizes(bufnr)
		print("Norminette show_size disable")
	end
end

function M.setup(opts)
	opts = opts or {}
	local default_opts = {
		norm_keybind = "<leader>n",
		size_keybind = "<leader>ns",
		diagnostic_color = "#00ff00",
		show_size = true,
		quickfix = true,
	}
	for key, value in pairs(default_opts) do
		if opts[key] == nil then
			opts[key] = value
		end
	end

	M.quickfix = opts.quickfix

	M.show_size = opts.show_size
	if opts.norm_keybind then
		vim.keymap.set("n", opts.norm_keybind, toggle_norminette, { noremap = true, silent = true })
	end

	if opts.size_keybind then
		vim.keymap.set("n", opts.size_keybind, toggle_size, { noremap = true, silent = true })
	end
	vim.api.nvim_set_hl(0, "NorminetteDiagnostic", { fg = opts.diagnostic_color })
	vim.api.nvim_create_user_command("NorminetteToggle", function()
		toggle_norminette()
	end, {})
	vim.api.nvim_create_user_command("NorminetteQuickToggle", function()
		toggle_norminette_quick()
	end, {})
	vim.api.nvim_create_user_command("NorminetteOneshot", function()
		oneshot()
	end, {})
	vim.api.nvim_create_user_command("NorminetteSizeToggle", function()
		toggle_size()
	end, {})

	vim.diagnostic.config({
		virtual_text = {
			format = function(diagnostic)
				if diagnostic.namespace == M.namespace then
					return string.format("%s", diagnostic.message)
				end
				return diagnostic.message
			end,
			prefix = "●",
			hl_group = "NorminetteDiagnostic",
		},
	}, M.namespace)

	-- vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufEnter", "BufWritePost" }, {
	vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost" }, {
		group = vim.api.nvim_create_augroup("NorminetteInitialUpdate", { clear = false }),
		pattern = { "*.c", "*.h" },
		callback = function()
			if M.toggle_state then
				local bufnr = vim.fn.bufnr(vim.fn.bufname())
				if M.quickfix then
					run_norminette_check(bufnr, M.namespace)
					vim.diagnostic.setqflist()
				else
					run_norminette_check(bufnr, M.namespace)
				end
			end
		end,
	})
	-- vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufEnter", "BufWritePost" }, {
	vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost" }, {
		group = vim.api.nvim_create_augroup("NorminetteInitialUpdate", { clear = false }),
		pattern = { "*.c", "*.h" },
		callback = function(ev)
			if M.show_size then
				update_function_sizes(ev.buf)
			end
		end,
	})
end

return M
