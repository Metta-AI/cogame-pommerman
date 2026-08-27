## The episode driver: ONE frame of the whole game, shared by the live server
## and by `tests/test_pom_engine.nim`.
##
## Everything that decides the episode lives here -- the command turn, the
## order and chat records, the sim advance, the hash and the wall-clock stop.
## `server.nim` adds only sockets and the broadcast; the end-to-end test drives
## THIS proc, so the test and production can never run two different loops (the
## bullwhip "stale binary" class of bug, structurally).

import std/[monotimes, times]
import sim, decide, replays, roster

type
  EpisodeState* = object
    frame*: int
    gamesPlayed*: int
    started*: bool
    stopped*: bool
    finished*: bool
    failureSlot*: int
    lastTurnKey*: int
    turnRecords*: seq[string]
    unregistered*: seq[int]

  EpisodeFrame* = object
    ## What the caller needs to know about the frame just run.
    records*: seq[ChatRecord]
    startedGame*: bool
    finishedGame*: bool
    faulted*: bool

proc initEpisodeState*(): EpisodeState =
  result.lastTurnKey = -1
  result.failureSlot = -1

proc maybeStop*(
  state: var EpisodeState, sim: var SimServer, writer: var ReplayWriter,
  elapsedSeconds: int
): bool =
  ## The engine's own hard stop, checked before anything else in a frame. The
  ## stop is written as ONE load-bearing record and applied by `sim.applyStop`
  ## -- the same proc playback calls -- so the hash chain stays clean at the
  ## stop tick (the particle-worlds scar).
  if state.stopped or elapsedSeconds < sim.config.wallClockBudgetSeconds:
    return false
  state.stopped = true
  sim.endReason = ReasonDeadline
  sim.stopDetail = "wall-clock budget of " &
    $sim.config.wallClockBudgetSeconds & "s reached"
  writer.writeStop(state.frame, EndRuleWallClock)
  sim.applyStop(EndRuleWallClock)
  state.finished = true
  true

proc maybeStartFirstGame*(
  state: var EpisodeState, sim: var SimServer, writer: var ReplayWriter
): bool =
  ## Starts the game once every seat is seated, or once the lobby budget
  ## expires. A seat that never connects DOES NOT end the episode: it is
  ## reported once to the platform and its bomber plays the sapper baseline.
  if state.started or sim.phase != Lobby:
    return false
  let ready = sim.seatsJoined() >= sim.config.numAgents
  if not ready and not sim.lobbyJoinTimedOut():
    return false
  if ready and sim.lobbyTicks < sim.config.startWaitTicks:
    ## A short grace after the last seat lands, so a slot-sequential join
    ## cannot start the game before the last seat's registration arrives.
    return false
  if not ready:
    for slot in 0 ..< sim.config.numAgents:
      if not sim.joined[slot]:
        sim.deadSeats[slot] = true
        if state.failureSlot < 0:
          state.failureSlot = slot
  ## THE GRF-FOOTBALL SCAR: a lost register packet made a champion play
  ## scripted for a whole episode with latency_ms 0 and no error anywhere. The
  ## server logs loudly and names every seat that produced no `register` record
  ## by the time the lobby closes, and `results.policyKinds` carries the same
  ## fact.
  for slot in 0 ..< sim.config.numAgents:
    if sim.joined[slot] and not sim.registered[slot]:
      state.unregistered.add(slot)
      echo "pommerman: WARNING seat ", slot, " (", seatAliasOf(slot),
        ") joined but sent NO register record before the lobby closed; it ",
        "plays the scripted default for the whole episode"
  state.started = true
  sim.applyGameStart(0)
  writer.writeGameStart(state.frame, 0)
  true

proc runTurnIfDue*(
  state: var EpisodeState, sim: var SimServer, engine: var DecisionEngine,
  writer: var ReplayWriter, elapsedSeconds: int
) =
  ## One command turn every `turnTicks`, at most once per turn, issued
  ## immediately BEFORE the tick it governs.
  if sim.phase != Playing or sim.tick mod max(1, sim.config.turnTicks) != 0:
    return
  let turnIndex = sim.tick div max(1, sim.config.turnTicks) + 1
  if turnIndex == state.lastTurnKey:
    return
  state.lastTurnKey = turnIndex
  sim.emitEvent(TurnStart, amount = turnIndex)
  state.turnRecords = engine.turn(sim, turnIndex, elapsedSeconds)
  inc sim.turnsPlayed
  for record in state.turnRecords:
    writer.writeChat(state.frame, 0, record)
  for seat in 0 ..< SeatCount:
    let directive = sim.directives[seat]
    case directive.source
    of dsLlm: inc sim.llmTurns[seat]
    of dsFallback:
      inc sim.fallbackTurns[seat]
      sim.emitEvent(Fallback, source = seat, amount = turnIndex)
    of dsScripted: discard
    writer.writeOrder(
      state.frame, turnIndex, seat, directive.order, directive.radio)
    writer.writeChat(state.frame, seat, directive.boundedDirectiveRecord(
      turnIndex, seat, engine.lastRadioIn[seat], engine.lastView[seat]))
    sim.emitEvent(Directive, source = seat, amount = turnIndex,
      detail = $directive.source)

proc advanceEpisodeFrame*(
  state: var EpisodeState, sim: var SimServer, writer: var ReplayWriter
): bool =
  ## Advances the sim by one frame and records its hash. Returns false when a
  ## fault was caught -- the episode is then settled from the last completed
  ## tick, `results.stopDetail` names it, and the artifacts are still written.
  result = true
  try:
    sim.advanceFrame()
  except CatchableError as error:
    sim.endReason = ReasonFault
    sim.stopDetail = error.msg.sanitizeLine(MaxStopDetailRunes)
    writer.writeStop(state.frame, EndRuleFault)
    sim.applyStop(EndRuleFault)
    state.finished = true
    result = false
  writer.writeHash(state.frame, sim.gameHash())

proc maybeNextGame*(
  state: var EpisodeState, sim: var SimServer, writer: var ReplayWriter
): bool =
  ## Banks the finished game. `maxGames` is 1 in every shipped variant -- the
  ## rotationally symmetric map removes paintbot's side-swap need -- but the
  ## loop stays so a future best-of-N variant is a config change.
  if state.finished or sim.phase != GameOver or
      sim.gameOverHold < sim.config.gameOverTicks:
    return false
  inc state.gamesPlayed
  result = true
  if state.gamesPlayed >= sim.config.maxGames:
    state.finished = true
    return
  sim.applyGameStart(state.gamesPlayed)
  # frame + 1, NOT frame: this runs AFTER this frame's advance and after this
  # frame's hash was written, so the recorded state for `frame` is still the
  # game-over state of the game just finished.
  writer.writeGameStart(state.frame + 1, state.gamesPlayed)
  state.lastTurnKey = -1

proc runEpisodeFrame*(
  state: var EpisodeState, sim: var SimServer, engine: var DecisionEngine,
  writer: var ReplayWriter, elapsedSeconds: int
): EpisodeFrame =
  ## The whole frame, in the order the design pins.
  if state.maybeStop(sim, writer, elapsedSeconds):
    discard
  result.startedGame = state.maybeStartFirstGame(sim, writer)
  state.turnRecords = @[]
  if not state.finished:
    state.runTurnIfDue(sim, engine, writer, elapsedSeconds)
    result.faulted = not state.advanceEpisodeFrame(sim, writer)
    result.finishedGame = state.maybeNextGame(sim, writer)
  inc state.frame

proc finishEpisode*(
  state: var EpisodeState, sim: var SimServer, writer: var ReplayWriter
) =
  ## Settles and writes the `result` control record -- the whole results
  ## document, once, into the replay chat stream, which is what makes the bytes
  ## self-sufficient.
  for seat in 0 ..< SeatCount:
    if not sim.joined[seat]:
      sim.deadSeats[seat] = true
  if sim.gameLog.len == 0:
    sim.applyStop(EndRuleWallClock)
  writer.writeChat(state.frame, 0, resultRecord(sim))
  writer.closeReplayWriter()

proc runHeadlessEpisode*(
  config: GameConfig, engine: var DecisionEngine, replayPath: string,
  joinSeats: set[uint8] = {0'u8, 1'u8, 2'u8, 3'u8}, maxFrames = 20000
): tuple[sim: SimServer, state: EpisodeState, bytes: string] =
  ## The whole episode with no sockets: the e2e test's driver, and the exact
  ## same per-frame proc the live server calls.
  var
    sim = initSimServer(config)
    state = initEpisodeState()
    writer = openReplayWriter(replayPath, config.configJson())
    started = getMonoTime()
  for seat in 0 ..< SeatCount:
    if uint8(seat) in joinSeats:
      sim.admitSeat(seat, "")
      writer.writeJoin(0, seat, seatAliasOf(seat), "")
      sim.registered[seat] = true
      sim.seatPolicyKind[seat] = engine.policyKind(seat)
  while not state.finished and state.frame < maxFrames:
    let elapsed = (getMonoTime() - started).inSeconds.int
    discard state.runEpisodeFrame(sim, engine, writer, elapsed)
  state.finishEpisode(sim, writer)
  (sim, state, writer.bytes())
