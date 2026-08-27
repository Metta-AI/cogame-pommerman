## Replay playback: the frame driver, the per-tick hash check, the transport
## commands, and the load-time PRE-SCAN that lets the momentum sparkline and
## the scrubber beats draw at full width on the very first frame.
##
## The driver is `sim.advanceFrame` -- the SAME proc the live server loop calls
## -- and every fact that cannot be re-derived from sim state (a game start, a
## wall-clock stop) is a recorded record applied by the same proc on both
## sides. That is what keeps the chain clean at the stop tick.

import std/[json, strutils]
import sim, replays, roster

const
  TicksPerSecondBase* = TargetFps
    ## Playback rate at speed 1: six sim ticks a second, one tick per 167 ms,
    ## advanced by an integer accumulator against TargetFps. A 144-tick episode
    ## therefore plays for 24 s, which comfortably outlasts
    ## `viewer_smoke.mjs --soak 10` (the ecos 2026-08-23 scar), and an 8-tick
    ## fuse reads as 1.3 s -- long enough to watch the countdown.
  LullTicks* = 24
    ## A lull is this many consecutive ticks with no bomb, wood, pickup, kick
    ## or death.

type
  Beat* = object
    tick*: int
    kind*: string
    team*: string
    label*: string

  ReplayPlayer* = object
    data*: ReplayData
    frame*: int
    maxFrame*: int
    playing*: bool
    looping*: bool
    skipLulls*: bool
    speedIndex*: int
    accumulator*: int
    hashMismatchTick*: int
    mismatchQuit*: bool
    orderCursor*: int
    chatCursor*: int
    startCursor*: int
    stopCursor*: int
    feed*: seq[ChatRecord]
    pending*: seq[ChatRecord]
    lulls*: seq[array[2, int]]
    beats*: seq[Beat]
    leadSeries*: seq[array[5, int]]  ## frame, red alive, blue alive, red wood,
                                     ## blue wood
    gameStartFrames*: seq[int]
    scanned*: bool
    fastForward*: bool

  InitializedReplay* = object
    config*: GameConfig
    sim*: SimServer
    player*: ReplayPlayer

proc playbackSpeed*(player: ReplayPlayer): int =
  PlaybackSpeeds[clamp(player.speedIndex, 0, PlaybackSpeeds.high)]

proc resetCursors(player: var ReplayPlayer) =
  player.frame = 0
  player.orderCursor = 0
  player.chatCursor = 0
  player.startCursor = 0
  player.stopCursor = 0
  player.accumulator = 0
  player.feed = @[]
  player.pending = @[]

proc configFromReplay*(data: ReplayData): GameConfig =
  result = defaultGameConfig()
  result.update(data.configJson)

proc runFrame(player: var ReplayPlayer, sim: var SimServer) =
  ## Applies every record stamped with the current frame, advances the sim by
  ## one frame, then checks the recorded hash.
  player.pending = @[]
  while player.startCursor < player.data.gameStarts.len and
      player.data.gameStarts[player.startCursor].tick == player.frame:
    sim.applyGameStart(player.data.gameStarts[player.startCursor].gameIndex)
    inc player.startCursor
  while player.orderCursor < player.data.orders.len and
      player.data.orders[player.orderCursor].tick == player.frame:
    let record = player.data.orders[player.orderCursor]
    if record.slot >= 0 and record.slot < SeatCount:
      var directive = sim.directives[record.slot]
      directive.order = record.order
      directive.radio = record.radio
      directive.source = dsScripted
      sim.applyOrders(record.slot, directive)
      sim.turnIndex = record.turn
    inc player.orderCursor
  while player.stopCursor < player.data.stops.len and
      player.data.stops[player.stopCursor].tick == player.frame:
    sim.applyStop(player.data.stops[player.stopCursor].endRule)
    inc player.stopCursor
  while player.chatCursor < player.data.chats.len and
      player.data.chats[player.chatCursor].tick == player.frame:
    player.pending.add(player.data.chats[player.chatCursor])
    player.feed.add(player.data.chats[player.chatCursor])
    inc player.chatCursor
  sim.advanceFrame()
  # the hash for THIS frame, checked at the tick it happens
  var recorded = -1
  for i in 0 ..< player.data.hashes.len:
    if player.data.hashes[i].tick == player.frame:
      recorded = i
      break
  if recorded >= 0 and player.hashMismatchTick < 0:
    if sim.gameHash() != player.data.hashes[recorded].value:
      player.hashMismatchTick = player.frame
      if player.mismatchQuit:
        raise newException(ReplayError,
          "replay hash mismatch at tick " & $player.frame)
  inc player.frame

proc scanReplay(player: var ReplayPlayer, config: GameConfig) =
  ## The load-time pre-scan: re-simulate the whole episode once headlessly,
  ## recording the per-frame alive counts and cumulative wood, the lull spans
  ## and the beat ticks, then reset and render frame 0. 144 ticks x 121 cells of
  ## integer work is sub-millisecond in wasm, and it is what lets the sparkline
  ## and the scrubber beats draw at FULL WIDTH on the first frame instead of
  ## growing in.
  var sim = initSimServer(config)
  player.resetCursors()
  player.hashMismatchTick = -1
  var
    firstBlood = false
    lastActionFrame = 0
  player.beats = @[]
  player.leadSeries = @[]
  player.lulls = @[]
  player.gameStartFrames = @[]
  for record in player.data.gameStarts:
    player.gameStartFrames.add(record.tick)
  while player.frame <= player.maxFrame:
    let frame = player.frame
    runFrame(player, sim)
    player.leadSeries.add([frame,
      sim.aliveOnTeam(TeamRed), sim.aliveOnTeam(TeamBlue),
      sim.teamWood[TeamRed], sim.teamWood[TeamBlue]])
    if sim.lastBombs.len > 0 or sim.lastWood.len > 0 or
        sim.lastPickups.len > 0 or sim.lastKicks.len > 0 or
        sim.lastDeaths.len > 0:
      lastActionFrame = frame
    for kick in sim.lastKicks:
      player.beats.add(Beat(
        tick: frame, kind: "kick", team: teamName(teamOfSeat(kick.seat)),
        label: seatAliasName(kick.seat) & " kicks a bomb " &
          DirNames[kick.dir]))
    for death in sim.lastDeaths:
      if not firstBlood and death.killer >= 0 and
          teamOfSeat(death.killer) != teamOfSeat(death.victim):
        firstBlood = true
        player.beats.add(Beat(
          tick: frame, kind: "firstblood",
          team: teamName(teamOfSeat(death.killer)),
          label: "First blood - " & seatAliasName(death.killer) &
            " kills " & seatAliasName(death.victim)))
      player.beats.add(Beat(
        tick: frame, kind: "death", team: teamName(teamOfSeat(death.victim)),
        label: seatAliasName(death.victim) & " is down (" & death.cause & ")"))
    if sim.lastCollapse > 0:
      player.beats.add(Beat(
        tick: frame, kind: "collapse", team: "",
        label: "The walls close in - ring " & $sim.lastCollapse))
    if frame - lastActionFrame >= LullTicks:
      if player.lulls.len > 0 and player.lulls[^1][1] >= lastActionFrame:
        player.lulls[^1][1] = frame
      else:
        player.lulls.add([lastActionFrame + 1, frame])
    if sim.phase == GameOver and sim.gameOverHold == 1:
      player.beats.add(Beat(
        tick: frame, kind: "end", team: "",
        label: "The game ends - " & sim.endRule))
  for record in player.data.chats:
    if record.text.len > 0 and record.text[0] == '{' and
        "\"k\":\"fallback\"" in record.text:
      player.beats.add(Beat(
        tick: record.tick, kind: "fallback", team: "",
        label: "A seat missed the call - scripted order"))
  player.scanned = true

proc initReplayRuntime*(
  data: ReplayData, mismatchQuit = false
): InitializedReplay =
  result.config = configFromReplay(data)
  result.player.data = data
  result.player.maxFrame = max(0, data.frameCount - 1)
  result.player.mismatchQuit = mismatchQuit
  result.player.hashMismatchTick = -1
  result.player.playing = true
  result.player.speedIndex = 0
  scanReplay(result.player, result.config)
  result.player.resetCursors()
  result.player.hashMismatchTick = -1
  result.sim = initSimServer(result.config)
  runFrame(result.player, result.sim)

proc seekTo*(player: var ReplayPlayer, sim: var SimServer, frame: int) =
  ## Seeks by re-simulating from frame 0. A couple of hundred integer frames on
  ## a 121-cell board is microseconds, so a fresh re-derivation is both the
  ## simplest and the most trustworthy seek: the state a viewer scrubs to is
  ## always the state the recorded orders produce.
  let target = clamp(frame, 0, player.maxFrame)
  let keepMismatch = player.hashMismatchTick
  player.resetCursors()
  player.hashMismatchTick = -1
  sim = initSimServer(sim.config)
  ## The spectator-side REAL policy names live in the replay's join and
  ## register records, not in sim state, so a fresh SimServer has to be
  ## re-seeded with them -- otherwise every seek silently reverts the scorebug
  ## and the endcard to the anonymous in-game aliases.
  sim.applySeatIdentities(player.data)
  while player.frame <= target:
    runFrame(player, sim)
  if player.hashMismatchTick < 0:
    player.hashMismatchTick = keepMismatch

proc applyCommand*(
  player: var ReplayPlayer, sim: var SimServer, command: string
) =
  ## The transport. Plain single chars from the shared chrome, plus `s:<tick>`
  ## from the scrubber and the labelled beat buttons.
  if command.len == 0:
    return
  if command.startsWith("s:"):
    try:
      player.seekTo(sim, parseInt(command[2 .. ^1].strip()))
    except CatchableError:
      discard
    return
  case command[0]
  of ' ': player.playing = not player.playing
  of 'b': player.seekTo(sim, player.frame - 2)
  of ',': player.seekTo(sim, 0)
  of '.': player.seekTo(sim, player.frame + 5 * TicksPerSecondBase)
  of 'e': player.seekTo(sim, player.maxFrame)
  of 'r': player.looping = not player.looping
  of 'f': player.skipLulls = not player.skipLulls
  of '1': player.speedIndex = 0
  of '2': player.speedIndex = 1
  of '4': player.speedIndex = 2
  of '8': player.speedIndex = 3
  else: discard

proc inLull(player: ReplayPlayer, frame: int): bool =
  for span in player.lulls:
    if frame >= span[0] and frame <= span[1]:
      return true
  false

proc advanceReplayFrame*(player: var ReplayPlayer, sim: var SimServer) =
  ## One presentation frame. Bounded: at most a handful of sim frames run per
  ## call even when skipping a lull, so a slow browser can never be starved.
  player.fastForward = false
  if not player.playing:
    return
  if player.frame > player.maxFrame:
    if player.looping:
      player.seekTo(sim, 0)
    return
  player.accumulator += player.playbackSpeed() * TicksPerSecondBase
  var advanced = 0
  while player.accumulator >= TargetFps and advanced < 8:
    player.accumulator -= TargetFps
    if player.frame > player.maxFrame:
      break
    runFrame(player, sim)
    inc advanced
  if player.skipLulls and player.inLull(player.frame):
    player.fastForward = true
    var skipped = 0
    while player.frame <= player.maxFrame and player.inLull(player.frame) and
        skipped < 64:
      runFrame(player, sim)
      inc skipped

proc beatsJson*(player: ReplayPlayer): JsonNode =
  result = newJArray()
  for beat in player.beats:
    result.add(%*{
      "t": beat.tick, "k": beat.kind, "side": beat.team, "label": beat.label})

proc lullsJson*(player: ReplayPlayer): JsonNode =
  result = newJArray()
  for span in player.lulls:
    result.add(%[span[0], span[1]])

proc leadJson*(player: ReplayPlayer): JsonNode =
  ## The momentum sparkline: living bombers per team over the whole episode, in
  ## the shape chrome_common's momentum graph reads (`{teams, pts}` with
  ## pts = [tick, a, b]), plus the cumulative wood series beside it.
  var
    pts = newJArray()
    wood = newJArray()
  var last = [-1, -1, -1, -1]
  for sample in player.leadSeries:
    if sample[1] == last[0] and sample[2] == last[1] and
        sample[3] == last[2] and sample[4] == last[3]:
      continue
    last = [sample[1], sample[2], sample[3], sample[4]]
    pts.add(%[sample[0], sample[1], sample[2]])
    wood.add(%[sample[0], sample[3], sample[4]])
  %*{"teams": ["red", "blue"], "pts": pts, "wood": wood}
