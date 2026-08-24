# BedWars agent guide

This document is the working map for agents changing the BedWars integration. It explains the
coordinate system, runtime seams, movement and request limits, anti-cheat observations, and the
boundaries of what can be verified from this repository.

The code is a client-side adapter. It is not the BedWars server, and it is not a complete
anti-cheat implementation. A value changed in the client can still be rejected, corrected, or
flagged by the server.

## Current state

As of 2026-08-24:

- `main` contains the merged compile and smoke-test work from PR #1.
- `6872274481` is the canonical BedWars system place ID, and
  `games/6872274481.lua` is the primary checked-in source file for it.
- `tests/check_luau.py` parses all Lua sources and runs a Roblox-shaped smoke test. It does not
  qualify live Roblox behavior or server validation.
- Recent maintenance has focused on guarded loading, module failure isolation, block traversal,
  movement helpers, request pacing, key publication, and Luau validation. See `merge.md` for the
  broader change log.

When a task says “BedWars code,” start with the checked-in adapter and the relevant wrapper. Do not
infer implementation behavior from a profile name alone.

## File map

| Path | Role |
| --- | --- |
| `games/6872274481.lua` | Primary BedWars adapter. Discovers controllers and remotes, tracks game state, registers modules, and provides block and movement helpers. |
| `games/8444591321.lua` | Alias wrapper. Sets `vape.Place` to `6872274481` and loads the primary adapter for that BedWars place variant. |
| `games/8560631822.lua` | Alias wrapper with the same primary-adapter mapping. |
| `games/123804558118054.lua` | Separate wrapper for place `5938036553`; do not assume it is the primary BedWars adapter. |
| `games/96342491571673.lua` | Separate wrapper for place `109983668079237`; do not assume it is the primary BedWars adapter. |
| `games/tarmac.lua` | Static block-name-to-asset metadata used by the Scaffold block-count display. It is not the authoritative block store or geometry definition. |
| `profiles/*6872274481*.txt` | Saved module configuration. Useful for discovering configured names and defaults, but not proof that a module is implemented in the checked-in source. |
| `merge.md` | Recent hardening and validation notes. |
| `tests/check_luau.py` | Official Luau parser download, digest verification, source parsing, and Roblox-shaped smoke harness. |

## Place routing

The filename of a game script is the place that Roblox initially selects, but the script may
change `vape.Place` before loading the actual adapter. For this system, always follow the route to
the canonical ID before deciding where a BedWars change belongs.

| Entry place ID | `vape.Place` / loaded adapter | Meaning |
| ---: | ---: | --- |
| `6872274481` | `6872274481` | Canonical BedWars source and system anchor. |
| `8444591321` | `6872274481` | BedWars variant wrapper; redirects to the canonical adapter. |
| `8560631822` | `6872274481` | BedWars variant wrapper; redirects to the canonical adapter. |
| `123804558118054` | `5938036553` | Separate adapter route; it does not redirect to the canonical BedWars source. |
| `96342491571673` | `109983668079237` | Separate adapter route; it does not redirect to the canonical BedWars source. |

The other wrapper families are outside this guide: `12011959048`, `14191889582`, and
`14662411059` route to Bridge Duel (`11630038968`), while `13246639586`, `8542259458`,
`8592115909`, and `8951451142` route to SkyWars (`8768229691`). Do not copy a fix into one of
those adapters just because it contains a similarly named module.

## Runtime and source boundaries

### Adapter boot

`games/6872274481.lua` has these important phases:

1. It refuses to run unless `shared.PistonwareAuthenticated` is true.
2. It establishes services, libraries, local-player state, inventory state, entity tracking, and
   the `bedwars` controller table.
3. It discovers the game remotes from the live controller functions. Remote names are not a
   stable hand-written API in this repository; changes to the game can move the constants used
   by the discovery code.
4. It registers each feature through the local `run(function() ... end)` wrapper. A failed module
   should report its own error and not prevent later modules from registering.
5. It publishes a shared integration surface at `shared.bedwars`.

### Shared integration surface

`shared.bedwars` is the adapter's shared integration surface. It exposes services, `vape`,
`entitylib`, the live `bedwars` controller table, discovered `remotes`, `store`, `RunLoops`, and
helpers including:

- `getItem`, `getWool`, `getNearGround`
- `getBlocksInPoints`, `getPlacedBlock`, `roundPos`
- `switchItem`, `updateVelocity`, `_baseGetSpeed`
- `collection`, `isnetworkowner`, `namecallGuard`, `fpsHooks`

Add shared helpers here when checked-in consumers need the same behavior. Do not add a second
global `__namecall` hook. The adapter owns the one hook and exposes `shared.bedwars.namecallGuard`
for exact instance-and-method watches.

The guard contract is:

- `true` means swallow the call.
- `nil` or `false` means forward it unchanged.
- a table means replacement arguments in `table.pack` shape.
- another truthy non-table value means swallow the call.

The hook chains to the first original metamethod and is designed to remain one layer deep across
re-injection. A new module should register a narrow watch instead of wrapping every namecall.

## Source evaluation and function map

`games/6872274481.lua` is a single large adapter, not a thin module list. Its source is easiest to
understand in five layers:

1. Bootstrap and shared helpers (`1..2624`): services, inventory/entity state, controller
   discovery, the namecall guard, block helpers, and the `run` isolation boundary.
2. Gameplay modules (`2627..7333`): Combat, Blatant, World, Render, Utility, and Inventory
   modules declared with `CreateModule`.
3. Legit/UI modules (`7336..8610`): local presentation, sound, viewmodel, interface, and
   end-of-round effects.
4. Device and nametag utilities (`8613..8733`): local input/device spoofing and nametag hiding.
5. Shared publication (`8735..8954`): the exported integration surface and key publication.

The important named functions are the contracts agents should look for before adding another
helper:

| Source area | Functions | Responsibility |
| --- | --- | --- |
| Inventory and item selection | `getBestArmor`, `getBow`, `getItem`, `getSword`, `getTool`, `getBestBreakTool`, `getWool`, `getStrength` | Resolve the current inventory, best tool, weapon, armor, and material. |
| World/grid | `getPlacedBlock`, `getBlocksInPoints`, `getNearGround`, `roundPos` | Convert between world studs and the three-stud block grid and query the block store. |
| Movement | `_baseGetSpeed`, `getSpeed`, `modifyVelocity`, `updateVelocity`, `switchItem` | Compute effective game speed, apply movement state, and switch the active item. |
| Entity tracking | `entitylib.start`, `entitylib.addPlayer`, `entitylib.addEntity`, `entitylib.getUpdateConnections`, `entitylib.targetCheck` | Maintain local player/entity records and target predicates used by modules. |
| Hook and scheduling | `namecallGuard.watch`, `namecallGuard.block`, `namecallGuard.unwatch`, `RunLoops:BindToRenderStep`, `RunLoops:BindToStepped`, `RunLoops:BindToHeartbeat` | Install narrow remote watches and manage named per-frame loops. |
| Remote/controller discovery | `entryMatches`, `safeGetProto`, `resolveSoundManager`, `dumpRemote`, `Client.Get` | Find live controller methods/remotes and wrap `AttackEntity` without replacing the whole remote layer. |
| Block interaction | `getBlockHealth`, `getBlockHits`, `calculatePath`, `boundary`, `frontOf`, `bedwars.placeBlock`, `bedwars.breakBlock` | Check breakability, choose a reachable dig position, place blocks, and send block damage. |
| State and queues | `flushInventoryEvents`, `updateStore`, `isEveryoneDead`, `joinQueue`, `sendChat` | Keep inventory state current and drive local queue/chat utilities. |
| Staff response | `getRole`, `staffFunction`, `checkFriends`, `matchRunningFor`, `isSpectating`, `checkJoin`, `playerAdded` | Detect configured staff/operator conditions and apply the selected local response. |
| World automation | `fixPosition`, `switchHotbarItem`, `getBedNear`, `getBlocks`, `getPyramid`, `lootChest`, `getPlacedBlocksInPoints` | Support AutoSuffocate, AutoTool, BedProtector, ChestSteal, Schematica, and related modules. |
| Shop/inventory | `getShopNPC`, `canBuy`, `buyItem`, `buyUpgrade`, `buyTool`, `consumeCheck` | Resolve shop purchases and local consumption checks. |
| UI and integration boundary | `CreateWindow`, `HotbarList`, `removeGameNametags`, `restoreGameNametags`, `modifyconstant`, `choosesong`, `updateVolumes`, `sendInputType`, `resolveInputType`, `downloadBedwars`, `republishKey` | Build local UI, patch reversible presentation hooks, resolve device state, and publish integration state. |

The most important control-flow fact is the `run` function at the top of the adapter: each module
registration is protected by `pcall`, so a failure should be isolated to that module. The
`collection` helper owns tag connections and cleanup, `entitylib` owns player/NPC tracking, and
`RunLoops` owns named render/stepped/heartbeat callbacks. Preserve those ownership boundaries
when adding code; a module should not create an untracked global loop or connection.

### Runtime remote key inventory

The adapter resolves these symbolic remote keys from live Knit controller functions using
`safeGetProto` and `dumpRemote` rather than hardcoding their instance names:

`AfkStatus`, `AttackEntity`, `BeePickup`, `CannonAim`, `CannonLaunch`, `ConsumeBattery`,
`ConsumeItem`, `ConsumeSoul`, `DepositPinata`, `DragonBreath`, `DragonEndFly`, `DragonFly`,
`DropItem`, `EquipItem`, `FireProjectile`, `GroundHit`, `GuitarHeal`, `HannahKill`,
`HarvestCrop`, `KaliyahPunch`, `MageSelect`, `MinerDig`, `PickupItem`, `PickupMetal`,
`ReportPlayer`, `ResetCharacter`, `SpawnRaven`, `SummonerClawAttack`, and `WarlockTarget`.

These are adapter-side symbolic keys, not a stable server API. Other request names used through
controllers include `DamageBlock`, `SetObservedChest`, `ChestGetItem`, `BedwarsPurchaseItem`,
`RequestPurchaseTeamUpgrade`, and `SendUserInputType`. Re-resolve them after a game update instead
of assuming the instance names or function constants are unchanged.

The adapter has no checked-in `commands/` directory or separate text-command router. In this
checkout, “commands” means the module/toggle surface and its options, plus the wrapper place
routes. The complete checked-in `CreateModule` inventory is below. Do not treat a name found only
in a saved profile as proof of an implementation here.

### Complete checked-in module inventory

These are the 59 modules declared by `games/6872274481.lua`, grouped by the source category
passed to `CreateModule`:

| Source category | Modules |
| --- | --- |
| Combat | `AimAssist`, `NoClickDelay`, `Reach`, `Sprint`, `TriggerBot`, `Velocity` |
| Blatant | `AntiFall`, `FastBreak`, `Fly`, `HitBoxes`, `KeepSprint`, `NoSlowdown`, `Speed` |
| World | `SafeWalk`, `Anti-AFK`, `AutoSuffocate`, `AutoTool`, `BedProtector`, `ChestSteal`, `Schematica` |
| Render | `BedESP`, `Health`, `KitESP`, `NameTags`, `StorageESP` |
| Utility | `AutoBalloon`, `AutoKit`, `AutoPlay`, `AutoToxic`, `MissileTP`, `PickupRange`, `RavenTP`, `StaffDetector`, `TrapDisabler`, `DeviceSpoofer`, `HideNametag` |
| Inventory | `AutoVoidDrop`, `ArmorSwitch`, `AutoBuy`, `AutoConsume`, `AutoHotbar`, `FastConsume`, `FastDrop` |
| Legit | `Bed Break Effect`, `Clean Kit`, `Crosshair`, `Damage Indicator`, `FOV`, `FPS Boost`, `Hit Color`, `HitFix`, `Interface`, `Kill Effect`, `Reach Display`, `Song Beats`, `SoundChanger`, `UI Cleanup`, `Viewmodel`, `WinEffect` |

Profile entries that do not have a corresponding checked-in implementation belong in the
“external/unknown” bucket until an authorized implementation is available for review.

## Units and block coordinates

### Studs are the world unit

Roblox positions, distances, velocities, ray lengths, and slider values in this code are in
studs unless a setting explicitly says otherwise. A speed value of `20` means approximately
`20 studs/second`, not 20 BedWars blocks per second.

### BedWars uses a three-stud block grid

The checked-in adapter consistently treats one standard BedWars grid block as `3 x 3 x 3` studs:

```text
1 block = 3 studs on X
1 block = 3 studs on Y
1 block = 3 studs on Z
```

This is a repository convention grounded in the code, not a claim that every decorative Roblox
part has that size. The evidence includes:

- `getBlocksInPoints` reads integer block cells and returns `cell * 3` world positions.
- `roundPos` snaps each world component with `round(component / 3) * 3`.
- block face offsets are `Vector3.FromNormalId(face) * 3`.
- multi-cell handlers use `block.Position / 3` to return grid cells.
- placement passes grid coordinates to `BlockController:getBlockPosition`.

### Conversion rules

Use these conversions when moving between the block store and world space:

```text
world studs = grid cells * 3
grid cells  = world studs / 3
```

Examples:

| World distance | Grid distance |
| ---: | ---: |
| 3 studs | 1 block |
| 6 studs | 2 blocks |
| 9 studs | 3 blocks |
| 14.4 studs | 4.8 blocks |
| 20 studs | 6.666... blocks |
| 30 studs | 10 blocks |
| 23 studs/second | 7.666... blocks/second |

Keep the coordinate types separate:

- A `Vector3` passed to `BlockController:getBlockPosition` is world space in studs.
- The returned block position is an integer grid-cell coordinate.
- A grid cell converted with `cell * 3` is a world-space block-center/placement coordinate.
- A player root or head position is arbitrary world space and usually is not a multiple of 3.

Prefer the game's `BlockController:getBlockPosition(worldPosition)` for authoritative cell
mapping. Use `roundPos` only when the adapter explicitly wants a snapped world position. Do not
replace the controller mapping with an ad hoc `floor` or `round` without checking the game's
offset and handler behavior.

### Block traversal rules

The block store is the source used by the adapter for block-aware decisions. Important helpers
in `games/6872274481.lua` are:

- `getPlacedBlock(worldPosition)`: maps world space to a block cell and reads the block store.
- `getBlocksInPoints(startCell, endCell)`: scans inclusive integer cell ranges and returns world
  positions by multiplying cells by 3.
- `getNearGround(range)`: searches a cubic region measured in blocks, then returns a world-space
  position one block above a nearby solid cell.
- `bedwars.placeBlock(worldPosition, item)`: resolves the world position to a block cell and
  routes through the game's `BlockPlacer`.
- `bedwars.breakBlock(block, ...)`: chooses a reachable dig spot, walks the cell line from the
  player's head, respects cover and `NoBreak`, and sends the game's `DamageBlock` request.

The break path uses a 30-stud guard, which is 10 standard blocks. It also refuses when the local
player has `DenyBlockBreak` or is not alive. These are adapter-side guards, not proof of the
server's complete break-distance policy.

## Movement and the speed system

### The game-speed calculation

`_baseGetSpeed` derives the current local game speed from
`bedwars.SprintController:getMovementStatusModifier():getModifiers()`:

1. It finds the strongest `constantSpeedMultiplier` and applies the adapter's reduction
   `0.06 * round(multiplier)` when that path wins.
2. It adds only positive `moveSpeedMultiplier - 1` contributions.
3. When additive modifiers are active, it adds the game-specific `0.16 + 0.02 * round(multi)`
   adjustment.
4. It returns `20 * (multi + 1)` in studs per second.

`getSpeed` delegates to `shared.bedwars.getSpeed` when that function is available; otherwise it
uses `_baseGetSpeed`. Agents must preserve this delegation because it is part of the adapter's
integration contract.

### The checked-in Speed module

The BedWars adapter's `Speed` module is not a hard speed limit. Its slider is `1..23` studs per
second, default `23`. On `RunService.PreSimulation`, while the player is alive, locally owns the
root part, is not climbing, and no conflicting movement module is active, it:

1. Reads the current game speed from `getSpeed()`.
2. Computes only the excess movement: `max(targetSpeed - currentSpeed, 0) * dt`.
3. Uses `Humanoid.MoveDirection` or the active AntiFall direction.
4. Optionally raycasts with the root collision group and shortens movement at a wall.
5. Adds the excess to `RootPart.CFrame`.
6. Sets horizontal `AssemblyLinearVelocity` to the current game speed and preserves vertical
   velocity.

Consequences that agents must preserve:

- The slider is a target speed, not an amount added to the game's speed.
- A target below the current game speed does not slow the player.
- `23` is a UI ceiling for this module, not a server-approved or anti-cheat-safe ceiling.
- Movement is frame-time-scaled. Do not replace the `dt` multiplication with a fixed per-frame
  displacement.
- The module uses `PreSimulation`, not a loose `while` loop, to keep movement synchronized with
  physics.
- The code uses local CFrame and velocity writes. The server can still correct or reject them.

When enabled, the module also marks `frictionTable.Speed`, updates body-part physical properties
through `updateVelocity`, attempts to switch the WindWalker constant, and holds
`StatefulEntityKnockbackController.lastImpulseTime` at `math.huge`. Those are implementation
details of the client movement path, not evidence that server-side movement checks are disabled.

### Related movement modules

- `Fly` shares the target horizontal-speed calculation, adds a `1..150` studs vertical control,
  uses `PreSimulation`, and raycasts walls. Balloon and match-state conditions affect whether
  its flight behavior is allowed locally.
- `AntiFall` finds the lowest usable block row, creates a large invisible safety part, and either
  eases the player toward a safe location, collides with the safety plane, or applies upward
  velocity. It uses the same three-stud grid conversion.
- `SafeWalk` intercepts the local `PlayerModule` movement function and clamps movement when a
  downward ray and blockcast show an edge.
- `NoSlowdown` removes or raises local movement modifiers below 1. It does not prove that the
  server will accept the resulting movement.
- `KeepSprint` changes the local sprint-controller constant so a sprint state is retained.

## Anti-cheat and server-validation model

### What is actually observable here

The adapter interacts with server-facing controllers and remotes. The server remains the
authority for attacks, block damage, placement, inventory, pickups, chest observation, and
movement correction. The checked-in code contains client-side hooks, request pacing, and local
guards. It does not contain the server's anti-cheat source or a complete list of detection rules.

Observed validation-related values and behavior:

- The normal sword character-distance constant is restored to `14.4` studs, or `4.8` blocks,
  when the local `Reach` module is disabled.
- The `Reach` slider is `0..18` and writes `value + 2` into the local combat constant. The
  `AttackEntity` wrapper also records the requested reach and, when Reach or HitBoxes is enabled,
  rewrites the submitted self-position along the target direction using a `14.399`-stud baseline.
  This is client request manipulation, not a guarantee that the server accepts the attack.
- `TriggerBot` uses the live sword attack range and raycasts/target checks before swinging. Its
  configured CPS range is `1..9` with a default of `7..7` in this adapter.
- `bedwars.breakBlock` refuses local requests beyond 30 studs, or 10 blocks, and sends the
  game's `DamageBlock` request with a grid-cell `blockPosition`, hit position, and top normal.
- Pickup and chest code explicitly documents a server request budget of 299 calls per minute.
  This number is a source comment for the observed endpoints, not a universal BedWars anti-cheat
  constant. Treat it as a pacing constraint until live behavior or authoritative source proves
  otherwise.
- `PickupRange` uses a weak-key per-drop next-allowed timestamp. New drops are requested once
  immediately; retries wait for the configured delay, default 1 second.
- `ChestSteal` observes and clears a chest around its loot pass and has a per-chest delay,
  default 0.5 seconds. Each pass costs two observation calls before item requests are counted.
- `DamageBlock` can return `cancelled`; the adapter records a failure cooldown and updates local
  health-bar/effect state only after a response.

### What is not verified from this checkout

The following must not be presented as confirmed anti-cheat behavior without inspecting current,
authorized source or observing a controlled live session:

- the server's actual movement threshold, tick window, or rubber-band policy;
- whether a particular CFrame/velocity pattern is detected, ignored, or corrected;
- the complete implementation of modules visible only in saved profiles or unavailable from this
  checkout;
- whether a current game update changed the 14.4-stud combat baseline or the 299/min request
  budget;
- whether a local constant rewrite changes a server-side validation path.

Saved profiles can contain names and options that are not implementation evidence. If an agent
needs to change a system that is unavailable from this checkout, first locate its current
implementation or obtain a source-grounded live fixture. Do not reverse-engineer a server rule
from a slider label.

### Staff detection is different from anti-cheat

The checked-in `StaffDetector` is an operator-presence response module, not the game's anti-cheat.
It checks configured user IDs, group role `5774246` at rank 100 or higher, configured clan tags,
and a guarded “impossible join” condition. Its responses can notify, uninject, requeue, switch
profile, or disable risky modules. Its timing rules include a 45-second join grace period and a
10-second team-settle wait. Keep those terms separate from movement or combat validation.

## Remote and request safety

The single `namecallGuard` is a performance and compatibility seam. It is also where request
watching or rewriting belongs when a feature truly needs it. Preserve these rules:

- watch exact remote instances and exact method names;
- forward untouched calls through the first original namecall whenever possible;
- do not install nested hooks on reinjection;
- use replacement arguments only when the handler owns the contract and has a table-pack shape;
- unregister watches on module disable;
- avoid broad logging in the namecall hot path.

For new loops that call server endpoints:

- identify the endpoint's budget and response semantics first;
- pace retries per object, not merely per frame;
- make the first observation useful without creating a steady-state flood;
- stop and clear timers when the module disables;
- treat a failed or rate-limited response as expected state, not as proof that the server is down.

## Agent change rules

1. Read the current `games/6872274481.lua` and the relevant wrapper before editing a BedWars
   feature.
2. Keep world studs and grid cells explicit in variable names and comments. Prefer names such as
   `worldPos`, `cellPos`, `studDistance`, and `blockDistance`.
3. Use `BlockController:getBlockPosition` for store access and multiply or divide by 3 only at a
   documented world/grid boundary.
4. Preserve `getSpeed` delegation and the distinction between current game speed and the Speed
   module's target speed.
5. Treat local movement, combat constants, and remote rewrites as client behavior. Do not write
   documentation claiming that they bypass or disable server anti-cheat.
6. Keep behavior unavailable from this checkout marked as unknown when the implementation is not
   checked in.
7. Make module patches reversible: restore monkey-patched functions, disconnect connections, and
   clear per-object pacing tables on disable.
8. Keep the one-hook `namecallGuard` architecture and the `run` error-isolation boundary intact.
9. Avoid changing `games/tarmac.lua` just to fix geometry. It is asset metadata; block geometry
   belongs to the game's block engine and the adapter's conversion boundary.
10. Before committing or pushing, run:

    ```bash
    python3 tests/check_luau.py
    ```

## Useful verification targets

The existing smoke test is intentionally offline and Roblox-shaped. It verifies that guarded
entrypoints and shared libraries parse and load with representative services, vectors, signals,
and data. It does not qualify live BedWars behavior.

For future test additions, prioritize pure or fixture-backed checks for:

- studs-to-cell and cell-to-studs conversion;
- `roundPos` and block-face offsets;
- the `_baseGetSpeed` modifier formula;
- the `Speed` module's excess-distance calculation with varying `dt`;
- block-line traversal and cover selection;
- per-drop and per-chest request pacing;
- cleanup and restoration after each module disables.

Those tests give agents durable contracts without pretending that a local harness can certify a
live anti-cheat interaction.
