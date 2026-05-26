local GameConfig   = require(game:GetService("ReplicatedStorage").Shared.GameConfig)
local Remotes      = require(game:GetService("ReplicatedStorage").Shared.Remotes)
local CoinService  = require(script.Parent.CoinService)
local WorldService = require(script.Parent.WorldService)
local TimeService  = require(script.Parent.TimeService)
local TweenService = game:GetService("TweenService")
local Players      = game:GetService("Players")

-- Lazy-loaded to avoid require ordering issues with AnimalService
local _AnimalService: any = nil
local function getAnimalService()
    if not _AnimalService then
        _AnimalService = require(script.Parent.AnimalService)
    end
    return _AnimalService
end

-- Tower occupancy registry: tower BasePart → occupying npc id
local _towerSlots: {[BasePart]: string} = {}

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
local COLOR_HUNTER   = BrickColor.new("Bright green")

-- Maps rack tool type → profession name
local TOOL_TO_PROFESSION: {[string]: string} = {
    Hammer = "Builder",
    Bow    = "Hunter",
}

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
    root.CanCollide     = false  -- NPCs phase through obstacles; Humanoid handles floor grounding
    root.CollisionGroup = "Friendly"
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

local function setNpcSpeed(npc: NpcData, speed: number)
    local humanoid = npc.instance:FindFirstChildOfClass("Humanoid")
    if humanoid then humanoid.WalkSpeed = speed end
end

local function moveNpcTo(npc: NpcData, target: Vector3)
    local humanoid = npc.instance:FindFirstChildOfClass("Humanoid")
    if humanoid then humanoid:MoveTo(target) end
end

local function getNpcPosition(npc: NpcData): Vector3
    local root = npc.instance.PrimaryPart
    return root and root.Position or Vector3.new(0, 0, 0)
end

-- When stuck against an obstacle, sidestep 5 studs perpendicular to the target
-- direction (randomly left or right) then re-issue the real target.
local function nudgeAroundObstacle(npc: NpcData, target: Vector3)
    local myPos   = getNpcPosition(npc)
    local flatDir = Vector3.new(target.X - myPos.X, 0, target.Z - myPos.Z)
    if flatDir.Magnitude < 0.5 then return end
    local forward = flatDir.Unit
    local side    = (math.random() < 0.5)
                    and Vector3.new(-forward.Z, 0, forward.X)
                    or  Vector3.new( forward.Z, 0, -forward.X)
    moveNpcTo(npc, myPos + side * 5 + forward)
end

local function collectNearbyCoins(npc: NpcData)
    local pos = getNpcPosition(npc)
    local now = tick()

    for _, coin in CoinService.getGroundCoins() do
        if npc.purse >= npc.maxPurse then break end
        if coin.claimed or not coin.instance.Parent then continue end
        if coin.ownerId > 0 and now - coin.droppedAt < GameConfig.WORKER_COIN_PICKUP_DELAY then continue end
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

-- Returns the nearest gate waypoint when the NPC is outside town, otherwise town center.
-- Ensures NPCs approach town through the 4 cardinal gate openings once walls are solid.
local function townWaypoint(fromPos: Vector3): Vector3
    local town = WorldService.getTownCenterPos()
    if (fromPos - town).Magnitude <= GameConfig.TOWN_RADIUS + 4 then
        return town
    end
    local gates = WorldService.getGatePositions()
    local nearest = gates[1]
    local nearestDist = math.huge
    for _, g in gates do
        local d = (fromPos - g).Magnitude
        if d < nearestDist then nearestDist = d; nearest = g end
    end
    return nearest
end

local function becomeJobless(npc: NpcData, campId: number?)
    npc.profession = "Jobless"
    npc.state      = "Jobless"
    npc.campId     = nil
    setNpcColor(npc, COLOR_JOBLESS)
    setNpcSpeed(npc, GameConfig.NPC_RUN_SPEED)  -- run to town
    if campId then
        _campCounts[campId] = math.max(0, (_campCounts[campId] or 1) - 1)
    end
    local town = WorldService.getTownCenterPos()
    moveNpcTo(npc, townWaypoint(getNpcPosition(npc)))
    task.spawn(function()
        local lastJoblessPos = getNpcPosition(npc)
        while npc.state == "Jobless" do
            task.wait(1)
            if (getNpcPosition(npc) - town).Magnitude < 10 then
                npc.state = "IdleAtTown"
                NpcService.assignTool(npc)
                break
            end
            local curPos = getNpcPosition(npc)
            local dest   = townWaypoint(curPos)
            if (curPos - lastJoblessPos).Magnitude < 1.5 then
                nudgeAroundObstacle(npc, dest)
            else
                moveNpcTo(npc, dest)
            end
            lastJoblessPos = curPos
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

    task.spawn(function()
        local lastWanderAt = 0
        while npc.state == "InCamp" or npc.state == "Wandering" do
            task.wait(0.5)
            if npc.state ~= "InCamp" and npc.state ~= "Wandering" then break end

            local pos = getNpcPosition(npc)

            -- Priority 1: food anywhere on the map
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
                    setNpcSpeed(npc, GameConfig.NPC_RUN_SPEED)
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
                        continue  -- becomeJobless owns speed from here
                    elseif nearestFood.Parent then
                        nearestFood:SetAttribute("Reserved", false)
                    end
                    setNpcSpeed(npc, GameConfig.VAGRANT_WALK_SPEED)
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
                setNpcSpeed(npc, GameConfig.NPC_RUN_SPEED)
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
                -- Only reset speed if becomeJobless wasn't called
                if npc.state == "InCamp" or npc.state == "Wandering" then
                    setNpcSpeed(npc, GameConfig.VAGRANT_WALK_SPEED)
                end
                continue
            end

            -- Nothing nearby: slow wander within camp, 5-10s between moves
            if npc.state == "InCamp" then
                local now = tick()
                if now - lastWanderAt >= math.random(5, 10) then
                    lastWanderAt = now
                    setNpcSpeed(npc, GameConfig.VAGRANT_WALK_SPEED)
                    local angle = math.random() * 2 * math.pi
                    local dist  = math.random() * GameConfig.CAMP_RADIUS
                    moveNpcTo(npc, campPos + Vector3.new(math.cos(angle) * dist, 0, math.sin(angle) * dist))
                end
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
        setNpcSpeed(npc, GameConfig.NPC_RUN_SPEED)  -- run to town
        local campIdx = npc.campId
        if campIdx then
            _campCounts[campIdx] = math.max(0, (_campCounts[campIdx] or 1) - 1)
        end
        local town = WorldService.getTownCenterPos()
        moveNpcTo(npc, townWaypoint(getNpcPosition(npc)))
        print("[NpcService] Homeless hired, walking to town")

        task.spawn(function()
            local lastHiredPos = getNpcPosition(npc)
            while npc.state == "HiredWalking" do
                task.wait(1)
                if (getNpcPosition(npc) - town).Magnitude < 10 then
                    npc.state = "IdleAtTown"
                    NpcService.assignTool(npc)
                    break
                end
                local curPos = getNpcPosition(npc)
                local dest   = townWaypoint(curPos)
                if (curPos - lastHiredPos).Magnitude < 1.5 then
                    nudgeAroundObstacle(npc, dest)
                else
                    moveNpcTo(npc, dest)
                end
                lastHiredPos = curPos
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
    npc.state      = "Working"
    setNpcColor(npc, COLOR_WORKER)

    task.spawn(function()
        while npc.instance.Parent do
            task.wait(1)
            if not npc.instance.Parent then break end
            if npc.state ~= "Working" then continue end

            local myPos    = getNpcPosition(npc)
            local marked   = WorldService.getMarkedTrees()
            local buildJobs = WorldService.getAvailableBuildJobs()

            if #marked == 0 and #buildJobs == 0 then
                -- Nothing to do: slow wander; pick a target and re-issue every 2s so the
                -- NPC doesn't freeze if Humanoid:MoveTo times out (8s Roblox limit) or hits an obstacle
                setNpcSpeed(npc, GameConfig.NPC_WANDER_SPEED)
                local town  = WorldService.getTownCenterPos()
                local r     = GameConfig.TOWN_RADIUS
                local angle = math.random() * 2 * math.pi
                local dist  = r * (0.5 + math.random() * 0.4)
                local wanderTarget = town + Vector3.new(math.cos(angle) * dist, 0, math.sin(angle) * dist)
                moveNpcTo(npc, wanderTarget)
                local lastCheckPos = getNpcPosition(npc)
                for _ = 1, 3 do  -- up to 6 seconds total before re-picking
                    task.wait(2)
                    if npc.state ~= "Working" then break end
                    local curPos = getNpcPosition(npc)
                    if (curPos - wanderTarget).Magnitude < 4 then break end
                    if (curPos - lastCheckPos).Magnitude < 1.5 then
                        nudgeAroundObstacle(npc, wanderTarget)
                    else
                        moveNpcTo(npc, wanderTarget)  -- re-issue in case of MoveTo timeout
                    end
                    lastCheckPos = curPos
                end
                continue
            end

            -- Find nearest unclaimed marked tree (1 builder per tree)
            local nearestTree: typeof(marked[1])? = nil
            local nearestTreeDist = math.huge
            for _, tree in marked do
                if WorldService.isTreeClaimed(tree.id) then continue end
                local d = (tree.position - myPos).Magnitude
                if d < nearestTreeDist then
                    nearestTreeDist = d
                    nearestTree = tree
                end
            end

            -- Find nearest available build job
            local nearestJob: { instance: BasePart, position: Vector3 }? = nil
            local nearestJobDist = math.huge
            for _, job in buildJobs do
                local d = (job.position - myPos).Magnitude
                if d < nearestJobDist then
                    nearestJobDist = d
                    nearestJob = job
                end
            end

            if nearestTree and (not nearestJob or nearestTreeDist <= nearestJobDist) then
                -- ── Chop tree ────────────────────────────────────────────────
                -- Claim first; if another builder beat us to it, skip this tick
                if not WorldService.claimTree(nearestTree.id) then continue end

                setNpcSpeed(npc, GameConfig.NPC_RUN_SPEED)
                local treeTarget = nearestTree.position
                moveNpcTo(npc, treeTarget)
                do  -- travel with stuck detection
                    local deadline    = tick() + nearestTreeDist / GameConfig.NPC_RUN_SPEED + 4
                    local lastTPos    = getNpcPosition(npc)
                    while tick() < deadline and npc.state == "Working" do
                        task.wait(1)
                        local cur = getNpcPosition(npc)
                        if (cur - treeTarget).Magnitude < 5 then break end
                        if (cur - lastTPos).Magnitude < 1.5 then
                            nudgeAroundObstacle(npc, treeTarget)
                        else
                            moveNpcTo(npc, treeTarget)
                        end
                        lastTPos = cur
                    end
                end
                if npc.state ~= "Working" then
                    WorldService.releaseTreeClaim(nearestTree.id)
                    continue
                end

                -- Re-verify tree still exists after travel
                local trees = WorldService.getMarkedTrees()
                local stillValid = false
                for _, t in trees do if t.id == nearestTree.id then stillValid = true break end end
                if not stillValid then
                    WorldService.releaseTreeClaim(nearestTree.id)
                    continue
                end

                task.wait(GameConfig.TREE_CHOP_DURATION)
                if npc.state ~= "Working" then
                    WorldService.releaseTreeClaim(nearestTree.id)
                    continue
                end

                -- Only pay if we actually removed the tree (guards against any edge-case double-chop)
                local removed = WorldService.removeTree(nearestTree.id)
                if removed then
                    local choppedAt = getNpcPosition(npc)
                    for _ = 1, GameConfig.TREE_CHOP_REWARD do
                        CoinService.spawnGroundCoins(choppedAt, 1, 0, true)
                    end
                    task.wait(0.2)
                    collectNearbyCoins(npc)
                end

            elseif nearestJob then
                -- ── Build structure / repair boat ─────────────────────────
                local target = nearestJob.instance
                local curB   = target:GetAttribute("CurrentBuilders") or 0
                local maxB   = target:GetAttribute("MaxBuilders") or 1
                if curB >= maxB then continue end  -- slot just got taken
                target:SetAttribute("CurrentBuilders", curB + 1)

                setNpcSpeed(npc, GameConfig.NPC_RUN_SPEED)
                local jobTarget = nearestJob.position
                moveNpcTo(npc, jobTarget)
                do  -- travel with stuck detection
                    local deadline = tick() + nearestJobDist / GameConfig.NPC_RUN_SPEED + 4
                    local lastJPos = getNpcPosition(npc)
                    while tick() < deadline and npc.state == "Working" do
                        task.wait(1)
                        local cur = getNpcPosition(npc)
                        if (cur - jobTarget).Magnitude < 5 then break end
                        if (cur - lastJPos).Magnitude < 1.5 then
                            nudgeAroundObstacle(npc, jobTarget)
                        else
                            moveNpcTo(npc, jobTarget)
                        end
                        lastJPos = cur
                    end
                end

                if npc.state ~= "Working" then
                    if target.Parent then
                        target:SetAttribute("CurrentBuilders",
                            math.max(0, (target:GetAttribute("CurrentBuilders") or 1) - 1))
                    end
                    continue
                end

                -- Progress loop: each builder contributes 1/s until complete
                while npc.state == "Working" and target.Parent do
                    if target:GetAttribute("Level") ~= 0 then break end
                    local progress = (target:GetAttribute("BuildProgress") or 0) + 1
                    local required = target:GetAttribute("BuildRequired") or GameConfig.STRUCTURE_BUILD_DURATION
                    target:SetAttribute("BuildProgress", progress)
                    if progress >= required then
                        if target:GetAttribute("Level") == 0 then
                            if target.Name == "BrokenBoat" then
                                WorldService.repairBoat(target)
                            else
                                WorldService.markStructureBuilt(target)
                            end
                        end
                        break
                    end
                    moveNpcTo(npc, target.Position)
                    task.wait(1)
                end

                if target.Parent then
                    target:SetAttribute("CurrentBuilders",
                        math.max(0, (target:GetAttribute("CurrentBuilders") or 1) - 1))
                end
            end
        end
    end)
end

-- Returns the first built tower with an open occupant slot, or nil.
local function findOpenTower(): BasePart?
    for _, child in workspace:GetChildren() do
        if not child:IsA("BasePart") then continue end
        if child:GetAttribute("StructureType") ~= "Tower" then continue end
        if (child:GetAttribute("Level") or 0) == 0 then continue end
        if (child:GetAttribute("MaxOccupants") or 0) < 1 then continue end
        if _towerSlots[child :: BasePart] then continue end
        return child :: BasePart
    end
    return nil
end

-- Fires a brief arrow tween from fromPos to toPos (synchronous — waits for arrival).
local function fireArrow(fromPos: Vector3, toPos: Vector3)
    local dir  = toPos - fromPos
    local dist = dir.Magnitude
    if dist < 1 then return end
    local mid = fromPos + dir * 0.5

    local arrow = Instance.new("Part")
    arrow.Name       = "Arrow"
    arrow.Size       = Vector3.new(0.12, 0.12, math.clamp(dist * 0.35, 0.5, 2.5))
    arrow.BrickColor = BrickColor.new("Reddish brown")
    arrow.Material   = Enum.Material.Wood
    arrow.Anchored   = true
    arrow.CanCollide = false
    arrow.CastShadow = false
    arrow.CFrame     = CFrame.lookAt(fromPos, toPos) * CFrame.new(0, 0, -(dist * 0.5 - arrow.Size.Z * 0.5))
    arrow.Parent     = workspace

    local t = TweenService:Create(arrow,
        TweenInfo.new(GameConfig.HUNTER_SHOOT_DELAY, Enum.EasingStyle.Linear),
        { CFrame = CFrame.lookAt(mid + dir * 0.5, fromPos) * CFrame.new(0, 0, arrow.Size.Z * 0.5) })
    t:Play()
    t.Completed:Wait()
    arrow:Destroy()
end

local function startHunterLoop(npc: NpcData)
    npc.profession = "Hunter"
    npc.maxPurse   = GameConfig.HUNTER_PURSE_MAX
    npc.state      = "Working"
    setNpcColor(npc, COLOR_HUNTER)

    -- Generation counter prevents stale loops after dusk/dawn or re-assign
    local data = npc :: any
    local gen  = (data._hunterGen or 0) + 1
    data._hunterGen = gen

    task.spawn(function()
        local occupiedTower: BasePart? = nil   -- tower this hunter currently occupies
        local lastArcherShot = 0

        while npc.instance.Parent and (npc :: any)._hunterGen == gen do
            task.wait(1)
            if not npc.instance.Parent then break end
            local state = npc.state

            -- ── TowerArcher branch ────────────────────────────────────────
            if state == "TowerArcher" then
                if not occupiedTower or not occupiedTower.Parent then
                    if occupiedTower then _towerSlots[occupiedTower] = nil end
                    occupiedTower = nil
                    npc.state     = "Working"
                    continue
                end
                -- Shoot nearest animal in range, ~2s cadence
                if tick() - lastArcherShot >= 2 then
                    local towerPos  = occupiedTower.Position + Vector3.new(0, 2, 0)
                    local AnimalSvc = getAnimalService()
                    local nearest: any = nil
                    local nearestDist  = GameConfig.HUNTER_SHOOT_RANGE
                    for _, a in AnimalSvc.getAnimals() do
                        local d = (a.position - towerPos).Magnitude
                        if d < nearestDist then nearestDist = d; nearest = a end
                    end
                    if nearest then
                        local root = nearest.instance.PrimaryPart
                        if root then
                            lastArcherShot = tick()
                            task.spawn(function()
                                fireArrow(towerPos, root.Position + Vector3.new(0, 0.75, 0))
                                AnimalSvc.killAnimal(nearest.id)
                            end)
                        end
                    end
                end
                collectNearbyCoins(npc)
                continue
            end

            if state ~= "Working" then continue end

            local myPos = getNpcPosition(npc)

            -- ── Priority 1: fill an open built tower ──────────────────────
            local openTower = findOpenTower()
            if openTower then
                local d = (openTower.Position - myPos).Magnitude
                if d <= GameConfig.TOWER_OCCUPY_DIST then
                    -- Claim slot (guard against two hunters racing)
                    if not _towerSlots[openTower] then
                        _towerSlots[openTower] = npc.id
                        occupiedTower          = openTower
                        npc.state              = "TowerArcher"
                        setNpcSpeed(npc, GameConfig.NPC_RUN_SPEED)
                        moveNpcTo(npc, openTower.Position)
                        print("[NpcService] Hunter entered tower →", openTower.Name)
                    end
                else
                    setNpcSpeed(npc, GameConfig.NPC_RUN_SPEED)
                    moveNpcTo(npc, openTower.Position)
                end
                continue
            end

            -- ── Priority 2: hunt animals ──────────────────────────────────
            local AnimalSvc = getAnimalService()
            local animals   = AnimalSvc.getAnimals()

            if #animals == 0 then
                -- Nothing to hunt: patrol outer ring
                setNpcSpeed(npc, GameConfig.NPC_WANDER_SPEED)
                local town  = WorldService.getTownCenterPos()
                local r     = GameConfig.ISLAND_RADIUS_BY_ISLAND[1] * 0.45
                local angle = math.random() * 2 * math.pi
                moveNpcTo(npc, town + Vector3.new(math.cos(angle) * r, 0, math.sin(angle) * r))
                task.wait(3)
                continue
            end

            -- Find nearest animal
            local nearest: any = nil
            local nearestDist  = math.huge
            for _, a in animals do
                local d = (a.position - myPos).Magnitude
                if d < nearestDist then nearestDist = d; nearest = a end
            end
            if not nearest then continue end

            -- Chase until in shoot range
            if nearestDist > GameConfig.HUNTER_SHOOT_RANGE then
                setNpcSpeed(npc, GameConfig.NPC_RUN_SPEED)
                local dir     = (nearest.position - myPos)
                local stopPos = nearest.position - (dir.Magnitude > 0.1 and dir.Unit * (GameConfig.HUNTER_SHOOT_RANGE * 0.7) or Vector3.zero)
                moveNpcTo(npc, stopPos)

                local deadline = tick() + nearestDist / GameConfig.NPC_RUN_SPEED + 4
                local lastPos  = getNpcPosition(npc)
                local inRange  = false
                while tick() < deadline and npc.state == "Working" do
                    task.wait(0.5)
                    -- Confirm animal still alive
                    local alive = false
                    for _, a in AnimalSvc.getAnimals() do
                        if a.id == nearest.id then alive = true break end
                    end
                    if not alive then break end
                    local curPos    = getNpcPosition(npc)
                    local root      = nearest.instance.PrimaryPart
                    local animalPos = root and root.Position or nearest.position
                    if (curPos - animalPos).Magnitude <= GameConfig.HUNTER_SHOOT_RANGE then
                        inRange = true; break
                    end
                    if (curPos - lastPos).Magnitude < 0.8 then
                        nudgeAroundObstacle(npc, animalPos)
                    else
                        local d2 = animalPos - curPos
                        if d2.Magnitude > 0.1 then
                            moveNpcTo(npc, animalPos - d2.Unit * (GameConfig.HUNTER_SHOOT_RANGE * 0.7))
                        end
                    end
                    lastPos = curPos
                end
                if not inRange or npc.state ~= "Working" then continue end
            end

            -- Confirm still in range and alive before shooting
            local animalRoot = nearest.instance and nearest.instance.PrimaryPart
            if not animalRoot or not nearest.instance.Parent then continue end
            if (animalRoot.Position - getNpcPosition(npc)).Magnitude > GameConfig.HUNTER_SHOOT_RANGE then continue end

            -- Fire arrow (synchronous wait for projectile)
            fireArrow(getNpcPosition(npc) + Vector3.new(0, 1.5, 0),
                      animalRoot.Position  + Vector3.new(0, 0.75, 0))
            if npc.state ~= "Working" then continue end

            local deathPos = AnimalSvc.killAnimal(nearest.id)
            if not deathPos then continue end  -- already killed by another hunter

            -- Walk to collect coins at death site
            setNpcSpeed(npc, GameConfig.NPC_WANDER_SPEED)
            moveNpcTo(npc, deathPos)
            local deadline = tick() + 8
            while tick() < deadline and npc.state == "Working" do
                task.wait(0.5)
                if (getNpcPosition(npc) - deathPos).Magnitude < 3 then break end
            end
            if npc.state == "Working" then collectNearbyCoins(npc) end
        end

        -- Cleanup: release tower slot when loop exits
        if occupiedTower and _towerSlots[occupiedTower] == npc.id then
            _towerSlots[occupiedTower] = nil
        end
    end)
end

local function fetchTool(npc: NpcData)
    local myPos = getNpcPosition(npc)
    local town  = WorldService.getTownCenterPos()

    -- Priority 1: shop racks (player-stocked tools)
    local racks = WorldService.getShopsWithTools()

    -- Priority 2: dropped tools on the ground within town (from worker-hit mechanic)
    local groundTools = {}
    for _, t in WorldService.getGroundTools() do
        if (t.instance.Position - town).Magnitude <= GameConfig.TOWN_RADIUS then
            table.insert(groundTools, t)
        end
    end

    if #racks == 0 and #groundTools == 0 then return end

    -- Find nearest rack
    local nearestRack: BasePart? = nil
    local nearestRackDist = math.huge
    for _, r in racks do
        local d = (r.Position - myPos).Magnitude
        if d < nearestRackDist then nearestRackDist = d; nearestRack = r end
    end

    -- Find nearest ground tool
    local nearestGround: { instance: BasePart, position: Vector3 }? = nil
    local nearestGroundDist = math.huge
    for _, t in groundTools do
        local d = (t.instance.Position - myPos).Magnitude
        if d < nearestGroundDist then nearestGroundDist = d; nearestGround = t end
    end

    -- Prefer rack (player-controlled supply); fall back to dropped ground tool
    if nearestRack and (nearestGround == nil or nearestRackDist <= nearestGroundDist) then
        npc.state = "FetchingTool"
        setNpcSpeed(npc, GameConfig.NPC_RUN_SPEED)
        local inward = (town - nearestRack.Position).Unit
        moveNpcTo(npc, nearestRack.Position + inward * 3)
        task.spawn(function()
            for _ = 1, 30 do
                task.wait(0.5)
                if npc.state ~= "FetchingTool" then return end
                if not nearestRack.Parent then NpcService.assignTool(npc) return end
                if (getNpcPosition(npc) - nearestRack.Position).Magnitude < 10 then
                    local toolType = WorldService.takeToolFromRack(nearestRack)
                    if not toolType then
                        -- Another NPC claimed it first; re-poll
                        NpcService.assignTool(npc)
                        return
                    end
                    local profession = TOOL_TO_PROFESSION[toolType] or "Builder"
                    if profession == "Hunter" then
                        startHunterLoop(npc)
                    else
                        startWorkerLoop(npc)
                    end
                    print("[NpcService] Jobless picked up", toolType, "→", profession)
                    return
                end
            end
            NpcService.assignTool(npc)
        end)

    elseif nearestGround then
        -- Dropped tool (from hit worker) — always makes a Builder
        npc.state = "FetchingTool"
        setNpcSpeed(npc, GameConfig.NPC_RUN_SPEED)
        moveNpcTo(npc, nearestGround.instance.Position)
        task.spawn(function()
            for _ = 1, 30 do
                task.wait(0.5)
                if npc.state ~= "FetchingTool" then return end
                if not nearestGround.instance.Parent then NpcService.assignTool(npc) return end
                if (getNpcPosition(npc) - nearestGround.instance.Position).Magnitude < 3 then
                    WorldService.removeGroundTool(nearestGround.instance)
                    nearestGround.instance:Destroy()
                    npc.state = "Working"
                    startWorkerLoop(npc)
                    print("[NpcService] Jobless picked up dropped tool, became Builder")
                    return
                end
            end
            NpcService.assignTool(npc)
        end)
    end
end

function NpcService.assignTool(npc: NpcData)
    npc.state = "IdleAtTown"
    local town = WorldService.getTownCenterPos()

    -- Generation counter: any previous assignTool loop sees the bump and exits
    local data = npc :: any
    local gen  = (data._gen or 0) + 1
    data._gen  = gen

    task.spawn(function()
        local lastWander  = 0
        local wanderDelay = math.random(1, 3)
        local lastWanderTarget = town
        local lastWanderPos    = getNpcPosition(npc)
        while npc.state == "IdleAtTown" and (npc :: any)._gen == gen do
            if npc.state ~= "IdleAtTown" or (npc :: any)._gen ~= gen then break end

            -- Tool check is FIRST — tools are priority #1 for idle jobless
            local hasTools = #WorldService.getShopsWithTools() > 0
            if not hasTools then
                for _, t in WorldService.getGroundTools() do
                    if (t.instance.Position - town).Magnitude <= GameConfig.TOWN_RADIUS then
                        hasTools = true
                        break
                    end
                end
            end
            if hasTools then
                fetchTool(npc)
                if npc.state == "FetchingTool" then break end
            end

            -- Wander when no tools available; re-issue MoveTo every half-second to beat
            -- the 8s Roblox MoveTo timeout and push through minor obstacles
            local now = tick()
            if now - lastWander >= wanderDelay then
                lastWander        = now
                wanderDelay       = math.random(2, 4)
                setNpcSpeed(npc, GameConfig.NPC_WANDER_SPEED)
                local angle = math.random() * 2 * math.pi
                local dist  = math.random() * (GameConfig.TOWN_RADIUS * 0.45)
                lastWanderTarget  = town + Vector3.new(math.cos(angle) * dist, 0, math.sin(angle) * dist)
                lastWanderPos     = getNpcPosition(npc)
                moveNpcTo(npc, lastWanderTarget)
            else
                -- Re-issue if stuck (hasn't moved 1.5 studs since last wander tick)
                local curPos = getNpcPosition(npc)
                if (curPos - lastWanderPos).Magnitude < 1.5 then
                    nudgeAroundObstacle(npc, lastWanderTarget)
                end
                lastWanderPos = curPos
            end

            task.wait(0.5)
        end
    end)
end

function NpcService.hitWorker(npc: NpcData)
    if npc.state == "Toolless" then
        npc.profession = "Jobless"
        npc.state      = "Wandering"
        npc.tool       = nil
        npc.campId     = nil
        setNpcColor(npc, COLOR_JOBLESS)
        print("[NpcService] Worker lost job, now Jobless")
        NpcService.assignTool(npc)
        return
    end

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

-- Periodic coin collection: builders + jobless passively pick up ground coins while moving
task.spawn(function()
    while true do
        task.wait(2)
        for _, npc in _npcs do
            if npc.profession == "Builder" and npc.state == "Working" then
                collectNearbyCoins(npc)
            elseif npc.profession == "Hunter"
                and (npc.state == "Working" or npc.state == "TowerArcher") then
                collectNearbyCoins(npc)
            elseif npc.profession == "Jobless"
                and (npc.state == "IdleAtTown" or npc.state == "FetchingTool") then
                collectNearbyCoins(npc)
            end
        end
    end
end)

-- Player proximity dump: NPC awards coins directly to player and fires the
-- NpcCoinDump event so the client plays a coin-arc animation (same style as buying).
task.spawn(function()
    while true do
        task.wait(0.5)
        for _, npc in _npcs do
            if npc.purse <= 1 then continue end
            local npcPos = getNpcPosition(npc)
            for _, player in Players:GetPlayers() do
                local char = player.Character
                if not char or not char.PrimaryPart then continue end
                if (char.PrimaryPart.Position - npcPos).Magnitude > GameConfig.NPC_DUMP_RADIUS then continue end
                local dumpAmt = npc.purse - 1
                npc.purse -= dumpAmt
                local received = CoinService.award(player.UserId, dumpAmt)
                local overflow = dumpAmt - received
                if overflow > 0 then
                    -- Bag full: scatter overflow near the NPC so it doesn't vanish
                    CoinService.spawnGroundCoins(npcPos, overflow, 0, true)
                end
                -- Fire animation event — client plays arc from NPC to player
                Remotes.NpcCoinDump:FireClient(player, npcPos, received)
                break  -- dump to one player at a time
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
    -- Clear tower occupancy before state changes so slots reopen at dawn
    local occupiedTowers = {}
    for tower in _towerSlots do table.insert(occupiedTowers, tower) end
    for _, tower in occupiedTowers do _towerSlots[tower] = nil end
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
            print("[NpcService] Builder ready on day", _day)
        elseif npc.profession == "Hunter" then
            -- startHunterLoop bumps gen and spawns a fresh loop
            startHunterLoop(npc)
            print("[NpcService] Hunter ready on day", _day)
        end
    end
end)

return NpcService
