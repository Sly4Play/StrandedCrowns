return {
    -- Phase durations (seconds) — tune via playtesting
    DAWN_DURATION  = 30,
    DAY_DURATION   = 240,
    DUSK_DURATION  = 30,
    NIGHT_DURATION = 120,

    -- Island layout (XZ positions; Y computed per-object at spawn)
    TOWN_CENTER_POS  = Vector3.new(  0, 0,    0),
    PORTAL_NORTH_POS = Vector3.new(  0, 0, -240),
    PORTAL_SOUTH_POS = Vector3.new(  0, 0,  240),
    ISLAND_RADIUS    = 160,  -- fallback; per-island values below take priority

    -- Per-island scaling. Island 5 must fit: main dungeon + lighthouse + 8 portals.
    ISLAND_RADIUS_BY_ISLAND = {160, 195, 230, 270, 340},
    TREE_COUNT_BY_ISLAND    = { 45,  58,  72,  88, 110},

    -- Gate positions (placeholder — no gate models in Phase 1)
    GATE_NORTH = Vector3.new(  0, 0, -40),
    GATE_SOUTH = Vector3.new(  0, 0,  40),
    GATE_EAST  = Vector3.new( 40, 0,   0),
    GATE_WEST  = Vector3.new(-40, 0,   0),

    -- Purse limits
    PLAYER_PURSE_MAX  = 25,
    BUILDER_PURSE_MAX = 10,
    WORKER_PURSE_MAX  = 10,   -- all hired NPCs carry up to 10 coins
    NPC_DUMP_RADIUS   = 8,    -- studs: NPC dumps coins to player within this range

    -- Economy
    STARTER_COINS          = 10,
    TREE_MARK_COST         = 1,
    TREE_CHOP_REWARD       = 2,   -- coins paid to the builder who chops
    TREE_MARK_RETURN_MULT  = 2,   -- unused in Phase 1, kept for Phase 2
    GROUND_COIN_DESPAWN    = 120,   -- seconds
    OWN_COIN_PICKUP_DELAY  = 5,     -- seconds

    -- Mayor bank
    BANK_INTEREST_RATE  = 0.05,
    BANK_INTEREST_CAP   = 15,
    MAYOR_DEPOSIT_RADIUS = 8,
    MAYOR_BANK_STEAL_AMT = 5,

    -- Town
    TOWN_RADIUS           = 44,
    FIREPIT_UPGRADE_COSTS = {8, 10, 12, 14, 16},

    -- Vagrant camps
    CAMP_COUNT                = 4,
    CAMP_MAX_VAGRANTS         = 5,
    CAMP_SPAWN_MIN            = 2,
    CAMP_SPAWN_MAX            = 3,
    CAMP_MIN_DIST_PORTAL      = 8,
    CAMP_MIN_DIST_SHORE       = 8,
    CAMP_MIN_DIST_TOWN_EDGE   = 55,  -- studs beyond town radius before camps can spawn
    CAMP_MIN_DIST_CAMP        = 50,  -- minimum studs between any two camps
    BOAT_MIN_DIST_CAMP        = 40,  -- camps must stay this far from the broken boat
    CAMP_RADIUS               = 35,

    -- NPC speeds
    NPC_RUN_SPEED      = 14,   -- purposeful movement: coin chase, to town, fetch tool, chop tree
    NPC_WANDER_SPEED   = 7,    -- idle wander: jobless at town, builder when no trees
    VAGRANT_WALK_SPEED = 2.5,  -- homeless slow amble

    -- Coin pickup
    COIN_PICKUP_RADIUS        = 2,
    HIRE_COIN_RADIUS          = 6,
    VAGRANT_COIN_SCAN_RADIUS  = 30,  -- how far homeless scan for player-dropped coins
    NPC_OVERFLOW_RADIUS       = 20,
    WORKER_COIN_PICKUP_DELAY  = 2,   -- seconds workers wait before collecting nearby ground coins

    -- Tool shops / racks
    RACK_MAX_TOOLS  = 4,    -- max tools on any shop rack at once
    HAMMER_COST     = 3,
    BOW_COST        = 2,

    -- Hunter
    HUNTER_PURSE_MAX = 8,

    -- Structures
    STRUCTURE_BUILD_DURATION = 5,
    TOWER_MAX_BUILDERS       = 2,
    BARRICADE_MAX_BUILDERS   = 2,

    -- Trees
    TREE_MAX_PLAYER_MARKS = 2,
    TREE_COUNT           = 45,
    TREE_MIN_DIST_TOWN   = 15,
    TREE_MIN_DIST_PORTAL = 12,
    TREE_CHOP_DURATION   = 3,

    -- Mounds (Phase 3 — placed but inert in Phase 1)
    MOUND_COUNT           = 8,
    MOUND_MIN_DIST_PORTAL = 10,

    -- Boat repair
    BOAT_REPAIR_COST     = 10,
    BOAT_REPAIR_DURATION = 120,
    BOAT_MAX_BUILDERS    = 3,

    -- Greed
    GREED_SPAWN_INTERVAL = 1,
    GREED_SPEED          = 16,
    GREED_RETREAT_SPEED  = 24,
    GREED_SCAN_RADIUS    = 35,
    GREED_STEAL_RANGE    = 3,
}
