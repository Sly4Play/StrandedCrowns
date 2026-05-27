local GameConfig = require(game:GetService("ReplicatedStorage").Shared.GameConfig)

local _fireLitEvent        = Instance.new("BindableEvent")
local _mayorHouseBuiltEvent = Instance.new("BindableEvent")

type GroundTool = { instance: BasePart, position: Vector3 }
local _groundTools: {GroundTool} = {}

type TreeData = {
    id: string, instance: Model, position: Vector3,
    isMarked: boolean, markerId: number?, markCost: number,
    treeSize: number,
}
local _trees: {[string]: TreeData} = {}
local _treeClaims: {[string]: boolean} = {}  -- treeId → claimed; enforces 1 builder per tree

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
    p.CanCollide = true
    p.CollisionGroup = "Portal"
    p.Position   = pos + Vector3.new(0, 4, 0)
    p:SetAttribute("Health",    GameConfig.PORTAL_HEALTH)
    p:SetAttribute("MaxHealth", GameConfig.PORTAL_HEALTH)
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
    trunk.CanCollide = true   -- blocks movement; NPCs and players bump into trunks
    trunk.Position   = pos + Vector3.new(0, trunkY, 0)
    trunk.Parent     = model

    local leaves      = Instance.new("Part")
    leaves.Name       = "Leaves"
    leaves.Size       = Vector3.new(leavesW, leavesH, leavesW)
    leaves.BrickColor = BrickColor.new("Bright green")
    leaves.Anchored   = true
    leaves.CanCollide = false  -- canopy is visual-only; walk under/through it freely
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
    local p = makeShop(pos, "Hammer", BrickColor.new("Bright orange"), Vector3.new(-24, 2, 24))
    initRack(p, "Hammer")
    return p
end

local function makeBowShop(pos: Vector3): BasePart
    local p = makeShop(pos, "Bow", BrickColor.new("Bright blue"), Vector3.new(24, 2, -24))
    initRack(p, "Bow")
    return p
end

local function makeIslandBoundary(center: Vector3, radius: number)
    local segments = 48
    local step     = (2 * math.pi) / segments
    local chord    = 2 * radius * math.sin(step / 2) + 0.3
    for i = 0, segments - 1 do
        local angle = i * step
        local x     = center.X + math.cos(angle) * radius
        local z     = center.Z + math.sin(angle) * radius
        local p         = Instance.new("Part")
        p.Name          = "IslandBoundary"
        p.Size          = Vector3.new(chord, 0.4, 0.6)
        p.CFrame        = CFrame.new(x, center.Y + 0.3, z)
                          * CFrame.Angles(0, -(angle + math.pi / 2), 0)
        p.Anchored      = true
        p.CanCollide    = false
        p.Transparency  = 0.45
        p.BrickColor    = BrickColor.new("Cyan")
        p.Material      = Enum.Material.Neon
        p.Parent        = workspace
    end
    -- Tall posts every 45° so the boundary is visible from across the island
    for i = 0, 7 do
        local angle   = i * (math.pi / 4)
        local x       = center.X + math.cos(angle) * radius
        local z       = center.Z + math.sin(angle) * radius
        local post        = Instance.new("Part")
        post.Name         = "IslandBoundaryPost"
        post.Size         = Vector3.new(0.6, 8, 0.6)
        post.BrickColor   = BrickColor.new("Cyan")
        post.Material     = Enum.Material.Neon
        post.Anchored     = true
        post.CanCollide   = false
        post.Transparency = 0.4
        post.Position     = Vector3.new(x, center.Y + 4, z)
        post.Parent       = workspace
    end
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
    makeIslandBoundary(center, radius)

    -- In dev mode portals are placed by spawnDevTown() — skip here
    local portalPositions: {Vector3} = {}
    if not GameConfig.DEV_MODE then
        local portalNorthPos = center + Vector3.new(0, 0, -radius)
        local portalSouthPos = center + Vector3.new(0, 0,  radius)
        local pn = makePortal(portalNorthPos)
        local ps = makePortal(portalSouthPos)
        table.insert(_portals, pn)
        table.insert(_portals, ps)
        table.insert(portalPositions, portalNorthPos)
        table.insert(portalPositions, portalSouthPos)
    end

    local forbidden = {
        GameConfig.PORTAL_NORTH_POS,
        GameConfig.PORTAL_SOUTH_POS,
        center,
    }

    -- Pre-compute structure footprints so no tree spawns on top of them.
    local structureSpots: {Vector3} = {}
    do
        local r = GameConfig.TOWN_RADIUS
        for _, theta in {0, math.pi/2, math.pi, 3*math.pi/2} do
            local radial  = Vector3.new(math.cos(theta), 0, math.sin(theta))
            local tangent = Vector3.new(-math.sin(theta), 0, math.cos(theta))
            local base    = center + radial * r
            table.insert(structureSpots, base + tangent * (-8))  -- tower
            table.insert(structureSpots, base + tangent *   8)    -- barricade
        end

        -- Town shops at tier-6 arc positions (radius 38, inside perimeter wall).
        -- These are the final positions on every island — reserved as no-tree zones
        -- from island 1 so the spots are already clear when a town reaches tier 6.
        for _, off in {
            Vector3.new(-19, 0,  33),  -- HammerShop  SW-arc 120°
            Vector3.new(-33, 0,  20),  -- PikemanShop SW-arc 150°
            Vector3.new(-33, 0, -20),  -- UpgradeShop NW-arc 210°
            Vector3.new(-19, 0, -33),  -- FarmerShop  NW-arc 240°
            Vector3.new( 19, 0, -33),  -- BowShop     NE-arc 300°
            Vector3.new( 33, 0, -20),  -- BombShop    NE-arc 330°
            Vector3.new( 24, 0,  24),  -- TownHall    SE
        } do
            table.insert(structureSpots, center + off)
        end
        -- 8 enemy portals (far-field; outside small islands' radii so harmless there)
        local pi = math.pi
        local cos, sin = math.cos, math.sin
        local edgeR, inR = 410, 310
        for _, off in {
            Vector3.new( edgeR,             0,  0                 ),  -- P1 E
            Vector3.new( cos(pi/4)*inR,     0,  sin(pi/4)*inR     ),  -- P2 SE
            Vector3.new( 0,                 0,  320               ),  -- P3 S
            Vector3.new( cos(3*pi/4)*edgeR, 0,  sin(3*pi/4)*edgeR),  -- P4 SW
            Vector3.new(-inR,               0,  0                 ),  -- P5 W
            Vector3.new( cos(5*pi/4)*edgeR, 0,  sin(5*pi/4)*edgeR),  -- P6 NW
            Vector3.new( 0,                 0, -270               ),  -- P7 N
            Vector3.new( edgeR - 50,        0,  0                 ),  -- P8 E-axis
        } do
            table.insert(structureSpots, center + off)
        end
        -- Far-field landmarks
        table.insert(structureSpots, center + Vector3.new(  0, 0, -370))  -- Guardian
        table.insert(structureSpots, center + Vector3.new(  0, 0, -440))  -- Lighthouse
        table.insert(structureSpots, center + Vector3.new(360, 0, -360))  -- Boat repair site
        -- Mountain base (80-stud wide): center + 8 perimeter points for full coverage
        local mtnC = center + Vector3.new(0, 0, 440)
        table.insert(structureSpots, mtnC)
        for i = 0, 7 do
            local a = i * math.pi / 4
            table.insert(structureSpots, mtnC + Vector3.new(math.cos(a) * 40, 0, math.sin(a) * 40))
        end
    end

    if not GameConfig.DEV_MODE then
        -- Random markers, trees, camps, mounds only in normal play
        WorldService.spawnRandomStructureMarkers(center, radius, rng, structureSpots, portalPositions)

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
                    and not tooClose(pos, structureSpots, 8)
                    and not tooCloseToTrees(pos, placedTrees, treeSize) then
                    placed = true
                    break
                end
            until attempts >= 80
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
    end

    WorldService.spawnTownStructures()

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
    local copy  = {}
    local alive = {}
    for _, p in _portals do
        if p.Parent then
            table.insert(copy,  p)
            table.insert(alive, p)
        end
    end
    _portals = alive  -- prune destroyed portals so Greed stops spawning from them
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

-- Returns true if the tree was actually removed, false if already gone (prevents duplicate pay).
function WorldService.removeTree(treeId: string): boolean
    local t = _trees[treeId]
    if not t then return false end
    _trees[treeId] = nil      -- deregister immediately
    _treeClaims[treeId] = nil -- release claim

    local model = t.instance
    local pos   = t.position
    if not model.Parent then return end

    -- collect parts + snapshot CFrames before animation starts
    local parts   : {BasePart} = {}
    local initCFs : {CFrame}   = {}
    for _, desc in model:GetDescendants() do
        if desc:IsA("BasePart") then
            table.insert(parts,   desc)
            table.insert(initCFs, desc.CFrame)
        end
    end

    local fallAngle = math.random() * 2 * math.pi
    local axis      = Vector3.new(-math.sin(fallAngle), 0, math.cos(fallAngle))
    local pivotCF   = CFrame.new(pos.X, 0, pos.Z)
    local DURATION  = 0.75

    task.spawn(function()
        local startTime = tick()
        repeat
            local tNorm = math.min((tick() - startTime) / DURATION, 1)
            local angle = (tNorm ^ 2) * math.rad(90)  -- ease-in: slow start, fast end
            local rotCF = CFrame.fromAxisAngle(axis, angle)
            for i, part in parts do
                if part.Parent then
                    part.CFrame = pivotCF * rotCF * (pivotCF:Inverse() * initCFs[i])
                end
            end
            task.wait()
        until tNorm >= 1

        if model.Parent then model:Destroy() end
        local grass      = Instance.new("Part")
        grass.Name       = "Grass"
        grass.Size       = Vector3.new(4, 0.2, 4)
        grass.BrickColor = BrickColor.new("Bright green")
        grass.Anchored   = true
        grass.CanCollide = false  -- visual only; NPCs must not snag on stump markers
        grass.Position   = pos + Vector3.new(0, 0.1, 0)
        grass.Parent     = workspace
    end)
    return true
end

-- Claim a tree for one builder; returns false if already claimed or gone.
function WorldService.claimTree(treeId: string): boolean
    if not _trees[treeId] then return false end
    if _treeClaims[treeId] then return false end
    _treeClaims[treeId] = true
    return true
end

function WorldService.releaseTreeClaim(treeId: string)
    _treeClaims[treeId] = nil
end

function WorldService.isTreeClaimed(treeId: string): boolean
    return _treeClaims[treeId] == true
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

-- Returns the 4 cardinal gate positions (passable gaps in the town wall).
-- Used by NpcService to route NPCs through walls instead of into them.
function WorldService.getGatePositions(): {Vector3}
    local center = GameConfig.TOWN_CENTER_POS
    local r      = GameConfig.TOWN_RADIUS
    return {
        center + Vector3.new( r,  0,  0),   -- East
        center + Vector3.new(-r,  0,  0),   -- West
        center + Vector3.new( 0,  0,  r),   -- South
        center + Vector3.new( 0,  0, -r),   -- North
    }
end

-- Scattered build-marker spots placed across the island at game start.
-- Players spend coins (F-hold) to build them; builders never touch these.
-- Appends generated positions into existingSpots so tree placement avoids them.
-- guardianPos is optional; pass it when Phase 2 Big Breeder position is known.
function WorldService.spawnRandomStructureMarkers(
    center: Vector3, radius: number, rng: Random,
    existingSpots: {Vector3}, portalPositions: {Vector3}, guardianPos: Vector3?
)
    local minR        = GameConfig.TOWN_RADIUS + GameConfig.MARKER_MIN_DIST_TOWN
    local minPortal   = GameConfig.MARKER_MIN_DIST_PORTAL
    local minGuardian = GameConfig.MARKER_MIN_DIST_GUARDIAN
    local minBetween  = GameConfig.MARKER_MIN_DIST_MARKER

    -- All markers are flat (height 0.5) on the ground until built.
    local specs = {
        { count = GameConfig.RANDOM_BARRICADE_COUNT, structType = "Barricade",
          size = Vector3.new(6, 0.5, 2), color = BrickColor.new("Medium stone grey"),
          cost = GameConfig.BARRICADE_BUILD_COST, namePrefix = "Barricade_Foundation_R" },
        { count = GameConfig.RANDOM_TOWER_COUNT,     structType = "Tower",
          size = Vector3.new(3, 0.5, 3), color = BrickColor.new("Reddish brown"),
          cost = GameConfig.TOWER_BUILD_COST,     namePrefix = "Tower_Foundation_R" },
        { count = GameConfig.RANDOM_FARM_COUNT,      structType = "FarmingArea",
          size = Vector3.new(10, 0.5, 10), color = BrickColor.new("Bright yellow"),
          cost = GameConfig.FARMING_BUILD_COST,   namePrefix = "Farm_Foundation_" },
    }

    local counter = 0
    for _, spec in specs do
        for _ = 1, spec.count do
            local pos
            local ok = false
            for _ = 1, 120 do
                pos = randXZ(rng, minR, radius * 0.85, 0)
                local clearPortals  = not tooClose(pos, portalPositions, minPortal)
                local clearSpots    = not tooClose(pos, existingSpots, minBetween)
                local clearGuardian = not guardianPos or (pos - guardianPos).Magnitude >= minGuardian
                if clearPortals and clearSpots and clearGuardian then
                    ok = true
                    break
                end
            end
            if not ok then
                warn("[WorldService] random marker", spec.structType, "could not be placed — skipped")
                continue
            end
            counter += 1
            table.insert(existingSpots, pos)

            local part = Instance.new("Part")
            part.Name  = spec.namePrefix .. counter
            part.Size  = spec.size
            part.BrickColor   = spec.color
            part.Transparency = 0.4
            part.Anchored     = true
            part.CanCollide   = false
            part.Position     = pos + Vector3.new(0, 0.25, 0)
            part.Parent       = workspace
            part:SetAttribute("StructureType",   spec.structType)
            part:SetAttribute("Level",           0)
            part:SetAttribute("BuildUnlocked",   false)
            part:SetAttribute("BuildProgress",   0)
            part:SetAttribute("BuildRequired",   spec.cost)
        end
    end
    print("[WorldService] Random structure markers placed:", counter)
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

        -- Tower: flat 3×0.5×3 brown square marker; expands to full height when built
        local tPos    = base + tangent * (-8) + Vector3.new(0, 0.25, 0)
        local tower   = Instance.new("Part")
        tower.Name    = "Tower_Foundation_" .. labels[idx]
        tower.Size    = Vector3.new(3, 0.5, 3)
        tower.BrickColor  = BrickColor.new("Reddish brown")
        tower.Transparency = 0.4
        tower.Anchored    = true
        tower.CanCollide  = false  -- passable until built
        tower.CFrame      = CFrame.lookAt(tPos, Vector3.new(center.X, tPos.Y, center.Z))
        tower.Parent      = workspace
        tower:SetAttribute("StructureType",   "Tower")
        tower:SetAttribute("Level",           0)
        tower:SetAttribute("PlayerOnly",      true)
        tower:SetAttribute("CardinalDefense", true)   -- completed by tier-2 firepit, not by player coins
        tower:SetAttribute("MaxBuilders",     GameConfig.TOWER_MAX_BUILDERS)
        tower:SetAttribute("CurrentBuilders", 0)
        tower:SetAttribute("BuildProgress",   0)
        tower:SetAttribute("BuildRequired",   GameConfig.TOWER_BUILD_COST)
        tower:SetAttribute("BuildUnlocked",   false)

        -- Barricade: flat 6×0.5×2 grey rectangle marker; expands to full height when built
        local bPos       = base + tangent * 8 + Vector3.new(0, 0.25, 0)
        local barricade  = Instance.new("Part")
        barricade.Name   = "Barricade_Foundation_" .. labels[idx]
        barricade.Size   = Vector3.new(6, 0.5, 2)
        barricade.BrickColor  = BrickColor.new("Medium stone grey")
        barricade.Transparency = 0.4
        barricade.Anchored    = true
        barricade.CanCollide  = false  -- passable until built
        barricade.CFrame      = CFrame.lookAt(bPos, Vector3.new(center.X, bPos.Y, center.Z))
        barricade.Parent      = workspace
        barricade:SetAttribute("StructureType",   "Barricade")
        barricade:SetAttribute("Level",           0)
        barricade:SetAttribute("PlayerOnly",      true)
        barricade:SetAttribute("CardinalDefense", true)   -- completed by tier-2 firepit, not by player coins
        barricade:SetAttribute("MaxBuilders",     GameConfig.BARRICADE_MAX_BUILDERS)
        barricade:SetAttribute("CurrentBuilders", 0)
        barricade:SetAttribute("BuildProgress",   0)
        barricade:SetAttribute("BuildRequired",   GameConfig.BARRICADE_BUILD_COST)
        barricade:SetAttribute("BuildUnlocked",   false)
    end

    print("[WorldService] Town Level 1 structures spawned (4 tower+barricade pairs)")
end

-- Instantly completes only the cardinal town defense foundations (triggered by tier-2 firepit).
-- Random scattered markers are NOT auto-completed; players must build those manually.
function WorldService.autoCompleteTownStructures()
    for _, child in workspace:GetChildren() do
        if not child:IsA("BasePart") then continue end
        if child:GetAttribute("Level") ~= 0 then continue end
        if not child:GetAttribute("CardinalDefense") then continue end
        WorldService.markStructureBuilt(child :: BasePart)
    end
    print("[WorldService] Cardinal town defenses completed via firepit tier-2 upgrade")
end

function WorldService.getUnbuiltStructures(): {BasePart}
    local list = {}
    for _, child in workspace:GetChildren() do
        if not child:IsA("BasePart") then continue end
        if child:GetAttribute("Level") ~= 0 then continue end
        if child:GetAttribute("BuildInProgress") then continue end
        if child:GetAttribute("StructureType") then
            table.insert(list, child :: BasePart)
        end
    end
    return list
end

function WorldService.markStructureBuilt(inst: BasePart)
    inst:SetAttribute("Level", 1)
    inst:SetAttribute("BuildInProgress", false)
    inst.Transparency = 0
    inst.Name         = inst.Name:gsub("_Foundation", "")
    local structType  = inst:GetAttribute("StructureType")
    if structType == "Tower" then
        -- 3× height and thickness: 9×12×9
        inst.Size     = Vector3.new(9, 12, 9)
        inst.Position = Vector3.new(inst.Position.X, 6, inst.Position.Z)
        inst.CanCollide     = true
        inst.BrickColor     = BrickColor.new("Reddish brown")
        inst.Material       = Enum.Material.Wood
        inst.CollisionGroup = "Defense"
        inst:SetAttribute("Health",       GameConfig.BARRICADE_HEALTH * 2)
        inst:SetAttribute("MaxHealth",    GameConfig.BARRICADE_HEALTH * 2)
        inst:SetAttribute("MaxOccupants", 1)   -- one TowerArcher slot
    elseif structType == "Barricade" then
        -- Castle gate: two thick stone pillars + lintel; passage is open (friendly collision group passes through)
        local pillarH  = 9
        local pillarW  = 5
        local halfSpan = 8   -- pillar center from gate midpoint; open passage = 2*halfSpan - pillarW = 11 studs
        local lookDir  = inst.CFrame.LookVector
        local rightDir = inst.CFrame.RightVector
        local origX    = inst.Position.X
        local origZ    = inst.Position.Z
        local gateBase = Vector3.new(origX, pillarH / 2, origZ)

        -- Repurpose inst as left gate pillar
        inst.Size        = Vector3.new(pillarW, pillarH, pillarW)
        inst.CFrame      = CFrame.lookAt(gateBase - rightDir * halfSpan,
                                         gateBase - rightDir * halfSpan + lookDir)
        inst.CanCollide     = true
        inst.BrickColor     = BrickColor.new("Medium stone grey")
        inst.Material       = Enum.Material.SmoothPlastic
        inst.CollisionGroup = "Defense"
        inst:SetAttribute("Health",    GameConfig.BARRICADE_HEALTH)
        inst:SetAttribute("MaxHealth", GameConfig.BARRICADE_HEALTH)

        -- Right gate pillar
        local rp          = Instance.new("Part")
        rp.Name           = inst.Name .. "_R"
        rp.Size           = Vector3.new(pillarW, pillarH, pillarW)
        rp.CFrame         = CFrame.lookAt(gateBase + rightDir * halfSpan,
                                          gateBase + rightDir * halfSpan + lookDir)
        rp.Anchored       = true
        rp.CanCollide     = true
        rp.BrickColor     = BrickColor.new("Medium stone grey")
        rp.Material       = Enum.Material.SmoothPlastic
        rp.CollisionGroup = "Defense"
        rp.Parent         = workspace

        -- Lintel spanning the opening
        local lintelCenter = Vector3.new(origX, pillarH + 1, origZ)
        local lp           = Instance.new("Part")
        lp.Name            = inst.Name .. "_Lintel"
        lp.Size            = Vector3.new(halfSpan * 2 + pillarW, 2, pillarW)
        lp.CFrame          = CFrame.lookAt(lintelCenter, lintelCenter + lookDir)
        lp.Anchored        = true
        lp.CanCollide      = true
        lp.BrickColor      = BrickColor.new("Medium stone grey")
        lp.Material        = Enum.Material.SmoothPlastic
        lp.CollisionGroup  = "Defense"
        lp.Parent          = workspace
    elseif structType == "FarmingArea" then
        inst.CanCollide = false
        inst.BrickColor = BrickColor.new("Sand green")
    elseif structType == "MayorHouse" then
        -- Flat 10×0.5×10 foundation expands to full 10×8×10 mayor house
        inst.Size     = Vector3.new(10, 8, 10)
        inst.Position = Vector3.new(inst.Position.X, 4, inst.Position.Z)
        inst.BrickColor  = BrickColor.new("Medium stone grey")
        inst.CanCollide  = true
        -- Seal the town perimeter now that the mayor house is standing
        WorldService.spawnPerimeterWalls()
        _mayorHouseBuiltEvent:Fire()
    end
    print("[WorldService] Built:", inst.Name)
end

-- Circular arc wall segments connecting each gate/barricade to the adjacent tower,
-- following the town boundary circle so the wall curves naturally around town.
function WorldService.spawnPerimeterWalls()
    local center = GameConfig.TOWN_CENTER_POS
    local r      = GameConfig.TOWN_RADIUS
    local wallH  = 6   -- matches barricade height
    local wallT  = 2   -- thicker for log-palisade look
    local segs   = 10  -- segments per arc

    -- Arc start: E-barricade far edge (barricade center tangent +8, half-length 11.5 → far point at tangent 19.5)
    -- Arc end:   S-tower near edge (tower center tangent -8, half-width 4.5 → near point at tangent -3.5 → absolute (12.5,0,44))
    -- By symmetry each arc is the same shape rotated π/2.
    local aStart = math.atan2(19.5, 44)  -- ≈ 0.417 rad from E-barricade far edge
    local aEnd   = math.atan2(44, 12.5)  -- ≈ 1.292 rad to S-tower near edge

    local wallNum = 0
    local function makeArc(a1: number, a2: number)
        for i = 0, segs - 1 do
            local t1    = a1 + (a2 - a1) * i / segs
            local t2    = a1 + (a2 - a1) * (i + 1) / segs
            local mid   = (t1 + t2) / 2
            local chord = 2 * r * math.sin(math.abs(t2 - t1) / 2) + 0.1
            local pos   = center + Vector3.new(math.cos(mid) * r, wallH / 2, math.sin(mid) * r)
            local ahead = center + Vector3.new(math.cos(t2)  * r, wallH / 2, math.sin(t2)  * r)
            wallNum += 1
            local wall = Instance.new("Part")
            wall.Name           = "PerimeterWall_" .. wallNum
            wall.Size           = Vector3.new(wallT, wallH, chord)
            wall.BrickColor     = BrickColor.new("Reddish brown")
            wall.Material       = Enum.Material.Wood
            wall.Anchored       = true
            wall.CanCollide     = true
            wall.CollisionGroup = "Defense"
            wall.CFrame         = CFrame.lookAt(pos, ahead)
            wall.Parent         = workspace
        end
    end

    for k = 0, 3 do
        makeArc(aStart + k * (math.pi / 2), aEnd + k * (math.pi / 2))
    end
    print("[WorldService] Circular town perimeter walls spawned")
end

-- Subscribe to mayor house completion (Bootstrap uses this to sync MayorService state)
function WorldService.onMayorHouseBuilt(cb: () -> ()): RBXScriptConnection
    return _mayorHouseBuiltEvent.Event:Connect(cb)
end

-- Spawn the mayor house foundation (BuildUnlocked=true so builders go immediately).
-- Called by Bootstrap when fire upgrades to tier 2.
function WorldService.spawnMayorHouseFoundation()
    local center = GameConfig.TOWN_CENTER_POS
    local pos    = center + Vector3.new(0, 0.25, -8)  -- just behind the firepit

    local found = Instance.new("Part")
    found.Name        = "MayorHouse_Foundation"
    found.Size        = Vector3.new(10, 0.5, 10)
    found.BrickColor  = BrickColor.new("Reddish brown")
    found.Transparency = 0.4
    found.Anchored    = true
    found.CanCollide  = false
    found.Position    = pos
    found.Parent      = workspace
    found:SetAttribute("StructureType",   "MayorHouse")
    found:SetAttribute("Level",           0)
    found:SetAttribute("BuildUnlocked",   true)   -- tier-2 cost already paid
    found:SetAttribute("BuildProgress",   0)
    found:SetAttribute("BuildRequired",   GameConfig.STRUCTURE_BUILD_DURATION)
    found:SetAttribute("MaxBuilders",     2)
    found:SetAttribute("CurrentBuilders", 0)
    print("[WorldService] Mayor house foundation placed — builders will complete it")
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

-- Unlock all cardinal town defenses for builder construction (called by tier-1 fire upgrade).
-- Sets BuildUnlocked=true and resets progress to builder build-time phase.
function WorldService.unlockCardinalDefenses()
    for _, child in workspace:GetChildren() do
        if not child:IsA("BasePart") then continue end
        if child:GetAttribute("Level") ~= 0 then continue end
        if not child:GetAttribute("CardinalDefense") then continue end
        child:SetAttribute("BuildUnlocked", true)
        child:SetAttribute("BuildProgress", 0)
        child:SetAttribute("BuildRequired", GameConfig.STRUCTURE_BUILD_DURATION)
    end
    print("[WorldService] Cardinal defenses unlocked — builders will complete them")
end

function WorldService.getAvailableBuildJobs(): {BuildJob}
    local jobs = {}
    for _, child in workspace:GetChildren() do
        if not child:IsA("BasePart") then continue end
        if child:GetAttribute("Level") ~= 0 then continue end
        local maxB = child:GetAttribute("MaxBuilders") or 1
        local curB = child:GetAttribute("CurrentBuilders") or 0
        if curB >= maxB then continue end
        -- Structures become builder jobs only after player has paid to unlock them
        local isStructure = child:GetAttribute("StructureType") ~= nil
            and child:GetAttribute("BuildUnlocked") == true
        local isBoat = child.Name == "BrokenBoat" and child:GetAttribute("Marked") == true
        if isStructure or isBoat then
            table.insert(jobs, { instance = child :: BasePart, position = child.Position })
        end
    end
    return jobs
end

-- Second perimeter wall ring (town level 2 upgrade). Same gate openings as inner ring.
function WorldService.spawnOuterPerimeterWalls()
    local center = GameConfig.TOWN_CENTER_POS
    local r      = GameConfig.TOWN_RADIUS + 14  -- 58 studs from center
    local wallH  = 2
    local wallT  = 1

    local corners = {
        { a = center + Vector3.new( r, 0,  8), b = center + Vector3.new( 8, 0,  r) },
        { a = center + Vector3.new(-8, 0,  r), b = center + Vector3.new(-r, 0,  8) },
        { a = center + Vector3.new(-r, 0, -8), b = center + Vector3.new(-8, 0, -r) },
        { a = center + Vector3.new( 8, 0, -r), b = center + Vector3.new( r, 0, -8) },
    }

    for i, corner in corners do
        local a   = corner.a
        local b   = corner.b
        local mid = (a + b) / 2 + Vector3.new(0, wallH / 2, 0)
        local len = (b - a).Magnitude + 4

        local wall = Instance.new("Part")
        wall.Name           = "OuterPerimeterWall_" .. i
        wall.Size           = Vector3.new(wallT, wallH, len)
        wall.BrickColor     = BrickColor.new("Dark stone grey")
        wall.Anchored       = true
        wall.CanCollide     = true
        wall.CollisionGroup = "Defense"
        wall.CFrame         = CFrame.lookAt(mid, b + Vector3.new(0, wallH / 2, 0))
        wall.Parent         = workspace
    end
    print("[WorldService] Outer perimeter walls spawned")
end

-- Spawns the fully-built Island 5 endgame town layout for dev feel-testing.
-- Called by Bootstrap when GameConfig.DEV_MODE is true.
function WorldService.spawnDevTown()
    local center = GameConfig.TOWN_CENTER_POS

    -- Remove default Baseplate to prevent Z-fighting with DevGround
    for _, child in workspace:GetChildren() do
        if child.Name == "Baseplate" and child:IsA("BasePart") then
            child:Destroy(); break
        end
    end

    -- Ground plane
    local ground      = Instance.new("Part")
    ground.Name       = "DevGround"
    ground.Size       = Vector3.new(1200, 1, 1200)
    ground.BrickColor = BrickColor.new("Bright green")
    ground.Material   = Enum.Material.Grass
    ground.Anchored   = true
    ground.CanCollide = true
    ground.Position   = Vector3.new(center.X, -0.5, center.Z)
    ground.Parent     = workspace

    -- Spawn just south of the firepit (pit half-size=4, spawn half-size=3, 1-stud gap)
    if _spawn then _spawn.Position = center + Vector3.new(0, 1, 8) end

    local function label(part: BasePart, text: string)
        local bb       = Instance.new("BillboardGui")
        bb.Size        = UDim2.new(0, 200, 0, 40)
        bb.StudsOffset = Vector3.new(0, part.Size.Y / 2 + 3, 0)
        bb.Parent      = part
        local lbl                  = Instance.new("TextLabel")
        lbl.Size                   = UDim2.new(1, 0, 1, 0)
        lbl.BackgroundTransparency = 1
        lbl.TextColor3             = Color3.new(1, 1, 1)
        lbl.TextStrokeTransparency = 0
        lbl.TextScaled             = true
        lbl.Text                   = text
        lbl.Parent                 = bb
    end

    -- Firepit — Fire.Color is a ColorSequence, not Color3; just use size+heat
    print("[DevTown] step 1: firepit")
    local pit      = Instance.new("Part")
    pit.Name       = "FirePit"
    pit.Size       = Vector3.new(8, 2, 8)
    pit.BrickColor = BrickColor.new("Reddish brown")
    pit.Anchored   = true
    pit.CanCollide = true
    pit.Position   = center + Vector3.new(0, 1, 0)
    pit.Parent     = workspace
    local fire     = Instance.new("Fire")
    fire.Size      = 30
    fire.Heat      = 25
    fire.Parent    = pit
    label(pit, "Firepit Lvl 6")

    -- Tool shops — placed near their cardinal gates in dev mode (override production SW/NE diagonals)
    print("[DevTown] step 2: shops")
    -- Shops placed at 1/3 and 2/3 of their perimeter arc (radius 38, inside the wall)
    -- SW arc (S-gate→W-tower): HammerShop at 120°, PikemanShop at 150°
    -- NW arc (W-gate→N-tower): UpgradeShop at 210°, FarmerShop at 240°
    -- NE arc (N-gate→E-tower): BowShop at 300°, BombShop at 330°
    _hammerShopSpawned = true
    local hammerShop = makeShop(center, "Hammer", BrickColor.new("Bright orange"), Vector3.new(-19, 2,  33))
    initRack(hammerShop, "Hammer")
    local bowShop    = makeShop(center, "Bow",    BrickColor.new("Bright blue"),   Vector3.new( 19, 2, -33))
    initRack(bowShop, "Bow")
    label(hammerShop, "Hammer Shop")
    label(bowShop,    "Bow Shop")

    -- Placeholder shops
    local function devShop(name: string, col: BrickColor, offset: Vector3)
        local p = Instance.new("Part")
        p.Name       = name .. "Shop"
        p.Size       = Vector3.new(4, 4, 4)
        p.BrickColor = col
        p.Anchored   = true
        p.CanCollide = true
        p.Position   = center + offset
        p.Parent     = workspace
        label(p, name .. " Shop")
        return p
    end

    print("[DevTown] step 3: placeholder shops")
    devShop("Pikeman", BrickColor.new("Bright red"),      Vector3.new(-33, 2,  20))  -- SW arc 150° (near W-tower)
    devShop("Upgrade", BrickColor.new("Bright yellow"),   Vector3.new(-33, 2, -20))  -- NW arc 210° (near W-gate)
    devShop("Farmer",  BrickColor.new("Bright green"),    Vector3.new(-19, 2, -33))  -- NW arc 240° (near N-tower)
    devShop("Bomb",    BrickColor.new("Dark stone grey"), Vector3.new( 33, 2, -20))  -- NE arc 330° (near E-tower)

    -- Town Hall
    print("[DevTown] step 4: town hall")
    local hall      = Instance.new("Part")
    hall.Name       = "TownHall"
    hall.Size       = Vector3.new(14, 10, 14)
    hall.BrickColor = BrickColor.new("Medium stone grey")
    hall.Anchored   = true
    hall.CanCollide = true
    hall.Position   = center + Vector3.new(24, 5, 24)  -- swapped with FarmerShop
    hall.Parent     = workspace
    label(hall, "Town Hall")

    -- Cardinal defenses
    print("[DevTown] step 5: cardinal defenses")
    WorldService.unlockCardinalDefenses()
    WorldService.autoCompleteTownStructures()
    for _, child in workspace:GetChildren() do
        if not child:IsA("BasePart") then continue end
        local sType = child:GetAttribute("StructureType")
        if sType == "Tower"     then label(child :: BasePart, "Tower")     end
        if sType == "Barricade" then label(child :: BasePart, "Gate")      end
    end

    -- Circular perimeter walls
    print("[DevTown] step 6: perimeter walls")
    WorldService.spawnPerimeterWalls()

    -- 8 portals — all pulled 50 studs closer to center vs island edge (islandR=510 → edgeR=460)
    -- Portal numbering: 1=E  2=SE  3=S  4=SW  5=W  6=NW  7=N  8=in-front-of-1
    -- NE edge (old portal 8 spot) left open for crashed boat spawn
    print("[DevTown] step 7: portals")
    local pi         = math.pi
    local cos, sin   = math.cos, math.sin
    local edgeR      = 410   -- edge portals pulled in another 50 (was 460)
    local inR        = 310   -- diagonal inset portals pulled in 50 (was 360)
    -- Dungeon Z=440 → front face Z=420; portal 3 now 100 studs north of face (gap doubled)
    -- Guardian Z=-370; portal 7 now 100 studs south of guardian (gap doubled)
    local portalPositions = {
        Vector3.new( edgeR,              0,  0                     ),  -- 1 E
        Vector3.new( cos(pi/4)  * inR,   0,  sin(pi/4)  * inR     ),  -- 2 SE inset
        Vector3.new( 0,                  0,  320                   ),  -- 3 S  100N of dungeon face (Z=420)
        Vector3.new( cos(3*pi/4)*edgeR,  0,  sin(3*pi/4)*edgeR    ),  -- 4 SW
        Vector3.new(-inR,                0,  0                     ),  -- 5 W  inset
        Vector3.new( cos(5*pi/4)*edgeR,  0,  sin(5*pi/4)*edgeR    ),  -- 6 NW
        Vector3.new( 0,                  0, -270                   ),  -- 7 N  100S of guardian (Z=-370)
        Vector3.new( edgeR - 50,         0,  0                     ),  -- 8 E-axis 50W of portal 1
    }
    for i, offset in portalPositions do
        local p = makePortal(center + offset)
        table.insert(_portals, p)
        label(p, "Portal " .. i)
    end

    -- Guardian placeholder
    print("[DevTown] step 8: guardian + dungeon")
    local guardian      = Instance.new("Part")
    guardian.Name       = "BigBreeder"
    guardian.Size       = Vector3.new(12, 20, 12)
    guardian.BrickColor = BrickColor.new("Maroon")
    guardian.Anchored   = true
    guardian.CanCollide = true
    guardian.Position   = center + Vector3.new(0, 10, -370)  -- pulled 50 closer (was -420)
    guardian.Parent     = workspace
    label(guardian, "Guardian")

    -- Lighthouse: north edge behind guardian (guardian Z=-420, lighthouse Z=-490)
    -- Base → shaft → light cap stacked vertically
    local lhBase          = Instance.new("Part")
    lhBase.Name           = "LighthouseBase"
    lhBase.Size           = Vector3.new(14, 4, 14)
    lhBase.BrickColor     = BrickColor.new("Medium stone grey")
    lhBase.Material       = Enum.Material.SmoothPlastic
    lhBase.Anchored       = true
    lhBase.CanCollide     = true
    lhBase.Position       = center + Vector3.new(0, 2, -440)  -- pulled 50 closer (was -490)
    lhBase.Parent         = workspace

    local lhShaft         = Instance.new("Part")
    lhShaft.Name          = "LighthouseTower"
    lhShaft.Size          = Vector3.new(8, 40, 8)
    lhShaft.BrickColor    = BrickColor.new("White")
    lhShaft.Material      = Enum.Material.SmoothPlastic
    lhShaft.Anchored      = true
    lhShaft.CanCollide    = true
    lhShaft.Position      = center + Vector3.new(0, 24, -440)
    lhShaft.Parent        = workspace

    local lhLight         = Instance.new("Part")
    lhLight.Name          = "LighthouseLight"
    lhLight.Size          = Vector3.new(12, 8, 12)
    lhLight.BrickColor    = BrickColor.new("Bright yellow")
    lhLight.Material      = Enum.Material.Neon
    lhLight.Transparency  = 0.2
    lhLight.Anchored      = true
    lhLight.CanCollide    = true
    lhLight.Position      = center + Vector3.new(0, 48, -440)
    lhLight.Parent        = workspace
    label(lhLight, "Lighthouse")

    -- Crashed boat repair site: between guardian (Z=-370) and lighthouse (Z=-440)
    local boat          = Instance.new("Part")
    boat.Name           = "BrokenBoat"
    boat.Size           = Vector3.new(12, 4, 30)
    boat.BrickColor     = BrickColor.new("Dark orange")
    boat.Material       = Enum.Material.Wood
    boat.Anchored       = true
    boat.CanCollide     = true
    boat.Position       = center + Vector3.new(360, 2, -360)  -- NE island edge, between lighthouse (N) and portal 1 (E)
    boat:SetAttribute("Level",           0)
    boat:SetAttribute("Marked",          false)
    boat:SetAttribute("BuildProgress",   0)
    boat:SetAttribute("BuildRequired",   GameConfig.BOAT_REPAIR_DURATION)
    boat:SetAttribute("MaxBuilders",     GameConfig.BOAT_MAX_BUILDERS)
    boat:SetAttribute("CurrentBuilders", 0)
    boat.Parent         = workspace
    label(boat, "Broken Boat")

    -- Dungeon: mountain silhouette (center Z=440, base north face at Z=400)
    local mtnZ = 440
    local caveZ = mtnZ - 40  -- north face of base layer (80/2 = 40)

    local function mtnLayer(xz: number, h: number, yc: number, col: BrickColor, mat: Enum.Material)
        local p          = Instance.new("Part")
        p.Name           = "DungeonMountain"
        p.Size           = Vector3.new(xz, h, xz)
        p.BrickColor     = col
        p.Material       = mat
        p.Anchored       = true
        p.CanCollide     = true
        p.Position       = center + Vector3.new(0, yc, mtnZ)
        p.Parent         = workspace
        return p
    end

    local grey1 = BrickColor.new("Medium stone grey")
    local grey2 = BrickColor.new("Light stone grey")
    mtnLayer(80, 16,  8,   grey1, Enum.Material.Cobblestone)
    mtnLayer(60, 14, 23,   grey1, Enum.Material.SmoothPlastic)
    mtnLayer(40, 12, 36,   grey1, Enum.Material.SmoothPlastic)
    mtnLayer(22, 10, 46,   grey2, Enum.Material.SmoothPlastic)
    local peak = mtnLayer(10,  8, 54,   BrickColor.new("White"), Enum.Material.SmoothPlastic)
    label(peak, "Dungeon Mountain")

    -- Cave entrance on north face of mountain base
    local darkGrey = BrickColor.new("Dark stone grey")
    local function caveRock(sz: Vector3, off: Vector3)
        local p          = Instance.new("Part")
        p.Name           = "CaveRock"
        p.Size           = sz
        p.BrickColor     = darkGrey
        p.Material       = Enum.Material.Cobblestone
        p.Anchored       = true
        p.CanCollide     = true
        p.Position       = center + off
        p.Parent         = workspace
        return p
    end

    -- Flanking pillars and lintel form a rough cave arch
    caveRock(Vector3.new(5, 14, 5), Vector3.new( -8,  7, caveZ - 2))  -- left pillar
    caveRock(Vector3.new(5, 14, 5), Vector3.new(  8,  7, caveZ - 2))  -- right pillar
    caveRock(Vector3.new(20, 5, 5), Vector3.new(  0, 15, caveZ - 2))  -- top arch
    caveRock(Vector3.new( 4,  4, 4), Vector3.new( -8, 18, caveZ - 2))  -- top-left boulder
    caveRock(Vector3.new( 4,  4, 4), Vector3.new(  8, 18, caveZ - 2))  -- top-right boulder

    -- Cave void: black recess gives depth illusion
    local void          = Instance.new("Part")
    void.Name           = "CaveVoid"
    void.Size           = Vector3.new(10, 10, 4)
    void.BrickColor     = BrickColor.new("Really black")
    void.Material       = Enum.Material.SmoothPlastic
    void.Anchored       = true
    void.CanCollide     = false
    void.Position       = center + Vector3.new(0, 5, caveZ + 2)
    void.Parent         = workspace

    -- Cave portal glow (the actual transport trigger — dark indigo neon)
    local dp            = Instance.new("Part")
    dp.Name             = "DungeonPortal"
    dp.Size             = Vector3.new(8, 8, 1)
    dp.BrickColor       = BrickColor.new("Dark indigo")
    dp.Material         = Enum.Material.Neon
    dp.Transparency     = 0.35
    dp.Anchored         = true
    dp.CanCollide       = false
    dp.Position         = center + Vector3.new(0, 5, caveZ - 0.5)
    dp.Parent           = workspace
    label(dp, "Enter Dungeon")

    print("[WorldService] Dev town fully spawned")
end

return WorldService
