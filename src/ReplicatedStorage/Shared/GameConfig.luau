return {
    -- Phase durations (seconds) — tune via playtesting
    DAWN_DURATION  = 30,
    DAY_DURATION   = 240,
    DUSK_DURATION  = 30,
    NIGHT_DURATION = 120,

    -- Island layout (XZ positions; Y computed per-object at spawn)
    TOWN_CENTER_POS  = Vector3.new(  0, 0,    0),
    PORTAL_NORTH_POS = Vector3.new(  0, 0, -120),
    PORTAL_SOUTH_POS = Vector3.new(  0, 0,  120),
    ISLAND_RADIUS    = 140,

    -- Gate positions (placeholder — no gate models in Phase 1)
    GATE_NORTH = Vector3.new(  0, 0, -40),
    GATE_SOUTH = Vector3.new(  0, 0,  40),
    GATE_EAST  = Vector3.new( 40, 0,   0),
    GATE_WEST  = Vector3.new(-40, 0,   0),

    -- Purse limits
    PLAYER_PURSE_MAX  = 25,
    BUILDER_PURSE_MAX = 10,
    WORKER_PURSE_MAX  = 5,

    -- Economy
    STARTER_COINS          = 10,
    HAMMER_COST            = 3,
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
    TOWN_RADIUS = 20,   -- NPCs wander within this radius; shops sit near the edge

    -- Vagrant camps
    CAMP_COUNT           = 4,
    CAMP_MAX_VAGRANTS    = 5,
    CAMP_SPAWN_MIN       = 2,
    CAMP_SPAWN_MAX       = 3,
    CAMP_MIN_DIST_PORTAL = 8,
    CAMP_MIN_DIST_SHORE  = 8,
    CAMP_RADIUS          = 24,

    -- NPC speeds
    WORKER_WALK_SPEED  = 14,
    VAGRANT_WALK_SPEED = 10,

    -- Coin pickup
    COIN_PICKUP_RADIUS        = 2,
    HIRE_COIN_RADIUS          = 6,
    VAGRANT_COIN_SCAN_RADIUS  = 8,   -- how far vagrants scan for player-dropped coins
    NPC_OVERFLOW_RADIUS       = 20,
    WORKER_COIN_PICKUP_DELAY  = 2,   -- seconds workers wait before collecting nearby ground coins

    -- Trees
    TREE_MAX_PLAYER_MARKS = 2,
    TREE_COUNT           = 25,
    TREE_MIN_DIST_TOWN   = 15,
    TREE_MIN_DIST_PORTAL = 12,
    TREE_CHOP_DURATION   = 3,

    -- Mounds (Phase 3 — placed but inert in Phase 1)
    MOUND_COUNT           = 8,
    MOUND_MIN_DIST_PORTAL = 10,

    -- Greed
    GREED_SPAWN_INTERVAL = 1,
    GREED_SPEED          = 16,
    GREED_RETREAT_SPEED  = 24,
    GREED_SCAN_RADIUS    = 35,
    GREED_STEAL_RANGE    = 3,
}
