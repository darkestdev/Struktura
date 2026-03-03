--!strict
--!optimize 2

--- @class Struktura
--- A lightweight services/controllers framework with a small networking surface.
---
--- Struktura is designed around two module "roles":
---
--- - **Services** (server): any module that does *not* set `Type == "Controller"`
--- - **Controllers** (client): modules that set `Type == "Controller"`
---
--- Typical boot flow:
---
--- ```lua
--- local Struktura = require(ReplicatedStorage.Packages.Struktura)
---
--- -- Server
--- Struktura.Initialize(ServerScriptService.Services, true)
--- Struktura.Start():catch(warn)
---
--- -- Client
--- Struktura.Initialize(Players.LocalPlayer.PlayerScripts.Controllers, true)
--- Struktura.Start():catch(warn)
--- ```
---
--- ## Lifecycle
--- Modules may optionally implement `Init` (runs before Start resolves) and `Start` (runs after).
---
--- Struktura also forwards a small set of lifecycle events to modules as `On<EventName>` methods:
---
--- - `OnPlayerAdded(player)`
--- - `OnPlayerRemoving(player)`
--- - `OnCharacterAdded(player, character)`
--- - `OnBindToClose(reason)` *(server only)*
---
--- You can define your own lifecycle events with [Struktura.CreateLifecycle].
---
--- ## Service client surface
--- Services can expose a `Client` table. Functions inside `Client` become RPC handlers callable from the client.
---
--- To expose server → client signals, assign a field to the marker returned by [Struktura.CreateSignal]:
---
--- ```lua
--- local Struktura = require(ReplicatedStorage.Packages.Struktura)
---
--- local MyService = { Name = "MyService" }
--- MyService.Client = {
---     DataChanged = Struktura.CreateSignal(),
---     GetData = function(self, player) return {} end,
--- }
--- return MyService
--- ```
---
--- On the client, use [Struktura.GetService] to access these methods and signals.

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

--- @type PlayerName string
--- @within Struktura
--- Convenience alias for `Player.Name` when using the framework APIs.

export type PlayerName = string
--- @type Target Player | PlayerName | { PlayerName } | "All" | { Except: PlayerName } | nil
--- @within Struktura
--- The set of supported target formats for server → client signals.
---
--- - `Player`: fire to a specific player
--- - `PlayerName` / `{ PlayerName }`: fire to one or more players by name
--- - `"All"`: fire to every player
--- - `{ Except = PlayerName }`: fire to everyone except one player name
--- - `nil`: an implementation-defined default (see `Net`)

export type Target = Player | PlayerName | { PlayerName } | "All" | { Except: PlayerName } | nil

--- @interface ClientMeta
--- @within Struktura
--- .Signals {string} -- Signal names exposed on a service's `Client` table
--- .Methods {string} -- Method names exposed on a service's `Client` table
---
--- Metadata returned by the internal `__struktura_meta` request. This is used to build
--- client-side service proxies in [Struktura.GetService].

export type ClientMeta = {
	Signals: { string },
	Methods: { string },
}

--- @interface Connection
--- @within Struktura
--- .Disconnect (self: Connection) -> () -- Disconnects the connection
---
--- Minimal connection interface returned by Struktura signals.

export type Connection = {
	Disconnect: (self: Connection) -> (),
}

--- @interface ClientSignal
--- @within Struktura
--- .Connect (self: ClientSignal<Args...>, callback: (Args...) -> ()) -> Connection
---
--- A client-side signal wrapper. You typically obtain these from [Struktura.GetService].

export type ClientSignal<Args...> = {
	Connect: (self: ClientSignal<Args...>, callback: (Args...) -> ()) -> Connection,
}

--- @interface ServerSignal
--- @within Struktura
--- .Fire (self: ServerSignal<Args...>, target: Target, Args...) -> ()
--- .FireAll (self: ServerSignal<Args...>, Args...) -> ()
--- .FireList (self: ServerSignal<Args...>, list: {PlayerName}, Args...) -> ()
--- .FireExcept (self: ServerSignal<Args...>, except: PlayerName, Args...) -> ()
---
--- A server-side signal wrapper that routes through `Struktura.Net`.
--- You create these indirectly by putting [Struktura.CreateSignal] markers in a service's `Client` table.

export type ServerSignal<Args...> = {
	Fire: (self: ServerSignal<Args...>, target: Target, Args...) -> (),
	FireAll: (self: ServerSignal<Args...>, Args...) -> (),
	FireList: (self: ServerSignal<Args...>, list: { PlayerName }, Args...) -> (),
	FireExcept: (self: ServerSignal<Args...>, except: PlayerName, Args...) -> (),
}

--- @interface Settings
--- @within Struktura
--- .ServicePromises boolean? -- If true, client service method calls return a Promise-like object (default: true)
---
--- Configuration options for [Struktura.Configure].

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
--- @prop Net any
--- @within Struktura
--- Low-level networking implementation used by Struktura.
---
--- Most projects should not need to touch this directly; prefer [Struktura.GetService],
--- service `Client` methods, and `Client` signals created via [Struktura.CreateSignal].

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

--- @within Struktura
--- @private
--- Ensures the networking layer has been started exactly once.
---
--- Struktura defers starting `Net` until it actually needs it (e.g. during [Struktura.Start] or
--- when a client calls [Struktura.GetService]).

local function ensureNetStarted()
	if netStarted then
		return
	end
	netStarted = true
	Struktura.Net:_Start()
end

--- @within Struktura
--- @private
--- Returns true when `value` looks like a Promise implementation compatible with Struktura.
---
--- Struktura only relies on `andThen`, `catch`, and `await`.

local function isPromiseLike(value: any): boolean
	return type(value) == "table"
		and type(value.andThen) == "function"
		and type(value.catch) == "function"
		and type(value.await) == "function"
end

--- @within Struktura
--- @private
--- Normalizes an `Init`/`Start` return value into a Promise-like object.
---
--- - `nil` becomes a resolved promise
--- - a Promise-like value is returned as-is
--- - anything else becomes `Promise.resolve(value)`

local function toPromise(value: any): PromiseLike
	if value == nil then
		return Promise.resolve()
	end
	if isPromiseLike(value) then
		return value
	end
	return Promise.resolve(value)
end

--- @within Struktura
--- @private
--- Requires a ModuleScript and registers it as a service or controller.
---
--- If the module table has `Type == "Controller"`, it is stored in the controller set; otherwise it is
--- treated as a server service module.
---
--- @return boolean -- True if the module was processed, false if feeding was rejected (already started).
--- @error string -- Throws if requiring the module errors.

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

--- @within Struktura
--- @private
--- Binds a lifecycle `signal` to call `On<name>` on every loaded module in the current realm.
---
--- For example, binding `"PlayerAdded"` will invoke `module.OnPlayerAdded(module, player)` for every module
--- that defines it.

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

--- @within Struktura
--- @private
--- @server
--- Creates a server signal object that routes through `Net:Fire` using `netName` + `eventName`.

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

--- @within Struktura
--- @private
--- @server
--- Scans service `Client` tables and registers:
---
--- - Signal markers (from [Struktura.CreateSignal]) as server signal objects
--- - Client RPC handlers for functions declared in `Client`
--- - The `__struktura_meta` handler used by [Struktura.GetService] on the client

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

--- Configures Struktura runtime options.
--- @within Struktura
---
--- This is usually called once during boot, before [Struktura.Start].
---
--- `ServicePromises` controls how client-side service method calls behave:
---
--- - `true` (default): methods return a Promise-like object from `Net:Request(...)`
--- - `false`: methods synchronously `:await()` the request and return the result (this yields)
---
--- @param options Settings? -- Configuration overrides.

function Struktura.Configure(options: Settings?)
	if not options then
		return
	end

	if options.ServicePromises ~= nil then
		initSettings.ServicePromises = options.ServicePromises
	end
end

--- Creates and (optionally) binds a custom lifecycle event.
--- @within Struktura
---
--- Once created, any module can listen by implementing a method named `On<name>`. For example, if you create
--- a lifecycle named `"RoundStarted"`, modules may implement `OnRoundStarted(...)`.
---
--- If Struktura has already started (or is in the process of starting), the lifecycle is bound immediately.
--- Otherwise, it will be bound during [Struktura.Start].
---
--- @param name string -- Lifecycle name (without the `On` prefix).
--- @param signal EventSignal -- Any object with `:Connect(callback)` that returns a disconnectable connection.
--- @return PromiseLike -- Resolves when the lifecycle is registered; rejects if it already exists.

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

--- Creates a **signal marker** for use inside a service's `Client` table (server only).
--- @within Struktura
--- @server
---
--- This does **not** create a real Signal object. Instead, it returns an opaque marker used by Struktura
--- during [Struktura.Start] to convert the field into a server signal wrapper (see [ServerSignal]).
---
--- Example:
---
--- ```lua
--- local MyService = { Name = "MyService" }
--- MyService.Client = {
---     Pinged = Struktura.CreateSignal(),
--- }
---
--- function MyService:Start()
---     self.Client.Pinged:FireAll("hello")
--- end
--- ```
---
--- @return any -- The internal marker object.

function Struktura.CreateSignal()
	if isServer then
		return signalFlag
	end
	warn("[Struktura] CreateSignal can only be called on Server.")
	return nil
end

--- Returns a promise that resolves once Struktura has finished starting.
--- @within Struktura
--- @yields
---
--- This is useful when a controller wants to wait until all `Init` functions have run and services have been
--- surfaced on the server.
---
--- @return PromiseLike

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

--- Loads (requires) modules from a container folder and registers them with Struktura.
--- @within Struktura
---
--- - If `deep` is truthy, Struktura scans all descendants; otherwise it only scans direct children.
--- - Any module that returns a table is registered.
--- - If that table has `Type == "Controller"`, it's treated as a controller (client). Otherwise it's a service (server).
---
--- You must call this before [Struktura.Start] if you want modules to participate in lifecycle events.
---
--- @param container Folder -- Folder containing modules.
--- @param deep boolean? -- Whether to include descendants.
--- @return PromiseLike -- Resolves with a timing string when initialization completes.

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

--- Returns a previously-initialized controller by name (client only).
--- @within Struktura
--- @client
---
--- Controllers are registered during [Struktura.Initialize]. Names come from the returned table's `Name` field
--- or fall back to the ModuleScript name.
---
--- @param name string -- Controller name.
--- @return T? -- The controller table if found, otherwise `nil`.

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

--- Returns a service by name.
--- @within Struktura
--- @server
--- @client
--- @yields
---
--- Behavior differs by realm:
---
--- - **Server:** returns the raw service module table that was loaded during [Struktura.Initialize].
--- - **Client:** builds and caches a proxy based on server-provided metadata.
---
--- The client proxy exposes:
---
--- - Signal fields as objects with `:Connect(callback)`
--- - Method calls via `Service:MethodName(...)` (implemented through `__index`)
---
--- By default, calling a method returns a Promise-like value. You can change this with [Struktura.Configure].
---
--- @param name string -- Service name.
--- @return T -- Service table (server) or proxy (client).
--- @error string -- Throws on client if service metadata cannot be fetched.

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

--- Starts Struktura: binds lifecycle events, starts networking, and runs module `Init`/`Start` hooks.
--- @within Struktura
--- @server
--- @client
--- @yields
---
--- Start order:
---
--- 1. Ensures `Net` is started
--- 2. Binds lifecycle signals (built-in and custom)
--- 3. Runs `Init` on every loaded module (services on server, controllers on client)
--- 4. On server, surfaces service `Client` tables (RPC + signals)
--- 5. Marks Struktura as started and then runs `Start` for each module asynchronously
---
--- On the client, Struktura will wait for the server to set the `ServerReady` attribute before continuing.
---
--- @return PromiseLike -- Resolves with a timing string when initialization hooks complete.

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
