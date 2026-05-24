local M = {}
local util = CoolModUtils

local updateAutofarm
local updateInfiniteFuel
local DefaultUpdateTasks
local AutoSaverTask

local isLoaded

local CurrentCar = nil
local CurrentGoalPos = nil
local DistanceToGoal = nil
local ActiveSpectators = ""
local CurrentServer = nil
local HookingBeammp = false
local BypassVehSpoofer = false
local InjectingIntoCaRP = false
local IsInCaRPServer = false
local RealVehicleName = nil
local CurrentVehicleID = nil
local PositionSpoofTask = nil
local CurrentTargetPos = nil
local dprint = function(...)end

-- Beammp hooks:
local OriginalSendToServer
local OriginalOnVehResetVehCaRP
local OriginalOnVehResetMainCaRP
local OriginalOnVehResetBeamMP

-- TODO:
-- complete autofarm system
-- ✅ Use these variables for the autofarm so that it can interact with CaRP using this global variable: "if modmenumain then modmenumain.GlobalSettings["Setting"] end"
-- Create a inbuild hwid spoofer with a button and menu etc, here is the hooked function:

--[[ How to hook/inject things: 

local function injectConfigCleanup()
  if extensions.MPVehicleGE and extensions.MPVehicleGE.onVehicleSpawned ~= customOnVehicleSpawned then
    log("E", "onExtensionLoaded", "loaded custom config schenanigans")
    origOnVehicleSpawned = extensions.MPVehicleGE.onVehicleSpawned
    extensions.MPVehicleGE.onVehicleSpawned = customOnVehicleSpawned

    extensions.hookUpdate("onVehicleSpawned") -- its a hook so we have to invalidate the cache
  end
end

usage: 

print(CoolModUtils.Hooker.IsHookable("MPVehicleGE","onVehicleSpawned"))

CoolModUtils.Hooker.HookFunction("MPVehicleGE","onVehicleSpawned", function()
	print("Spawner got injected ( it works :D )")
end)

TODO: make this a function in the mod util thingy

]]

local function GenerateRandomHWID()
	local chars = "ABCDEF0123456789"
	local id = {}
	for i = 1, 32 do
		local randIndex = math.random(1, #chars)
		table.insert(id, chars:sub(randIndex, randIndex))
	end
	return table.concat(id)
end

local settingsPath = '/settings/modmenuSettings.json'
local IsSaveSynced = false
local ScheduledTasks = {
	["FuelTask"] = nil,
	["AutoFarmTask"] = nil,
	["UpdateTasks"] = nil,
	["SettingsSaverTask"] = nil
}
M.GlobalSettings = {
	["AutoFarmMode"] = "Inactive",
	["AiMode"] = "None"
}
M.SavingSettings = {
	["VehicleSpoofer"] = true,
	["Autofarm"] = false,
	["InfiniteFuel"] = true,
	["FreeRepairs"] = true,
	["PaxSpoofer"] = true,
	["ShowCarpElements"] = true,
	["ConsoleDebugger"] = false,
	["TeleportAutoFarmTime"] = 86,
	["MinCompletetionDistance"] = 90,
	["RespawnTimeout"] = 25,
	["DisableAutoFarmOnJoin"] = false,
	["DisableAutoFarmOnSpectators"] = false,
	["CurrentHwid"] = GenerateRandomHWID()
}

-- Ui Settings:
local ModMenuWindow
local ModMenuWindowName = "CaRP mod menu (Test build)"
local ModMenuWindowSize = {342, 548}
local ModMenuVisible = true
local ModMenuAutoSized = true

getHardwareID = function() -- Overwrite global function
	return M.SavingSettings.CurrentHwid
end

local function getNearestContact()
	local group = scenetree and scenetree.CarpcontactTriggersGroup

	if not group then
		return
	end

	local playerVehicle = be:getPlayerVehicle(0)

	if not playerVehicle then
		return
	end

	local triggers = group:getObjects()
	local playerVehiclePosition = playerVehicle:getPosition()
	local shortestDistance = nil
	local NearestContact

  	for _, name in pairs(triggers) do
		local Location = group:findObject(name)
		local CurrentDistance = M.CalculateDistance(Location:getPosition(), playerVehiclePosition)

		if not shortestDistance or CurrentDistance < shortestDistance then
			shortestDistance = CurrentDistance
			NearestContact = Location
		end
  	end

	return NearestContact
end

local function settingsLoad()
	local storedSettings = jsonReadFile(settingsPath)
	if storedSettings then
		for settingName, value in pairs(storedSettings) do
			M.SavingSettings[settingName] = value
		end
	end
	IsSaveSynced = true
end

local function settingsSave()
	if not IsSaveSynced then
		local settingsToSave = M.SavingSettings
		jsonWriteFile(settingsPath, settingsToSave, true)
		IsSaveSynced = true
	end
end

local function CalculateDistance(firstvec, secondvec)
	return (firstvec-secondvec):length()
end

local function DoNotRenderCarpElements()
	return not M.SavingSettings.ShowCarpElements
end

local function getCharacters(str, characters)
	return string.sub(str, 1, characters)
end

local function sendVehicleEditBypassed()
	local vehicleID = be and be:getPlayerVehicleID(0)
	if vehicleID and vehicleID ~= -1 and MPVehicleGE and MPVehicleGE.sendVehicleEdit then
		BypassVehSpoofer = true
		CurrentVehicleID = vehicleID
		M.updateVehicleName(vehicleID)
		MPVehicleGE.sendVehicleEdit(vehicleID)
	end
end

local function DumpTable(o) 
	if type(o) == 'table' then 
		dprint('{') 
		for k,v in pairs(o) do 
			if type(k) ~= 'number' then k = '"'..k..'"' end 
			dprint(' ['..k..'] = ') 
			DumpTable(v) 
		end 
		dprint('}') 
	else 
		dprint(tostring(o)..', ') 
	end 
end 

local function getVehicleName(Vehicle) 
	local vehKey = Vehicle.JBeam
	local vehMainInfo = core_vehicles.getModel(vehKey)

	if vehMainInfo then
		return (vehMainInfo.model["Brand"] and vehMainInfo.model["Brand"].." " or "")..(vehMainInfo.model["Name"] or vehKey)
	end
end

local function decodePacket(str)
    local prefix, body = str:match("^(.-)(%{.*)$")

    if not body then return end

    local jsonString = body:gsub('=', ':')
    local success, decodedTable = pcall(jsonDecode, jsonString)

    if not success then
        return nil
    end
    return decodedTable, prefix
end

local function encodePacket(tbl, prefix)
    local jsonString = jsonEncode(tbl)
    local customBody = jsonString:gsub(':', '=')

    return prefix .. customBody
end

local function OnSendDataToServer(Data) -- string
	if not M.SavingSettings.VehicleSpoofer then
		if OriginalSendToServer then
			OriginalSendToServer(Data)
		end
	else
		local ReplicationType = getCharacters(Data, 2)

		if ReplicationType ~= "Oc" then
			if ReplicationType ~= "Zp" then
				if IsInCaRPServer then
					if ReplicationType == "E:" then -- E: = CaRP client to server event
						if Data:find("receiveHandleTeleport") then
							return
						elseif CurrentTargetPos and Data:find("receiveHandlePlayerGetPosition") then
							local DecodedData, PacketPrefix = decodePacket(Data)

							if DecodedData then
								DecodedData["x"] = CurrentTargetPos[1]
								DecodedData["y"] = CurrentTargetPos[2]
								DecodedData["z"] = CurrentTargetPos[3]
								return OriginalSendToServer(encodePacket(DecodedData, PacketPrefix))
							end
						elseif M.SavingSettings.PaxSpoofer and Data:find("paxMissionRequests") then
							local DecodedData, PacketPrefix = decodePacket(Data)

							if DecodedData then
								local MissionRequests = DecodedData["passengerPayload"] and DecodedData["passengerPayload"]["paxMissionRequests"]
								DecodedData.resetDuringMission = false

								if MissionRequests then
									for MissionName, Success in pairs(MissionRequests) do
										dprint("["..MissionName.."] = "..tostring(Success))
										if not Success then
											dprint("Spoofed mission: "..MissionName)
											MissionRequests[MissionName] = true
										end
									end
								end

								return OriginalSendToServer(encodePacket(DecodedData, PacketPrefix))
							end
						end
					end
				end
			elseif CurrentTargetPos then -- Zp = replicate vehicle position and velocity
				local DecodedData, PacketPrefix = decodePacket(Data)
				DecodedData["pos"] = CurrentTargetPos
				return OriginalSendToServer(encodePacket(DecodedData, PacketPrefix))
			end
			OriginalSendToServer(Data)
		elseif BypassVehSpoofer then
			BypassVehSpoofer = false
			OriginalSendToServer(Data)
		end

	end
end

local function OnCarpResetVeh(vehID, other)
	if M.SavingSettings.FreeRepairs == false then
		OriginalOnVehResetVehCaRP(vehID, other)
	end
end

local function OnCarpVehResetMain(vehID, other)
	if M.SavingSettings.FreeRepairs == false then
		OriginalOnVehResetMainCaRP(vehID, other)
	end
end

local function OnBeamMPVehReset(...)
	if M.SavingSettings.FreeRepairs == false then
		return OriginalOnVehResetBeamMP(...)
	end
end

local function InjectIntoBeammp()
	if not HookingBeammp then
		HookingBeammp = true
		util.Hooker.HookFunction("MPGameNetwork", "send", 1, OnSendDataToServer, function(OriginalSendFunc)
			OriginalSendToServer = OriginalSendFunc
			dprint("Network spoofer injected into Beammp!")
		end, true)

		util.Hooker.HookFunction("MPVehicleGE", "onVehicleResetted", 1, OnBeamMPVehReset, function(OriginalFunction)
			OriginalOnVehResetBeamMP = OriginalFunction
			dprint("Injected into MPVehicleGE!")
		end, true)
	end
	if not InjectingIntoCaRP and CurrentServer and CurrentServer.name and string.find(string.lower(CurrentServer.name), "carp") then
		InjectingIntoCaRP = true
		IsInCaRPServer = true
		dprint("Injecting into CaRP...")

		util.Hooker.HookFunction("carp_vehicle", "onVehicleResetted", 1, OnCarpResetVeh, function(OriginalResetFunc)
			OriginalOnVehResetVehCaRP = OriginalResetFunc
			dprint("Respawn spoofer injected into CaRP-Veh!")
		end, true)

		util.Hooker.HookFunction("carp", "onVehicleResetted", 1, OnCarpVehResetMain, function(OriginalResetFunc)
			OriginalOnVehResetMainCaRP = OriginalResetFunc
			dprint("Respawn spoofer injected into CaRP-Lua!")
		end, true)

	end
end

local function CleanupInjector()
	if InjectingIntoCaRP then
		InjectingIntoCaRP = false
		IsInCaRPServer = false
		OriginalOnVehResetVehCaRP = nil
		OriginalOnVehResetMainCaRP = nil
	end
	RealVehicleName = nil
	PositionSpoofTask = nil
end

local function TriggerEkey(State)
	if carp then carp.ePress(be:getPlayerVehicle(0):getID(), State) end
end

-- Equals: ServerTP
local function SpoofServerPosition(NewPosition)
	if PositionSpoofTask then
		util.Scheduler.avoidFunction(PositionSpoofTask)
		PositionSpoofTask = nil
	end
	
	if type(NewPosition) == "table" then
		CurrentTargetPos = {
			tonumber(NewPosition[1]),
			tonumber(NewPosition[2]),
			tonumber(NewPosition[3])
		}
	else
		CurrentTargetPos = {NewPosition.x, NewPosition.y, NewPosition.z}
	end

	PositionSpoofTask = util.Scheduler.delayfunction(0.01, function()
		CurrentTargetPos = nil
		PositionSpoofTask = nil
	end)
end

local function LoadUI()
	ModMenuWindow = util.CreateWindow(ModMenuWindowName, nil, ModMenuVisible, ModMenuAutoSized, {
		{
			Name = "InServer",
			Type = "label",
			TextFunc = function()
				return "In server: "..(CurrentServer and "true ("..getCharacters(CurrentServer.name or "", 15)..")" or "false")
			end,
		},
		{
			Type = "button",
			TextFunc = function() return "Unspoof vehicle" end,
			OnClick = sendVehicleEditBypassed
		},
		{
			Type = "button",
			DoNotRenderFunc = DoNotRenderCarpElements,
			TextFunc = function() return "Skip mission (DETECTABLE!)" end,
			OnClick = function()
				if carp then
					local Mission = carp.getCurrentMission()
					if Mission then
						local MissionCoords = util.SimpleTables.stringToTable(Mission.destinationCoords, "|")
						if MissionCoords then
							SpoofServerPosition(MissionCoords)
							TriggerEkey(true)
						end
					end
				end
			end
		},
		{
			Type = "button",
			DoNotRenderFunc = DoNotRenderCarpElements,
			TextFunc = function() return "Get mission" end,
			OnClick = function()
				if carp then
					local Location = getNearestContact()
					if Location then
						SpoofServerPosition(Location:getPosition())
						TriggerEkey(true)
					end
				end
			end
		},
		{
			Type = "button",
			TextFunc = function() return "Save settings" end,
			OnClick = function()
				settingsSave()
			end
		},
		{
			Type = "CollapseStart",
			Title = "HWID Spoofer",
			Uncollapsed = true
		},
		{
			Type = "label",
			Text = "Current HWID:"
		},
		{
			Type = "label",
			TextFunc = function()
				return M.SavingSettings.CurrentHwid
			end
		},
		{
			Type = "button",
			TextFunc = function() return "Spoof / change BeamNG's HWID" end,
			OnClick = function()
				IsSaveSynced = false
				M.SavingSettings.CurrentHwid = GenerateRandomHWID()
				settingsSave()
			end
		},
		{
			Type = "CollapseEnd"
		},
		{
			Type = "checkbox",
			State = M.SavingSettings.ConsoleDebugger,
			TextFunc = function() return "Debug stuff in console: " end,
			OnChange = function(newState)
				M.SavingSettings.ConsoleDebugger = newState
				IsSaveSynced = false
				if newState then
					dprint = function(...)
						return print(...)
					end
				else
					dprint = function() end
				end
			end
		},
		{
			Type = "checkbox",
			State = M.SavingSettings.VehicleSpoofer,
			TextFunc = function() return "Vehicle Spoofer: " end,
			OnChange = function(newState)
				M.SavingSettings.VehicleSpoofer = newState
				IsSaveSynced = false
				if not newState then
					sendVehicleEditBypassed()
				end
			end
		},
		{
			Type = "checkbox",
			State = M.SavingSettings.ShowCarpElements,
			TextFunc = function() return "Show CaRP cheats: " end,
			OnChange = function(newState)
				M.SavingSettings.ShowCarpElements = newState
				IsSaveSynced = false
			end
		},
		{
			Type = "checkbox",
			State = M.SavingSettings.Autofarm,
			DoNotRenderFunc = DoNotRenderCarpElements,
			TextFunc = function() return "AI-Autofarm (Autopilot): " end,
			OnChange = function(newState)
				M.SavingSettings.Autofarm = newState
				IsSaveSynced = false
				if not newState then
					M.GlobalSettings.AutoFarmMode = "Inactive"
					local Veh = be:getPlayerVehicle(0)
					if Veh then
							dprint("Disabling AI")
							Veh:queueLuaCommand([[
								ai.setMode("disabled");
							]])
						end
					end
				end
		},
		{
			Type = "checkbox",
			State = M.SavingSettings.InfiniteFuel,
			TextFunc = function() return "Infinite fuel: " end,
			OnChange = function(newState)
				M.SavingSettings.InfiniteFuel = newState
				IsSaveSynced = false
			end
		},
		{
			Type = "checkbox",
			State = M.SavingSettings.FreeRepairs,
			DoNotRenderFunc = DoNotRenderCarpElements,
			TextFunc = function() return "Force free repairs: " end,
			OnChange = function(newState)
				M.SavingSettings.FreeRepairs = newState
				IsSaveSynced = false
			end
		},
		{
			Type = "checkbox",
			State = M.SavingSettings.PaxSpoofer,
			TextFunc = function() return "Force always perfect mission: " end,
			OnChange = function(newState)
				M.SavingSettings.PaxSpoofer = newState
				IsSaveSynced = false
			end
		},
		{
			Type = "separator",
			DoNotRenderFunc = DoNotRenderCarpElements
		},
		{
			Type = "label",
			Text = "Autofarm settings",
			DoNotRenderFunc = DoNotRenderCarpElements,
			Centered = true
		},
		{
			Type = "textinput",
			InputLabel = "Tp-Autofarm teleport time: ",
			DoNotRenderFunc = DoNotRenderCarpElements,
			DefaultText = tostring(M.SavingSettings.TeleportAutoFarmTime),
			BoxLenght = 50,
			OnInput = function(newText)
				M.SavingSettings.TeleportAutoFarmTime = tonumber(newText) or M.SavingSettings.TeleportAutoFarmTime
				IsSaveSynced = false
			end
		},
		{
			Type = "textinput",
			InputLabel = "Min-distance until completing mission: ",
			DoNotRenderFunc = DoNotRenderCarpElements,
			DefaultText = tostring(M.SavingSettings.MinCompletetionDistance),
			BoxLenght = 50,
			OnInput = function(newText)
				M.SavingSettings.MinCompletetionDistance = tonumber(newText) or M.SavingSettings.MinCompletetionDistance
				IsSaveSynced = false
			end
		},
		{
			Type = "textinput",
			InputLabel = "Ai reset timeout: ",
			DoNotRenderFunc = DoNotRenderCarpElements,
			DefaultText = tostring(M.SavingSettings.RespawnTimeout),
			BoxLenght = 50,
			OnInput = function(newText)
				M.SavingSettings.RespawnTimeout = tonumber(newText) or M.SavingSettings.RespawnTimeout
				IsSaveSynced = false
			end
		},
		{
			Type = "separator",
			DoNotRenderFunc = DoNotRenderCarpElements
		},
		{
			Type = "checkbox",
			State = M.SavingSettings.DisableAutoFarmOnSpectators,
			DoNotRenderFunc = DoNotRenderCarpElements,
			TextFunc = function() return "Avoid teleporting when there are spectators: " end,
			OnChange = function(newState)
				M.SavingSettings.DisableAutoFarmOnSpectators = newState
				IsSaveSynced = false
			end
		},
		{
			Type = "checkbox",
			State = M.SavingSettings.DisableAutoFarmOnJoin,
			DoNotRenderFunc = DoNotRenderCarpElements,
			TextFunc = function() return "Disable Autofarm when player joins the server: " end,
			OnChange = function(newState)
				M.SavingSettings.DisableAutoFarmOnJoin = newState
				IsSaveSynced = false
			end
		},
		{
			Type = "CollapseStart",
			Title = "Stats",
			Uncollapsed = true
		},
		{
			Type = "label",
			TextFunc = function()
				local Spectators = ActiveSpectators == "" and "None" or ActiveSpectators
				return "Spectators: "..Spectators
			end
		},
		{
			Name = "RealVehicle",
			Type = "label",
			DoNotRenderFunc = function()
				if not CurrentServer or not M.SavingSettings.VehicleSpoofer then
					return true
				end
			end,
			TextFunc = function()
				return "Current real Vehicle: "..(RealVehicleName or "Unknown")
			end,
		},
		{
			Type = "label",
			DoNotRenderFunc = DoNotRenderCarpElements,
			TextFunc = function() return "Autofarm status: "..M.GlobalSettings.AutoFarmMode end
		},
		{
			Type = "label",
			DoNotRenderFunc = DoNotRenderCarpElements,
			TextFunc = function()
				DistanceToGoal = ((CurrentCar and CurrentGoalPos and M.SavingSettings.Autofarm)
							and tostring(CalculateDistance(CurrentCar:getPosition(), CurrentGoalPos)))
				return "Goal Distance: "..(DistanceToGoal or "inactive")
			end
		},
		{
			Type = "label",
			TextFunc = function() return "AI status: "..M.GlobalSettings.AiMode end
		},
		{
			Type = "label",
			TextFunc = function()
				local WindowSize = ModMenuWindow and ModMenuWindow.GetWindowSize() or {["x"] = 0, ["y"] = 0}
				return "Window size: "..tostring(WindowSize.x).."x "..tostring(WindowSize.y).."y"
			end
		},
		{
			Type = "CollapseEnd"
		}
	})
end

local function StopAllTasks()
	for i,Task in pairs(ScheduledTasks) do
		if Task then
			util.Scheduler.avoidFunction(Task)
			ScheduledTasks[i] = nil
		end
	end
end

local function StartAllTasks()
	updateAutofarm()
	updateInfiniteFuel()
	DefaultUpdateTasks()
	AutoSaverTask()
end

local function initModMenu()
	if not util then
		util = CoolModUtils
	end
	if not isLoaded and util then
		settingsLoad()
		if M.SavingSettings.ConsoleDebugger then
			dprint = function(...)
				return print(...)
			end
		else
			dprint = function() end
		end
		LoadUI()
		isLoaded = true
		StartAllTasks()
	end
end

local function uninitModMenu()
	-- Small cleanup (for some reason Beamng won't do it correctly by it self or not at all)
	settingsSave()
	if ModMenuWindow then
		ModMenuWindow:Destroy()
		ModMenuWindow = nil
	end
	if isLoaded then
		isLoaded = false
	end
	StopAllTasks()
end

local function getCurrentServer()
	return MPCoreNetwork and MPCoreNetwork.getCurrentServer()
end

local function GetPlayerByID(ID) 
	return MPVehicleGE and MPVehicleGE.getPlayers()[ID] 
end 

local function updateVehicleName(vehicleID)
	local Vehicle = vehicleID and be:getObjectByID(vehicleID) or be:getPlayerVehicle(0)
	if Vehicle then
		RealVehicleName = getVehicleName(Vehicle)
	else
		RealVehicleName = nil
	end
end

local function onVehicleSpawned(gameVehicleID)
	if not CurrentVehicleID and MPVehicleGE and MPVehicleGE.isOwn(gameVehicleID) then
		CurrentVehicleID = gameVehicleID
		updateVehicleName(gameVehicleID)
	end
end

local function onVehicleDestroyed(gameVehicleID)
	if CurrentVehicleID == gameVehicleID then
		RealVehicleName = nil
	end
end

local function getNaviPos()
	local posOrNode = core_groundMarkers.getTargetPos()
	if type(posOrNode) == "string" then
		local NodePos = map.getMap().nodes[posOrNode]
		return NodePos and NodePos.pos
	else
		return posOrNode
	end
end

local function RecieveAiMode(AiMode)
	M.GlobalSettings.AiMode = AiMode
end

local function getSpectators()
	local spectators = {} 

	if MPVehicleGE then 
		local Veh = be:getPlayerVehicle(0) 
		if Veh then 
			local VehID = Veh:getID() 
			local VehData = MPVehicleGE.getVehicleByGameID(VehID) 
			
			if VehData then 
				local VehOwner = VehData.ownerName 
				
				if VehOwner then 
					for playerName, playerVariables in pairs(MPVehicleGE.getPlayerByName(VehOwner).vehicles) do 
						for PlayerID, isValid in pairs(playerVariables.spectators) do 
							local SpectatingPlayer = GetPlayerByID(PlayerID).name 
							if SpectatingPlayer ~= VehOwner then 
								spectators[SpectatingPlayer] = true 
							end 
						end 
					end 
				end 
			end 
		end 
	end 

	local ComputedString = "" 

	for plrName,_ in pairs(spectators) do 
		ComputedString = ComputedString == "" and plrName or ComputedString .. ", " .. plrName 
	end 

	return ComputedString
end

local function ToggleModMenu()
	if ModMenuWindow then
		ModMenuWindow.Visible = not ModMenuWindow.Visible
	end
end

DefaultUpdateTasks = function()
	ActiveSpectators = getSpectators()
	CurrentServer = getCurrentServer()
	ScheduledTasks.UpdateTasks = util.Scheduler.delayfunction(0.5, DefaultUpdateTasks)
end

updateInfiniteFuel = function()
	local currVeh = be:getPlayerVehicle(0)
	if currVeh then
		if M.SavingSettings.InfiniteFuel then
			currVeh:queueLuaCommand([[
				local storages = energyStorage.getStorages() 
				  
				if not storages then 
					return 
				end 

				for _, storage in pairs(storages) do 
					if storage.type ~= "pressureTank" then 
						storage:setRemainingRatio(storage.capacity) 
						storage:updateGFX(0) 
					end 
				end 
			]])
		end
	end
	ScheduledTasks.FuelTask = util.Scheduler.delayfunction(0.05, updateInfiniteFuel)
end

updateAutofarm = function()
	initModMenu()
	if util then
		local naviPos = M.SavingSettings.Autofarm and getNaviPos() or nil
		local currVeh = be:getPlayerVehicle(0)

		CurrentCar = currVeh
		CurrentGoalPos = naviPos

		if currVeh then
			currVeh:queueLuaCommand([[
			  obj:queueGameEngineLua("modmenumain.RecieveAiMode('"..ai.mode.."')")
			]])
		end

		if naviPos then
			if currVeh then
				local path = map.getPointToPointPath(currVeh:getPosition(), naviPos, 2, 100)
				local nodes = path and path[#path-1]
				M.GlobalSettings.AutoFarmMode = "Driving to point"
				if nodes then
					--local targetPos = vec3(tonumber(]]..naviPos.x.."),tonumber("..naviPos.y.."),tonumber("..naviPos.z..[[));
					currVeh:queueLuaCommand([[
						local targetPos = "]]..nodes..[[";
						if ai.mode ~= "manual" then
							ai.setMode("manual");
							ai.driveInLane("on");
							ai.setSpeedMode("off");
							ai.setAvoidCars("on");
							ai.setAggressionMode('rubberBand');
						end;
						if ai.manualTargetName ~= targetPos then
							ai.setTarget(targetPos);
						end;
					]])
					ScheduledTasks.AutoFarmTask = util.Scheduler.delayfunction(10, updateAutofarm)
					return
				end
			end
		end
		ScheduledTasks.AutoFarmTask = util.Scheduler.delayfunction(1, updateAutofarm)
	end
end

AutoSaverTask = function()
	if not IsSaveSynced then
		settingsSave()
	end
	ScheduledTasks.SettingsSaverTask = util.Scheduler.delayfunction(5, AutoSaverTask)
end

-- Exports:
M.onDisconnect = CleanupInjector
M.onWorldReadyState = InjectIntoBeammp
M.onVehicleSpawned = onVehicleSpawned
M.onVehicleDestroyed = onVehicleDestroyed
M.onExtensionLoaded = initModMenu -- Top 1 worst mod systems: BeamNG Drive
M.onExtensionUnloaded = uninitModMenu
M.onModDeactivated = uninitModMenu
M.onModActivated = initModMenu
M.RecieveAiMode = RecieveAiMode
M.ToggleModMenu = ToggleModMenu
M.updateVehicleName = updateVehicleName
M.CalculateDistance = CalculateDistance

return M