# Board art

The bomber sprites are **nano-banana renders of the Softmax cog**, one kit per role, generated
with `gemini-2.5-flash-image` from the starter's own `data/soldier_red.png` as the style anchor.
The source render and the script that turns it into sprites are both committed, so the assets are
reproducible rather than mysterious. CI does not regenerate art.

| File | What it is |
|---|---|
| `scripts/art/source/bombers_sheet.png` | the single nano-banana render: four bomber kits side by side on a flat chroma backdrop |
| `scripts/art/split_cog_sheet.py` | key → split → trim → pad → resize to 128 px |
| `data/bomber_red.png`, `bomber_red_crown.png`, `bomber_blue.png`, `bomber_blue_crown.png` | the derived board sprites the viewer bakes its chips from — plain for seat `-1`, crowned for seat `-2`, so partners are tellable apart at a glance with labels hidden |
| `data/soldier_red.png`, `data/soldier_blue.png` | the starter's own cog art, carried BYTE FOR BYTE as the fallback |
| `data/arena_floor.png` | the starter's floor plate, tiled and darkened 18 % at load |
| `data/bomb.png` | the starter's bomb art, carried byte for byte (the file was `paintbomb.png` upstream; renamed so the spectator-vocabulary gate in `tests/test_pom_endcard_labels.nim` stays clean) |
| `data/powerup_range.png`, `data/powerup_kick.png` | the starter's `spraycan.png` and `shield.png`, carried byte for byte and renamed for the same reason |
| `client/art/walls/{wall_h,wall_v}.jpg` | the starter's wall tiles, composited onto the rigid cells at bake time |
| `client/art/lockerroom/*` | the starter's ready-room curtain, red and blue cogs only |

Regenerate:

```bash
python3 -m pip install --user pillow
python3 scripts/art/split_cog_sheet.py
```

The prompt used for the sheet (one call, all four kits in one render so the style cannot drift
between them):

> Using this wheeled robot character ("cog") as the exact character design reference, draw FOUR
> of these cogs side by side in one row, evenly spaced, same size, full body, TOP-DOWN overhead
> view, same clean cartoon rendering, crisp readable silhouette at very small size on a game
> board. Background: perfectly flat, solid, uniform pure bright green (#00FF00), no shadows, no
> gradients, no floor - it will be chroma-keyed out.
> They are BOMBER robots in a Bomberman-style arena. Each carries a small round black bomb with a
> short lit fuse held low in one arm - the bomb must read clearly as a bomb at tiny size.
> 1st from LEFT - RED BOMBER: warm red (#E0523A) plating, plain rounded head dome.
> 2nd - RED CAPTAIN BOMBER: identical to the 1st in shape, silhouette and colour, but wearing a
> small pointed GOLD CROWN on top of its head.
> 3rd - BLUE BOMBER: cool blue (#3F7CC4) plating, plain rounded head dome, otherwise identical in
> shape and pose to the 1st.
> 4th - BLUE CAPTAIN BOMBER: identical to the 3rd but wearing the same small pointed GOLD CROWN.
> All four must be IDENTICAL in shape, pose and size and differ ONLY in plating colour and the
> presence of the crown. No text, no labels, no numbers, no shields, no capes, no weapons other
> than the bomb.

The key is passed as the header `x-goog-api-key: $GEMINI_API_KEY` and is never written to a file,
a URL or a log.

## Why chips, not a rig

Each sprite is baked ONCE at load into three chip sizes (16, 24 and 32 px) with a 1 px team rim
and an alive/dead variant — **24 pre-baked chips** — so drawing four bombers a frame is four
blits and never a per-bomber rasterisation. At the 360 px featured-match embed an 11 × 11 board
is ~32 px a cell, which is exactly the largest chip; a 128 px articulated rig would cost four
rasterisations a frame to look the same.

## The rest of the board

Everything else is drawn, not sprited: the floor is the starter's plate tiled and darkened with
1 px cell gridlines, the rigid cells carry the starter's wall tiles (with a red-hot rim once
their ring has collapsed), the wooden walls get a per-cell seeded plank grain so 36 crates do not
look stamped, the flames are procedural additive quads, and the bomb countdown ring, the
chain-resolved blast footprints, the danger tint, the kick trail and the radio badges are all
canvas primitives in `client/broadcast_core.js`.
