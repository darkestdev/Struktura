--!strict
--!optimize 2

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

export type PlayerName = string
export type Target = Player | PlayerName | { PlayerName } | "All" | { Except: PlayerName } | nil

export type ClientMeta = {
	Signals: { string },
	Methods: { string },
}

export type Connection = {
	Disconnect: (self: Connection) -> (),
}

export type ClientSignal<Args...> = {
	Connect: (self: ClientSignal<Args...>, callback: (Args...) -> ()) -> Connection,
}

export type ServerSignal<Args...> = {
	Fire: (self: ServerSignal<Args...>, target: Target, Args...) -> (),
	FireAll: (self: ServerSignal<Args...>, Args...) -> (),
	FireList: (self: ServerSignal<Args...>, list: { PlayerName }, Args...) -> (),
	FireExcept: (self: ServerSignal<Args...>, except: PlayerName, Args...) -> (),
}

export type Settings = {
	ServicePromises: boolean?,
}

type PromiseLike = {
	andThen: (self: PromiseLike, onResolve: ((...any) -> ...any)?, onReject: ((...any) -> ...any)?) -> PromiseLike,
	catch: (self: PromiseLike, onReject: (...any) -> ...any) -> PromiseLike,
	await: (self: PromiseLike) -> (boolean, ...any),
}

type PromiseStatic = {
	new: (executor: (resolve: (...any) -> (), reject: (...any) -> ()) -> ()) -> PromiseLike,
	resolve: (...any) -> PromiseLike,
	reject: (...any) -> PromiseLike,
	try: (fn: (...any) -> ...any, ...any) -> PromiseLike,
	all: ({ PromiseLike }) -> PromiseLike,
}

type LemonSignalLike = {
	Connect: (self: LemonSignalLike, callback: (...any) -> ()) -> Connection,
	Fire: (self: LemonSignalLike, ...any) -> (),
}

type LemonSignalStatic = {
	new: () -> LemonSignalLike,
}

type TroveLike = {
	Add: (self: TroveLike, item: any) -> any,
	Connect: (self: TroveLike, signal: RBXScriptSignal, callback: (...any) -> ()) -> RBXScriptConnection,
	Destroy: (self: TroveLike) -> (),
}

type TroveStatic = {
	new: () -> TroveLike,
}

type EventSignal = {
	Connect: (self: EventSignal, callback: (...any) -> ()) -> Connection,
}

type FrameworkModule = {
	Name: string?,
	Type: string?,
	Init: ((self: any) -> any)?,
	Start: ((self: any) -> any)?,
	[string]: any,
}

local Packages = script.Parent :: Folder
local Promise = require(Packages:WaitForChild("Promise")) :: PromiseStatic
local LemonSignal = require(Packages:WaitForChild("LemonSignal")) :: LemonSignalStatic
local Trove = require(Packages:WaitForChild("Trove")) :: TroveStatic
local Net = require(script:WaitForChild("Net"))

local Struktura = {}
Struktura.Net = Net

local isServer = RunService:IsServer()
local isStudio = RunService:IsStudio()

local cleaner = Trove.new()
local started = false
local starting = false
local netStarted = false

local signalFlag = newproxy(false)

local controllers: { [string]: FrameworkModule } = {}
local controllerCache: { [string]: any } = {}
local modules: { [string]: FrameworkModule } = {}
local serviceCache: { [string]: any } = {}
local boundLifecycles: { [string]: boolean } = {}

local bindToCloseSignal = if isServer then LemonSignal.new() else nil
local playerAddedSignal = LemonSignal.new()
local playerRemovingSignal = LemonSignal.new()
local characterAddedSignal = LemonSignal.new()

local customEvents: { [string]: EventSignal? } = {
	BindToClose = bindToCloseSignal,
	PlayerAdded = playerAddedSignal,
	PlayerRemoving = playerRemovingSignal,
	CharacterAdded = characterAddedSignal,
}

local initSettings: Settings = {
	ServicePromises = true,
}

local playerCharConn: { [string]: RBXScriptConnection } = {}

local function ensureNetStarted()
	if netStarted then
		return
	end
	netStarted = true
	Struktura.Net:_Start()
end

local function isPromiseLike(value: any): boolean
	return type(value) == "table"
		and type(value.andThen) == "function"
		and type(value.catch) == "function"
		and type(value.await) == "function"
end

local function toPromise(value: any): PromiseLike
	if value == nil then
		return Promise.resolve()
	end
	if isPromiseLike(value) then
		return value
	end
	return Promise.resolve(value)
end

local function feed(moduleScript: ModuleScript): boolean
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
			warn(`[Struktura] {moduleScript.Name} Module does not return a table.\nThis has not been fed.`)
		end
		return true
	end

	local tbl = loaded :: FrameworkModule
	local key = tbl.Name or moduleScript.Name

	if tbl.Type == "Controller" then
		controllers[key] = tbl
	else
		modules[key] = tbl
	end

	return true
end

local function bindLifecycle(name: string, signal: EventSignal?)
	if not signal or boundLifecycles[name] then
		return
	end

	boundLifecycles[name] = true
	local methodName = "On" .. name
	local targetSet = if isServer then modules else controllers

	local ok, conn = pcall(function()
		return signal:Connect(function(...)
			for _, module in pairs(targetSet) do
				local method = module[methodName]
				if type(method) == "function" then
					task.spawn(method, module, ...)
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

local function createServerSignal(netName: string, eventName: string): ServerSignal<...any>
	local obj: any = {}

	function obj:Fire(target: Target, ...)
		Struktura.Net:Fire(target, netName, eventName, ...)
	end

	function obj:FireAll(...)
		Struktura.Net:Fire("All", netName, eventName, ...)
	end

	function obj:FireList(list: { PlayerName }, ...)
		Struktura.Net:Fire(list, netName, eventName, ...)
	end

	function obj:FireExcept(except: PlayerName, ...)
		Struktura.Net:Fire({ Except = except }, netName, eventName, ...)
	end

	return obj
end

local function setupClientSurface()
	for serviceKey, service in pairs(modules) do
		local clientTable = rawget(service, "Client")
		if typeof(clientTable) ~= "table" then
			continue
		end

		local signals: { string } = {}
		local methods: { string } = {}

		for name, value in pairs(clientTable) do
			if value == signalFlag then
				table.insert(signals, name)
				clientTable[name] = createServerSignal(serviceKey, name)
			elseif typeof(value) == "function" then
				table.insert(methods, name)
				Net:Handle(serviceKey, name, function(player: Player, ...)
					return value(clientTable, player, ...)
				end)
			end
		end

		Net:Handle(serviceKey, "__struktura_meta", function(_player: Player)
			return {
				Signals = signals,
				Methods = methods,
			}
		end)
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

function Struktura.CreateLifecycle(name: string, signal: EventSignal)
	if customEvents[name] ~= nil then
		return Promise.reject("Lifecycle already exists.")
	end

	customEvents[name] = signal

	if started or starting then
		bindLifecycle(name, signal)
	end

	return Promise.resolve()
end

function Struktura.CreateSignal()
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
		repeat
			task.wait()
		until started
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

	local startClock = os.clock()
	local list = if deep then container:GetDescendants() else container:GetChildren()

	for _, child in ipairs(list) do
		if child:IsA("ModuleScript") then
			feed(child)
		end
	end

	return Promise.resolve(`[Struktura] Initialization Completed in: {os.clock() - startClock} s`)
end

function Struktura.GetController<T>(name: string): T?
	if isServer then
		if isStudio then
			warn("[Struktura] GetController can only be called on the client.")
		end
		return nil
	end

	local cached = controllerCache[name]
	if cached ~= nil then
		return cached :: T
	end

	local controller = controllers[name]
	if not controller then
		if isStudio then
			warn(("[Struktura] Controller '%s' not found.\nDid you Initialize() controllers?"):format(name))
		end
		return nil
	end

	controllerCache[name] = controller
	return controller :: any
end

function Struktura.GetService<T>(name: string): T
	if isServer then
		return (modules[name] :: any) :: T
	end

	local cached = serviceCache[name]
	if cached ~= nil then
		return cached :: T
	end

	ensureNetStarted()

	local ok, meta = Net:Request(name, "__struktura_meta"):await()
	if not ok then
		error(`[Struktura] Failed to fetch service meta for "{name}".`)
	end

	local proxy: any = {}

	if type(meta) == "table" and type(meta.Signals) == "table" then
		for _, signalName in ipairs(meta.Signals) do
			local signalObj: any = {}

			function signalObj:Connect(callback: (...any) -> ())
				return Net:On(name, signalName, callback)
			end

			proxy[signalName] = signalObj
		end
	end

	setmetatable(proxy, {
		__index = function(t, key)
			local methodName = tostring(key)

			local fn = function(_self, ...)
				local request = Net:Request(name, methodName, ...)
				if initSettings.ServicePromises then
					return request
				end

				local ok2, result = request:await()
				if not ok2 then
					error(result)
				end
				return result
			end

			rawset(t, methodName, fn)
			return fn
		end,
	})

	serviceCache[name] = proxy
	return proxy :: T
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

	cleaner:Connect(Players.PlayerAdded, function(player)
		playerAddedSignal:Fire(player)

		local key = player.Name
		local existing = playerCharConn[key]
		if existing then
			existing:Disconnect()
			playerCharConn[key] = nil
		end

		playerCharConn[key] = player.CharacterAdded:Connect(function(character)
			characterAddedSignal:Fire(player, character)
		end)

		if player.Character then
			task.spawn(function()
				characterAddedSignal:Fire(player, player.Character)
			end)
		end
	end)

	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(function()
			playerAddedSignal:Fire(player)

			playerCharConn[player.Name] = player.CharacterAdded:Connect(function(character)
				characterAddedSignal:Fire(player, character)
			end)

			if player.Character then
				characterAddedSignal:Fire(player, player.Character)
			end
		end)
	end

	cleaner:Connect(Players.PlayerRemoving, function(player)
		playerRemovingSignal:Fire(player)

		local conn = playerCharConn[player.Name]
		if conn then
			conn:Disconnect()
			playerCharConn[player.Name] = nil
		end
	end)

	if isServer then
		game:BindToClose(function(reason)
			if bindToCloseSignal then
				bindToCloseSignal:Fire(reason)
			end
			cleaner:Destroy()
		end)
	end

	local set = if isServer then modules else controllers
	local initPromises: { PromiseLike } = {}

	for _, module in pairs(set) do
		local initFn = module.Init
		if type(initFn) == "function" then
			table.insert(initPromises, Promise.try(initFn, module):andThen(toPromise))
		end
	end

	local startClock = os.clock()

	return Promise.all(initPromises):andThen(function()
		if isServer then
			setupClientSurface()
		end

		started = true
		starting = false

		if isServer then
			script:SetAttribute("ServerReady", true)
		end

		task.spawn(function()
			local startPromises: { PromiseLike } = {}

			for _, module in pairs(set) do
				local startFn = module.Start
				if type(startFn) == "function" then
					table.insert(startPromises, Promise.try(startFn, module):andThen(toPromise))
				end
			end

			Promise.all(startPromises):catch(function(err)
				warn("[Struktura] Module Start error:", err)
			end)
		end)

		return `[Struktura] Started in: {os.clock() - startClock} s`
	end)
end

return Struktura