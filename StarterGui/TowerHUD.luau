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
hint.Position = UDim2.new(0.5, -175, 1, -50)
hint.BackgroundColor3 = Color3.fromRGB(25, 25, 35)
hint.BackgroundTransparency = 0.3
hint.BorderSizePixel = 0
hint.Text = ""
hint.TextColor3 = Color3.fromRGB(220, 220, 220)
hint.TextScaled = true
hint.Font = Enum.Font.SourceSans
hint.Parent = screenGui

local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(80, 120, 200)
stroke.Thickness = 1
stroke.Parent = hint
