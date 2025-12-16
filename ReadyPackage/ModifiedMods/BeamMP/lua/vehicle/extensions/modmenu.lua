-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

if true then
	return {} -- Disabled for maintance
end

local M = {}
local btm = {}
local state = {}

local ExactPos = nil
local ExactPoiPos = nil

local TrailerID = nil
local settingsPath = '/settings/modmenu.json'

M.Settings = {}
M.Settings.NotifyOnSpectator = false
M.Settings.NotifyifNoSpectators = false
M.Settings.DisableAutoFarmOnSpectator = true
M.Settings.DisableAutoFarmOnPlayerJoin = true
M.Settings.ReenableAutofarmWhenServerEmpty = true
M.Settings.ReenableAutofarmWhenNoSpectators = true
M.Settings.AutoFarmTeleportTime = 40

local MissionRequestCooldown = 6
local AutoFarmDisabledcuzOfSpectator = false
local AutoFarmDisabledcuzOfPlrJoin = false

local function settingsLoad()
	local s = jsonReadFile(settingsPath)
	if s then
		M.Settings.NotifyOnSpectator= s.NotifyOnSpectator or false
		M.Settings.NotifyifNoSpectators = s.NotifyifNoSpectators or false
		M.Settings.DisableAutoFarmOnSpectator = s.DisableAutoFarmOnSpectator or true
		M.Settings.DisableAutoFarmOnPlayerJoin = s.DisableAutoFarmOnPlayerJoin or true
		M.Settings.ReenableAutofarmWhenServerEmpty = s.ReenableAutofarmWhenServerEmpty or true
		M.Settings.ReenableAutofarmWhenNoSpectators = s.ReenableAutofarmWhenNoSpectators or true
		M.Settings.AutoFarmTeleportTime = s.AutoFarmTeleportTime or 40
	end
end

local function settingsSave()
	local s = {
		NotifyOnSpectator = M.Settings.NotifyOnSpectator,
		NotifyifNoSpectators = M.Settings.NotifyifNoSpectators,
		DisableAutoFarmOnSpectator = M.Settings.DisableAutoFarmOnSpectator,
		DisableAutoFarmOnPlayerJoin = M.Settings.DisableAutoFarmOnPlayerJoin,
		ReenableAutofarmWhenServerEmpty = M.ReenableAutofarmWhenServerEmpty,
		ReenableAutofarmWhenNoSpectators = M.ReenableAutofarmWhenNoSpectators,
		AutoFarmTeleportTime = M.AutoFarmTeleportTime,
	}
	jsonWriteFile(settingsPath, s, true)
	settingsLoad()
end

-- Function to add a variable to a table if it doesn't exist in the table already
function btm.addVariable(table, variable)
    for key, value in pairs(table) do
        if value == variable then
            return table  -- Variable already exists, return the table as is
        end
    end
    table[#table + 1] = variable
    return table
end

-- Function to remove a variable from a table if it exists in the table
function btm.removeVariable(table, variable)
    local indexToRemove = nil
    for i, value in ipairs(table) do
        if value == variable then
            indexToRemove = i
            break
        end
    end
    if indexToRemove then
        table[indexToRemove] = nil
    end
    return table
end

-- Function to clear a table
function btm.clearTable(table)
    for k in pairs(table) do
        table[k] = nil
    end
    return table
end

-- Function to sort a table's variables by number (numeric values)
function btm.sortTable(table)
    local numericValues = {}
    local otherValues = {}
    
    for _, value in ipairs(table) do
        if type(value) == "number" then
            table.insert(numericValues, value)
        else
            table.insert(otherValues, value)
        end
    end
    
    table.sort(numericValues)
    
    local sortedTable = {}
    for _, value in ipairs(numericValues) do
        table.insert(sortedTable, value)
    end
    
    for _, value in ipairs(otherValues) do
        table.insert(sortedTable, value)
    end
    
    return sortedTable
end

function btm.wait(second, millisecond)
	local ostime_vrbl = os.time() + second, millisecond;
	while os.time() > ostime_vrbl do end 
end


function btm.stringToTable(inputString, delimiter)
    local resultTable = {}
    local pattern = "(.-)" .. delimiter
    local lastEnd = 1
    local _, endIndex, capturedValue = inputString:find(pattern, 1)

    while endIndex do
        table.insert(resultTable, capturedValue)
        lastEnd = endIndex + 1
        _, endIndex, capturedValue = inputString:find(pattern, lastEnd)
    end

    table.insert(resultTable, inputString:sub(lastEnd))
    return resultTable
end

local function TriggerEkey(State)
	obj:queueGameEngineLua("if carp then carp.ePress(" .. obj:getID() .. ", " .. tostring(State) .. ") end")
end

local function GetTrailerID()
	  obj:queueGameEngineLua([[if carp and carp_vehicle then 
	  local Veh = be:getPlayerVehicle(0) 
    if Veh then 
		local TrailerID = carp_vehicle.getTrailerVehicleID() 
		if TrailerID then 
			Veh:queueLuaCommand("extensions.modmenu.UpdateTrailerID('"..TrailerID.."')") 
			else 
			Veh:queueLuaCommand("extensions.modmenu.UpdateTrailerID('SetToNil')") 
		end 
    end 
end]])

end

local function SetAiGoal(Target)
	obj:queueGameEngineLua([[
	group = scenetree.CarpmissionTriggersGroup 
	local triggers = group:getObjects() 
	
	
	if triggers == nil or #triggers == nil or #triggers == 0 then 
		return 
	end 
	
	local playerVehicle = be:getPlayerVehicle(0) 
	local playerVehiclePosition = playerVehicle:getPosition() 

	local nearestWaypoint = vec3(0, 0, 0) 
	local nearestNode = "" 
	local shortestDistance = 999999999 
 
	for _, name in pairs(triggers) do 
		local testLocation = group:findObject(name):getPosition() 
		local dist, lastNodeName = carp_groundmarkers.getPointToPointDistance(playerVehiclePosition, testLocation) 

		if dist < shortestDistance and not string.find(name, "icon") then 
			shortestDistance = dist 
			nearestWaypoint = testLocation 
			nearestNode = lastNodeName 
		end 
	end 

	if shortestDistance == 999999999 then 
		return 
	end 
	playerVehicle:queueLuaCommand("ai.setTarget('"..nearestNode.."')") 
	print(tostring(nearestWaypoint))
	]])
end

local function UpdateTrailerID(ID)
	if ID == "SetToNil" then
		TrailerID = nil
		else
		TrailerID = ID
	end
end

local function UpdatePos(Pos)
    ExactPos = Pos
	SetAiGoal(btm.stringToTable(Pos, "|"))
    ExactPoiPos = nil
end

local function UpdatePoiPos(Pos)
    ExactPoiPos = tostring(Pos)
end

local function GetPoiPos()
	obj:queueGameEngineLua([[
	group = scenetree.CarpcontactTriggersGroup 
	local triggers = group:getObjects() 
	
	
	if triggers == nil or #triggers == nil or #triggers == 0 then 
		return 
	end 
	
	local playerVehicle = be:getPlayerVehicle(0) 
	local playerVehiclePosition = playerVehicle:getPosition() 

	local nearestWaypoint = vec3(0, 0, 0) 
	local nearestNode = "" 
	local shortestDistance = 999999999 
 
	for _, name in pairs(triggers) do 
		local testLocation = group:findObject(name):getPosition() 
		local dist, lastNodeName = carp_groundmarkers.getPointToPointDistance(playerVehiclePosition, testLocation) 

		if dist < shortestDistance and not string.find(name, "icon") then 
		shortestDistance = dist 
		nearestWaypoint = testLocation 
		nearestNode = lastNodeName 
		end 
	end 

	if shortestDistance == 999999999 then 
		return 
	end 
	playerVehicle:queueLuaCommand("extensions.modmenu.UpdatePoiPos('"..nearestWaypoint.x..","..nearestWaypoint.y..","..nearestWaypoint.z.."')") 
	]])
end

local function SetAiEnabled()
   ai.setMode("manual")
   ai.driveInLane(true)
   ai.setSpeedMode("Off")
end

local function teleport(x,y)
    GetTrailerID()

    if not ExactPos then
	   obj:queueGameEngineLua("be:getPlayerVehicle(0):setPositionNoPhysicsReset(vec3("..x..","..y..",".."(Engine.castRay(vec3("..x..","..y..",99999), vec3("..x..","..y..",-99999), true, true)).pt.z".."))")
	   else
	   local coords = btm.stringToTable(ExactPos, "|")
	   coords[3] = coords[3] + 0.6
	   obj:queueGameEngineLua("be:getPlayerVehicle(0):setPositionNoPhysicsReset(vec3("..tonumber(coords[1])..","..tonumber(coords[2])..","..tonumber(coords[3]).."))")
	end
	
	if TrailerID then
		if ExactPos then
			local coords = btm.stringToTable(ExactPos, "|")
			coords[3] = coords[3] + 0.6
			obj:queueGameEngineLua("be:getObjectByID("..TrailerID.."):setPositionNoPhysicsReset(vec3("..tonumber(coords[1])..","..tonumber(coords[2])..","..tonumber(coords[3]).."))")
			else
			obj:queueGameEngineLua("be:getObjectByID("..TrailerID.."):setPositionNoPhysicsReset(vec3("..x..","..y..",".."(Engine.castRay(vec3("..x..","..y..",99999), vec3("..x..","..y..",-99999), true, true)).pt.z".."))")
		end
	end
	
	TriggerEkey(true)
end

local function ExactTp()
    local coords = btm.stringToTable(ExactPoiPos, ",")
	coords[3] = coords[3] - 0.6
	obj:queueGameEngineLua("be:getPlayerVehicle(0):setPositionNoPhysicsReset(vec3("..tonumber(coords[1])..","..tonumber(coords[2])..","..tonumber(coords[3]).."))")
end

local function regenerate(dest)
 teleport(dest)
end

local function ChangeCheckBoxState(Data)
	guihooks.trigger('Autofarmstate', Data)
end

local AutoFarmActive = false
local function SetAutoFarmState(State, notbutton)
	if not State or State == false or State == "false" then
	AutoFarmActive = false
	ChangeCheckBoxState(false)
	if not notbutton then
		AutoFarmDisabledcuzOfPlrJoin = false
		AutoFarmDisabledcuzOfSpectator = false
	end
	else
	AutoFarmActive = true
	AutoFarmDisabledcuzOfPlrJoin = false
	AutoFarmDisabledcuzOfSpectator = false
	ChangeCheckBoxState(true)
	end
end

local function LegacyMsg(Text)
	obj:queueGameEngineLua("ui_message('"..Text.."')")
end

local function PlayerAdded()
	if AutoFarmActive and M.Settings.DisableAutoFarmOnPlayerJoin then
		LegacyMsg("Autofarm has been disabled because a player joined the server")
		SetAutoFarmState(false, true)
		AutoFarmDisabledcuzOfPlrJoin = true
	end
end

local function OnNoPlayers()
	if not AutoFarmActive and AutoFarmDisabledcuzOfPlrJoin and M.Settings.ReenableAutofarmWhenServerEmpty then
		SetAutoFarmState(true, true)
		LegacyMsg("Autofarm has been automaticly reenabled since there are no players.")
	end
end

local function OnSpectator(payloadtext)
	if AutoFarmActive and M.Settings.DisableAutoFarmOnSpectator then
		LegacyMsg("Autofarm has been disabled because a player spectates you.")
		SetAutoFarmState(false, true)
		AutoFarmDisabledcuzOfSpectator = true
	end
	
	if payloadtext then
		if M.Settings.NotifyOnSpectator then
			LegacyMsg(payloadtext)
		end
	end
end

local function OnNoSpectators()
	if not AutoFarmActive and AutoFarmDisabledcuzOfSpectator and M.Settings.ReenableAutofarmWhenNoSpectators then
		SetAutoFarmState(true, true)
		LegacyMsg("Autofarm has been automaticly reenabled since no one spectates you.")
	end
	if M.Settings.NotifyifNoSpectators then
		LegacyMsg("Nobody spectates you right now")
	end
end

local function RepairCar()
	obj:queueGameEngineLua([[spawn.teleportToLastRoad()]])
end

local function GetSpectatingPlayers()
obj:queueGameEngineLua([[
	if MPVehicleGE then 
		local Veh = be:getPlayerVehicle(0) 
		local VehID = Veh:getID() 
		local VehData = MPVehicleGE.getVehicleByGameID(VehID) 
		
		local VehOwner = VehData.ownerName 
		local SpectatedByOwner = false 
		
		local function tAppend(table, variable) for key, value in pairs(table) do if value == variable then return table end end table[#table + 1] = variable return table end 
		local function GetPlayerByID(ID) return MPVehicleGE.getPlayers()[ID] end 
		
		if VehOwner then 
			local Spectators = {} 
			for playerName, playerVariables in pairs(MPVehicleGE.getPlayerByName(VehOwner).vehicles) do 
				for variableName, variableValue in pairs(playerVariables) do 
				
					for PlayerID, isValid in pairs(playerVariables.spectators) do 
					
						local SpectatingPlayer = GetPlayerByID(PlayerID).name 
						if SpectatingPlayer == VehOwner then  
							SpectatedByOwner = true 
						end 
						
						if SpectatingPlayer ~= VehOwner then 
							Spectators = tAppend(Spectators, SpectatingPlayer) 
						end 
					end 
				end 

			end 
			
			local Text = function(p) return p.." is spectating this vehicle" end 
			
			if #Spectators==0 then 
				Veh:queueLuaCommand("extensions.modmenu.OnNoSpectators()") 
			end 
			
			for i=1, #Spectators do 
				local T = Text(Spectators[i]) 
				Veh:queueLuaCommand("extensions.modmenu.OnSpectator('"..T.."')") 
			end 
		
		else 
		
		end 
	end 
]])
-- add a space after each statement to prevent compiling errors
end


local Timer = 0
local TPTIMER = 0
local Teleported = false
local AiModeEnabled = false
local DidAiTP = false
local function loopingFunction()
        if AutoFarmActive then
			GetTrailerID()
			ChangeCheckBoxState(true)
            Timer = Timer + 1
			
			if not AiModeEnabled then
				if ai then
					SetAiEnabled()
					AiModeEnabled = true
				end
			end
			
			if Timer<M.Settings.AutoFarmTeleportTime-2 then
			   LegacyMsg("Automatic teleportation will start in a few seconds")
			end
			
			if Timer>M.Settings.AutoFarmTeleportTime-10 then
				LegacyMsg("You will be teleported in 10 seconds")
			end

			if Timer>M.Settings.AutoFarmTeleportTime-5 then
				LegacyMsg("You will be teleported in 5 seconds")
			end
			
			if Timer>M.Settings.AutoFarmTeleportTime-2 then
				if ai.mode ~= "disabled" then
					DidAiTP = true
					ai.setMode("disabled")
					RepairCar()
				end
			end
			
			if ExactPos=="ZeroVal" then
				ExactPos = nil
			end
			
            if Teleported then
                if ExactPos then
					TriggerEkey(true)
					else
					Teleported = false
				end
            end
			
            if Timer > M.Settings.AutoFarmTeleportTime then
                if ExactPos then
                    Timer = 0
                    teleport(0, 0)
					LegacyMsg("You have been teleported")
                    Teleported = true
					TPTIMER = MissionRequestCooldown
					
					if DidAiTP then
						RepairCar()
						DidAiTP = false
						SetAiEnabled()
					end
                end
            end
			
			if ExactPoiPos and not ExactPos then
				ExactTp()
				TriggerEkey(true)
				TPTIMER = MissionRequestCooldown
			end
			
			if not ExactPoiPos and not ExactPos then
				if TPTIMER>0 then
					TPTIMER = TPTIMER-1
				else
					GetPoiPos()
				end
				LegacyMsg("Getting new mission point and teleporting to it in: "..TPTIMER.."s")
			end
        else
			if ai.mode ~= "disabled" and AiModeEnabled then
				DidAiTP = false
				ai.setMode("disabled")
			end
			AiModeEnabled = false
			ChangeCheckBoxState(false)
            Timer = 0
        end
end

local CurrentOsClock = os.clock()
local function updateTimer(dt)
   if (os.clock()-CurrentOsClock)>= 1 then
	CurrentOsClock = os.clock()
	
	settingsLoad()

	if M.Settings.NotifyOnSpectator or M.Settings.DisableAutoFarmOnSpectator or M.Settings.NotifyifNoSpectators then
		GetSpectatingPlayers()
	end
	
	loopingFunction()
   end
end

local function updateGFX(dt)
	updateTimer(dt)
end

local function onInit()
	-- loads the mod menus configuration
	settingsLoad()
	updateGFX(1)
	loopingFunction()
end

local function onExit()
	-- saves the mod menus configuration
	settingsSave()
end

-- public interface
M.SetAiGoal = SetAiGoal
M.OnSpectator = OnSpectator
M.OnNoSpectators = OnNoSpectators
M.OnNoPlayers = OnNoPlayers
M.onInit = onInit
M.onExit = onExit
M.settingsSave = settingsSave
M.GetSpectatingPlayers = GetSpectatingPlayers
M.UpdateTrailerID = UpdateTrailerID
M.ExactTp = ExactTp
M.PlayerAdded = PlayerAdded
M.UpdatePoiPos = UpdatePoiPos
M.updateGFX = updateGFX
M.updateTimer = updateTimer
M.regenerate = regenerate
M.teleport = teleport
M.UpdatePos = UpdatePos
M.SetAutoFarmState = SetAutoFarmState

return {} -- Disabled for maintance
--return M
