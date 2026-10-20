# Mount Ignis

A volcanic-eruption disaster for Roblox, made for the HiddenDevs **Design a Disaster** event.

A stratovolcano towers over the village of Emberfall. Each round it wakes up, erupts and
collapses into a pyroclastic flow. Lava really flows: it is a simulated fluid that follows
the terrain, pools in craters, pours around houses, sets timber alight and finally freezes
into black rock you can walk on. Lava bombs rain on marked targets, buildings burn and
crumble when their supports fail, and the climax can only be survived inside a proper building.

Everything is generated from code: terrain, village, lobby, UI and effects. No free models
are used.

---

## Opening it

**Option A: ready-made place.** Open `build/MountIgnis.rbxl` in Roblox Studio and press **Play**.

**Option B: Rojo (for editing).**

```sh
rojo serve           # then connect with the Rojo Studio plugin
rojo build -o build/MountIgnis.rbxl   # rebuild the place file
```

Testing tips:

- The intermission is 30 seconds. Type `!erupt` in chat to skip it (works in Studio or for the place owner).
- **Test → Clients and Servers** with 2+ players shows the replication: lava, bombs and the flow
  are identical on every client.
- `Config.Debug.Verbose = true` prints simulation timings.

---

## A round

| Phase | Time | What happens | How to survive |
|---|---|---|---|
| Intermission | 30 s | Players wait in the lobby; the village is rebuilt. A guide pops up on joining, and the last 5 seconds tick audibly | Read the guide, then press "Okay!" |
| **Rumbling** | 18 s | Tremors build, steam vents hiss, boulders break off the summit, bounce down the flanks and burst where they land | Keep off the slopes; a burst hurts badly but won't one-shot you |
| **Eruption** | 55 s | The crater explodes; lava floods through the breach toward the village; lava bombs fall on red warning rings; a fissure opens on a flank; ash darkens the sky | Dodge rings, stay out of molten lava, avoid burning houses. Burning? Only the lake puts it out |
| **Pyroclastic Flow** | 22 s | The eruption column collapses into a searing avalanche of ash aimed at the survivors | Get inside a house or the concrete bunker, behind a wall facing the volcano. Out in the open it is fatal. The HUD shows SHELTERED / EXPOSED |
| **Aftermath** | 15 s | Vents die down, flows crust over into walkable basalt | Glowing rock still burns |
| Results | 10 s | Survivors are listed | |

---

## How it works (scripting highlights)

### Lava flow simulation (`server/LavaSim.luau`, `server/LavaFlow.luau`)
- A 160 × 160 heightfield (4-stud cells) over the volcano. Each cell has ground, crust, molten depth and temperature.
- Lava is modelled as a **Bingham plastic**: it only moves when the surface step beats a yield height, so flows stop with thick lobed edges instead of thinning into a film.
- **Viscous flux scales with depth**, so a deep channel carries far more than a thin sheet. Cooler lava is less fluid with a higher yield.
- Stability: each edge moves at most 1/8 of its surface step (the monotonicity bound for an explicit 4-neighbour solver, which removes checkerboard flicker), with 3 sub-iterations per 10 Hz tick to keep throughput.
- Thin sheets cool faster than deep pools. Cold lava **freezes into crust that raises the ground**, so later flows pile on top of earlier ones.
- Ground comes from raycasts against terrain *and* buildings, so lava flows around houses. When a house collapses, the cells under it are re-sampled and lava pours into the gap.
- Lava touching timber sets it on fire.
- Touching molten lava hits you with a **short burst** (3 quick hits), slows you and **sets you on fire**. Stay in it and the burst repeats every 1.25 s.
- Every moment of contact fills the **heat meter**, a vertical gauge on the left of the screen: empty to **MAX in 4 s** of continuous contact. While it is up you are on fire and take a **poke every 0.5 s that grows with the meter** (2 damage when nearly empty, 6 at MAX).
- The meter **never cools down on its own**. Only the **lake** helps: the flames and pokes stop at once, queued lava hits are cancelled, and the meter drains to empty over **3 s**, then disappears. Bombs, burning buildings and the pyroclastic flow also set you alight at a lower level.

### Network streaming (`shared/LavaGrid.luau`)
- The server never replicates lava Parts. Changed cells are packed into a `buffer` (9 bytes per cell) and only sent when the change is visible (depth > 8 cm, or a temperature band change). Settled cells are always sent exactly.
- In the offline eruption test this averages about **5 KB/s**. Late joiners request one snapshot.

### Lava rendering (`client/LavaRenderer.luau`)
- Pooled slabs, **tilted to the local surface gradient** from neighbouring cells so the flow reads as a continuous sheet rather than a staircase.
- Heights ease toward the server value every frame, and all slabs move in a single `BulkMoveTo`.
- Molten slabs glow (Neon → CrackedLava as they cool) and are non-collidable. Crust turns to Basalt and becomes **collidable for the local character**, which is simulated on that client, so everyone can walk on cooled flows.

### Lava bombs (`server/LavaBombs.luau`, `shared/Ballistics.luau`, `client/BombRenderer.luau`)
- Server-authoritative. The server solves the launch velocity for a target (players are **led by their velocity**), traces the arc against the world to find the true impact, and sends only the arc.
- Clients animate the bomb from the same closed-form ballistics and the synced server clock, so what you see is exactly what hits you. A warning ring tightens on the impact point.
- Impacts deal blast damage with line-of-sight falloff and client-side knockback. They also break structures, start fires, splash lava into the simulation, carve a terrain crater and scorch the ground voxel by voxel.

### Structural collapse (`server/Structures.luau`)
- Every house and tree gets a **support graph** built from touching parts. When a part breaks or burns through, a breadth-first search from grounded parts finds everything that lost support and drops it with a staggered delay, so buildings crumble.
- Glass shatters into shards. Tremors crack windows. Debris uses a collision group that cannot fling players.

### Rockfall (`server/Tremors.luau`, `client/RockfallEffects.luau`)
- Boulders shake loose from the summit (some on the flank facing the players) and tumble down under real physics.
- Every frame the server compares each boulder's velocity with the last frame's. A sudden change (a landing, a bounce, smashing into a wall) sets off a **blast with falloff**, and a direct hit on a player bursts too. Rolling smoothly does nothing, so a tumbling rock thumps down the slope.
- Damage scales with boulder size and impact strength and is capped well below a one-shot (38 at most), with knockback, so it scares people off the flanks rather than killing outright. Clients show a dust burst, rock chips and a camera thump.

### Fire (`server/Combustion.luau`)
- Heat-based spread between flammable materials, faster upward (fire climbs). Parts char as they burn, then run out of fuel and give way, which feeds the collapse system.

### Pyroclastic flow (`server/Pyroclastic.luau`, `shared/Shelter.luau`, `client/PyroclasticVisual.luau`)
- An expanding arc aimed at the survivors. Everything in the sector is **pre-sorted by distance**, so each tick walks a pointer instead of scanning the map.
- Out in the open the flow is fatal. **Only proper buildings shelter you**: models tagged `Shelter` (the 15 or so houses in two rings around the square, and three concrete bunkers). You need that building's roof over you and its solid walls blocking at least 2 of 3 sightlines toward the volcano. Terrain, rocks, trees, props, the well and debris never count, and glass doesn't stop the flow. An open doorway facing the volcano, or a wall that has burned away, leaves you exposed.
- The **shelter test is shared** between server damage and the client HUD, so the "SHELTERED / EXPOSED" indicator never disagrees with what happens to you.
- The cloud hugs the terrain using the shared heightmap (no raycasts) and smothers your screen when it engulfs you.

### Terrain and map (`server/MapBuilder.luau`, `shared/Heightmap.luau`)
- A pure heightmap function (cone profile, crater, a descending breach gorge that steers lava toward the village, pond) written chunk by chunk with `WriteVoxels`.
- Between rounds only the chunks that craters touched are rewritten. The village is rebuilt from a fixed seed.

### Also
- A how-to-play pop-up when a player joins (phase names and lengths are read from Config, so it never goes stale), closed with "Okay!", and an audible countdown tick for the last 5 seconds of the intermission.
- Players are tracked from the moment their character reaches the Workspace (`CharacterAdded` fires before that), with a safety net in the update loop. A character that slipped through would be immune to every hazard.
- A red flash at the screen edges on every hit, scaled by damage. It snaps in and fades straight back out, so a burst of hits reads as a burst of flashes and nothing ever lingers on screen.
- Camera shake that is undone before the default camera updates, so it never drifts your view.
- A round director with a phase janitor, so ending a phase or a round always cleans up every thread, source and effect it started.

---

## Project layout

```
caldera/
├─ default.project.json        Rojo project
├─ build/MountIgnis.rbxl       ready-to-open place
├─ src/shared/                 ReplicatedStorage.MountIgnis
│  ├─ Config.luau              every tunable number
│  ├─ Net.luau                 remotes + replicated state attributes
│  ├─ LavaGrid.luau            grid geometry + binary codec
│  ├─ Heightmap.luau           terrain shape (pure)
│  ├─ Ballistics.luau          projectile maths (pure)
│  ├─ Shelter.luau             shared cover test
│  └─ Signal.luau, Janitor.luau
├─ src/server/                 ServerScriptService.MountIgnisServer
│  ├─ init.server.luau         bootstrap
│  ├─ RoundService.luau        game loop
│  ├─ Volcano.luau             phase director
│  ├─ LavaSim.luau             fluid simulation (pure, unit-tested)
│  ├─ LavaFlow.luau            simulation runner + streaming
│  ├─ LavaBombs.luau, Pyroclastic.luau, Tremors.luau
│  ├─ Structures.luau, Combustion.luau, Hazards.luau
│  └─ MapBuilder.luau
├─ src/client/                 StarterPlayerScripts.MountIgnisClient
│  ├─ init.client.luau
│  ├─ LavaRenderer.luau, BombRenderer.luau, PyroclasticVisual.luau, RockfallEffects.luau
│  ├─ AshSky.luau, CameraShake.luau
│  ├─ HUD.luau, GuidePopup.luau
│  └─ UiKit.luau               shared UI helpers
├─ tests/                      offline tests for the pure modules
└─ tools/luaurun/              tiny Luau runner used by the tests
```

## Tuning

All balance lives in `src/shared/Config.luau`: phase lengths, vent output, lava viscosity
and cooling, bomb rate and damage, flow speed, fire spread, building health. Change a number
and press Play.

## Tests

The physics and maths modules contain no Roblox API calls, so they run outside Studio:

```sh
cargo build --release --manifest-path tools/luaurun/Cargo.toml
tools/luaurun/target/release/luaurun tests/run.luau
```

The tests cover volume conservation, yield-stopping, downhill flow, the void edge, heat
mixing, network change filtering, codec round trips, ballistics, the volcano shape, the
shelter rule (against a scripted fake world: terrain, the well, glass, doorways, two houses),
and a full eruption on the real heightmap. The eruption test asserts that the lava leaves through
the breach, reaches the village within the round, never spills over the far rim, and crusts
over in the aftermath.

Linting and formatting: `selene src` (uses `mountignis.yml`) and `stylua src tests`.

Type checking against the real Roblox API with [luau-lsp](https://github.com/JohnnyMorganz/luau-lsp)
(its repo ships the Roblox definitions as `scripts/globalTypes.d.luau`):

```sh
rojo sourcemap default.project.json -o sourcemap.json
luau-lsp analyze --platform roblox --sourcemap sourcemap.json --definitions @roblox=globalTypes.d.luau src
```

---

## Free models and assets used

**None.** All geometry is generated by script. The only content references are Roblox
built-in engine assets that ship with every client:

- Particle textures: `rbxasset://textures/particles/fire_main.dds`, `smoke_main.dds`, `sparkles_main.dds`
- Sounds: `rbxasset://sounds/volume_slider.ogg` (countdown tick), `rbxasset://sounds/action_falling.ogg` (pyroclastic roar), both checked against the current client's file manifest
- Built-in `Fire`, `Smoke` and `Explosion` instances

## Team

- _Member 1_: _what you built_
- _Member 2_: _what you built_
