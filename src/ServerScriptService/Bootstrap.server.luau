local Shared      = game:GetService("ReplicatedStorage").Shared
local Services    = game:GetService("ServerScriptService").Services
local GameConfig  = require(Shared.GameConfig)
local _Types      = require(Shared.Types)
local _Remotes    = require(Shared.Remotes)

assert(GameConfig.PLAYER_PURSE_MAX == 25, "PLAYER_PURSE_MAX mismatch")
assert(GameConfig.TREE_MARK_COST   ==  1, "TREE_MARK_COST mismatch")
print("[Bootstrap] Shared modules OK")

local TimeService = require(Services.TimeService)

local CoinService = require(Services.CoinService)

local WorldService = require(Services.WorldService)
WorldService.buildIsland()

local MayorService = require(Services.MayorService)

local Remotes    = require(game:GetService("ReplicatedStorage").Shared.Remotes)
local NpcService = require(Services.NpcService)

Remotes.DropCoins.OnServerEvent:Connect(function(player: Player, amount: number)
    if amount and amount > 0 then
        local char = player.Character
        local pos  = char and char.PrimaryPart and char.PrimaryPart.Position
        if pos then
            -- Try mayor deposit first (if near mayor)
            local MayorSvc = require(Services.MayorService)
            if MayorSvc.isBankOpen() and (pos - MayorSvc.getPosition()).Magnitude < GameConfig.MAYOR_DEPOSIT_RADIUS then
                MayorSvc.deposit(player.UserId, amount)
            else
                if CoinService.spend(player.UserId, amount) then
                    CoinService.spawnGroundCoins(pos, amount, player.UserId)
                end
            end
        end
    end
end)

local GreedService = require(Services.GreedService)

Remotes.DropFood.OnServerEvent:Connect(function(player: Player)
    local char = player.Character
    local pos  = char and char.PrimaryPart and char.PrimaryPart.Position
    if pos then WorldService.spawnFood(pos) end
end)

-- ── Remote handlers ────────────────────────────────────────────────────────

local function scatterCoinsOnFail(player: Player, attempted: number)
    local char  = player.Character
    local pos   = char and char.PrimaryPart and char.PrimaryPart.Position
    local purse = CoinService.getPurse(player.UserId)
    if pos and purse > 0 then
        local drop = math.min(purse, attempted)
        CoinService.spend(player.UserId, drop)
        CoinService.spawnGroundCoins(pos, drop, player.UserId)
    end
end

Remotes.BuyTool.OnServerInvoke = function(player: Player): boolean
    local hammerShop = workspace:FindFirstChild("HammerShop")
    if not hammerShop then return false end
    if not CoinService.spend(player.UserId, GameConfig.HAMMER_COST) then
        scatterCoinsOnFail(player, GameConfig.HAMMER_COST)
        return false
    end
    local shopPart = hammerShop :: BasePart
    local toolPart = Instance.new("Part")
    toolPart.Name        = "Hammer"
    toolPart.Size        = Vector3.new(1, 1, 3)
    toolPart.BrickColor  = BrickColor.new("Medium stone grey")
    toolPart.Anchored    = true
    toolPart.CanCollide  = false
    toolPart.Position    = Vector3.new(shopPart.Position.X, 0.5, shopPart.Position.Z + 3)
    toolPart.Parent      = workspace
    toolPart:SetAttribute("ToolType", "Hammer")
    WorldService.registerGroundTool(toolPart, toolPart.Position)
    print("[Bootstrap] Hammer purchased by", player.Name)
    return true
end

Remotes.MarkTree.OnServerInvoke = function(player: Player, treeId: string): boolean
    if WorldService.getPlayerMarkCount(player.UserId) >= GameConfig.TREE_MAX_PLAYER_MARKS then return false end
    if not CoinService.spend(player.UserId, GameConfig.TREE_MARK_COST) then
        scatterCoinsOnFail(player, GameConfig.TREE_MARK_COST)
        return false
    end
    local ok = WorldService.markTree(treeId, player.UserId, GameConfig.TREE_MARK_COST)
    if not ok then CoinService.award(player.UserId, GameConfig.TREE_MARK_COST) end
    return ok
end

Remotes.BankWithdraw.OnServerInvoke = function(player: Player, amount: number): boolean
    return MayorService.withdraw(player.UserId, amount)
end
