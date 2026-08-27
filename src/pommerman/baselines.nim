## The two scripted baselines, both shipped as fillers. `sapper` is also the
## server-side fallback -- the decision engine imports THIS proc rather than
## duplicating it, so the two can never drift
## (tests/test_pom_control.nim).
##
## Both emit the same SeatDirective an LLM does, WITH A RADIO PAIR, through the
## same validator, which is what makes the bounded-orders test meaningful and
## what keeps the channel exercised in an all-scripted episode.
##
## PURE INTEGER (see board.nim).

import std/strutils
import sim_types, sim_config, board, bombs, radio, directives, sim_state,
  control

type
  Baseline* = enum
    blSapper = "sapper"
    blCamper = "camper"

  BaselineParams* = object
    bombEnemyRange*: int
    powerupSearch*: int
    dodgeHorizon*: int
    campExits*: int

const
  DefaultBaselineParams* = BaselineParams(
    # bombEnemyRange: an enemy this close on a clear row or column is worth a
    #   bomb even before the blast can reach it -- the fuse outlives the gap.
    # powerupSearch: how far sapper will walk for a power-up before going back
    #   to breaking wood.
    # dodgeHorizon: how many ticks ahead the survival override looks.
    # campExits: how many safe orthogonal neighbours camper insists on before
    #   it will lay a bomb at all.
    bombEnemyRange: 2,
    powerupSearch: 8,
    dodgeHorizon: 6,
    campExits: 2
  )
    ## Not guessed: tools/tune_baselines.nim sweeps the four head to head and
    ## tools/ci/baseline_tuning.json records the pick;
    ## tests/test_pom_tuning.nim asserts the shipped defaults still equal it.

  DefaultBaseline* = blSapper
    ## Anything unrecognised is the published default (the starter's rule).

  MiddleLow* = 3
  MiddleHigh* = 7
    ## The 5 x 5 block play is forced into once both rings have gone.

proc parseBaseline*(text: string): Baseline =
  let key = text.strip().toLowerAscii()
  for baseline in Baseline:
    if $baseline == key:
      return baseline
  DefaultBaseline

func inMiddle*(x, y: int): bool {.inline.} =
  x >= MiddleLow and x <= MiddleHigh and y >= MiddleLow and y <= MiddleHigh

func headInwardTick*(config: GameConfig): int =
  ## Eight ticks before the FIRST ring goes -- derived from the config, not
  ## from the literal 88, so the blitz variant (rings at 64 and 80) gets 56
  ## rather than a number that arrives after the arena has already shrunk.
  if config.collapseTicks.len == 0: high(int) else: config.collapseTicks[0] - 8

func onDoomedRing*(config: GameConfig, x, y: int): bool =
  ## The cell sits on a ring that is still scheduled to collapse.
  let ring = ringOf(x, y)
  ring >= 1 and ring <= config.collapseTicks.len

func enemiesWithin*(sim: SimServer, seat, radius: int): int =
  let me = sim.bombers[seat]
  for other in 0 ..< SeatCount:
    if teamOfSeat(other) == teamOfSeat(seat) or not sim.bombers[other].alive:
      continue
    if manhattan(me.x, me.y, sim.bombers[other].x,
        sim.bombers[other].y) <= radius:
      inc result

func adjacentToWood*(sim: SimServer, seat: int): bool =
  let me = sim.bombers[seat]
  for offset in DirOffsets:
    if sim.board.terrainAt(me.x + offset.dx, me.y + offset.dy) == tWood:
      return true
  false

func adjacentEnemy*(sim: SimServer, seat: int): int =
  let me = sim.bombers[seat]
  for offset in DirOffsets:
    let other = sim.bomberAt(me.x + offset.dx, me.y + offset.dy)
    if other >= 0 and teamOfSeat(other) != teamOfSeat(seat):
      return other
  -1

func enemyInLane*(sim: SimServer, seat, reach: int): int =
  ## The nearest living enemy on my row or column within `reach` cells with
  ## only passage between, or -1. Ties by lowest seat index.
  let me = sim.bombers[seat]
  result = -1
  var best = 0
  for other in 0 ..< SeatCount:
    if teamOfSeat(other) == teamOfSeat(seat) or not sim.bombers[other].alive:
      continue
    let him = sim.bombers[other]
    if me.x != him.x and me.y != him.y:
      continue
    let distance = manhattan(me.x, me.y, him.x, him.y)
    if distance == 0 or distance > reach:
      continue
    let
      stepX = (if him.x > me.x: 1 elif him.x < me.x: -1 else: 0)
      stepY = (if him.y > me.y: 1 elif him.y < me.y: -1 else: 0)
    var clear = true
    for k in 1 ..< distance:
      if not isPassage(sim.board, me.x + stepX * k, me.y + stepY * k):
        clear = false
        break
    if not clear:
      continue
    if result < 0 or distance < best:
      result = other
      best = distance

func woodRemains*(sim: SimServer): bool =
  for cell in 0 ..< BoardCells:
    if sim.board.terrain[cell] == tWood:
      return true
  false

proc sapperRadio*(sim: SimServer, seat: int): RadioPair =
  ## A real, legible signal, so the channel is exercised even in an
  ## all-scripted episode and a champion partnered with a filler has something
  ## to decode: `a` = ammo in hand plus one, `b` = living enemies within four
  ## cells plus one.
  clampPair(1 + sim.bombers[seat].ammo, 1 + sim.enemiesWithin(seat, 4))

proc sapperDirective*(
  sim: SimServer, seat: int, params = DefaultBaselineParams
): SeatDirective =
  ## 1. an enemy in a clear lane within `bombEnemyRange`, with ammo -> bomb;
  ## 2. else adjacent to wood, with ammo -> bomb;
  ## 3. else a reachable power-up within `powerupSearch` -> go to it;
  ## 4. else any wooden wall left -> break;
  ## 5. else the rings are closing and I am outside the middle -> go (5,5);
  ## 6. else -> hunt the nearest living enemy.
  result = defaultDirective()
  result.source = dsScripted
  result.radio = sapperRadio(sim, seat)
  let me = sim.bombers[seat]
  if not me.alive:
    result.order = BomberOrder(kind: okHide, target: -1, dir: -1,
      fromReply: true)
    return
  if me.ammo > 0 and sim.enemyInLane(seat, params.bombEnemyRange) >= 0:
    result.order = BomberOrder(kind: okBomb, target: -1, dir: -1,
      fromReply: true)
    return
  if me.ammo > 0 and sim.adjacentToWood(seat):
    result.order = BomberOrder(kind: okBomb, target: -1, dir: -1,
      fromReply: true)
    return
  let item = sim.nearestItem(seat, params.powerupSearch)
  if item.found:
    result.order = BomberOrder(kind: okGo, x: item.x, y: item.y, target: -1,
      dir: -1, fromReply: true)
    return
  if sim.woodRemains() and sim.nearestWoodApproach(seat).found:
    result.order = BomberOrder(kind: okBreak, target: -1, dir: -1,
      fromReply: true)
    return
  if (onDoomedRing(sim.config, me.x, me.y) or not inMiddle(me.x, me.y)) and
      sim.tick >= headInwardTick(sim.config):
    result.order = BomberOrder(kind: okGo, x: BoardSize div 2,
      y: BoardSize div 2, target: -1, dir: -1, fromReply: true)
    return
  let enemy = sim.nearestEnemy(seat)
  if enemy >= 0:
    result.order = BomberOrder(kind: okHunt, target: enemy, dir: -1,
      fromReply: true)
  else:
    result.order = BomberOrder(kind: okHide, target: -1, dir: -1,
      fromReply: true)

proc camperDirective*(
  sim: SimServer, seat: int, params = DefaultBaselineParams
): SeatDirective =
  ## Deliberately weaker and DIFFERENT IN SHAPE, so the ladder gets a spread
  ## rather than two versions of one bot -- and deliberately SILENT on the
  ## radio, which is the control against which "did the radio matter?" is
  ## measured.
  result = defaultDirective()
  result.source = dsScripted
  result.radio = defaultPair()
  let me = sim.bombers[seat]
  if not me.alive:
    result.order = BomberOrder(kind: okHide, target: -1, dir: -1,
      fromReply: true)
    return
  if me.ammo > 0 and sim.adjacentEnemy(seat) >= 0:
    result.order = BomberOrder(kind: okBomb, target: -1, dir: -1,
      fromReply: true)
    return
  if me.ammo > 0 and sim.adjacentToWood(seat):
    let danger = sim.dangerNow(params.dodgeHorizon)
    var safeExits = 0
    for offset in DirOffsets:
      let
        nx = me.x + offset.dx
        ny = me.y + offset.dy
      if sim.passableNow(nx, ny) and danger.safeThroughout(nx, ny):
        inc safeExits
    if safeExits >= params.campExits:
      result.order = BomberOrder(kind: okBomb, target: -1, dir: -1,
        fromReply: true)
      return
  if sim.tick >= headInwardTick(sim.config) and
      (onDoomedRing(sim.config, me.x, me.y) or not inMiddle(me.x, me.y)):
    result.order = BomberOrder(kind: okGo, x: BoardSize div 2,
      y: BoardSize div 2, target: -1, dir: -1, fromReply: true)
    return
  result.order = BomberOrder(kind: okHide, target: -1, dir: -1,
    fromReply: true)

proc scriptedDirective*(
  sim: SimServer, seat: int, baseline: Baseline,
  params = DefaultBaselineParams
): SeatDirective =
  case baseline
  of blSapper: sapperDirective(sim, seat, params)
  of blCamper: camperDirective(sim, seat, params)

proc fallbackDirective*(
  sim: SimServer, seat: int, params = DefaultBaselineParams
): SeatDirective =
  ## The server-side fallback IS the sapper baseline -- same proc, never a
  ## copy (tests/test_pom_control.nim asserts they agree field for field).
  var directive = sapperDirective(sim, seat, params)
  directive.source = dsFallback
  directive
