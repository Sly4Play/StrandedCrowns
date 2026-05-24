local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService  = game:GetService("UserInputService")
local GameConfig        = require(ReplicatedStorage.Shared.GameConfig)
local Remotes           = require(ReplicatedStorage.Shared.Remotes)

local player  = Players.LocalPlayer

local PROMPT_RADIUS = 8

-- ── Proximity prompt helper ───────────────────────────────────────────────

local function addPrompt(part: BasePart, label: string, onActivate: () -> ())
    local prompt            = Instance.new("ProximityPrompt")
    prompt.ActionText       = label
    prompt.HoldDuration     = 0
    prompt.MaxActivationDistance = PROMPT_RADIUS
    prompt.Parent           = part
    prompt.Triggered:Connect(function(triggeringPlayer)
        if triggeringPlayer == player then onActivate() end
    end)
    return prompt
end

-- ── Hammer Shop ───────────────────────────────────────────────────────────

local function watchForHammerShop()
    local function attach(child)
        if child.Name == "HammerShop" and child:IsA("BasePart") then
            addPrompt(child :: BasePart, "Buy Hammer (3 coins)", function()
                local success = Remotes.BuyTool:InvokeServer()
                if not success then
                    print("[InputController] Not enough coins for hammer")
                end
            end)
        end
    end
    workspace.ChildAdded:Connect(attach)
    local existing = workspace:FindFirstChild("HammerShop")
    if existing and existing:IsA("BasePart") then attach(existing) end
end

-- ── Trees (mark on proximity prompt) ─────────────────────────────────────

local function attachTreePrompt(treeModel: Model)
    local trunk = treeModel:FindFirstChild("Trunk")
    if not trunk or not trunk:IsA("BasePart") then return end
    local treeId = treeModel.Name:gsub("Tree_", "")
    addPrompt(trunk :: BasePart, "Mark Tree (" .. GameConfig.TREE_MARK_COST .. " coins)", function()
        local success = Remotes.MarkTree:InvokeServer(treeId)
        if not success then print("[InputController] Cannot mark tree") end
    end)
end

local function watchForTrees()
    for _, child in workspace:GetChildren() do
        if child.Name:sub(1, 5) == "Tree_" and child:IsA("Model") then
            attachTreePrompt(child :: Model)
        end
    end
    workspace.ChildAdded:Connect(function(child)
        if child.Name:sub(1, 5) == "Tree_" and child:IsA("Model") then
            attachTreePrompt(child :: Model)
        end
    end)
end

-- ── Mayor (deposit / withdraw) ────────────────────────────────────────────

local function watchForMayor()
    local function attachMayorPrompts(mayor: Model)
        local root = mayor:FindFirstChild("HumanoidRootPart")
        if not root or not root:IsA("BasePart") then return end

        addPrompt(root :: BasePart, "Deposit 5 coins", function()
            Remotes.DropCoins:FireServer(5)
        end)

        addPrompt(root :: BasePart, "Withdraw 10 coins", function()
            local success = Remotes.BankWithdraw:InvokeServer(10)
            if not success then print("[InputController] Withdraw failed") end
        end)
    end

    workspace.ChildAdded:Connect(function(child)
        if child.Name == "Mayor" and child:IsA("Model") then
            attachMayorPrompts(child :: Model)
        end
    end)
    local existing = workspace:FindFirstChild("Mayor")
    if existing and existing:IsA("Model") then
        attachMayorPrompts(existing :: Model)
    end
end

-- ── Vagrant hiring (F key to drop a coin near camp) ──────────────────────

UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.KeyCode == Enum.KeyCode.F then
        Remotes.DropCoins:FireServer(1)
    end
end)

-- ── Init ──────────────────────────────────────────────────────────────────

watchForHammerShop()
watchForTrees()
watchForMayor()

local InputController = {}
return InputController
