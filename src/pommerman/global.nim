## The board payload: the bomber/bomb/item/flame object pools the viewer blits,
## the baked-arena descriptor and the pool sizing.
##
## The board is a GRID, not a pixel arena: coordinates are emitted in CELL
## space and the renderer scales them, so the same packet reads correctly at
## 360 px and at desktop width. There is no fov cache and no shadowcasting --
## spectators see everything; the per-seat hiding (the opposing team's radio)
## lives in the observation builder (decide.nim), not in the renderer.

import std/json
import sim_types, board, bombs, sim_state

const
  BomberSpriteBase* = 1000
    ## Bomber chip pool base id, filled in seat order like the starter's other
    ## object families.
  BombObjectBase* = 2000
  ItemObjectBase* = 3000
  FlameFxBase* = 4000
  BomberPool* = SeatCount
  BombPool* = MaxBombs
  ItemPool* = MaxItems
  FlamePool* = MaxFlames

  FloorDarkenPermille* = 180
    ## arena_floor.png is tiled and darkened 18 % at map install, plus 1 px cell
    ## gridlines, so the grid reads with the HUD off.
  GridlineEvery* = 1

func skinOf*(seat: int): string {.inline.} =
  ## Seat `-1` of each team wears the plain kit and seat `-2` the crown, so
  ## partners are distinguishable at a glance without a label.
  if seat < TeamCount: "plain" else: "crown"

proc boardJson*(sim: SimServer): JsonNode =
  ## The board descriptor the renderer bakes its floor from, plus the terrain
  ## rows, the live flames, the loose items and how far the arena has shrunk.
  var flames = newJArray()
  for at in 0 ..< BoardCells:
    if sim.board.flame[at] > 0:
      flames.add(%[at mod BoardSize, at div BoardSize, sim.board.flame[at]])
  var items = newJArray()
  for at in 0 ..< BoardCells:
    if sim.board.item[at] != ikNone:
      let kind =
        case sim.board.item[at]
        of ikExtraBomb: "extrabomb"
        of ikIncrRange: "range"
        of ikKick: "kick"
        of ikNone: ""
      items.add(%*{
        "x": at mod BoardSize, "y": at div BoardSize, "kind": kind})
  var rings = newJArray()
  for ring in 1 .. sim.board.collapsedRings:
    rings.add(%ring)
  var terrain = newJArray()
  for row in sim.board.terrainRows():
    terrain.add(%row)
  %*{
    "w": BoardSize,
    "h": BoardSize,
    "terrain": terrain,
    "flame": flames,
    "items": items,
    "collapsedRings": rings,
    "floorDarken": FloorDarkenPermille,
    "gridEvery": GridlineEvery,
    "pools": {
      "bombers": BomberPool, "bombs": BombPool,
      "items": ItemPool, "flames": FlamePool
    }
  }

proc bombsJson*(sim: SimServer): JsonNode =
  ## Every live bomb with the CHAIN-RESOLVED footprint the viewer draws,
  ## computed by the same `bombs.nim` proc the sim and the observation use --
  ## so what a spectator sees is what will burn.
  result = newJArray()
  for bomb in sim.bombs:
    var footprint = newJArray()
    for cell in blastCells(sim.board, bomb.x, bomb.y, bomb.blast):
      footprint.add(%[cell.x, cell.y])
    result.add(%*{
      "id": bomb.id, "x": bomb.x, "y": bomb.y, "fuse": bomb.fuse,
      "range": bomb.blast, "seat": bomb.owner,
      "team": teamName(teamOfSeat(bomb.owner)),
      "moving": $bomb.velocity, "blast": footprint})

proc bombersJson*(sim: SimServer): JsonNode =
  result = newJArray()
  for seat in 0 ..< SeatCount:
    let bomber = sim.bombers[seat]
    let pair = sim.mailbox.lastSent(seat)
    result.add(%*{
      "seat": seat,
      "alias": seatAliasName(seat),
      "team": teamName(teamOfSeat(seat)),
      "x": bomber.x, "y": bomber.y,
      "alive": bomber.alive,
      "ammo": bomber.ammo,
      "range": bomber.blast,
      "kick": bomber.kick,
      "radio": [pair.a, pair.b],
      "radioAge": 1,
      "skin": skinOf(seat),
      "fallback": sim.fallbackTurns[seat] > 0})

proc dangerJson*(sim: SimServer): JsonNode =
  result = newJArray()
  for row in sim.dangerNow(9).dangerRows():
    result.add(%row)

proc deathsJson*(sim: SimServer): JsonNode =
  ## The deaths resolved in the frame just stepped: the renderer flashes the
  ## cell white, drops the bomber and leaves a chalk outline for the rest of
  ## the replay.
  result = newJArray()
  for death in sim.lastDeaths:
    result.add(%*{
      "x": death.x, "y": death.y, "victim": death.victim,
      "killer": death.killer, "cause": death.cause,
      "team": teamName(teamOfSeat(death.victim))})

proc scorchJson*(sim: SimServer): JsonNode =
  ## Wooden walls broken this frame: six frames of debris and a 60-frame
  ## scorch, so the shape of the fight persists.
  result = newJArray()
  for wood in sim.lastWood:
    result.add(%*{"x": wood.x, "y": wood.y, "team": teamName(wood.team)})
