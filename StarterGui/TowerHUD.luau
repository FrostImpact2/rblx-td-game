local Players = game:GetService("Players")
local player  = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "TowerHUD"
screenGui.ResetOnSpawn = false
screenGui.Parent = playerGui

local hint = Instance.new("TextLabel")
hint.Name = "PlacementHint"
hint.Size = UDim2.new(0, 350, 0, 36)
hint.Position = UDim2.new(0.5, -175, 1, -80)
hint.BackgroundColor3 = Color3.fromRGB(42, 44, 58)
hint.BackgroundTransparency = 0.15
hint.BorderSizePixel = 0
hint.Text = ""
hint.TextColor3 = Color3.fromRGB(235, 237, 245)
hint.TextScaled = true
hint.Font = Enum.Font.GothamBold
hint.Parent = screenGui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 8)
corner.Parent = hint

local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(255, 90, 120)
stroke.Thickness = 1
stroke.Transparency = 0.3
stroke.Parent = hint
