# Cloud Glider — Godot 4.7 fluid-cloud flight playground

A dreamy hang-glider flight toy: fluid, beam-carvable clouds near you, metaball/SDF solid
clouds to the horizon, a full day/night sky, procedural wonderland terrain, ocean, lakes,
flocks of birds and a fully procedural soundscape. No external assets — everything is
generated at startup (terrain + cloud field + noise on the GPU, audio on a worker thread).

## Run it

```powershell
& "C:\Users\chris\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64.exe" --path "C:\Users\chris\Documents\Claude\Clouds Generator Playground"
```

Open in the editor instead with `-e`. Automated screenshot + perf tour:
`... --path . -- --shots` (PNG files land in `shots/`; `-- --shots --only=08` runs a subset).

> Gotcha: if you edit a `compute/*.glsl` file outside the editor, delete its
> `.godot/imported/<name>.glsl-*` files (or open the editor) — headless `--import`
> does not always pick up compute-shader edits.

## Controls (also shown on the left of the screen)

| Key | Action |
|---|---|
| W / S | Pitch — inverted by default (S climbs). Toggle in Options |
| A / D | Yaw |
| Q / E | Roll (full 3-axis: loops and inverted flight work) |
| Shift / Ctrl | Throttle up / down — a target airspeed from 0 to **500 m/s**. Passing 120 m/s fires a cloud-shoving **boost puff**; passing 343 m/s breaks the **sound barrier**. On foot: Shift sprints |
| Space / LMB | Cloud beam (flight). On ground/water: tap to hop, **hold to charge; at full charge you launch into flight** |
| M | Mouse steering (nose eases toward the reticle) |
| C | Cycle camera: first person → chase → free orbit |
| Middle-drag | Look around in third person (chase springs back, free stays) · T resets the camera |
| Scroll | Zoom (3.5–320 m) · **Alt + scroll** field of view |
| N | +90 minutes · V new weather · Caps Lock pause |
| 1–4 | Quality preset (Low / Medium / High / Ultra) |
| R | Respawn above the cloud deck · **F2** reload the whole world (keeps settings) |
| O / K | Options (columns along both screen edges, no scrolling) / sound mixer |
| H / F1 / F11 | Hide key list / hide HUD / fullscreen |
| Esc | Exit (with confirmation) |

Options: hover any slider for an explanation, right-click it to reset. Every setting is saved
between sessions in `user://settings.cfg` (on Windows:
`%APPDATA%\Godot\app_userdata\Cloud Glider\settings.cfg`).

Flight model: below ~12 m/s you keep most of your control; below ~8 m/s you **stall** — lift
fades and the nose drops into the fall until you have airspeed again. Nothing pulls the nose up
on its own; the optional wing auto-level only acts near upright.

## How the clouds work

```
           ┌──────────── near field (≤ "transition" m) ────────────┐
 player ──►│ compute fluid grid 96³ (cloud space, scrolls with you) │
           │ velocity + density, semi-Lagrangian advection,         │
           │ optional Jacobi pressure, wake / beam / splash forces, │
           │ heals toward the far field ───────────────┐            │
           └───────────────────────────────────────────┼────────────┘
                                                        ▼
 far field: smooth-union flat-bottomed metaballs + deck shelf, baked on the GPU into a
 tiling SDF volume (384×96×384 over 16×3.2×16 km) ──► raymarched with sphere tracing,
 billow/detail noise erosion, SDF light-march, analytic SDF normals ("solid" shading).
 Beyond the raymarch range: optional billboard impostors cross-fade in.
```

* **Seamless hand-off:** the fluid is seeded from, and heals toward, exactly the same
  coverage function the far field renders, and both are eroded by the same noise, so the
  blend across the transition band never pops. Far clouds sit outside the grid, so the
  beam cannot touch them.
* **Splashes:** entering a cloud fires a crown-splash event; exiting fires a puffed-out
  "exit wound" plus a trailing whirlwind tendril. All scale with speed. Your wake drags,
  swirls (twin wingtip vortices) and bores tunnels that slowly heal.
* **Inside a cloud:** the cloud you are in is thinned to a grey veil, and its outer shell
  is outlined as you look out ("inverse X-ray").
* **Thunderheads:** tall twisted billow columns with anvils, grey albedo, rain shafts,
  lightning that lights the cloud interior and the ground, and distance-delayed thunder.
  Width, base, anvil spread / thickness and twist are sliders.
* **Light:** SDF light march + multiple-scattering octaves (Lighting quality 1–5), powder
  term, silver lining, a **glory** (rainbow ring around your shadow on a cloud when the sun is
  behind you) and a pale fogbow, crepuscular shafts, your glider's shadow on clouds.
  Sunlight colour comes from Rayleigh + aerosol extinction through the air mass; the sun and
  moon linger near the horizon so golden light fills about half the day.
* **Sound:** a generative soundtrack (pads, kalimba plucks, glass bells over wandering chords)
  that follows what you do — calm cruising, dreamy above the deck, hushed at night, darker near
  storms, muffled inside clouds, rippling when you speed up — plus a wah-wah sci-fi beam.
* **The pilot:** a moustached aviator in leather cap and brass goggles under a ribbed,
  scalloped Lilienthal-style glider; the silk scarf and the red tail ribbon are cloth sims.

Everything about spawning and look is live-tunable in **Options → Cloud look / Cloud
spawning / Fluid simulation** (puffiness, billow size, tendrils, edge softness, fullness,
transparency, mist halo, reflectivity, silver lining, self-shadowing, counts, sizes,
tower-iness, deck altitude/coverage, thunderheads, heal rate, wake, swirl, beam…).

## Files

| File | Role |
|---|---|
| `scripts/main.gd` | Builds the world, input, per-frame wiring, screenshot tour |
| `scripts/params.gd` | Autoload `P`: every tweakable + quality presets (drives the Options UI) |
| `scripts/cloud_field.gd` + `compute/sdf_bake.glsl` | Metaball/deck/storm generation, binned SDF bake, CPU copy for queries |
| `scripts/fluid.gd` + `compute/fluid.glsl` | Near-field fluid grid (8 passes in one shader) |
| `shaders/clouds.gdshader` | Fullscreen raymarcher (fluid + SDF, lighting, veil, rain, lightning) |
| `shaders/sky.gdshader` | Atmosphere, sun/moon, stars, Milky Way, galaxies, cirrus, overcast |
| `shaders/common.gdshaderinc` | Shared atmosphere/haze — keeps sky, clouds, land and water in one palette |
| `scripts/terrain.gd` + `compute/terrain_gen.glsl` + `shaders/terrain.gdshader` | Wonderland heightmap, lakes, geomorphing clipmap |
| `shaders/water.gdshader` | Ocean + lakes (per-pixel Gerstner, glitter, foam, ripples) |
| `scripts/player.gd`, `pilot_model.gd`, `ribbon.gd` | Flight model, ground/swim modes, pilot + glider, cloth ribbon/scarf, contrails, beam, sonic FX |
| `scripts/camera_rig.gd`, `hud.gd` | Cameras, FOV/shake, cockpit instruments, options, exit dialog |
| `scripts/birds.gd`, `audio.gd`, `sky_env.gd`, `impostors.gd` | Flocks, procedural audio, time/weather/lightning, far impostors |

## Measured performance (RTX 2060, 1600×900, Medium preset, render scale 0.75 + FSR 1)

| Scene | GPU | CPU |
|---|---|---|
| Open sky / cumulus | 6–8 ms | 8–10 ms |
| Above the deck, sunset | 9–10 ms | 11 ms |
| Grazing along the deck / beside a storm | ~10 ms | ~12 ms |
| Inside a cloud | ~13 ms | ~15 ms |

That's 80–144 FPS. The display is 144 Hz, so many readings are v-sync capped.
