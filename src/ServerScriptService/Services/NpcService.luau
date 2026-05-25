local GameConfig   = require(game:GetService("ReplicatedStorage").Shared.GameConfig)
local CoinService  = require(script.Parent.CoinService)
local WorldService = require(script.Parent.WorldService)
local TimeService  = require(script.Parent.TimeService)
local Players      = game:GetService("Players")

-- NPC registry: id → NpcData
type NpcData = {
    id: string, instance: Model,
    profession: string, tool: BasePart?,
    purse: number, maxPurse: number,
    state: string, campId: number?,
}
local _npcs: {[string]: NpcData} = {}
local _npcCounter = 0

-- camp homeless counts
local _campCounts: {[number]: number} = {}

-- NPC color palette
local COLOR_HOMELESS = BrickColor.new("Medium stone grey")
local COLOR_JOBLESS  = BrickColor.new("Bright yellow")
local COLOR_WORKER   = BrickColor.new("Reddish brown")

-- ── helpers ──────────────────────────────────────────────────────────────

local function nextId(): string
    _npcCounter += 1
    return "npc_" .. _npcCounter
end

local function makeNpcModel(name: string, color: BrickColor, pos: Vector3): Model
    local model = Instance.new("Model")
    model.Name  = name

    local root      = Instance.new("Part")
    root.Name       = "HumanoidRootPart"
    root.Size       = Vector3.new(2, 3, 1)
    root.BrickColor = color
    root.CanCollide = false
    root.Position   = pos + Vector3.new(0, 1.5, 0)
    root.Parent     = model

    local humanoid         = Instance.new("Humanoid")
    humanoid.WalkSpeed     = GameConfig.VAGRANT_WALK_SPEED
    humanoid.MaxHealth     = 100
    humanoid.Health        = 100
    humanoid.Parent        = model

    model.PrimaryPart = root
    model.Parent      = workspace
    return model
end

local function setNpcColor(npc: NpcData, color: BrickColor)
    local root = npc.instance.PrimaryPart
    if root then root.BrickColor = color end
end

local function moveNpcTo(npc: NpcData, target: Vector3)
    local humanoid = npc.instance:FindFirstChildOfClass("Humanoid")
    if humanoid then humanoid:MoveTo(target) end
end

local function getNpcPosition(npc: NpcData): Vector3
    local root = npc.instance.PrimaryPart
    return root and root.Position or Vector3.new(0, 0, 0)
end

local function collectNearbyCoins(npc: NpcData)
    local pos = getNpcPosition(npc)
    local now = tick()

    for _, coin in CoinService.getGroundCoins() do
        if npc.purse >= npc.maxPurse then break end
        if coin.claimed or not coin.instance.Parent then continue end
        if now - coin.droppedAt < GameConfig.WORKER_COIN_PICKUP_DELAY then continue end
        if (coin.instance.Position - pos).Magnitude > GameConfig.COIN_PICKUP_RADIUS then continue end
        local canTake = npc.maxPurse - npc.purse
        local amount  = CoinService.claimGroundCoin(coin.instance)
        if amount > 0 then
            npc.purse += math.min(amount, canTake)
        end
    end

    if npc.purse >= npc.maxPurse then
        CoinService.spawnGroundCoins(getNpcPosition(npc), npc.purse, 0)
        npc.purse = 0
    end
end

local NpcService = {}

local function becomeJobless(npc: NpcData, campId: number?)
    npc.profession = "Jobless"
    npc.state      = "Jobless"
    npc.campId     = nil
    setNpcColor(npc, COLOR_JOBLESS)
    if campId then
        _campCounts[campId] = math.max(0, (_campCounts[campId] or 1) - 1)
    end
    local town = WorldService.getTownCenterPos()
    moveNpcTo(npc, town)
    task.spawn(function()
        while npc.state == "Jobless" do
            task.wait(1)
            if (getNpcPosition(npc) - town).Magnitude < 5 then
                npc.state = "IdleAtTown"
                NpcService.assignTool(npc)
                break
            end
        end
    end)
end

-- ── Homeless camp spawning ────────────────────────────────────────────────

local function spawnHomeless(campIdx: number, campPos: Vector3)
    local count = _campCounts[campIdx] or 0
    if count >= GameConfig.CAMP_MAX_VAGRANTS then return end

    local id     = nextId()
    local offset = Vector3.new(math.random(-3, 3), 0, math.random(-3, 3))
    local model  = makeNpcModel("Homeless_" .. id, COLOR_HOMELESS, campPos + offset)

    local npc: NpcData = {
        id = id, instance = model,
        profession = "Homeless", tool = nil,
        purse = 0, maxPurse = 0,
        state = "InCamp", campId = campIdx,
    }
    _npcs[id] = npc
    _campCounts[campIdx] = count + 1

    -- Camp behavior: food (global) > coins (scan radius) > enforce bounds
    task.spawn(function()
        while npc.state == "InCamp" or npc.state == "Wandering" do
            task.wait(0.5)
            if npc.state ~= "InCamp" and npc.state ~= "Wandering" then break end

            local pos = getNpcPosition(npc)

            -- Priority 1: food anywhere on the map — only 1 homeless responds per item
            local foods = WorldService.getAvailableFood()
            if #foods > 0 then
                local nearestFood: BasePart? = nil
                local nearestFoodDist = math.huge
                for _, food in foods do
                    local d = (food.Position - pos).Magnitude
                    if d < nearestFoodDist then
                        nearestFoodDist = d
                        nearestFood     = food
                    end
                end
                if nearestFood and WorldService.reserveFood(nearestFood) then
                    moveNpcTo(npc, nearestFood.Position)
                    local reached   = false
                    local coinHired = false
                    for _ = 1, 40 do
                        task.wait(1)
                        if npc.state ~= "InCamp" and npc.state ~= "Wandering" then break end
                        if not nearestFood.Parent then break end
                        local npcPos = getNpcPosition(npc)
                        for _, coin in CoinService.getGroundCoins() do
                            if coin.claimed or not coin.instance.Parent then continue end
                            if coin.ownerId == 0 then continue end
                            if (coin.instance.Position - npcPos).Magnitude <= GameConfig.COIN_PICKUP_RADIUS then
                                local amount = CoinService.claimGroundCoin(coin.instance)
                                if amount > 0 then
                                    npc.maxPurse = GameConfig.WORKER_PURSE_MAX
                                    npc.purse    = math.min(npc.purse + amount, npc.maxPurse)
                                    nearestFood:SetAttribute("Reserved", false)
                                    coinHired = true
                                end
                                break
                            end
                        end
                        if coinHired then break end
                        if (npcPos - nearestFood.Position).Magnitude < 2 then
                            reached = true
                            break
                        end
                    end
                    if coinHired or (reached and nearestFood.Parent) then
                        if reached then WorldService.consumeFood(nearestFood) end
                        becomeJobless(npc, npc.campId)
                    elseif nearestFood.Parent then
                        nearestFood:SetAttribute("Reserved", false)
                    end
                    continue
                end
            end

            -- Priority 2: player-dropped coin within scan radius
            local coins = CoinService.getGroundCoins()
            local nearestCoin = nil
            local nearestCoinDist = GameConfig.VAGRANT_COIN_SCAN_RADIUS
            for _, coin in coins do
                if coin.claimed or not coin.instance.Parent then continue end
                if coin.ownerId == 0 then continue end
                local d = (coin.instance.Position - pos).Magnitude
                if d < nearestCoinDist then
                    nearestCoinDist = d
                    nearestCoin     = coin
                end
            end
            if nearestCoin then
                moveNpcTo(npc, nearestCoin.instance.Position)
                for _ = 1, 8 do
                    task.wait(0.5)
                    if npc.state ~= "InCamp" and npc.state ~= "Wandering" then break end
                    if nearestCoin.claimed or not nearestCoin.instance.Parent then break end
                    if (getNpcPosition(npc) - nearestCoin.instance.Position).Magnitude < 2 then
                        local amount = CoinService.claimGroundCoin(nearestCoin.instance)
                        if amount > 0 then
                            npc.maxPurse = GameConfig.WORKER_PURSE_MAX
                            npc.purse    = math.min(npc.purse + amount, npc.maxPurse)
                            becomeJobless(npc, npc.campId)
                        end
                        break
                    end
                end
                continue
            end

            -- Nothing nearby: keep homeless inside camp radius
            if npc.state == "InCamp" and (pos - campPos).Magnitude > GameConfig.CAMP_RADIUS then
                moveNpcTo(npc, campPos)
            end
        end
    end)
end

TimeService.onDawn(function(_day)
    local camps = WorldService.getCampPositions()
    for i, campPos in camps do
        local toSpawn = math.random(GameConfig.CAMP_SPAWN_MIN, GameConfig.CAMP_SPAWN_MAX)
        for _ = 1, toSpawn do
            spawnHomeless(i, campPos)
        end
    end
end)

-- ── Hiring logic ──────────────────────────────────────────────────────────

local function tryHireHomeless(player: Player, pos: Vector3)
    for _, npc in _npcs do
        if npc.state ~= "InCamp" and npc.state ~= "Wandering" then continue end
        if (getNpcPosition(npc) - pos).Magnitude > GameConfig.HIRE_COIN_RADIUS then continue end
        if not CoinService.spend(player.UserId, 1) then continue end
        npc.state      = "HiredWalking"
        npc.profession = "Jobless"
        setNpcColor(npc, COLOR_JOBLESS)
        local campIdx = npc.campId
        if campIdx then
            _campCounts[campIdx] = math.max(0, (_campCounts[campIdx] or 1) - 1)
        end
        local town = WorldService.getTownCenterPos()
        moveNpcTo(npc, town)
        print("[NpcService] Homeless hired, walking to town")

        task.spawn(function()
            while npc.state == "HiredWalking" do
                task.wait(1)
                if (getNpcPosition(npc) - town).Magnitude < 5 then
                    npc.state = "IdleAtTown"
                    NpcService.assignTool(npc)
                end
            end
        end)
        return
    end
end

-- ── Public API ────────────────────────────────────────────────────────────

function NpcService.getNpcs(): {NpcData}
    local list = {}
    for _, npc in _npcs do table.insert(list, npc) end
    return list
end

function NpcService.getWorkers(): {NpcData}
    local list = {}
    for _, npc in _npcs do
        if npc.profession == "Builder" then table.insert(list, npc) end
    end
    return list
end

function NpcService.getHomelessNear(pos: Vector3, radius: number): {NpcData}
    local list = {}
    for _, npc in _npcs do
        if npc.profession == "Homeless"
            and (getNpcPosition(npc) - pos).Magnitude <= radius then
            table.insert(list, npc)
        end
    end
    return list
end

-- Dropped tool instances available for pickup (set by hitWorker)
type GroundToolEntry = { instance: BasePart, pos: Vector3 }
local _droppedTools: {GroundToolEntry} = {}

local function startWorkerLoop(npc: NpcData)
    npc.profession = "Builder"
    npc.maxPurse   = GameConfig.BUILDER_PURSE_MAX
    setNpcColor(npc, COLOR_WORKER)
    local humanoid = npc.instance:FindFirstChildOfClass("Humanoid")
    if humanoid then humanoid.WalkSpeed = GameConfig.WORKER_WALK_SPEED end

    task.spawn(function()
        while npc.instance.Parent do
            task.wait(1)
            if not npc.instance.Parent then break end
            if npc.state ~= "Working" then continue end

            local marked = WorldService.getMarkedTrees()
            if #marked == 0 then
                local town = WorldService.getTownCenterPos()
                local r = GameConfig.TOWN_RADIUS
                if (getNpcPosition(npc) - town).Magnitude > r then
                    local angle = math.random() * 2 * math.pi
                    local dist  = math.random() * r
                    moveNpcTo(npc, town + Vector3.new(math.cos(angle) * dist, 0, math.sin(angle) * dist))
                end
                task.wait(5)
                continue
            end

            local nearest: typeof(marked[1])? = nil
            local nearestDist = math.huge
            local myPos = getNpcPosition(npc)
            for _, tree in marked do
                local d = (tree.position - myPos).Magnitude
                if d < nearestDist then
                    nearestDist = d
                    nearest     = tree
                end
            end
            if not nearest then continue end

            moveNpcTo(npc, nearest.position)
            task.wait(nearestDist / GameConfig.WORKER_WALK_SPEED + 1)

            if npc.state ~= "Working" then continue end

            local trees = WorldService.getMarkedTrees()
            local stillValid = false
            for _, t in trees do if t.id == nearest.id then stillValid = true break end end
            if not stillValid then continue end

            task.wait(GameConfig.TREE_CHOP_DURATION)

            if npc.state ~= "Working" then continue end

            local reward = GameConfig.TREE_CHOP_REWARD
            if npc.purse + reward <= npc.maxPurse then
                npc.purse += reward
                print("[NpcService] Worker earned", reward, "coins from chopping")
            end

            WorldService.removeTree(nearest.id)
        end
    end)
end

local function fetchTool(npc: NpcData)
    local town = WorldService.getTownCenterPos()
    local all  = WorldService.getGroundTools()

    local tools = {}
    for _, t in all do
        if (t.instance.Position - town).Magnitude <= GameConfig.TOWN_RADIUS then
            table.insert(tools, t)
        end
    end
    if #tools == 0 then return end

    local myPos   = getNpcPosition(npc)
    local nearest = tools[1]
    for _, t in tools do
        if (t.instance.Position - myPos).Magnitude < (nearest.instance.Position - myPos).Magnitude then
            nearest = t
        end
    end

    npc.state = "FetchingTool"
    moveNpcTo(npc, nearest.instance.Position)
    task.spawn(function()
        for _ = 1, 20 do
            task.wait(0.5)
            if npc.state ~= "FetchingTool" then return end
            if not nearest.instance.Parent then
                npc.state = "IdleAtTown"
                return
            end
            if (getNpcPosition(npc) - nearest.instance.Position).Magnitude < 3 then
                WorldService.removeGroundTool(nearest.instance)
                nearest.instance:Destroy()
                npc.state = "Working"
                startWorkerLoop(npc)
                print("[NpcService] Jobless picked up tool, became Worker")
                return
            end
        end
        npc.state = "IdleAtTown"
    end)
end

function NpcService.assignTool(npc: NpcData)
    npc.state = "IdleAtTown"
    local town = WorldService.getTownCenterPos()

    -- Wander visibly inside town while waiting for a tool
    task.spawn(function()
        while npc.state == "IdleAtTown" do
            task.wait(math.random(3, 7))
            if npc.state ~= "IdleAtTown" then break end
            local angle = math.random() * 2 * math.pi
            local dist  = math.random() * GameConfig.TOWN_RADIUS
            moveNpcTo(npc, town + Vector3.new(math.cos(angle) * dist, 0, math.sin(angle) * dist))
        end
    end)

    -- Poll for a tool inside town boundary
    task.spawn(function()
        while npc.state == "IdleAtTown" do
            task.wait(1)
            if npc.state ~= "IdleAtTown" then break end
            local inTown = false
            for _, t in WorldService.getGroundTools() do
                if (t.instance.Position - town).Magnitude <= GameConfig.TOWN_RADIUS then
                    inTown = true
                    break
                end
            end
            if inTown then
                fetchTool(npc)
                break
            end
        end
    end)
end

function NpcService.hitWorker(npc: NpcData)
    if npc.state == "Toolless" then
        -- Second hit: become jobless, wander town
        npc.profession = "Jobless"
        npc.state      = "Wandering"
        npc.tool       = nil
        npc.campId     = nil
        setNpcColor(npc, COLOR_JOBLESS)
        print("[NpcService] Worker lost job, now Jobless")
        NpcService.assignTool(npc)
        return
    end

    -- First hit: drop tool
    npc.state = "Toolless"
    local pos = getNpcPosition(npc)
    local p   = Instance.new("Part")
    p.Name    = "DroppedTool"
    p.Size    = Vector3.new(1, 1, 3)
    p.BrickColor = BrickColor.new("Medium stone grey")
    p.Anchored   = true
    p.CanCollide = false
    p.Position = pos + Vector3.new(0, 0.5, 0)
    p.Parent  = workspace
    p:SetAttribute("ToolType", "Hammer")
    WorldService.registerGroundTool(p, pos)
    npc.tool  = nil
    print("[NpcService] Worker dropped tool")
end

function NpcService.tryHireFromDrop(player: Player, pos: Vector3)
    tryHireHomeless(player, pos)
end

-- Periodic coin collection for workers
task.spawn(function()
    while true do
        task.wait(2)
        for _, npc in _npcs do
            if npc.profession == "Builder" and npc.state == "Working" then
                collectNearbyCoins(npc)
            end
        end
    end
end)

-- Initial spawn: seed each camp with homeless on game start
task.delay(1, function()
    local camps = WorldService.getCampPositions()
    for i, campPos in camps do
        spawnHomeless(i, campPos)
    end
end)

TimeService.onDusk(function()
    local wallPos = GameConfig.TOWN_CENTER_POS
    for _, npc in _npcs do
        if npc.profession ~= "Homeless" then
            npc.state = "ReturningToWalls"
            moveNpcTo(npc, wallPos + Vector3.new(math.random(-5,5), 0, math.random(-5,5)))
            task.delay(5, function()
                if npc.state == "ReturningToWalls" then npc.state = "AtWalls" end
            end)
        end
    end
end)

TimeService.onDawn(function(_day)
    for _, npc in _npcs do
        if npc.profession == "Builder" then
            npc.state = "Working"
            print("[NpcService] Worker ready on day", _day)
        end
    end
end)

return NpcService
