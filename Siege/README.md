# Siege: Teardown multiplayer game mode

Attackers break through the defences and capture the objectives. Defenders fortify and hold out until the timer runs out. It works on any map. The host places objectives, spawn points and wall sections in-game, and layouts are saved per map.

## Install and test

1. Keep this `Siege` folder in `Documents/Teardown/mods/Siege`.
2. Start Teardown, enable the mod, host a multiplayer session on a map, and pick **Siege** as the game mode.
3. To play with friends, **publish it to the Workshop**, and publish again after every change. Multiplayer only uses published, unmodified mods, and joiners download them automatically. If files differ, a client gets "Mod files differ from host".

## Controls

| Key | Action |
|---|---|
| **O** | Siege menu (team, spawn, host tools) |
| **B** | Build mode: press again for the next piece, and once more after the last piece to exit |
| **LMB / RMB** in build mode | Place / rotate |
| **K** (hold) | Scoreboard |

Keys are set at the top of `siege_config.lua`.

## Setting up a map (host)

Pick a team and spawn, then press **O**. The host panel has six tabs:

- **Layout:** walk to a spot, then add objectives, attacker and defender spawns, and wall sections. Markers go at your feet, facing where you're looking.
- **Markers:** rename any marker and set each objective's points.
- **Saves:** five named layout slots per map. The current layout also saves itself.
- **Weapons:** turn each tool on or off, including explosives and tools from other mods, and choose which cannon balls are allowed. By default, explosives and non-cannon mod tools are off, and the only ball on is Traditional.
- **Settings:** round rules, building and team balance. Numbers are sliders. The far-left position on some sliders means Off, All or Unlimited.
- **Match:** **START MATCH**, or during a match, end the round or go back to setup.

Starting a match reloads the map, so damage and test pieces from setup are removed.

### Map editor tags (optional)

Location nodes in the map are used when no saved layout exists:

| Tag | Meaning |
|---|---|
| `siegeobjective` or `siegeobjective=3` | Objective, optionally with points |
| `siegespawn=attack` / `siegespawn=defend` | Spawn for that role (facing = node rotation) |
| `teamspawn=1` / `teamspawn=2` | Fallback: 1 = attackers, 2 = defenders |
| `siegewall=12x8x4` or `siegewall=gate` | Wall section box in metres, bottom-centre at the node |
| `siegename=South_camp` | Optional display name for any of the above. Underscores become spaces. |

## How a match plays

- **Joining:** read the briefing, pick a team, then pick a spawn. Late joiners get the same steps.
- **Teams:** attackers can never outnumber defenders. Team balance sets how far ahead defenders can get. If swapping sides would break the rule, players are moved at the start of the round. The first attacker can still join an empty server, so solo testing works.
- **Preparation:** both teams can move and build. Attackers have no weapons and can't be hurt. When the siege starts they return to their spawn, unless **Attackers at siege start** is set to Stay put.
- **Capturing:** an attacker in a zone with no defender inside fills its bar. Extra attackers speed it up, to at most 2x. A defender inside pauses it, and an empty zone slowly drains it.
- **Floor destruction:** an objective also counts as captured once enough of the floor under it is gone (50% by default, or off).
- **Ending a round:**
  - attackers reach **Points to win round** (attackers win),
  - the timer runs out (defenders win), or
  - reinforcements run out and every attacker is dead (defenders win).
- **Scoring:** each objective's points go to the attackers if captured, otherwise to the defenders. Give a harder objective more points to balance it. The match goes to the team with more points.
- **Between rounds:** the map reloads, so damage and fortifications never carry over. Teams, spawn choices, scores, kills and deaths are kept.

## Fortifications

| Piece | Look | Cost |
|---|---|---|
| Stone rampart | Light stone | 3 |
| Low stone cover | Dark stone | 1 |
| Brick wall | Aged brick, larger | 5 |
| Timber barricade | Wood planks | 2 |
| Iron bulwark | Unbreakable heavy metal | 8 |

- Every piece is 1.6 m thick. The cannon's Breaker round tunnels 1.2 m through anything, so one shot won't pass through, but a second in the same hole can.
- **Placement rules:** Anarchy (default) lets you place anywhere within 15 m, even in mid-air. Standard limits you to 6 m and blocks spots near objectives, spawns and players.
- The limit is 150 pieces per round, for performance.

## THE CANNON and ball types

Players switch balls in-game with **R**. The original mod has no way to restrict that, so **THE CANNON (Siege)** is a patched copy: while Siege is running, it skips any ball the host turned off. Outside Siege it behaves as normal.

- **Weapons > Cannon balls** has a power slider and separate on/off switches for cannons and trebuchets for each ball: 25% to 500%, or 1% to 500% for the Traditional ball, whose slider gives its left half to 1-100%. Explosive balls get a bigger or smaller blast, Breaker tunnels further or less far, and Traditional, Tether chain and Colossus get heavier or lighter, with no change to their launch speed. These need the patched copy.
- Above 133%, one Breaker shot can tunnel through a 1.6 m fortification.
- Enable only one of the two cannon mods. They use the same tool id.
- The patched copy has to be published for multiplayer. It's someone else's mod, so ask its author (seached) first.

## Files

- `siege.lua`: entry point and server rules (phases, capture, floors, weapons, round reset).
- `siege_ui.lua`: client HUD and menus.
- `siege_layout.lua`: objectives, spawns, walls, saving, map tags.
- `siege_build.lua`: fortification building.
- `siege_integrity.lua`: wall tracker.
- `siege_config.lua`: everything you're likely to tune.
- `mplib/`: Tuxedo Labs' official multiplayer library (MIT licence, unmodified).

## Check these first when testing

- **Round reset:** the map should reload between rounds and everyone should keep their team. If someone has to re-pick, their player name changed or didn't load in time.
- **Piece textures:** pieces use built-in brushes spawned at runtime. If a piece fails to appear or looks wrong, tell me which one.
- **Floor destruction:** floors made of unbreakable rock can't be destroyed, and an objective with almost no static floor under it skips this check.

## Working gates on your own map

Gates are static bodies moved by script. Tag the body `siegegate=<id> siegegatetype=drop|bridge siegegatetravel=<metres or degrees>`, and tag a shape `siegelever=<id>`. Build a drop gate raised. Build a bridge lowered, with its body origin on the hinge line and its deck along local +z. Add `siegegatebody=<deck length>` to draw a bridge's chains, and `siegegatestart=closed` for a gate that starts shut. Defenders use the lever during a round. A gate that loses nearly half its voxels falls down for real.

## Bow and sword

Everyone starts with the bow instead of guns. Hold fire to draw and let go to shoot. A longer draw flies further and hits harder, and a head hit does double damage. Plain arrows are unlimited. R switches to fire arrows, which set wood alight, and the host sets how many each player gets per round in Settings. The sword swings with left click and chops into wood. The host chooses with Weapons era in Settings: Medieval has the bow and sword with guns and modern tools off, and Guns turns the bow and sword off.

## Reload times

The host sets Fixed cannon reload and Trebuchet reload in Settings. Without Siege, fixed guns use `GUN_RELOAD_TIME` and `TREB_RELOAD_TIME` at the top of `scripts/fixed_guns.lua` in THE CANNON (Siege). The hand cannon uses `RELOAD_TIME` at the top of its `main.lua`.

## Bots

The host sets Bot archers per side, Bot gun crews per side and Bot skill in Settings. Archers stand at posts the map marks with locations tagged `siegebotpost=attack` or `siegebotpost=defend`, and shoot at enemies they can see. Crews work fixed guns. Attacker crews aim at locations tagged `siegebottarget=attack`. Defender crews aim at attacking players, then attacker bots, then locations tagged `siegebottarget=defend`. Bots can be killed and come back after a while. They aren't players: they don't capture objectives or count toward winning a round. A player can take over any gun a bot is on.

## Ladders

Once the siege starts, an attacker presses L and a 13 m ladder appears in their hands. They walk slowly while carrying it, and it points where they look. Left click lets go and it leans for real. If it comes to rest between about 6 and 38 degrees from upright with something to lean on, it holds and can be climbed with W, gone down with S and let go with Space. Otherwise it falls and that ladder is lost. L puts it back and returns the ladder. Defenders can push one off from the top with the interact key, and shooting one brings it down. The host sets how many each attacker gets per round in Settings, or turns them off.

## Hoists on your own map

Tag a shape `siegelift=<name>` and a location `siegeliftto=<name>`. A defender who uses the shape rides straight to that location. Attackers can't use it. Names ending in `_top` say up to the top of the tower, and other names say down to the ground. The labels for `roof` and `hall` are in `siege_gates.lua`.

## Fixed guns on your own map

Fixed cannons and trebuchets run in THE CANNON (Siege). Tag static bodies `siegegun=<id> siegegunkind=cannon|treb` (the carriage, optional `siegegunyaw=<degrees>`) and `siegegunarm=<id>` (the barrel or arm), and the shape it stands on `siegegunbase=<id>`. Forward is the carriage's local -z. Optional tags on the carriage: `siegegunscale=<size>` and `siegegunside=defend`. During a Siege round each side can only man its own guns, once the siege has started.
