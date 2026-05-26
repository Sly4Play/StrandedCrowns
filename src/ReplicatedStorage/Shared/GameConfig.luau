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
    ISLAND_RADIUS    = 240,  -- fallback; per-island values below take priority

    -- Per-island scaling. Island 5 must fit: main dungeon + lighthouse + 8 portals.
    ISLAND_RADIUS_BY_ISLAND = {240, 295, 345, 405, 510},
    TREE_COUNT_BY_ISLAND    = {110, 140, 180, 225, 275},

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

    -- Animals
    ANIMAL_COUNT               = 10,   -- target live population on island
    ANIMAL_RESPAWN_DELAY       = 30,   -- seconds before a replacement spawns after a kill
    ANIMAL_COIN_REWARD         = 2,    -- coins dropped at death site
    ANIMAL_WANDER_SPEED        = 5,
    ANIMAL_SPAWN_MIN_DIST_PORTAL = 20,  -- keep animals away from portals

    -- Hunter
    HUNTER_PURSE_MAX    = 8,
    HUNTER_SHOOT_RANGE  = 30,   -- studs; hunter shoots from within this radius
    HUNTER_SHOOT_DELAY  = 0.7,  -- seconds for arrow projectile travel
    TOWER_OCCUPY_DIST   = 8,    -- studs: hunter enters tower and converts to TowerArcher

    -- Structures
    STRUCTURE_BUILD_DURATION = 5,
    TOWER_BUILD_COST         = 3,   -- coins to unlock a tower marker (player F-hold); builder then completes it
    BARRICADE_BUILD_COST     = 1,   -- coins to unlock a barricade marker; builder then completes it
    FARMING_BUILD_COST       = 4,   -- coins player must spend to establish a farming area
    TOWER_MAX_BUILDERS       = 2,
    BARRICADE_MAX_BUILDERS   = 2,

    -- Random scattered build markers (placed by buildIsland, built by player coin drop)
    RANDOM_BARRICADE_COUNT   = 14,
    RANDOM_TOWER_COUNT       = 10,
    RANDOM_FARM_COUNT        = 8,
    MARKER_MIN_DIST_TOWN     = 20,  -- studs beyond town radius before markers can spawn
    MARKER_MIN_DIST_PORTAL   = 30,  -- keep markers away from portals and guardian
    MARKER_MIN_DIST_GUARDIAN = 30,  -- Phase 2: Big Breeder exclusion zone
    MARKER_MIN_DIST_MARKER   = 22,  -- minimum studs between any two random markers

    -- Trees
    TREE_MAX_PLAYER_MARKS = 16,  -- total marked trees allowed at once
    TREE_COUNT           = 57,
    TREE_MIN_DIST_TOWN   = 15,
    TREE_MIN_DIST_PORTAL = 12,
    TREE_CHOP_DURATION   = 3.75,

    -- Mounds (Phase 3 — placed but inert in Phase 1)
    MOUND_COUNT           = 8,
    MOUND_MIN_DIST_PORTAL = 10,

    -- Boat repair
    BOAT_REPAIR_COST     = 10,
    BOAT_REPAIR_DURATION = 120,
    BOAT_MAX_BUILDERS    = 3,

    -- Destructibles
    PORTAL_HEALTH              = 20,  -- hits to kill a portal
    BARRICADE_HEALTH           = 10,  -- hits to destroy a built barricade
    PORTAL_INTERACT_RADIUS     = 12,  -- studs player must be within to attack a portal
    STRUCTURE_INTERACT_RADIUS  = 12,  -- studs player must be within to contribute a build tick

    -- Greed
    GREED_SPAWN_INTERVAL = 1,
    GREED_SPEED          = 16,
    GREED_RETREAT_SPEED  = 24,
    GREED_SCAN_RADIUS    = 35,
    GREED_STEAL_RANGE    = 3,
}
