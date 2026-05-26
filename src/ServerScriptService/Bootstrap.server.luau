-- ── Collision groups (must be registered before any parts exist) ────────────
local PhysicsService = game:GetService("PhysicsService")
local _colGroups = {"Friendly", "Greed", "Defense", "Portal"}
for _, g in _colGroups do
    pcall(function() PhysicsService:RegisterCollisionGroup(g) end)
end
PhysicsService:CollisionGroupSetCollidable("Friendly", "Defense",   false)  -- players/workers walk through own walls
PhysicsService:CollisionGroupSetCollidable("Greed",    "Portal",   false)  -- Greed can re-enter their own portal
PhysicsService:CollisionGroupSetCollidable("Friendly", "Friendly", false)  -- players/NPCs don't block each other

-- Assign player characters to the Friendly collision group
local _Players = game:GetService("Players")
local function assignFriendly(character: Model)
    local function setGroup(inst: Instance)
        if inst:IsA("BasePart") then (inst :: BasePart).CollisionGroup = "Friendly" end
    end
    for _, d in character:GetDescendants() do setGroup(d) end
    character.DescendantAdded:Connect(setGroup)
end
_Players.PlayerAdded:Connect(function(player)
    player.CharacterAdded:Connect(assignFriendly)
    if player.Character then assignFriendly(player.Character) end
end)
for _, player in _Players:GetPlayers() do
    if player.Character then assignFriendly(player.Character) end
end

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
WorldService.buildIsland(1)

require(Services.AnimalService)  -- seeds island animal population; NpcService lazy-loads it for hunting

local MayorService = require(Services.MayorService)

-- When builders finish the mayor house, sync MayorService internal state
WorldService.onMayorHouseBuilt(function()
    MayorService.buildTent(GameConfig.TOWN_CENTER_POS)
end)

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
    local shopPart = workspace:FindFirstChild("HammerShop")
    if not shopPart or not shopPart:IsA("BasePart") then return false end
    if (shopPart:GetAttribute("RackCount") or 0) >= GameConfig.RACK_MAX_TOOLS then return false end
    if not CoinService.spend(player.UserId, GameConfig.HAMMER_COST) then
        scatterCoinsOnFail(player, GameConfig.HAMMER_COST)
        return false
    end
    if not WorldService.addToolToRack(shopPart :: BasePart) then
        CoinService.award(player.UserId, GameConfig.HAMMER_COST)
        return false
    end
    print("[Bootstrap] Hammer added to rack by", player.Name)
    return true
end

Remotes.BuyBow.OnServerInvoke = function(player: Player): boolean
    local shopPart = workspace:FindFirstChild("BowShop")
    if not shopPart or not shopPart:IsA("BasePart") then return false end
    if (shopPart:GetAttribute("RackCount") or 0) >= GameConfig.RACK_MAX_TOOLS then return false end
    if not CoinService.spend(player.UserId, GameConfig.BOW_COST) then
        scatterCoinsOnFail(player, GameConfig.BOW_COST)
        return false
    end
    if not WorldService.addToolToRack(shopPart :: BasePart) then
        CoinService.award(player.UserId, GameConfig.BOW_COST)
        return false
    end
    print("[Bootstrap] Bow added to rack by", player.Name)
    return true
end

Remotes.MarkTree.OnServerInvoke = function(player: Player, treeId: string): boolean
    if WorldService.getPlayerMarkCount(player.UserId) >= GameConfig.TREE_MAX_PLAYER_MARKS then
        -- No coin was spent; fire CoinChanged to correct the client's optimistic HUD decrement
        Remotes.CoinChanged:FireClient(player, CoinService.getPurse(player.UserId))
        return false
    end
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

local _firepitLevel    = 0
local _island2Unlocked = false  -- set true when Island 2 is unlocked (Phase 2)

Remotes.UpgradeFirepit.OnServerInvoke = function(player: Player): boolean
    local costs     = GameConfig.FIREPIT_UPGRADE_COSTS
    local nextLevel = _firepitLevel + 1
    if nextLevel > #costs then return false end
    -- Levels 3 and 4 (costs[3]=12, costs[4]=14) locked until Island 2
    if nextLevel >= 3 and not _island2Unlocked then return false end
    local cost = costs[nextLevel]
    if not CoinService.spend(player.UserId, cost) then
        scatterCoinsOnFail(player, cost)
        return false
    end
    _firepitLevel = nextLevel
    local firePit = workspace:FindFirstChild("FirePit") :: BasePart?
    if firePit then
        local fire = firePit:FindFirstChildOfClass("Fire")
        if fire then fire.Size = 6 + _firepitLevel * 2 end
    end
    if _firepitLevel == 1 then
        WorldService.unlockCardinalDefenses()   -- 8g "pays for" all 8 cardinal defenses; builders complete them
    end
    if _firepitLevel == 2 then
        WorldService.spawnMayorHouseFoundation()  -- builders will complete it; walls seal when done
    end
    local nextCost = costs[_firepitLevel + 1]
    Remotes.FirepitLevelChanged:FireAllClients(_firepitLevel, nextCost)
    print("[Bootstrap] Firepit upgraded to level", _firepitLevel, "by", player.Name)
    return true
end

Remotes.MarkBoat.OnServerInvoke = function(player: Player): boolean
    if not CoinService.spend(player.UserId, GameConfig.BOAT_REPAIR_COST) then
        scatterCoinsOnFail(player, GameConfig.BOAT_REPAIR_COST)
        return false
    end
    local ok = WorldService.markBoatForRepair()
    if not ok then CoinService.award(player.UserId, GameConfig.BOAT_REPAIR_COST) end
    return ok
end

-- Player pays coin cost to unlock a structure; builder then physically completes it.
-- 1 coin = 1 payment tick.  When fully paid, BuildUnlocked=true and BuildProgress resets
-- for the builder's build phase (STRUCTURE_BUILD_DURATION ticks).
Remotes.BuildStructure.OnServerInvoke = function(player: Player): boolean
    local char = player.Character
    local pos  = char and char.PrimaryPart and char.PrimaryPart.Position
    if not pos then return false end
    local nearest: BasePart? = nil
    local nearestDist = GameConfig.STRUCTURE_INTERACT_RADIUS
    for _, child in workspace:GetChildren() do
        if not child:IsA("BasePart") then continue end
        if child:GetAttribute("Level") ~= 0 then continue end
        if child:GetAttribute("BuildUnlocked") == true then continue end  -- already paid; waiting on builder
        if not child:GetAttribute("StructureType") then continue end
        local d = ((child :: BasePart).Position - pos).Magnitude
        if d < nearestDist then nearestDist = d; nearest = child :: BasePart end
    end
    if not nearest then return false end
    if not CoinService.spend(player.UserId, 1) then
        scatterCoinsOnFail(player, 1)
        return false
    end
    local progress = (nearest:GetAttribute("BuildProgress") or 0) + 1
    local required = nearest:GetAttribute("BuildRequired") or GameConfig.STRUCTURE_BUILD_DURATION
    nearest:SetAttribute("BuildProgress", progress)
    if progress >= required then
        -- Payment complete — hand off to builders
        nearest:SetAttribute("BuildUnlocked", true)
        nearest:SetAttribute("BuildProgress", 0)
        nearest:SetAttribute("BuildRequired", GameConfig.STRUCTURE_BUILD_DURATION)
        print("[Bootstrap] Structure unlocked for builders:", nearest.Name, "by", player.Name)
    end
    return true
end

-- Returns remaining portal HP, or -1 if no portal in range
Remotes.AttackPortal.OnServerInvoke = function(player: Player): number
    local char = player.Character
    local pos  = char and char.PrimaryPart and char.PrimaryPart.Position
    if not pos then return -1 end
    local portals = WorldService.getPortals()
    local nearest: BasePart? = nil
    local nearestDist = GameConfig.PORTAL_INTERACT_RADIUS
    for _, portal in portals do
        local d = (portal.Position - pos).Magnitude
        if d < nearestDist then nearestDist = d; nearest = portal end
    end
    if not nearest then return -1 end
    local hp = math.max(0, (nearest:GetAttribute("Health") or 0) - 1)
    nearest:SetAttribute("Health", hp)
    if hp <= 0 then
        nearest:Destroy()
        print("[Bootstrap] Portal destroyed by", player.Name)
        return 0
    end
    return hp
end
