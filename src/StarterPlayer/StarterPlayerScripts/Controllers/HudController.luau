local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local Lighting          = game:GetService("Lighting")
local Remotes    = require(ReplicatedStorage.Shared.Remotes)
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- ── Coin counter (top-right) ──────────────────────────────────────────────

local screenGui = Instance.new("ScreenGui")
screenGui.Name         = "GameHud"
screenGui.ResetOnSpawn = false
screenGui.Parent       = playerGui

local coinFrame = Instance.new("Frame")
coinFrame.Name                   = "CoinFrame"
coinFrame.Size                   = UDim2.new(0, 160, 0, 48)
coinFrame.Position               = UDim2.new(1, -176, 0, 16)
coinFrame.BackgroundColor3       = Color3.fromRGB(30, 30, 30)
coinFrame.BackgroundTransparency = 0.4
coinFrame.Parent                 = screenGui

local coinLabel = Instance.new("TextLabel")
coinLabel.Name                   = "CoinLabel"
coinLabel.Size                   = UDim2.new(1, 0, 1, 0)
coinLabel.BackgroundTransparency = 1
coinLabel.TextColor3             = Color3.fromRGB(255, 220, 50)
coinLabel.TextSize               = 22
coinLabel.Font                   = Enum.Font.GothamBold
coinLabel.Text                   = "Coins: 0"
coinLabel.Parent                 = coinFrame

Remotes.CoinChanged.OnClientEvent:Connect(function(amount: number)
    coinLabel.Text = "Coins: " .. tostring(amount)
end)

-- ── Sun / Moon / Lighting ─────────────────────────────────────────────────
-- Roblox's built-in sky automatically renders the sun and moon at the correct
-- position for any ClockTime value.  We drive ClockTime each frame to match
-- the current game phase, giving a smooth day/night cycle with no extra UI.

Lighting.GlobalShadows = true
Lighting.ClockTime     = 12
Lighting.Brightness    = 1.5

-- Each phase maps a window of clock-hours over its real-time duration
local CLOCK_START: {[string]: number} = { Dawn = 5,  Day = 7,  Dusk = 17, Night = 19 }
local CLOCK_END:   {[string]: number} = { Dawn = 7,  Day = 17, Dusk = 19, Night = 5  }
local PHASE_DUR:   {[string]: number} = {
    Dawn  = GameConfig.DAWN_DURATION,
    Day   = GameConfig.DAY_DURATION,
    Dusk  = GameConfig.DUSK_DURATION,
    Night = GameConfig.NIGHT_DURATION,
}

-- Ambient colour endpoints
local AMB_DAY:   Color3 = Color3.fromRGB(110, 110, 110)
local AMB_DUSK:  Color3 = Color3.fromRGB( 90,  55,  35)
local AMB_NIGHT: Color3 = Color3.fromRGB( 25,  25,  55)
local AMB_DAWN:  Color3 = Color3.fromRGB(100, 105, 115)  -- brighter dawn start, near day-grey

local _phase      = "Dawn"
local _phaseStart = tick()

Remotes.PhaseChanged.OnClientEvent:Connect(function(phase: string, _day: number)
    _phase      = phase
    _phaseStart = tick()
    -- Snap to phase start so the sun doesn't teleport mid-interpolation
    Lighting.ClockTime = CLOCK_START[phase] or 12
end)

RunService.Heartbeat:Connect(function()
    local t  = math.clamp((tick() - _phaseStart) / (PHASE_DUR[_phase] or 60), 0, 1)
    local cs = CLOCK_START[_phase] or 12
    local ce = CLOCK_END[_phase]   or 12

    -- Interpolate clock time; handle the Night→midnight→Dawn wrap (19→5 crosses 24)
    local raw: number
    if ce < cs then
        raw = cs + t * ((24 - cs) + ce)
        if raw >= 24 then raw -= 24 end
    else
        raw = cs + t * (ce - cs)
    end
    Lighting.ClockTime = raw

    -- Ambient colour
    local amb: Color3
    if _phase == "Day" then
        amb = AMB_DAY
    elseif _phase == "Dawn" then
        amb = AMB_DAWN:Lerp(AMB_DAY, t)
    elseif _phase == "Dusk" then
        amb = AMB_DAY:Lerp(AMB_DUSK, t)
    else  -- Night
        -- darkest at midnight (t≈0.5); gently brightens toward Dawn
        local dark = math.sin(t * math.pi)
        amb = AMB_NIGHT:Lerp(AMB_DUSK, 1 - dark)
    end
    Lighting.Ambient = amb

    -- Brightness
    if _phase == "Night" then
        Lighting.Brightness = 0.4
    elseif _phase == "Dusk" then
        Lighting.Brightness = 1.5 - t * 1.1
    elseif _phase == "Dawn" then
        Lighting.Brightness = 1.1 + t * 0.4
    else
        Lighting.Brightness = 1.5
    end
end)

local HudController = {}
return HudController
