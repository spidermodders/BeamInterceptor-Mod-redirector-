-- Mod menu for BeamMP / CaRP.
--   Vehicle spoofer   hides vehicle config edits from the server until you press "Unspoof vehicle".
--   Infinite fuel     keeps the fuel tanks of your vehicle full.
--   HWID spoofer      replaces the game's hardware id.
--   CaRP              free repairs (hides resets and damage), perfect missions, hidden teleport and
--                     speed trap reports, mission trailer removal, autopilot autofarm. All of it works
--                     on the packets sent to the server. The autopilot has its own settings window.
-- Toggle the window with the "Toggle the Mod-Menu UI" keybind (default: alt g).

local M = {}
M.dependencies = {"CoolModUtils"}

local util
local isLoaded = false

local LOG_TAG = "modmenumain"
local SETTINGS_PATH = "/settings/modmenuSettings.json"
local WINDOW_NAME = "CaRP Mod Menu"
local AUTOPILOT_WINDOW_NAME = "Autopilot settings"

local GREEN = {0.35, 0.85, 0.45, 1}
local GRAY = {0.60, 0.62, 0.68, 1}
local ORANGE = {0.95, 0.55, 0.15, 1}

M.GlobalSettings = {
	AutoFarmMode = "Inactive",
	AiMode = "None",
}

-- Persistent settings. Unknown keys in the saved file are ignored. The CaRP cheats are opt-in:
-- they change what is sent to the server.
local SETTINGS_VERSION = 2
local settings = {
	SettingsVersion = SETTINGS_VERSION,
	VehicleSpoofer = true,
	InfiniteFuel = true,
	ShowCarpElements = true,
	FreeRepairs = false,
	PaxSpoofer = false,
	HideTeleportReports = false,
	HideSpeedTraps = false,
	DeleteMissionTrailer = false,
	Autofarm = false,
	-- Autopilot settings window
	AutofarmSpeed = 130,          -- km/h, the AI still slows down for corners and traffic
	AutofarmAggression = 55,      -- %
	AutofarmCornerCutting = 40,   -- %, 100 is BeamNG's default, less keeps the AI in its lane in corners
	AutofarmKeepLane = true,
	AutofarmLaneGuard = true,
	AutofarmAvoidCars = true,
	AutofarmBlobGuard = true,
	AutofarmLoadBlobs = true,
	AutofarmBlobDistance = 150,   -- m
	AutofarmDrawBoxes = false,
	AutofarmArriveDistance = 10,  -- m to the road node that counts as arrived
	AutofarmSpoofDistance = 250,  -- m, never claim to be further away than this from the real position
	AutofarmRequestTimeout = 5,   -- s to wait for the server to start or end the mission
	AutofarmSkipTime = 180,       -- s a contact that gave no mission is skipped
	AutofarmStuckTime = 4,        -- s below walking speed before the AI counts as stuck
	AutofarmReplans = 2,          -- re-plans while stuck before the vehicle is repaired
	AutofarmRepairDamage = 15,    -- % of broken + deformed beams that triggers a repair
	AutofarmRepairCooldown = 15,  -- s between two repairs
	AutofarmEngineRepair = true,
	ConsoleDebugger = false,
	MenuVisible = true,
	MenuScale = 100, -- slider value in percent, see menuScale()
	CurrentHwid = "",
}
M.SavingSettings = settings

local DEFAULTS = {}
for key, defaultValue in pairs(settings) do DEFAULTS[key] = defaultValue end

local settingsDirty = false
local window
local autopilotWindow
local tasks = {}

-- Live state
local currentServer
local isCarpServer = false
local spectatorNames = {}
local currentCar
local currentGoal
local spoofPos -- while set, the server is told the vehicle stands here (see onSendToServer)
local bypassVehicleSpoofer = false
local intercepted = {edits = 0, resets = 0, events = 0} -- packets hidden or rewritten this session

-- Originals of everything we hook
local sendToServer
local originalGetHardwareID

local function dprint(...)
	if settings.ConsoleDebugger then print("[ModMenu]", ...) end
end

----------------------------------------------------------------------------------------------------
-- Settings
----------------------------------------------------------------------------------------------------

local function generateHwid()
	local chars = "ABCDEF0123456789"
	local id = {}
	for i = 1, 32 do
		local index = math.random(#chars)
		id[i] = chars:sub(index, index)
	end
	return table.concat(id)
end

local function loadSettings()
	local stored = jsonReadFile(SETTINGS_PATH)
	if type(stored) == "table" then
		-- Settings written by an older version only keep the HWID, the defaults changed.
		local current = stored.SettingsVersion == SETTINGS_VERSION
		for key, defaultValue in pairs(settings) do
			local keep = current or key == "CurrentHwid"
			if keep and type(stored[key]) == type(defaultValue) then settings[key] = stored[key] end
		end
		if not current then settingsDirty = true end
	end
	if settings.CurrentHwid == "" then
		math.randomseed(os.time() + math.floor(os.clock() * 1000000)) -- unseeded, every install would get the same id
		settings.CurrentHwid = generateHwid()
		settingsDirty = true
	end
end

local function saveSettings()
	jsonWriteFile(SETTINGS_PATH, settings, true)
	settingsDirty = false
end

local function changed()
	settingsDirty = true
end

----------------------------------------------------------------------------------------------------
-- Network packets
----------------------------------------------------------------------------------------------------
-- Everything the game sends to the server goes through MPGameNetwork.send. BeamMP builds most
-- packets in a LuaJIT string.buffer (MPNetworkHelpers.generatePacketBuffer), so `data` is either
-- a string or a buffer; tostring() reads a buffer without consuming it. Packet layout:
--   Oc:<serverVehicleID>:<json>   vehicle config edit (spawn menu, parts, tuning, "Sync" button)
--   Or:<serverVehicleID>:<json>   vehicle reset or recover, CaRP charges roadside repairs for it
--   E:<event>:<data>              client to server event (TriggerServerEvent), CaRP uses JSON data

local function packetText(data)
	if type(data) == "string" then return data end
	local ok, text = pcall(tostring, data)
	return ok and type(text) == "string" and text or nil
end

local function decodeJson(text)
	local ok, decoded = pcall(jsonDecode, text)
	return ok and type(decoded) == "table" and decoded or nil
end

local function event(name, body)
	return "E:" .. name .. ":" .. body
end

-- Reports from these events make the server bill or penalize a reset.
local RESET_EVENTS = {
	receiveHandleAnyMissionAttemptedReset = true,
	receiveHandleSpecialMissionAttemptedReset = true,
}

local PERFECT_GEES = 0.3 -- g, per axis in the "x@y@z" maximumGees report

-- Turns the mission report into a perfect run. Layout from carp.sendMissionRequest:
--   {x, y, z, resetDuringMission, maximumGees = "x@y@z", excitementScore, compRI, dSync,
--    passengerPayload = carp_passengers.getPassengerMissionData()}
-- Penalties and scores the server rates the run by are zeroed. Fun passengers (isExciteMission)
-- want a high excitement score, every other passenger a low one.
local function perfectMission(payload)
	payload.resetDuringMission = false
	if type(payload.maximumGees) == "string" then
		payload.maximumGees = payload.maximumGees:gsub("[-%d%.e]+", function(number)
			return string.format("%.2f", math.min(math.abs(tonumber(number) or 0), PERFECT_GEES))
		end)
	end

	local pax = payload.passengerPayload
	if type(pax) ~= "table" then return end
	if type(pax.paxMissionRequests) == "table" then
		for request in pairs(pax.paxMissionRequests) do pax.paxMissionRequests[request] = 0 end
	end
	if type(pax.paxRequestWarnings) == "table" then
		for warning in pairs(pax.paxRequestWarnings) do pax.paxRequestWarnings[warning] = false end
	end
	pax.damagePercent = 0
	pax.totalDriftScore = 0
	pax.gForceUISmoothed = 0
	local limit = tonumber(pax.speedExceedLimit)
	if limit and tonumber(pax.peakSpeedKmh) then pax.peakSpeedKmh = math.min(pax.peakSpeedKmh, limit - 1) end
	if limit and tonumber(pax.currentSpeedKmh) then pax.currentSpeedKmh = math.min(pax.currentSpeedKmh, limit - 1) end

	local score
	if pax.isExciteMission then
		score = math.max(tonumber(payload.excitementScore) or 0, tonumber(pax.excitementTargetScore) or 0)
	else
		score = 0
		for _, key in ipairs({"currentDriftScore", "currentGforceScore", "currentAirtimeScore", "currentSpeedScore",
			"currentDriftScoreWeighted", "currentGforceScoreWeighted", "currentAirtimeScoreWeighted",
			"currentSpeedScoreWeighted", "driftCombo", "speedCombo"}) do
			if pax[key] ~= nil then pax[key] = 0 end
		end
	end
	payload.excitementScore = score
	pax.excitementScore = score
end

-- Special missions come with a trailer (carp.onClientStartMission spawns it). At the destination
-- CaRP reports the average of the vehicle and trailer position, with z = "300" when they are more
-- than 15 m apart. "Delete mission trailer" removes it (see trailerTask) and reports it right next to
-- the vehicle instead.
local TRAILER_OFFSET = 0.5 -- m, the reported trailer is at most this far from the vehicle
local missionTrailer = {} -- id, seenAt, registeredAt, deleted: for the running trailer mission

local function trailerMission()
	return isCarpServer and carp and carp.hasTrailerMission and carp.hasTrailerMission() and true or false
end

local function reportTrailerNextToVehicle(payload)
	local base = spoofPos
	if not base then
		local veh = be and be:getPlayerVehicle(0)
		if not veh then return end
		base = veh:getPosition()
	end
	local angle, distance = math.random() * 2 * math.pi, math.sqrt(math.random()) * TRAILER_OFFSET
	local trailerX, trailerY = base.x + math.cos(angle) * distance, base.y + math.sin(angle) * distance
	payload.x, payload.y, payload.z = (base.x + trailerX) / 2, (base.y + trailerY) / 2, base.z
end

-- Returns the packet to send instead, `false` to drop it, or nil to send it unchanged.
local function rewriteCarpEvent(name, body)
	if settings.HideTeleportReports and name == "receiveHandleTeleport" then return false end
	if settings.HideSpeedTraps and name == "receiveHandleProcessSpeedtrap" then return false end
	-- Without the trailer every reset of the vehicle counts as giving up the special mission.
	if missionTrailer.deleted and name == "receiveHandleSpecialMissionAttemptedReset" then return false end

	if settings.FreeRepairs then
		if RESET_EVENTS[name] then return false end
		if name == "setDamagedParts" then return event(name, "[]") end
		if name == "setDamageStatus" then
			local damage = decodeJson(body)
			if not damage then return nil end
			damage.broBeams, damage.defBeams = 0, 0
			if damage.tbroBeams then damage.tbroBeams, damage.tdefBeams = 0, 0 end
			return event(name, jsonEncode(damage))
		end
	end

	-- The mission request: {x, y, z} to start a mission, plus the mission report at the destination.
	local trailerReport = settings.DeleteMissionTrailer and trailerMission()
	if name == "receiveHandlePlayerGetPosition" and (spoofPos or settings.PaxSpoofer or trailerReport) then
		local payload = decodeJson(body)
		if not payload then return nil end
		if spoofPos then
			payload.x, payload.y, payload.z = spoofPos.x, spoofPos.y, spoofPos.z
		end
		-- Only the report at the destination carries more than the position.
		local atDestination = payload.resetDuringMission ~= nil
		if trailerReport and atDestination then reportTrailerNextToVehicle(payload) end
		if settings.PaxSpoofer and atDestination then perfectMission(payload) end
		dprint("mission request rewritten")
		return event(name, jsonEncode(payload))
	end
end

-- Zp:<serverVehicleID>:{"pos":[x,y,z],"vel":[..],"rvel":[..],"rot":[..],"tim":..,"ping":..}
local function rewritePosition(text)
	local prefix, body = text:match("^(Zp:[^:]+:)(.*)$")
	local data = body and decodeJson(body)
	if not data then return nil end
	data.pos = {spoofPos.x, spoofPos.y, spoofPos.z}
	data.vel = {0, 0, 0}
	data.rvel = {0, 0, 0}
	return prefix .. jsonEncode(data)
end

local function onSendToServer(data)
	if not sendToServer then return end

	local text = packetText(data)
	if not text then return sendToServer(data) end

	local kind = text:sub(1, 2)
	local replacement

	if kind == "Oc" then
		if settings.VehicleSpoofer and not bypassVehicleSpoofer then
			intercepted.edits = intercepted.edits + 1
			dprint("vehicle edit hidden")
			return
		end
		bypassVehicleSpoofer = false
	elseif kind == "Or" then
		if isCarpServer and settings.FreeRepairs then
			intercepted.resets = intercepted.resets + 1
			dprint("reset hidden")
			return
		end
	elseif kind == "Zp" then
		if spoofPos then replacement = rewritePosition(text) end
	elseif kind == "E:" and isCarpServer then
		local name, body = text:match("^E:([^:]+):(.*)$")
		if name then replacement = rewriteCarpEvent(name, body) end
		if replacement ~= nil then intercepted.events = intercepted.events + 1 end
		if replacement == false then
			dprint("event dropped: " .. name)
			return
		end
	end

	sendToServer(replacement or data)
end

----------------------------------------------------------------------------------------------------
-- Hooks
----------------------------------------------------------------------------------------------------

local function installNetworkHook()
	util.Hooker.HookFunction("MPGameNetwork", "send", onSendToServer, function(original)
		sendToServer = original
		dprint("network hook installed")
	end)
end

----------------------------------------------------------------------------------------------------
-- Game helpers
----------------------------------------------------------------------------------------------------

local function playerVehicle()
	return be and be:getPlayerVehicle(0)
end

local function sendVehicleEditBypassed()
	local veh = playerVehicle()
	if veh and MPVehicleGE and MPVehicleGE.sendVehicleEdit then
		bypassVehicleSpoofer = true
		MPVehicleGE.sendVehicleEdit(veh:getID())
	end
end

local function readSpectators()
	local names = {}
	local veh = playerVehicle()
	local vehicleData = veh and MPVehicleGE and MPVehicleGE.getVehicleByGameID(veh:getID())
	if vehicleData and vehicleData.spectators then
		local players = MPVehicleGE.getPlayers()
		for playerId in pairs(vehicleData.spectators) do
			local player = players[playerId]
			if player and player.name ~= vehicleData.ownerName then names[#names + 1] = player.name end
		end
		table.sort(names)
	end
	return names
end

local FUEL_COMMAND = [[
local storages = energyStorage.getStorages()
if not storages then return end
for _, storage in pairs(storages) do
	if storage.type ~= "pressureTank" and storage.setRemainingRatio then
		storage:setRemainingRatio(1)
	end
end
]]

-- AI mode and whether the engine is dead: off, disabled by damage, locked up or hydrolocked.
local AI_MODE_REPORT = [[
local engineDead = electrics.values.engineRunning == 0
if damageTracker and damageTracker.getDamage then
	engineDead = engineDead or damageTracker.getDamage("engine", "engineDisabled")
		or damageTracker.getDamage("engine", "engineLockedUp") or damageTracker.getDamage("engine", "engineHydrolocked")
end
obj:queueGameEngineLua("modmenumain.RecieveAiMode('" .. ai.mode .. "', " .. tostring(engineDead and true or false) .. ")")
]]

----------------------------------------------------------------------------------------------------
-- Autofarm
----------------------------------------------------------------------------------------------------
-- 1. Picks the nearest CaRP contact (mission start), or the mission destination while a mission runs.
-- 2. The AI drives to the road node closest to it. BeamNG's AI only drives on the road network, so
--    the last stretch to a point off the road is never driven.
-- 3. Once there (or stuck close enough), the server is told the vehicle stands on the point: the
--    position packets (Zp) and the mission request carry the point's position.
-- 4. The mission request is sent, the spoof stays until the server answers, then the real position
--    is sent again and the next target is picked.
-- While driving, blobs (see blobGuard) slow the AI down, a wrong lane makes it re-plan, and damage,
-- a dead engine or being stuck puts the vehicle back on the road, which repairs it. The tuning values
-- are in settings, see the "Autopilot settings" window.

local FARM_TICK = 0.25
local GUARD_TICK = 0.05         -- s, at 400 km/h the vehicle moves 5.5 m per guard tick (at most once a frame)
local STUCK_SPEED = 1           -- m/s
local SPOOF_LEAD = 0.8          -- s of spoofed position packets before the request
local REPAIR_SETTLE = 2         -- s to let the vehicle land after the repair before driving on
local REPAIRS_PER_START = 3     -- repairs on the way to one contact before it is skipped
local ENGINE_DEAD_TIME = 2      -- s the engine has to be off before it counts as dead
local WRONG_LANE_TIME = 1       -- s on the wrong side of a two-way road before the AI re-plans
local WRONG_LANE_MARGIN = 0.75  -- m past the road center that counts as the wrong side
local WRONG_LANE_MIN_SPEED = 8  -- m/s, below this the AI may be turning or parking
local LANE_REPLAN_COOLDOWN = 3  -- s
local OWN_HALF_WIDTH = 1.6      -- m to each side of the driving line: a car half width and a margin
local BLOB_GAP = 9              -- m from the vehicle to the blob's box the AI stops at
local BLOB_DECEL = 5            -- m/s², the braking the speed cap plans with
local BLOB_HEIGHT = 6           -- m, blobs further above or below are on a bridge or under it
local BLOB_LOAD_RETRY = 3       -- s between two spawn queue loads
local BLOB_IGNORE_AFTER = 10    -- s standing in front of a blob that does not load before it is ignored
local BLOB_IGNORE_TIME = 30     -- s

local farm = {state = "idle"}
local farmClock = 0
local lastRepairAt = -math.huge
local farmRepairs = 0
local laneFixes = 0
local engineDead = false -- reported by the vehicle together with the AI mode
local blobs = {ignored = {}, lastLoad = -math.huge, blocked = false} -- stoppedSince: farmClock
local sentSpeed -- m/s, last speed limit sent to the AI

local function setFarmMode(text)
	M.GlobalSettings.AutoFarmMode = text
end

local function drivingText()
	return farm.kind == "start" and "Driving to a mission" or "Driving to the destination"
end

local function parseCoords(value)
	if type(value) == "table" and value.x then return vec3(value.x, value.y, value.z) end
	if type(value) ~= "string" then return nil end
	local x, y, z = value:match("^%s*([-%d%.e]+)|([-%d%.e]+)|([-%d%.e]+)")
	x, y, z = tonumber(x), tonumber(y), tonumber(z)
	return x and vec3(x, y, z) or nil
end

local function currentMission()
	local mission = carp and carp.getCurrentMission and carp.getCurrentMission()
	return type(mission) == "table" and mission.missionDestination and mission or nil
end

local function missionDestination(mission)
	local pos = parseCoords(mission.destinationCoords)
	if pos then return pos end
	local group = scenetree and scenetree.CarpmissionTriggersGroup
	if not group then return nil end
	for _, name in pairs(group:getObjects()) do
		local object = group:findObject(name)
		if object and not name:find("icon", 1, true) then return object:getPosition() end
	end
end

local function nearestContact(from)
	local best, bestKey, bestDistance
	local contacts = carp_poi and carp_poi.getContactWaypoints and carp_poi.getContactWaypoints() or {}
	for key, waypoint in pairs(contacts) do
		local pos = waypoint._x and vec3(waypoint._x, waypoint._y, waypoint._z) or parseCoords(waypoint.location)
		local skippedUntil = farm.blacklist and farm.blacklist[key]
		if pos and not (skippedUntil and skippedUntil > farmClock) then
			local distance = (pos - from):length()
			if not bestDistance or distance < bestDistance then
				best, bestKey, bestDistance = pos, key, distance
			end
		end
	end
	return best, bestKey
end

-- The road node nearest to `pos`, which is as close as the AI can drive.
local function roadNodeNear(pos)
	if not (map and map.findClosestRoad) then return nil end
	local nodeA, nodeB = map.findClosestRoad(pos)
	local nodes = map.getMap().nodes
	local a, b = nodeA and nodes[nodeA], nodeB and nodes[nodeB]
	if a and b then
		if (a.pos - pos):length() <= (b.pos - pos):length() then return nodeA, a.pos end
		return nodeB, b.pos
	end
	if a then return nodeA, a.pos end
	if b then return nodeB, b.pos end
end

-- Signed distance of `pos` from the center line of the two-way road it is on, positive on the legal
-- side for a vehicle moving along `vel`. nil on one-way roads, in junctions and off the road.
local function laneOffset(pos, vel)
	local nameA, nameB, distance = map.findClosestRoad(pos)
	local nodes = nameA and nameB and map.getMap().nodes
	local a, b = nodes and nodes[nameA], nodes and nodes[nameB]
	if not (a and b) then return nil end
	local link = (a.links and a.links[nameB]) or (b.links and b.links[nameA])
	if not link or link.oneWay then return nil end
	local lanes = type(link.lanes) == "string" and link.lanes or ""
	if lanes ~= "" and not (lanes:find("+", 1, true) and lanes:find("-", 1, true)) then return nil end
	if distance and distance > math.max(a.radius or 0, b.radius or 0) then return nil end

	local dx, dy = b.pos.x - a.pos.x, b.pos.y - a.pos.y
	local length = math.sqrt(dx * dx + dy * dy)
	if length < 1 then return nil end
	dx, dy = dx / length, dy / length
	local rx, ry = pos.x - a.pos.x, pos.y - a.pos.y
	local along = rx * dx + ry * dy
	if along <= 0 or along >= length then return nil end -- in the junction at either end
	if vel.x * dx + vel.y * dy < 0 then dx, dy = -dx, -dy end
	local legalSide = map.getRoadRules and map.getRoadRules().rightHandDrive and -1 or 1
	return (rx * dy - ry * dx) * legalSide -- (dy, -dx) points to the right of the driving direction
end

local function aiCommand(veh, command)
	veh:queueLuaCommand(command)
end

local function cruiseSpeed()
	return math.max(30, settings.AutofarmSpeed) / 3.6
end

local function setAiSpeed(veh, speed)
	if sentSpeed and math.abs(sentSpeed - speed) < 0.5 then return end
	sentSpeed = speed
	aiCommand(veh, string.format("ai.setSpeed(%.2f)", speed))
end

-- turnForceCoef pulls the planned line to the inside of corners, BeamNG's default is 2.
local function driveTo(veh, nodeName)
	sentSpeed = cruiseSpeed()
	aiCommand(veh, string.format([[
		ai.setMode("manual")
		ai.setSpeedMode("limit")
		ai.setSpeed(%.2f)
		ai.setAggression(%.2f)
		ai.driveInLane(%q)
		ai.setAvoidCars(%q)
		ai.setParameters({turnForceCoef = %.2f})
		ai.setTarget(%q)
	]], sentSpeed, settings.AutofarmAggression / 100, settings.AutofarmKeepLane and "on" or "off",
		settings.AutofarmAvoidCars and "on" or "off", 2 * settings.AutofarmCornerCutting / 100, nodeName))
end

local function stopSpoof()
	if spoofPos then dprint("position spoof off") end
	spoofPos = nil
end

local function resetFarm(veh)
	stopSpoof()
	if veh and farm.state ~= "idle" then aiCommand(veh, [[ai.setMode("disabled")]]) end
	farm = {state = "idle", blacklist = farm.blacklist}
	blobs.blocked, blobs.stoppedSince = false, nil
	currentGoal = nil
end

local function skipContact()
	if farm.kind == "start" then farm.blacklist[farm.key] = farmClock + settings.AutofarmSkipTime end
	farm.state = "idle"
end

local function pickTarget(veh)
	local mission = currentMission()
	local pos, key, kind
	if mission then
		pos, kind = missionDestination(mission), "destination"
		key = tostring(mission.missionDestination)
	else
		pos, key = nearestContact(veh:getPosition())
		kind = "start"
	end
	if not pos then
		setFarmMode(mission and "Waiting for the destination" or "No mission point found")
		return
	end

	local nodeName, nodePos = roadNodeNear(pos)
	if not nodeName then
		setFarmMode("No road near the target")
		return
	end

	farm = {state = "drive", kind = kind, key = key, pos = pos, node = nodeName, nodePos = nodePos,
		slowFor = 0, deadFor = 0, wrongFor = 0, laneReplanAt = -math.huge, replans = 0, repairs = 0,
		blacklist = farm.blacklist or {}}
	currentGoal = pos
	driveTo(veh, nodeName)
	setFarmMode(drivingText())
end

local function beginSpoof(veh)
	aiCommand(veh, [[ai.setMode("stop")]])
	spoofPos = vec3(farm.pos.x, farm.pos.y, farm.pos.z + 0.5)
	farm.state = "spoof"
	farm.until_ = farmClock + SPOOF_LEAD
	dprint("position spoof on")
	setFarmMode("Reporting position at the point")
end

-- Same measure the CaRP server uses for damage: (broken + deformed) / total beams.
local function damageRatio(veh)
	local stats = carp_vehicle and carp_vehicle.getDamageStats and carp_vehicle.getDamageStats(veh:getID())
	if not (stats and stats.totalBeams and stats.totalBeams > 0) then return 0 end
	return ((stats.brokenBeams or 0) + (stats.deformedBeams or 0)) / stats.totalBeams
end

-- Puts the vehicle back on the last road it drove on and resets it, which repairs it and its engine.
-- With "Free repairs" on, the reset packet and the damage report never reach the server.
local function repairVehicle(veh, reason)
	if farmClock - lastRepairAt < settings.AutofarmRepairCooldown then return false end
	lastRepairAt = farmClock
	farmRepairs = farmRepairs + 1
	farm.repairs = farm.repairs + 1
	aiCommand(veh, [[ai.setMode("disabled")]])
	if spawn and spawn.teleportToLastRoad then
		spawn.teleportToLastRoad()
	else
		aiCommand(veh, [[recovery.startRecovering() recovery.stopRecovering()]])
	end
	engineDead = false -- until the vehicle reports again
	farm.state = "repair"
	farm.until_ = farmClock + REPAIR_SETTLE
	farm.slowFor, farm.deadFor, farm.wrongFor = 0, 0, 0
	dprint("repair: " .. reason)
	setFarmMode("Repairing (" .. reason .. ")")
	return true
end

-- Blob boxes, same as CaRP draws them for trailers (carp/trailerBoxes.lua): the spawn queue entry
-- names the vehicle and config, lua/trailerBoundingBoxes.json (shipped with CaRP) has the box of
-- every trailer config as full extents and the offset of the box center from the reference node.
-- Everything else gets a car sized box. The box turns with the blob's last known rotation.
local CAR_BOX = {extents = {x = 2.1, y = 5.0, z = 1.6}, refnodeOffset = {x = 0, y = 0, z = 0.6}}
local BOX_CORNERS = { -- unit corners, bottom face first, in the order drawBox uses
	{-1, -1, -1}, {1, -1, -1}, {1, 1, -1}, {-1, 1, -1},
	{-1, -1, 1}, {1, -1, 1}, {1, 1, 1}, {-1, 1, 1},
}
local BOX_FACES = {{2, 1, 4, 3}, {5, 6, 7, 8}, {1, 2, 6, 5}, {2, 3, 7, 6}, {3, 4, 8, 7}, {4, 1, 5, 8}}
local BOX_EDGES = {{1, 2}, {2, 3}, {3, 4}, {4, 1}, {5, 6}, {6, 7}, {7, 8}, {8, 5}, {1, 5}, {2, 6}, {3, 7}, {4, 8}}

local trailerSizes -- false when CaRP's file is missing
local boxSizeCache = {} -- [serverVehicleID] = {raw = spawnQueue.data, size = box}

local function trailerSize(spawnData)
	if trailerSizes == nil then trailerSizes = jsonReadFile("lua/trailerBoundingBoxes.json") or false end
	if not (trailerSizes and spawnData) then return nil end
	local partConfig = type(spawnData.vcf) == "table" and spawnData.vcf.partConfigFilename
	if type(partConfig) ~= "string" then return nil end
	local jbeam, config = partConfig:match("^vehicles/(%g+)/(%g+)%.pc")
	if not jbeam or jbeam ~= spawnData.jbm or not trailerSizes[jbeam] then return nil end
	return trailerSizes[jbeam][config]
end

local function blobSize(id, vehicle)
	local raw = type(vehicle.spawnQueue) == "table" and vehicle.spawnQueue.data
	if type(raw) ~= "string" then return CAR_BOX end
	local cached = boxSizeCache[id]
	if not (cached and cached.raw == raw) then
		cached = {raw = raw, size = trailerSize(decodeJson(raw)) or CAR_BOX}
		boxSizeCache[id] = cached
	end
	return cached.size
end

-- Rotates (x, y, z) by quaternion q like BeamNG's quat * vec3.
local function rotate(q, x, y, z)
	local tx, ty, tz = 2 * (q.y * z - q.z * y), 2 * (q.z * x - q.x * z), 2 * (q.x * y - q.y * x)
	return x - q.w * tx + (q.y * tz - q.z * ty),
		y - q.w * ty + (q.z * tx - q.x * tz),
		z - q.w * tz + (q.x * ty - q.y * tx)
end

-- Fills `out` with the 8 corners of the blob's box as {x, y, z}. False without a position.
local function blobCorners(id, vehicle, out)
	local pos, rot = vehicle.position, vehicle.rotation
	if not pos or (pos.x == 0 and pos.y == 0) then return false end
	if not (rot and rot.w) then rot = {x = 0, y = 0, z = 0, w = 1} end
	local size = blobSize(id, vehicle)
	local offset, extents = size.refnodeOffset, size.extents
	local ox, oy, oz = rotate(rot, offset.x, offset.y, offset.z)
	for i, unit in ipairs(BOX_CORNERS) do
		local cx, cy, cz = rotate(rot, unit[1] * extents.x / 2, unit[2] * extents.y / 2, unit[3] * extents.z / 2)
		local corner = out[i] or {}
		corner.x, corner.y, corner.z = pos.x + ox + cx, pos.y + oy + cy, pos.z + oz + cz
		out[i] = corner
	end
	return true
end

-- Every vehicle BeamMP knows but has not spawned: queued players and deleted vehicles.
local function forEachBlob(callback)
	local vehicles = MPVehicleGE and MPVehicleGE.getVehicles and MPVehicleGE.getVehicles()
	if not vehicles then return end
	for id, vehicle in pairs(vehicles) do
		if not vehicle.isSpawned then callback(id, vehicle) end
	end
end

local drawCorners = {}
local drawPoints = {}
local BOX_FILL, BOX_EDGE

local function drawBlobBoxes()
	if not (debugDrawer and vec3 and ColorF) then return end
	BOX_FILL = BOX_FILL or ColorF(0.2, 0.6, 1, 0.25)
	BOX_EDGE = BOX_EDGE or ColorF(0.2, 0.6, 1, 1)
	forEachBlob(function(id, vehicle)
		if not blobCorners(id, vehicle, drawCorners) then return end
		for i, corner in ipairs(drawCorners) do
			drawPoints[i] = drawPoints[i] or vec3()
			drawPoints[i]:set(corner.x, corner.y, corner.z)
		end
		-- both windings, a quad is only drawn from its front side
		for _, face in ipairs(BOX_FACES) do
			local a, b, c, d = drawPoints[face[1]], drawPoints[face[2]], drawPoints[face[3]], drawPoints[face[4]]
			debugDrawer:drawQuadSolid(a, b, c, d, BOX_FILL)
			debugDrawer:drawQuadSolid(d, c, b, a, BOX_FILL)
		end
		for _, edge in ipairs(BOX_EDGES) do
			debugDrawer:drawLine(drawPoints[edge[1]], drawPoints[edge[2]], BOX_EDGE)
		end
	end)
end

-- BeamMP shows vehicles of players that are still loading (spawn queue) or were deleted as blobs:
-- a position without a vehicle, so the AI cannot see them and drives through them. The guard caps
-- the AI speed so it stops in front of a blob box on its line, and loads the spawn queue when a
-- queued blob comes close, which turns it into a real vehicle the AI drives around.
local guardCorners = {}
local function blobGuard()
	local veh = playerVehicle()
	if not (veh and farm.state == "drive") then
		blobs.blocked = false
		return
	end

	local cap, blocker
	local dir = veh:getDirectionVector()
	local dirLength = math.sqrt(dir.x * dir.x + dir.y * dir.y)
	if settings.AutofarmBlobGuard and dirLength > 0.1 then
		local pos = veh:getPosition()
		local speed = veh:getVelocity():length()
		local fx, fy = dir.x / dirLength, dir.y / dirLength
		local lookahead = speed * speed / (2 * BLOB_DECEL) + speed + BLOB_GAP + 20
		local loadQueue = false
		forEachBlob(function(id, vehicle)
			if (blobs.ignored[id] or -math.huge) > farmClock then return end
			if not blobCorners(id, vehicle, guardCorners) then return end
			local blobPos = vehicle.position
			local rx, ry = blobPos.x - pos.x, blobPos.y - pos.y
			if vehicle.spawnQueue and rx * rx + ry * ry < settings.AutofarmBlobDistance ^ 2 then loadQueue = true end
			if math.abs(blobPos.z - pos.z) >= BLOB_HEIGHT then return end
			-- the box's extent along and across the driving line
			local alongMin, alongMax, sideMin, sideMax = math.huge, -math.huge, math.huge, -math.huge
			for _, corner in ipairs(guardCorners) do
				local cx, cy = corner.x - pos.x, corner.y - pos.y
				local along, side = cx * fx + cy * fy, cx * fy - cy * fx
				alongMin, alongMax = math.min(alongMin, along), math.max(alongMax, along)
				sideMin, sideMax = math.min(sideMin, side), math.max(sideMax, side)
			end
			if alongMax > -2 and alongMin < lookahead and sideMax > -OWN_HALF_WIDTH and sideMin < OWN_HALF_WIDTH then
				local allowed = math.sqrt(2 * BLOB_DECEL * math.max(0, alongMin - BLOB_GAP))
				if not cap or allowed < cap then cap, blocker = allowed, id end
			end
		end)

		if loadQueue and settings.AutofarmLoadBlobs and MPVehicleGE.applyQueuedEvents
			and farmClock - blobs.lastLoad >= BLOB_LOAD_RETRY then
			blobs.lastLoad = farmClock
			dprint("loading the spawn queue")
			MPVehicleGE.applyQueuedEvents()
		end
	end

	-- A blob that never loads (deleted vehicle) would block the road forever.
	if not (cap and cap < STUCK_SPEED) then
		blobs.stoppedSince = nil
	elseif not blobs.stoppedSince then
		blobs.stoppedSince = farmClock
	elseif farmClock - blobs.stoppedSince >= BLOB_IGNORE_AFTER then
		blobs.ignored[blocker] = farmClock + BLOB_IGNORE_TIME
		blobs.stoppedSince = nil
		dprint("ignoring blob " .. tostring(blocker))
	end

	local cruise = cruiseSpeed()
	blobs.blocked = cap ~= nil and cap < cruise
	setAiSpeed(veh, blobs.blocked and cap or cruise) -- also applies a changed top speed
end

local function farmTick()
	local veh = playerVehicle()
	if not (settings.Autofarm and veh and isCarpServer and carp) then
		if farm.state ~= "idle" then resetFarm(veh) end
		if not settings.Autofarm then setFarmMode("Inactive") end
		return
	end
	currentCar = veh

	local missionRunning = currentMission() ~= nil
	local wantedKind = missionRunning and "destination" or "start"

	if farm.state == "idle" or ((farm.state == "drive") and farm.kind ~= wantedKind) then
		pickTarget(veh)
		return
	end

	if farm.state == "repair" then
		if farmClock < farm.until_ then return end
		farm.state = "drive"
		farm.replans = 0
		driveTo(veh, farm.node) -- a fresh route from wherever the repair put the vehicle
		setFarmMode(drivingText())
		return
	end

	if farm.state == "drive" then
		local pos, vel = veh:getPosition(), veh:getVelocity()
		local speed = vel:length()
		local toNode = (pos - farm.nodePos):length()
		local toTarget = (pos - farm.pos):length()
		local stuckTime = settings.AutofarmStuckTime
		farm.slowFor = (speed < STUCK_SPEED and not blobs.blocked) and farm.slowFor + FARM_TICK or 0
		farm.deadFor = (engineDead and settings.AutofarmEngineRepair) and farm.deadFor + FARM_TICK or 0

		if toNode < settings.AutofarmArriveDistance or (farm.slowFor >= stuckTime and toTarget <= settings.AutofarmSpoofDistance) then
			if toTarget <= settings.AutofarmSpoofDistance then
				beginSpoof(veh)
			else
				setFarmMode("Road ends too far from the point")
				skipContact()
			end
			return
		end

		local stuck = farm.slowFor >= stuckTime
		local repairReason = (farm.deadFor >= ENGINE_DEAD_TIME and "engine dead")
			or (damageRatio(veh) >= settings.AutofarmRepairDamage / 100 and "damaged")
			or (stuck and farm.replans >= settings.AutofarmReplans and "stuck")
		if repairReason then
			if farm.kind == "start" and farm.repairs >= REPAIRS_PER_START then
				setFarmMode("Repaired " .. farm.repairs .. " times, picking another point")
				skipContact()
			elseif not repairVehicle(veh, repairReason) then
				-- the cooldown runs, the reason stays and the repair follows as soon as it ends
				setFarmMode("Waiting to repair (" .. repairReason .. ")")
			end
			return
		end

		if stuck then
			farm.replans = farm.replans + 1
			farm.slowFor = 0
			driveTo(veh, farm.node) -- re-plans the route from where the vehicle stands
			setFarmMode("Stuck, re-planning")
			return
		end

		local offset = settings.AutofarmLaneGuard and speed > WRONG_LANE_MIN_SPEED and laneOffset(pos, vel)
		farm.wrongFor = (offset and offset < -WRONG_LANE_MARGIN) and farm.wrongFor + FARM_TICK or 0
		if farm.wrongFor >= WRONG_LANE_TIME and farmClock - farm.laneReplanAt >= LANE_REPLAN_COOLDOWN then
			farm.laneReplanAt = farmClock
			farm.wrongFor = 0
			laneFixes = laneFixes + 1
			driveTo(veh, farm.node) -- the new plan starts in the legal lane
			setFarmMode("Wrong lane, re-planning")
			return
		end

		setFarmMode(blobs.blocked and "Slowing down for a loading player" or drivingText())
		return
	end

	if farm.state == "spoof" then
		if farmClock < farm.until_ then return end
		farm.missionWas = missionRunning
		farm.state = "request"
		farm.until_ = farmClock + settings.AutofarmRequestTimeout
		carp.sendMissionRequest()
		setFarmMode("Mission request sent")
		return
	end

	if farm.state == "request" then
		if missionRunning ~= farm.missionWas then
			stopSpoof()
			dprint(missionRunning and "mission started" or "mission finished")
			farm.state = "idle"
		elseif farmClock >= farm.until_ then
			stopSpoof()
			setFarmMode("No answer from the server, trying the next point")
			skipContact()
		end
	end
end

local function farmTask()
	farmClock = farmClock + FARM_TICK
	local ok, err = pcall(farmTick)
	if not ok then
		stopSpoof() -- never leave the position spoofed after an error
		farm = {state = "idle", blacklist = farm.blacklist}
		error(err, 0)
	end
end

----------------------------------------------------------------------------------------------------
-- Scheduled tasks
----------------------------------------------------------------------------------------------------

local function fuelTask()
	local veh = playerVehicle()
	if veh and settings.InfiniteFuel then veh:queueLuaCommand(FUEL_COMMAND) end
end

local function statusTask()
	currentServer = MPCoreNetwork and MPCoreNetwork.getCurrentServer and MPCoreNetwork.getCurrentServer()
	spectatorNames = readSpectators()

	local name = currentServer and currentServer.name
	isCarpServer = carp ~= nil or (name ~= nil and name:lower():find("carp", 1, true) ~= nil)

	local veh = playerVehicle()
	if veh and (settings.Autofarm or (window and window.Visible)) then veh:queueLuaCommand(AI_MODE_REPORT) end
end

-- Deletes the trailer of a special mission. Deleting it right after the spawn breaks CaRP: the server
-- registers the trailer (setPlayerVehicleSlot) a moment later and would point CaRP at a vehicle
-- that is gone. carp_vehicle.removeTrailerVehicle is CaRP's own cleanup for a finished mission.
local TRAILER_TICK = 0.5
local TRAILER_DELETE_DELAY = 5     -- s after the server registered the trailer
local TRAILER_DELETE_TIMEOUT = 15  -- s after the spawn, when the server never registers it
local trailerClock = 0

local function trailerTask()
	trailerClock = trailerClock + TRAILER_TICK
	if not trailerMission() then
		missionTrailer = {}
		return
	end
	local slot = type(currentVehicles) == "table" and currentVehicles.trailer -- global of carp/vehicle.lua
	local id = type(slot) == "table" and slot.gameVehicleID
	local exists = id and be:getObjectByID(id) ~= nil

	if missionTrailer.deleted then
		-- a late setPlayerVehicleSlot points CaRP at the deleted trailer again
		if id and not exists then currentVehicles.trailer = nil end
		return
	end
	if not (settings.DeleteMissionTrailer and exists and carp_vehicle and carp_vehicle.removeTrailerVehicle) then return end

	if missionTrailer.id ~= id then missionTrailer.id, missionTrailer.seenAt, missionTrailer.registeredAt = id, trailerClock, nil end
	if slot.name and not missionTrailer.registeredAt then missionTrailer.registeredAt = trailerClock end
	local registered = missionTrailer.registeredAt and trailerClock - missionTrailer.registeredAt >= TRAILER_DELETE_DELAY
	if registered or trailerClock - missionTrailer.seenAt >= TRAILER_DELETE_TIMEOUT then
		missionTrailer.deleted = true
		carp_vehicle.removeTrailerVehicle()
		dprint("mission trailer deleted")
	end
end

local function saveTask()
	if settingsDirty then saveSettings() end
end

local function stopTasks()
	for name, id in pairs(tasks) do
		util.Scheduler.avoidFunction(id)
		tasks[name] = nil
	end
end

local function startTasks()
	tasks.fuel = util.Scheduler.every(1, fuelTask)
	tasks.status = util.Scheduler.every(0.5, statusTask)
	tasks.autofarm = util.Scheduler.every(FARM_TICK, farmTask)
	tasks.blobs = util.Scheduler.every(GUARD_TICK, blobGuard)
	tasks.trailer = util.Scheduler.every(TRAILER_TICK, trailerTask)
	tasks.save = util.Scheduler.every(5, saveTask)
end

----------------------------------------------------------------------------------------------------
-- UI
----------------------------------------------------------------------------------------------------

-- The slider shows 100% to 0%, the window really scales from 100% down to 40%.
local MIN_SCALE = 0.4
local function menuScale()
	return MIN_SCALE + (1 - MIN_SCALE) * (math.max(0, math.min(100, settings.MenuScale)) / 100)
end

local function carpHidden()
	return not settings.ShowCarpElements
end

local function toggle(key, label, tooltip, onChange, hidden)
	return {
		Type = "checkbox",
		Label = label,
		Tooltip = tooltip,
		Hidden = hidden,
		Get = function() return settings[key] end,
		Set = function(value)
			settings[key] = value
			changed()
			if onChange then onChange(value) end
		end,
	}
end

local function slider(key, label, min, max, format, tooltip, step, onChange)
	return {
		Type = "slider",
		Label = label,
		Min = min,
		Max = max,
		Step = step,
		Format = format,
		Tooltip = tooltip,
		Get = function() return settings[key] end,
		Set = function(value)
			settings[key] = value
			changed()
			if onChange then onChange(value) end
		end,
	}
end

-- Driving settings reach the AI with the next route, so a running drive gets a new one.
local function applyDriving()
	local veh = playerVehicle()
	if veh and farm.state == "drive" then driveTo(veh, farm.node) end
end

local function serverText()
	local name = currentServer and currentServer.name
	if not name then return "Offline" end
	name = name:gsub("%^[%w]", "") -- BeamMP color codes
	return #name > 28 and name:sub(1, 26) .. ".." or name
end

local function goalDistanceText()
	if not (settings.Autofarm and currentCar and currentGoal) then return "-" end
	return string.format("%.0f m", (currentCar:getPosition() - currentGoal):length())
end

local function value(label, textFunc, color, hidden)
	return {Type = "value", Label = label, TextFunc = textFunc, Color = color, Hidden = hidden}
end

local function onOff(enabled)
	return enabled and GREEN or GRAY
end

local function buildWindow()
	window = util.CreateWindow(WINDOW_NAME, {
		Visible = settings.MenuVisible,
		Width = 320,
		Scale = menuScale,
		Elements = {
			value("Server", serverText, function() return currentServer and GREEN or GRAY end),
			value("Mode", function() return isCarpServer and "CaRP" or "BeamMP" end,
				function() return isCarpServer and ORANGE or GRAY end),
			{Type = "slider", Label = "Scale", Format = "%d%%",
				Get = function() return settings.MenuScale end,
				Set = function(scale) settings.MenuScale = scale changed() end,
				Tooltip = "Zooms the whole menu. 100% is full size, 0% is the smallest."},
			{Type = "spacer", Height = 2},
			{Type = "section", Title = "Vehicle", DefaultOpen = true, Children = {
				toggle("VehicleSpoofer", "Vehicle spoofer", "Hides vehicle config edits (Oc packets) from the server."),
				toggle("InfiniteFuel", "Infinite fuel", "Keeps every fuel tank of your vehicle full."),
				{Type = "button", Text = "Unspoof vehicle", Fill = true, OnClick = sendVehicleEditBypassed,
					Tooltip = "Sends your current vehicle config to the server once."},
			}},
			{Type = "section", Title = "CaRP", DefaultOpen = true, Hidden = carpHidden, Children = {
				toggle("FreeRepairs", "Free repairs", "Hides resets and damage reports from the CaRP server."),
				toggle("PaxSpoofer", "Perfect missions", "Reports every passenger mission without penalties."),
				toggle("HideTeleportReports", "Hide teleport reports", "Does not report teleports to the CaRP server."),
					toggle("HideSpeedTraps", "Hide speed traps", "Does not report speed trap flashes to the CaRP server."),
				toggle("DeleteMissionTrailer", "Delete mission trailer",
					"Deletes the trailer of a special mission a few seconds after it spawns and reports it next to your vehicle at the destination."),
				toggle("Autofarm", "Autopilot autofarm",
					"Drives to the nearest mission and its destination, then reports the vehicle on the point.",
					function(enabled) if not enabled then resetFarm(playerVehicle()) setFarmMode("Inactive") end end),
				{Type = "button", Text = "Autopilot settings", Fill = true, OnClick = function()
					if autopilotWindow then autopilotWindow.Visible = not autopilotWindow.Visible end
				end, Tooltip = "Speed, lane keeping, blobs, repairs and mission point settings."},
			}},
			{Type = "section", Title = "Status", DefaultOpen = true, Children = {
				value("Spectators", function()
					return #spectatorNames > 0 and table.concat(spectatorNames, ", ") or "none"
				end, function() return #spectatorNames > 0 and ORANGE or GRAY end),
				value("Hidden edits", function() return tostring(intercepted.edits) end,
					function() return onOff(intercepted.edits > 0) end),
				value("Hidden resets", function() return tostring(intercepted.resets) end,
					function() return onOff(intercepted.resets > 0) end, carpHidden),
				value("Rewritten events", function() return tostring(intercepted.events) end,
					function() return onOff(intercepted.events > 0) end, carpHidden),
				value("AI", function() return M.GlobalSettings.AiMode end),
				value("Autofarm", function() return M.GlobalSettings.AutoFarmMode end, nil, carpHidden),
				value("Goal distance", goalDistanceText, nil, carpHidden),
				value("Autofarm repairs", function() return tostring(farmRepairs) end, nil, carpHidden),
				value("Lane corrections", function() return tostring(laneFixes) end, nil, carpHidden),
			}},
			{Type = "section", Title = "HWID spoofer", Children = {
				{Type = "label", TextFunc = function() return settings.CurrentHwid end, Color = GRAY},
				{Type = "button", Text = "Generate new HWID", Fill = true, OnClick = function()
					settings.CurrentHwid = generateHwid()
					saveSettings()
				end},
			}},
			{Type = "section", Title = "Settings", Children = {
				toggle("ShowCarpElements", "Show CaRP options", "Shows or hides everything CaRP specific."),
				toggle("ConsoleDebugger", "Debug output in console"),
			}},
			{Type = "spacer", Height = 2},
			{Type = "row", Children = {
				{Type = "button", Text = "Save settings", OnClick = saveSettings},
				{Type = "button", Text = "Hide menu", OnClick = function() M.ToggleModMenu() end,
					Tooltip = "Brings it back with the keybind (default: alt g)."},
			}},
		},
	})
end

----------------------------------------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------------------------------------

local function buildAutopilotWindow()
	autopilotWindow = util.CreateWindow(AUTOPILOT_WINDOW_NAME, {
		Visible = false,
		Width = 340,
		X = 400,
		Scale = menuScale,
		Elements = {
			{Type = "section", Title = "Driving", DefaultOpen = true, Children = {
				slider("AutofarmSpeed", "Top speed", 60, 400, "%d km/h",
					"It still slows down for corners, traffic and blobs.", 10),
				slider("AutofarmAggression", "Aggression", 10, 100, "%d%%",
					"How close to the grip limit it brakes, accelerates and corners.", 5, applyDriving),
				slider("AutofarmCornerCutting", "Corner cutting", 0, 100, "%d%%",
					"How far it cuts corners. 100% is BeamNG's default, less keeps it in its lane.", 5, applyDriving),
				toggle("AutofarmKeepLane", "Drive in lane", "Keeps to the legal lane instead of the whole road.", applyDriving),
				toggle("AutofarmLaneGuard", "Correct wrong lane",
					"Re-plans the route when it drives on the wrong side of a two-way road for a second."),
				toggle("AutofarmAvoidCars", "Avoid cars", "Brakes for and drives around other loaded vehicles.", applyDriving),
			}},
			{Type = "section", Title = "Loading players (blobs)", DefaultOpen = true, Children = {
				toggle("AutofarmBlobGuard", "Stop for blobs",
					"Slows down and stops in front of players that are still loading."),
				toggle("AutofarmLoadBlobs", "Load nearby blobs",
					"Loads the BeamMP spawn queue when a loading player comes close, so the AI sees the vehicle."),
				slider("AutofarmBlobDistance", "Load distance", 50, 500, "%d m", nil, 10),
				toggle("AutofarmDrawBoxes", "Draw bounding boxes",
					"Draws the box the AI avoids around every blob, trailers in their real size."),
			}},
			{Type = "section", Title = "Mission points", Children = {
				slider("AutofarmArriveDistance", "Arrive distance", 3, 50, "%d m",
					"Distance to the road node closest to the point that counts as arrived."),
				slider("AutofarmSpoofDistance", "Max report distance", 25, 500, "%d m",
					"The vehicle is only reported on a point this close to its real position.", 25),
				slider("AutofarmRequestTimeout", "Server timeout", 2, 20, "%d s",
					"How long to wait for the server to start or finish the mission."),
				slider("AutofarmSkipTime", "Skip failed point", 30, 600, "%d s",
					"How long a mission point that gave no mission is skipped.", 30),
			}},
			{Type = "section", Title = "Stuck and repair", Children = {
				slider("AutofarmStuckTime", "Stuck after", 2, 15, "%d s", "Time below walking speed that counts as stuck."),
				slider("AutofarmReplans", "Re-plans first", 0, 6, "%d",
					"New routes it tries while stuck before it repairs.", 1),
				slider("AutofarmRepairDamage", "Repair at damage", 5, 80, "%d%%",
					"Share of broken and deformed beams that triggers a repair.", 5),
				slider("AutofarmRepairCooldown", "Repair cooldown", 5, 60, "%d s", nil, 5),
				toggle("AutofarmEngineRepair", "Repair dead engine", "Repairs when the engine is off or broken for 2 s."),
			}},
			{Type = "spacer", Height = 2},
			{Type = "row", Children = {
				{Type = "button", Text = "Reset to defaults", OnClick = function()
					for key, defaultValue in pairs(DEFAULTS) do
						if key:find("^Autofarm.") then settings[key] = defaultValue end
					end
					changed()
					applyDriving()
				end},
				{Type = "button", Text = "Close", OnClick = function() autopilotWindow.Visible = false end},
			}},
		},
	})
end

local function init()
	if isLoaded then return end
	util = CoolModUtils
	if not util then
		log("E", LOG_TAG, "CoolModUtils is not loaded, the mod menu cannot start")
		return
	end
	isLoaded = true

	loadSettings()
	originalGetHardwareID = getHardwareID
	getHardwareID = function() return settings.CurrentHwid end

	buildWindow()
	buildAutopilotWindow()
	installNetworkHook()
	startTasks()
end

local function uninit()
	if not isLoaded then return end
	isLoaded = false

	if settingsDirty then saveSettings() end
	stopTasks()
	if window then
		window:Destroy()
		window = nil
	end
	if autopilotWindow then
		autopilotWindow:Destroy()
		autopilotWindow = nil
	end

	resetFarm(playerVehicle())
	util.Hooker.Unhook("MPGameNetwork", "send")
	sendToServer, isCarpServer = nil, false
	getHardwareID = originalGetHardwareID
end

local function toggleModMenu()
	if not window then return end
	window.Visible = not window.Visible
	settings.MenuVisible = window.Visible
	changed()
end

local function onWorldReadyState()
	if isLoaded then installNetworkHook() end -- no-op while the hook is in place
end

local function onPreRender()
	if isLoaded and settings.AutofarmDrawBoxes then drawBlobBoxes() end
end

local function recieveAiMode(mode, isEngineDead)
	M.GlobalSettings.AiMode = mode
	engineDead = isEngineDead == true
end

M.onExtensionLoaded = init
M.onExtensionUnloaded = uninit
M.onWorldReadyState = onWorldReadyState
M.onPreRender = onPreRender
M.RecieveAiMode = recieveAiMode -- called from the vehicle, name kept for the vehicle command
M.ToggleModMenu = toggleModMenu -- called by the keybind

return M
