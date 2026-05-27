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
    if GameConfig.DEV_MODE then return true end
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

-- scatter: radius of random XZ jitter on spawn
local function makeCoinPart(pos: Vector3, amount: number, scatter: number?): BasePart
    local s          = scatter or 2.0
    local p          = Instance.new("Part")
    p.Name           = "GroundCoin"
    p.Size           = Vector3.new(1.5, 1.5, 1.5)
    p.Shape          = Enum.PartType.Ball
    p.BrickColor     = BrickColor.new("Bright yellow")
    p.Anchored       = true
    p.CanCollide     = false
    p.Position       = Vector3.new(
        pos.X + (math.random() * 2 - 1) * s,
        0.3,
        pos.Z + (math.random() * 2 - 1) * s
    )
    p.Parent         = workspace
    p:SetAttribute("Amount", amount)
    return p
end

local function registerCoin(part: BasePart, amount: number, ownerId: number)
    local now   = tick()
    local entry: GroundCoin = {
        instance  = part,
        amount    = amount,
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

-- exact=true: spawn one part per coin (tight scatter so NPCs can collect them);
-- exact=false (default): halve total into a single pile (hit-drop behaviour)
function CoinService.spawnGroundCoins(pos: Vector3, total: number, ownerId: number, exact: boolean?)
    if total <= 0 then return end
    if exact == true then
        -- Spawn individual coins, scatter 0.7 studs so they stay within COIN_PICKUP_RADIUS
        for _ = 1, math.min(total, 10) do
            registerCoin(makeCoinPart(pos, 1, 0.7), 1, ownerId)
        end
        if total > 10 then
            registerCoin(makeCoinPart(pos, total - 10, 1.5), total - 10, ownerId)
        end
        return
    end
    local persist = math.ceil(total / 2)
    registerCoin(makeCoinPart(pos, persist), persist, ownerId)
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
                    local received = CoinService.award(player.UserId, coin.amount)
                    local overflow = coin.amount - received
                    if overflow > 0 then
                        -- Bag full: scatter overflow so coins aren't lost
                        CoinService.spawnGroundCoins(pos, overflow, player.UserId, true)
                    end
                end
            end
        end
    end
end)

local function onPlayerAdded(p: Player)
    CoinService.init(p.UserId, GameConfig.PLAYER_PURSE_MAX)
    if GameConfig.DEV_MODE then
        CoinService.award(p.UserId, GameConfig.PLAYER_PURSE_MAX)
    else
        Remotes.CoinChanged:FireClient(p, 0)
    end
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(function(p)
    purses[p.UserId] = nil
end)

-- Play Solo: local player exists before this module loads; PlayerAdded won't replay.
for _, p in Players:GetPlayers() do
    onPlayerAdded(p)
end

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
