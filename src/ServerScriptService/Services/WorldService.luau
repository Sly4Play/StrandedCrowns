local GameConfig = require(game:GetService("ReplicatedStorage").Shared.GameConfig)

local _fireLitEvent = Instance.new("BindableEvent")

type GroundTool = { instance: BasePart, position: Vector3 }
local _groundTools: {GroundTool} = {}

type TreeData = {
    id: string, instance: Model, position: Vector3,
    isMarked: boolean, markerId: number?, markCost: number,
}
local _trees: {[string]: TreeData} = {}

local _campPositions: {Vector3} = {}
local _portals: {BasePart} = {}
local _hammerShopSpawned = false

local WorldService = {}

local function randXZ(rng: Random, radius: number, yHeight: number): Vector3
    local angle = rng:NextNumber(0, 2 * math.pi)
    local dist  = rng:NextNumber(20, radius)
    return Vector3.new(math.cos(angle) * dist, yHeight, math.sin(angle) * dist)
end

local function tooClose(pos: Vector3, others: {Vector3}, minDist: number): boolean
    for _, other in others do
        if (pos - other).Magnitude < minDist then return true end
    end
    return false
end

local function makePortal(pos: Vector3): BasePart
    local p      = Instance.new("Part")
    p.Name       = "Portal"
    p.Size       = Vector3.new(6, 8, 6)
    p.BrickColor = BrickColor.new("Dark indigo")
    p.Material   = Enum.Material.Neon
    p.Anchored   = true
    p.Position   = pos + Vector3.new(0, 4, 0)
    p.Parent     = workspace
    return p
end

local function makeTree(id: string, pos: Vector3): Model
    local model = Instance.new("Model")
    model.Name  = "Tree_" .. id

    local trunk      = Instance.new("Part")
    trunk.Name       = "Trunk"
    trunk.Size       = Vector3.new(1, 4, 1)
    trunk.BrickColor = BrickColor.new("Reddish brown")
    trunk.Anchored   = true
    trunk.Position   = pos + Vector3.new(0, 2, 0)
    trunk.Parent     = model

    local leaves      = Instance.new("Part")
    leaves.Name       = "Leaves"
    leaves.Size       = Vector3.new(4, 4, 4)
    leaves.BrickColor = BrickColor.new("Bright green")
    leaves.Anchored   = true
    leaves.Position   = pos + Vector3.new(0, 6, 0)
    leaves.Parent     = model

    model.PrimaryPart = trunk
    model.Parent      = workspace
    return model
end

local function makeHammerShop(pos: Vector3): BasePart
    local p      = Instance.new("Part")
    p.Name       = "HammerShop"
    p.Size       = Vector3.new(4, 4, 4)
    p.BrickColor = BrickColor.new("Bright orange")
    p.Anchored   = true
    p.Position   = pos + Vector3.new(0, 2, 16)
    p.Parent     = workspace
    p:SetAttribute("ShopType", "Hammer")
    return p
end

local function makeMound(pos: Vector3)
    local p      = Instance.new("Part")
    p.Name       = "Mound"
    p.Size       = Vector3.new(3, 0.5, 3)
    p.BrickColor = BrickColor.new("Brown")
    p.Anchored   = true
    p.Position   = pos + Vector3.new(0, 0.25, 0)
    p.Parent     = workspace
end

function WorldService.buildIsland()
    local rng    = Random.new(os.time())
    local center = GameConfig.TOWN_CENTER_POS
    local radius = GameConfig.ISLAND_RADIUS

    local pn = makePortal(GameConfig.PORTAL_NORTH_POS)
    local ps = makePortal(GameConfig.PORTAL_SOUTH_POS)
    table.insert(_portals, pn)
    table.insert(_portals, ps)

    local portalPositions = {GameConfig.PORTAL_NORTH_POS, GameConfig.PORTAL_SOUTH_POS}

    local forbidden = {
        GameConfig.PORTAL_NORTH_POS,
        GameConfig.PORTAL_SOUTH_POS,
        center,
    }

    for i = 1, GameConfig.TREE_COUNT do
        local pos
        local placed = false
        local attempts = 0
        repeat
            pos = randXZ(rng, radius, 0)
            attempts += 1
            if not tooClose(pos, {center}, GameConfig.TREE_MIN_DIST_TOWN)
                and not tooClose(pos, portalPositions, GameConfig.TREE_MIN_DIST_PORTAL) then
                placed = true
                break
            end
        until attempts >= 50
        if not placed then
            warn("[WorldService] tree", i, "could not be placed — skipped")
            continue
        end
        local id    = tostring(i)
        local model = makeTree(id, pos)
        _trees[id]  = {
            id = id, instance = model, position = pos,
            isMarked = false, markerId = nil, markCost = 0,
        }
    end

    for i = 1, GameConfig.CAMP_COUNT do
        local pos
        local placed = false
        local attempts = 0
        repeat
            pos = randXZ(rng, radius * 0.8, 0)
            attempts += 1
            if not tooClose(pos, forbidden, GameConfig.CAMP_MIN_DIST_PORTAL)
                and not tooClose(pos, _campPositions, 20) then
                placed = true
                break
            end
        until attempts >= 50
        if not placed then
            warn("[WorldService] camp", i, "could not be placed — skipped")
            continue
        end
        table.insert(_campPositions, pos)
        local marker      = Instance.new("Part")
        marker.Name       = "Camp_" .. i
        marker.Size       = Vector3.new(4, 0.5, 4)
        marker.BrickColor = BrickColor.new("Sand green")
        marker.Anchored   = true
        marker.Position   = pos + Vector3.new(0, 0.25, 0)
        marker.Parent     = workspace
    end

    for _ = 1, GameConfig.MOUND_COUNT do
        local pos
        local placed = false
        local attempts = 0
        repeat
            pos = randXZ(rng, radius, 0)
            attempts += 1
            if not tooClose(pos, forbidden, GameConfig.MOUND_MIN_DIST_PORTAL) then
                placed = true
                break
            end
        until attempts >= 50
        if not placed then
            warn("[WorldService] mound could not be placed — skipped")
            continue
        end
        makeMound(pos)
    end

    local treeCount = 0
    for _ in _trees do treeCount += 1 end
    print("[WorldService] Island built — portals:", #_portals, "trees:", treeCount, "camps:", #_campPositions)
end

function WorldService.getTownCenterPos(): Vector3
    return GameConfig.TOWN_CENTER_POS
end

function WorldService.getPortals(): {BasePart}
    local copy = {}
    for _, p in _portals do table.insert(copy, p) end
    return copy
end

function WorldService.getCampPositions(): {Vector3}
    local copy = {}
    for _, p in _campPositions do table.insert(copy, p) end
    return copy
end

function WorldService.getTrees(): {TreeData}
    local list = {}
    for _, t in _trees do table.insert(list, t) end
    return list
end

function WorldService.getMarkedTrees(): {TreeData}
    local list = {}
    for _, t in _trees do
        if t.isMarked then table.insert(list, t) end
    end
    return list
end

function WorldService.getPlayerMarkCount(playerId: number): number
    local count = 0
    for _, t in _trees do
        if t.isMarked and t.markerId == playerId then count += 1 end
    end
    return count
end

function WorldService.markTree(treeId: string, playerId: number, cost: number): boolean
    local t = _trees[treeId]
    if not t or t.isMarked then return false end
    t.isMarked = true
    t.markerId = playerId
    t.markCost = cost
    if t.instance and t.instance.PrimaryPart then
        t.instance.PrimaryPart.BrickColor = BrickColor.new("Bright yellow")
    end
    return true
end

function WorldService.removeTree(treeId: string)
    local t = _trees[treeId]
    if not t then return end
    if t.instance.Parent then t.instance:Destroy() end
    _trees[treeId] = nil
    local grass      = Instance.new("Part")
    grass.Name       = "Grass"
    grass.Size       = Vector3.new(4, 0.2, 4)
    grass.BrickColor = BrickColor.new("Bright green")
    grass.Anchored   = true
    grass.Position   = t.position + Vector3.new(0, 0.1, 0)
    grass.Parent     = workspace
end

function WorldService.registerGroundTool(inst: BasePart, pos: Vector3)
    table.insert(_groundTools, { instance = inst, position = pos })
end

function WorldService.removeGroundTool(inst: BasePart)
    for i = #_groundTools, 1, -1 do
        if _groundTools[i].instance == inst then
            table.remove(_groundTools, i)
            return
        end
    end
end

function WorldService.getGroundTools(): {GroundTool}
    local copy = {}
    for _, gt in _groundTools do table.insert(copy, gt) end
    return copy
end

function WorldService.spawnHammerShop()
    if _hammerShopSpawned then return end
    _hammerShopSpawned = true
    makeHammerShop(GameConfig.TOWN_CENTER_POS)
    print("[WorldService] Hammer shop spawned")
end

-- ── Food ─────────────────────────────────────────────────────────────────

local _foodParts: {BasePart} = {}

local function makeFood(pos: Vector3): BasePart
    local p      = Instance.new("Part")
    p.Name       = "Food"
    p.Size       = Vector3.new(0.8, 0.8, 0.8)
    p.Shape      = Enum.PartType.Ball
    p.BrickColor = BrickColor.new("Bright orange")
    p.Anchored   = true
    p.Position   = pos + Vector3.new(0, 0.4, 0)
    p.Parent     = workspace
    p:SetAttribute("Reserved", false)
    return p
end

function WorldService.spawnFood(pos: Vector3)
    table.insert(_foodParts, makeFood(pos))
end

function WorldService.getAvailableFood(): {BasePart}
    local available = {}
    for i = #_foodParts, 1, -1 do
        local p = _foodParts[i]
        if not p.Parent then
            table.remove(_foodParts, i)
        elseif not p:GetAttribute("Reserved") then
            table.insert(available, p)
        end
    end
    return available
end

function WorldService.reserveFood(part: BasePart): boolean
    if not part.Parent or part:GetAttribute("Reserved") then return false end
    part:SetAttribute("Reserved", true)
    return true
end

function WorldService.consumeFood(part: BasePart)
    for i = #_foodParts, 1, -1 do
        if _foodParts[i] == part then table.remove(_foodParts, i) break end
    end
    if part.Parent then part:Destroy() end
end

function WorldService.onFireLit(cb: () -> ()): RBXScriptConnection
    return _fireLitEvent.Event:Connect(cb)
end

function WorldService.fireFireLit()
    _fireLitEvent:Fire()
    WorldService.spawnHammerShop()
end

return WorldService
