--[[
	DamageIndicatorClient (LocalScript)
	Place in StarterPlayer/StarterPlayerScripts/

	Listens for "ShowDamageIndicator" RemoteEvent and renders a
	floating damage number over the hit position in world-space.

	RemoteEvent payload (server fires with):
		position : Vector3  – world position of the hit
		amount   : number   – damage / heal value to display
		kind     : string?  – "Normal" | "Critical" | "Heal" | "Enemy" | "Nano"
		                       (defaults to "Normal")
]]

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DamageIndicator   = require(ReplicatedStorage:WaitForChild("DamageIndicator", 10))

local player  = Players.LocalPlayer
local camera  = workspace.CurrentCamera

-- ── GUI container ─────────────────────────────────────────────
local screenGui               = Instance.new("ScreenGui")
screenGui.Name                = "DamageIndicators"
screenGui.ResetOnSpawn        = false
screenGui.ZIndexBehavior      = Enum.ZIndexBehavior.Sibling
screenGui.IgnoreGuiInset      = true
screenGui.Parent              = player.PlayerGui

-- ── Remote ────────────────────────────────────────────────────
local remote = ReplicatedStorage:WaitForChild("ShowDamageIndicator", 15)
if not remote then
	error("[DamageIndicatorClient] RemoteEvent 'ShowDamageIndicator' not found!")
end

-- ── Active indicator list ─────────────────────────────────────
type Indicator = {
	label     : TextLabel,
	worldPos  : Vector3,
	elapsed   : number,
	lifetime  : number,
	floatDist : number,
	kind      : string,
	baseSize  : number,
}

local active: { Indicator } = {}

-- ── Spawn ──────────────────────────────────────────────────────
local function spawnIndicator(position: Vector3, amount: number, kind: string?)
	kind = kind or "Normal"

	local colour   = DamageIndicator.Colours[kind] or DamageIndicator.Colours.Normal
	local baseSize = (kind == "Critical" or kind == "Nano")
		and DamageIndicator.FONT_SIZE_CRIT
		or  DamageIndicator.FONT_SIZE_BASE

	-- Small random scatter so stacked hits don't perfectly overlap
	local scatter = Vector3.new(
		(math.random() - 0.5) * 0.6,
		0,
		(math.random() - 0.5) * 0.6
	)

	local label                      = Instance.new("TextLabel")
	label.Size                       = UDim2.new(0, 90, 0, 44)
	label.BackgroundTransparency     = 1
	label.TextScaled                 = false
	label.TextSize                   = baseSize
	label.Font                       = Enum.Font.GothamBold
	label.TextColor3                 = colour
	label.TextStrokeColor3           = Color3.fromRGB(0, 0, 0)
	label.TextStrokeTransparency     = 0.35
	label.Text                       = (kind == "Heal" and "+" or "") .. tostring(math.round(amount))
	label.AnchorPoint                = Vector2.new(0.5, 0.5)
	label.ZIndex                     = 10
	label.Parent                     = screenGui

	table.insert(active, {
		label     = label,
		worldPos  = position + scatter,
		elapsed   = 0,
		lifetime  = DamageIndicator.FLOAT_TIME,
		floatDist = DamageIndicator.FLOAT_HEIGHT,
		kind      = kind,
		baseSize  = baseSize,
	})
end

-- ── Per-frame update ───────────────────────────────────────────
RunService.RenderStepped:Connect(function(dt: number)
	local toRemove = {}

	for i, ind in ipairs(active) do
		ind.elapsed += dt
		local t = math.min(ind.elapsed / ind.lifetime, 1)  -- 0 → 1

		if t >= 1 then
			ind.label:Destroy()
			table.insert(toRemove, i)
			continue
		end

		-- Float upward in world space
		local worldPos = ind.worldPos + Vector3.new(0, ind.floatDist * t, 0)

		-- Project to screen
		local screenPos, onScreen = camera:WorldToViewportPoint(worldPos)
		if not onScreen then
			ind.label.Visible = false
			continue
		end

		ind.label.Visible  = true
		ind.label.Position = UDim2.new(0, screenPos.X, 0, screenPos.Y)

		-- Fade out over the last 40 % of lifetime
		local alpha = t > 0.6
			and 1 - ((t - 0.6) / 0.4)
			or  1

		ind.label.TextTransparency       = 1 - alpha
		ind.label.TextStrokeTransparency = 1 - (alpha * 0.65)

		-- Pop-in scale: grows from 1.4× → 1× in first 15 % of lifetime
		local scale = t < 0.15
			and (1 + (1 - t / 0.15) * 0.4)
			or  1

		ind.label.TextSize = math.round(ind.baseSize * scale)
	end

	-- Remove expired entries (backwards so indices stay valid)
	for j = #toRemove, 1, -1 do
		table.remove(active, toRemove[j])
	end
end)

-- ── Receive from server ────────────────────────────────────────
remote.OnClientEvent:Connect(function(position: Vector3, amount: number, kind: string?)
	spawnIndicator(position, amount, kind)
end)