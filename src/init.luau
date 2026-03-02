--!strict
--!optimize 2

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Packages = script.Parent :: Folder

local Promise = require(Packages:WaitForChild("Promise")) :: any
local LemonSignal = require(Packages:WaitForChild("LemonSignal")) :: any
local Trove = require(Packages:WaitForChild("Trove")) :: any
local Net = require(script:WaitForChild("Net")) :: any

local Struktura = {}

export type ClientMeta = { Signals: {string}, Methods: {string} }
export type Connection = { Disconnect: (self: Connection) -> () }
export type ClientSignal = { Connect: (self: ClientSignal, callback: (...any) -> ()) -> Connection }
export type ServerSignal = {
	Fire: (self: ServerSignal, target: Player | string | {string} | "All" | { Except: string } | nil, ...any) -> (),
	FireAll: (self: ServerSignal, ...any) -> (),
	FireList: (self: ServerSignal, list: {string}, ...any) -> (),
	FireExcept: (self: ServerSignal, except: string, ...any) -> (),
}
export type ServiceProxy = { [string]: any }
export type Settings = { ServicePromises: boolean? }

type Success = boolean

local isServer = RunService:IsServer()
local isStudio = RunService:IsStudio()

local cleaner = Trove.new()

local started = false
local starting = false
local netStarted = false

local signalFlag = newproxy(false)

local controllers: {[string]: any} = {}
local controllerCache: {[string]: any} = {}
local serviceCache: {[string]: ServiceProxy} = {}
local modules: {[string]: any} = {}

local boundLifecycles: {[string]: boolean} = {}

local bindToCloseSignal = if isServer then LemonSignal.new() else nil
local playerAddedSignal = LemonSignal.new()
local playerRemovingSignal = LemonSignal.new()
local characterAddedSignal = LemonSignal.new()

local customEvents: {[string]: any} = {
	["BindToClose"] = bindToCloseSignal,
	["PlayerAdded"] = playerAddedSignal,
	["PlayerRemoving"] = playerRemovingSignal,
	["CharacterAdded"] = characterAddedSignal,
}

local initSettings = {
	ServicePromises = true,
}

local playerCharConn: {[string]: RBXScriptConnection} = {}

Struktura.Net = Net

local function ensureNetStarted()
	if netStarted then
		return
	end
	netStarted = true
	Struktura.Net:_Start()
end

local function feed(moduleScript: ModuleScript): Success
	if started then
		if isStudio then
			warn("[Struktura] Cannot feed Modules when already Started.")
		end
		return false
	end

	local ok, loaded = pcall(require, moduleScript)
	if not ok then
		error(`[Struktura] Found error while feeding {moduleScript.Name} Module: {tostring(loaded)}`)
	end

	if typeof(loaded) ~= "table" then
		if isStudio then
			warn(`[Struktura] {moduleScript.Name} Module does not return a table. This has not been fed.`)
		end
		return true
	end

	local key = (loaded.Name or moduleScript.Name)
	if loaded.Type == "Controller" then
		controllers[key] = loaded
	else
		modules[key] = loaded
	end

	return true
end

local function isPromiseLike(value: any): boolean
	return type(value) == "table" and type(value.andThen) == "function" and type(value.catch) == "function"
end

local function toPromise(value: any)
	if value == nil then
		return Promise.resolve()
	end
	if isPromiseLike(value) then
		return value
	end
	return Promise.resolve(value)
end

local function bindLifecycle(name: string, signal: any)
	if not signal then
		return
	end
	if boundLifecycles[name] then
		return
	end
	boundLifecycles[name] = true

	local ok, conn = pcall(function()
		return signal:Connect(function(...)
			local set = if isServer then modules else controllers
			for _, module in pairs(set) do
				local lifecycle = module[`On{name}`]
				if lifecycle and typeof(lifecycle) == "function" then
					task.spawn(lifecycle, module, ...)
				end
			end
		end)
	end)

	if ok and conn then
		cleaner:Add(conn)
	elseif isStudio then
		warn(`[Struktura] Failed to bind lifecycle "{name}".`)
	end
end

local function createServerSignal(netName: string, eventName: string): ServerSignal
	local obj: any = {}

	function obj:Fire(target: any, ...)
		Struktura.Net:Fire(target, netName, eventName, ...)
	end

	function obj:FireAll(...)
		Struktura.Net:Fire("All", netName, eventName, ...)
	end

	function obj:FireList(list: {string}, ...)
		Struktura.Net:Fire(list, netName, eventName, ...)
	end

	function obj:FireExcept(except: string, ...)
		Struktura.Net:Fire({ Except = except }, netName, eventName, ...)
	end

	return obj :: ServerSignal
end

local function setupClientSurface()
	for serviceKey, service in pairs(modules) do
		local client = rawget(service, "Client")
		if typeof(client) ~= "table" then
			continue
		end

		local signals: {string} = {}
		local methods: {string} = {}

		for name, value in pairs(client) do
			if value == signalFlag then
				table.insert(signals, name)
				client[name] = createServerSignal(serviceKey, name)
			elseif typeof(value) == "function" then
				table.insert(methods, name)
				Struktura.Net:Handle(serviceKey, name, function(player: Player, ...)
					return value(client, player, ...)
				end)
			end
		end

		Struktura.Net:Handle(serviceKey, "__struktura_meta", function(_player: Player)
			local meta: ClientMeta = { Signals = signals, Methods = methods }
			return meta
		end)
	end
end

local function onCharacterAdded(player: Player, character: Model)
	characterAddedSignal:Fire(player, character)
end

local function onPlayerAdded(player: Player)
	playerAddedSignal:Fire(player)

	local key = player.Name
	local existing = playerCharConn[key]
	if existing then
		existing:Disconnect()
		playerCharConn[key] = nil
	end

	playerCharConn[key] = player.CharacterAdded:Connect(function(character: Model)
		onCharacterAdded(player, character)
	end)

	if player.Character then
		task.spawn(onCharacterAdded, player, player.Character)
	end
end

local function onPlayerRemoving(player: Player)
	playerRemovingSignal:Fire(player)

	local key = player.Name
	local conn = playerCharConn[key]
	if conn then
		conn:Disconnect()
		playerCharConn[key] = nil
	end
end

function Struktura.Configure(options: Settings?)
	if not options then
		return
	end
	if options.ServicePromises ~= nil then
		initSettings.ServicePromises = options.ServicePromises
	end
end

function Struktura.CreateLifecycle(name: string, signal: any)
	if customEvents[name] then
		return Promise.reject("Lifecycle already exists.")
	end

	customEvents[name] = signal
	if started or starting then
		bindLifecycle(name, signal)
	end

	return Promise.resolve()
end

function Struktura.CreateSignal(): any
	if isServer then
		return signalFlag
	end
	warn("[Struktura] CreateSignal can only be called on Server.")
	return nil
end

function Struktura.OnStart()
	if started then
		return Promise.resolve()
	end
	return Promise.new(function(resolve)
		repeat task.wait() until started
		resolve()
	end)
end

function Struktura.Initialize(container: Folder, deep: boolean?)
	if started then
		if isStudio then
			warn("[Struktura] Cannot Initialize when already Started.")
		end
		return Promise.reject("[Struktura] Cannot Initialize when already Started.")
	end

	local startClock: number = os.clock()
	local isDeep: boolean = if deep ~= nil then deep else false

	local list = if isDeep then container:GetDescendants() else container:GetChildren()
	for _, child: Instance in ipairs(list) do
		if child:IsA("ModuleScript") then
			feed(child :: ModuleScript)
		end
	end

	return Promise.resolve(`[Struktura] Initialization Completed in: {os.clock() - startClock} s`)
end

function Struktura.GetController(name: string)
	if isServer then
		if isStudio then
			warn("[Struktura] GetController can only be called on the client.")
		end
		return nil
	end

	local cached = controllerCache[name]
	if cached then
		return cached
	end

	local ctrl = controllers[name]
	if not ctrl then
		if isStudio then
			warn(("[Struktura] Controller '%s' not found. Did you Initialize() controllers?"):format(name))
		end
		return nil
	end

	controllerCache[name] = ctrl
	return ctrl
end

function Struktura.GetService(name: string): any
	if isServer then
		return modules[name]
	end

	local cached = serviceCache[name]
	if cached then
		return cached
	end

	ensureNetStarted()

	local ok, metaAny = Struktura.Net:Request(name, "__struktura_meta"):await()
	if not ok then
		error(`[Struktura] Failed to fetch service meta for "{name}".`)
	end

	local meta = metaAny :: ClientMeta
	local proxy: any = {}

	if type(meta) == "table" and type(meta.Signals) == "table" then
		for _, signalName in ipairs(meta.Signals) do
			proxy[signalName] = {
				Connect = function(_self: any, cb: (...any) -> ())
					return Struktura.Net:On(name, signalName, cb)
				end,
			} :: ClientSignal
		end
	end

	setmetatable(proxy, {
		__index = function(_t, methodName: any)
			return function(_self, ...)
				local req = Struktura.Net:Request(name, tostring(methodName), ...)
				if initSettings.ServicePromises then
					return req
				end
				local ok2, result = req:await()
				if not ok2 then
					error(result)
				end
				return result
			end
		end,
	})

	serviceCache[name] = proxy :: ServiceProxy
	return proxy
end

function Struktura.Start()
	if started then
		return Promise.resolve()
	end

	starting = true

	if not isServer then
		if workspace.StreamingEnabled and isStudio then
			warn("Some things may not function as expected due to StreamingEnabled.")
		end

		if not script:GetAttribute("ServerReady") then
			while not script:GetAttribute("ServerReady") do
				task.wait()
			end
		end
	end

	ensureNetStarted()

	for name, signal in pairs(customEvents) do
		bindLifecycle(name, signal)
	end

	cleaner:Connect(Players.PlayerAdded, onPlayerAdded)
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(onPlayerAdded, player)
	end
	cleaner:Connect(Players.PlayerRemoving, onPlayerRemoving)

	if isServer then
		game:BindToClose(function(reason: any)
			if bindToCloseSignal then
				bindToCloseSignal:Fire(reason)
			end
			cleaner:Destroy()
		end)
	end

	local startClock = os.clock()
	local set = if isServer then modules else controllers

	local initPromises = {}
	for _, module in pairs(set) do
		local initFn = module.Init
		if typeof(initFn) == "function" then
			table.insert(initPromises, Promise.try(initFn, module):andThen(toPromise))
		end
	end

	return Promise.all(initPromises)
		:andThen(function()
			if isServer then
				setupClientSurface()
			end

			started = true
			starting = false
			if isServer then
				script:SetAttribute("ServerReady", true)
			end

			local msg = `[Struktura] Started in: {os.clock() - startClock} s`

			task.spawn(function()
				local startPromises = {}
				for _, module in pairs(set) do
					local startFn = module.Start
					if typeof(startFn) == "function" then
						table.insert(startPromises, Promise.try(startFn, module):andThen(toPromise))
					end
				end

				Promise.all(startPromises):catch(function(err: any)
					warn("[Struktura] Module Start error:", err)
				end)
			end)

			return msg
		end)
end

return Struktura