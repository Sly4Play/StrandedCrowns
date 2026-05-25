local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService  = game:GetService("UserInputService")
local TweenService      = game:GetService("TweenService")
local GameConfig        = require(ReplicatedStorage.Shared.GameConfig)
local Remotes           = require(ReplicatedStorage.Shared.Remotes)

local player         = Players.LocalPlayer
local BUY_RADIUS     = 8
local HOLD_THRESHOLD = 0.8

-- ── Interactive registry ──────────────────────────────────────────────────

type Interactive = { part: BasePart, cost: number, action: () -> boolean }
local _interactives: {Interactive} = {}

local function register(part: BasePart, cost: number, action: () -> boolean)
    table.insert(_interactives, { part = part, cost = cost, action = action })
end

-- ── Coin bubble ───────────────────────────────────────────────────────────

local function attachCoinBubble(part: BasePart, cost: number, maxDist: number?)
    local billboard             = Instance.new("BillboardGui")
    billboard.Name              = "CoinBubble"
    billboard.Size              = UDim2.new(0, 44, 0, 24)
    billboard.StudsOffset       = Vector3.new(0, 5, 0)
    billboard.MaxDistance       = maxDist or 12
    billboard.AlwaysOnTop       = false
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

-- ── Coin fly animation ────────────────────────────────────────────────────

local function playCoinFlyAnim(fromPos: Vector3, toPos: Vector3, count: number, success: boolean)
    local coinCount = math.min(count, 5)
    for i = 1, coinCount do
        task.spawn(function()
            task.wait((i - 1) * 0.06)

            local coin          = Instance.new("Part")
            coin.Name           = "CoinFX"
            coin.Size           = Vector3.new(0.45, 0.45, 0.45)
            coin.Shape          = Enum.PartType.Ball
            coin.BrickColor     = BrickColor.new("Bright yellow")
            coin.Material       = Enum.Material.Neon
            coin.Anchored       = true
            coin.CanCollide     = false
            coin.CastShadow     = false
            coin.Position       = fromPos + Vector3.new(
                (math.random() - 0.5) * 1.2, 1.5, (math.random() - 0.5) * 1.2)
            coin.Parent         = workspace

            -- Arc midpoint between player and target
            local mid = (fromPos + toPos) / 2 + Vector3.new(0, 4, 0)

            local t1 = TweenService:Create(coin,
                TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
                { Position = mid })
            t1:Play()
            t1.Completed:Wait()

            if success then
                -- Fly into the target and shrink away
                local t2 = TweenService:Create(coin,
                    TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
                    { Position = toPos, Size = Vector3.new(0.05, 0.05, 0.05) })
                t2:Play()
                t2.Completed:Wait()
                coin:Destroy()
            else
                -- Bounce back down to ground near player
                local scatter = fromPos + Vector3.new(
                    (math.random() - 0.5) * 2.5, 0.5, (math.random() - 0.5) * 2.5)
                local t2 = TweenService:Create(coin,
                    TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
                    { Position = scatter })
                t2:Play()
                t2.Completed:Wait()
                -- Sit on ground briefly (server has spawned real pickable coins)
                task.delay(4, function()
                    if coin.Parent then coin:Destroy() end
                end)
            end
        end)
    end
end

-- ── Buy nearest on long hold ──────────────────────────────────────────────

local function buyNearest()
    local char = player.Character
    if not char or not char.PrimaryPart then return end
    local pos  = char.PrimaryPart.Position

    local best: Interactive? = nil
    local bestDist = BUY_RADIUS
    for _, item in _interactives do
        if not item.part.Parent then continue end
        local d = (item.part.Position - pos).Magnitude
        if d < bestDist then
            bestDist = d
            best     = item
        end
    end

    if best then
        local success = best.action()
        playCoinFlyAnim(pos, best.part.Position, best.cost, success)
    end
end

-- ── F key: tap = drop coin  /  hold = buy nearest ────────────────────────

local _holdStart = 0

UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.KeyCode == Enum.KeyCode.F then
        _holdStart = tick()
    end
end)

UserInputService.InputEnded:Connect(function(input)
    if input.KeyCode ~= Enum.KeyCode.F then return end
    local duration = tick() - _holdStart
    _holdStart = 0
    if duration < HOLD_THRESHOLD then
        Remotes.DropCoins:FireServer(1)
    else
        buyNearest()
    end
end)

-- ── Watchers ──────────────────────────────────────────────────────────────

local function watchForHammerShop()
    local function attach(child)
        if not (child.Name == "HammerShop" and child:IsA("BasePart")) then return end
        local part = child :: BasePart
        attachCoinBubble(part, GameConfig.HAMMER_COST)
        register(part, GameConfig.HAMMER_COST, function(): boolean
            return Remotes.BuyTool:InvokeServer()
        end)
    end
    workspace.ChildAdded:Connect(attach)
    local existing = workspace:FindFirstChild("HammerShop")
    if existing and existing:IsA("BasePart") then attach(existing) end
end

local function watchForTrees()
    local function attach(child)
        if not (child.Name:sub(1, 5) == "Tree_" and child:IsA("Model")) then return end
        local trunk = child:FindFirstChild("Trunk")
        if not trunk or not trunk:IsA("BasePart") then return end
        local treeId = child.Name:gsub("Tree_", "")
        attachCoinBubble(trunk :: BasePart, GameConfig.TREE_MARK_COST)
        register(trunk :: BasePart, GameConfig.TREE_MARK_COST, function(): boolean
            return Remotes.MarkTree:InvokeServer(treeId)
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

watchForHammerShop()
watchForTrees()
watchForMayor()

local InputController = {}
return InputController
