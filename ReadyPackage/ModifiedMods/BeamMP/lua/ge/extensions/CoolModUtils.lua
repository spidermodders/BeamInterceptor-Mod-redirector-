local M = {}
local btm = {}
local drawableWindows = {}
local gfxScheduler = { tasks = {}, nextId = 0 }
local simpleHooker = {}

M.dependencies = {"ui_imgui"}

local im = ui_imgui
local ffi = require("ffi")

--[[ Better table api ]]
function btm.add(table, variable) for key, value in pairs(table) do if value == variable then return table end end table[#table + 1] = variable return table end 
function btm.remove(table, variable) local indexToRemove = nil for i, value in ipairs(table) do if value == variable then indexToRemove = i break end end if indexToRemove then table[indexToRemove] = nil end return table end 
function btm.clear(table) for k in pairs(table) do table[k] = nil end return table end 
function btm.sort(table) local numericValues = {} local otherValues = {} for _, value in ipairs(table) do if type(value) == "number" then table.insert(numericValues, value) else table.insert(otherValues, value) end end table.sort(numericValues) local sortedTable = {} for _, value in ipairs(numericValues) do table.insert(sortedTable, value) end for _, value in ipairs(otherValues) do table.insert(sortedTable, value) end return sortedTable end 
function btm.stringToTable(str, sep) local t = {} for s in string.gmatch(str, "([^" .. sep .. "]+)") do table.insert(t, s) end return t end

--[[ Better table api end ]]



--[[ GFX scheduler api ]]
gfxScheduler = {
    nextId = 1,
    tasks = {},
    freeIds = {} -- Store reusable IDs
}

function gfxScheduler.delayfunction(seconds, func, params)
    local id

    if #gfxScheduler.freeIds > 0 then
        id = table.remove(gfxScheduler.freeIds) -- Reuse an old ID
    else
        id = gfxScheduler.nextId
        gfxScheduler.nextId = gfxScheduler.nextId + 1
    end

    gfxScheduler.tasks[id] = {
        time = os.clock() + seconds,
        func = func,
		params = params
    }
    return id
end

function gfxScheduler.avoidFunction(id)
    if gfxScheduler.tasks[id] then
        gfxScheduler.tasks[id] = nil
        table.insert(gfxScheduler.freeIds, id) -- Mark ID as reusable
    end
end

function gfxScheduler.update()
    local now = os.clock()
    for id, task in pairs(gfxScheduler.tasks) do
        if now >= task.time then
            if task.params then
                (task.func)(unpack(task.params))
            else
                (task.func)()
            end
            gfxScheduler.tasks[id] = nil
            table.insert(gfxScheduler.freeIds, id) -- Recycle ID
        end
    end
end

--[[Gfx scheduler api end]]



--[[ Simple hooker api: ]]

function simpleHooker.IsHookable(ExtensionName, FunctionName)
	return (extensions[ExtensionName] and extensions[ExtensionName][FunctionName]) and true or false
end

function simpleHooker.HookFunction(ExtensionName, FunctionName, InjectionSpeed, NewFunction, OnHookedFunction, DeferInjection)
	if DeferInjection or not extensions[ExtensionName] then
		gfxScheduler.delayfunction(InjectionSpeed or 0.05, simpleHooker.HookFunction, {
			ExtensionName, FunctionName, InjectionSpeed, NewFunction, OnHookedFunction
		})
	else
		local OldFunction = extensions[ExtensionName][FunctionName]
		extensions[ExtensionName][FunctionName] = NewFunction
		extensions.hookUpdate(FunctionName)
		if OnHookedFunction then
			OnHookedFunction(OldFunction) -- Fire connection and give it the old function
		end
	end
end

--[[ Simple hooker api end ]]



--[[ ezImgUI api ]]
local function getText(element)
    if element.TextFunc then
        return element.TextFunc() -- Call function to get text
    else
        return element.Text or "" -- Use fixed text if no function is provided
    end
end

local function DontRenderElement(Element)
	return Element.DoNotRender or Element.DoNotRenderFunc and Element.DoNotRenderFunc()
end

local function toPercentage(part, total)
    if total == 0 then
        return 0
    end
    return part / total
end

local BoolConst = im.BoolPtr(false)

local function constBoolNew(Bool)
	BoolConst[0] = Bool
	return BoolConst
end

local function createWindow(WindowName, WindowSize, Visible, AutoSize, elements)
	local WindowData = {}
	local ElementCache = {}
	local ImGuiFlags = im.WindowFlags_NoDocking
	local SkipRendering = false
	local IsUncollapsed = false

	if AutoSize then
		ImGuiFlags = ImGuiFlags + im.WindowFlags_AlwaysAutoResize
	end

	WindowData.Size = WindowSize or im.ImVec2(0,0)
	WindowData.WindowName = WindowName
	WindowData.DrawElements = elements
	WindowData.Visible = Visible

	WindowData.SetWindowSize = function(newSize)
		local size = newSize or WindowData.Size
		if not size then
			-- Automatic size based on amounts of elements
			local width, height = 200, 0
			for _, element in ipairs(elements) do
				height = height + 30 -- standard height for each elements
			end
			size = { width, height + 100 } -- buffer for edges
		end
		im.SetNextWindowSize(im.ImVec2(size[1], size[2])) 
	end

	WindowData.GetWindowSize = function()
		return WindowData.Size
	end

	WindowData.RenderWindow = function()
		if im.Begin(WindowName, constBoolNew(WindowData.Visible), ImGuiFlags) then
			WindowData.Size = im.GetWindowSize()
			for i, element in ipairs(elements) do
				if not DontRenderElement(element) then
					if element.Type == "CollapseEnd" then
						SkipRendering = false
						im.Separator()
						if IsUncollapsed then
							IsUncollapsed = false
							im.TreePop()
						end
	
					elseif not SkipRendering then
						if element.Type == "label" then
							local text = getText(element)
							if element.Centered then
								local windowWidth = im.GetWindowWidth()
								local textWidth = im.CalcTextSize(text).x
								local padding = (windowWidth - textWidth) * 0.5 -- Calculate center position
							
								im.SetCursorPosX(math.max(padding, 0)) -- Set X cursor position to center
							end
							im.Text(text)
						
						elseif element.Type == "CollapseStart" then
							if element.Title then
								im.Separator()
								-- TODO: Add default state here using im.TreeNodeFlags_DefaultOpen as a second argument
								IsUncollapsed = im.TreeNodeEx1(element.Title)
								SkipRendering = not IsUncollapsed
								if IsUncollapsed then
									im.Separator()
								end
							end
	
						elseif element.Type == "button" then
							if im.Button(getText(element)) then
								if element.OnClick then
									element.OnClick()
								end
							end
						
						elseif element.Type == "checkbox" then
							if element.State ~= nil then
								im.Text(getText(element))
								im.SameLine()
								local state = im.BoolPtr(element.State) -- Capture the current state
								local changed, newState = im.Checkbox("##"..i, state)
								if changed then
									element.State = not element.State -- Update state
									if element.OnChange then
										element.OnChange(element.State)
									end
								end
							end
						
						elseif element.Type == "separator" then
							im.Separator()
	
						elseif element.Type == "textinput" then
							if element.DefaultText ~= nil then
								if not element.TextBuffer then
									element.TextBuffer = im.ArrayChar(128, element.DefaultText) -- Persistent Buffer
								end
								local BoxLenght = element.BoxLenght or 40
								im.Text(element.InputLabel) -- Label left
								im.SameLine() -- keeps it on the same line
								im.SetNextItemWidth(BoxLenght)
								if im.InputText("##"..i, element.TextBuffer) then -- empty name, just the box
									element.DefaultText = ffi.string(element.TextBuffer) -- Update Text
									if element.OnInput then
										element.OnInput(element.DefaultText)
									end
								end
							end
						end
					end
					element.rendering = not SkipRendering	
				end
				end
			im.End()
		end
	end	

	function WindowData.getElement(ElementName)
		local CachedElementIndex = ElementCache[ElementName]
		local CachedElement = CachedElementIndex and elements[CachedElementIndex]

		if CachedElement and CachedElement.Name and CachedElement.Name == ElementName then
			return CachedElement, CachedElementIndex
		end

		for i, element in ipairs(elements) do
			if element.Name and element.Name == ElementName then
				ElementCache[ElementName] = i
				return element, i
			end
		end
	end

	if WindowSize then
		WindowData.SetWindowSize()
	end

	function WindowData:Destroy()
		btm.remove(drawableWindows, WindowData)
		WindowData = nil
		elements = nil
	end
	
	if WindowData.Visible then
		WindowData.RenderWindow()
	end
	drawableWindows = btm.add(drawableWindows, WindowData)

	return WindowData
end

local function GetWindow(WindowName)
	for i=1, #drawableWindows do
		if drawableWindows[i].WindowName == WindowName then
			return drawableWindows[i]
		end
	end
end

--[[ ezImgUI api end ]]

local function onUpdate()
	gfxScheduler.update()
	for i=1, #drawableWindows do
		if drawableWindows[i].Visible then
			drawableWindows[i].RenderWindow()
		end
	end
end

M.GetWindow = GetWindow
M.CreateWindow = createWindow
M.onUpdate = onUpdate -- Ensures the UI updates every frame
M.SimpleTables = btm
M.Scheduler = gfxScheduler
M.Hooker = simpleHooker
M.onInit = function() setExtensionUnloadMode(M, "manual") end

return M
