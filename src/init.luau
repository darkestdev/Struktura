--!strict
--!optimize 2

--[=[
	@class Struktura
	Struktura is a lightweight **Services / Controllers** framework for Roblox, with a small networking surface.

	## How networking works (VoidSentry + Blink)
	- **Blink** generates the low-level networking modules used by `Struktura.Net` (binary packets over buffers).
	- **VoidSentry.Dynamic** serializes/deserializes Lua values into a `buffer` that becomes the packet `Payload`.
	- Struktura builds a friendly API on top: services expose a `Client` surface (methods + signals), and controllers consume it.

	## Server: Services, client surface, and signals
	A **Service** is any module that does **not** set `Type = "Controller"`.

	If a service defines a `Client` table:
	- **Functions** inside `Client` become server RPC handlers callable from the client via [Struktura.GetService].
	- Fields set to [Struktura.CreateSignal] become server → client signals (exposed on the client proxy as `:Connect(...)`).

	For an example of a Service, you can use this:

	```lua
	local Struktura = require(ReplicatedStorage.Packages.Struktura)

	local MyService = {
		Name = "MyService"
		Client = {
			DataChanged = Struktura.CreateSignal()
		}
	}

	function MyService.Client:GetData(player: Player...)
		local DataService = Struktura.GetService("DataService")
		return DataService:GetPlayerData(player)
	end

	return MyService
	```

	On the client, use [Struktura.GetService] to access these methods and signals.

	In this example, [MyService:GetData()] would be accessible on the client, as well as [MyService.DataChanged].

	## Client: Controllers
	A **Controller** is any module table with `Type = "Controller"`.

	Controllers usually:
	- call [Struktura.GetService] to talk to services
	- optionally call [Struktura.GetController] to talk to other controllers

	Example Controller:

	```lua
	local Struktura = require(ReplicatedStorage.Packages.Struktura)

	local DataController = {
		Name = "DataController",
		Type = "Controller",
	}

	function DataController:Init()
		self.MyService = Struktura.GetService("MyService")
	end

	function DataController:Start()
		self.MyService.DataChanged:Connect(function(...)
			print("DataChanged:", ...)
		end)

		self.MyService:GetData():andThen(function(data)
			print("GetData result:", data)
		end)
	end

	return DataController
	```

	## Boot
	1. Call [Struktura.Initialize] to load/register modules.
	2. Call [Struktura.Start] to run `Init`, surface service `Client` APIs, then run `Start`.
]=]

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

--[=[
	@prop Net any
	@within Struktura
	Low-level networking implementation.

	Most projects should not interact with this directly. Prefer:
	- [Struktura.GetService] (client) / [Struktura.GetService] (server)
	- service `Client` methods
	- service `Client` signals created via [Struktura.CreateSignal]
]=]
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

--[=[
	@within Struktura
	Configure Struktura runtime options (call before [Struktura.Start]).

	Currently supported:
	- `ServicePromises` (default `true`): when `true`, client service method calls return a Promise-like object.
	  When `false`, client service method calls synchronously `:await()` and return the result (this yields).
]=]
function Struktura.Configure(options: Settings?)
	if not options then
		return
	end

	if options.ServicePromises ~= nil then
		initSettings.ServicePromises = options.ServicePromises
	end
end

--[=[
	@within Struktura
	Create and (optionally) bind a custom lifecycle event.

	Modules can receive this lifecycle by defining `On<LifecycleName>(...)`.
	If Struktura has already started (or is starting), the lifecycle is bound immediately.

	@return PromiseLike -- Rejects if the lifecycle name already exists.
]=]
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

--[=[
	@within Struktura
	@server
	Create a **signal marker** for use inside a service's `Client` table.

	At startup, Struktura converts these markers into server signal objects with:
	- `:Fire(target, ...)`
	- `:FireAll(...)`
	- `:FireList(list, ...)`
	- `:FireExcept(exceptName, ...)`

	On the **client**, the same field appears as a signal with `:Connect(callback)` on the proxy returned by [Struktura.GetService].
]=]
function Struktura.CreateSignal()
	if isServer then
		return signalFlag
	end
	warn("[Struktura] CreateSignal can only be called on Server.")
	return nil
end

--[=[
	@within Struktura
	@yields
	Returns a Promise that resolves once Struktura has finished starting.
]=]
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

--[=[
	@within Struktura
	Load/register modules from a container folder.

	- If `deep` is truthy, Struktura scans all descendants; otherwise only direct children.
	- Modules returning a table are registered as either:
	  - **Controller** (client): table has `Type == "Controller"`
	  - **Service** (server): everything else

	@return PromiseLike -- Resolves with a timing string.
]=]
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

--[=[
	@within Struktura
	@client
	Get a previously-initialized controller by name.

	Controllers are registered during [Struktura.Initialize]. Names come from the table's `Name` field, or fall back to the ModuleScript name.
]=]
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

--[=[
	@within Struktura
	@server
	@client
	@yields
	Get a service by name.

	- **Server:** returns the raw service table loaded during [Struktura.Initialize].
	- **Client:** returns a cached **proxy** built from server metadata.

	Client proxy behavior:
	- Signals become objects with `:Connect(callback)`.
	- Any method call `Service:MethodName(...)` performs a request to the server.

	Use [Struktura.Configure] to control whether client method calls return a Promise (`ServicePromises = true`) or yield and return directly (`ServicePromises = false`).
]=]
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

--[=[
	@within Struktura
	@server
	@client
	@yields
	Start Struktura.

	What this does:
	1. Ensures networking is started.
	2. Binds built-in and custom lifecycles.
	3. Runs `Init` on every loaded module (services on server / controllers on client).
	4. **Server only:** surfaces service `Client` APIs (signals + RPC handlers).
	5. Marks Struktura as started, then runs `Start` for each module.

	On the client, Struktura waits for the server to set the `ServerReady` attribute before continuing.
]=]
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