local GameConfig    = require(game:GetService("ReplicatedStorage").Shared.GameConfig)
local CoinService   = require(script.Parent.CoinService)
local WorldService  = require(script.Parent.WorldService)
local NpcService    = require(script.Parent.NpcService)
local TimeService   = require(script.Parent.TimeService)
local MayorService  = require(script.Parent.MayorService)
local Players       = game:GetService("Players")

type GreedData = {
    id: string, instance: Model,
    state: string, target: any?,
    portalPos: Vector3,
}

local _greeds: {[string]: GreedData} = {}
local _greedCounter = 0
local _dayNumber    = 1
local _isNight      = false

local function nextId(): string
    _greedCounter += 1
    return "greed_" .. _greedCounter
end

local function makeGreedModel(id: string, pos: Vector3): Model
    local model = Instance.new("Model")
    model.Name  = "Greed_" .. id

    local root      = Instance.new("Part")
    root.Name       = "HumanoidRootPart"
    root.Size       = Vector3.new(2, 3, 1)
    root.BrickColor = BrickColor.new("Bright red")
    root.CanCollide = false
    root.Position   = pos + Vector3.new(0, 1.5, 0)
    root.Parent     = model

    local humanoid         = Instance.new("Humanoid")
    humanoid.WalkSpeed     = GameConfig.GREED_SPEED
    humanoid.MaxHealth     = 100
    humanoid.Health        = 100
    humanoid.Parent        = model

    model.PrimaryPart = root
    model.Parent      = workspace
    return model
end

local function getGreedPos(gd: GreedData): Vector3
    local root = gd.instance.PrimaryPart
    return root and root.Position or Vector3.new(0,0,0)
end

local function moveGreed(gd: GreedData, target: Vector3, speed: number)
    local humanoid = gd.instance:FindFirstChildOfClass("Humanoid")
    if humanoid then
        humanoid.WalkSpeed = speed
        humanoid:MoveTo(target)
    end
end

local function despawnGreed(gd: GreedData)
    gd.state = "Despawned"
    if gd.instance.Parent then gd.instance:Destroy() end
    _greeds[gd.id] = nil
end

local function onGreedDied(gd: GreedData)
    if gd.state == "Despawned" then return end
    local pos = getGreedPos(gd)  -- cache before Destroy
    despawnGreed(gd)
    CoinService.spawnGroundCoins(pos, 2, 0)
end

-- Forward-declare before spawnWave (which calls GreedService.runAI)
local GreedService = {}

-- Spawn wave from a portal
local function spawnWave(portalPos: Vector3, quota: number)
    for i = 1, quota do
        task.delay((i - 1) * GameConfig.GREED_SPAWN_INTERVAL, function()
            if not _isNight then return end  -- dawn broke before this spawn fired
            local id    = nextId()
            local model = makeGreedModel(id, portalPos)
            local gd: GreedData = {
                id = id, instance = model,
                state = "Scanning", target = nil,
                portalPos = portalPos,
            }
            _greeds[id] = gd

            local humanoid = model:FindFirstChildOfClass("Humanoid")
            if humanoid then
                humanoid.Died:Connect(function() onGreedDied(gd) end)
            end

            task.spawn(function() GreedService.runAI(gd) end)
        end)
    end
end

local function calcQuota(day: number): number
    -- Day 1 = 1, grows linearly — tune in GameConfig
    return math.max(1, day)
end

-- Dawn: retreat all living Greed
TimeService.onDawn(function(day)
    _isNight   = false
    _dayNumber = day
    for _, gd in _greeds do
        if gd.state ~= "Despawned" then
            gd.state  = "Retreating"
            gd.target = nil
        end
    end
end)

-- Night: activate all portals
TimeService.onNight(function()
    _isNight = true
    -- Remove any stale entries from previous night whose instances are gone
    local stale = {}
    for id, gd in _greeds do
        if not gd.instance.Parent then table.insert(stale, id) end
    end
    for _, id in stale do _greeds[id] = nil end
    local portals = WorldService.getPortals()
    if not portals or #portals == 0 then
        warn("[GreedService] No portals found — skipping night wave")
        return
    end
    local quota   = calcQuota(_dayNumber)
    for _, portal in portals do
        spawnWave(portal.Position, quota)
    end
    print("[GreedService] Night wave spawned — day:", _dayNumber, "quota per portal:", quota)
end)

function GreedService.getActiveGreed(): {GreedData}
    local list = {}
    for _, gd in _greeds do table.insert(list, gd) end
    return list
end

local function scanForTarget(gd: GreedData): any?
    local pos    = getGreedPos(gd)
    local radius = GameConfig.GREED_SCAN_RADIUS

    -- Priority 1: Ground tools
    for _, gt in WorldService.getGroundTools() do
        if (gt.position - pos).Magnitude < radius then
            return { type = "GroundTool", instance = gt.instance, position = gt.position }
        end
    end

    -- Priority 2: Ground coins
    for _, coin in CoinService.getGroundCoins() do
        if coin.instance.Parent and (coin.instance.Position - pos).Magnitude < radius then
            return { type = "GroundCoin", instance = coin.instance, position = coin.instance.Position }
        end
    end

    -- Priority 3: Pets — N/A Phase 1

    -- Priority 4: Town coffer (Mayor bank, only when bank is open)
    if MayorService.isBankOpen() then
        local mayorPos = MayorService.getPosition()
        if (mayorPos - pos).Magnitude < radius then
            return { type = "Coffer", position = mayorPos }
        end
    end

    -- Priority 5: Workers with tool
    for _, npc in NpcService.getWorkers() do
        if npc.tool and npc.state ~= "AtWalls" then
            local npcPos = npc.instance.PrimaryPart and npc.instance.PrimaryPart.Position
            if npcPos and (npcPos - pos).Magnitude < radius then
                return { type = "WorkerTool", npc = npc, position = npcPos }
            end
        end
    end

    -- Priority 6: Workers with coins
    for _, npc in NpcService.getWorkers() do
        if npc.purse > 0 and npc.state ~= "AtWalls" then
            local npcPos = npc.instance.PrimaryPart and npc.instance.PrimaryPart.Position
            if npcPos and (npcPos - pos).Magnitude < radius then
                return { type = "WorkerCoins", npc = npc, position = npcPos }
            end
        end
    end

    -- Priority 7: Players with coins (full pass first)
    for _, player in Players:GetPlayers() do
        local char = player.Character
        if not (char and char.PrimaryPart) then continue end
        local ppos = char.PrimaryPart.Position
        if (ppos - pos).Magnitude < radius then
            if CoinService.getPurse(player.UserId) > 0 then
                return { type = "PlayerCoins", player = player, position = ppos }
            end
        end
    end

    -- Priority 8: Crown (players with empty purse)
    for _, player in Players:GetPlayers() do
        local char = player.Character
        if not (char and char.PrimaryPart) then continue end
        local ppos = char.PrimaryPart.Position
        if (ppos - pos).Magnitude < radius then
            if CoinService.getPurse(player.UserId) == 0 then
                return { type = "Crown", player = player, position = ppos }
            end
        end
    end

    -- Priority 9: Crownless player weapon — deferred to Phase 4

    return nil
end

local function executeSteal(gd: GreedData, target: any)
    if target.type == "GroundTool" then
        WorldService.removeGroundTool(target.instance)
        if target.instance.Parent then target.instance:Destroy() end
        print("[Greed] Stole ground tool")

    elseif target.type == "GroundCoin" then
        CoinService.removeGroundCoin(target.instance)
        print("[Greed] Stole ground coin")

    elseif target.type == "Coffer" then
        local stolen = MayorService.steal(GameConfig.MAYOR_BANK_STEAL_AMT)
        print("[Greed] Stole from bank:", stolen)

    elseif target.type == "WorkerTool" then
        NpcService.hitWorker(target.npc)
        print("[Greed] Hit worker for tool")

    elseif target.type == "WorkerCoins" then
        NpcService.hitWorker(target.npc)
        print("[Greed] Hit worker for coins")

    elseif target.type == "PlayerCoins" then
        local player = target.player :: Player
        local char   = player.Character
        local pos    = char and char.PrimaryPart and char.PrimaryPart.Position or gd.portalPos
        CoinService.dropFromHit(player.UserId, pos)
        print("[Greed] Hit player for coins")

    elseif target.type == "Crown" then
        local player = target.player :: Player
        local char   = player.Character
        local pos    = char and char.PrimaryPart and char.PrimaryPart.Position or gd.portalPos
        CoinService.dropFromHit(player.UserId, pos)
        print("[Greed] Attempted crown steal (Phase 4) — hit for coins instead")
    end
end

function GreedService.runAI(gd: GreedData)
    local retreatTicks = 0
    while gd.state ~= "Despawned" do
        task.wait(0.5)
        if gd.state == "Despawned" then return end

        if gd.state == "Scanning" then
            local target = scanForTarget(gd)
            if target then
                gd.target = target
                gd.state  = "Pursuing"
                moveGreed(gd, target.position, GameConfig.GREED_SPEED)
            else
                -- No target: assault nearest gate position
                local gates = {
                    GameConfig.GATE_NORTH, GameConfig.GATE_SOUTH,
                    GameConfig.GATE_EAST,  GameConfig.GATE_WEST,
                }
                local myPos   = getGreedPos(gd)
                local nearest = gates[1]
                for _, g in gates do
                    if (g - myPos).Magnitude < (nearest - myPos).Magnitude then nearest = g end
                end
                moveGreed(gd, nearest, GameConfig.GREED_SPEED)
            end

        elseif gd.state == "Pursuing" then
            local target = gd.target
            if not target then gd.state = "Scanning" continue end

            -- Stale ground-object check
            if target.type == "GroundTool" or target.type == "GroundCoin" then
                if not (target.instance and target.instance.Parent) then
                    gd.target = nil
                    gd.state  = "Scanning"
                    continue
                end
            end

            -- Update target position for moving targets
            if target.type == "PlayerCoins" or target.type == "Crown" then
                local char = (target.player :: Player).Character
                if char and char.PrimaryPart then
                    target.position = char.PrimaryPart.Position
                    moveGreed(gd, target.position, GameConfig.GREED_SPEED)
                else
                    gd.target = nil
                    gd.state  = "Scanning"
                    continue
                end
            elseif target.type == "WorkerTool" or target.type == "WorkerCoins" then
                local npcRoot = target.npc.instance.PrimaryPart
                if npcRoot then
                    target.position = npcRoot.Position
                    moveGreed(gd, target.position, GameConfig.GREED_SPEED)
                else
                    gd.target = nil
                    gd.state  = "Scanning"
                    continue
                end
            end

            -- Check if in steal range
            local myPos  = getGreedPos(gd)
            local dist   = (target.position - myPos).Magnitude
            if dist < GameConfig.GREED_STEAL_RANGE then
                gd.state = "Stealing"
            end

        elseif gd.state == "Stealing" then
            if gd.target then
                executeSteal(gd, gd.target)
            end
            gd.target = nil
            gd.state  = "Retreating"
            retreatTicks = 0
            moveGreed(gd, gd.portalPos, GameConfig.GREED_RETREAT_SPEED)

        elseif gd.state == "Retreating" then
            retreatTicks += 1
            local myPos = getGreedPos(gd)
            if (myPos - gd.portalPos).Magnitude < 5 or retreatTicks > 60 then
                despawnGreed(gd)
                return
            end
            moveGreed(gd, gd.portalPos, GameConfig.GREED_RETREAT_SPEED)
        end
    end
end

return GreedService
