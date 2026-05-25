# StrandedCrowns — Claude Memory

## Project
Roblox co-op kingdom builder (Kingdom: Two Crowns style). Synced via Rojo.
GitHub: Sly4Play/StrandedCrowns, branch: main
Working dir: /home/daddy-butler/StrandedCrowns
GDD: /home/daddy-butler/Desktop/Roblox_Games/StrandedCrowns_GDD_v1.docx

## Architecture
- Bootstrap.server.luau — server entry, all RemoteFunction/Event handlers
- Services/TimeService — phase clock (Dawn/Day/Dusk/Night), fires onDawn/onDusk callbacks
- Services/CoinService — purses, ground coins, proximity pickup
- Services/WorldService — island gen, trees, camps, boat, structures, food, spawn
- Services/NpcService — NPC state machine (Homeless → Jobless → Builder)
- Services/MayorService — bank, mayor NPC, fire lighting sequence
- Services/GreedService — greed mechanic
- Controllers/HudController — coin counter UI + Lighting (sun/moon clock cycle)
- Controllers/InputController — F key (tap=drop, hold=stream-buy), interactive registry

## Key GameConfig Constants (last known)
- ISLAND_RADIUS = 160
- TOWN_RADIUS = 44
- PLAYER_PURSE_MAX = 25
- TREE_MARK_COST = 1, HAMMER_COST = 3
- TREE_CHOP_REWARD = 2
- TREE_COUNT = 30
- FIREPIT_UPGRADE_COSTS = {8, 10, 12, 14, 16}  (levels 3-4 locked until Island 2)
- BOAT_REPAIR_COST = 10, BOAT_REPAIR_DURATION = 120, BOAT_MAX_BUILDERS = 3
- BOAT_MIN_DIST_CAMP = 40
- TOWER_MAX_BUILDERS = 2, BARRICADE_MAX_BUILDERS = 2
- STRUCTURE_BUILD_DURATION = 5
- NPC_RUN_SPEED = 14, NPC_WANDER_SPEED = 7, VAGRANT_WALK_SPEED = 2.5
- COIN_PICKUP_RADIUS = 2, WORKER_COIN_PICKUP_DELAY = 2
- NPC_DUMP_RADIUS = 8

## NPC State Machine
Homeless (InCamp/Wandering) → hired by coin/food → Jobless (runs to town)
→ walks to nearest shop rack with available tool → becomes profession
→ Builder: hammer → Working
→ Hunter: bow → Hunting/Collecting
Dusk: all non-Homeless → ReturningToWalls → AtWalls
Dawn: Builders→Working, new Homeless spawn at camps

## GDD Rules — Critical
- ONLY newly hired jobless grab tools. Existing workers NEVER switch professions.
- Closest available shop rack (with tools) determines new jobless's profession.
- Escort team slots fill first, then hunter, then other professions.
- Workers fight back outside walls: can handle 1-2 Greed before overwhelmed.
- Ranger true invisibility: 0 crown + 0 coins = portals ignore them entirely.
- Portal detection radius GROWS with each coin deposited (bribing = feeding portal).

## Town Levels → Unlocks
- Level 0→1: first Mayor payment → Mayor tent spawns
- Level 1→2: Mayor cabin near firepit
- Level 2: +Farmer shop unlocks; +townhall/bank
- Level 3: +Pikeman shop (pike banner from Town Center); +larger townhall/bank
- Level 4: +Knight shop (shield 6c + sword, Oak Mill required); +Blacksmith

## Professions
- Builder: hammer, chops small trees (medium unlocks Island 2 Timber Mill), builds/repairs
- Hunter: bow, shoots animals (ranged), walks to collect coins, dusk→town, converts to tower Archer permanently on entering tower
- Tower Archer: stationary in tower, shoots animals+Greed, only collects coins when in tower, displaced during upgrade→becomes Hunter, tower rebuilt→nearest hunters fill slots
- Farmer: farming tool, works farm spring building, 8 coins/day from day 2, max 20 purse, cannot fight, sleeps in Farmer Hut (Town Level 2+)
- Pikeman: pike banner (Town Level 3), max 4/island, defends gates at night
- Knight: shield(6c)+sword (Town Level 4, Oak Mill), max 4/island, Blacksmith upgrade 12c
- Baker: auto-spawns after 5 farmers fill one farm; sells burgers 4c; vagrants wander to baker

## Movement Tiers
- Homeless wander: VAGRANT_WALK_SPEED (2.5)
- Jobless to town: NPC_RUN_SPEED (14)
- Worker purposeful (hunting, chopping, building): NPC_RUN_SPEED (14)
- Worker collecting coins / dusk return: NPC_WANDER_SPEED (7)
- Any non-combat NPC when Greed nearby: NPC_RUN_SPEED (14) flee

## Animal System (GDD §12)
- Constant population per island — kill one → new spawns elsewhere after short delay
- Spawn on cleared GRASS areas (chopped trees create spawn zones)
- Moose: deep forest, high risk near portals, high reward coins
- When killed: drop coins on ground
- Hunter: shoots from range, walks to collect, dumps to player
- Tower archer: shoots in range, coins drop to ground, only collects when in tower

## Farming System (GDD §6.5)
- Farming springs: RNG placed per island, farm buildings ONLY on these spots
- Up to 5 farmers per farm building
- 8 coins/day per farmer starting day 2
- Baker appears after first full farm (5 farmers)

## Island Crossing / Bell
- Bell placed at boat crash/repair site
- Only ringable after boat fully repaired (BrokenBoat Level attr = 1)
- Island 1→2: builders + hunters rally and cross
- Island 3+: larger groups as town level and escorts scale
- Current island stays, just loses those NPCs
- Boat capacity: 10→20→40→80→160 passengers per island
- After lighthouse built: lighthouse front = spawn + departure (boat replaced)
- WorldService.setSpawnAtTown() ready to call when lighthouse repaired

## Lighthouse / Big Breeder
- Flips each island: Island 1 = North, Island 2 = South, Island 3 = North, etc.
- Big Breeder: stationary, constantly spawns Greed toward town while alive
- Guardian behavior: spawns Greed at dusk/night OR when provoked (like portal)
- Death: lighthouse lights, spawn moves to lighthouse front
- Must defeat Breeder before lighthouse can be repaired

## Critical Patterns

### assignTool (NpcService) — generation counter
Uses `_gen` field on npc data. Each call bumps gen; single combined loop checks gen each tick.
Prevents duplicate loops from re-calls.

### Tree sizes
- treeSize 1 (small): trunk 1.5×7×1.5 at Y=3.5, leaves 5×6×5 at Y=9.5  ← choppable/markable
- treeSize 2 (medium): trunk 2.5×12×2.5 at Y=6, leaves 8×8×8 at Y=15    ← decorative (until Timber Mill)
- treeSize 3 (large): trunk 3.5×18×3.5 at Y=9, leaves 11×10×11 at Y=22.5 ← decorative
- TreeSize attribute set on Model instance for client-side filtering

### Coin ground position
makeCoinPart always uses Y=0.3 so coins land on ground.

### F key interaction
- Tap < 0.3s → DropCoins:FireServer(1)
- Hold near interactive → stream-buy (coin animation flies one at a time)
- Hold away → no action on release

### Boat (current)
- Positioned at ISLAND_RADIUS (160), angle pi/6
- Hull 12×7.5×45 (75% of previous); fully multi-part
- BrokenBoat Part has: Level=0, Marked, BuildProgress, BuildRequired, MaxBuilders, CurrentBuilders attrs
- SpawnLocation placed 14 studs inshore from boat position (island arrival point)
- WorldService._spawn tracked; setSpawnAtTown() moves it to town center on lighthouse repair

### SpawnLocation
Invisible SpawnLocation "IslandSpawn" at boat shore position, spawned in buildIsland().
Neutral=true, CanCollide=true, Transparency=1, Y=1.

### Lighting (HudController)
- ClockTime driven each Heartbeat from CLOCK_START/CLOCK_END per phase
- Night wraps: 19→5 through midnight
- Brightness: Night=0.4, Dusk=1.5→0.4, Dawn=1.3→1.5, Day=1.5
- AMB_DAWN = RGB(100,105,115), AMB_NIGHT = RGB(25,25,55)

### HammerShop bubble
MaxDistance=20 (shop is 16 studs from town center at Z+16).

### Tool Rack system (Phase 2 — to build)
- Shops hold max 4 tools on a rack (visible parts)
- Jobless walks to nearest shop rack with tools available
- Player restocks via F-hold at shop
- NOT scattered on ground anymore (ground-scatter was Phase 1 only)

## Completed Batches
- Batch 1: collectNearbyCoins delay fix, taller trees, BillboardGui AlwaysOnTop, unified builder job priority, multi-builder progress attrs, firepit multi-level upgrade, broken boat spawn+repair
- Batch 2: tree floating fix, 3 tree sizes, fetchTool restart on failure, larger boat multi-part, sun/moon lighting replacing UI
- Batch 3: assignTool gen-counter rewrite, tree sizes increased + filtering, boat at ISLAND_RADIUS doubled, SpawnLocation at town center, coin Y=0.3, F tap threshold, tree bubble small-only, HammerShop MaxDist=20, Dawn/Night brightness fix
- Batch 4 (playtesting): boat 25% smaller, dawn brighter (1.3→1.5), coin transfer visible (spawn at feet), trees no overlap (size-based footprint), SpawnLocation destroys existing + Neutral=true
- Batch 5 (design): spawn at boat shoreside (14 studs inshore), TREE_COUNT 25→30, NPC_DUMP_RADIUS 4→8, camps forbidden near boat (BOAT_MIN_DIST_CAMP=40), WorldService.setSpawnAtTown() added

## Phase 2 Implementation Queue (in dependency order)
1. Tool Rack system — shops hold 4 tools on rack, jobless walks to rack, player restocks
2. BowShop — RNG near gate entrance, same placement logic as HammerShop
3. Animal system (AnimalService) — constant pop, spawn on grass, coins on death, respawn elsewhere
4. Hunter profession — bow from rack, ranged shoot, collect coins, flee Greed, dusk return, tower conversion
5. Flee behavior — universal: builders/hunters/farmers run from Greed when nearby
6. Farming Springs — RNG placed in buildIsland(), farm-only build sites
7. Farm + Farmer profession — 8c/day from day 2, up to 5 per farm, Farmer Hut at Town Level 2
8. Baker — auto-spawns after first full farm, burgers 4c, vagrants wander to baker
9. Town Level system — drives mayor building upgrades + profession shop unlocks
10. Days banner — HUD label above each player, updates at dawn
11. Bell at boat — ringable only after repair, rallies builders+hunters
12. Lighthouse + Big Breeder — stationary spawner, death lights lighthouse, spawn moves
