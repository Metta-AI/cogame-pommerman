## Sim unit tests: the whole physics of the game, one rule at a time, plus the
## mechanical gate that keeps floating point out of the hashed path.

import std/[json, monotimes, random, strutils, times, unittest]
import helpers

suite "pommerman sim":

  test "bomb fuse and blast":
    ## 1. A bomb placed at tick t detonates at t + bombFuse; its blast is its
    ## own cell plus blast-1 cells in each direction; it stops BEFORE rigid and
    ## AT AND INCLUDING wood; it passes through passage, power-ups, bombers and
    ## other bombs.
    block fuseLength:
      var sim = openBoard()
      sim.place(0, 5, 5, ammo = 1)
      sim.place(1, 1, 1)
      let placedAt = sim.tick
      sim.setOrder(0, okBomb)
      sim.setOrder(1, okHide)
      ## force the bomb down this tick rather than trusting the controller
      var actions: array[SeatCount, Action]
      actions[0] = acBomb
      inc sim.tick
      sim.resolveTick(actions)
      check sim.bombs.len == 1
      check sim.bombs[0].fuse == sim.config.bombFuse
      var ticks = 0
      while sim.bombs.len > 0 and ticks < 40:
        var idle: array[SeatCount, Action]
        inc sim.tick
        sim.resolveTick(idle)
        inc ticks
      check sim.tick == placedAt + 1 + sim.config.bombFuse

    block footprint:
      var sim = openBoard()
      ## a rigid wall two cells right, a wooden wall two cells left
      sim.board.terrain[cellIndex(7, 5)] = tRigid
      sim.board.terrain[cellIndex(3, 5)] = tWood
      let cells = blastCells(sim.board, 5, 5, 3)
      var seen: seq[string]
      for cell in cells:
        seen.add($cell.x & "," & $cell.y)
      ## own cell
      check "5,5" in seen
      ## right: (6,5) then STOPS BEFORE the rigid (7,5)
      check "6,5" in seen
      check "7,5" notin seen
      ## left: (4,5) then STOPS AT AND INCLUDING the wood (3,5)
      check "4,5" in seen
      check "3,5" in seen
      ## up and down run the full blast-1
      check "5,4" in seen
      check "5,3" in seen
      check "5,6" in seen
      check "5,7" in seen

    block passesThrough:
      var sim = openBoard()
      sim.place(0, 6, 5)
      discard sim.addBomb(1, 4, 5)
      sim.board.item[cellIndex(5, 4)] = ikKick
      let cells = blastCells(sim.board, 5, 5, 3)
      var seen: seq[string]
      for cell in cells:
        seen.add($cell.x & "," & $cell.y)
      check "6,5" in seen and "7,5" in seen      ## through a bomber
      check "4,5" in seen and "3,5" in seen      ## through a bomb
      check "5,4" in seen and "5,3" in seen      ## through a power-up

  test "chain reaction":
    ## Three bombs in a line, only the first fusing: all three detonate on the
    ## same tick. A fourth outside every footprint does not.
    var sim = openBoard()
    sim.place(0, 1, 1)
    sim.place(1, 9, 9)
    discard sim.addBomb(0, 3, 5, fuse = 1, blast = 3)
    discard sim.addBomb(0, 5, 5, fuse = 8, blast = 3)
    discard sim.addBomb(0, 7, 5, fuse = 8, blast = 3)
    discard sim.addBomb(1, 2, 9, fuse = 8, blast = 2)
    var idle: array[SeatCount, Action]
    inc sim.tick
    sim.resolveTick(idle)
    check sim.bombs.len == 1
    check sim.bombs[0].x == 2 and sim.bombs[0].y == 9
    check sim.board.flame[cellIndex(3, 5)] > 0
    check sim.board.flame[cellIndex(5, 5)] > 0
    check sim.board.flame[cellIndex(7, 5)] > 0

    block fixpointTerminates:
      ## The fixpoint terminates with a board full of bombs.
      var packed = openBoard()
      packed.place(0, 1, 1)
      packed.place(1, 9, 9)
      for i in 0 ..< MaxBombs:
        let x = 1 + (i mod 9)
        let y = 3 + (i div 9)
        discard packed.addBomb(0, x, y, fuse = (if i == 0: 1 else: 8), blast = 3)
      var none: array[SeatCount, Action]
      inc packed.tick
      packed.resolveTick(none)
      check packed.bombs.len < MaxBombs

  test "flame lifetime":
    ## A flame kills on the tick it appears and on the next, and is gone on the
    ## third; a bomber that walks onto a live flame dies.
    var sim = openBoard()
    sim.place(0, 5, 5)
    sim.place(2, 1, 9)          ## RED's partner, out of the blast
    sim.place(1, 1, 1)
    sim.place(3, 9, 1)
    discard sim.addBomb(1, 5, 7, fuse = 1, blast = 4)
    var idle: array[SeatCount, Action]
    inc sim.tick
    sim.resolveTick(idle)
    check not sim.bombers[0].alive          ## killed on the tick it appeared
    check sim.board.flame[cellIndex(5, 5)] == sim.config.flameLife - 1
    inc sim.tick
    sim.resolveTick(idle)
    check sim.board.flame[cellIndex(5, 5)] == 0

    block walkIntoFire:
      var walk = openBoard()
      walk.place(0, 5, 4)
      walk.place(2, 1, 9)
      walk.place(1, 1, 1)
      walk.place(3, 9, 1)
      walk.board.flame[cellIndex(5, 5)] = 2
      walk.board.flameOwner[cellIndex(5, 5)] = 1
      var actions: array[SeatCount, Action]
      actions[0] = acDown
      inc walk.tick
      walk.resolveTick(actions)
      check not walk.bombers[0].alive
      check walk.seatKills[1] == 1

  test "wood and power-ups":
    ## Wood in a blast becomes passage, is credited ONCE to the bomb owner's
    ## team, and reveals its hidden power-up ON that cell; a power-up already
    ## lying in a blast is destroyed; walking onto one applies and consumes it;
    ## ammo and blast cap.
    block revealAndCredit:
      var sim = openBoard()
      sim.place(0, 5, 5)
      sim.place(1, 1, 1)
      sim.board.terrain[cellIndex(5, 4)] = tWood
      sim.board.hidden[cellIndex(5, 4)] = ikIncrRange
      sim.board.item[cellIndex(5, 6)] = ikExtraBomb
      discard sim.addBomb(0, 5, 5, fuse = 1, blast = 3)
      var idle: array[SeatCount, Action]
      inc sim.tick
      sim.resolveTick(idle)
      check sim.board.terrain[cellIndex(5, 4)] == tPassage
      check sim.board.item[cellIndex(5, 4)] == ikIncrRange   ## survives
      check sim.board.item[cellIndex(5, 6)] == ikNone        ## destroyed
      check sim.teamWood[TeamRed] == 1
      check sim.woodCleared[0] == 1
      check sim.teamWood[TeamBlue] == 0

    block pickupApplies:
      var sim = openBoard()
      sim.place(0, 5, 5, ammo = 1, blast = 2)
      sim.place(1, 1, 1)
      sim.board.item[cellIndex(6, 5)] = ikExtraBomb
      var actions: array[SeatCount, Action]
      actions[0] = acRight
      inc sim.tick
      sim.resolveTick(actions)
      check sim.bombers[0].x == 6
      check sim.bombers[0].ammo == 2
      check sim.board.item[cellIndex(6, 5)] == ikNone
      check sim.pickups[0] == 1

    block caps:
      var sim = openBoard()
      sim.place(0, 5, 5, ammo = sim.config.maxAmmo,
        blast = sim.config.maxBlast)
      sim.place(1, 1, 1)
      sim.board.item[cellIndex(6, 5)] = ikExtraBomb
      sim.board.item[cellIndex(7, 5)] = ikIncrRange
      var right: array[SeatCount, Action]
      right[0] = acRight
      inc sim.tick
      sim.resolveTick(right)
      inc sim.tick
      sim.resolveTick(right)
      check sim.bombers[0].ammo == sim.config.maxAmmo
      check sim.bombers[0].blast == sim.config.maxBlast

  test "movement":
    ## A move into rigid or wood fails; two bombers into one cell resolve
    ## lower-seat-wins; no swaps; a bomber that places a bomb does not move.
    block intoWall:
      var sim = openBoard()
      sim.place(0, 5, 5)
      sim.place(1, 1, 1)
      sim.board.terrain[cellIndex(6, 5)] = tRigid
      sim.board.terrain[cellIndex(5, 6)] = tWood
      var actions: array[SeatCount, Action]
      actions[0] = acRight
      inc sim.tick
      sim.resolveTick(actions)
      check sim.bombers[0].x == 5
      actions[0] = acDown
      inc sim.tick
      sim.resolveTick(actions)
      check sim.bombers[0].y == 5

    block contested:
      var sim = openBoard()
      sim.place(0, 4, 5)
      sim.place(2, 6, 5)
      sim.place(1, 1, 1)
      sim.place(3, 9, 9)
      var actions: array[SeatCount, Action]
      actions[0] = acRight
      actions[2] = acLeft
      inc sim.tick
      sim.resolveTick(actions)
      check sim.bombers[0].x == 5      ## the LOWER seat wins
      check sim.bombers[2].x == 6

    block noSwap:
      var sim = openBoard()
      sim.place(0, 4, 5)
      sim.place(2, 5, 5)
      sim.place(1, 1, 1)
      sim.place(3, 9, 9)
      var actions: array[SeatCount, Action]
      actions[0] = acRight
      actions[2] = acLeft
      inc sim.tick
      sim.resolveTick(actions)
      check sim.bombers[0].x == 4
      check sim.bombers[2].x == 5

    block bombingDoesNotMove:
      var sim = openBoard()
      sim.place(0, 5, 5, ammo = 1)
      sim.place(1, 1, 1)
      var actions: array[SeatCount, Action]
      actions[0] = acBomb
      inc sim.tick
      sim.resolveTick(actions)
      check sim.bombers[0].x == 5 and sim.bombers[0].y == 5
      check sim.bombs.len == 1
      check sim.bombers[0].ammo == 0

    block bombDegradesToStay:
      ## No ammo: the action degrades to `stay`, it does not move.
      var sim = openBoard()
      sim.place(0, 5, 5, ammo = 0)
      sim.place(1, 1, 1)
      var actions: array[SeatCount, Action]
      actions[0] = acBomb
      inc sim.tick
      sim.resolveTick(actions)
      check sim.bombs.len == 0
      check sim.bombers[0].x == 5

  test "kick":
    block kicks:
      var sim = openBoard()
      sim.place(0, 4, 5, kick = true)
      sim.place(1, 1, 1)
      discard sim.addBomb(1, 5, 5, fuse = 8)
      var actions: array[SeatCount, Action]
      actions[0] = acRight
      inc sim.tick
      sim.resolveTick(actions)
      check sim.bombs[0].velocity == vRight
      check sim.bombers[0].x == 4          ## the kicker does not move
      check sim.kicks[0] == 1
      ## a moving bomb advances one cell a tick
      var idle: array[SeatCount, Action]
      inc sim.tick
      sim.resolveTick(idle)
      check sim.bombs[0].x == 6
      inc sim.tick
      sim.resolveTick(idle)
      check sim.bombs[0].x == 7

    block noKickPowerUp:
      var sim = openBoard()
      sim.place(0, 4, 5, kick = false)
      sim.place(1, 1, 1)
      discard sim.addBomb(1, 5, 5)
      var actions: array[SeatCount, Action]
      actions[0] = acRight
      inc sim.tick
      sim.resolveTick(actions)
      check sim.bombs[0].velocity == vNone
      check sim.bombers[0].x == 4
      check sim.kicks[0] == 0

    block farCellBlocked:
      var sim = openBoard()
      sim.place(0, 4, 5, kick = true)
      sim.place(1, 6, 5)
      discard sim.addBomb(1, 5, 5)
      var actions: array[SeatCount, Action]
      actions[0] = acRight
      inc sim.tick
      sim.resolveTick(actions)
      check sim.bombs[0].velocity == vNone

    block stopsAtObstruction:
      var sim = openBoard()
      sim.place(0, 1, 1)
      sim.place(1, 9, 9)
      sim.board.terrain[cellIndex(7, 5)] = tRigid
      discard sim.addBomb(0, 5, 5, fuse = 20, velocity = vRight)
      var idle: array[SeatCount, Action]
      inc sim.tick
      sim.resolveTick(idle)
      check sim.bombs[0].x == 6
      inc sim.tick
      sim.resolveTick(idle)
      check sim.bombs[0].x == 6
      check sim.bombs[0].velocity == vNone

    block neverEntersFlame:
      var sim = openBoard()
      sim.place(0, 1, 1)
      sim.place(1, 9, 9)
      sim.board.flame[cellIndex(6, 5)] = 2
      sim.board.flameOwner[cellIndex(6, 5)] = 1
      discard sim.addBomb(0, 5, 5, fuse = 20, velocity = vRight)
      var idle: array[SeatCount, Action]
      inc sim.tick
      sim.resolveTick(idle)
      check sim.bombs[0].x == 5
      check sim.bombs[0].velocity == vNone

  test "simultaneous death":
    ## Two bombers on flames from the same detonation both die in one step;
    ## mutual team annihilation is a draw; `cause` is right and `kills`
    ## increments ONLY for a cross-team victim.
    block bothDie:
      var sim = openBoard()
      sim.place(0, 4, 5)
      sim.place(1, 6, 5)
      sim.place(2, 1, 1)
      sim.place(3, 9, 9)
      discard sim.addBomb(0, 5, 5, fuse = 1, blast = 3)
      var idle: array[SeatCount, Action]
      inc sim.tick
      sim.resolveTick(idle)
      check not sim.bombers[0].alive
      check not sim.bombers[1].alive
      check sim.lastDeaths.len == 2
      var causes: seq[string]
      for death in sim.lastDeaths:
        causes.add(death.cause)
      check "suicide" in causes
      check "bomb" in causes
      check sim.teamKills[TeamRed] == 1     ## only the cross-team victim
      check sim.teamKills[TeamBlue] == 0
      check sim.seatSuicides[0] == 1

    block friendlyFire:
      var sim = openBoard()
      sim.place(0, 5, 5)
      sim.place(2, 5, 6)
      sim.place(1, 1, 1)
      sim.place(3, 9, 9)
      discard sim.addBomb(0, 5, 4, fuse = 1, blast = 4)
      var idle: array[SeatCount, Action]
      inc sim.tick
      sim.resolveTick(idle)
      check not sim.bombers[2].alive
      var cause = ""
      for death in sim.lastDeaths:
        if death.victim == 2: cause = death.cause
      check cause == "friendlyfire"
      check sim.teamKills[TeamRed] == 0

    block mutualWipeIsADraw:
      var sim = openBoard()
      sim.place(0, 4, 5)
      sim.place(2, 4, 6)
      sim.place(1, 6, 5)
      sim.place(3, 6, 6)
      discard sim.addBomb(0, 5, 5, fuse = 1, blast = 4)
      discard sim.addBomb(0, 5, 6, fuse = 1, blast = 4)
      var idle: array[SeatCount, Action]
      inc sim.tick
      sim.resolveTick(idle)
      check sim.aliveOnTeam(TeamRed) == 0
      check sim.aliveOnTeam(TeamBlue) == 0
      check sim.endRule == EndRuleWipe
      check sim.scoreOf(0) == 0
      check sim.scoreOf(1) == 0

  test "ammo return":
    ## An owner regains ammo exactly when its bomb detonates, and never when a
    ## collapse removes it.
    block onDetonation:
      var sim = openBoard()
      sim.place(0, 1, 1, ammo = 1)
      sim.place(1, 9, 9)
      discard sim.addBomb(0, 5, 5, fuse = 1)
      var idle: array[SeatCount, Action]
      inc sim.tick
      sim.resolveTick(idle)
      check sim.bombers[0].ammo == 2

    block notOnCollapse:
      var sim = openBoard()
      sim.place(0, 5, 5, ammo = 1)
      sim.place(1, 5, 6)
      discard sim.addBomb(0, 1, 5, fuse = 20)   ## ring 1
      sim.applyCollapse(1)
      check sim.bombs.len == 0
      check sim.bombers[0].ammo == 1

  test "collapse":
    var sim = openBoard()
    sim.place(0, 1, 5)          ## ring 1
    sim.place(1, 2, 5)          ## ring 2
    sim.place(2, 5, 5)
    sim.place(3, 6, 6)
    sim.board.item[cellIndex(1, 4)] = ikKick
    discard sim.addBomb(2, 1, 6, fuse = 20)
    sim.applyCollapse(1)
    check not sim.bombers[0].alive
    check sim.lastDeaths[0].cause == "crushed"
    check sim.board.terrain[cellIndex(1, 5)] == tRigid
    check sim.board.item[cellIndex(1, 4)] == ikNone
    check sim.bombs.len == 0
    check sim.board.flame[cellIndex(1, 6)] == 0
    sim.applyCollapse(2)
    check not sim.bombers[1].alive
    for y in 0 ..< BoardSize:
      for x in 0 ..< BoardSize:
        if ringOf(x, y) <= 2:
          check sim.board.terrain[cellIndex(x, y)] == tRigid
    ## the playable set afterwards is the middle 5x5
    for y in 3 .. 7:
      for x in 3 .. 7:
        check ringOf(x, y) >= 3

  test "radio isolation":
    ## The pair a seat sends on turn T reaches ONLY its partner and ONLY on
    ## turn T+1; over 500 randomised turns no observation for a seat on team t
    ## ever contains a pair sent by a seat on the other team; a fallback seat
    ## still sends a pair.
    var rng = initRand(31337)
    var sim = playingSim()
    var engine = initDecisionEngine(sim.config)
    var sent: array[SeatCount, RadioPair]
    for turn in 1 .. 500:
      sim.mailbox.deliver()
      for seat in 0 ..< SeatCount:
        let inbox = sim.mailbox.receive(teamOfSeat(seat), seat)
        if turn == 1:
          check not inbox.has
        else:
          check inbox.has
          check inbox.pair == sent[partnerOfSeat(seat)]
      for seat in 0 ..< SeatCount:
        var directive = defaultDirective()
        directive.radio = clampPair(rng.rand(1 .. 8), rng.rand(1 .. 8))
        sent[seat] = directive.radio
        sim.applyOrders(seat, directive)
      ## the observation NEVER carries a cross-team pair
      for seat in 0 ..< SeatCount:
        let view = engine.seatView(sim, seat, includeNotes = false)
        let incoming = view["radio_from_teammate"]
        if incoming.kind != JNull:
          check incoming[0].getInt() == sim.mailbox.delivered[seat].a
          check incoming[1].getInt() == sim.mailbox.delivered[seat].b
    ## a read indexed by a seat on the wrong team RAISES rather than leaking
    expect SimGuardError:
      discard sim.mailbox.receive(TeamRed, 1)
    expect SimGuardError:
      var box = sim.mailbox
      box.send(TeamBlue, 0, defaultPair())

    block fallbackStillSends:
      var run = playingSim()
      let before = run.mailbox.sentCount[0]
      run.applyOrders(0, fallbackDirective(run, 0))
      check run.mailbox.sentCount[0] == before + 1

  test "scoring is zero-sum":
    ## Over 500 randomised end states the four seat scores sum to zero, the
    ## sign is right, both seats of a team hold the identical score, and a
    ## mutual wipe with equal wood is a draw.
    var rng = initRand(7)
    for _ in 0 ..< 500:
      var sim = initSimServer(testConfig())
      sim.applyGameStart(0)
      for seat in 0 ..< SeatCount:
        sim.bombers[seat].alive = rng.rand(0 .. 1) == 1
      sim.teamWood = [rng.rand(0 .. 36), rng.rand(0 .. 36)]
      sim.teamKills = [rng.rand(0 .. 2), rng.rand(0 .. 2)]
      sim.bankGame(EndRuleTickCap)
      var total = 0
      for seat in 0 ..< SeatCount:
        total += sim.scoreOf(seat)
      check total == 0
      check sim.scoreOf(0) == sim.scoreOf(2)
      check sim.scoreOf(1) == sim.scoreOf(3)
      check sim.scoreOf(0) == -sim.scoreOf(1)
      let
        red = sim.gameLog[^1].alive[TeamRed]
        blue = sim.gameLog[^1].alive[TeamBlue]
      if red > blue:
        check sim.scoreOf(0) > 0
      elif red < blue:
        check sim.scoreOf(0) < 0

    block mutualDraw:
      var sim = initSimServer(testConfig())
      sim.applyGameStart(0)
      for seat in 0 ..< SeatCount:
        sim.bombers[seat].alive = false
      sim.teamWood = [11, 11]
      sim.bankGame(EndRuleWipe)
      check sim.scoreOf(0) == 0
      check sim.winnerTeam() < 0

  test "end conditions":
    block teamWipe:
      var sim = openBoard()
      sim.place(0, 1, 1)
      sim.place(2, 9, 1)
      sim.place(1, 5, 5)
      sim.place(3, 5, 6)
      discard sim.addBomb(0, 5, 4, fuse = 1, blast = 4)
      var idle: array[SeatCount, Action]
      inc sim.tick
      sim.resolveTick(idle)
      check sim.endRule == EndRuleWipe
      check sim.phase == GameOver
      check sim.winnerTeam() == TeamRed
      check sim.gameLog[^1].alive == [2, 0]

    block tickCap:
      var config = testConfig(maxTicks = 8)
      config.collapseTicks = @[]
      var sim = initSimServer(config)
      sim.applyGameStart(0)
      var idle: array[SeatCount, Action]
      for _ in 0 ..< 8:
        inc sim.tick
        sim.resolveTick(idle)
      check sim.endRule == EndRuleTickCap
      check sim.phase == GameOver
      check sim.gameLog[^1].alive == [2, 2]
      check sim.winnerTeam() < 0

    block wallClock:
      var sim = playingSim()
      sim.applyStop(EndRuleWallClock)
      check sim.endRule == EndRuleWallClock
      check sim.gameLog.len == 1
      check sim.gameLog[^1].endRule == EndRuleWallClock

    block fault:
      var sim = playingSim()
      sim.applyStop(EndRuleFault)
      check sim.gameLog[^1].endRule == EndRuleFault

  test "no floating point in the sim":
    ## The integer-determinism pin, mechanically enforced: no `float`, no
    ## `sqrt` and no float literal in the modules that produce the hash.
    for name in ["sim", "board", "bombs", "control", "baselines"]:
      let code = stripNimComments(
        readRepoFile("src/pommerman/" & name & ".nim"))
      checkpoint(name & ".nim")
      check "float" notin code
      check "sqrt" notin code
      for line in code.splitLines():
        for i in 1 ..< max(1, line.len - 1):
          if line[i] == '.' and line[i - 1] in {'0' .. '9'} and
              line[i + 1] in {'0' .. '9'}:
            checkpoint("float literal in " & name & ".nim: " & line)
            fail()

  test "tick budget":
    ## A full 144-tick episode completes well inside a second in a release
    ## build.
    let started = getMonoTime()
    var sim = playingSim()
    var ticks = 0
    while sim.phase == Playing and ticks < 144:
      sim.step()
      inc ticks
    let elapsed = (getMonoTime() - started).inMilliseconds.int
    checkpoint("144 ticks in " & $elapsed & " ms")
    ## The note's budget is "< 1 s in a release build"; ci.yml runs every test
    ## in BOTH modes, and a debug build carries range/overflow checks and no
    ## optimisation, so the bound is the release one where it applies. Measured
    ## on this machine: 1-3 ms release, ~20 ms debug -- both bounds are two to
    ## three orders of magnitude of headroom, not a tolerance to be widened.
    when defined(release):
      check elapsed < 1000
    else:
      check elapsed < 4000
