--!strict
--!optimize 2

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

export type PlayerName = string
export type Target = Player | PlayerName | { PlayerName } | "All" | { Except: PlayerName } | nil
export type NetName = string
export type EventName = string

export type Connection = {
	Disconnect: (self: Connection) -> (),
}

export type Packet = {
	Net: NetName,
	Event: EventName,
	Payload: buffer?,
}

type PromiseLike = {
	await: (self: PromiseLike) -> (boolean, ...any),
}

type PromiseStatic = {
	try: (fn: (...any) -> ...any, ...any) -> PromiseLike,
}

type DynamicCodec = {
	serialize: (state: any, version: number, ...any) -> buffer,
	deserialize: (state: any, version: number, payload: buffer) -> ...any,
}

type VoidSentryModule = {
	Dynamic: DynamicCodec,
}

type GeneratedServer = {
	ClientEvent: {
		Fire: (player: Player, packet: Packet) -> (),
		FireAll: (packet: Packet) -> (),
		FireList: (players: { Player }, packet: Packet) -> (),
		FireExcept: (player: Player, packet: Packet) -> (),
	},
	ServerEvent: {
		On: (callback: (player: Player, packet: Packet?) -> ()) -> (),
	},
	RemoteFunction: {
		On: (callback: (player: Player, packet: Packet) -> buffer?) -> (),
	},
}

type GeneratedClient = {
	ClientEvent: {
		On: (callback: (packet: Packet?) -> ()) -> (),
	},
	ServerEvent: {
		Fire: (packet: Packet) -> (),
	},
	RemoteFunction: {
		Invoke: (packet: Packet) -> buffer?,
	},
}

local Packages = script.Parent.Parent
local Promise = require(Packages:WaitForChild("Promise")) :: PromiseStatic
local VoidSentry = require(Packages:WaitForChild("VoidSentry")) :: VoidSentryModule
local Generated =
	require(script:WaitForChild(if RunService:IsServer() then "Server" else "Client")) :: GeneratedServer | GeneratedClient

local Dynamic = VoidSentry.Dynamic
local isServer = RunService:IsServer()

local Net = {}

local listeners: { [NetName]: { [EventName]: { (...any) -> () } } } = {}
local handlers: { [NetName]: { [EventName]: (Player, ...any) -> ...any } } = {}

local function packPayload(...): buffer
	return Dynamic.serialize(nil, 0, ...)
end

local function unpackPayload(payload: buffer?): ...any
	if payload == nil then
		return
	end

	return Dynamic.deserialize(nil, 0, payload)
end

local function dispatch(netName: NetName, eventName: EventName, ...)
	local byNet = listeners[netName]
	if not byNet then
		return
	end

	local list = byNet[eventName]
	if not list then
		return
	end

	for _, callback in ipairs(list) do
		task.spawn(callback, ...)
	end
end

function Net:On(netName: NetName, eventName: EventName, callback: (...any) -> ()): Connection
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

	local conn: Connection = {} :: any
	local connected = true

	function conn:Disconnect()
		if not connected then
			return
		end

		connected = false

		local currentByNet = listeners[netName]
		if not currentByNet then
			return
		end

		local currentList = currentByNet[eventName]
		if not currentList then
			return
		end

		for i = #currentList, 1, -1 do
			if currentList[i] == callback then
				table.remove(currentList, i)
				break
			end
		end
	end

	return conn
end

function Net:Fire(target: Target, netName: NetName, eventName: EventName, ...)
	local packet: Packet = {
		Net = netName,
		Event = eventName,
		Payload = packPayload(...),
	}

	if isServer then
		local transport = Generated :: GeneratedServer

		if target == nil or target == "All" then
			transport.ClientEvent.FireAll(packet)
			return
		end

		if typeof(target) == "Instance" then
			transport.ClientEvent.Fire(target :: Player, packet)
			return
		end

		if type(target) == "string" then
			local player = Players:FindFirstChild(target)
			if player and player:IsA("Player") then
				transport.ClientEvent.Fire(player, packet)
			end
			return
		end

		if type(target) == "table" then
			local except = (target :: { Except: PlayerName? }).Except
			if type(except) == "string" then
				local player = Players:FindFirstChild(except)
				if player and player:IsA("Player") then
					transport.ClientEvent.FireExcept(player, packet)
				end
				return
			end

			local players = table.create(#target)
			for _, name in ipairs(target :: { PlayerName }) do
				local player = Players:FindFirstChild(name)
				if player and player:IsA("Player") then
					table.insert(players, player)
				end
			end

			if #players > 0 then
				transport.ClientEvent.FireList(players, packet)
			end
			return
		end

		error("[Struktura.Net] Invalid target")
	else
		local transport = Generated :: GeneratedClient
		transport.ServerEvent.Fire(packet)
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

function Net:Request(netName: NetName, eventName: EventName, ...): PromiseLike
	if isServer then
		error("[Struktura.Net] Request can only be called on the client")
	end

	local transport = Generated :: GeneratedClient
	local packet: Packet = {
		Net = netName,
		Event = eventName,
		Payload = packPayload(...),
	}

	return Promise.try(function()
		local result = transport.RemoteFunction.Invoke(packet)
		if result == nil then
			return
		end

		return unpackPayload(result)
	end)
end

function Net:_Start()
	if isServer then
		local transport = Generated :: GeneratedServer

		transport.ServerEvent.On(function(_player: Player, packet: Packet?)
			if packet == nil then
				return
			end

			dispatch(packet.Net, packet.Event, unpackPayload(packet.Payload))
		end)

		transport.RemoteFunction.On(function(player: Player, packet: Packet): buffer?
			local byNet = handlers[packet.Net]
			local handler = byNet and byNet[packet.Event]
			if not handler then
				return nil
			end

			local ok, result = pcall(function()
				return table.pack(handler(player, unpackPayload(packet.Payload)))
			end)

			if not ok then
				warn(`[Struktura.Net] Handler error for {packet.Net}.{packet.Event}: {tostring(result)}`)
				return nil
			end

			return packPayload(table.unpack(result, 1, result.n))
		end)
	else
		local transport = Generated :: GeneratedClient

		transport.ClientEvent.On(function(packet: Packet?)
			if packet == nil then
				return
			end

			dispatch(packet.Net, packet.Event, unpackPayload(packet.Payload))
		end)
	end
end

return Net