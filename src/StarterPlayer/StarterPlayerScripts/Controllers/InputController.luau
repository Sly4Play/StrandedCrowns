local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService  = game:GetService("UserInputService")
local GameConfig        = require(ReplicatedStorage.Shared.GameConfig)
local Remotes           = require(ReplicatedStorage.Shared.Remotes)

local player         = Players.LocalPlayer
local BUY_RADIUS     = 8
local HOLD_THRESHOLD = 0.8  -- seconds to count as a hold

-- ── Interactive registry ──────────────────────────────────────────────────

type Interactive = { part: BasePart, action: () -> () }
local _interactives: {Interactive} = {}

local function register(part: BasePart, action: () -> ())
    table.insert(_interactives, { part = part, action = action })
end

-- ── Coin bubble ───────────────────────────────────────────────────────────

local function attachCoinBubble(part: BasePart, cost: number)
    local billboard             = Instance.new("BillboardGui")
    billboard.Name              = "CoinBubble"
    billboard.Size              = UDim2.new(0, 44, 0, 24)
    billboard.StudsOffset       = Vector3.new(0, 5, 0)
    billboard.MaxDistance       = 20
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
    if best then best.action() end
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
        register(part, function()
            local ok = Remotes.BuyTool:InvokeServer()
            if not ok then print("[InputController] Not enough coins for hammer") end
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
        register(trunk :: BasePart, function()
            local ok = Remotes.MarkTree:InvokeServer(treeId)
            if not ok then print("[InputController] Cannot mark tree") end
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
        register(root :: BasePart, function()
            local ok = Remotes.BankWithdraw:InvokeServer(10)
            if not ok then print("[InputController] Withdraw failed") end
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
