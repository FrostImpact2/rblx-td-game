--[[
	GameStateManager (Server Script)
	Place in ServerScriptService/

	Manages the high-level game state: "Lobby" vs "InRound".
	Creates a StringValue in ReplicatedStorage that all scripts can observe.
	Exposes a RemoteEvent so clients can request a state toggle (temporary
	testing convenience – remove or gate behind admin checks before shipping).
]]

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ============================================================
-- SHARED STATE VALUE
-- ============================================================

-- All scripts (client and server) can read this to know the current state.
local gameStateValue       = Instance.new("StringValue")
gameStateValue.Name        = "GameState"
gameStateValue.Value       = "Lobby"     -- starts in Lobby
gameStateValue.Parent      = ReplicatedStorage

print("[GameStateManager] GameState created – starting in Lobby.")

-- ============================================================
-- REMOTE EVENTS
-- ============================================================

-- Client → Server: request a state toggle (testing only)
local toggleRemote      = Instance.new("RemoteEvent")
toggleRemote.Name       = "ToggleGameState"
toggleRemote.Parent     = ReplicatedStorage

-- Server → Client: broadcast state change so GUIs can react immediately
local stateChangedRemote      = Instance.new("RemoteEvent")
stateChangedRemote.Name       = "GameStateChanged"
stateChangedRemote.Parent     = ReplicatedStorage

-- ============================================================
-- STATE TRANSITIONS
-- ============================================================

local function setState(newState: string)
	if gameStateValue.Value == newState then return end
	gameStateValue.Value = newState
	print("[GameStateManager] State → " .. newState)
	-- Notify all clients
	stateChangedRemote:FireAllClients(newState)
end

-- ============================================================
-- REMOTE HANDLER  (testing – any player can toggle)
-- ============================================================

toggleRemote.OnServerEvent:Connect(function(_player: Player)
	if gameStateValue.Value == "Lobby" then
		setState("InRound")
	else
		setState("Lobby")
	end
end)
