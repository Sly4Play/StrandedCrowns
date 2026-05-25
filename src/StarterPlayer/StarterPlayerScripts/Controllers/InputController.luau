local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService  = game:GetService("UserInputService")
local TweenService      = game:GetService("TweenService")
local GameConfig        = require(ReplicatedStorage.Shared.GameConfig)
local Remotes           = require(ReplicatedStorage.Shared.Remotes)

local player     = Players.LocalPlayer
local BUY_RADIUS = 5

-- ── Interactive registry ──────────────────────────────────────────────────

type Interactive = { part: BasePart, cost: number, action: () -> boolean, condition: (() -> boolean)? }
local _interactives: {Interactive} = {}

local function register(part: BasePart, cost: number, action: () -> boolean, condition: (() -> boolean)?)
    table.insert(_interactives, { part = part, cost = cost, action = action, condition = condition })
end

-- ── Coin bubble ───────────────────────────────────────────────────────────

local function attachCoinBubble(part: BasePart, cost: number, maxDist: number?)
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
    local bestDist = BUY_RADIUS
    for _, item in _interactives do
        if not item.part.Parent then continue end
        if item.condition and not item.condition() then continue end
        local d = (item.part.Position - pos).Magnitude
        if d < bestDist then
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
        coin.Size       = Vector3.new(0.45, 0.45, 0.45)
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
            TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
            { Position = mid })
        t1:Play()
        t1.Completed:Wait()

        if _cancelStream then coin:Destroy() resetLabel() return end

        local t2 = TweenService:Create(coin,
            TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
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

local function watchForTrees()
    local function attach(child)
        if not (child.Name:sub(1, 5) == "Tree_" and child:IsA("Model")) then return end
        -- WaitForChild: model arrives before children replicate on the client
        task.spawn(function()
            local trunk = child:WaitForChild("Trunk", 5)
            if not trunk or not trunk:IsA("BasePart") then return end
            if child:GetAttribute("TreeSize") ~= 1 then return end
            local treeId = child.Name:gsub("Tree_", "")
            attachCoinBubble(trunk :: BasePart, GameConfig.TREE_MARK_COST)
            register(trunk :: BasePart, GameConfig.TREE_MARK_COST, function(): boolean
                return Remotes.MarkTree:InvokeServer(treeId)
            end)
        end)
    end
    for _, child in workspace:GetChildren() do attach(child) end
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
    local function attach(child)
        if not (child.Name == "FirePit" and child:IsA("BasePart")) then return end
        local part        = child :: BasePart
        local initialCost = GameConfig.FIREPIT_UPGRADE_COSTS[1]
        attachCoinBubble(part, initialCost, 15)
        register(part, initialCost, function(): boolean
            return Remotes.UpgradeFirepit:InvokeServer()
        end)
        Remotes.FirepitLevelChanged.OnClientEvent:Connect(function(_level: number, nextCost: number?)
            for i, item in _interactives do
                if item.part ~= part then continue end
                if nextCost then
                    item.cost = nextCost
                    local label = getBubbleLabel(part)
                    if label and label.Parent then label.Text = tostring(nextCost) end
                else
                    -- All upgrades done
                    table.remove(_interactives, i)
                    local bb = part:FindFirstChild("CoinBubble")
                    if bb then bb:Destroy() end
                end
                break
            end
        end)
    end
    workspace.ChildAdded:Connect(attach)
    local existing = workspace:FindFirstChild("FirePit")
    if existing and existing:IsA("BasePart") then attach(existing) end
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

watchForHammerShop()
watchForBowShop()
watchForTrees()
watchForMayor()
watchForFirePit()
watchForBoat()

local InputController = {}
return InputController
