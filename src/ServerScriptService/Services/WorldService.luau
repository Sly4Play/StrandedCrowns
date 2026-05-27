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

local _shieldMounts: {BasePart} = {}
local _shieldVisuals: {[BasePart]: BasePart} = {}
local _townHallTier = 0
local _mayorAiRunning = false

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

local function label(part: BasePart, text: string)
    local bb       = Instance.new("BillboardGui")
    bb.Size        = UDim2.new(0, 220, 0, 40)
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

-- Spawns (or rebuilds) the firepit visual for tiers 0-6.
-- Tier 0 = 4 smouldering sticks; tier 6 = great bonfire log stack.
-- All parts live in a Model named "FirePitModel"; the central "FirePit" part
-- (invisible) holds the Fire particle so Bootstrap can still find it.
local function spawnFirepit(center: Vector3, tier: number)
    local existing = workspace:FindFirstChild("FirePitModel")
    if existing then existing:Destroy() end

    local model = Instance.new("Model")
    model.Name  = "FirePitModel"

    local logCol   = BrickColor.new("Reddish brown")
    local stoneCol = BrickColor.new("Medium stone grey")
    local ashCol   = BrickColor.new("Dark stone grey")

    local function mkLog(sz: Vector3, cf: CFrame)
        local p = Instance.new("Part"); p.Name = "Log"
        p.Size = sz; p.BrickColor = logCol; p.Material = Enum.Material.Wood
        p.Anchored = true; p.CanCollide = false; p.CFrame = cf; p.Parent = model
    end
    local function mkStone(sz: Vector3, cf: CFrame)
        local p = Instance.new("Part"); p.Name = "Stone"
        p.Size = sz; p.BrickColor = stoneCol; p.Material = Enum.Material.Cobblestone
        p.Anchored = true; p.CanCollide = false; p.CFrame = cf; p.Parent = model
    end
    local function mkBase(sz: Vector3, pos: Vector3, col: BrickColor, mat: Enum.Material): BasePart
        local p = Instance.new("Part"); p.Name = "FireBase"
        p.Size = sz; p.BrickColor = col; p.Material = mat
        p.Anchored = true; p.CanCollide = false; p.Position = pos; p.Parent = model
        return p
    end
    -- N logs radiating from center, length `len`, diameter `dia`, at height y, rotated by `off`
    local function logRing(n: number, len: number, dia: number, y: number, off: number)
        for i = 0, n - 1 do
            local a = i * (2 * math.pi / n) + off
            mkLog(Vector3.new(len, dia, dia),
                CFrame.new(center + Vector3.new(0, y, 0)) * CFrame.Angles(0, a, 0))
        end
    end
    -- N stones evenly spaced on a circle of radius r at height y
    local function stoneRing(n: number, r: number, sz: Vector3, y: number)
        for i = 0, n - 1 do
            local a = i * (2 * math.pi / n)
            mkStone(sz, CFrame.new(center + Vector3.new(math.cos(a)*r, y, math.sin(a)*r)))
        end
    end

    -- Invisible anchor Part that holds the Fire particle
    local firePart = Instance.new("Part")
    firePart.Name         = "FirePit"
    firePart.Size         = Vector3.new(1, 0.2, 1)
    firePart.Transparency = 1
    firePart.Anchored     = true
    firePart.CanCollide   = false
    firePart.Parent       = model

    local fire = Instance.new("Fire")

    if tier == 0 then
        -- 4 smouldering sticks on an ash patch; barely alight
        firePart.Position = center + Vector3.new(0, 0.4, 0)
        fire.Size = 1; fire.Heat = 1
        mkBase(Vector3.new(4, 0.2, 4), center + Vector3.new(0, 0.1, 0), ashCol, Enum.Material.SmoothPlastic)
        mkLog(Vector3.new(3.5, 0.4, 0.4), CFrame.new(center + Vector3.new( 0,    0.3,  0.6)))
        mkLog(Vector3.new(3.5, 0.4, 0.4), CFrame.new(center + Vector3.new( 0,    0.3, -0.6)))
        mkLog(Vector3.new(0.4, 0.4, 3.5), CFrame.new(center + Vector3.new( 0.6,  0.3,  0  )))
        mkLog(Vector3.new(0.4, 0.4, 3.5), CFrame.new(center + Vector3.new(-0.6,  0.3,  0  )))

    elseif tier == 1 then
        -- 4 logs in a cross; kindling catches
        firePart.Position = center + Vector3.new(0, 0.6, 0)
        fire.Size = 4; fire.Heat = 5
        mkBase(Vector3.new(5, 0.2, 5), center + Vector3.new(0, 0.1, 0), ashCol, Enum.Material.SmoothPlastic)
        logRing(4, 5, 0.7, 0.45, 0)

    elseif tier == 2 then
        -- 6-log star + first stone ring; campfire proper
        firePart.Position = center + Vector3.new(0, 0.9, 0)
        fire.Size = 9; fire.Heat = 10
        mkBase(Vector3.new(6, 0.2, 6), center + Vector3.new(0, 0.1, 0), ashCol, Enum.Material.SmoothPlastic)
        logRing(6, 5.5, 0.7, 0.45, 0)
        stoneRing(6, 2.8, Vector3.new(0.8, 0.5, 0.8), 0.25)

    elseif tier == 3 then
        -- Stone ring + base logs + 2 crossed logs on top; fire getting serious
        firePart.Position = center + Vector3.new(0, 1.5, 0)
        fire.Size = 13; fire.Heat = 14
        mkBase(Vector3.new(7, 0.3, 7), center + Vector3.new(0, 0.15, 0), ashCol, Enum.Material.SmoothPlastic)
        stoneRing(8, 3.2, Vector3.new(1, 0.8, 1), 0.4)
        logRing(6, 5.5, 0.8, 0.5, 0)
        mkLog(Vector3.new(5, 0.8, 0.8), CFrame.new(center + Vector3.new(0, 1.4, 0)))
        mkLog(Vector3.new(0.8, 0.8, 5), CFrame.new(center + Vector3.new(0, 1.4, 0)))

    elseif tier == 4 then
        -- Stone pit walls + 3-layer log stack; fire pit
        firePart.Position = center + Vector3.new(0, 2.3, 0)
        fire.Size = 18; fire.Heat = 17
        mkBase(Vector3.new(8, 0.5, 8), center + Vector3.new(0, 0.25, 0), stoneCol, Enum.Material.Cobblestone)
        -- 4 arc wall segments forming a stone pit ring
        for i = 0, 3 do
            local a = i * math.pi / 2
            mkStone(Vector3.new(3.2, 1.2, 0.8),
                CFrame.new(center + Vector3.new(0, 0.9, 0)) * CFrame.Angles(0, a, 0) * CFrame.new(0, 0, 3.5))
        end
        logRing(6, 6, 0.9, 0.5, 0)
        logRing(4, 5, 0.9, 1.45, math.pi / 4)
        mkLog(Vector3.new(4.5, 0.9, 0.9), CFrame.new(center + Vector3.new(0, 2.4, 0)))
        mkLog(Vector3.new(0.9, 0.9, 4.5), CFrame.new(center + Vector3.new(0, 2.4, 0)))

    elseif tier == 5 then
        -- Large stone ring, 4-layer bonfire
        firePart.Position = center + Vector3.new(0, 3.3, 0)
        fire.Size = 24; fire.Heat = 21
        mkBase(Vector3.new(9, 0.6, 9), center + Vector3.new(0, 0.3, 0), stoneCol, Enum.Material.Cobblestone)
        stoneRing(8, 4.2, Vector3.new(1.2, 1.5, 1.2), 0.75)
        logRing(8, 7, 1, 0.6, 0)
        logRing(6, 6, 1, 1.6, math.pi / 6)
        logRing(4, 5, 1, 2.6, math.pi / 4)
        mkLog(Vector3.new(4, 1, 1), CFrame.new(center + Vector3.new(0, 3.6, 0)))
        mkLog(Vector3.new(1, 1, 4), CFrame.new(center + Vector3.new(0, 3.6, 0)))

    else -- tier == 6: Great Bonfire
        firePart.Position = center + Vector3.new(0, 4.6, 0)
        fire.Size = 30; fire.Heat = 25
        mkBase(Vector3.new(10, 0.8, 10), center + Vector3.new(0, 0.4, 0), stoneCol, Enum.Material.Cobblestone)
        stoneRing(8, 4.8, Vector3.new(1.5, 2, 1.5), 1)
        logRing(8, 8, 1.2, 0.7, 0)
        logRing(6, 7, 1.2, 1.9, math.pi / 6)
        logRing(6, 6, 1.2, 3.1, 0)
        logRing(4, 5, 1.2, 4.2, math.pi / 4)
        mkLog(Vector3.new(4.5, 1.2, 1.2), CFrame.new(center + Vector3.new(0, 5.4, 0)))
        mkLog(Vector3.new(1.2, 1.2, 4.5), CFrame.new(center + Vector3.new(0, 5.4, 0)))
    end

    fire.Parent = firePart

    -- Tier 1+ fires are solid — players and NPCs can no longer walk through them.
    if tier >= 1 then
        for _, part in ipairs(model:GetDescendants()) do
            if part:IsA("BasePart") and part ~= firePart then
                part.CanCollide = true
            end
        end
    end

    label(firePart, "FirePit Lvl " .. tier)
    model.Parent = workspace
end

-- Spawns (or rebuilds) the tower visual for tiers 0-6.
-- `anchor` is the BasePart in workspace that NpcService tracks for attributes.
-- Visual geometry lives in a sibling Model named anchor.Name.."_Vis".
-- Tier 0 = dirt patch marker; tier 1 = earthen mound; tiers 2-6 = progressively
-- taller/stonier fortifications.
local function spawnTower(anchor: BasePart, tier: number)
    local visName = anchor.Name .. "_Vis"
    local old = workspace:FindFirstChild(visName)
    if old then old:Destroy() end

    anchor:SetAttribute("UpgradeTier", tier)  -- replicated to clients for bubble cost

    -- Reset anchor to a clean ground-level invisible pin; NpcService still finds it
    anchor.Position    = Vector3.new(anchor.Position.X, 0, anchor.Position.Z)
    anchor.Size        = Vector3.new(1, 0.1, 1)
    anchor.Transparency = 1
    anchor.CanCollide  = false

    if tier == 0 then
        anchor.Size        = Vector3.new(6, 0.3, 6)
        anchor.BrickColor  = BrickColor.new("Sand yellow brown")
        anchor.Material    = Enum.Material.Ground
        anchor.Transparency = 0.3
        anchor:SetAttribute("MaxOccupants", 0)
        return
    end

    local model = Instance.new("Model")
    model.Name  = visName

    local cf       = anchor.CFrame  -- LookVector points toward town center
    local woodCol  = BrickColor.new("Reddish brown")
    local darkWood = BrickColor.new("Dark orange")
    local stoneCol = BrickColor.new("Medium stone grey")

    local function mk(nm: string, sz: Vector3, lx: number, ly: number, lz: number, col: BrickColor, mat: Enum.Material?)
        local p = Instance.new("Part")
        p.Name           = nm
        p.Size           = sz
        p.BrickColor     = col
        p.Material       = mat or Enum.Material.Wood
        p.Anchored       = true
        p.CanCollide     = true
        p.CollisionGroup = "Defense"
        p.CFrame         = cf * CFrame.new(lx, ly, lz)
        p.Parent         = model
    end

    if tier == 1 then
        -- Earthen mound, 1 archer exposed on top
        mk("Base",     Vector3.new(8,   0.3, 8),    0,  0.15,  0, BrickColor.new("Sand yellow"), Enum.Material.Ground)
        mk("Mound",    Vector3.new(5,   2.5, 5),    0,  1.5,   0, woodCol, Enum.Material.SmoothPlastic)
        mk("Platform", Vector3.new(4.5, 0.4, 4.5),  0,  2.95,  0, woodCol, Enum.Material.SmoothPlastic)
        anchor:SetAttribute("MaxOccupants", 1)
        anchor:SetAttribute("ArcherY", 3.5)

    elseif tier == 2 then
        -- Wooden palisade: 3 solid walls + short front parapet; archer protected
        mk("Base",      Vector3.new(8.5, 0.5, 8.5),  0,    0.25,  0,    woodCol, Enum.Material.SmoothPlastic)
        mk("BackWall",  Vector3.new(8.5, 9,   1.2),  0,    5,     3.6,  woodCol)
        mk("LeftWall",  Vector3.new(1.2, 9,   7.2), -3.6,  5,     0,    woodCol)
        mk("RightWall", Vector3.new(1.2, 9,   7.2),  3.6,  5,     0,    woodCol)
        mk("FrontWall", Vector3.new(8.5, 4,   1.2),  0,    2.25, -3.6,  woodCol)
        mk("Platform",  Vector3.new(6,   0.5, 6),    0,    9.25,  0,    woodCol)
        anchor:SetAttribute("MaxOccupants", 1)
        anchor:SetAttribute("ArcherY", 10)

    elseif tier == 3 then
        -- Taller palisade with overhang roof, 2 archers
        mk("Base",      Vector3.new(9.5,  0.5,  9.5),   0,     0.25,  0,     woodCol, Enum.Material.SmoothPlastic)
        mk("BackWall",  Vector3.new(9.5,  11,   1.5),   0,     6,     4.25,  woodCol)
        mk("LeftWall",  Vector3.new(1.5,  11,   8.5),  -4.25,  6,     0,     woodCol)
        mk("RightWall", Vector3.new(1.5,  11,   8.5),   4.25,  6,     0,     woodCol)
        mk("FrontWall", Vector3.new(9.5,  5,    1.5),   0,     3,    -4.25,  woodCol)
        mk("Platform",  Vector3.new(8,    0.6,  7.5),   0,    11.55,  0,     woodCol)
        mk("Roof",      Vector3.new(10.5, 0.7,  10.5),  0,    12.25,  0,     darkWood)
        anchor:SetAttribute("MaxOccupants", 2)
        anchor:SetAttribute("ArcherY", 12.5)

    elseif tier == 4 then
        -- 2-story pyramid: wide lower level (2 archers) + narrow upper (1 archer)
        mk("Base",       Vector3.new(12.5, 0.6,  12.5),  0,      0.3,    0,      woodCol, Enum.Material.SmoothPlastic)
        mk("LowerBack",  Vector3.new(11,   7,    1.5),   0,      4,      5,      woodCol)
        mk("LowerLeft",  Vector3.new(1.5,  7,    10),   -5,      4,      0,      woodCol)
        mk("LowerRight", Vector3.new(1.5,  7,    10),    5,      4,      0,      woodCol)
        mk("LowerFront", Vector3.new(11,   3,    1.5),   0,      2,     -5,      woodCol)
        mk("LowerPlat",  Vector3.new(10,   0.6,  9.5),   0.25,   7.55,   0.25,   woodCol)
        mk("UpperBack",  Vector3.new(7,    6,    1.5),   0,     11.5,    2.5,    darkWood)
        mk("UpperLeft",  Vector3.new(1.5,  6,    5.5),  -2.75, 11.5,    0.5,    darkWood)
        mk("UpperRight", Vector3.new(1.5,  6,    5.5),   2.75, 11.5,    0.5,    darkWood)
        mk("UpperFront", Vector3.new(7,    3,    1.5),   0,     9.5,   -2.25,   darkWood)
        mk("UpperPlat",  Vector3.new(6.5,  0.5,  5.5),   0,    14.55,   0.75,   darkWood)
        anchor:SetAttribute("MaxOccupants", 3)
        anchor:SetAttribute("ArcherY", 15)

    elseif tier == 5 then
        -- Watch tower: solid body, wide overhang platform, 3 archers same level
        mk("Base",      Vector3.new(11.5, 0.8, 11.5),  0,    0.4,    0,    darkWood)
        mk("BackWall",  Vector3.new(10,   13,  2),      0,    7,      4.5,  darkWood)
        mk("LeftWall",  Vector3.new(2,    13,  9),     -4.5,  7,      0,    darkWood)
        mk("RightWall", Vector3.new(2,    13,  9),      4.5,  7,      0,    darkWood)
        mk("FrontWall", Vector3.new(10,   5.5, 2),      0,    3.5,   -4.5,  darkWood)
        mk("TopPlat",   Vector3.new(12,   0.7, 12),     0,   13.85,   0,    darkWood)
        mk("PostBL",    Vector3.new(1.5,  2.5, 1.5),   -5,   15.1,   5,    darkWood)
        mk("PostBR",    Vector3.new(1.5,  2.5, 1.5),    5,   15.1,   5,    darkWood)
        mk("PostFL",    Vector3.new(1.5,  2.5, 1.5),   -5,   15.1,  -4.5,  darkWood)
        mk("PostFR",    Vector3.new(1.5,  2.5, 1.5),    5,   15.1,  -4.5,  darkWood)
        anchor:SetAttribute("MaxOccupants", 3)
        anchor:SetAttribute("ArcherY", 15)

    else -- tier == 6: Stone Fortress
        mk("Base",      Vector3.new(14, 1,    14),     0,     0.5,   0,    stoneCol, Enum.Material.Cobblestone)
        mk("BackWall",  Vector3.new(12, 15,   2),      0,     8.5,   5.5,  stoneCol, Enum.Material.Cobblestone)
        mk("LeftWall",  Vector3.new(2,  15,   11),    -5.5,   8.5,   0,    stoneCol, Enum.Material.Cobblestone)
        mk("RightWall", Vector3.new(2,  15,   11),     5.5,   8.5,   0,    stoneCol, Enum.Material.Cobblestone)
        mk("FrontWall", Vector3.new(12, 7,    2),      0,     4.5,  -5.5,  stoneCol, Enum.Material.Cobblestone)
        mk("TopPlat",   Vector3.new(14, 0.8,  14),     0,    16.4,   0,    stoneCol, Enum.Material.Cobblestone)
        for i = -2, 2 do
            mk("MB"..i, Vector3.new(1.5, 2.5, 1.5), i * 2.4,  18,  5.5,  stoneCol, Enum.Material.Cobblestone)
            mk("ML"..i, Vector3.new(1.5, 2.5, 1.5),    -5.5,  18,  i * 2, stoneCol, Enum.Material.Cobblestone)
            mk("MR"..i, Vector3.new(1.5, 2.5, 1.5),     5.5,  18,  i * 2, stoneCol, Enum.Material.Cobblestone)
        end
        mk("MF1", Vector3.new(1.5, 2.5, 1.5), -4, 18, -5.5, stoneCol, Enum.Material.Cobblestone)
        mk("MF2", Vector3.new(1.5, 2.5, 1.5),  0, 18, -5.5, stoneCol, Enum.Material.Cobblestone)
        mk("MF3", Vector3.new(1.5, 2.5, 1.5),  4, 18, -5.5, stoneCol, Enum.Material.Cobblestone)
        anchor:SetAttribute("MaxOccupants", 4)
        anchor:SetAttribute("ArcherY", 17.5)
    end

    model.Parent = workspace
end

-- Town hall rebuilds in sync with firepit tier (1=tent … 6=grand hall).
-- Tier 0 removes all town-hall visuals (and legacy mayor foundation plates).
-- Build slot is SE of center. Parts are built in local space (front = -Z flat face),
-- then the whole model is rotated so that face points at the firepit.
local function spawnTownHall(tier: number)
    if tier == 0 then
        local existing = workspace:FindFirstChild("TownHallModel")
        if existing then existing:Destroy() end
        local legacyHall = workspace:FindFirstChild("TownHall")
        if legacyHall and legacyHall:IsA("BasePart") then legacyHall:Destroy() end
        local mayorPlate = workspace:FindFirstChild("MayorHouse_Foundation")
        if mayorPlate then mayorPlate:Destroy() end
        _shieldMounts = {}
        _shieldVisuals = {}
        _townHallTier = 0
        return true
    end

    local model = Instance.new("Model")
    model.Name  = "TownHallModel"
    local base  = GameConfig.TOWN_CENTER_POS + GameConfig.TOWN_HALL_OFFSET
    local GY    = 0

    local toward = (GameConfig.TOWN_CENTER_POS - base).Unit
    local worldCF = CFrame.lookAt(
        Vector3.new(base.X, GY, base.Z),
        Vector3.new(base.X + toward.X, GY, base.Z + toward.Z)
    )

    local woodCol    = BrickColor.new("Reddish brown")
    local canvasCol  = BrickColor.new("Brick yellow")
    local stoneCol   = BrickColor.new("Medium stone grey")
    local lightStone = BrickColor.new("Light stone grey")
    local roofCol    = BrickColor.new("Dark stone grey")
    local trimCol    = BrickColor.new("Brown")
    local accentCol  = BrickColor.new("Bright yellow")
    local winCol     = BrickColor.new("Cyan")
    local interiorCol = BrickColor.new("Pastel brown")

    local newShieldMounts: {BasePart} = {}

    local function place(name: string, sz: Vector3, localCF: CFrame, col: BrickColor, mat: Enum.Material?)
        local p = Instance.new("Part")
        p.Name = name; p.Size = sz; p.BrickColor = col
        p.Material = mat or Enum.Material.SmoothPlastic
        p.Anchored = true; p.CanCollide = true
        p.CFrame = worldCF * localCF
        p.Parent = model
        return p
    end

    local function box(name: string, sx: number, sy: number, sz: number, lx: number, ly: number, lz: number, col: BrickColor, mat: Enum.Material?)
        return place(name, Vector3.new(sx, sy, sz), CFrame.new(lx, ly, lz), col, mat)
    end

    local function onFloor(name: string, sx: number, sy: number, sz: number, lx: number, lz: number, col: BrickColor, mat: Enum.Material?)
        box(name, sx, sy, sz, lx, sy * 0.5, lz, col, mat)
    end

    local function stackOn(name: string, sx: number, sy: number, sz: number, lx: number, lz: number, yBot: number, col: BrickColor, mat: Enum.Material?)
        box(name, sx, sy, sz, lx, yBot + sy * 0.5, lz, col, mat)
    end

    local function addWindowGlow(part: BasePart)
        part.Transparency = 0.25
        part.Material = Enum.Material.Glass
        local light = Instance.new("PointLight")
        light.Brightness = 1.4
        light.Range = 12
        light.Color = Color3.fromRGB(255, 195, 110)
        light.Parent = part
    end

    local function frontDoor(name: string, w: number, h: number, halfZ: number, yBot: number, col: BrickColor, th: number?)
        local t = th or 0.25
        box(name, w, h, t, 0, yBot + h * 0.5, -(halfZ + t * 0.5 + 0.08), col, Enum.Material.Wood)
    end

    local function frontSteps(w: number, d: number, h: number, edgeHalfZ: number, yBot: number, col: BrickColor, mat: Enum.Material?)
        box("Steps", w, h, d, 0, yBot + h * 0.5, -(edgeHalfZ + d * 0.5), col, mat)
    end

    local function frontColumn(name: string, size: number, h: number, halfZ: number, yBot: number, xOff: number, col: BrickColor, mat: Enum.Material?)
        box(name, size, h, size, xOff, yBot + h * 0.5, -(halfZ + size * 0.35), col, mat)
    end

    local function frontWallWithDoor(halfZ: number, yBot: number, wallH: number, wallW: number, doorW: number, doorH: number, wallTh: number, col: BrickColor, mat: Enum.Material?)
        local z = -(halfZ - wallTh * 0.5)
        local sideW = (wallW - doorW) * 0.5
        box("WallFL", sideW, wallH, wallTh, -(doorW * 0.5 + sideW * 0.5), yBot + wallH * 0.5, z, col, mat)
        box("WallFR", sideW, wallH, wallTh,  (doorW * 0.5 + sideW * 0.5), yBot + wallH * 0.5, z, col, mat)
        local topH = wallH - doorH
        if topH > 0.1 then
            box("WallFTop", doorW, topH, wallTh, 0, yBot + doorH + topH * 0.5, z, col, mat)
        end
    end

    local function frontWallSolid(halfZ: number, yBot: number, wallH: number, wallW: number, wallTh: number, col: BrickColor, mat: Enum.Material?)
        box("WallFront", wallW, wallH, wallTh, 0, yBot + wallH * 0.5, -(halfZ - wallTh * 0.5), col, mat)
    end

    local function sideWallWithWindow(prefix: string, xWall: number, halfZ: number, yWin: number, hWin: number, wWin: number, wallTh: number, wallH: number, yBot: number, col: BrickColor, mat: Enum.Material?, lit: boolean?)
        local halfGap = wWin * 0.5
        local yLow, yHigh = yWin - hWin * 0.5, yWin + hWin * 0.5
        local sign = xWall >= 0 and 1 or -1

        local dFront = halfZ - halfGap
        if dFront > 0.25 then
            box(prefix .. "_F", wallTh, wallH, dFront, xWall, yBot + wallH * 0.5, -(halfZ - dFront * 0.5), col, mat)
        end
        local dBack = halfZ - halfGap
        if dBack > 0.25 then
            box(prefix .. "_B", wallTh, wallH, dBack, xWall, yBot + wallH * 0.5, halfGap + dBack * 0.5, col, mat)
        end
        local topH = (yBot + wallH) - yHigh
        if topH > 0.12 then
            box(prefix .. "_T", wallTh, topH, wWin, xWall, yHigh + topH * 0.5, 0, col, mat)
        end
        local botH = yLow - yBot
        if botH > 0.12 then
            box(prefix .. "_S", wallTh, botH, wWin, xWall, yBot + botH * 0.5, 0, col, mat)
        end

        local gx = xWall + sign * (wallTh * 0.5 + 0.08)
        local glass = box(prefix .. "_Glass", 0.1, hWin, wWin, gx, yWin, 0, winCol, Enum.Material.Glass)
        glass.Transparency = 0.08
        box(prefix .. "_Fill", wallTh + 0.25, hWin - 0.08, wWin - 0.08, xWall, yWin, 0, interiorCol)
        if lit then addWindowGlow(glass) end
    end

    local function frontWindowOpening(name: string, xOff: number, yCenter: number, halfZ: number, h: number, w: number, wallTh: number, col: BrickColor, mat: Enum.Material?, lit: boolean?)
        local zWall = -(halfZ - wallTh * 0.5)
        box(name .. "_Top", w, 0.35, wallTh, xOff, yCenter + h * 0.5 + 0.18, zWall, col, mat)
        box(name .. "_Bot", w, 0.35, wallTh, xOff, yCenter - h * 0.5 - 0.18, zWall, col, mat)
        local glass = box(name .. "_Glass", w, h, 0.1, xOff, yCenter, -(halfZ + 0.12), winCol, Enum.Material.Glass)
        glass.Transparency = 0.08
        box(name .. "_Fill", w - 0.08, h - 0.08, wallTh + 0.2, xOff, yCenter, -(halfZ - wallTh * 0.5), interiorCol)
        if lit then addWindowGlow(glass) end
    end

    local function wedge(name: string, sz: Vector3, localCF: CFrame, col: BrickColor, mat: Enum.Material?)
        local w = Instance.new("WedgePart")
        w.Name = name; w.Size = sz; w.BrickColor = col
        w.Material = mat or Enum.Material.SmoothPlastic
        w.Anchored = true; w.CanCollide = true
        w.CFrame = worldCF * localCF
        w.Parent = model
        return w
    end

    local function frontArch(doorW: number, halfZ: number, yBot: number, col: BrickColor)
        local zFace = -(halfZ + 0.35)
        local lintelY = yBot + 6.0
        box("Lintel", doorW + 2.2, 0.7, 0.55, 0, lintelY, zFace, col, Enum.Material.Cobblestone)
        wedge("ArchL", Vector3.new(1.1, 1.1, 0.55),
            CFrame.new(-doorW * 0.5 - 0.55, yBot + 4.8, zFace) * CFrame.Angles(0, math.rad(90), math.rad(-90)),
            col, Enum.Material.Cobblestone)
        wedge("ArchR", Vector3.new(1.1, 1.1, 0.55),
            CFrame.new( doorW * 0.5 + 0.55, yBot + 4.8, zFace) * CFrame.Angles(0, math.rad(-90), math.rad(90)),
            col, Enum.Material.Cobblestone)
        wedge("ArchKey", Vector3.new(1.0, 0.9, 0.55),
            CFrame.new(0, lintelY + 0.35, zFace) * CFrame.Angles(math.rad(180), math.rad(90), 0),
            col, Enum.Material.Cobblestone)
    end

    local function spawnKnightShieldMounts(halfZ: number, yBot: number, doorHalfW: number)
        local xInner = doorHalfW + 1.15
        local xOuter = doorHalfW + 2.55
        local slotOffsets = { -xOuter, -xInner, xInner, xOuter }
        for i, xOff in ipairs(slotOffsets) do
            local mount = Instance.new("Part")
            mount.Name = "KnightShieldMount"
            mount.Size = Vector3.new(0.7, 1.5, 0.35)
            mount.Transparency = 1
            mount.CanCollide = false
            mount.Anchored = true
            mount.CFrame = worldCF * CFrame.new(xOff, yBot + 3.2, -(halfZ + 0.12))
            mount:SetAttribute("SlotId", i)
            mount:SetAttribute("HasShield", false)
            mount:SetAttribute("HasBanner", false)
            mount:SetAttribute("MountType", "KnightShield")
            mount.Parent = model
            table.insert(newShieldMounts, mount)
        end
    end

    local anchor = Instance.new("Part")
    anchor.Name = "TownHall"; anchor.Size = Vector3.new(1, 1, 1)
    anchor.Transparency = 1; anchor.CanCollide = false
    anchor.Anchored = true; anchor.Parent = model

    local buildOk, buildErr = pcall(function()
        if tier == 1 then
            anchor.CFrame = worldCF * CFrame.new(0, 5, 0)
            onFloor("Floor", 8, 0.15, 8, 0, 0, canvasCol)
            for _, xz in { {3.5, 3.5}, {-3.5, 3.5}, {3.5, -3.5}, {-3.5, -3.5} } do
                onFloor("Pole", 0.3, 5.5, 0.3, xz[1], xz[2], trimCol, Enum.Material.Wood)
            end
            box("WallE", 0.12, 4.5, 7.5, 3.75, 2.25, 0, canvasCol)
            box("WallBack", 7.5, 4.5, 0.12, 0, 2.25, 3.75, canvasCol)
            wedge("RoofL", Vector3.new(8.5, 2.5, 5), CFrame.new(-2.2, 6.2, 0) * CFrame.Angles(0, math.rad(45), 0), canvasCol)
            wedge("RoofR", Vector3.new(8.5, 2.5, 5), CFrame.new( 2.2, 6.2, 0) * CFrame.Angles(0, math.rad(-135), 0), canvasCol)
            onFloor("FlagPole", 0.15, 7, 0.15, 0, -3.5, trimCol, Enum.Material.Wood)
            stackOn("SleepingBag", 2.2, 0.12, 1.4, -1.2, 1.2, 0.15, BrickColor.new("Bright green"))
            stackOn("SleepingBagPillow", 0.55, 0.18, 0.45, -0.5, 1.2, 0.28, BrickColor.new("Earth green"))

        elseif tier == 2 then
            local halfZ = 4.5
            local yBot = 0.35
            local wallH = 5.5
            local wallTh = 0.55
            anchor.CFrame = worldCF * CFrame.new(0, 4.5, 0)
            onFloor("Sill", 10, 0.35, 9, 0, 0, woodCol, Enum.Material.Wood)
            frontWallSolid(halfZ, yBot, wallH, 6.4, wallTh, woodCol, Enum.Material.Wood)
            box("WallBack", 10, wallH, wallTh, 0, yBot + wallH * 0.5, halfZ - wallTh * 0.5, woodCol, Enum.Material.Wood)
            sideWallWithWindow("WinE", 4.75, halfZ - 0.05, yBot + 3.2, 2.2, 1.8, wallTh, wallH, yBot, woodCol, Enum.Material.Wood, false)
            sideWallWithWindow("WinW", -4.75, halfZ - 0.05, yBot + 3.2, 2.2, 1.8, wallTh, wallH, yBot, woodCol, Enum.Material.Wood, false)
            box("InnerE", 0.1, wallH - 0.4, 8.2, 4.75 - wallTh + 0.08, yBot + wallH * 0.5, 0, interiorCol)
            box("InnerW", 0.1, wallH - 0.4, 8.2, -4.75 + wallTh - 0.08, yBot + wallH * 0.5, 0, interiorCol)
            box("InnerBack", 8.2, wallH - 0.4, 0.1, 0, yBot + wallH * 0.5, 4.2 - wallTh + 0.08, interiorCol)
            stackOn("BedFrame", 2.2, 0.45, 3, 2.6, 2.2, yBot, trimCol, Enum.Material.Wood)
            stackOn("Mattress", 2, 0.35, 2.6, 2.6, 2.2, yBot + 0.45, BrickColor.new("White"))
            stackOn("Pillow", 0.65, 0.18, 0.45, 3.35, 2.2, yBot + 0.98, BrickColor.new("White"))
            stackOn("RoofFront", 11, 0.8, 5, 0, -2.2, yBot + wallH, roofCol, Enum.Material.Wood)
            stackOn("RoofBack",  11, 0.8, 5, 0,  2.2, yBot + wallH, roofCol, Enum.Material.Wood)
            stackOn("Chimney", 1, 3.5, 1, 2.5, 2, yBot + wallH, stoneCol, Enum.Material.Cobblestone)

        elseif tier == 3 then
            local halfZ = 4.75
            local halfX = 4.75
            local wallTh = 0.65
            local yBot = 0.8
            local bodyH = 7
            local porchDepth = 2.5
            local foundationHalfZ = 5.5
            anchor.CFrame = worldCF * CFrame.new(0, 6.5, 0)
            onFloor("Foundation", 11, 0.8, 11, 0, 0, stoneCol, Enum.Material.Cobblestone)
            onFloor("PorchDeck", 5.5, 0.8, porchDepth, 0, -(foundationHalfZ + porchDepth * 0.5), lightStone, Enum.Material.Cobblestone)
            frontSteps(5.5, porchDepth, 0.8, foundationHalfZ + porchDepth, 0, lightStone, Enum.Material.Cobblestone)
            stackOn("Interior", 9.5 - wallTh * 2, bodyH - wallTh, 9.5 - wallTh * 2, 0, 0, yBot + wallTh * 0.5, interiorCol)
            frontWallWithDoor(halfZ, yBot, bodyH, 9.5, 2.5, 4.5, wallTh, stoneCol, Enum.Material.Cobblestone)
            frontDoor("Door", 2.5, 4.5, halfZ, yBot, trimCol, 0.25)
            sideWallWithWindow("WinE", halfX, halfZ, yBot + 3.5, 2.5, 2, wallTh, bodyH, yBot, stoneCol, Enum.Material.Cobblestone, false)
            sideWallWithWindow("WinW", -halfX, halfZ, yBot + 3.5, 2.5, 2, wallTh, bodyH, yBot, stoneCol, Enum.Material.Cobblestone, false)
            box("WallBack", 9.5, bodyH, wallTh, 0, yBot + bodyH * 0.5, halfZ - wallTh * 0.5, stoneCol, Enum.Material.Cobblestone)
            frontWindowOpening("WinFL", -2.2, yBot + 5.5, halfZ, 1.4, 1.8, wallTh, stoneCol, Enum.Material.Cobblestone, false)
            frontWindowOpening("WinFR",  2.2, yBot + 5.5, halfZ, 1.4, 1.8, wallTh, stoneCol, Enum.Material.Cobblestone, false)
            stackOn("Band", 9.8, 0.5, 9.8, 0, 0, yBot + bodyH, lightStone, Enum.Material.Cobblestone)
            stackOn("Roof", 11.5, 1.2, 11.5, 0, 0, yBot + bodyH + 0.25, roofCol)

        elseif tier == 4 then
            local halfZ = 5.25
            local halfX = 5.25
            local wallTh = 0.65
            local yBot = 1.0
            local bodyH = 9
            local porchDepth = 2.5
            local plinthHalfZ = 6
            anchor.CFrame = worldCF * CFrame.new(0, 8, 0)
            onFloor("Plinth", 12, 1, 12, 0, 0, stoneCol, Enum.Material.Cobblestone)
            onFloor("PorchDeck", 6, 1, porchDepth, 0, -(plinthHalfZ + porchDepth * 0.5), lightStone, Enum.Material.Cobblestone)
            frontSteps(6, porchDepth, 1, plinthHalfZ + porchDepth, 0, lightStone, Enum.Material.Cobblestone)
            stackOn("Interior", 10.5 - wallTh * 2, bodyH - wallTh, 10.5 - wallTh * 2, 0, 0, yBot + wallTh * 0.5, interiorCol)
            frontWallWithDoor(halfZ, yBot, bodyH, 10.5, 3, 5.5, wallTh, stoneCol, Enum.Material.Cobblestone)
            frontColumn("ColumnL", 1.2, 8, halfZ, yBot, -2.5, lightStone, Enum.Material.Cobblestone)
            frontColumn("ColumnR", 1.2, 8, halfZ, yBot,  2.5, lightStone, Enum.Material.Cobblestone)
            frontDoor("Door", 3, 5.5, halfZ, yBot, trimCol, 0.25)
            frontArch(3, halfZ, yBot, lightStone)
            sideWallWithWindow("WinE", halfX, halfZ, yBot + 4.5, 3, 2.2, wallTh, bodyH, yBot, stoneCol, Enum.Material.Cobblestone, true)
            sideWallWithWindow("WinW", -halfX, halfZ, yBot + 4.5, 3, 2.2, wallTh, bodyH, yBot, stoneCol, Enum.Material.Cobblestone, true)
            box("WallBack", 10.5, bodyH, wallTh, 0, yBot + bodyH * 0.5, halfZ - wallTh * 0.5, stoneCol, Enum.Material.Cobblestone)
            frontWindowOpening("WinFL", -3.5, yBot + 6.5, halfZ, 1.6, 2, wallTh, stoneCol, Enum.Material.Cobblestone, true)
            frontWindowOpening("WinFR",  3.5, yBot + 6.5, halfZ, 1.6, 2, wallTh, stoneCol, Enum.Material.Cobblestone, true)
            stackOn("Frieze", 10.8, 0.6, 10.8, 0, 0, yBot + bodyH, lightStone, Enum.Material.Cobblestone)
            stackOn("Roof", 12.5, 1.4, 12.5, 0, 0, yBot + bodyH + 0.3, roofCol)

        elseif tier == 5 then
            local halfZ = 5.5
            local halfX = 5.5
            local wallTh = 0.65
            local yBot = 1.0
            local lowerH = 8
            local porchDepth = 2.8
            anchor.CFrame = worldCF * CFrame.new(0, 10, 0)
            onFloor("Plinth", 13, 1, 13, 0, 0, stoneCol, Enum.Material.Cobblestone)
            onFloor("PorchDeck", 7, 1, porchDepth, 0, -(halfZ + porchDepth * 0.5), lightStone, Enum.Material.Cobblestone)
            frontSteps(7, porchDepth, 1, halfZ + porchDepth, 0, lightStone, Enum.Material.Cobblestone)
            stackOn("Interior", 11 - wallTh * 2, lowerH - wallTh, 11 - wallTh * 2, 0, 0, yBot + wallTh * 0.5, interiorCol)
            frontWallWithDoor(halfZ, yBot, lowerH, 11, 3.2, 6, wallTh, stoneCol, Enum.Material.Cobblestone)
            frontDoor("Door", 3.2, 6, halfZ, yBot, trimCol, 0.25)
            sideWallWithWindow("WinE1", halfX, halfZ, yBot + 3, 2.5, 2, wallTh, lowerH, yBot, stoneCol, Enum.Material.Cobblestone, false)
            sideWallWithWindow("WinE2", halfX, halfZ, yBot + 6.5, 2.5, 2, wallTh, lowerH, yBot, stoneCol, Enum.Material.Cobblestone, true)
            sideWallWithWindow("WinW1", -halfX, halfZ, yBot + 3, 2.5, 2, wallTh, lowerH, yBot, stoneCol, Enum.Material.Cobblestone, false)
            sideWallWithWindow("WinW2", -halfX, halfZ, yBot + 6.5, 2.5, 2, wallTh, lowerH, yBot, stoneCol, Enum.Material.Cobblestone, true)
            box("WallBack", 11, lowerH, wallTh, 0, yBot + lowerH * 0.5, halfZ - wallTh * 0.5, stoneCol, Enum.Material.Cobblestone)
            local upperH = 5
            local upperYBot = yBot + lowerH
            local upperHalfZ = 4.75
            stackOn("UpperFloor", 9.5, 0.4, 9.5, 0, 0, upperYBot, lightStone, Enum.Material.Cobblestone)
            stackOn("UpperInner", 8.2, upperH - 0.45, 8.2, 0, 0, upperYBot + 0.22, interiorCol)
            box("UpperBack", 9.5, upperH, wallTh, 0, upperYBot + upperH * 0.5, upperHalfZ - wallTh * 0.5, lightStone, Enum.Material.Cobblestone)
            box("UpperFrontL", 2.8, upperH, wallTh, -3.1, upperYBot + upperH * 0.5, -(upperHalfZ - wallTh * 0.5), lightStone, Enum.Material.Cobblestone)
            box("UpperFrontR", 2.8, upperH, wallTh,  3.1, upperYBot + upperH * 0.5, -(upperHalfZ - wallTh * 0.5), lightStone, Enum.Material.Cobblestone)
            stackOn("Roof", 13.5, 1.5, 13.5, 0, 0, upperYBot + upperH, roofCol)
            stackOn("Tower", 4, 12, 4, 3.5, 3.5, yBot, stoneCol, Enum.Material.Cobblestone)
            stackOn("TowerRoof", 4.8, 1.2, 4.8, 3.5, 3.5, yBot + 12, roofCol)
            frontWindowOpening("WinFL", -2.5, yBot + lowerH + 2.5, 4.75, 1.8, 2, wallTh, lightStone, Enum.Material.Cobblestone, true)
            frontWindowOpening("WinFR",  2.5, yBot + lowerH + 2.5, 4.75, 1.8, 2, wallTh, lightStone, Enum.Material.Cobblestone, true)

        else -- tier 6
            local halfZ = 6
            local halfX = 6
            local wallTh = 0.65
            local yBot = 1.1
            local lowerH = 9
            local porchDepth = 3
            anchor.CFrame = worldCF * CFrame.new(0, 11, 0)
            onFloor("Plinth", 14, 1.1, 14, 0, 0, stoneCol, Enum.Material.Cobblestone)
            onFloor("PorchDeck", 8, 1.1, porchDepth, 0, -(halfZ + porchDepth * 0.5), lightStone, Enum.Material.Cobblestone)
            frontSteps(8, porchDepth, 1.1, halfZ + porchDepth, 0, lightStone, Enum.Material.Cobblestone)
            stackOn("Interior", 12 - wallTh * 2, lowerH - wallTh, 12 - wallTh * 2, 0, 0, yBot + wallTh * 0.5, interiorCol)
            frontWallWithDoor(halfZ, yBot, lowerH, 12, 3.5, 6.5, wallTh, stoneCol, Enum.Material.Cobblestone)
            frontDoor("Door", 3.5, 6.5, halfZ, yBot, trimCol, 0.25)
            sideWallWithWindow("WinE1", halfX, halfZ, yBot + 3.5, 2.8, 2.2, wallTh, lowerH, yBot, stoneCol, Enum.Material.Cobblestone, false)
            sideWallWithWindow("WinE2", halfX, halfZ, yBot + 7.5, 2.8, 2.2, wallTh, lowerH, yBot, stoneCol, Enum.Material.Cobblestone, true)
            sideWallWithWindow("WinW1", -halfX, halfZ, yBot + 3.5, 2.8, 2.2, wallTh, lowerH, yBot, stoneCol, Enum.Material.Cobblestone, false)
            sideWallWithWindow("WinW2", -halfX, halfZ, yBot + 7.5, 2.8, 2.2, wallTh, lowerH, yBot, stoneCol, Enum.Material.Cobblestone, true)
            box("WallBack", 12, lowerH, wallTh, 0, yBot + lowerH * 0.5, halfZ - wallTh * 0.5, stoneCol, Enum.Material.Cobblestone)
            stackOn("Upper", 10.5, 6, 10.5, 0, 0, yBot + lowerH, lightStone, Enum.Material.Cobblestone)
            stackOn("Cornice", 12.5, 0.7, 12.5, 0, 0, yBot + lowerH + 6, accentCol)
            stackOn("Roof", 14.5, 1.6, 14.5, 0, 0, yBot + lowerH + 6.7, roofCol)
            stackOn("BellTower", 4.5, 8, 4.5, 0, 0, yBot + lowerH + 7.5, stoneCol, Enum.Material.Cobblestone)
            stackOn("Belfry", 5.2, 1.5, 5.2, 0, 0, yBot + lowerH + 12, roofCol)
            stackOn("Spire", 1.2, 3, 1.2, 0, 0, yBot + lowerH + 14.35, accentCol)
            frontWindowOpening("WinFL", -2.8, yBot + lowerH + 3, 5.25, 1.8, 2.2, wallTh, lightStone, Enum.Material.Cobblestone, true)
            frontWindowOpening("WinFR",  2.8, yBot + lowerH + 3, 5.25, 1.8, 2.2, wallTh, lightStone, Enum.Material.Cobblestone, true)
            spawnKnightShieldMounts(halfZ, yBot, 1.75)
        end

        anchor:SetAttribute("TownHallTier", tier)
        label(anchor, "Town Hall Lvl " .. tier)
    end)

    if not buildOk then
        model:Destroy()
        warn("[WorldService] spawnTownHall tier", tier, "FAILED:", buildErr)
        return false
    end

    local existing = workspace:FindFirstChild("TownHallModel")
    if existing then existing:Destroy() end
    local legacyHall = workspace:FindFirstChild("TownHall")
    if legacyHall and legacyHall:IsA("BasePart") then legacyHall:Destroy() end
    local mayorPlate = workspace:FindFirstChild("MayorHouse_Foundation")
    if mayorPlate then mayorPlate:Destroy() end

    _shieldMounts = newShieldMounts
    _shieldVisuals = {}
    _townHallTier = tier
    model.Parent = workspace
    return true
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
            GameConfig.TOWN_HALL_OFFSET,  -- TownHall SE slot
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

local function replaceMountWithBanner(mount: BasePart)
    local banner = Instance.new("Part")
    banner.Name = "KnightBanner"
    banner.Size = Vector3.new(0.9, 1.4, 0.12)
    banner.BrickColor = BrickColor.new("Bright red")
    banner.Material = Enum.Material.Fabric
    banner.Anchored = true
    banner.CanCollide = false
    banner.CFrame = mount.CFrame
    banner.Parent = mount.Parent
end

function WorldService.getShieldMountsWithShields(): {BasePart}
    local list = {}
    for _, mount in _shieldMounts do
        if mount.Parent and mount:GetAttribute("HasShield") then
            table.insert(list, mount)
        end
    end
    return list
end

function WorldService.getEmptyShieldMount(slotId: number): BasePart?
    for _, mount in _shieldMounts do
        if mount.Parent
            and mount:GetAttribute("SlotId") == slotId
            and not mount:GetAttribute("HasShield")
            and not mount:GetAttribute("HasBanner") then
            return mount
        end
    end
    return nil
end

function WorldService.countOccupiedKnightSlots(): number
    local n = 0
    for _, mount in _shieldMounts do
        if mount.Parent and (mount:GetAttribute("HasShield") or mount:GetAttribute("HasBanner")) then
            n += 1
        end
    end
    return n
end

function WorldService.countKnightShields(): number
    local n = 0
    for _, mount in _shieldMounts do
        if mount.Parent and mount:GetAttribute("HasShield") then
            n += 1
        end
    end
    return n
end

function WorldService.addShieldToMount(mount: BasePart): boolean
    if mount:GetAttribute("MountType") ~= "KnightShield" then return false end
    if mount:GetAttribute("HasShield") or mount:GetAttribute("HasBanner") then return false end
    if WorldService.countOccupiedKnightSlots() >= GameConfig.KNIGHT_MAX_SHIELDS then return false end

    local shield = Instance.new("Part")
    shield.Name = "Shield"
    shield.Size = Vector3.new(1.35, 1.6, 0.22)
    shield.BrickColor = BrickColor.new("Bright blue")
    shield.Material = Enum.Material.Metal
    shield.Anchored = true
    shield.CanCollide = false
    shield.CFrame = mount.CFrame
    shield:SetAttribute("ToolType", "Shield")
    shield.Parent = mount

    mount:SetAttribute("HasShield", true)
    _shieldVisuals[mount] = shield
    return true
end

function WorldService.takeShieldFromMount(mount: BasePart): boolean
    if mount:GetAttribute("MountType") ~= "KnightShield" then return false end
    if not mount:GetAttribute("HasShield") then return false end

    local visual = _shieldVisuals[mount]
    if visual and visual.Parent then visual:Destroy() end
    _shieldVisuals[mount] = nil
    mount:SetAttribute("HasShield", false)
    mount:SetAttribute("HasBanner", true)
    replaceMountWithBanner(mount)
    return true
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
        inst:SetAttribute("Health",    GameConfig.BARRICADE_HEALTH * 2)
        inst:SetAttribute("MaxHealth", GameConfig.BARRICADE_HEALTH * 2)
        spawnTower(inst, 1)
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

    -- Spawn south of the firepit; pass-through so it doesn't block the dungeon-side approach
    if _spawn then
        _spawn.Position   = center + Vector3.new(0, 1, 8)
        _spawn.CanCollide = false
    end

    -- Firepit + town hall start at tier 0 so upgrade progression can be tested
    print("[DevTown] step 1: firepit + town hall slot")
    spawnFirepit(center, 0)
    spawnTownHall(0)  -- clears legacy mayor plate / static hall parts

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

    -- Cardinal defenses (town hall appears at SE slot when firepit upgrades)
    print("[DevTown] step 4: cardinal defenses")
    WorldService.unlockCardinalDefenses()
    WorldService.autoCompleteTownStructures()
    for _, child in workspace:GetChildren() do
        if not child:IsA("BasePart") then continue end
        local sType = child:GetAttribute("StructureType")
        if sType == "Tower"     then label(child :: BasePart, "Tower")     end
        if sType == "Barricade" then label(child :: BasePart, "Gate")      end
    end

    -- Circular perimeter walls
    print("[DevTown] step 5: perimeter walls")
    WorldService.spawnPerimeterWalls()

    -- 8 portals — all pulled 50 studs closer to center vs island edge (islandR=510 → edgeR=460)
    -- Portal numbering: 1=E  2=SE  3=S  4=SW  5=W  6=NW  7=N  8=in-front-of-1
    -- NE edge (old portal 8 spot) left open for crashed boat spawn
    print("[DevTown] step 6: portals")
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
    print("[DevTown] step 7: guardian + dungeon")
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

    -- Dev mayor for bank UI + dusk town-hall retreat testing
    if not workspace:FindFirstChild("Mayor") then
        local mayor = Instance.new("Model")
        mayor.Name  = "Mayor"
        local root  = Instance.new("Part")
        root.Name   = "HumanoidRootPart"
        root.Size   = Vector3.new(2, 3, 1)
        root.BrickColor = BrickColor.new("Bright blue")
        root.CanCollide = false
        root.Position   = center + Vector3.new(-10, 1.5, -6)
        root.Parent     = mayor
        local hum = Instance.new("Humanoid")
        hum.WalkSpeed = 6
        hum.Parent = mayor
        mayor.PrimaryPart = root
        mayor.Parent = workspace
        WorldService.startMayorAI(mayor)
    end
end

-- Rebuilds the firepit at the new tier. Called by Bootstrap on each upgrade.
function WorldService.upgradeFirepit(tier: number)
    spawnFirepit(GameConfig.TOWN_CENTER_POS, tier)
end

-- Rebuilds a single tower at the given tier. towerName matches the anchor BasePart
-- name in workspace (e.g. "Tower_E", "Tower_S", "Tower_W", "Tower_N").
function WorldService.upgradeTower(towerName: string, tier: number)
    local anchor = workspace:FindFirstChild(towerName)
    if anchor and anchor:IsA("BasePart") then
        spawnTower(anchor, tier)
    end
end

function WorldService.upgradeTownHall(tier: number): boolean
    return spawnTownHall(tier)
end

function WorldService.getTownHallTier(): number
    return _townHallTier
end

function WorldService.getTownHallEntryPos(): Vector3?
    if _townHallTier < 1 then return nil end
    local model = workspace:FindFirstChild("TownHallModel")
    local anchor = model and model:FindFirstChild("TownHall")
    if anchor and anchor:IsA("BasePart") then
        return anchor.Position + Vector3.new(0, -1.5, 0)
    end
    return GameConfig.TOWN_CENTER_POS + GameConfig.TOWN_HALL_OFFSET + Vector3.new(0, 2, 0)
end

function WorldService.getTownHallExclusion(): (Vector3?, number?)
    if _townHallTier < 1 then return nil, nil end
    local entry = WorldService.getTownHallEntryPos()
    if not entry then return nil, nil end
    local radius = _townHallTier == 1 and 5 or 7
    return entry, radius
end

function WorldService.startMayorAI(mayor: Model)
    if _mayorAiRunning then return end
    _mayorAiRunning = true
    task.spawn(function()
        while mayor.Parent do
            task.wait(math.random(8, 14))
            if not mayor.Parent then break end
            local humanoid = mayor:FindFirstChildOfClass("Humanoid")
            if not humanoid then continue end
            local town = GameConfig.TOWN_CENTER_POS
            local hallCenter, hallRadius = WorldService.getTownHallExclusion()
            for _ = 1, 10 do
                local angle = math.random() * 2 * math.pi
                local dist  = math.random() * (GameConfig.TOWN_RADIUS * 0.65)
                local target = town + Vector3.new(math.cos(angle) * dist, 0, math.sin(angle) * dist)
                if hallCenter and hallRadius then
                    local flat = Vector3.new(target.X - hallCenter.X, 0, target.Z - hallCenter.Z)
                    if flat.Magnitude < hallRadius + 2 then continue end
                end
                local firePos = GameConfig.TOWN_CENTER_POS + Vector3.new(0, 0, 4)
                if (target - firePos).Magnitude < 5 then continue end
                humanoid:MoveTo(target)
                break
            end
        end
        _mayorAiRunning = false
    end)
end

function WorldService.retreatMayorToTownHall()
    local mayor = workspace:FindFirstChild("Mayor")
    if not mayor or not mayor:IsA("Model") then return end
    local root = mayor.PrimaryPart
    local entry = WorldService.getTownHallEntryPos()
    if root and entry and _townHallTier >= 1 then
        root.CFrame = CFrame.new(entry)
        print("[WorldService] Mayor inside town hall (tier", _townHallTier, ")")
    end
end

function WorldService.releaseMayorFromTownHall()
    local mayor = workspace:FindFirstChild("Mayor")
    if not mayor or not mayor:IsA("Model") then return end
    local root = mayor.PrimaryPart
    local entry = WorldService.getTownHallEntryPos()
    if not root or not entry or _townHallTier < 1 then return end
    local outward = (GameConfig.TOWN_CENTER_POS - entry)
    outward = Vector3.new(outward.X, 0, outward.Z)
    if outward.Magnitude < 1 then outward = Vector3.new(-1, 0, -1) end
    root.CFrame = CFrame.new(entry + outward.Unit * 10 + Vector3.new(0, 2, 0))
end

return WorldService
