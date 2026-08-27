## The bomber controller: the deterministic map from one commander order to one
## grid action per living bomber, every tick.
##
## There is NO randomness here at all. Every tie breaks by the fixed direction
## order up, down, left, right, stay, then by ascending seat id -- which is what
## makes the recorded order stream sufficient to re-derive the whole episode in
## the browser.
##
## PURE INTEGER (see board.nim).

import sim_types, sim_config, board, bombs, radio, directives, sim_state

type
  Action* = enum
    acStay = 0
    acUp = 1
    acDown = 2
    acLeft = 3
    acRight = 4
    acBomb = 5

func actionOfDir*(dir: int): Action {.inline.} =
  case dir
  of 0: acUp
  of 1: acDown
  of 2: acLeft
  of 3: acRight
  else: acStay

func dirOfAction*(action: Action): int {.inline.} =
  case action
  of acUp: 0
  of acDown: 1
  of acLeft: 2
  of acRight: 3
  else: -1

func passableNow*(sim: SimServer, x, y: int): bool =
  ## Walkable at this instant: passage terrain (an item lies ON passage), no
  ## bomb, no living bomber, no flame.
  if not isPassage(sim.board, x, y):
    return false
  if sim.board.flame[cellIndex(x, y)] > 0:
    return false
  if bombIndexAt(sim.bombs, x, y) >= 0:
    return false
  sim.bomberAt(x, y) < 0

func exitsOf*(sim: SimServer, x, y: int): int =
  for offset in DirOffsets:
    if isPassage(sim.board, x + offset.dx, y + offset.dy):
      inc result

proc nearestEnemy*(sim: SimServer, seat: int): int =
  ## The nearest living enemy by Manhattan distance, ties by lowest seat index.
  ## -1 when the other team is wiped.
  result = -1
  var best = 0
  let me = sim.bombers[seat]
  for other in 0 ..< SeatCount:
    if teamOfSeat(other) == teamOfSeat(seat) or not sim.bombers[other].alive:
      continue
    let d = manhattan(me.x, me.y, sim.bombers[other].x, sim.bombers[other].y)
    if result < 0 or d < best:
      result = other
      best = d

proc bfsStep*(
  sim: SimServer, fromX, fromY, toX, toY: int
): tuple[found: bool, dir: int, steps: int] =
  ## The first step of the shortest path from (fromX, fromY) to (toX, toY) over
  ## cells passable NOW. Ties break by the fixed direction order, because the
  ## frontier is expanded in that order and a cell is claimed once.
  result = (false, -1, 0)
  if fromX == toX and fromY == toY:
    return (true, -1, 0)
  var
    firstDir = newSeq[int](BoardCells)
    dist = newSeq[int](BoardCells)
    queue = newSeq[int](0)
  for cell in 0 ..< BoardCells:
    firstDir[cell] = -2
    dist[cell] = -1
  let start = cellIndex(fromX, fromY)
  firstDir[start] = -1
  dist[start] = 0
  queue.add(start)
  var head = 0
  while head < queue.len:
    let
      at = queue[head]
      cx = at mod BoardSize
      cy = at div BoardSize
    inc head
    for dir, offset in DirOffsets:
      let
        nx = cx + offset.dx
        ny = cy + offset.dy
      if not onBoard(nx, ny):
        continue
      let next = cellIndex(nx, ny)
      if firstDir[next] != -2:
        continue
      if not sim.passableNow(nx, ny):
        continue
      firstDir[next] = (if at == start: dir else: firstDir[at])
      dist[next] = dist[at] + 1
      if nx == toX and ny == toY:
        return (true, firstDir[next], dist[next])
      queue.add(next)
  # Unreachable: step toward the reachable cell that minimises Manhattan
  # distance to the target. If that is the current cell, stay.
  var
    bestDir = -1
    bestDist = manhattan(fromX, fromY, toX, toY)
    bestSteps = 0
  for cell in 0 ..< BoardCells:
    if firstDir[cell] < 0:
      continue
    let
      cx = cell mod BoardSize
      cy = cell div BoardSize
      d = manhattan(cx, cy, toX, toY)
    if d < bestDist or (d == bestDist and bestDir >= 0 and
        dist[cell] < bestSteps):
      bestDir = firstDir[cell]
      bestDist = d
      bestSteps = dist[cell]
  (false, bestDir, bestSteps)

proc escapeStep*(
  sim: SimServer, seat: int, danger: DangerMap
): tuple[found: bool, dir: int] =
  ## Step B, the survival override. BFS over cells passable NOW, up to
  ## `dodgeHorizon`, along a path whose every cell is safe at its own arrival
  ## tick, to the nearest cell that is safe for EVERY t <= horizon. The first
  ## step of that path, or -1 for "stay put is already the best you can do".
  ##
  ## THE OVERRIDE IS NOT A SHIELD: a bomber boxed into a dead end still dies,
  ## which is exactly how Pommerman is won.
  let
    me = sim.bombers[seat]
    horizon = danger.horizon
  var
    firstDir = newSeq[int](BoardCells)
    depth = newSeq[int](BoardCells)
    queue = newSeq[int](0)
  for cell in 0 ..< BoardCells:
    firstDir[cell] = -2
  let start = cellIndex(me.x, me.y)
  firstDir[start] = -1
  depth[start] = 0
  queue.add(start)
  var head = 0
  while head < queue.len:
    let
      at = queue[head]
      cx = at mod BoardSize
      cy = at div BoardSize
      d = depth[at]
    inc head
    if d >= horizon:
      continue
    for dir, offset in DirOffsets:
      let
        nx = cx + offset.dx
        ny = cy + offset.dy
      if not onBoard(nx, ny):
        continue
      let next = cellIndex(nx, ny)
      if firstDir[next] != -2:
        continue
      if not sim.passableNow(nx, ny):
        continue
      if not danger.safeAt(nx, ny, d + 1):
        continue
      firstDir[next] = (if at == start: dir else: firstDir[at])
      depth[next] = d + 1
      if danger.safeThroughout(nx, ny):
        return (true, firstDir[next])
      queue.add(next)
  # No wholly safe cell in reach: take the step that maximises the tick at
  # which the destination first becomes flame, ties by the direction order and
  # then by staying.
  var
    bestDir = -1
    bestWhen = danger.firstDangerAt(me.x, me.y)
  if bestWhen < 0:
    return (true, -1)
  for dir, offset in DirOffsets:
    let
      nx = me.x + offset.dx
      ny = me.y + offset.dy
    if not sim.passableNow(nx, ny):
      continue
    let value = danger.firstDangerAt(nx, ny)
    if value < 0:
      return (true, dir)
    if value > bestWhen:
      bestWhen = value
      bestDir = dir
  (false, bestDir)

proc escapeExistsAfterBomb*(sim: SimServer, seat: int): bool =
  ## "An escape exists": after hypothetically placing the bomb, the Step-B
  ## escape BFS from the bomber's own cell finds a cell safe for all
  ## t <= dodgeHorizon. THIS IS THE ONE PLACE THE CONTROLLER REFUSES A
  ## COMMANDER'S ORDER, and the system prompt says so.
  let me = sim.bombers[seat]
  var projected = sim.bombs
  projected.add(Bomb(
    id: sim.nextBombId, x: me.x, y: me.y, fuse: sim.config.bombFuse,
    blast: me.blast, owner: seat, velocity: vNone, placedTick: sim.tick))
  let danger = dangerMap(sim.board, projected, sim.config, sim.tick,
    sim.config.dodgeHorizon)
  let step = escapeStep(sim, seat, danger)
  if not step.found:
    return false
  if step.dir < 0:
    return danger.safeThroughout(me.x, me.y)
  true

proc nearestWoodApproach*(
  sim: SimServer, seat: int
): tuple[found: bool, x, y: int] =
  ## The nearest passage cell orthogonally adjacent to a wooden wall, by BFS
  ## depth from the bomber, ties by the fixed direction order.
  let me = sim.bombers[seat]
  proc touchesWood(x, y: int): bool =
    for offset in DirOffsets:
      if sim.board.terrainAt(x + offset.dx, y + offset.dy) == tWood:
        return true
    false
  if touchesWood(me.x, me.y):
    return (true, me.x, me.y)
  var
    seen = newSeq[bool](BoardCells)
    queue = newSeq[int](0)
  let start = cellIndex(me.x, me.y)
  seen[start] = true
  queue.add(start)
  var head = 0
  while head < queue.len:
    let
      at = queue[head]
      cx = at mod BoardSize
      cy = at div BoardSize
    inc head
    for offset in DirOffsets:
      let
        nx = cx + offset.dx
        ny = cy + offset.dy
      if not onBoard(nx, ny) or seen[cellIndex(nx, ny)]:
        continue
      if not sim.passableNow(nx, ny):
        continue
      seen[cellIndex(nx, ny)] = true
      if touchesWood(nx, ny):
        return (true, nx, ny)
      queue.add(cellIndex(nx, ny))
  (false, me.x, me.y)

proc nearestItem*(
  sim: SimServer, seat, maxSteps: int
): tuple[found: bool, x, y, steps: int] =
  ## The nearest reachable power-up within `maxSteps`, BFS over cells passable
  ## now, ties by lowest y then lowest x at equal depth.
  let me = sim.bombers[seat]
  var
    seen = newSeq[bool](BoardCells)
    depth = newSeq[int](BoardCells)
    queue = newSeq[int](0)
  let start = cellIndex(me.x, me.y)
  seen[start] = true
  queue.add(start)
  var head = 0
  var bestDepth = -1
  result = (false, me.x, me.y, 0)
  while head < queue.len:
    let
      at = queue[head]
      cx = at mod BoardSize
      cy = at div BoardSize
      d = depth[at]
    inc head
    if bestDepth >= 0 and d > bestDepth:
      break
    if d > maxSteps:
      break
    if sim.board.item[at] != ikNone and at != start:
      if bestDepth < 0 or d < bestDepth or
          (d == bestDepth and (cy < result.y or
            (cy == result.y and cx < result.x))):
        bestDepth = d
        result = (true, cx, cy, d)
    for offset in DirOffsets:
      let
        nx = cx + offset.dx
        ny = cy + offset.dy
      if not onBoard(nx, ny) or seen[cellIndex(nx, ny)]:
        continue
      if not sim.passableNow(nx, ny):
        continue
      seen[cellIndex(nx, ny)] = true
      depth[cellIndex(nx, ny)] = d + 1
      queue.add(cellIndex(nx, ny))

proc hideTarget*(
  sim: SimServer, seat: int, danger: DangerMap
): tuple[x, y: int] =
  ## The reachable cell (<= dodgeHorizon steps) maximising the tick at which it
  ## first becomes dangerous; ties by fewest steps, then by most orthogonal
  ## exits, then by the BFS order.
  let me = sim.bombers[seat]
  var
    seen = newSeq[bool](BoardCells)
    depth = newSeq[int](BoardCells)
    queue = newSeq[int](0)
  let start = cellIndex(me.x, me.y)
  seen[start] = true
  queue.add(start)
  var
    bestX = me.x
    bestY = me.y
    bestWhen = danger.firstDangerAt(me.x, me.y)
    bestSteps = 0
    bestExits = sim.exitsOf(me.x, me.y)
  if bestWhen < 0:
    bestWhen = high(int) div 4
  var head = 0
  while head < queue.len:
    let
      at = queue[head]
      cx = at mod BoardSize
      cy = at div BoardSize
      d = depth[at]
    inc head
    if d >= danger.horizon:
      continue
    for offset in DirOffsets:
      let
        nx = cx + offset.dx
        ny = cy + offset.dy
      if not onBoard(nx, ny) or seen[cellIndex(nx, ny)]:
        continue
      if not sim.passableNow(nx, ny):
        continue
      seen[cellIndex(nx, ny)] = true
      depth[cellIndex(nx, ny)] = d + 1
      queue.add(cellIndex(nx, ny))
      var value = danger.firstDangerAt(nx, ny)
      if value < 0:
        value = high(int) div 4
      let
        steps = d + 1
        exits = sim.exitsOf(nx, ny)
      if value > bestWhen or
          (value == bestWhen and steps < bestSteps) or
          (value == bestWhen and steps == bestSteps and exits > bestExits):
        bestX = nx
        bestY = ny
        bestWhen = value
        bestSteps = steps
        bestExits = exits
  (bestX, bestY)

func inBlastLane*(sim: SimServer, seat, target: int): bool =
  ## The target is on the same row or column within `blast - 1` cells with only
  ## passage between -- the condition `hunt` lays a bomb on.
  let
    me = sim.bombers[seat]
    him = sim.bombers[target]
  if not him.alive:
    return false
  if me.x != him.x and me.y != him.y:
    return false
  let reach = max(0, me.blast - 1)
  let distance = manhattan(me.x, me.y, him.x, him.y)
  if distance == 0 or distance > reach:
    return false
  let
    stepX = (if him.x > me.x: 1 elif him.x < me.x: -1 else: 0)
    stepY = (if him.y > me.y: 1 elif him.y < me.y: -1 else: 0)
  for k in 1 ..< distance:
    if not isPassage(sim.board, me.x + stepX * k, me.y + stepY * k):
      return false
  true

proc targetCell*(
  sim: SimServer, seat: int, danger: DangerMap
): tuple[x, y, bombOk: int] =
  ## Step C: `T(u)`, and whether a bomb may be laid this tick. Returned as
  ## ints so the whole module stays free of bools in the hashed path.
  let
    me = sim.bombers[seat]
    order = sim.directives[seat].order
    firstTickOfTurn =
      (sim.tick - 1) mod max(1, sim.config.turnTicks) == 0
  result = (me.x, me.y, 0)
  case order.kind
  of okGo:
    if isPassage(sim.board, order.x, order.y):
      result = (order.x, order.y, 0)
    else:
      let repaired = nearestPassable(sim.board, order.x, order.y)
      result = (repaired.x, repaired.y, 0)
  of okBomb:
    result = (me.x, me.y, (if firstTickOfTurn: 1 else: 0))
  of okHunt:
    var target = order.target
    if target < 0 or not sim.bombers[target].alive or
        teamOfSeat(target) == teamOfSeat(seat):
      target = sim.nearestEnemy(seat)
    if target < 0:
      let hide = sim.hideTarget(seat, danger)
      result = (hide.x, hide.y, 0)
    else:
      result = (sim.bombers[target].x, sim.bombers[target].y,
        (if sim.inBlastLane(seat, target): 1 else: 0))
  of okBreak:
    let approach = sim.nearestWoodApproach(seat)
    if approach.found:
      result = (approach.x, approach.y,
        (if approach.x == me.x and approach.y == me.y: 1 else: 0))
    else:
      let hide = sim.hideTarget(seat, danger)
      result = (hide.x, hide.y, 0)
  of okHide:
    let hide = sim.hideTarget(seat, danger)
    result = (hide.x, hide.y, 0)
  of okKick:
    result = (me.x, me.y, 0)
  of okFollow:
    let partner = partnerOfSeat(seat)
    if not sim.bombers[partner].alive or
        manhattan(me.x, me.y, sim.bombers[partner].x,
          sim.bombers[partner].y) <= 2:
      let approach = sim.nearestWoodApproach(seat)
      if approach.found:
        result = (approach.x, approach.y,
          (if approach.x == me.x and approach.y == me.y: 1 else: 0))
      else:
        let hide = sim.hideTarget(seat, danger)
        result = (hide.x, hide.y, 0)
    else:
      result = (sim.bombers[partner].x, sim.bombers[partner].y, 0)

proc chooseAction*(sim: SimServer, seat: int, danger: DangerMap): Action =
  ## One action for one living bomber: stay | up | down | left | right | bomb.
  let me = sim.bombers[seat]
  if not me.alive:
    return acStay

  # --- Step B: the survival override, ahead of the order ---------------------
  if danger.firstDangerAt(me.x, me.y) >= 0:
    let escape = escapeStep(sim, seat, danger)
    return actionOfDir(escape.dir)

  let order = sim.directives[seat].order

  # `kick dir`: emit the move so the game's own kick rule fires. Without the
  # kick power-up, or with nothing to shove, the seat behaves as `hide`.
  if order.kind == okKick:
    if order.dir >= 0 and me.kick:
      let
        offset = DirOffsets[order.dir]
        bomb = bombIndexAt(sim.bombs, me.x + offset.dx, me.y + offset.dy)
      if bomb >= 0:
        return actionOfDir(order.dir)

  let target = targetCell(sim, seat, danger)
  if target.bombOk == 1 and me.ammo > 0 and
      bombIndexAt(sim.bombs, me.x, me.y) < 0 and
      escapeExistsAfterBomb(sim, seat):
    return acBomb

  # --- Step D: the step ------------------------------------------------------
  let step = bfsStep(sim, me.x, me.y, target.x, target.y)
  if step.dir < 0:
    return acStay
  # Never walk into a cell that is about to burn when standing still is safe.
  let
    offset = DirOffsets[step.dir]
    nx = me.x + offset.dx
    ny = me.y + offset.dy
  if not danger.safeAt(nx, ny, 1) and danger.safeThroughout(me.x, me.y):
    return acStay
  actionOfDir(step.dir)
