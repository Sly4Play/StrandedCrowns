local GameConfig = require(game:GetService("ReplicatedStorage").Shared.GameConfig)

local _fireLitEvent = Instance.new("BindableEvent")

type GroundTool = { instance: BasePart, position: Vector3 }
local _groundTools: {GroundTool} = {}

type TreeData = {
    id: string, instance: Model, position: Vector3,
    isMarked: boolean, markerId: number?, markCost: number,
    treeSize: number,
}
local _trees: {[string]: TreeData} = {}

local _campPositions: {Vector3} = {}
local _portals: {BasePart} = {}
local _hammerShopSpawned = false
local _structuresSpawned = false
local _boat: BasePart? = nil
local _spawn: SpawnLocation? = nil

-- Tool rack registry: shopPart → { toolType, tools[] }
type RackEntry = { toolType: string, tools: {BasePart} }
local _racks: {[BasePart]: RackEntry} = {}

local WorldService = {}

local function randXZ(rng: Random, minDist: number, maxDist: number, yHeight: number): Vector3
    local angle = rng:NextNumber(0, 2 * math.pi)
    local dist  = rng:NextNumber(minDist, maxDist)
    return Vector3.new(math.cos(angle) * dist, yHeight, math.sin(angle) * dist)
end

local function tooClose(pos: Vector3, others: {Vector3}, minDist: number): boolean
    for _, other in others do
        if (pos - other).Magnitude < minDist then return true end
    end
    return false
end

-- Half-width of each tree's canopy footprint (leaves width / 2 + buffer)
local TREE_FOOTPRINT: {[number]: number} = { [1] = 3, [2] = 5, [3] = 7 }

-- Weighted tree size per island tier:
--   Island 1:   small dominant  (60 / 28 / 12)
--   Islands 2-3: medium dominant (18 / 58 / 24)
--   Islands 4-5: large dominant  (8  / 28 / 64)
local function pickTreeSize(rng: Random, islandIdx: number): number
    local r = rng:NextNumber()
    if islandIdx <= 1 then
        return r < 0.60 and 1 or r < 0.88 and 2 or 3
    elseif islandIdx <= 3 then
        return r < 0.18 and 1 or r < 0.76 and 2 or 3
    else
        return r < 0.08 and 1 or r < 0.36 and 2 or 3
    end
end

local function tooCloseToTrees(pos: Vector3, placed: {{pos: Vector3, size: number}}, newSize: number): boolean
    local newR = TREE_FOOTPRINT[newSize] or 3
    for _, t in placed do
        local minDist = newR + (TREE_FOOTPRINT[t.size] or 3)
        if (pos - t.pos).Magnitude < minDist then return true end
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

-- treeSize: 1 = small, 2 = medium, 3 = large
local function makeTree(id: string, pos: Vector3, treeSize: number): Model
    local model = Instance.new("Model")
    model.Name  = "Tree_" .. id

    local trunkW: number; local trunkH: number; local trunkY: number
    local leavesW: number; local leavesH: number; local leavesY: number

    if treeSize == 3 then        -- Large
        trunkW  = 3.5;  trunkH  = 18;  trunkY  = 9
        leavesW = 11;   leavesH = 10;  leavesY = 22.5
    elseif treeSize == 2 then    -- Medium
        trunkW  = 2.5;  trunkH  = 12;  trunkY  = 6
        leavesW = 8;    leavesH = 8;   leavesY = 15
    else                          -- Small
        trunkW  = 1.5;  trunkH  = 7;   trunkY  = 3.5
        leavesW = 5;    leavesH = 6;   leavesY = 9.5
    end

    local trunk      = Instance.new("Part")
    trunk.Name       = "Trunk"
    trunk.Size       = Vector3.new(trunkW, trunkH, trunkW)
    trunk.BrickColor = BrickColor.new("Reddish brown")
    trunk.Anchored   = true
    trunk.Position   = pos + Vector3.new(0, trunkY, 0)
    trunk.Parent     = model

    local leaves      = Instance.new("Part")
    leaves.Name       = "Leaves"
    leaves.Size       = Vector3.new(leavesW, leavesH, leavesW)
    leaves.BrickColor = BrickColor.new("Bright green")
    leaves.Anchored   = true
    leaves.Position   = pos + Vector3.new(0, leavesY, 0)
    leaves.Parent     = model

    model.PrimaryPart = trunk
    model:SetAttribute("TreeSize", treeSize)
    model.Parent      = workspace
    return model
end

-- ── Tool shop + rack ─────────────────────────────────────────────────────

local function initRack(shopPart: BasePart, toolType: string)
    _racks[shopPart] = { toolType = toolType, tools = {} }
    shopPart:SetAttribute("RackCount", 0)
    shopPart:SetAttribute("RackMax",   GameConfig.RACK_MAX_TOOLS)
    -- Visual shelf on top of shop
    local shelf       = Instance.new("Part")
    shelf.Name        = "ToolRack"
    shelf.Size        = Vector3.new(shopPart.Size.X - 0.2, 0.2, 1.4)
    shelf.BrickColor  = BrickColor.new("Reddish brown")
    shelf.Material    = Enum.Material.Wood
    shelf.Anchored    = true
    shelf.CanCollide  = false
    shelf.Position    = shopPart.Position + Vector3.new(0, shopPart.Size.Y / 2 + 0.1, 0)
    shelf.Parent      = workspace
end

local function makeShop(pos: Vector3, shopType: string, col: BrickColor, offset: Vector3): BasePart
    local p       = Instance.new("Part")
    p.Name        = shopType .. "Shop"
    p.Size        = Vector3.new(4, 4, 4)
    p.BrickColor  = col
    p.Anchored    = true
    p.Position    = pos + offset
    p.Parent      = workspace
    p:SetAttribute("ShopType", shopType)
    return p
end

local function makeHammerShop(pos: Vector3): BasePart
    local p = makeShop(pos, "Hammer", BrickColor.new("Bright orange"), Vector3.new(0, 2, 16))
    initRack(p, "Hammer")
    return p
end

local function makeBowShop(pos: Vector3): BasePart
    local p = makeShop(pos, "Bow", BrickColor.new("Bright blue"), Vector3.new(16, 2, 0))
    initRack(p, "Bow")
    return p
end

local function makeTownBoundary(center: Vector3, radius: number)
    local segments = 24
    local step     = (2 * math.pi) / segments
    local chord    = 2 * radius * math.sin(step / 2) + 0.3
    for i = 0, segments - 1 do
        local angle = i * step
        local x     = center.X + math.cos(angle) * radius
        local z     = center.Z + math.sin(angle) * radius
        local p         = Instance.new("Part")
        p.Name          = "TownBoundary"
        p.Size          = Vector3.new(chord, 0.4, 0.6)
        p.CFrame        = CFrame.new(x, center.Y + 0.2, z) * CFrame.Angles(0, -(angle + math.pi / 2), 0)
        p.Anchored      = true
        p.CanCollide    = false
        p.Transparency  = 0.45
        p.BrickColor    = BrickColor.new("White")
        p.Material      = Enum.Material.Neon
        p.Parent        = workspace
    end
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

local function spawnBrokenBoat()
    local center  = GameConfig.TOWN_CENTER_POS
    local angle   = math.pi / 6
    local dist    = GameConfig.ISLAND_RADIUS
    local pos     = center + Vector3.new(math.cos(angle) * dist, 0, math.sin(angle) * dist)

    -- Axes at this shore position
    local outward = Vector3.new( math.cos(angle), 0,  math.sin(angle))
    local tangent = Vector3.new(-math.sin(angle), 0,  math.cos(angle))

    -- Boat runs along the coast; +Z of CFrame = -tangent (back face along coast)
    local baseCF = CFrame.fromMatrix(pos, outward, Vector3.new(0, 1, 0), -tangent)

    local function makePart(name: string, sz: Vector3, col: BrickColor,
                            off: Vector3, extra: CFrame?): Part
        local p      = Instance.new("Part")
        p.Name       = name
        p.Size       = sz
        p.BrickColor = col
        p.Material   = Enum.Material.Wood
        p.Anchored   = true
        p.CFrame     = baseCF * CFrame.new(off) * (extra or CFrame.identity)
        p.Parent     = workspace
        return p :: Part
    end

    -- Hull at 75% of previous: 12×7.5×45
    local hull = makePart("BrokenBoat",
        Vector3.new(12, 7.5, 45), BrickColor.new("Reddish brown"), Vector3.new(0, 3.75, 0))
    hull:SetAttribute("Level",           0)
    hull:SetAttribute("Marked",          false)
    hull:SetAttribute("BuildProgress",   0)
    hull:SetAttribute("BuildRequired",   GameConfig.BOAT_REPAIR_DURATION)
    hull:SetAttribute("MaxBuilders",     GameConfig.BOAT_MAX_BUILDERS)
    hull:SetAttribute("CurrentBuilders", 0)

    -- Deck: sits on hull top (Y=7.5), center at 7.5+0.75=8.25
    makePart("BoatDeck",  Vector3.new(10.5, 1.5, 39), BrickColor.new("Brown"),
        Vector3.new(0, 8.25, 0))
    -- Bow/stern: same Y as hull center, Z = hull half (22.5) + piece half (3.75)
    makePart("BoatBow",   Vector3.new(9, 7.5, 7.5), BrickColor.new("Reddish brown"),
        Vector3.new(0, 3.75, 26.25))
    makePart("BoatStern", Vector3.new(13.5, 7.5, 7.5), BrickColor.new("Reddish brown"),
        Vector3.new(0, 3.75, -26.25))
    -- Mast: deck top = 9, mast half = 12 → center Y=21; Z scaled 8→6
    makePart("BrokenMast", Vector3.new(1.8, 24, 1.8), BrickColor.new("Brown"),
        Vector3.new(0, 21, 6), CFrame.Angles(math.rad(30), 0, 0))
    makePart("FallenYard", Vector3.new(1.5, 18, 1.5), BrickColor.new("Brown"),
        Vector3.new(0, 7.5, 13.5), CFrame.Angles(0, math.pi / 4, math.rad(70)))

    _boat = hull
    print("[WorldService] Broken boat spawned at", math.floor(pos.X), math.floor(pos.Z))
end

function WorldService.buildIsland(islandIdx: number?)
    local rng    = Random.new(os.time())
    local center = GameConfig.TOWN_CENTER_POS
    local iIdx   = islandIdx or 1
    local radii  = GameConfig.ISLAND_RADIUS_BY_ISLAND
    local trees  = GameConfig.TREE_COUNT_BY_ISLAND
    local radius    = (radii and radii[iIdx]) or GameConfig.ISLAND_RADIUS
    local treeCount = (trees and trees[iIdx]) or GameConfig.TREE_COUNT

    -- Pre-compute boat shore position so camps stay clear of it
    local boatAngle = math.pi / 6
    local boatPos   = center + Vector3.new(math.cos(boatAngle) * radius, 0, math.sin(boatAngle) * radius)

    -- Remove any default SpawnLocations so ours is the only one
    for _, child in workspace:GetChildren() do
        if child:IsA("SpawnLocation") then child:Destroy() end
    end

    -- Spawn point starts at the broken boat (island arrival point).
    -- WorldService.setSpawnAtTown() moves it once the lighthouse is repaired.
    local inward = (center - boatPos).Unit
    local sp             = Instance.new("SpawnLocation")
    sp.Name              = "IslandSpawn"
    sp.Size              = Vector3.new(6, 1, 6)
    sp.Anchored          = true
    sp.CanCollide        = true
    sp.Transparency      = 1
    sp.Neutral           = true
    sp.Position          = boatPos + inward * 14 + Vector3.new(0, 1, 0)
    sp.Parent            = workspace
    _spawn               = sp

    makeTownBoundary(center, GameConfig.TOWN_RADIUS)

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

    local placedTrees: {{pos: Vector3, size: number}} = {}

    for i = 1, treeCount do
        local treeSize = pickTreeSize(rng, iIdx)
        local pos
        local placed = false
        local attempts = 0
        repeat
            pos = randXZ(rng, 20, radius, 0)
            attempts += 1
            if not tooClose(pos, {center}, GameConfig.TREE_MIN_DIST_TOWN)
                and not tooClose(pos, portalPositions, GameConfig.TREE_MIN_DIST_PORTAL)
                and not tooCloseToTrees(pos, placedTrees, treeSize) then
                placed = true
                break
            end
        until attempts >= 50
        if not placed then
            warn("[WorldService] tree", i, "could not be placed — skipped")
            continue
        end
        table.insert(placedTrees, { pos = pos, size = treeSize })
        local id    = tostring(i)
        local model = makeTree(id, pos, treeSize)
        _trees[id]  = {
            id = id, instance = model, position = pos,
            isMarked = false, markerId = nil, markCost = 0,
            treeSize = treeSize,
        }
    end

    local campMinFromCenter = GameConfig.TOWN_RADIUS + GameConfig.CAMP_MIN_DIST_TOWN_EDGE

    for i = 1, GameConfig.CAMP_COUNT do
        local pos
        local placed = false
        local attempts = 0
        repeat
            pos = randXZ(rng, campMinFromCenter, radius * 0.9, 0)
            attempts += 1
            if not tooClose(pos, portalPositions, GameConfig.CAMP_MIN_DIST_PORTAL)
                and not tooClose(pos, {boatPos}, GameConfig.BOAT_MIN_DIST_CAMP)
                and not tooClose(pos, _campPositions, GameConfig.CAMP_MIN_DIST_CAMP) then
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
            pos = randXZ(rng, 20, radius, 0)
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

    spawnBrokenBoat()

    local treeCount = 0
    for _ in _trees do treeCount += 1 end
    print("[WorldService] Island built — portals:", #_portals, "trees:", treeCount, "camps:", #_campPositions)
end

function WorldService.getTownCenterPos(): Vector3
    return GameConfig.TOWN_CENTER_POS
end

-- Call when the lighthouse is repaired to move the island spawn to town center.
function WorldService.setSpawnAtTown()
    if not _spawn then return end
    _spawn.Position = GameConfig.TOWN_CENTER_POS + Vector3.new(0, 1, 0)
    _spawn.Name     = "TownSpawn"
    print("[WorldService] Spawn moved to town center (lighthouse repaired)")
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
    if t.treeSize ~= 1 then return false end
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
    makeBowShop(GameConfig.TOWN_CENTER_POS)
    print("[WorldService] Hammer shop and Bow shop spawned")
end

-- ── Rack public API ───────────────────────────────────────────────────────

function WorldService.addToolToRack(shopPart: BasePart): boolean
    local rack = _racks[shopPart]
    if not rack then return false end
    if #rack.tools >= GameConfig.RACK_MAX_TOOLS then return false end
    local idx    = #rack.tools          -- 0-based slot index
    local slotX  = (idx - 1.5) * 0.95  -- 4 slots centred on shop
    local shelfY = shopPart.Position.Y + shopPart.Size.Y / 2 + 0.3
    local isBow  = rack.toolType == "Bow"
    local tool        = Instance.new("Part")
    tool.Name         = rack.toolType
    tool.Size         = Vector3.new(0.4, 0.4, 1.2)
    tool.BrickColor   = isBow and BrickColor.new("Brown") or BrickColor.new("Medium stone grey")
    tool.Material     = isBow and Enum.Material.Wood or Enum.Material.Metal
    tool.Anchored     = true
    tool.CanCollide   = false
    tool.Position     = Vector3.new(shopPart.Position.X + slotX, shelfY, shopPart.Position.Z)
    tool:SetAttribute("ToolType", rack.toolType)
    tool.Parent       = workspace
    table.insert(rack.tools, tool)
    shopPart:SetAttribute("RackCount", #rack.tools)
    return true
end

function WorldService.takeToolFromRack(shopPart: BasePart): string?
    local rack = _racks[shopPart]
    if not rack or #rack.tools == 0 then return nil end
    local tool = table.remove(rack.tools)
    if tool.Parent then tool:Destroy() end
    shopPart:SetAttribute("RackCount", #rack.tools)
    return rack.toolType
end

-- Returns all shop parts that have at least one tool on the rack.
function WorldService.getShopsWithTools(): {BasePart}
    local list = {}
    for shopPart, rack in _racks do
        if shopPart.Parent and #rack.tools > 0 then
            table.insert(list, shopPart)
        end
    end
    return list
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

-- 4 pairs of (tower + barricade) at the N/E/S/W positions on the town boundary.
-- Each pair has the tower and barricade side-by-side, leaving a ~12-stud opening
-- at each cardinal gap for gates.  Barricades become gates at upgrade 2.
function WorldService.spawnTownStructures()
    if _structuresSpawned then return end
    _structuresSpawned = true

    local center  = GameConfig.TOWN_CENTER_POS
    local r       = GameConfig.TOWN_RADIUS

    -- Cardinals: East=0, South=π/2, West=π, North=3π/2
    local cardinals = {0, math.pi / 2, math.pi, 3 * math.pi / 2}
    local labels    = {"E", "S", "W", "N"}

    for idx, theta in cardinals do
        local radial  = Vector3.new(math.cos(theta), 0, math.sin(theta))
        local tangent = Vector3.new(-math.sin(theta), 0, math.cos(theta))
        local base    = center + radial * r   -- point on circumference

        -- Tower (3×4×3): sits 2.5 studs to the "left" of the cardinal along the tangent
        local tH      = 4
        local tPos    = base + tangent * (-2.5) + Vector3.new(0, tH / 2, 0)
        local tower   = Instance.new("Part")
        tower.Name    = "Tower_Foundation_" .. labels[idx]
        tower.Size    = Vector3.new(3, tH, 3)
        tower.BrickColor  = BrickColor.new("Medium stone grey")
        tower.Transparency = 0.5
        tower.Anchored    = true
        tower.CFrame      = CFrame.lookAt(tPos, Vector3.new(center.X, tPos.Y, center.Z))
        tower.Parent      = workspace
        tower:SetAttribute("StructureType",   "Tower")
        tower:SetAttribute("Level",           0)
        tower:SetAttribute("MaxBuilders",     GameConfig.TOWER_MAX_BUILDERS)
        tower:SetAttribute("CurrentBuilders", 0)
        tower:SetAttribute("BuildProgress",   0)
        tower:SetAttribute("BuildRequired",   GameConfig.STRUCTURE_BUILD_DURATION)

        -- Barricade (6×2×2): sits 3.5 studs to the "right" of the cardinal
        local bH         = 2
        local bPos       = base + tangent * 3.5 + Vector3.new(0, bH / 2, 0)
        local barricade  = Instance.new("Part")
        barricade.Name   = "Barricade_Foundation_" .. labels[idx]
        barricade.Size   = Vector3.new(6, bH, 2)
        barricade.BrickColor  = BrickColor.new("Medium stone grey")
        barricade.Transparency = 0.5
        barricade.Anchored    = true
        barricade.CFrame      = CFrame.lookAt(bPos, Vector3.new(center.X, bPos.Y, center.Z))
        barricade.Parent      = workspace
        barricade:SetAttribute("StructureType",   "Barricade")
        barricade:SetAttribute("Level",           0)
        barricade:SetAttribute("MaxBuilders",     GameConfig.BARRICADE_MAX_BUILDERS)
        barricade:SetAttribute("CurrentBuilders", 0)
        barricade:SetAttribute("BuildProgress",   0)
        barricade:SetAttribute("BuildRequired",   GameConfig.STRUCTURE_BUILD_DURATION)
    end

    print("[WorldService] Town Level 1 structures spawned (4 tower+barricade pairs)")
end

function WorldService.getUnbuiltStructures(): {BasePart}
    local list = {}
    for _, child in workspace:GetChildren() do
        if not child:IsA("BasePart") then continue end
        if child:GetAttribute("Level") ~= 0 then continue end
        if child:GetAttribute("BuildInProgress") then continue end
        local n = child.Name
        if n:sub(1, 16) == "Tower_Foundation" or n:sub(1, 20) == "Barricade_Foundation" then
            table.insert(list, child :: BasePart)
        end
    end
    return list
end

function WorldService.markStructureBuilt(inst: BasePart)
    inst:SetAttribute("Level", 1)
    inst:SetAttribute("BuildInProgress", false)
    inst.Transparency = 0
    inst.BrickColor   = BrickColor.new("Dark stone grey")
    inst.Name         = inst.Name:gsub("_Foundation", "")
    print("[WorldService] Built:", inst.Name)
end

function WorldService.onFireLit(cb: () -> ()): RBXScriptConnection
    return _fireLitEvent.Event:Connect(cb)
end

function WorldService.fireFireLit()
    _fireLitEvent:Fire()
    WorldService.spawnHammerShop()
end

-- ── Boat ─────────────────────────────────────────────────────────────────

function WorldService.markBoatForRepair(): boolean
    if not _boat or not _boat.Parent then return false end
    if _boat:GetAttribute("Marked") then return false end
    _boat:SetAttribute("Marked", true)
    _boat.BrickColor = BrickColor.new("Bright yellow")
    print("[WorldService] Boat marked for repair")
    return true
end

function WorldService.repairBoat(part: BasePart)
    part:SetAttribute("Level", 1)
    part:SetAttribute("CurrentBuilders", 0)
    part.BrickColor = BrickColor.new("Dark orange")
    part.Name = "RepairedBoat"
    print("[WorldService] Boat repaired!")
end

-- ── Unified build job query ───────────────────────────────────────────────

type BuildJob = { instance: BasePart, position: Vector3 }

function WorldService.getAvailableBuildJobs(): {BuildJob}
    local jobs = {}
    for _, child in workspace:GetChildren() do
        if not child:IsA("BasePart") then continue end
        if child:GetAttribute("Level") ~= 0 then continue end
        local maxB = child:GetAttribute("MaxBuilders") or 1
        local curB = child:GetAttribute("CurrentBuilders") or 0
        if curB >= maxB then continue end
        local n = child.Name
        local isStructure = n:sub(1, 16) == "Tower_Foundation" or n:sub(1, 20) == "Barricade_Foundation"
        local isBoat = n == "BrokenBoat" and child:GetAttribute("Marked") == true
        if isStructure or isBoat then
            table.insert(jobs, { instance = child :: BasePart, position = child.Position })
        end
    end
    return jobs
end

return WorldService
