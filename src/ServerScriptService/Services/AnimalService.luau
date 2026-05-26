local GameConfig   = require(game:GetService("ReplicatedStorage").Shared.GameConfig)
local CoinService  = require(script.Parent.CoinService)
local WorldService = require(script.Parent.WorldService)

type AnimalData = { id: string, instance: Model, position: Vector3 }
local _animals: {[string]: AnimalData} = {}
local _counter = 0
local _rng     = Random.new()

local function nextId(): string
    _counter += 1
    return "animal_" .. _counter
end

local function countAlive(): number
    local n = 0
    for _, a in _animals do if a.instance.Parent then n += 1 end end
    return n
end

local function randomSpawnPos(): Vector3
    local center   = GameConfig.TOWN_CENTER_POS
    local islandR  = GameConfig.ISLAND_RADIUS_BY_ISLAND[1]
    local minDist  = GameConfig.TOWN_RADIUS + 20
    local maxDist  = islandR - 25

    for _ = 1, 25 do
        local angle = _rng:NextNumber() * 2 * math.pi
        local dist  = minDist + _rng:NextNumber() * math.max(0, maxDist - minDist)
        local pos   = center + Vector3.new(math.cos(angle) * dist, 0, math.sin(angle) * dist)
        local ok    = true
        for _, portal in WorldService.getPortals() do
            if (pos - portal.Position).Magnitude < GameConfig.ANIMAL_SPAWN_MIN_DIST_PORTAL then
                ok = false; break
            end
        end
        if ok then return pos end
    end
    -- fallback: due-north safe point
    return center + Vector3.new(0, 0, -(GameConfig.TOWN_RADIUS + 40))
end

local function spawnAnimal()
    local pos = randomSpawnPos()
    local id  = nextId()

    local model = Instance.new("Model")
    model.Name  = "Animal_" .. id
    model:SetAttribute("AnimalId", id)

    local body = Instance.new("Part")
    body.Name           = "HumanoidRootPart"
    body.Size           = Vector3.new(2, 1.5, 3)
    body.BrickColor     = BrickColor.new("Brown")
    body.Material       = Enum.Material.SmoothPlastic
    body.CanCollide     = false
    body.CollisionGroup = "Friendly"
    body.Position       = pos + Vector3.new(0, 0.75, 0)
    body.Parent         = model

    local humanoid     = Instance.new("Humanoid")
    humanoid.WalkSpeed = GameConfig.ANIMAL_WANDER_SPEED
    humanoid.MaxHealth = 1
    humanoid.Health    = 1
    humanoid.Parent    = model

    model.PrimaryPart = body
    model.Parent      = workspace

    _animals[id] = { id = id, instance = model, position = pos }

    task.spawn(function()
        while model.Parent and _animals[id] do
            task.wait(_rng:NextNumber() * 6 + 4)
            if not model.Parent then break end
            local h = model:FindFirstChildOfClass("Humanoid")
            local r = model.PrimaryPart
            if not h or not r then break end
            local cur = r.Position
            if _animals[id] then _animals[id].position = cur end
            local angle = _rng:NextNumber() * 2 * math.pi
            h:MoveTo(cur + Vector3.new(math.cos(angle) * 18, 0, math.sin(angle) * 18))
        end
    end)
end

-- Seed population after island finishes generating
task.delay(5, function()
    for _ = 1, GameConfig.ANIMAL_COUNT do
        spawnAnimal()
    end
end)

-- ── Public API ────────────────────────────────────────────────────────────

local AnimalService = {}

function AnimalService.getAnimals(): {{id: string, instance: Model, position: Vector3}}
    local list = {}
    for _, a in _animals do
        if a.instance.Parent then
            local r = a.instance.PrimaryPart
            if r then a.position = r.Position end
            table.insert(list, a)
        end
    end
    return list
end

-- Returns death position, or nil if animal was already dead (double-kill guard).
function AnimalService.killAnimal(id: string): Vector3?
    local a = _animals[id]
    if not a then return nil end
    if not a.instance.Parent then _animals[id] = nil; return nil end
    local root     = a.instance.PrimaryPart
    local deathPos = root and root.Position or a.position
    a.instance:Destroy()
    _animals[id] = nil
    CoinService.spawnGroundCoins(deathPos, GameConfig.ANIMAL_COIN_REWARD, 0, true)
    task.delay(GameConfig.ANIMAL_RESPAWN_DELAY, function()
        if countAlive() < GameConfig.ANIMAL_COUNT then spawnAnimal() end
    end)
    print("[AnimalService] Kill →", deathPos, "| alive:", countAlive())
    return deathPos
end

return AnimalService
