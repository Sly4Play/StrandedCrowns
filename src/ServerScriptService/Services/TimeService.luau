local GameConfig = require(game:GetService("ReplicatedStorage").Shared.GameConfig)
local Remotes    = require(game:GetService("ReplicatedStorage").Shared.Remotes)
local Players    = game:GetService("Players")

local PHASES = {"Dawn", "Day", "Dusk", "Night"}
local DURATIONS = {
    Dawn  = GameConfig.DAWN_DURATION,
    Day   = GameConfig.DAY_DURATION,
    Dusk  = GameConfig.DUSK_DURATION,
    Night = GameConfig.NIGHT_DURATION,
}

local _dayNumber = 0
local _phase     = "Dawn"

local _events: {[string]: BindableEvent} = {
    Dawn  = Instance.new("BindableEvent"),
    Day   = Instance.new("BindableEvent"),
    Dusk  = Instance.new("BindableEvent"),
    Night = Instance.new("BindableEvent"),
}

local function broadcast()
    for _, player in Players:GetPlayers() do
        Remotes.PhaseChanged:FireClient(player, _phase, _dayNumber)
    end
end
Players.PlayerAdded:Connect(function(player)
    Remotes.PhaseChanged:FireClient(player, _phase, _dayNumber)
end)

local function advanceTo(phase: string)
    _phase = phase
    if phase == "Dawn" then
        _dayNumber += 1
        _events.Dawn:Fire(_dayNumber)
    elseif phase == "Day" then
        _events.Day:Fire()
    elseif phase == "Dusk" then
        _events.Dusk:Fire()
    elseif phase == "Night" then
        _events.Night:Fire()
    end
    broadcast()
end

task.spawn(function()
    _dayNumber += 1                  -- day 1 starts here, same path as all future Dawns
    broadcast()
    _events.Dawn:Fire(_dayNumber)   -- fire Dawn for day 1
    while true do
        task.wait(DURATIONS[_phase])
        local idx  = table.find(PHASES, _phase) :: number
        local next = PHASES[(idx % #PHASES) + 1]
        advanceTo(next)
    end
end)

local TimeService = {}

function TimeService.getDayNumber(): number return _dayNumber end
function TimeService.getPhase():     string  return _phase    end

function TimeService.onDawn(cb: (number) -> ()): RBXScriptConnection
    return _events.Dawn.Event:Connect(cb)
end
function TimeService.onDay(cb: () -> ()): RBXScriptConnection
    return _events.Day.Event:Connect(cb)
end
function TimeService.onDusk(cb: () -> ()): RBXScriptConnection
    return _events.Dusk.Event:Connect(cb)
end
function TimeService.onNight(cb: () -> ()): RBXScriptConnection
    return _events.Night.Event:Connect(cb)
end

TimeService._runTests = function()
    assert(TimeService.getPhase() == "Dawn", "Should start in Dawn")
    print("[TimeService] Tests PASS")
end

return TimeService
