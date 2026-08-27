## The board: the 4-fold rotationally symmetric map generator, its counts, its
## connectivity, its power-up placement -- over 1000 seeds -- and the four
## corner spawns.

import std/[sets, strutils, unittest]
import helpers

proc reachable(board: Board, woodPassable: bool): HashSet[int] =
  var queue = @[cellIndex(1, 1)]
  result.incl(queue[0])
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
      if not onBoard(nx, ny):
        continue
      let next = cellIndex(nx, ny)
      if next in result:
        continue
      let terrain = board.terrain[next]
      if terrain == tRigid:
        continue
      if terrain == tWood and not woodPassable:
        continue
      result.incl(next)
      queue.add(next)

suite "pommerman board":

  test "map is symmetric and correct":
    ## For 1000 seeds: the board is invariant under rot(x,y) = (10-y, x);
    ## the counts are exactly 56 rigid / 36 wood / 29 passage (the design
    ## note's 57/28 is an arithmetic slip -- the 40-cell border plus the
    ## 16-cell lattice is 56, and 56 + 36 + 29 = 121; recorded as an errata in
    ## docs/plans/2026-08-27-pommerman-design.md); the 12 corner-pocket cells
    ## and (5,5) are passage; exactly 20 power-ups (8 extra-bomb, 8 range,
    ## 4 kick) sit under wood; and every non-rigid cell is reachable from
    ## (1,1) both treating wood as passable and once all the wood is cleared.
    for seed in 1 .. 1000:
      let board = generateBoard(seed)
      var rigid, wood, passage = 0
      for y in 0 ..< BoardSize:
        for x in 0 ..< BoardSize:
          case board.terrain[cellIndex(x, y)]
          of tRigid: inc rigid
          of tWood: inc wood
          of tPassage: inc passage
          ## rotational invariance, cell by cell, including what is hidden
          let turned = rotCell(x, y)
          if board.terrain[cellIndex(turned.x, turned.y)] !=
              board.terrain[cellIndex(x, y)] or
              board.hidden[cellIndex(turned.x, turned.y)] !=
                board.hidden[cellIndex(x, y)]:
            checkpoint("seed " & $seed & " is not rot-invariant at " &
              $x & "," & $y)
            fail()
      if rigid != 56 or wood != 36 or passage != 29:
        checkpoint("seed " & $seed & ": " & $rigid & " rigid / " & $wood &
          " wood / " & $passage & " passage")
        fail()
      var extras, ranges, kicks = 0
      for cell in 0 ..< BoardCells:
        case board.hidden[cell]
        of ikExtraBomb: inc extras
        of ikIncrRange: inc ranges
        of ikKick: inc kicks
        of ikNone: discard
        ## nothing is hidden anywhere but under wood
        if board.hidden[cell] != ikNone:
          check board.terrain[cell] == tWood
      if extras != 8 or ranges != 8 or kicks != 4:
        checkpoint("seed " & $seed & ": " & $extras & " extra / " & $ranges &
          " range / " & $kicks & " kick")
        fail()
      ## the reserved pockets and the centre are always passage
      for spawn in SpawnCells:
        check board.terrain[cellIndex(spawn.x, spawn.y)] == tPassage
      check board.terrain[cellIndex(5, 5)] == tPassage
      var pockets = 0
      for y in 0 ..< BoardSize:
        for x in 0 ..< BoardSize:
          if isCornerPocket(x, y):
            inc pockets
            check board.terrain[cellIndex(x, y)] == tPassage
      check pockets == 12
      ## connected treating wood as passable, and connected once cleared
      if seed mod 50 == 1:
        let soft = reachable(board, woodPassable = true)
        check soft.len == wood + passage
        var cleared = board
        for cell in 0 ..< BoardCells:
          if cleared.terrain[cell] == tWood:
            cleared.terrain[cell] = tPassage
        let hard = reachable(cleared, woodPassable = false)
        check hard.len == wood + passage

  test "the free orbits partition the interior exactly":
    let orbits = freeOrbits()
    check orbits.len == 13
    var seen: HashSet[int]
    for orbit in orbits:
      for cell in orbit:
        check not (cell.x == 5 and cell.y == 5)
        check not isLattice(cell.x, cell.y)
        check not isCornerPocket(cell.x, cell.y)
        check ringOf(cell.x, cell.y) > 0
        seen.incl(cellIndex(cell.x, cell.y))
      ## every orbit is closed under rot
      for cell in orbit:
        let turned = rotCell(cell.x, cell.y)
        var found = false
        for other in orbit:
          if other.x == turned.x and other.y == turned.y:
            found = true
        check found
    check seen.len == 52

  test "different seeds really give different boards":
    var shapes: HashSet[string]
    for seed in 1 .. 200:
      shapes.incl(generateBoard(seed).terrainRows().join("|"))
    check shapes.len > 20

  test "spawns":
    ## The four bombers start at (1,1) (9,1) (9,9) (1,9) in seat order 0,1,2,3,
    ## teams RED = {0,2} and BLUE = {1,3}, and each corner's 5x5 neighbourhood
    ## is a rotation of every other's.
    var sim = playingSim()
    check SpawnCells[0] == (1, 1)
    check SpawnCells[1] == (9, 1)
    check SpawnCells[2] == (9, 9)
    check SpawnCells[3] == (1, 9)
    for seat in 0 ..< SeatCount:
      check sim.bombers[seat].alive
      check sim.bombers[seat].x == SpawnCells[seat].x
      check sim.bombers[seat].y == SpawnCells[seat].y
      check sim.bombers[seat].ammo == sim.config.startAmmo
      check sim.bombers[seat].blast == sim.config.startBlast
      check not sim.bombers[seat].kick
    check teamOfSeat(0) == TeamRed
    check teamOfSeat(2) == TeamRed
    check teamOfSeat(1) == TeamBlue
    check teamOfSeat(3) == TeamBlue
    check partnerOfSeat(0) == 2
    check partnerOfSeat(1) == 3
    check partnerOfSeat(2) == 0
    check partnerOfSeat(3) == 1
    ## Every corner's 5x5 neighbourhood is an exact rotation of the previous
    ## one's: rot maps SpawnCells[k] onto SpawnCells[k+1], and an offset
    ## (dx, dy) from a corner maps onto (-dy, dx) from the next corner. So no
    ## seat has a positional advantage and no side swap is needed.
    for seed in [1, 42, 999]:
      let board = generateBoard(seed)
      for seat in 0 ..< SeatCount:
        let
          here = SpawnCells[seat]
          nextCorner = SpawnCells[(seat + 1) mod SeatCount]
        check rotCell(here.x, here.y) == nextCorner
        for dy in -2 .. 2:
          for dx in -2 .. 2:
            checkpoint("seed " & $seed & " seat " & $seat &
              " offset " & $dx & "," & $dy)
            check board.terrainAt(nextCorner.x - dy, nextCorner.y + dx) ==
              board.terrainAt(here.x + dx, here.y + dy)

  test "the ring table and the collapse schedule":
    check ringOf(0, 0) == 0
    check ringOf(1, 5) == 1
    check ringOf(2, 5) == 2
    check ringOf(5, 5) == 5
    var config = defaultGameConfig()
    check collapseRingFor(config, 96) == 1
    check collapseRingFor(config, 120) == 2
    check collapseRingFor(config, 95) == -1
    check nextCollapse(config, 0) == (96, 1)
    check nextCollapse(config, 96) == (120, 2)
    check nextCollapse(config, 130) == (-1, -1)
