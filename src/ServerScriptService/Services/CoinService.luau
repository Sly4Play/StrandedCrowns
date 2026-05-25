local GameConfig = require(game:GetService("ReplicatedStorage").Shared.GameConfig)
local Remotes    = require(game:GetService("ReplicatedStorage").Shared.Remotes)
local Players    = game:GetService("Players")

-- purses[entityId] = { amount: number, max: number }
local purses: {[number]: {amount: number, max: number}} = {}

type GroundCoin = {
    instance: BasePart, amount: number,
    ownerId: number, droppedAt: number,
    claimed: boolean,
}
local groundCoins: {GroundCoin} = {}

local function notifyPlayer(player: Player)
    local id = player.UserId
    if purses[id] then
        Remotes.CoinChanged:FireClient(player, purses[id].amount)
    end
end

local CoinService = {}

function CoinService.init(id: number, max: number)
    purses[id] = { amount = 0, max = max }
end

function CoinService.award(id: number, amt: number): number
    local entry = purses[id]
    if not entry then return 0 end
    local space  = entry.max - entry.amount
    local actual = math.min(amt, space)
    entry.amount += actual
    local player = Players:GetPlayerByUserId(id)
    if player then notifyPlayer(player) end
    return actual
end

function CoinService.spend(id: number, amt: number): boolean
    local entry = purses[id]
    if not entry or entry.amount < amt then return false end
    entry.amount -= amt
    local player = Players:GetPlayerByUserId(id)
    if player then notifyPlayer(player) end
    return true
end

function CoinService.getPurse(id: number): number
    local entry = purses[id]
    return entry and entry.amount or 0
end

local function makeCoinPart(pos: Vector3, amount: number): BasePart
    local p          = Instance.new("Part")
    p.Name           = "GroundCoin"
    p.Size           = Vector3.new(0.5, 0.5, 0.5)
    p.Shape          = Enum.PartType.Ball
    p.BrickColor     = BrickColor.new("Bright yellow")
    p.Anchored       = true
    p.CanCollide     = false
    p.Position       = pos + Vector3.new(math.random(-2, 2), 0.5, math.random(-2, 2))
    p.Parent         = workspace
    p:SetAttribute("Amount", amount)
    return p
end

function CoinService.spawnGroundCoins(pos: Vector3, total: number, ownerId: number)
    if total <= 0 then return end
    local persist = math.ceil(total / 2)
    local now     = tick()

    local part = makeCoinPart(pos, persist)
    local entry: GroundCoin = {
        instance  = part,
        amount    = persist,
        ownerId   = ownerId,
        droppedAt = now,
        claimed   = false,
    }
    table.insert(groundCoins, entry)

    part.Touched:Connect(function(hit)
        if entry.claimed then return end
        local character = hit.Parent
        local player    = Players:GetPlayerFromCharacter(character)
        if not player then return end
        if not part.Parent then return end
        if player.UserId == ownerId then
            if tick() - entry.droppedAt < GameConfig.OWN_COIN_PICKUP_DELAY then return end
        end
        entry.claimed = true
        CoinService.award(player.UserId, entry.amount)
        for i = #groundCoins, 1, -1 do
            if groundCoins[i].instance == part then table.remove(groundCoins, i) break end
        end
        part:Destroy()
    end)

    task.delay(GameConfig.GROUND_COIN_DESPAWN, function()
        if part.Parent and not entry.claimed then
            entry.claimed = true
            for i = #groundCoins, 1, -1 do
                if groundCoins[i].instance == part then table.remove(groundCoins, i) break end
            end
            part:Destroy()
        end
    end)
end

-- Returns the coin amount and removes it from the world; 0 if already claimed.
function CoinService.claimGroundCoin(part: BasePart): number
    for i = #groundCoins, 1, -1 do
        local coin = groundCoins[i]
        if coin.instance ~= part then continue end
        if coin.claimed then return 0 end
        coin.claimed = true
        table.remove(groundCoins, i)
        if part.Parent then part:Destroy() end
        return coin.amount
    end
    return 0
end

function CoinService.dropFromHit(id: number, pos: Vector3)
    local entry = purses[id]
    if not entry then return end
    local drop = math.floor(entry.amount / 3)
    if drop <= 0 then return end
    entry.amount -= drop
    local player = Players:GetPlayerByUserId(id)
    if player then notifyPlayer(player) end
    CoinService.spawnGroundCoins(pos, drop, id)
end

function CoinService.getGroundCoins(): {GroundCoin}
    local copy = {}
    for _, c in groundCoins do table.insert(copy, c) end
    return copy
end

function CoinService.removeGroundCoin(part: BasePart)
    for i = #groundCoins, 1, -1 do
        if groundCoins[i].instance == part then
            table.remove(groundCoins, i)
            if part.Parent then part:Destroy() end
            return
        end
    end
end

-- Proximity pickup for players: award ground coins within COIN_PICKUP_RADIUS
task.spawn(function()
    while true do
        task.wait(0.5)
        local now = tick()
        for _, player in Players:GetPlayers() do
            local char = player.Character
            if not char or not char.PrimaryPart then continue end
            local pos = char.PrimaryPart.Position
            for i = #groundCoins, 1, -1 do
                local coin = groundCoins[i]
                if coin.claimed then continue end
                if not coin.instance.Parent then continue end
                if coin.ownerId == player.UserId
                    and now - coin.droppedAt < GameConfig.OWN_COIN_PICKUP_DELAY then continue end
                if (coin.instance.Position - pos).Magnitude <= GameConfig.COIN_PICKUP_RADIUS then
                    coin.claimed = true
                    table.remove(groundCoins, i)
                    coin.instance:Destroy()
                    CoinService.award(player.UserId, coin.amount)
                end
            end
        end
    end
end)

Players.PlayerAdded:Connect(function(p)
    CoinService.init(p.UserId, GameConfig.PLAYER_PURSE_MAX)
    Remotes.CoinChanged:FireClient(p, 0)
end)
Players.PlayerRemoving:Connect(function(p)
    purses[p.UserId] = nil
end)

CoinService._runTests = function()
    CoinService.init(999, 25)
    assert(CoinService.getPurse(999) == 0,  "New entity should have 0 coins")
    local got = CoinService.award(999, 10)
    assert(got == 10,                       "award(10) should return 10")
    assert(CoinService.getPurse(999) == 10, "Purse should be 10 after award")
    assert(CoinService.spend(999, 4),       "spend(4) should succeed")
    assert(CoinService.getPurse(999) == 6,  "Purse should be 6 after spend")
    assert(not CoinService.spend(999, 99),  "spend(99) should fail")
    assert(CoinService.getPurse(999) == 6,  "Purse unchanged after failed spend")
    CoinService.award(999, 100)
    assert(CoinService.getPurse(999) == 25, "Purse capped at max 25")
    print("[CoinService] Tests PASS")
end

return CoinService
