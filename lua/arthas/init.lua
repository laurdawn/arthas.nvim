-- Copy an Arthas command to the "+ and " registers. Nothing is executed locally.
-- The key after <leader>ya is the command's first letter. A second command that
-- shares that letter uses the uppercase key, or another free letter from the name.
-- On a class name, method name, or inside a method body, treesitter supplies the
-- current class and method. On a call, jdtls hover is used. If that fails, the
-- current class and method are used.
-- stop, shutdown, reset, redefine, and mc are omitted. They change a live JVM.
local M = {}

local TYPE_NODES = {
	class_declaration = true,
	interface_declaration = true,
	enum_declaration = true,
	record_declaration = true,
	annotation_type_declaration = true,
}

local function hover_text(contents)
	if type(contents) == "string" then
		return contents
	end
	if type(contents) ~= "table" then
		return nil
	end
	if type(contents.value) == "string" then
		return contents.value
	end
	local parts = {}
	for _, item in ipairs(contents) do
		if type(item) == "string" then
			parts[#parts + 1] = item
		elseif type(item) == "table" and type(item.value) == "string" then
			parts[#parts + 1] = item.value
		end
	end
	if #parts == 0 then
		return nil
	end
	return table.concat(parts, "\n")
end

local function signature_line(text)
	if not text or text == "" then
		return nil
	end
	local code = text:match("```%s*java%s*\n(.-)```") or text:match("```%s*\n(.-)```")
	local src = code or text
	for line in src:gmatch("[^\r\n]+") do
		line = line:gsub("^%s+", ""):gsub("%s+$", "")
		if line ~= "" and not line:match("^```") then
			return line
		end
	end
end

-- com.foo.Outer.Inner -> com.foo.Outer$Inner.
-- Lowercase segments stay in the package. From the first uppercase segment, join with $.
function M.to_binary_name(dotted)
	if not dotted or dotted == "" then
		return dotted
	end
	local pkg, types = {}, {}
	local seen_type = false
	for part in vim.gsplit(dotted, ".", { plain = true, trimempty = true }) do
		local is_pkg = not seen_type and part:match("^[%l_]") and not part:find("$", 1, true)
		if is_pkg then
			pkg[#pkg + 1] = part
		else
			seen_type = true
			types[#types + 1] = part
		end
	end
	local class = table.concat(types, "$")
	if #pkg == 0 then
		return class
	end
	if class == "" then
		return table.concat(pkg, ".")
	end
	return table.concat(pkg, ".") .. "." .. class
end

-- First line of a jdtls hover. A method is a dotted name immediately followed by "(".
-- Otherwise the longest dotted name that starts with a lowercase segment is used.
-- An ALL_CAPS last segment is a field. Returns nil when nothing qualifies.
function M.parse_hover(sig)
	if type(sig) ~= "string" or sig == "" then
		return nil
	end
	local method_fqn
	for ident in sig:gmatch("([%a_][%w_%.%$]*)%s*%(") do
		if ident:find(".", 1, true) and ident:match("^[%l_]") then
			method_fqn = ident
		end
	end
	if method_fqn then
		local class, method = method_fqn:match("^(.*)%.(%a[%w_]*)$")
		if class and class ~= "" and method then
			return { class = M.to_binary_name(class), method = method }
		end
	end
	local best
	for ident in sig:gmatch("([%a_][%w_%.%$]+)") do
		if ident:find(".", 1, true) and ident:match("^[%l_]") and (not best or #ident > #best) then
			best = ident
		end
	end
	if not best then
		return nil
	end
	local class_part, field = best:match("^(.*)%.(%u[%u%d_]*)$")
	if field and class_part and class_part ~= "" then
		return { class = M.to_binary_name(class_part), field = field }
	end
	return { class = M.to_binary_name(best) }
end

local function node_text(node, buf)
	return vim.treesitter.get_node_text(node, buf)
end

local function name_of(node, buf)
	local names = node:field("name")
	if names and names[1] then
		return node_text(names[1], buf)
	end
end

local function package_name(root, buf)
	for child in root:iter_children() do
		if child:type() == "package_declaration" then
			for part in child:iter_children() do
				local t = part:type()
				if t == "scoped_identifier" or t == "identifier" then
					return node_text(part, buf)
				end
			end
		end
	end
end

-- Calls, field access, and type references are not declared in this file. Ask jdtls.
local function should_use_lsp(node)
	if not node then
		return false
	end
	local t = node:type()
	if t ~= "identifier" and t ~= "type_identifier" then
		return false
	end
	local parent = node:parent()
	if not parent then
		return false
	end
	local pt = parent:type()
	local call_sites = {
		method_invocation = true,
		method_reference = true,
		field_access = true,
		object_creation_expression = true,
		marker_annotation = true,
		annotation = true,
		scoped_identifier = true,
	}
	if call_sites[pt] then
		return true
	end
	if t == "type_identifier" and not TYPE_NODES[pt] then
		return true
	end
	return false
end

local function field_name(node, buf)
	local cur = node
	while cur do
		local t = cur:type()
		if TYPE_NODES[t] or t == "method_declaration" or t == "constructor_declaration" then
			return nil
		end
		if t == "variable_declarator" then
			local name = cur:field("name")[1]
			local parent = cur:parent()
			if name and parent and parent:type() == "field_declaration" and node:equal(name) then
				return node_text(name, buf)
			end
		end
		cur = cur:parent()
	end
end

-- class is the binary name. method is the enclosing method, or "<init>".
-- field is set when the cursor is on a field name. use_lsp marks a call site.
function M.context(buf)
	buf = buf or vim.api.nvim_get_current_buf()
	if vim.bo[buf].filetype ~= "java" then
		return {}
	end
	local ok, parser = pcall(vim.treesitter.get_parser, buf, "java")
	if not ok or not parser then
		return {}
	end
	local tree_ok, trees = pcall(function()
		return parser:parse()
	end)
	if not tree_ok or not trees or not trees[1] then
		return {}
	end
	local pos = vim.api.nvim_win_get_cursor(0)
	local node = vim.treesitter.get_node({ bufnr = buf, pos = { pos[1] - 1, pos[2] }, lang = "java" })
	if not node then
		return {}
	end
	local pkg = package_name(trees[1]:root(), buf)
	local types = {}
	local method
	local cur = node
	while cur do
		local t = cur:type()
		if TYPE_NODES[t] then
			local name = name_of(cur, buf)
			if name and name ~= "" then
				types[#types + 1] = name
			end
		elseif not method and t == "constructor_declaration" then
			method = "<init>"
		elseif not method and t == "method_declaration" then
			method = name_of(cur, buf)
		end
		cur = cur:parent()
	end
	local ordered = {}
	for i = #types, 1, -1 do
		ordered[#ordered + 1] = types[i]
	end
	local class
	if #ordered > 0 then
		local binary = table.concat(ordered, "$")
		class = pkg and (pkg .. "." .. binary) or binary
	end
	return {
		class = class,
		method = method,
		field = field_name(node, buf),
		use_lsp = should_use_lsp(node),
	}
end

function M.resolve(cb)
	local ts = M.context()
	if not ts.use_lsp then
		cb(ts)
		return
	end
	local clients = vim.lsp.get_clients({ bufnr = 0, name = "jdtls" })
	if #clients == 0 then
		vim.notify("jdtls is not attached; using the current class and method", vim.log.levels.WARN)
		ts.use_lsp = false
		cb(ts)
		return
	end
	local client = clients[1]
	local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
	client:request("textDocument/hover", params, function(err, result)
		vim.schedule(function()
			local parsed = not err and result and M.parse_hover(signature_line(hover_text(result.contents)))
			if parsed and parsed.class and parsed.class ~= "" then
				cb(parsed)
				return
			end
			vim.notify("could not resolve the call; using the current class and method", vim.log.levels.WARN)
			cb(ts)
		end)
	end, 0)
end

local function watch(t)
	return ("watch %s %s '{params,returnObj,throwExp}' -n 5 -x 3"):format(t.class, t.method)
end

local function ognl(t)
	if t.field and t.field ~= "" then
		return ("ognl '@%s@%s'"):format(t.class, t.field)
	end
	return ("ognl '@%s@%s()'"):format(t.class, t.method)
end

-- needs: none | class | method | field | member
local commands = {
	{ id = "jad", key = "j", desc = "jad decompile", needs = "class", build = function(t)
		if t.method and t.method ~= "" then
			return ("jad %s %s"):format(t.class, t.method)
		end
		return "jad " .. t.class
	end },
	{ id = "jvm", key = "J", desc = "jvm", needs = "none", build = function()
		return "jvm"
	end },
	{ id = "sc", key = "s", desc = "sc search class", needs = "class", build = function(t)
		return "sc -d " .. t.class
	end },
	{ id = "sm", key = "S", desc = "sm methods", needs = "class", build = function(t)
		if t.method and t.method ~= "" then
			return ("sm -d %s %s"):format(t.class, t.method)
		end
		return "sm " .. t.class
	end },
	{ id = "watch", key = "w", desc = "watch", needs = "method", build = watch },
	{ id = "trace", key = "t", desc = "trace", needs = "method", build = function(t)
		return ("trace %s %s -n 5"):format(t.class, t.method)
	end },
	{ id = "thread", key = "T", desc = "thread -n 5", needs = "none", build = function()
		return "thread -n 5"
	end },
	{ id = "deadlock", key = "b", desc = "thread -b", needs = "none", build = function()
		return "thread -b"
	end },
	{ id = "dashboard", key = "d", desc = "dashboard", needs = "none", build = function()
		return "dashboard"
	end },
	{ id = "monitor", key = "m", desc = "monitor", needs = "method", build = function(t)
		return ("monitor -c 5 %s %s"):format(t.class, t.method)
	end },
	{ id = "memory", key = "M", desc = "memory", needs = "none", build = function()
		return "memory"
	end },
	{ id = "classloader", key = "c", desc = "classloader", needs = "none", build = function()
		return "classloader -l"
	end },
	{ id = "logger", key = "l", desc = "logger", needs = "none", build = function()
		return "logger"
	end },
	{ id = "ognl", key = "o", desc = "ognl", needs = "member", build = ognl },
	{ id = "heapdump", key = "h", desc = "heapdump", needs = "none", build = function()
		return "heapdump"
	end },
	{ id = "getstatic", key = "g", desc = "getstatic", needs = "field", build = function(t)
		return ("getstatic %s %s"):format(t.class, t.field)
	end },
	{ id = "stack", key = "k", desc = "stack", needs = "method", build = function(t)
		return ("stack %s %s -n 5"):format(t.class, t.method)
	end },
	{ id = "tt", key = "u", desc = "tt", needs = "method", build = function(t)
		return ("tt -t %s %s -n 5"):format(t.class, t.method)
	end },
	{ id = "profiler", key = "p", desc = "profiler start", needs = "none", build = function()
		return "profiler start"
	end },
	{ id = "profiler_stop", key = "P", desc = "profiler stop", needs = "none", build = function()
		return "profiler stop"
	end },
	{ id = "vmtool", key = "v", desc = "vmtool", needs = "class", build = function(t)
		return ("vmtool -x 3 --action getInstances --className %s --limit 1"):format(t.class)
	end },
	{ id = "sysprop", key = "r", desc = "sysprop", needs = "none", build = function()
		return "sysprop"
	end },
	{ id = "sysenv", key = "e", desc = "sysenv", needs = "none", build = function()
		return "sysenv"
	end },
}

local by_id = {}
for _, spec in ipairs(commands) do
	by_id[spec.id] = spec
end

function M.command_text(id, target)
	local spec = by_id[id]
	if not spec then
		return nil, "unknown command"
	end
	target = target or {}
	local needs_class = spec.needs == "class" or spec.needs == "method" or spec.needs == "field" or spec.needs == "member"
	if needs_class and (not target.class or target.class == "") then
		return nil, "no class name"
	end
	if spec.needs == "method" and (not target.method or target.method == "") then
		return nil, "no method name"
	end
	if spec.needs == "field" and (not target.field or target.field == "") then
		return nil, "no field name"
	end
	if spec.needs == "member" and (not target.field or target.field == "") and (not target.method or target.method == "") then
		return nil, "no member"
	end
	return spec.build(target)
end

local function yank_text(text)
	vim.fn.setreg("+", text)
	vim.fn.setreg('"', text)
	vim.notify(text, vim.log.levels.INFO)
end

local function prompt_missing(spec, target, err, done)
	local prompt = spec.desc .. " name: "
	if err == "no method name" then
		prompt = spec.desc .. " method name: "
	elseif err == "no field name" then
		prompt = spec.desc .. " field name: "
	end
	vim.ui.input({ prompt = prompt }, function(input)
		if not input or input == "" then
			return
		end
		if err == "no method name" then
			target.method = input
		elseif err == "no field name" then
			target.field = input
		elseif input:find("(", 1, true) then
			target.method = input:gsub("%(.*$", "")
		else
			target.field = input
		end
		done(target)
	end)
end

local function yank(id)
	local spec = by_id[id]
	return function()
		local function emit(target)
			local text, err = M.command_text(id, target)
			if not text then
				if err == "no method name" or err == "no field name" or err == "no member" then
					prompt_missing(spec, target, err, emit)
					return
				end
				vim.notify("Arthas " .. spec.desc .. ": " .. err .. ". Put the cursor on a class or method.", vim.log.levels.WARN)
				return
			end
			yank_text(text)
		end
		if spec.needs == "none" then
			emit({})
			return
		end
		if vim.bo.filetype ~= "java" then
			vim.notify("this command needs a Java file", vim.log.levels.WARN)
			return
		end
		M.resolve(emit)
	end
end

function M.setup()
	local ok, wk = pcall(require, "which-key")
	if ok then
		wk.add({ { "<leader>ya", group = "arthas" } })
	end
	for _, spec in ipairs(commands) do
		vim.keymap.set("n", "<leader>ya" .. spec.key, yank(spec.id), { desc = spec.desc, silent = true })
	end
end

return M
