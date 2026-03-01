--!strict
--!optimize 2

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Packages = script.Parent :: Folder

local Promise = require(Packages:WaitForChild("Promise")) :: any
local VoidSentry = require(Packages:WaitForChild("VoidSentry")) :: any
local Dynamic = VoidSentry.Dynamic

local isServer = RunService:IsServer()

local Generated = if isServer
	then require(script:WaitForChild("Server")) :: any
	else require(script:WaitForChild("Client")) :: any

export type PlayerName = string
export type Target = Player | PlayerName | {PlayerName} | "All" | { Except: PlayerName }

export type NetName = string
export type EventName = string

local Net = {}

local listeners: {[NetName]: {[EventName]: {(...any) -> ()}}} = {}
local handlers: {[NetName]: {[EventName]: (Player, ...any) -> ...any}} = {}

local function packPayload(...): buffer
	return Dynamic.serialize(nil, nil, ...)
end

local function unpackPayload(payload: buffer?): ...any
	if payload == nil then
		return
	end
	return Dynamic.deserialize(nil, nil, payload)
end

local function dispatch(netName: string, eventName: string, ...)
	local byNet = listeners[netName]
	if not byNet then
		return
	end
	local list = byNet[eventName]
	if not list then
		return
	end
	for _, cb in ipairs(list) do
		task.spawn(cb, ...)
	end
end

function Net:On(netName: NetName, eventName: EventName, callback: (...any) -> ())
	local byNet = listeners[netName]
	if not byNet then
		byNet = {}
		listeners[netName] = byNet
	end

	local list = byNet[eventName]
	if not list then
		list = {}
		byNet[eventName] = list
	end

	table.insert(list, callback)

	return function()
		local n = listeners[netName]
		if not n then
			return
		end
		local l = n[eventName]
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

local function resolvePlayer(name: string): Player?
	local p = Players:FindFirstChild(name)
	if p and p:IsA("Player") then
		return p
	end
	return nil
end

local function resolveList(names: {string}): {Player}
	local out = {}
	for _, n in ipairs(names) do
		local p = resolvePlayer(n)
		if p then
			table.insert(out, p)
		end
	end
	return out
end

function Net:Fire(target: Target?, netName: NetName, eventName: EventName, ...)
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
			Generated.ClientEvent.Fire(target :: Player, pkt)
			return
		end

		if type(target) == "string" then
			local p = resolvePlayer(target)
			if p then
				Generated.ClientEvent.Fire(p, pkt)
			end
			return
		end

		if type(target) == "table" then
			local exceptName = (target :: any).Except
			if type(exceptName) == "string" then
				local p = resolvePlayer(exceptName)
				if p then
					Generated.ClientEvent.FireExcept(p, pkt)
				end
				return
			end

			local list = resolveList(target :: {string})
			if #list > 0 then
				Generated.ClientEvent.FireList(list, pkt)
			end
			return
		end

		error("[Struktura.Net] Invalid target")
	else
		Generated.ServerEvent.Fire(pkt)
	end
end

function Net:Handle(netName: NetName, eventName: EventName, handler: (Player, ...any) -> ...any)
	local byNet = handlers[netName]
	if not byNet then
		byNet = {}
		handlers[netName] = byNet
	end
	byNet[eventName] = handler
end

function Net:Request(netName: NetName, eventName: EventName, ...)
	if isServer then
		error("[Struktura.Net] Request can only be called on the client")
	end

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
			dispatch(tostring(pkt.Net), tostring(pkt.Event), unpackPayload(pkt.Payload))
		end)

		Generated.RemoteFunction.On(function(player: Player, pkt): buffer?
			local netName = tostring(pkt.Net)
			local eventName = tostring(pkt.Event)

			local byNet = handlers[netName]
			local handler = byNet and byNet[eventName]
			if not handler then
				return nil
			end

			local ok, results = pcall(function()
				return table.pack(handler(player, unpackPayload(pkt.Payload)))
			end)

			if not ok then
				warn(`[Struktura.Net] Handler error for {netName}.{eventName}: {tostring(results)}`)
				return nil
			end

			return packPayload(table.unpack(results, 1, results.n))
		end)
	else
		Generated.ClientEvent.On(function(pkt)
			if pkt == nil then
				return
			end
			dispatch(tostring(pkt.Net), tostring(pkt.Event), unpackPayload(pkt.Payload))
		end)
	end
end

return Net