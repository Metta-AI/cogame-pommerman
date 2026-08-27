## The board: an 11 x 11 integer grid, the deterministic 4-fold rotationally
## symmetric map generator, the ring/collapse table and the four corner spawns.
##
## PURE INTEGER. No pixie, no pixel queries, no floating point -- the native
## and the wasm builds must agree bit for bit, and
## `tests/test_pom_sim.nim`'s no-float grep enforces it mechanically.

import sim_types

type
  Terrain* = enum
    tRigid = 0
    tWood = 1
    tPassage = 2

  ItemKind* = enum
    ikNone = 0
    ikExtraBomb = 1
    ikIncrRange = 2
    ikKick = 3

  Cell* = tuple[x, y: int]

  Board* = object
    terrain*: array[BoardCells, Terrain]
    item*: array[BoardCells, ItemKind]      ## the item lying on the cell
    hidden*: array[BoardCells, ItemKind]    ## what a wooden wall is hiding
    flame*: array[BoardCells, int]          ## remaining flame life, 0 = none
    flameOwner*: array[BoardCells, int]     ## seat whose bomb lit it, or -1;
                                            ## NOT hashed -- it is re-derived
                                            ## identically on playback and the
                                            ## hash pins terrain/item/life
    collapsedRings*: int

const
  SpawnCells*: array[SeatCount, Cell] = [
    (1, 1),    ## seat 0, RED-1,  NW
    (9, 1),    ## seat 1, BLUE-1, NE
    (9, 9),    ## seat 2, RED-2,  SE
    (1, 9)     ## seat 3, BLUE-2, SW
  ]

  TerrainChars* = ['#', 'W', '.']
  ItemChars* = ['.', 'e', 'r', 'k']

  WoodOrbits* = 9        ## 9 orbits x 4 = 36 wooden walls (upstream NUM_WOOD)
  ExtraBombOrbits* = 2   ## 2 x 4 = 8 extra-bomb pickups
  IncrRangeOrbits* = 2   ## 2 x 4 = 8 blast-range pickups
  KickOrbits* = 1        ## 1 x 4 = 4 kick pickups; 20 items = NUM_ITEMS

func cellIndex*(x, y: int): int {.inline.} =
  y * BoardSize + x

func onBoard*(x, y: int): bool {.inline.} =
  x >= 0 and y >= 0 and x < BoardSize and y < BoardSize

func ringOf*(x, y: int): int {.inline.} =
  ## ring(x, y) = min(x, y, 10-x, 10-y). Ring 0 is the permanent border; ring 1
  ## turns rigid at the first collapse tick and ring 2 at the second.
  min(min(x, y), min(BoardSize - 1 - x, BoardSize - 1 - y))

func rotCell*(x, y: int): Cell {.inline.} =
  ## A 90 degree turn about (5, 5). The whole map is built out of orbits of
  ## this map, so every seat's corner is an exact rotation of every other's.
  (BoardSize - 1 - y, x)

func terrainAt*(board: Board, x, y: int): Terrain {.inline.} =
  if not onBoard(x, y): tRigid else: board.terrain[cellIndex(x, y)]

func itemAt*(board: Board, x, y: int): ItemKind {.inline.} =
  if not onBoard(x, y): ikNone else: board.item[cellIndex(x, y)]

func flameAt*(board: Board, x, y: int): int {.inline.} =
  if not onBoard(x, y): 0 else: board.flame[cellIndex(x, y)]

func isPassage*(board: Board, x, y: int): bool {.inline.} =
  onBoard(x, y) and board.terrain[cellIndex(x, y)] == tPassage

# ---------------------------------------------------------------------------
#  The generator
# ---------------------------------------------------------------------------

type Xorshift* = object
  state*: uint64

func initXorshift*(seed: int): Xorshift =
  ## xorshift64*, seeded so a seed of 0 still produces a live generator. The
  ## ONLY randomness in the whole game, and it is used in exactly one place --
  ## the orbit draw below.
  var s = uint64(seed) * 0x2545F4914F6CDD1D'u64
  s = s xor 0x9E3779B97F4A7C15'u64
  if s == 0: s = 0x9E3779B97F4A7C15'u64
  Xorshift(state: s)

func next*(rng: var Xorshift): uint64 =
  var x = rng.state
  x = x xor (x shr 12)
  x = x xor (x shl 25)
  x = x xor (x shr 27)
  rng.state = x
  x * 0x2545F4914F6CDD1D'u64

func below*(rng: var Xorshift, bound: int): int =
  if bound <= 1: 0 else: int(rng.next() mod uint64(bound))

func isCornerPocket*(x, y: int): bool =
  ## The four corner cells and their two interior orthogonal neighbours each:
  ## 12 cells, exactly three `rot` orbits. Always passage, so no seat can be
  ## walled in at tick 0.
  for spawn in SpawnCells:
    if x == spawn.x and y == spawn.y:
      return true
    let
      towardsX = (if spawn.x == 1: spawn.x + 1 else: spawn.x - 1)
      towardsY = (if spawn.y == 1: spawn.y + 1 else: spawn.y - 1)
    if (x == towardsX and y == spawn.y) or (x == spawn.x and y == towardsY):
      return true
  false

func isLattice*(x, y: int): bool {.inline.} =
  ## The classic Bomberman even lattice: interior cells with BOTH coordinates
  ## even. Closed under `rot`, and it leaves every odd row and every odd column
  ## fully open -- which is what makes the board connected BY CONSTRUCTION with
  ## no repair pass.
  x >= 1 and y >= 1 and x <= BoardSize - 2 and y <= BoardSize - 2 and
    x mod 2 == 0 and y mod 2 == 0

proc freeOrbits*(): seq[array[4, Cell]] =
  ## The 13 orbits of 4 that are neither border, nor lattice, nor a corner
  ## pocket, nor the centre. Ordered by their canonical representative (lowest
  ## y, then lowest x) so the draw below is a pure function of the seed.
  var taken: array[BoardCells, bool]
  for y in 0 ..< BoardSize:
    for x in 0 ..< BoardSize:
      if ringOf(x, y) == 0 or isLattice(x, y) or isCornerPocket(x, y) or
          (x == BoardSize div 2 and y == BoardSize div 2):
        taken[cellIndex(x, y)] = true
  for y in 0 ..< BoardSize:
    for x in 0 ..< BoardSize:
      if taken[cellIndex(x, y)]:
        continue
      var orbit: array[4, Cell]
      var cx = x
      var cy = y
      for k in 0 ..< 4:
        orbit[k] = (cx, cy)
        taken[cellIndex(cx, cy)] = true
        let turned = rotCell(cx, cy)
        cx = turned.x
        cy = turned.y
      result.add(orbit)

proc generateBoard*(seed: int): Board =
  ## Deterministic, 4-fold rotationally symmetric, connected by construction.
  ##
  ## 1. the outer ring is rigid (40 cells);
  ## 2. the even lattice is rigid (16 cells);
  ## 3. the corner pockets (12) and the centre (1) are passage;
  ## 4. the remaining 52 cells are 13 orbits of 4: Fisher-Yates them with a
  ##    xorshift64* seeded by `seed`, then the first 9 orbits are wooden wall
  ##    (36 cells) and the last 4 are passage (16 cells);
  ## 5. of the 9 wood orbits, in that same shuffled order, orbits 1-2 hide an
  ##    extra bomb, 3-4 hide +1 range, 5 hides kick, 6-9 hide nothing --
  ##    20 power-ups, upstream's NUM_ITEMS.
  for y in 0 ..< BoardSize:
    for x in 0 ..< BoardSize:
      let at = cellIndex(x, y)
      result.terrain[at] =
        if ringOf(x, y) == 0 or isLattice(x, y): tRigid else: tPassage
      result.item[at] = ikNone
      result.hidden[at] = ikNone
      result.flame[at] = 0
      result.flameOwner[at] = -1
  var orbits = freeOrbits()
  var rng = initXorshift(seed)
  # Fisher-Yates, downward, so the shuffle is a pure function of the draw order
  for i in countdown(orbits.high, 1):
    let j = rng.below(i + 1)
    swap(orbits[i], orbits[j])
  for index in 0 ..< WoodOrbits:
    let hidden =
      if index < ExtraBombOrbits: ikExtraBomb
      elif index < ExtraBombOrbits + IncrRangeOrbits: ikIncrRange
      elif index < ExtraBombOrbits + IncrRangeOrbits + KickOrbits: ikKick
      else: ikNone
    for cell in orbits[index]:
      let at = cellIndex(cell.x, cell.y)
      result.terrain[at] = tWood
      result.hidden[at] = hidden

func collapseRingFor*(config: GameConfig, tick: int): int =
  ## Which ring collapses on `tick`, or -1. `collapseTicks[i]` collapses ring
  ## `i + 1`, so the table is a list of ticks and the ring is its position.
  for index, at in config.collapseTicks:
    if at == tick:
      return index + 1
  -1

func nextCollapse*(
  config: GameConfig, tick: int
): tuple[tick, ring: int] =
  ## The next scheduled collapse strictly after `tick`, or (-1, -1).
  result = (-1, -1)
  for index, at in config.collapseTicks:
    if at > tick:
      return (at, index + 1)

proc collapseRing*(board: var Board, ring: int) =
  ## Every cell of `ring` becomes rigid; anything lying there is destroyed.
  ## Bombers and bombs are handled by the sim, which owns them.
  if ring <= 0:
    return
  for y in 0 ..< BoardSize:
    for x in 0 ..< BoardSize:
      if ringOf(x, y) != ring:
        continue
      let at = cellIndex(x, y)
      board.terrain[at] = tRigid
      board.item[at] = ikNone
      board.hidden[at] = ikNone
      board.flame[at] = 0
      board.flameOwner[at] = -1
  board.collapsedRings = max(board.collapsedRings, ring)

proc terrainRows*(board: Board): seq[string] =
  ## 11 strings of 11 characters: `#` rigid, `W` wood, `.` passage, plus
  ## `e`/`r`/`k` for an item lying in the open. A bomb is NOT drawn here (it is
  ## in `bombs`) and neither is a bomber (it is in `bombers`), so the layers
  ## can never collide.
  for y in 0 ..< BoardSize:
    var row = newString(BoardSize)
    for x in 0 ..< BoardSize:
      let at = cellIndex(x, y)
      row[x] =
        if board.flame[at] > 0: '*'
        elif board.item[at] != ikNone: ItemChars[ord(board.item[at])]
        else: TerrainChars[ord(board.terrain[at])]
    result.add(row)

func manhattan*(ax, ay, bx, by: int): int {.inline.} =
  abs(ax - bx) + abs(ay - by)
