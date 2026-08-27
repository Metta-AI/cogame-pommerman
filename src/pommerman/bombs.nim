## Bombs: fuses, kicking, the blast-cell walk, the chain-reaction fixpoint, the
## flame timers -- and `dangerMap`, the ONE proc the observation builder, the
## controller and the viewer's overlay all call, so the three can never
## disagree about what is about to be on fire.
##
## PURE INTEGER (see board.nim).

import sim_types, board

type
  Velocity* = enum
    vNone = "none"
    vUp = "up"
    vDown = "down"
    vLeft = "left"
    vRight = "right"

  Bomb* = object
    id*: int          ## creation order, ascending, never reused
    x*, y*: int
    fuse*: int        ## ticks until it detonates
    blast*: int       ## copied from the owner at placement, never updated
    owner*: int       ## seat index
    velocity*: Velocity
    # placedTick: the tick the bomb was laid on. Its fuse does not tick on
    # that tick, so a bomb laid at t detonates at exactly t + bombFuse --
    # upstream's own off-by-one, and what docs/RULES.md states.
    placedTick*: int

  DangerMap* = object
    ## `unsafe[t * BoardCells + cell]` is true when that cell is lethal at tick
    ## `now + t`; `first[cell]` is the smallest such t, or -1.
    horizon*: int
    unsafe*: seq[bool]
    first*: array[BoardCells, int]

const
  # The FIXED direction order every tie in this game breaks by: up, down,
  # left, right, then stay.
  DirOffsets*: array[4, tuple[dx, dy: int]] =
    [(0, -1), (0, 1), (-1, 0), (1, 0)]
  DirNames* = ["up", "down", "left", "right"]

func velocityOfDir*(dir: int): Velocity {.inline.} =
  case dir
  of 0: vUp
  of 1: vDown
  of 2: vLeft
  else: vRight

func dirOfVelocity*(velocity: Velocity): int {.inline.} =
  case velocity
  of vNone: -1
  of vUp: 0
  of vDown: 1
  of vLeft: 2
  of vRight: 3

func bombIndexAt*(bombs: seq[Bomb], x, y: int): int =
  ## The live bomb standing on that cell, or -1. At most one bomb per cell.
  for index, bomb in bombs:
    if bomb.x == x and bomb.y == y:
      return index
  -1

proc blastCells*(board: Board, x, y, blast: int): seq[Cell] =
  ## The bomb's own cell plus, in each of the four directions, up to
  ## `blast - 1` cells: walking outward, STOPPING BEFORE the first rigid cell,
  ## STOPPING AT AND INCLUDING the first wood cell, and passing through
  ## passage, power-ups, bombers and bombs.
  result.add((x, y))
  for offset in DirOffsets:
    for step in 1 ..< max(1, blast):
      let
        cx = x + offset.dx * step
        cy = y + offset.dy * step
      if not onBoard(cx, cy):
        break
      let terrain = board.terrain[cellIndex(cx, cy)]
      if terrain == tRigid:
        break
      result.add((cx, cy))
      if terrain == tWood:
        break

func projectBomb*(board: Board, bombs: seq[Bomb], index, ticks: int): Cell =
  ## Where a kicked bomb will be in `ticks` ticks if nothing stops it: one cell
  ## a tick down its lane while the destination is passage and holds no other
  ## bomb, then stationary. Used only by `dangerMap`, which is a FORECAST --
  ## the authoritative movement is `sim.resolveTick`.
  let bomb = bombs[index]
  result = (bomb.x, bomb.y)
  let dir = dirOfVelocity(bomb.velocity)
  if dir < 0:
    return
  let offset = DirOffsets[dir]
  for _ in 0 ..< max(0, ticks):
    let
      nx = result.x + offset.dx
      ny = result.y + offset.dy
    if not isPassage(board, nx, ny):
      return
    var blocked = false
    for other in 0 ..< bombs.len:
      if other != index and bombs[other].x == nx and bombs[other].y == ny:
        blocked = true
        break
    if blocked:
      return
    result = (nx, ny)

proc detonationTicks*(board: Board, bombs: seq[Bomb]): seq[int] =
  ## Every live bomb's effective detonation tick offset, resolved through the
  ## SAME chain-reaction fixpoint the sim runs: a bomb standing in another
  ## bomb's footprint at the moment that one goes off goes off with it.
  result = newSeq[int](bombs.len)
  for index, bomb in bombs:
    result[index] = max(0, bomb.fuse)
  for _ in 0 ..< bombs.len + 1:
    var changed = false
    for index in 0 ..< bombs.len:
      let at = projectBomb(board, bombs, index, result[index])
      for cell in blastCells(board, at.x, at.y, bombs[index].blast):
        for other in 0 ..< bombs.len:
          if other == index:
            continue
          let otherAt = projectBomb(board, bombs, other, result[index])
          if otherAt.x == cell.x and otherAt.y == cell.y and
              result[other] > result[index]:
            result[other] = result[index]
            changed = true
    if not changed:
      break

proc dangerMap*(
  board: Board, bombs: seq[Bomb], config: GameConfig, tick, horizon: int
): DangerMap =
  ## "Ticks until this cell is on fire", decoded once for everybody. Covers the
  ## flames already burning, every live bomb resolved through the chain
  ## reaction, and every collapse ring scheduled inside the horizon (standing
  ## on a ring when it goes is death by crushing, which is danger by any other
  ## name).
  result.horizon = max(0, horizon)
  result.unsafe = newSeq[bool]((result.horizon + 1) * BoardCells)
  for cell in 0 ..< BoardCells:
    result.first[cell] = -1

  proc mark(self: var DangerMap, cell, t: int) =
    if t < 0 or t > self.horizon:
      return
    self.unsafe[t * BoardCells + cell] = true
    if self.first[cell] < 0 or t < self.first[cell]:
      self.first[cell] = t

  let life = max(1, config.flameLife)
  for cell in 0 ..< BoardCells:
    let remaining = board.flame[cell]
    for t in 0 ..< remaining:
      result.mark(cell, t)

  let times = detonationTicks(board, bombs)
  for index in 0 ..< bombs.len:
    let
      at = projectBomb(board, bombs, index, times[index])
      start = times[index]
    if start > result.horizon:
      continue
    for cell in blastCells(board, at.x, at.y, bombs[index].blast):
      for t in start ..< start + life:
        result.mark(cellIndex(cell.x, cell.y), t)

  for index, at in config.collapseTicks:
    let offset = at - tick
    if offset < 0 or offset > result.horizon:
      continue
    let ring = index + 1
    for y in 0 ..< BoardSize:
      for x in 0 ..< BoardSize:
        if ringOf(x, y) == ring:
          ## A collapsing ring is lethal from the tick it goes and stays
          ## impassable for ever after, so it is unsafe for the whole horizon.
          for t in offset .. result.horizon:
            result.mark(cellIndex(x, y), t)

func safeAt*(danger: DangerMap, x, y, t: int): bool {.inline.} =
  if not onBoard(x, y):
    return false
  if t < 0 or t > danger.horizon:
    return true
  not danger.unsafe[t * BoardCells + cellIndex(x, y)]

func safeThroughout*(danger: DangerMap, x, y: int): bool =
  ## Safe for EVERY t in 0 .. horizon -- what "an escape exists" means.
  if not onBoard(x, y):
    return false
  danger.first[cellIndex(x, y)] < 0

func firstDangerAt*(danger: DangerMap, x, y: int): int {.inline.} =
  if not onBoard(x, y): 0 else: danger.first[cellIndex(x, y)]

proc dangerRows*(danger: DangerMap): seq[string] =
  ## The grid as 11 strings of digits: `danger[y][x]` is the number of ticks
  ## until that cell first catches fire, or `.` for "safe for at least 10
  ## ticks". Exactly what the observation and the viewer overlay both read.
  for y in 0 ..< BoardSize:
    var row = newString(BoardSize)
    for x in 0 ..< BoardSize:
      let first = danger.first[cellIndex(x, y)]
      row[x] =
        if first < 0 or first > 9: '.'
        else: char(ord('0') + first)
    result.add(row)
