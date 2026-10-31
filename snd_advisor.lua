local widget = widget ---@type Widget

function widget:GetInfo()
	return {
		name = "Advisor",
		desc = "Voice reminders: idle builders, tech 2 and 3, anti-air, anti-nuke, long-range plasma cannon, energy",
		author = "Backbone",
		date = "October 2026",
		license = "GNU GPL, v2 or later",
		layer = 0,
		enabled = true,
	}
end

-- Reminds the player of what is easy to forget: idle builders, teching up, anti-air, an anti-nuke, a long-range plasma
-- cannon, energy storage and converting surplus energy. Every ANNOUNCEMENT_SECONDS one announcement slot comes up, and
-- the most overdue active reminder (time past its own interval) gets it; priority only breaks ties, so no reminder can
-- crowd out the others.
-- Uses only the player's own team (units and income) and gives no orders. When watching a replay it follows every
-- team except Gaia and logs "[reminder]" lines instead of playing sounds, to test it on past games.

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------

local ANNOUNCEMENT_SECONDS = 10
local VOLUME = 0.7 -- as BAR's voice notifications; at most 1.0 (OpenAL's gain limit)

local IDLE_SECONDS = 30 -- guarding and assisting are orders, so they don't count as idle
local COMMANDER_MUTE_TECH2_BUILDERS = nil -- mutes the idle commander from this many tech 2 builders; nil: never

-- Reclaiming a wreck makes income spike for a moment, so income thresholds must hold this long.
local INCOME_HOLD_SECONDS = 60

-- Metal income thresholds at which a new lab costs about 90 s of income: T2 lab 2600 metal, Gantry 8000 metal.
local TECH2_METAL_PER_SECOND = 30
local TECH2_MINUTES = 14 -- nil: metal income only
local TECH3_METAL_PER_SECOND = 90 -- no time fallback: tech 3 is an option, not a must

local ANTIAIR_MINUTES = 3
local ANTIAIR_MIN_COUNT = 2

local ANTINUKE_MINUTES = 25
local ANTINUKE_METAL_PER_SECOND = 80 -- if you can afford a nuke, so can an equal opponent

-- Energy above the share level (top bar slider, default 95% of storage) goes to allies, or is lost when they are full
-- or there are none. Energy converters start below that (their slider, default 75%), so energy that stays near the
-- share level means the converters can't keep up with the surplus.
local ENERGY_SHARE_MARGIN = 0.05 -- "near": within this fraction of storage below the share level
local ENERGY_HOLD_SECONDS = 60

-- Energy storage: a team starts with 1000 (BAR's minimum; the commander's 500 is not added), one T1 energy storage adds
-- 6000. BARb Hard builds its first at about 5 min. Before that time, energy near the share level asks for storage
-- instead of converters while there is none: 175 metal is the cheaper fix.
local ENERGY_STORAGE_MINUTES = 6
local ENERGY_STORAGE_MIN = 7000

-- A long-range plasma cannon (Basilica, Basilisk, Olympus) fires only when its whole shot energy is in storage: 6000
-- for Basilisk and Olympus (one 3-shot salvo), 5000 for Basilica. The converters keep storage near their level (slider,
-- default 75%) and energy above the share level leaves, so only storage up to the lower of the two counts: at the
-- defaults 8000 storage. A cannon is due like a lab at about 90 s of income (Basilisk 4600 metal, 67000 energy), with
-- a T2 constructor to build it; then the cannon is suggested if the storage holds a shot, storage is asked for if not.
-- Storage is also asked for while a started cannon could not fire. No time fallback: a cannon is an option, not a must.
local LRPC_METAL_PER_SECOND = 50
local LRPC_ENERGY_PER_SECOND = 750
local LRPC_ENERGY_PER_SHOT = 6000
local LONG_RANGE_MIN_RANGE = 4000 -- static weapons from this range, not stockpiled: the cannons and the rapid-fire ones
local DEFAULT_CONVERSION_LEVEL = 0.75 -- game_energy_conversion.lua, if its "mmLevel" team rules param is missing

---@class Reminder
---@field key string condition, log name and voice line sounds/<key>.wav (spoken text in sounds/<key>.txt)
---@field interval number minimum seconds between two announcements
---@field priority number breaks ties between equally overdue reminders
---@field text string console message

---@type Reminder[]
local REMINDERS = {
	{
		key = "build_anti_nuke",
		interval = 60,
		priority = 5,
		text = "Build anti-nuke (none with a missile ready)",
	},
	{
		key = "build_anti_air",
		interval = 60,
		priority = 4,
		text = "Build anti-air",
	},
	{
		key = "commander_idle",
		interval = 30,
		priority = 3,
		text = "Commander idle",
	},
	{
		key = "tech_one_constructor_idle",
		interval = 30,
		priority = 2,
		text = "Tech 1 constructor idle",
	},
	{
		key = "tech_two_constructor_idle",
		interval = 30,
		priority = 2,
		text = "Tech 2 constructor idle",
	},
	{
		key = "consider_tech_two",
		interval = 120,
		priority = 1,
		text = "Consider tech 2",
	},
	{
		key = "consider_tech_three",
		interval = 120,
		priority = 1,
		text = "Consider tech 3",
	},
	{
		key = "consider_long_range_plasma_cannon",
		interval = 120,
		priority = 1,
		text = "Consider a long-range plasma cannon",
	},
	{
		key = "build_energy_storage",
		interval = 60,
		priority = 1,
		text = "Build energy storage",
	},
	{
		key = "consider_energy_converters",
		interval = 60,
		priority = 1,
		text = "Consider energy converters (energy near the share level)",
	},
}

-- Game sounds played for a missing voice line; the first one that exists is used.
local FALLBACK_SOUNDS = {
	"sounds/voice/en/winter/unused/IdleBuilders.wav",
	"sounds/ui/warning1.wav",
}

local DEFAULT_SOUND_FOLDER = "LuaUI/Widgets/bar-advisor/"

--------------------------------------------------------------------------------
-- Engine API and state
--------------------------------------------------------------------------------

local spEcho = Spring.Echo
local spGetAIInfo = Spring.GetAIInfo
local spGetGaiaTeamID = Spring.GetGaiaTeamID
local spGetMyTeamID = Spring.GetMyTeamID
local spGetPlayerInfo = Spring.GetPlayerInfo
local spGetSpectatingState = Spring.GetSpectatingState
local spGetTeamInfo = Spring.GetTeamInfo
local spGetTeamList = Spring.GetTeamList
local spGetTeamResources = Spring.GetTeamResources
local spGetTeamRulesParam = Spring.GetTeamRulesParam
local spGetTeamUnits = Spring.GetTeamUnits
local spGetUnitCommandCount = Spring.GetUnitCommandCount
local spGetUnitDefID = Spring.GetUnitDefID
local spGetUnitIsBeingBuilt = Spring.GetUnitIsBeingBuilt
local spGetUnitIsBuilding = Spring.GetUnitIsBuilding
local spGetUnitStockpile = Spring.GetUnitStockpile
local spIsReplay = Spring.IsReplay
local spPlaySoundFile = Spring.PlaySoundFile

local GAME_SPEED = Game.gameSpeed
local CHECK_FRAMES = GAME_SPEED -- conditions are evaluated once per second
local ANNOUNCEMENT_FRAMES = ANNOUNCEMENT_SECONDS * GAME_SPEED
local IDLE_FRAMES = IDLE_SECONDS * GAME_SPEED
local INCOME_HOLD_FRAMES = INCOME_HOLD_SECONDS * GAME_SPEED
local ENERGY_HOLD_FRAMES = ENERGY_HOLD_SECONDS * GAME_SPEED

-- Unit def lookups, filled in Initialize.
local idleReminderKeyByDefID = {} -- key of the reminder for an idle builder of this type
local isTech2FactoryDef = {} -- tech 3 factories count too: they are past tech 2
local isTech3FactoryDef = {}
local isAntiAirDef = {}
local isAntiNukeDef = {}
local isLongRangeDef = {} -- long-range plasma cannons and the rapid-fire ones

---@class WatchedTeam
---@field teamID number
---@field name string the team leader's player name, or the AI's name
---@field isAI boolean
---@field builders table<number, { idleReminderKey: string, idleSince: number|false }> unitID -> builder
---@field tech2Factories table<number, true> started, finished or not
---@field tech3Factories table<number, true> started, finished or not
---@field finishedTech2Factories table<number, true>
---@field antiAirUnits table<number, true>
---@field antiNukeUnits table<number, true>
---@field longRangeUnits table<number, true> started, finished or not
---@field reminderStates table<string, { activeSince: number, lastPlayedFrame: number? }> key -> state, while active
---@field incomeHeldSince table<string, number> resource and threshold -> frame since income has been at or above it
---@field energyNearShareSince number|false frame since when stored energy has been near the share level

---@type table<number, WatchedTeam>
local watchedTeams = {} -- teamID -> team; the player's own team, or every team but Gaia in a replay
local isReplayTest = false
local soundFileByKey = {}

--------------------------------------------------------------------------------
-- Unit tracking
--------------------------------------------------------------------------------

local function isFinished(unitID)
	return not spGetUnitIsBeingBuilt(unitID)
end

local function removeUnit(team, unitID)
	team.builders[unitID] = nil
	team.tech2Factories[unitID] = nil
	team.tech3Factories[unitID] = nil
	team.finishedTech2Factories[unitID] = nil
	team.antiAirUnits[unitID] = nil
	team.antiNukeUnits[unitID] = nil
	team.longRangeUnits[unitID] = nil
end

local function addUnit(team, unitID, unitDefID, finished)
	if isTech2FactoryDef[unitDefID] then
		team.tech2Factories[unitID] = true
	end
	if isTech3FactoryDef[unitDefID] then
		team.tech3Factories[unitID] = true
	end
	if isLongRangeDef[unitDefID] then
		team.longRangeUnits[unitID] = true
	end
	if not finished then
		return
	end
	if isTech2FactoryDef[unitDefID] then
		team.finishedTech2Factories[unitID] = true
	end
	if idleReminderKeyByDefID[unitDefID] then
		team.builders[unitID] = { idleReminderKey = idleReminderKeyByDefID[unitDefID], idleSince = false }
	end
	if isAntiAirDef[unitDefID] then
		team.antiAirUnits[unitID] = true
	end
	if isAntiNukeDef[unitDefID] then
		team.antiNukeUnits[unitID] = true
	end
end

local function getTeamName(teamID)
	local _, leaderID, _, isAI = spGetTeamInfo(teamID, false)
	if isAI then
		local _, aiName = spGetAIInfo(teamID)
		return aiName or "AI", true
	end
	return leaderID and spGetPlayerInfo(leaderID, false) or "unknown", false
end

local function watchTeam(teamID)
	local name, isAI = getTeamName(teamID)
	local team = {
		teamID = teamID,
		name = name,
		isAI = isAI,
		builders = {},
		tech2Factories = {},
		tech3Factories = {},
		finishedTech2Factories = {},
		antiAirUnits = {},
		antiNukeUnits = {},
		longRangeUnits = {},
		reminderStates = {},
		incomeHeldSince = {},
		energyNearShareSince = false,
	}
	for _, unitID in ipairs(spGetTeamUnits(teamID) or {}) do
		addUnit(team, unitID, spGetUnitDefID(unitID), isFinished(unitID))
	end
	watchedTeams[teamID] = team
end

local function watchTeams()
	watchedTeams = {}
	if not isReplayTest then
		watchTeam(spGetMyTeamID())
		return
	end
	local gaiaTeamID = spGetGaiaTeamID()
	for _, teamID in ipairs(spGetTeamList()) do
		if teamID ~= gaiaTeamID then
			watchTeam(teamID)
		end
	end
end

-- Constructors are the builders that can build a metal extractor. Rez bots, resurrection subs, minelayers and spies
-- build too, but aren't constructors in purpose.
local function buildsMetalExtractor(unitDef)
	for _, buildDefID in ipairs(unitDef.buildOptions) do
		if UnitDefs[buildDefID].extractsMetal > 0 then
			return true
		end
	end
	return false
end

local function classifyUnitDefs()
	for unitDefID, unitDef in pairs(UnitDefs) do
		local customParams = unitDef.customParams
		local techLevel = tonumber(customParams.techlevel) or 1
		-- Nano turrets build but can't move; they often wait as repair stations on purpose, so they're left out.
		if unitDef.isBuilder and unitDef.canMove and not unitDef.isFactory and buildsMetalExtractor(unitDef) then
			if customParams.iscommander then
				idleReminderKeyByDefID[unitDefID] = "commander_idle"
			else
				idleReminderKeyByDefID[unitDefID] = techLevel >= 2 and "tech_two_constructor_idle"
					or "tech_one_constructor_idle"
			end
		end
		if unitDef.isFactory and techLevel >= 2 then
			isTech2FactoryDef[unitDefID] = true
		end
		if unitDef.isFactory and techLevel >= 3 then
			isTech3FactoryDef[unitDefID] = true
		end
		if customParams.unitgroup == "aa" then
			isAntiAirDef[unitDefID] = true
		end
		for _, weapon in ipairs(unitDef.weapons) do
			local weaponDef = WeaponDefs[weapon.weaponDef]
			if weaponDef and weaponDef.interceptor and weaponDef.interceptor ~= 0 then
				isAntiNukeDef[unitDefID] = true
			end
			local isLongRange = weaponDef and weaponDef.range >= LONG_RANGE_MIN_RANGE and not weaponDef.stockpile
			if isLongRange and not unitDef.canMove then
				isLongRangeDef[unitDefID] = true
			end
		end
	end
end

local function findSoundFiles()
	local fallback
	for _, file in ipairs(FALLBACK_SOUNDS) do
		if VFS.FileExists(file) then
			fallback = file
			break
		end
	end
	-- The widget handler records the script's path before Initialize, so the folder may have any name.
	local widgetFolder = widget.whInfo and widget.whInfo.filename and widget.whInfo.filename:match("^(.*[/\\])")
	local soundFolder = (widgetFolder or DEFAULT_SOUND_FOLDER) .. "sounds/"
	local found = {}
	for _, reminder in ipairs(REMINDERS) do
		local file = soundFolder .. reminder.key .. ".wav"
		if VFS.FileExists(file) then
			soundFileByKey[reminder.key] = file
			found[#found + 1] = reminder.key
		else
			soundFileByKey[reminder.key] = fallback
			found[#found + 1] = reminder.key .. " (fallback)"
		end
	end
	spEcho("Advisor: sounds " .. table.concat(found, ", "))
end

--------------------------------------------------------------------------------
-- Conditions and announcements
--------------------------------------------------------------------------------

local function count(set)
	local total = 0
	for _ in pairs(set) do
		total = total + 1
	end
	return total
end

-- Must be called every check for each resource and threshold, so that its hold time keeps counting.
local function isIncomeHeld(team, resource, income, threshold, frame)
	local incomeHeldSince = team.incomeHeldSince
	local key = resource .. threshold
	if income >= threshold then
		incomeHeldSince[key] = incomeHeldSince[key] or frame
	else
		incomeHeldSince[key] = nil
	end
	return incomeHeldSince[key] ~= nil and frame - incomeHeldSince[key] >= INCOME_HOLD_FRAMES
end

-- Energy storage left for a big shot while the converters run and energy above the share level goes to allies.
local function getUsableEnergyStorage(team, storage, share)
	local conversionLevel = spGetTeamRulesParam(team.teamID, "mmLevel") or DEFAULT_CONVERSION_LEVEL
	return storage * math.min(conversionLevel, share or 1)
end

-- Must be called every check, so that the hold time keeps counting.
local function isEnergyNearShareHeld(team, frame)
	local current, storage, _, _, _, share = spGetTeamResources(team.teamID, "energy")
	if current and storage > 0 and current >= storage * (share - ENERGY_SHARE_MARGIN) then
		team.energyNearShareSince = team.energyNearShareSince or frame
	else
		team.energyNearShareSince = false
	end
	return team.energyNearShareSince and frame - team.energyNearShareSince >= ENERGY_HOLD_FRAMES
end

local function hasReadyAntiNuke(team)
	for unitID in pairs(team.antiNukeUnits) do
		if (spGetUnitStockpile(unitID) or 0) >= 1 then
			return true
		end
	end
	return false
end

-- Returns the set of active reminder keys, and the number of idle builders per idle reminder key.
local function evaluateConditions(team, frame)
	local idleCountByKey = {}
	local tech2BuilderCount = 0
	for unitID, builder in pairs(team.builders) do
		if (spGetUnitCommandCount(unitID) or 0) > 0 or spGetUnitIsBuilding(unitID) then
			builder.idleSince = false
		elseif not builder.idleSince then
			builder.idleSince = frame
		end
		if builder.idleSince and frame - builder.idleSince >= IDLE_FRAMES then
			idleCountByKey[builder.idleReminderKey] = (idleCountByKey[builder.idleReminderKey] or 0) + 1
		end
		if builder.idleReminderKey == "tech_two_constructor_idle" then
			tech2BuilderCount = tech2BuilderCount + 1
		end
	end

	local _, _, _, metalIncome = spGetTeamResources(team.teamID, "metal")
	metalIncome = metalIncome or 0
	local _, energyStorage, _, energyIncome, _, energyShare = spGetTeamResources(team.teamID, "energy")
	energyStorage = energyStorage or 0
	energyIncome = energyIncome or 0
	local minutes = frame / GAME_SPEED / 60
	local tech2IncomeHeld = isIncomeHeld(team, "metal", metalIncome, TECH2_METAL_PER_SECOND, frame)
	local tech3IncomeHeld = isIncomeHeld(team, "metal", metalIncome, TECH3_METAL_PER_SECOND, frame)
	local antiNukeIncomeHeld = isIncomeHeld(team, "metal", metalIncome, ANTINUKE_METAL_PER_SECOND, frame)
	local lrpcMetalHeld = isIncomeHeld(team, "metal", metalIncome, LRPC_METAL_PER_SECOND, frame)
	local lrpcEnergyHeld = isIncomeHeld(team, "energy", energyIncome, LRPC_ENERGY_PER_SECOND, frame)
	local energyNearShareHeld = isEnergyNearShareHeld(team, frame)

	local hasLongRange = next(team.longRangeUnits) ~= nil
	local lrpcDue = tech2BuilderCount > 0 and not hasLongRange and lrpcMetalHeld and lrpcEnergyHeld
	local storageHoldsShot = getUsableEnergyStorage(team, energyStorage, energyShare) >= LRPC_ENERGY_PER_SHOT
	local noEnergyStorage = energyStorage < ENERGY_STORAGE_MIN

	local commanderMuted = COMMANDER_MUTE_TECH2_BUILDERS ~= nil and tech2BuilderCount >= COMMANDER_MUTE_TECH2_BUILDERS

	local active = {
		tech_one_constructor_idle = idleCountByKey.tech_one_constructor_idle ~= nil,
		tech_two_constructor_idle = idleCountByKey.tech_two_constructor_idle ~= nil,
		commander_idle = idleCountByKey.commander_idle ~= nil and not commanderMuted,
		consider_tech_two = next(team.tech2Factories) == nil
			and (tech2IncomeHeld or (TECH2_MINUTES ~= nil and minutes >= TECH2_MINUTES)),
		consider_tech_three = next(team.finishedTech2Factories) ~= nil
			and next(team.tech3Factories) == nil
			and tech3IncomeHeld,
		build_anti_air = minutes >= ANTIAIR_MINUTES and count(team.antiAirUnits) < ANTIAIR_MIN_COUNT,
		build_anti_nuke = not hasReadyAntiNuke(team) and (minutes >= ANTINUKE_MINUTES or antiNukeIncomeHeld),
		consider_long_range_plasma_cannon = lrpcDue and storageHoldsShot,
		build_energy_storage = (noEnergyStorage and (minutes >= ENERGY_STORAGE_MINUTES or energyNearShareHeld))
			or ((lrpcDue or hasLongRange) and not storageHoldsShot),
		consider_energy_converters = energyNearShareHeld and not noEnergyStorage,
	}
	return active, idleCountByKey
end

local function updateReminderStates(team, active, frame)
	for _, reminder in ipairs(REMINDERS) do
		if not active[reminder.key] then
			team.reminderStates[reminder.key] = nil -- resolved: starts fresh when it comes back
		elseif not team.reminderStates[reminder.key] then
			team.reminderStates[reminder.key] = { activeSince = frame }
		end
	end
end

-- The active reminder furthest past its interval; one that never played counts from when it became active.
local function pickMostOverdue(team, frame)
	local best, bestOverdue
	for _, reminder in ipairs(REMINDERS) do
		local state = team.reminderStates[reminder.key]
		if state then
			local overdue
			if state.lastPlayedFrame then
				overdue = frame - state.lastPlayedFrame - reminder.interval * GAME_SPEED
			else
				overdue = frame - state.activeSince
			end
			local isBetter = not best
				or overdue > bestOverdue
				or (overdue == bestOverdue and reminder.priority > best.priority)
			if overdue >= 0 and isBetter then
				best, bestOverdue = reminder, overdue
			end
		end
	end
	return best
end

local function announce(team, reminder, idleCount, frame)
	if isReplayTest then
		-- The name goes last: it may contain spaces.
		spEcho(
			string.format(
				"[reminder] f=%d team=%d ai=%d key=%s idle=%d name=%s",
				frame,
				team.teamID,
				team.isAI and 1 or 0,
				reminder.key,
				idleCount or 0,
				team.name
			)
		)
		return
	end
	if soundFileByKey[reminder.key] then
		spPlaySoundFile(soundFileByKey[reminder.key], VOLUME, "ui")
	end
	local text = reminder.text
	if idleCount and idleCount > 1 then
		text = text .. " (" .. idleCount .. ")"
	end
	spEcho("Reminder: " .. text)
end

local function updateTeam(team, frame)
	local active, idleCountByKey = evaluateConditions(team, frame)
	updateReminderStates(team, active, frame)
	if frame % ANNOUNCEMENT_FRAMES ~= 0 then
		return
	end
	local reminder = pickMostOverdue(team, frame)
	if reminder then
		team.reminderStates[reminder.key].lastPlayedFrame = frame
		announce(team, reminder, idleCountByKey[reminder.key], frame)
	end
end

--------------------------------------------------------------------------------
-- Call-ins
--------------------------------------------------------------------------------

function widget:Initialize()
	isReplayTest = spIsReplay()
	-- A spectator of a live game has no team of their own to watch.
	if spGetSpectatingState() and not isReplayTest then
		widgetHandler:RemoveWidget()
		return
	end
	classifyUnitDefs()
	findSoundFiles()
	watchTeams()
end

function widget:PlayerChanged()
	if isReplayTest then
		return
	end
	if spGetSpectatingState() then
		widgetHandler:RemoveWidget()
		return
	end
	if not watchedTeams[spGetMyTeamID()] then
		watchTeams()
	end
end

function widget:UnitCreated(unitID, unitDefID, teamID)
	local team = watchedTeams[teamID]
	if team then
		addUnit(team, unitID, unitDefID, false)
	end
end

function widget:UnitFinished(unitID, unitDefID, teamID)
	local team = watchedTeams[teamID]
	if team then
		addUnit(team, unitID, unitDefID, true)
	end
end

function widget:UnitGiven(unitID, unitDefID, newTeamID)
	local team = watchedTeams[newTeamID]
	if team then
		addUnit(team, unitID, unitDefID, isFinished(unitID))
	end
end

function widget:UnitTaken(unitID, _, oldTeamID)
	local team = watchedTeams[oldTeamID]
	if team then
		removeUnit(team, unitID)
	end
end

function widget:UnitDestroyed(unitID, _, teamID)
	local team = watchedTeams[teamID]
	if team then
		removeUnit(team, unitID)
	end
end

function widget:GameFrame(frame)
	if frame % CHECK_FRAMES ~= 0 then
		return
	end
	for _, team in pairs(watchedTeams) do
		updateTeam(team, frame)
	end
end
