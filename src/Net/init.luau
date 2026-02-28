--!strict
--!optimize 2

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Packages = ReplicatedStorage:WaitForChild("Packages")

local Promise = require(Packages:WaitForChild("Promise")) :: any
local VoidSentry = require(Packages:WaitForChild("VoidSentry")) :: any
local Dynamic = VoidSentry.Dynamic

local isServer = RunService:IsServer()

local Generated = if isServer
	then require(script:WaitForChild("Server")) :: any
	else require(script:WaitForChild("Client")) :: any

export type Target = Player | {Player} | "All" | { Except: Player }
export type Route = string

local Net = {}

local listeners: {[string]: {(...any) -> ()}} = {}
local handlers: {[string]: (Player, ...any) -> ...any} = {}

local function splitRoute(route: string): (string, string)
	local a, b = route:match("^(.-)%.(.+)$")
	if a and b then
		return a, b
	end
	return route, ""
end

local function packPayload(...): buffer
	return Dynamic.serialize(nil, nil, ...)
end

local function unpackPayload(payload: buffer?): ...any
	if payload == nil then
		return
	end
	return Dynamic.deserialize(nil, nil, payload)
end

local function dispatch(route: string, ...)
	local list = listeners[route]
	if not list then
		return
	end
	for _, cb in ipairs(list) do
		task.spawn(cb, ...)
	end
end

function Net:On(route: Route, callback: (...any) -> ())
	local list = listeners[route]
	if not list then
		list = {}
		listeners[route] = list
	end
	table.insert(list, callback)

	return function()
		local l = listeners[route]
		if not l then
			return
		end
		for i = #l, 1, -1 do
			if l[i] == callback then
				table.remove(l, i)
				break
			end
		end
	end
end

function Net:Fire(target: Target?, route: Route, ...)
	local netName, eventName = splitRoute(route)
	local payload = packPayload(...)

	local pkt = {
		Net = netName,
		Event = eventName,
		Payload = payload,
	}

	if isServer then
		if target == nil or target == "All" then
			Generated.ClientEvent.FireAll(pkt)
			return
		end

		if typeof(target) == "Instance" then
			Generated.ClientEvent.Fire(target, pkt)
			return
		end

		if type(target) == "table" then
			if (target :: any).Except ~= nil then
				Generated.ClientEvent.FireExcept((target :: any).Except, pkt)
				return
			end

			Generated.ClientEvent.FireList(target :: {Player}, pkt)
			return
		end

		error("[Struktura.Net] Invalid target")
	else
		Generated.ServerEvent.Fire(pkt)
	end
end

function Net:Handle(route: Route, handler: (Player, ...any) -> ...any)
	handlers[route] = handler
end

function Net:Request(route: Route, ...)
	if isServer then
		error("[Struktura.Net] Request can only be called on the client")
	end

	local netName, eventName = splitRoute(route)
	local payload = packPayload(...)

	local pkt = {
		Net = netName,
		Event = eventName,
		Payload = payload,
	}

	return Promise.try(function()
		local ret = Generated.RemoteFunction.Invoke(pkt)
		if ret == nil then
			return
		end
		return unpackPayload(ret)
	end)
end

function Net:_Start()
	if isServer then
		Generated.ServerEvent.On(function(player: Player, pkt)
			if pkt == nil then
				return
			end
			local route = tostring(pkt.Net) .. "." .. tostring(pkt.Event)
			dispatch(route, unpackPayload(pkt.Payload))
		end)

		Generated.RemoteFunction.On(function(player: Player, pkt): buffer?
			local route = tostring(pkt.Net) .. "." .. tostring(pkt.Event)
			local handler = handlers[route]
			if not handler then
				return nil
			end

			local ok, results = pcall(function()
				return table.pack(handler(player, unpackPayload(pkt.Payload)))
			end)

			if not ok then
				warn(`[Struktura.Net] Handler error for {route}: {tostring(results)}`)
				return nil
			end

			return packPayload(table.unpack(results, 1, results.n))
		end)
	else
		Generated.ClientEvent.On(function(pkt)
			if pkt == nil then
				return
			end
			local route = tostring(pkt.Net) .. "." .. tostring(pkt.Event)
			dispatch(route, unpackPayload(pkt.Payload))
		end)
	end
end

return Net