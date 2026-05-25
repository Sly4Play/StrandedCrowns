local Players         = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Remotes         = require(ReplicatedStorage.Shared.Remotes)

local player          = Players.LocalPlayer
local playerGui       = player:WaitForChild("PlayerGui")

-- Build GUI
local screenGui = Instance.new("ScreenGui")
screenGui.Name         = "GameHud"
screenGui.ResetOnSpawn = false
screenGui.Parent       = playerGui

-- Coin counter (top-right, clear of Roblox chat)
local coinFrame = Instance.new("Frame")
coinFrame.Name            = "CoinFrame"
coinFrame.Size            = UDim2.new(0, 160, 0, 48)
coinFrame.Position        = UDim2.new(1, -176, 0, 16)
coinFrame.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
coinFrame.BackgroundTransparency = 0.4
coinFrame.Parent          = screenGui

local coinLabel = Instance.new("TextLabel")
coinLabel.Name            = "CoinLabel"
coinLabel.Size            = UDim2.new(1, 0, 1, 0)
coinLabel.BackgroundTransparency = 1
coinLabel.TextColor3      = Color3.fromRGB(255, 220, 50)
coinLabel.TextSize        = 22
coinLabel.Font            = Enum.Font.GothamBold
coinLabel.Text            = "Coins: 0"
coinLabel.Parent          = coinFrame

-- Day banner (top-center)
local dayFrame = Instance.new("Frame")
dayFrame.Name             = "DayFrame"
dayFrame.Size             = UDim2.new(0, 200, 0, 48)
dayFrame.Position         = UDim2.new(0.5, -100, 0, 16)
dayFrame.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
dayFrame.BackgroundTransparency = 0.4
dayFrame.Parent           = screenGui

local dayLabel = Instance.new("TextLabel")
dayLabel.Name             = "DayLabel"
dayLabel.Size             = UDim2.new(1, 0, 1, 0)
dayLabel.BackgroundTransparency = 1
dayLabel.TextColor3       = Color3.fromRGB(255, 255, 255)
dayLabel.TextSize         = 22
dayLabel.Font             = Enum.Font.GothamBold
dayLabel.Text             = "Day 1 — Dawn"
dayLabel.Parent           = dayFrame

-- Phase colour map
local PHASE_COLORS = {
    Dawn  = Color3.fromRGB(255, 200, 100),
    Day   = Color3.fromRGB(255, 255, 255),
    Dusk  = Color3.fromRGB(255, 140,  60),
    Night = Color3.fromRGB( 80, 100, 180),
}

-- Remote listeners
Remotes.CoinChanged.OnClientEvent:Connect(function(amount: number)
    coinLabel.Text = "Coins: " .. tostring(amount)
end)

Remotes.PhaseChanged.OnClientEvent:Connect(function(phase: string, day: number)
    dayLabel.Text       = "Day " .. day .. " — " .. phase
    dayLabel.TextColor3 = PHASE_COLORS[phase] or Color3.fromRGB(255,255,255)
end)

local HudController = {}
return HudController
