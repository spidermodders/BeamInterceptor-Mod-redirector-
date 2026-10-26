-- CoolModUtils: shared helpers for the mod menu.
--   Scheduler  timed and repeating tasks. A failing task is logged and never stops the others.
--   Hooker     replace a function of a loaded extension and hand back the original.
--   Windows    a small declarative layer over imgui (labels, buttons, checkboxes, inputs, sections).

local M = {}
M.dependencies = {"ui_imgui"}

local ffi = require("ffi")
local im -- ui_imgui, resolved on first use so load order never matters

local LOG_TAG = "CoolModUtils"

----------------------------------------------------------------------------------------------------
-- Scheduler
----------------------------------------------------------------------------------------------------

local Scheduler = {}
local tasks = {}
local nextTaskId = 1
local clock = 0

--- Runs func(...) once after `seconds`. Returns a task id for Scheduler.avoidFunction.
function Scheduler.delayfunction(seconds, func, params)
	local id = nextTaskId
	nextTaskId = id + 1
	tasks[id] = {time = clock + seconds, func = func, params = params}
	return id
end

--- Runs func(...) every `interval` seconds. If func returns a number, that is the delay until the next run.
function Scheduler.every(interval, func, params)
	local id = nextTaskId
	nextTaskId = id + 1
	tasks[id] = {time = clock + interval, interval = interval, func = func, params = params}
	return id
end

--- Cancels a task. Unknown ids and nil are ignored.
function Scheduler.avoidFunction(id)
	if id then tasks[id] = nil end
end

local function runTask(id, task)
	if not task.interval then tasks[id] = nil end

	local ok, result = pcall(task.func, unpack(task.params or {}))
	if not ok and not task.failed then
		task.failed = true -- one log line per task, not one per run
		log("E", LOG_TAG, "scheduled task failed: " .. tostring(result))
	end

	if task.interval and tasks[id] == task then
		task.time = clock + ((ok and type(result) == "number") and result or task.interval)
	end
end

function Scheduler.update(dt)
	clock = clock + dt

	local due
	for id, task in pairs(tasks) do
		if task.time <= clock then
			due = due or {}
			due[#due + 1] = id
		end
	end
	if not due then return end

	table.sort(due)
	for _, id in ipairs(due) do
		local task = tasks[id]
		if task then runTask(id, task) end
	end
end

----------------------------------------------------------------------------------------------------
-- Hooker
----------------------------------------------------------------------------------------------------

local Hooker = {}
local hooks = {}   -- "Extension.function" -> {original, replacement}
local pending = {} -- "Extension.function" -> true while waiting for the extension to appear
local HOOK_RETRY_SECONDS = 0.5
local HOOK_MAX_TRIES = 240

function Hooker.IsHookable(extensionName, functionName)
	local extension = extensions[extensionName]
	return extension ~= nil and type(extension[functionName]) == "function"
end

--- Replaces extensions[extensionName][functionName] with newFunction as soon as that function exists.
--- onHooked(originalFunction) is called once the hook is in place. Hooking twice is a no-op, and a
--- reloaded extension gets hooked again.
function Hooker.HookFunction(extensionName, functionName, newFunction, onHooked)
	local key = extensionName .. "." .. functionName
	if pending[key] then return end
	pending[key] = true

	local function attempt(tries)
		pending[key] = nil
		local extension = extensions[extensionName]
		local current = extension and extension[functionName]

		if type(current) == "function" then
			local entry = hooks[key]
			if entry and current == entry.replacement then return end -- already hooked

			extension[functionName] = newFunction
			hooks[key] = {original = current, replacement = newFunction}
			extensions.hookUpdate(functionName) -- hooks are cached, so the cache has to be rebuilt
			if onHooked then onHooked(current) end
		elseif tries < HOOK_MAX_TRIES then
			pending[key] = true
			Scheduler.delayfunction(HOOK_RETRY_SECONDS, attempt, {tries + 1})
		end
	end

	attempt(0)
end

--- Puts the original function back, but only if nothing else replaced our hook in the meantime.
function Hooker.Unhook(extensionName, functionName)
	local key = extensionName .. "." .. functionName
	local entry = hooks[key]
	hooks[key] = nil
	pending[key] = nil

	local extension = extensions[extensionName]
	if entry and extension and extension[functionName] == entry.replacement then
		extension[functionName] = entry.original
		extensions.hookUpdate(functionName)
	end
end

----------------------------------------------------------------------------------------------------
-- Windows
----------------------------------------------------------------------------------------------------
-- Element types: label, value, button, row, checkbox, slider, textinput, separator, spacer, section.
-- Common fields: Hidden = function() -> boolean, Tooltip = string.
--   label      Text | TextFunc, Color = {r,g,b,a} | function, Centered
--   value      Label, TextFunc, Color: label on the left, value right aligned
--   button     Text | TextFunc, OnClick, Width | Fill
--   row        Children = {buttons}: shares the line equally between them
--   checkbox   Label, Get = function() -> boolean, Set = function(boolean)
--   slider     Label, Get = function() -> integer, Set = function(integer), Min, Max, Format
--   textinput  Label, Get = function() -> value, Set = function(text), Width
--   section    Title, DefaultOpen, Children = {elements}

local windows = {}
local drawers = {}
local uiScale = 1 -- scale of the window being drawn
local contentRight = 0 -- right edge of the content area of the window being drawn

local THEME = {
	accent = {0.96, 0.56, 0.16, 1.0},
	text = {0.91, 0.92, 0.95, 1.0},
	dim = {0.55, 0.57, 0.63, 1.0},
	colors = {
		{"Col_Text", {0.91, 0.92, 0.95, 1.0}},
		{"Col_TextDisabled", {0.55, 0.57, 0.63, 1.0}},
		{"Col_WindowBg", {0.07, 0.075, 0.09, 0.97}},
		{"Col_PopupBg", {0.10, 0.105, 0.125, 0.98}},
		{"Col_Border", {1.0, 1.0, 1.0, 0.07}},
		{"Col_TitleBg", {0.07, 0.075, 0.09, 1.0}},
		{"Col_TitleBgActive", {0.11, 0.09, 0.07, 1.0}},
		{"Col_TitleBgCollapsed", {0.07, 0.075, 0.09, 0.9}},
		{"Col_FrameBg", {0.13, 0.14, 0.17, 1.0}},
		{"Col_FrameBgHovered", {0.17, 0.18, 0.22, 1.0}},
		{"Col_FrameBgActive", {0.21, 0.22, 0.27, 1.0}},
		{"Col_CheckMark", {0.96, 0.56, 0.16, 1.0}},
		{"Col_SliderGrab", {0.96, 0.56, 0.16, 0.85}},
		{"Col_SliderGrabActive", {1.0, 0.65, 0.25, 1.0}},
		{"Col_Button", {0.15, 0.16, 0.20, 1.0}},
		{"Col_ButtonHovered", {0.80, 0.46, 0.13, 1.0}},
		{"Col_ButtonActive", {0.96, 0.56, 0.16, 1.0}},
		{"Col_Header", {0.12, 0.125, 0.15, 1.0}},
		{"Col_HeaderHovered", {0.17, 0.15, 0.13, 1.0}},
		{"Col_HeaderActive", {0.22, 0.17, 0.12, 1.0}},
		{"Col_Separator", {1.0, 1.0, 1.0, 0.08}},
	},
	vars = {
		{"StyleVar_WindowRounding", 10},
		{"StyleVar_FrameRounding", 6},
		{"StyleVar_GrabRounding", 6},
		{"StyleVar_PopupRounding", 6},
		{"StyleVar_GrabMinSize", 10},
		{"StyleVar_WindowBorderSize", 1},
		{"StyleVar_FrameBorderSize", 0},
	},
	vec2Vars = { -- third value false: a ratio, not scaled with the window
		{"StyleVar_WindowPadding", {14, 12}},
		{"StyleVar_ItemSpacing", {8, 6}},
		{"StyleVar_ItemInnerSpacing", {6, 4}},
		{"StyleVar_FramePadding", {10, 6}},
		{"StyleVar_WindowTitleAlign", {0.5, 0.5}, false},
	},
}

local function vec4(c) return im.ImVec4(c[1], c[2], c[3], c[4] or 1) end

-- Style pushes fail soft: an imgui build that lacks a constant just keeps its default look.
local function pushTheme()
	local colorCount, varCount = 0, 0
	for _, entry in ipairs(THEME.colors) do
		local index = im[entry[1]]
		if index and im.PushStyleColor2 then
			im.PushStyleColor2(index, vec4(entry[2]))
			colorCount = colorCount + 1
		end
	end
	for _, entry in ipairs(THEME.vars) do
		local index = im[entry[1]]
		if index and im.PushStyleVar1 then
			im.PushStyleVar1(index, entry[2] * uiScale)
			varCount = varCount + 1
		end
	end
	for _, entry in ipairs(THEME.vec2Vars) do
		local index = im[entry[1]]
		if index and im.PushStyleVar2 then
			local scale = entry[3] == false and 1 or uiScale
			im.PushStyleVar2(index, im.ImVec2(entry[2][1] * scale, entry[2][2] * scale))
			varCount = varCount + 1
		end
	end
	return colorCount, varCount
end

local function popTheme(colorCount, varCount)
	if colorCount > 0 then im.PopStyleColor(colorCount) end
	if varCount > 0 then im.PopStyleVar(varCount) end
end

local function isHidden(element)
	return element.Hidden and element.Hidden() or false
end

local function textOf(element)
	if element.TextFunc then return element.TextFunc() end
	return element.Text or ""
end

local function showTooltip(element)
	if element.Tooltip and im.IsItemHovered() then im.SetTooltip(element.Tooltip) end
end

local function drawElements(list)
	for _, element in ipairs(list) do
		if not isHidden(element) then
			local draw = drawers[element.Type]
			if draw then draw(element) end
		end
	end
end

drawers.label = function(element)
	local text = textOf(element)
	if element.Centered then
		local padding = (im.GetWindowWidth() - im.CalcTextSize(text).x) * 0.5
		im.SetCursorPosX(math.max(padding, 0))
	end

	local color = element.Color
	if type(color) == "function" then color = color() end
	if color then
		im.TextColored(vec4(color), text)
	else
		im.Text(text)
	end
	showTooltip(element)
end

drawers.value = function(element)
	local text = textOf(element)
	im.TextColored(vec4(THEME.dim), element.Label or "")
	im.SameLine()
	im.SetCursorPosX(math.max(im.GetCursorPosX(), contentRight - im.CalcTextSize(text).x))
	local color = element.Color
	if type(color) == "function" then color = color() end
	im.TextColored(vec4(color or THEME.text), text)
	showTooltip(element)
end

drawers.button = function(element)
	local width = element.rowWidth or (element.Fill and contentRight - im.GetCursorPosX()) or (element.Width or 0) * uiScale
	if im.Button(textOf(element) .. "##" .. element.id, im.ImVec2(width, 0)) and element.OnClick then
		element.OnClick()
	end
	showTooltip(element)
end

drawers.row = function(element)
	local visible = {}
	for _, child in ipairs(element.Children or {}) do
		if not isHidden(child) then visible[#visible + 1] = child end
	end
	if #visible == 0 then return end

	local spacing = 8 * uiScale
	local width = (contentRight - im.GetCursorPosX() - spacing * (#visible - 1)) / #visible
	for i, child in ipairs(visible) do
		if i > 1 then im.SameLine(0, spacing) end
		child.rowWidth = width
		local draw = drawers[child.Type]
		if draw then draw(child) end
	end
end

-- Enabled options read bright, disabled ones dimmed.
drawers.checkbox = function(element)
	element.pointer = element.pointer or im.BoolPtr(false)
	element.pointer[0] = element.Get() and true or false
	local dimmed = not element.pointer[0] and im.PushStyleColor2 and im.Col_Text
	if dimmed then im.PushStyleColor2(im.Col_Text, vec4(THEME.dim)) end
	local clicked = im.Checkbox(element.Label .. "##" .. element.id, element.pointer)
	if dimmed then im.PopStyleColor() end
	if clicked then element.Set(element.pointer[0]) end
	showTooltip(element)
end

drawers.textinput = function(element)
	local value = tostring(element.Get())
	if not element.buffer then
		element.buffer = im.ArrayChar(64, value)
		element.lastValue = value
	elseif element.lastValue ~= value then -- changed from outside (settings load), keep the box in step
		element.buffer = im.ArrayChar(64, value)
		element.lastValue = value
	end

	im.Text(element.Label)
	im.SameLine()
	im.SetNextItemWidth((element.Width or 70) * uiScale)
	if im.InputText("##" .. element.id, element.buffer) then
		local text = ffi.string(element.buffer)
		element.lastValue = text
		element.Set(text)
	end
	showTooltip(element)
end

-- Integer slider. If the imgui build rejects the call, falls back to - / + buttons.
drawers.slider = function(element)
	local value = element.Get()
	im.AlignTextToFramePadding()
	im.Text(element.Label or "")
	showTooltip(element)
	im.SameLine()
	if not element.fallback then
		element.pointer = element.pointer or im.IntPtr(value)
		element.pointer[0] = value
		im.SetNextItemWidth(math.max(contentRight - im.GetCursorPosX(), 40 * uiScale))
		local ok, moved = pcall(im.SliderInt, "##" .. element.id, element.pointer, element.Min or 0, element.Max or 100, element.Format or "%d")
		if ok then
			if moved then element.Set(element.pointer[0]) end
		else
			element.fallback = true
			log("W", LOG_TAG, "SliderInt unavailable, using buttons: " .. tostring(moved))
		end
	end
	if element.fallback then
		local step = element.Step or 10
		if im.Button("-##" .. element.id, im.ImVec2(28 * uiScale, 0)) then element.Set(math.max(element.Min or 0, value - step)) end
		im.SameLine()
		if im.Button("+##" .. element.id, im.ImVec2(28 * uiScale, 0)) then element.Set(math.min(element.Max or 100, value + step)) end
		im.SameLine()
		im.Text(string.format(element.Format or "%d", value))
	end
	showTooltip(element)
end

drawers.separator = function() im.Separator() end

drawers.spacer = function(element)
	im.Dummy(im.ImVec2(0, (element.Height or 4) * uiScale))
end

-- A framed header bar over the full width. Without NoTreePushOnOpen the node pushes a tree level
-- that has to be popped again.
drawers.section = function(element)
	local noPush = im.TreeNodeFlags_NoTreePushOnOpen
	local flags = (element.DefaultOpen and im.TreeNodeFlags_DefaultOpen or 0)
		+ (im.TreeNodeFlags_Framed or 0) + (im.TreeNodeFlags_SpanAvailWidth or 0) + (noPush or 0)
	local tinted = im.PushStyleColor2 and im.Col_Text
	if tinted then im.PushStyleColor2(im.Col_Text, vec4(THEME.accent)) end
	local open = im.TreeNodeEx1(element.Title .. "##" .. element.id, flags)
	if tinted then im.PopStyleColor() end

	if open then
		local indent = 6 * uiScale
		if noPush then im.Indent(indent) end
		local ok, err = pcall(drawElements, element.Children or {})
		if noPush then im.Unindent(indent) else im.TreePop() end -- balanced even when a child failed
		im.Dummy(im.ImVec2(0, 2 * uiScale))
		if not ok then error(err, 0) end
	end
end

local nextElementId = 1
local function assignIds(list)
	for _, element in ipairs(list) do
		element.id = nextElementId
		nextElementId = nextElementId + 1
		if element.Children then assignIds(element.Children) end
	end
end

-- Returns an error message when drawing failed; imgui's stack is balanced either way.
local function renderWindow(window)
	uiScale = window.Scale and window.Scale() or 1
	local colorCount, varCount = pushTheme()
	window.openPointer[0] = true

	im.SetNextWindowPos(im.ImVec2(window.x, window.y), im.Cond_FirstUseEver)
	local failure
	if im.Begin(window.name, window.openPointer, window.flags) then
		im.SetWindowFontScale(uiScale) -- text, checkboxes and frames grow with the font
		contentRight = im.GetCursorPosX() + window.width * uiScale
		im.Dummy(im.ImVec2(window.width * uiScale, 0)) -- fixes the window width, the height follows the content
		local ok, err = pcall(drawElements, window.elements)
		if not ok then failure = err end
	end
	im.End() -- always, also when the window is collapsed

	popTheme(colorCount, varCount)
	if not window.openPointer[0] then window.Visible = false end -- the title bar X closes the window
	return failure
end

--- Creates a window that draws itself every frame while window.Visible is true.
--- options: Visible (default true), Width (default 340), X, Y, Scale = function() -> factor, Elements = {...}
function M.CreateWindow(name, options)
	im = im or ui_imgui
	options = options or {}

	local window = {
		name = name,
		width = options.Width or 340,
		x = options.X or 60,
		y = options.Y or 120,
		elements = options.Elements or {},
		Visible = options.Visible ~= false,
		Scale = options.Scale, -- function() -> number, 1 is normal size
		openPointer = im.BoolPtr(true),
		flags = im.WindowFlags_NoDocking + im.WindowFlags_AlwaysAutoResize,
	}
	assignIds(window.elements)

	function window:Destroy()
		for i = #windows, 1, -1 do
			if windows[i] == self then table.remove(windows, i) end
		end
	end

	windows[#windows + 1] = window
	return window
end

function M.GetWindow(name)
	for _, window in ipairs(windows) do
		if window.name == name then return window end
	end
end

local function onUpdate(dtReal, dtSim, dtRaw)
	Scheduler.update(dtRaw or dtReal or 0)

	for _, window in ipairs(windows) do
		if window.Visible then
			local ok, err = pcall(renderWindow, window)
			if err then
				window.Visible = false -- a broken window must not take the game's UI loop down
				log("E", LOG_TAG, "window '" .. window.name .. "' failed and was hidden: " .. tostring(err))
			end
		end
	end
end

M.Scheduler = Scheduler
M.Hooker = Hooker
M.onUpdate = onUpdate
M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
