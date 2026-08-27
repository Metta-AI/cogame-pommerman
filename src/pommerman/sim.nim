## The tick loop: the WHOLE physics of the game and nothing else mutates the
## world. Re-exports the sim modules, so `import pommerman/sim` sees
## everything -- the starter's layout, kept, and the reason the SAME module
## compiles natively for the server and to wasm for the replay viewer.
##
## PURE INTEGER (see board.nim). Every rule reads the snapshot taken at the top
## of the tick, never a partially updated world; every tie breaks by the fixed
## direction order and then by ascending seat id.

import sim_types, sim_config, board, bombs, radio, directives, events,
  sim_state, control

export sim_types, sim_config, board, bombs, radio, directives, events,
  sim_state, control

proc evaluateEnd*(sim: var SimServer) =
  ## Checked at the end of a tick. Team wipe first (both at once is a draw),
  ## then the tick cap.
  if sim.phase != Playing:
    return
  let
    red = sim.aliveOnTeam(TeamRed)
    blue = sim.aliveOnTeam(TeamBlue)
  if red == 0 or blue == 0:
    sim.wipedTeam =
      if red == 0 and blue == 0: TeamCount
      elif red == 0: TeamRed
      else: TeamBlue
    sim.bankGame(EndRuleWipe)
  elif sim.tick >= sim.config.maxTicks:
    sim.bankGame(EndRuleTickCap)

proc applyStop*(sim: var SimServer, endRule: string) =
  ## The load-bearing stop. A wall-clock or fault stop cannot be re-derived
  ## from sim state, so it is written to the replay as ONE record and applied
  ## by THIS proc on record AND on playback -- which is what keeps the hash
  ## chain clean at the stop tick (the particle-worlds scar).
  if sim.phase == GameOver:
    return
  sim.bankGame(endRule)

proc chooseActions*(sim: SimServer, danger: DangerMap): array[SeatCount, Action] =
  ## One action per living bomber, in ascending seat order, from the snapshot
  ## world -- no rule in `resolveTick` reads a partially updated board.
  for seat in 0 ..< SeatCount:
    result[seat] =
      if sim.bombers[seat].alive: chooseAction(sim, seat, danger)
      else: acStay

proc applyCollapse(sim: var SimServer, ring: int) =
  ## Step 2. Done FIRST so nothing else acts on a cell that is about to be
  ## wall: a living bomber there dies `crushed`, a bomb there is removed
  ## without detonating, a power-up there is destroyed, a flame there clears.
  sim.lastCollapse = ring
  sim.board.collapseRing(ring)
  var kept: seq[Bomb]
  for bomb in sim.bombs:
    if ringOf(bomb.x, bomb.y) == ring:
      continue
    kept.add(bomb)
  sim.bombs = kept
  for seat in 0 ..< SeatCount:
    if not sim.bombers[seat].alive:
      continue
    if ringOf(sim.bombers[seat].x, sim.bombers[seat].y) != ring:
      continue
    sim.bombers[seat].alive = false
    inc sim.seatDeaths[seat]
    sim.lastDeaths.add(DeathRecord(
      tick: sim.tick, victim: seat, killer: -1,
      x: sim.bombers[seat].x, y: sim.bombers[seat].y, cause: "crushed"))
    sim.emitEvent(Death, source = -1, target = seat,
      x = sim.bombers[seat].x, y = sim.bombers[seat].y, detail = "crushed")
  sim.emitEvent(Collapse, amount = ring)

proc resolveTick*(sim: var SimServer, actions: array[SeatCount, Action]) =
  ## Steps 4-13 of one tick, given the actions. Split out from `step` so a unit
  ## test can force an action the deterministic controller would never choose.
  if sim.phase != Playing:
    return

  # --- 4. bomb placement, ascending seat -----------------------------------
  var placed: array[SeatCount, bool]
  for seat in 0 ..< SeatCount:
    if not sim.bombers[seat].alive or actions[seat] != acBomb:
      continue
    let me = sim.bombers[seat]
    if me.ammo <= 0 or bombIndexAt(sim.bombs, me.x, me.y) >= 0:
      continue          ## the action degrades to `stay`
    sim.bombs.add(Bomb(
      id: sim.nextBombId, x: me.x, y: me.y, fuse: sim.config.bombFuse,
      blast: me.blast, owner: seat, velocity: vNone, placedTick: sim.tick))
    inc sim.nextBombId
    dec sim.bombers[seat].ammo
    inc sim.bombsPlaced[seat]
    placed[seat] = true
    sim.lastBombs.add(BombRecord(
      tick: sim.tick, seat: seat, x: me.x, y: me.y,
      fuse: sim.config.bombFuse, blast: me.blast))
    sim.emitEvent(BombPlaced, source = seat, x = me.x, y = me.y,
      amount = sim.config.bombFuse)

  # --- 5. kicked-bomb movement, ascending bomb id --------------------------
  for index in 0 ..< sim.bombs.len:
    let dir = dirOfVelocity(sim.bombs[index].velocity)
    if dir < 0:
      continue
    let
      offset = DirOffsets[dir]
      nx = sim.bombs[index].x + offset.dx
      ny = sim.bombs[index].y + offset.dy
    var blocked = not isPassage(sim.board, nx, ny)
    if not blocked and sim.board.flame[cellIndex(nx, ny)] > 0:
      blocked = true
    if not blocked and bombIndexAt(sim.bombs, nx, ny) >= 0:
      blocked = true
    if not blocked and sim.bomberAt(nx, ny) >= 0:
      blocked = true
    if blocked:
      sim.bombs[index].velocity = vNone
    else:
      sim.bombs[index].x = nx
      sim.bombs[index].y = ny

  # --- 6. bomber movement, ascending seat, from the SNAPSHOT positions -----
  var occupied: array[BoardCells, bool]
  for seat in 0 ..< SeatCount:
    if sim.bombers[seat].alive:
      occupied[cellIndex(sim.bombers[seat].x, sim.bombers[seat].y)] = true
  for seat in 0 ..< SeatCount:
    if not sim.bombers[seat].alive or placed[seat]:
      continue
    let dir = dirOfAction(actions[seat])
    if dir < 0:
      continue
    let
      me = sim.bombers[seat]
      offset = DirOffsets[dir]
      nx = me.x + offset.dx
      ny = me.y + offset.dy
    if not onBoard(nx, ny):
      continue
    let terrain = sim.board.terrain[cellIndex(nx, ny)]
    if terrain != tPassage:
      continue                                  ## rigid or wood: the move fails
    let bomb = bombIndexAt(sim.bombs, nx, ny)
    if bomb >= 0:
      ## A bomb in the way: kick it iff the mover has `kick` AND the cell one
      ## further in the same direction is clear. THE KICKER DOES NOT MOVE.
      let
        fx = nx + offset.dx
        fy = ny + offset.dy
      if me.kick and isPassage(sim.board, fx, fy) and
          sim.board.flame[cellIndex(fx, fy)] == 0 and
          bombIndexAt(sim.bombs, fx, fy) < 0 and sim.bomberAt(fx, fy) < 0:
        sim.bombs[bomb].velocity = velocityOfDir(dir)
        inc sim.kicks[seat]
        sim.lastKicks.add(KickRecord(
          tick: sim.tick, seat: seat, x: nx, y: ny, dir: dir))
        sim.emitEvent(BombKicked, source = seat, x = nx, y = ny,
          detail = DirNames[dir])
      continue
    if occupied[cellIndex(nx, ny)]:
      continue                                  ## no swaps, lower seat wins
    occupied[cellIndex(nx, ny)] = true
    sim.bombers[seat].x = nx
    sim.bombers[seat].y = ny
    let item = sim.board.item[cellIndex(nx, ny)]
    if item != ikNone:
      sim.board.item[cellIndex(nx, ny)] = ikNone
      case item
      of ikExtraBomb:
        sim.bombers[seat].ammo =
          min(sim.config.maxAmmo, sim.bombers[seat].ammo + 1)
      of ikIncrRange:
        sim.bombers[seat].blast =
          min(sim.config.maxBlast, sim.bombers[seat].blast + 1)
      of ikKick:
        sim.bombers[seat].kick = true
      of ikNone: discard
      inc sim.pickups[seat]
      sim.lastPickups.add(PickupRecord(
        tick: sim.tick, seat: seat, x: nx, y: ny, kind: item))
      sim.emitEvent(Pickup, source = seat, x = nx, y = ny, detail = $item)

  # --- 7. fuse tick --------------------------------------------------------
  for index in 0 ..< sim.bombs.len:
    if sim.bombs[index].placedTick != sim.tick:
      dec sim.bombs[index].fuse

  # --- 8. detonation, with chain reaction ----------------------------------
  var detonating = newSeq[bool](sim.bombs.len)
  var any = false
  for index in 0 ..< sim.bombs.len:
    if sim.bombs[index].fuse <= 0:
      detonating[index] = true
      any = true
  if any:
    for _ in 0 ..< sim.bombs.len + 1:
      var grew = false
      for index in 0 ..< sim.bombs.len:
        if not detonating[index]:
          continue
        for cell in blastCells(sim.board, sim.bombs[index].x,
            sim.bombs[index].y, sim.bombs[index].blast):
          let other = bombIndexAt(sim.bombs, cell.x, cell.y)
          if other >= 0 and not detonating[other]:
            detonating[other] = true
            sim.bombs[other].fuse = 0
            grew = true
      if not grew:
        break

    # --- 9. flames and wood -------------------------------------------------
    var owner: array[BoardCells, int]
    for cell in 0 ..< BoardCells:
      owner[cell] = -1
    for index in 0 ..< sim.bombs.len:
      if not detonating[index]:
        continue
      sim.emitEvent(Explosion, source = sim.bombs[index].owner,
        x = sim.bombs[index].x, y = sim.bombs[index].y,
        amount = sim.bombs[index].blast)
      for cell in blastCells(sim.board, sim.bombs[index].x,
          sim.bombs[index].y, sim.bombs[index].blast):
        let at = cellIndex(cell.x, cell.y)
        if owner[at] < 0:
          owner[at] = index
    for at in 0 ..< BoardCells:
      if owner[at] < 0:
        continue
      let
        seat = sim.bombs[owner[at]].owner
        team = teamOfSeat(seat)
        x = at mod BoardSize
        y = at div BoardSize
      if sim.board.terrain[at] == tWood:
        sim.board.terrain[at] = tPassage
        inc sim.teamWood[team]
        inc sim.woodCleared[seat]
        sim.lastWood.add(WoodRecord(tick: sim.tick, x: x, y: y, team: team))
        sim.emitEvent(WoodCleared, source = seat, x = x, y = y, amount = team)
        ## Upstream's rule: the power-up the wall was hiding now LIES on the
        ## cell -- it survives the blast that revealed it.
        if sim.board.hidden[at] != ikNone:
          sim.board.item[at] = sim.board.hidden[at]
          sim.board.hidden[at] = ikNone
      else:
        ## A power-up already lying in a blast cell is destroyed.
        sim.board.item[at] = ikNone
      sim.board.flame[at] = sim.config.flameLife
      sim.board.flameOwner[at] = seat
    var kept: seq[Bomb]
    for index in 0 ..< sim.bombs.len:
      if detonating[index]:
        let seat = sim.bombs[index].owner
        sim.bombers[seat].ammo = min(sim.config.maxAmmo,
          sim.bombers[seat].ammo + 1)
      else:
        kept.add(sim.bombs[index])
    sim.bombs = kept

  # --- 10. deaths, SIMULTANEOUS --------------------------------------------
  var dying: array[SeatCount, bool]
  for seat in 0 ..< SeatCount:
    if not sim.bombers[seat].alive:
      continue
    if sim.board.flame[cellIndex(sim.bombers[seat].x,
        sim.bombers[seat].y)] > 0:
      dying[seat] = true
  for seat in 0 ..< SeatCount:
    if not dying[seat]:
      continue
    let
      at = cellIndex(sim.bombers[seat].x, sim.bombers[seat].y)
      killer = sim.board.flameOwner[at]
    var cause = "bomb"
    if killer == seat:
      cause = "suicide"
      inc sim.seatSuicides[seat]
    elif killer >= 0 and teamOfSeat(killer) == teamOfSeat(seat):
      cause = "friendlyfire"
    sim.bombers[seat].alive = false
    inc sim.seatDeaths[seat]
    ## kills increments ONLY for a victim on the other team: a suicide or a
    ## friendly kill counts nothing and still costs the team a bomber.
    if killer >= 0 and teamOfSeat(killer) != teamOfSeat(seat):
      inc sim.teamKills[teamOfSeat(killer)]
      inc sim.seatKills[killer]
      if sim.firstBloodTick < 0:
        sim.firstBloodTick = sim.tick
        sim.firstBloodKiller = killer
        sim.firstBloodVictim = seat
    sim.lastDeaths.add(DeathRecord(
      tick: sim.tick, victim: seat, killer: killer,
      x: sim.bombers[seat].x, y: sim.bombers[seat].y, cause: cause))
    sim.emitEvent(Death, source = killer, target = seat,
      x = sim.bombers[seat].x, y = sim.bombers[seat].y, detail = cause)

  # --- 11. flame decay ------------------------------------------------------
  for at in 0 ..< BoardCells:
    if sim.board.flame[at] > 0:
      dec sim.board.flame[at]
      if sim.board.flame[at] == 0:
        sim.board.flameOwner[at] = -1

  # --- 13. end conditions ---------------------------------------------------
  sim.evaluateEnd()

proc step*(sim: var SimServer) =
  ## One tick: advance the clock, collapse if due, choose, then resolve.
  if sim.phase != Playing:
    return
  inc sim.tick
  inc sim.episodeTick
  let ring = collapseRingFor(sim.config, sim.tick)
  if ring > 0:
    sim.applyCollapse(ring)
  if sim.phase != Playing:
    return
  let danger = sim.dangerNow()
  sim.resolveTick(sim.chooseActions(danger))

proc clearFrameDeltas*(sim: var SimServer) =
  sim.lastDeaths = @[]
  sim.lastKicks = @[]
  sim.lastPickups = @[]
  sim.lastWood = @[]
  sim.lastBombs = @[]
  sim.lastCollapse = -1

proc applyGameStart*(sim: var SimServer, gameIndex: int) =
  ## Starts one game. Recorded as a `gameStart` record and applied by THIS
  ## proc on record and on playback.
  if gameIndex > 0:
    sim.resetToLobby()
  sim.gameIndex = gameIndex
  sim.startGame()

proc advanceFrame*(sim: var SimServer) =
  ## ONE server frame. The single advance proc both the live loop and the
  ## replay player call, which is what keeps the hash chain aligned across
  ## lobby, play and the game-over hold.
  sim.clearFrameDeltas()
  case sim.phase
  of Lobby: inc sim.lobbyTicks
  of Playing: sim.step()
  of GameOver: inc sim.gameOverHold
  if sim.phase != Playing:
    inc sim.episodeTick

proc applyOrders*(sim: var SimServer, seat: int, directive: SeatDirective) =
  ## Installs one seat's order AND stores its radio pair for delivery to its
  ## partner next turn. Called by the decision engine live and by the replay
  ## player from the recorded order records, so the two paths are one proc.
  sim.directives[seat] = directive
  sim.haveDirective[seat] = true
  sim.mailbox.send(teamOfSeat(seat), seat, directive.radio)
  sim.emitEvent(Radio, source = seat, amount = directive.radio.a,
    target = directive.radio.b)
