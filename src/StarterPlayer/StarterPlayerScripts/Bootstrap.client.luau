local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService      = game:GetService("TweenService")
local Remotes    = require(ReplicatedStorage.Shared.Remotes)
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)

local player = Players.LocalPlayer

local Controllers = script.Parent.Controllers
require(Controllers.HudController)
require(Controllers.InputController)

-- ── NPC → Player coin arc animation ──────────────────────────────────────
-- Mirrors the buying animation in InputController but runs in reverse:
-- coins fly FROM the NPC position TO the player character.

local function playCoinArc(fromPos: Vector3, toPos: Vector3, count: number)
    local visual = math.min(count, 8)  -- max 8 coin parts per dump
    for i = 1, visual do
        task.delay((i - 1) * 0.13, function()
            local coin       = Instance.new("Part")
            coin.Name        = "CoinFX"
            coin.Size        = Vector3.new(1.5, 1.5, 1.5)
            coin.Shape       = Enum.PartType.Ball
            coin.BrickColor  = BrickColor.new("Bright yellow")
            coin.Material    = Enum.Material.Neon
            coin.Anchored    = true
            coin.CanCollide  = false
            coin.CastShadow  = false
            coin.Position    = fromPos + Vector3.new(0, 1.2, 0)
            coin.Parent      = workspace

            -- Arc upward to midpoint then sweep into player
            local mid = (fromPos + toPos) * 0.5 + Vector3.new(0, 5, 0)

            local t1 = TweenService:Create(coin,
                TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
                { Position = mid })
            t1:Play()
            t1.Completed:Wait()

            local t2 = TweenService:Create(coin,
                TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
                { Position = toPos })
            t2:Play()
            t2.Completed:Wait()
            coin:Destroy()
        end)
    end
end

Remotes.NpcCoinDump.OnClientEvent:Connect(function(npcPos: Vector3, amount: number)
    local char = player.Character
    if not char or not char.PrimaryPart then return end
    playCoinArc(npcPos, char.PrimaryPart.Position, amount)
end)
