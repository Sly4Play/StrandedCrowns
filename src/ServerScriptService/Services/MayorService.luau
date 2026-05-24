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
    root.Position   = pos + Vector3.new(0, 1.5, 0)
    root.Parent     = model

    local humanoid         = Instance.new("Humanoid")
    humanoid.WalkSpeed     = 12
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

local function doFireLightSequence()
    if _fireLit then return end
    _fireLit = true
    local mayorRoot = _mayorModel and _mayorModel.PrimaryPart
    if not mayorRoot then return end

    -- Walk to fire pit position (slightly south of town center)
    local firePos = GameConfig.TOWN_CENTER_POS + Vector3.new(0, 0, 5)
    local humanoid = _mayorModel:FindFirstChildOfClass("Humanoid")
    if humanoid then
        humanoid:MoveTo(firePos)
        task.wait(3)
    end

    -- Spawn fire model
    local fire      = Instance.new("Part")
    fire.Name       = "FirePit"
    fire.Size       = Vector3.new(2, 0.5, 2)
    fire.BrickColor = BrickColor.new("Dark orange")
    fire.Anchored   = true
    fire.Position   = firePos + Vector3.new(0, 0.25, 0)
    fire.Parent     = workspace
    local flame     = Instance.new("Fire")
    flame.Parent    = fire

    -- Town Level 1 unlock
    WorldService.fireFireLit()
    print("[MayorService] Fire lit! Town Level 1 unlocked.")

    -- Give Island 1 starter coins to all players
    task.wait(1)
    for _, player in Players:GetPlayers() do
        CoinService.award(player.UserId, GameConfig.STARTER_COINS)
        print("[MayorService] Gave", GameConfig.STARTER_COINS, "starter coins to", player.Name)
    end
end

-- ── Init ──────────────────────────────────────────────────────────────────

local function init()
    _mayorModel = spawnMayor(GameConfig.TOWN_CENTER_POS)

    -- Give the Mayor time to exist, then light fire
    task.delay(3, doFireLightSequence)

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

    -- Dusk: close bank, Mayor goes inside
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
