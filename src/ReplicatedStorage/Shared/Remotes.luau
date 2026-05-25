local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local IS_SERVER         = RunService:IsServer()

local folder: Folder
if IS_SERVER then
    folder = Instance.new("Folder")
    folder.Name   = "Remotes"
    folder.Parent = ReplicatedStorage
else
    folder = ReplicatedStorage:WaitForChild("Remotes", 15) :: Folder
end

local function get(className: string, name: string): any
    if IS_SERVER then
        local inst = Instance.new(className) :: any
        inst.Name   = name
        inst.Parent = folder
        return inst
    else
        local inst = folder:WaitForChild(name, 15)
        assert(inst, "Remotes: timed out waiting for " .. name)
        return inst
    end
end

return {
    -- Server → Client
    PhaseChanged = get("RemoteEvent",    "PhaseChanged"),  -- (phase: Phase, day: number)
    CoinChanged  = get("RemoteEvent",    "CoinChanged"),   -- (amount: number)
    -- Client → Server
    DropCoins    = get("RemoteEvent",    "DropCoins"),     -- (amount: number)
    DropFood     = get("RemoteEvent",    "DropFood"),      -- () spawns food at player pos
    BuyTool      = get("RemoteFunction", "BuyTool"),       -- () → bool
    MarkTree     = get("RemoteFunction", "MarkTree"),      -- (treeId: string) → bool
    BankWithdraw = get("RemoteFunction", "BankWithdraw"),  -- (amount: number) → bool
}
