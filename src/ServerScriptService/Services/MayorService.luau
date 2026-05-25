local GameConfig    = require(game:GetService("ReplicatedStorage").Shared.GameConfig)
local CoinService   = require(script.Parent.CoinService)
local WorldService  = require(script.Parent.WorldService)
local TimeService   = require(script.Parent.TimeService)
local Players       = game:GetService("Players")

local _bankBalance = 0
local _bankOpen    = false
local _mayorModel: Model
local _tentBuilt   = false
local _fireLit     = false

local function spawnMayor(pos: Vector3): Model
    local model = Instance.new("Model")
    model.Name  = "Mayor"

    local root      = Instance.new("Part")
    root.Name       = "HumanoidRootPart"
    root.Size       = Vector3.new(2, 3, 1)
    root.BrickColor = BrickColor.new("Bright blue")
    root.CanCollide = false   -- players walk through the mayor
    root.Position   = pos + Vector3.new(0, 1.5, 0)
    root.Parent     = model

    local humanoid         = Instance.new("Humanoid")
    humanoid.WalkSpeed     = 6
    humanoid.MaxHealth     = math.huge
    humanoid.Health        = math.huge
    humanoid.Parent        = model

    model.PrimaryPart = root
    model.Parent      = workspace
    return model
end

local function buildTent(pos: Vector3)
    if _tentBuilt then return end
    _tentBuilt = true
    local tent      = Instance.new("Part")
    tent.Name       = "TownCenterTent"
    tent.Size       = Vector3.new(10, 8, 10)
    tent.BrickColor = BrickColor.new("Medium stone grey")
    tent.Anchored   = true
    tent.Position   = pos + Vector3.new(0, 4, -8)
    tent.Parent     = workspace
    print("[MayorService] Town Center tent built")
end

local function spawnFirePit()
    -- Fixed at town center; does not depend on mayor position
    local firePos = GameConfig.TOWN_CENTER_POS + Vector3.new(0, 0.25, 4)
    local fire      = Instance.new("Part")
    fire.Name       = "FirePit"
    fire.Size       = Vector3.new(2, 0.5, 2)
    fire.BrickColor = BrickColor.new("Dark orange")
    fire.Anchored   = true
    fire.CanCollide = false
    fire.Position   = firePos
    fire.Parent     = workspace
    local flame     = Instance.new("Fire")
    flame.Parent    = fire
end

local function doFireLightSequence()
    if _fireLit then return end
    _fireLit = true

    spawnFirePit()
    WorldService.fireFireLit()
    print("[MayorService] Fire lit! Town Level 1 unlocked.")

    task.wait(1)
    for _, player in Players:GetPlayers() do
        CoinService.award(player.UserId, GameConfig.STARTER_COINS)
        print("[MayorService] Gave", GameConfig.STARTER_COINS, "starter coins to", player.Name)
    end
end

-- ── Init ──────────────────────────────────────────────────────────────────

local function init()
    _mayorModel = spawnMayor(GameConfig.TOWN_CENTER_POS)

    task.delay(3, doFireLightSequence)

    -- Gentle wander around town center
    task.spawn(function()
        while true do
            task.wait(math.random(6, 14))
            if not _mayorModel or not _mayorModel.Parent then break end
            local humanoid = _mayorModel:FindFirstChildOfClass("Humanoid")
            if not humanoid then continue end
            local angle  = math.random() * 2 * math.pi
            local dist   = math.random() * 8
            humanoid:MoveTo(GameConfig.TOWN_CENTER_POS
                + Vector3.new(math.cos(angle) * dist, 0, math.sin(angle) * dist))
        end
    end)

    -- Dawn: pay interest, open bank
    TimeService.onDawn(function(_day)
        _bankOpen = true
        if _bankBalance > 0 then
            local interest = math.min(math.floor(_bankBalance * GameConfig.BANK_INTEREST_RATE), GameConfig.BANK_INTEREST_CAP)
            _bankBalance  += interest
            if interest > 0 then
                print("[MayorService] Bank interest paid:", interest, "| Balance:", _bankBalance)
            end
        end
    end)

    -- Dusk: close bank, Mayor retreats to tent
    TimeService.onDusk(function()
        _bankOpen = false
        if _mayorModel then
            local tent = workspace:FindFirstChild("TownCenterTent")
            if tent then
                local humanoid = _mayorModel:FindFirstChildOfClass("Humanoid")
                if humanoid then humanoid:MoveTo(tent.Position + Vector3.new(0, -4, 0)) end
            end
        end
    end)
end

-- ── Public API ────────────────────────────────────────────────────────────

local MayorService = {}

function MayorService.getPosition(): Vector3
    local root = _mayorModel and _mayorModel.PrimaryPart
    return root and root.Position or GameConfig.TOWN_CENTER_POS
end

function MayorService.isBankOpen(): boolean
    return _bankOpen
end

function MayorService.deposit(playerId: number, amount: number)
    if not _bankOpen then return end
    if not CoinService.spend(playerId, amount) then return end
    _bankBalance += amount
    if not _tentBuilt then buildTent(GameConfig.TOWN_CENTER_POS) end
    print("[MayorService] Deposit", amount, "| Balance:", _bankBalance)
end

function MayorService.withdraw(playerId: number, amount: number): boolean
    if not _bankOpen then return false end
    if _bankBalance < amount then return false end
    _bankBalance -= amount
    CoinService.award(playerId, amount)
    print("[MayorService] Withdrawal", amount, "| Balance:", _bankBalance)
    return true
end

function MayorService.getBalance(): number
    return _bankBalance
end

function MayorService.steal(amount: number): number
    local actual   = math.min(amount, _bankBalance)
    _bankBalance  -= actual
    return actual
end

init()
return MayorService
