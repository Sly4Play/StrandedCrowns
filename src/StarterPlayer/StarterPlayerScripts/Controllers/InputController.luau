local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService  = game:GetService("UserInputService")
local TweenService      = game:GetService("TweenService")
local GameConfig        = require(ReplicatedStorage.Shared.GameConfig)
local Remotes           = require(ReplicatedStorage.Shared.Remotes)

local player     = Players.LocalPlayer
local BUY_RADIUS = 5

-- ── Interactive registry ──────────────────────────────────────────────────

type Interactive = { part: BasePart, cost: number, action: () -> boolean, condition: (() -> boolean)?, maxDist: number? }
local _interactives: {Interactive} = {}

local function register(part: BasePart, cost: number, action: () -> boolean, condition: (() -> boolean)?, maxDist: number?)
    table.insert(_interactives, { part = part, cost = cost, action = action, condition = condition, maxDist = maxDist })
end

-- ── Coin bubble ───────────────────────────────────────────────────────────

local function attachCoinBubble(part: BasePart, cost: number, maxDist: number?)
    local existing = part:FindFirstChild("CoinBubble")
    if existing then existing:Destroy() end

    local billboard             = Instance.new("BillboardGui")
    billboard.Name              = "CoinBubble"
    billboard.Size              = UDim2.new(0, 44, 0, 24)
    billboard.StudsOffset       = Vector3.new(0, 6, 0)
    billboard.MaxDistance       = maxDist or 12
    billboard.AlwaysOnTop       = true
    billboard.Parent            = part

    local bg                    = Instance.new("Frame")
    bg.Size                     = UDim2.new(1, 0, 1, 0)
    bg.BackgroundColor3         = Color3.fromRGB(255, 210, 0)
    bg.BorderSizePixel          = 0
    bg.Parent                   = billboard

    local corner                = Instance.new("UICorner")
    corner.CornerRadius         = UDim.new(1, 0)
    corner.Parent               = bg

    local label                 = Instance.new("TextLabel")
    label.Size                  = UDim2.new(1, 0, 1, 0)
    label.BackgroundTransparency = 1
    label.Text                  = tostring(cost)
    label.TextColor3            = Color3.fromRGB(20, 20, 20)
    label.TextSize              = 15
    label.Font                  = Enum.Font.GothamBold
    label.Parent                = bg
end

local function getBubbleLabel(part: BasePart): TextLabel?
    local bb    = part:FindFirstChild("CoinBubble")
    local frame = bb and bb:FindFirstChildOfClass("Frame")
    return frame and frame:FindFirstChildOfClass("TextLabel") :: TextLabel?
end

local function getBubbleFrame(part: BasePart): Frame?
    local bb = part:FindFirstChild("CoinBubble")
    return bb and bb:FindFirstChildOfClass("Frame") :: Frame?
end

-- ── Find nearest interactive ──────────────────────────────────────────────

local function findNearest(): (Interactive?, Vector3)
    local char = player.Character
    if not char or not char.PrimaryPart then return nil, Vector3.zero end
    local pos = char.PrimaryPart.Position

    local best: Interactive? = nil
    local bestDist = math.huge
    for _, item in _interactives do
        if not item.part.Parent then continue end
        if item.condition and not item.condition() then continue end
        local d    = (item.part.Position - pos).Magnitude
        local limit = item.maxDist or BUY_RADIUS
        if d < limit and d < bestDist then
            bestDist = d
            best     = item
        end
    end
    return best, pos
end

-- ── Streaming coin buy ────────────────────────────────────────────────────
-- Coins fly one at a time into the target; the cost label counts down as
-- each coin lands.  Fires the server only after the last coin arrives.
-- Cancelled immediately if F is released mid-stream.

local _cancelStream   = false
local _streaming      = false
local _streamComplete = false

-- Returns the HUD coin label so we can decrement it in sync with each coin landing.
local function getHudCoinLabel(): TextLabel?
    local gui   = player.PlayerGui:FindFirstChild("GameHud")
    local frame = gui and gui:FindFirstChild("CoinFrame")
    return frame and frame:FindFirstChildOfClass("TextLabel") :: TextLabel?
end

local function streamBuy(best: Interactive, fromPos: Vector3)
    if GameConfig.DEV_MODE then
        _streamComplete = true
        local success = best.action()
        if not success then
            local frame = getBubbleFrame(best.part)
            if frame then
                frame.BackgroundColor3 = Color3.fromRGB(220, 50, 50)
                task.delay(0.4, function()
                    if frame.Parent then
                        frame.BackgroundColor3 = Color3.fromRGB(255, 210, 0)
                    end
                end)
            end
        end
        return
    end

    local cost      = best.cost
    local remaining = cost
    local label     = getBubbleLabel(best.part)

    local function resetLabel()
        if label and label.Parent then label.Text = tostring(cost) end
    end

    for _ = 1, cost do
        if _cancelStream then resetLabel() return end

        local coin      = Instance.new("Part")
        coin.Name       = "CoinFX"
        coin.Size       = Vector3.new(1.35, 1.35, 1.35)
        coin.Shape      = Enum.PartType.Ball
        coin.BrickColor = BrickColor.new("Bright yellow")
        coin.Material   = Enum.Material.Neon
        coin.Anchored   = true
        coin.CanCollide = false
        coin.CastShadow = false
        coin.Position   = fromPos + Vector3.new(
            (math.random() - 0.5) * 1.2, 1.5, (math.random() - 0.5) * 1.2)
        coin.Parent     = workspace

        local mid = (fromPos + best.part.Position) / 2 + Vector3.new(0, 4, 0)

        local t1 = TweenService:Create(coin,
            TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
            { Position = mid })
        t1:Play()
        t1.Completed:Wait()

        if _cancelStream then coin:Destroy() resetLabel() return end

        local t2 = TweenService:Create(coin,
            TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
            { Position = best.part.Position, Size = Vector3.new(0.05, 0.05, 0.05) })
        t2:Play()
        t2.Completed:Wait()
        coin:Destroy()

        remaining -= 1
        if label and label.Parent then label.Text = tostring(remaining) end

        -- Optimistic HUD decrement so counter drops as each coin lands
        local hudLabel = getHudCoinLabel()
        if hudLabel then
            local cur = tonumber(hudLabel.Text:match("%d+")) or 0
            hudLabel.Text = "Coins: " .. math.max(0, cur - 1)
        end
    end

    -- Final cancel check before committing to server
    if _cancelStream then resetLabel() return end

    _streamComplete = true
    local success = best.action()
    -- Server fires CoinChanged which snaps HUD to the authoritative value
    resetLabel()

    if not success then
        -- Flash the bubble red to signal rejection
        local frame = getBubbleFrame(best.part)
        if frame then
            frame.BackgroundColor3 = Color3.fromRGB(220, 50, 50)
            task.delay(0.4, function()
                if frame.Parent then
                    frame.BackgroundColor3 = Color3.fromRGB(255, 210, 0)
                end
            end)
        end
    end
end

-- ── F key: tap = drop coin  /  hold near target = stream buy ─────────────

local _holdStart = 0

UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.KeyCode ~= Enum.KeyCode.F then return end
    _holdStart      = tick()
    _streamComplete = false

    local best, pos = findNearest()
    if best then
        _streaming    = true
        _cancelStream = false
        task.spawn(function()
            streamBuy(best, pos)
            _streaming = false
        end)
    end
end)

UserInputService.InputEnded:Connect(function(input)
    if input.KeyCode ~= Enum.KeyCode.F then return end
    if _streaming then
        _cancelStream = true
        _streaming    = false
    elseif not _streamComplete then
        if tick() - _holdStart < 0.3 then
            Remotes.DropCoins:FireServer(1)
        end
    end
    _holdStart = 0
end)

-- ── Watchers ──────────────────────────────────────────────────────────────

local function watchForShop(shopName: string, cost: number, buyFn: () -> boolean)
    local function attach(child)
        if not (child.Name == shopName and child:IsA("BasePart")) then return end
        local part = child :: BasePart
        attachCoinBubble(part, cost, 20)
        register(part, cost,
            buyFn,
            function(): boolean
                -- Rack not full (checked client-side via replicated attribute)
                return (part:GetAttribute("RackCount") or 0) < GameConfig.RACK_MAX_TOOLS
            end
        )
        -- Update bubble label when rack count changes
        part.AttributeChanged:Connect(function(attr: string)
            if attr ~= "RackCount" then return end
            local count = part:GetAttribute("RackCount") or 0
            local label = getBubbleLabel(part)
            if not label or not label.Parent then return end
            label.Text = count >= GameConfig.RACK_MAX_TOOLS and "FULL" or tostring(cost)
        end)
    end
    workspace.ChildAdded:Connect(attach)
    local existing = workspace:FindFirstChild(shopName)
    if existing and existing:IsA("BasePart") then attach(existing) end
end

local function watchForHammerShop()
    watchForShop("HammerShop", GameConfig.HAMMER_COST, function(): boolean
        return Remotes.BuyTool:InvokeServer()
    end)
end

local function watchForBowShop()
    watchForShop("BowShop", GameConfig.BOW_COST, function(): boolean
        return Remotes.BuyBow:InvokeServer()
    end)
end

local function watchForKnightShields()
    local function attachMount(mount: BasePart)
        if mount:GetAttribute("MountType") ~= "KnightShield" then return end
        attachCoinBubble(mount, GameConfig.KNIGHT_SHIELD_COST, 18)
        register(mount, GameConfig.KNIGHT_SHIELD_COST, function(): boolean
            local slotId = mount:GetAttribute("SlotId")
            if typeof(slotId) ~= "number" then return false end
            return Remotes.BuyKnightShield:InvokeServer(slotId)
        end, function(): boolean
            return not mount:GetAttribute("HasShield") and not mount:GetAttribute("HasBanner")
        end, 18)
        mount.AttributeChanged:Connect(function(attr: string)
            if attr ~= "HasShield" and attr ~= "HasBanner" then return end
            if mount:GetAttribute("HasShield") or mount:GetAttribute("HasBanner") then
                local bb = mount:FindFirstChild("CoinBubble")
                if bb then bb:Destroy() end
            end
        end)
    end

    local function attachModel(model: Instance)
        if model.Name ~= "TownHallModel" then return end
        for _, desc in model:GetDescendants() do
            if desc.Name == "KnightShieldMount" and desc:IsA("BasePart") then
                attachMount(desc)
            end
        end
        model.DescendantAdded:Connect(function(desc: Instance)
            if desc.Name == "KnightShieldMount" and desc:IsA("BasePart") then
                attachMount(desc)
            end
        end)
    end

    workspace.ChildAdded:Connect(function(child)
        if child.Name == "TownHallModel" then attachModel(child) end
    end)
    local existing = workspace:FindFirstChild("TownHallModel")
    if existing then attachModel(existing) end
end

local function watchForTrees()
    local function attach(child)
        if not (child.Name:sub(1, 5) == "Tree_" and child:IsA("Model")) then return end
        -- WaitForChild: model arrives before children replicate on the client
        task.spawn(function()
            local trunk = child:WaitForChild("Trunk", 5)
            if not trunk or not trunk:IsA("BasePart") then return end
            -- TreeSize attribute may not have replicated yet; wait for it
            local treeSize = child:GetAttribute("TreeSize")
            if treeSize == nil then
                child:GetAttributeChangedSignal("TreeSize"):Wait()
                treeSize = child:GetAttribute("TreeSize")
            end
            if treeSize ~= 1 then return end
            local treeId = child.Name:gsub("Tree_", "")
            attachCoinBubble(trunk :: BasePart, GameConfig.TREE_MARK_COST)
            register(trunk :: BasePart, GameConfig.TREE_MARK_COST, function(): boolean
                return Remotes.MarkTree:InvokeServer(treeId)
            end)
        end)
    end
    for _, child in workspace:GetChildren() do
        if child.Name:sub(1, 5) == "Tree_" and child:IsA("Model") then attach(child) end
    end
    workspace.ChildAdded:Connect(attach)
end

local function watchForMayor()
    local function attach(child)
        if not (child.Name == "Mayor" and child:IsA("Model")) then return end
        local root = child:FindFirstChild("HumanoidRootPart")
        if not root or not root:IsA("BasePart") then return end
        attachCoinBubble(root :: BasePart, 10)
        register(root :: BasePart, 10, function(): boolean
            return Remotes.BankWithdraw:InvokeServer(10)
        end)
    end
    workspace.ChildAdded:Connect(attach)
    local existing = workspace:FindFirstChild("Mayor")
    if existing and existing:IsA("Model") then attach(existing) end
end

local function watchForFirePit()
    -- FirePit anchor lives inside FirePitModel (rebuilt on every upgrade).
    -- We track the current upgrade cost here so re-registrations use the right value.
    local _currentCost   = GameConfig.FIREPIT_UPGRADE_COSTS[1]
    local _attachedPart: BasePart? = nil
    local _pendingModel: Model?    = nil

    local function clearFirepitInteractive()
        for i = #_interactives, 1, -1 do
            if _interactives[i].part.Name == "FirePit" then
                table.remove(_interactives, i)
            end
        end
        if _attachedPart and _attachedPart.Parent then
            local bb = _attachedPart:FindFirstChild("CoinBubble")
            if bb then bb:Destroy() end
        end
        _attachedPart = nil
    end

    local function attachModel(model: Model)
        if _pendingModel == model then return end
        _pendingModel = model

        task.spawn(function()
            print("[FirePit] attachModel waiting for FirePit child in", model:GetFullName())
            local part = model:WaitForChild("FirePit", 10)
            _pendingModel = nil

            if not part or not part:IsA("BasePart") then
                warn("[FirePit] no FirePit BasePart inside FirePitModel (timeout)")
                return
            end
            if not model.Parent then return end

            part = part :: BasePart
            if _attachedPart == part then return end

            clearFirepitInteractive()
            _attachedPart = part
            -- Only clear if THIS model is still the active firepit (old models' Destroying
            -- callbacks fire after the replacement re-attaches and must not wipe the new one).
            model.Destroying:Once(function()
                if _attachedPart and _attachedPart:IsDescendantOf(model) then
                    clearFirepitInteractive()
                end
            end)

            attachCoinBubble(part, _currentCost, 30)
            register(part, _currentCost, function(): boolean
                return Remotes.UpgradeFirepit:InvokeServer()
            end, nil, 15)
            print("[FirePit] registered — cost:", _currentCost, "pos:", part.Position)
        end)
    end

    -- New FirePitModel replicated (initial spawn or post-upgrade rebuild)
    workspace.ChildAdded:Connect(function(child)
        if child.Name == "FirePitModel" and child:IsA("Model") then
            print("[FirePit] FirePitModel arrived via ChildAdded")
            attachModel(child :: Model)
        end
    end)

    -- Already in workspace when this controller loads (DEV_MODE fast spawn)
    local existing = workspace:FindFirstChild("FirePitModel")
    print("[FirePit] existing FirePitModel on load:", existing)
    if existing and existing:IsA("Model") then
        attachModel(existing :: Model)
    end

    -- Keep cost in sync; when nextCost is nil the firepit is maxed out
    Remotes.FirepitLevelChanged.OnClientEvent:Connect(function(_level: number, nextCost: number?)
        if nextCost then
            _currentCost = nextCost
            if _attachedPart and _attachedPart.Parent then
                for _, item in _interactives do
                    if item.part == _attachedPart then
                        item.cost = nextCost
                        break
                    end
                end
                local lbl = getBubbleLabel(_attachedPart)
                if lbl and lbl.Parent then lbl.Text = tostring(nextCost) end
            else
                -- Rebuild may have cleared registration before the new model attached
                local model = workspace:FindFirstChild("FirePitModel")
                if model and model:IsA("Model") then
                    attachModel(model :: Model)
                end
            end
        else
            clearFirepitInteractive()
        end
    end)
end

local function watchForBoat()
    local function attach(child)
        if not (child.Name == "BrokenBoat" and child:IsA("BasePart")) then return end
        local part = child :: BasePart
        attachCoinBubble(part, GameConfig.BOAT_REPAIR_COST, 15)
        register(part, GameConfig.BOAT_REPAIR_COST, function(): boolean
            local ok = Remotes.MarkBoat:InvokeServer()
            if ok then
                for i, item in _interactives do
                    if item.part == part then table.remove(_interactives, i) break end
                end
                local bb = part:FindFirstChild("CoinBubble")
                if bb then bb:Destroy() end
            end
            return ok
        end)
    end
    workspace.ChildAdded:Connect(attach)
    local existing = workspace:FindFirstChild("BrokenBoat")
    if existing and existing:IsA("BasePart") then attach(existing) end
end

local function watchForStructureFoundations()
    local function removeBubbleAndInteractive(part: BasePart)
        for i, item in _interactives do
            if item.part == part then table.remove(_interactives, i) break end
        end
        local bb = part:FindFirstChild("CoinBubble")
        if bb then bb:Destroy() end
    end

    local function attach(child)
        if not child:IsA("BasePart") then return end
        if child:GetAttribute("Level") ~= 0 then return end
        if not child:GetAttribute("StructureType") then return end
        if child:GetAttribute("BuildUnlocked") == true then return end  -- already paid; builder handles it
        local part     = child :: BasePart
        local required = part:GetAttribute("BuildRequired") or GameConfig.STRUCTURE_BUILD_DURATION
        local initial  = required - (part:GetAttribute("BuildProgress") or 0)
        attachCoinBubble(part, initial, GameConfig.STRUCTURE_INTERACT_RADIUS)
        register(part, 1, function(): boolean
            return Remotes.BuildStructure:InvokeServer()
        end, function(): boolean
            return part:GetAttribute("Level") == 0 and part:GetAttribute("BuildUnlocked") ~= true
        end, GameConfig.STRUCTURE_INTERACT_RADIUS)
        -- Remove bubble when fully paid (BuildUnlocked) or when actually built (Level=1)
        part.AttributeChanged:Connect(function(attr: string)
            if attr ~= "BuildProgress" and attr ~= "Level" and attr ~= "BuildUnlocked" then return end
            if part:GetAttribute("Level") ~= 0 or part:GetAttribute("BuildUnlocked") == true then
                removeBubbleAndInteractive(part)
                return
            end
            local req   = part:GetAttribute("BuildRequired") or GameConfig.STRUCTURE_BUILD_DURATION
            local prog  = part:GetAttribute("BuildProgress") or 0
            local label = getBubbleLabel(part)
            if label and label.Parent then label.Text = tostring(req - prog) end
        end)
    end
    for _, child in workspace:GetChildren() do attach(child) end
    workspace.ChildAdded:Connect(attach)
end

local function watchForPortals()
    local function attach(child)
        if not (child.Name == "Portal" and child:IsA("BasePart")) then return end
        local part = child :: BasePart
        -- Show remaining HP in the bubble (colour it red to distinguish from coin costs)
        local hp = part:GetAttribute("Health") or GameConfig.PORTAL_HEALTH
        attachCoinBubble(part, hp, GameConfig.PORTAL_INTERACT_RADIUS)
        local frame = getBubbleFrame(part)
        if frame then frame.BackgroundColor3 = Color3.fromRGB(180, 30, 30) end
        -- Keep bubble HP label in sync as players whittle the portal down
        part.AttributeChanged:Connect(function(attr)
            if attr ~= "Health" then return end
            local label = getBubbleLabel(part)
            if label and label.Parent then
                label.Text = tostring(part:GetAttribute("Health") or 0)
            end
        end)
        -- Register as zero-cost interactive (no coins spent, just an attack tap)
        register(part, 0, function(): boolean
            local remaining = Remotes.AttackPortal:InvokeServer()
            return remaining >= 0
        end, nil, GameConfig.PORTAL_INTERACT_RADIUS)
    end
    workspace.ChildAdded:Connect(attach)
    for _, child in workspace:GetChildren() do
        if child.Name == "Portal" and child:IsA("BasePart") then attach(child) end
    end
end

local function watchForTowers()
    -- Every time spawnTower fires on the server it sets UpgradeTier on the anchor.
    -- That attribute replicates to the client and triggers onTierChanged, which
    -- re-registers the interactive with the correct next-tier cost.

    local function onTierChanged(anchor: BasePart)
        local tier = anchor:GetAttribute("UpgradeTier")
        if tier == nil then return end

        -- Clear any old interactive + bubble for this anchor
        for i = #_interactives, 1, -1 do
            if _interactives[i].part == anchor then table.remove(_interactives, i) end
        end
        local oldBubble = anchor:FindFirstChild("CoinBubble")
        if oldBubble then oldBubble:Destroy() end

        local nextCost = GameConfig.TOWER_UPGRADE_COSTS[tier + 1]  -- [1]=3 for 0→1, …, [6]=13 for 5→6
        if not nextCost then return end  -- tier 6 max, no bubble needed

        attachCoinBubble(anchor, nextCost, 20)
        register(anchor, nextCost, function(): boolean
            return Remotes.UpgradeTower:InvokeServer(anchor.Name)
        end, nil, 15)
    end

    local function hookAnchor(child: Instance)
        if not child:IsA("BasePart") then return end
        local anchor = child :: BasePart
        if anchor:GetAttribute("StructureType") ~= "Tower" then return end
        -- React now if UpgradeTier already replicated, and on every future change
        onTierChanged(anchor)
        anchor:GetAttributeChangedSignal("UpgradeTier"):Connect(function()
            onTierChanged(anchor)
        end)
    end

    for _, child in workspace:GetChildren() do hookAnchor(child) end
    workspace.ChildAdded:Connect(hookAnchor)

    -- After a successful upgrade the server fires TowerLevelChanged;
    -- update cost label immediately so the player sees the next tier's price
    -- without waiting for the UpgradeTier attribute replication round-trip.
    Remotes.TowerLevelChanged.OnClientEvent:Connect(function(towerName: string, _tier: number, nextCost: number?)
        local anchor = workspace:FindFirstChild(towerName)
        if not anchor or not anchor:IsA("BasePart") then return end
        if nextCost then
            for _, item in _interactives do
                if item.part == anchor then item.cost = nextCost break end
            end
            local lbl = getBubbleLabel(anchor :: BasePart)
            if lbl then lbl.Text = tostring(nextCost) end
        end
        -- nil nextCost means maxed — the UpgradeTier attribute change already cleared it
    end)
end

watchForHammerShop()
watchForBowShop()
watchForKnightShields()
watchForTrees()
watchForMayor()
watchForFirePit()
watchForBoat()
watchForPortals()
watchForStructureFoundations()
watchForTowers()

local InputController = {}
return InputController
