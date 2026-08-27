## Sim state: the server object every module reads, the `gameHash` chain the
## replay integrity check runs on, the event sink, and the lobby / game-over
## lifecycle.

import std/strutils
import sim_types, sim_config, board, bombs, radio, directives, events

type
  Bomber* = object
    x*, y*: int
    ammo*: int
    blast*: int
    kick*: bool
    alive*: bool

  DeathRecord* = object
    tick*, victim*, killer*, x*, y*: int
    cause*: string        ## bomb | suicide | friendlyfire | crushed

  KickRecord* = object
    tick*, seat*, x*, y*, dir*: int

  PickupRecord* = object
    tick*, seat*, x*, y*: int
    kind*: ItemKind

  WoodRecord* = object
    tick*, x*, y*, team*: int

  BombRecord* = object
    tick*, seat*, x*, y*, fuse*, blast*: int

  GameRecord* = object
    game*: int
    alive*: array[TeamCount, int]
    kills*: array[TeamCount, int]
    wood*: array[TeamCount, int]
    ticks*: int
    endRule*: string

  SimServer* = object
    config*: GameConfig
    board*: Board
    bombers*: array[SeatCount, Bomber]
    bombs*: seq[Bomb]
    nextBombId*: int
    mailbox*: RadioMailbox

    tick*: int
    episodeTick*: int
    gameIndex*: int
    phase*: Phase
    lobbyTicks*: int
    gameOverHold*: int
    turnIndex*: int
    turnsPlayed*: int
    endReason*: string
    endRule*: string
    stopDetail*: string
    gameLog*: seq[GameRecord]

    directives*: array[SeatCount, SeatDirective]
    haveDirective*: array[SeatCount, bool]

    teamKills*: array[TeamCount, int]
    teamWood*: array[TeamCount, int]
    bombsPlaced*: array[SeatCount, int]
    woodCleared*: array[SeatCount, int]
    kicks*: array[SeatCount, int]
    pickups*: array[SeatCount, int]
    seatKills*: array[SeatCount, int]
    seatDeaths*: array[SeatCount, int]
    seatSuicides*: array[SeatCount, int]

    seatNames*: array[SeatCount, string]
    seatPolicyKind*: array[SeatCount, string]
    seatPolicyLabel*: array[SeatCount, string]
    llmTurns*: array[SeatCount, int]
    fallbackTurns*: array[SeatCount, int]
    ordersRejected*: array[SeatCount, int]
    deadSeats*: array[SeatCount, bool]
    joined*: array[SeatCount, bool]
    registered*: array[SeatCount, bool]

    gameHashValue*: uint64
    collectEvents*: bool
    events*: seq[SimEvent]
    wipedTeam*: int

    ## Per-frame deltas the broadcast layer derives its events from. Cleared at
    ## the top of every advanced frame, so they describe exactly the tick just
    ## stepped and nothing else.
    lastDeaths*: seq[DeathRecord]
    lastKicks*: seq[KickRecord]
    lastPickups*: seq[PickupRecord]
    lastWood*: seq[WoodRecord]
    lastBombs*: seq[BombRecord]
    lastCollapse*: int
    firstBloodTick*: int
    firstBloodKiller*: int
    firstBloodVictim*: int

func aliveOnTeam*(sim: SimServer, team: int): int =
  for seat in 0 ..< SeatCount:
    if teamOfSeat(seat) == team and sim.bombers[seat].alive:
      inc result

func teamOf*(seat: int): int {.inline.} = teamOfSeat(seat)

func seatAlias*(seat: int): string {.inline.} = seatAliasName(seat)

func turnsPerGame*(sim: SimServer): int {.inline.} =
  max(1, sim.config.maxTicks div max(1, sim.config.turnTicks))

func bomberAt*(sim: SimServer, x, y: int): int =
  ## The LIVING bomber standing on that cell, or -1.
  for seat in 0 ..< SeatCount:
    if sim.bombers[seat].alive and sim.bombers[seat].x == x and
        sim.bombers[seat].y == y:
      return seat
  -1

proc mixHash*(value: var uint64, item: int) {.inline.} =
  ## FNV-1a over the 64-bit two's-complement image of `item`. Integer only, so
  ## the native build and the wasm32 build mix identically.
  var bits = cast[uint64](int64(item))
  for _ in 0 ..< 8:
    value = value xor (bits and 0xff'u64)
    value = value * 0x100000001b3'u64
    bits = bits shr 8

proc emitEvent*(
  sim: var SimServer, kind: SimEventKind, source = -1, target = -1,
  amount = 0, x = -1, y = -1, detail = ""
) =
  if not sim.collectEvents:
    return
  sim.events.add(SimEvent(
    kind: kind, tick: sim.tick, source: source, target: target,
    amount: amount, x: x, y: y, detail: detail))

proc resetToLobby*(sim: var SimServer) =
  ## The board, the bombers, the bombs and the radio, back to tick 0. The
  ## seats, their policies and the episode-level counters survive. `maxGames`
  ## is 1 in every shipped variant -- the symmetric map removes the side-swap
  ## need -- but the path stays so a future best-of-N variant is a config
  ## change and not a rewrite.
  sim.board = generateBoard(sim.config.seed)
  sim.bombs = @[]
  sim.nextBombId = 0
  sim.mailbox = initRadioMailbox()
  for seat in 0 ..< SeatCount:
    sim.bombers[seat] = Bomber(
      x: SpawnCells[seat].x, y: SpawnCells[seat].y,
      ammo: sim.config.startAmmo, blast: sim.config.startBlast,
      kick: false, alive: true)
    sim.directives[seat] = defaultDirective()
    sim.haveDirective[seat] = false
  sim.tick = 0
  sim.turnIndex = 0
  sim.phase = Lobby
  sim.lobbyTicks = 0
  sim.gameOverHold = 0
  sim.endRule = ""
  sim.teamKills = [0, 0]
  sim.teamWood = [0, 0]
  sim.wipedTeam = -1
  sim.lastDeaths = @[]
  sim.lastKicks = @[]
  sim.lastPickups = @[]
  sim.lastWood = @[]
  sim.lastBombs = @[]
  sim.lastCollapse = -1

proc initSimServer*(config: GameConfig): SimServer =
  result.config = config
  result.endReason = ReasonComplete
  result.gameHashValue = 0xcbf29ce484222325'u64
  result.firstBloodTick = -1
  result.firstBloodKiller = -1
  result.firstBloodVictim = -1
  for seat in 0 ..< SeatCount:
    result.seatNames[seat] = seatAliasName(seat)
    result.seatPolicyKind[seat] = "scripted"
    result.seatPolicyLabel[seat] = "sapper"
  result.resetToLobby()

proc startGame*(sim: var SimServer) =
  sim.phase = Playing
  sim.tick = 0
  sim.turnIndex = 0

func lobbyJoinTimedOut*(sim: SimServer): bool =
  sim.phase == Lobby and sim.lobbyTicks >= sim.config.lobbyJoinTimeoutTicks

proc dangerNow*(sim: SimServer, horizon = -1): DangerMap =
  ## The one decoded danger grid: what the observation reports, what the
  ## controller escapes from, and what the viewer tints. One proc, three
  ## readers, so they cannot disagree.
  dangerMap(sim.board, sim.bombs, sim.config, sim.tick,
    (if horizon >= 0: horizon else: sim.config.dodgeHorizon))

func teamScore*(sim: SimServer, team: int): int =
  ## `100 * outcome + 20 * (alive[t] - alive[other]) + (wood[t] - wood[other])`.
  ## Exactly zero-sum: every term is an antisymmetric difference, so the four
  ## seat scores sum to zero with no tie-break clause. Higher is better.
  let
    other = 1 - team
    mine = sim.aliveOnTeam(team)
    theirs = sim.aliveOnTeam(other)
  var outcome = 0
  if mine > theirs: outcome = 1
  elif mine < theirs: outcome = -1
  100 * outcome + 20 * (mine - theirs) +
    (sim.teamWood[team] - sim.teamWood[other])

func scoreOf*(sim: SimServer, seat: int): int =
  ## Both seats of a team receive the identical team score.
  if sim.gameLog.len == 0:
    return sim.teamScore(teamOfSeat(seat))
  let
    record = sim.gameLog[^1]
    team = teamOfSeat(seat)
    other = 1 - team
  var outcome = 0
  if record.alive[team] > record.alive[other]: outcome = 1
  elif record.alive[team] < record.alive[other]: outcome = -1
  100 * outcome + 20 * (record.alive[team] - record.alive[other]) +
    (record.wood[team] - record.wood[other])

func winnerTeam*(sim: SimServer): int =
  ## 0 = RED, 1 = BLUE, -1 = draw.
  let red = sim.scoreOf(0)
  if red > 0: TeamRed
  elif red < 0: TeamBlue
  else: -1

proc bankGame*(sim: var SimServer, endRule: string) =
  ## Archives the game. Called by the SAME proc on record and on playback, so a
  ## wall-clock stop re-derives identically.
  if sim.phase == GameOver:
    return
  var record = GameRecord(
    game: sim.gameIndex + 1, ticks: sim.tick, endRule: endRule)
  for team in 0 ..< TeamCount:
    record.alive[team] = sim.aliveOnTeam(team)
    record.kills[team] = sim.teamKills[team]
    record.wood[team] = sim.teamWood[team]
  sim.gameLog.add(record)
  sim.endRule = endRule
  sim.phase = GameOver
  sim.gameOverHold = 0
  sim.emitEvent(PhaseChange, amount = sim.gameIndex + 1, detail = endRule)

proc gameHash*(sim: SimServer): uint64 =
  ## The per-tick integrity chain. Mix order is FIXED: per cell, per bomber,
  ## per bomb, per team, then the clock, the collapsed rings and the four
  ## seats' stored radio pairs. The RADIO PAIRS ARE HASHED -- they are inputs,
  ## and a replay that got them wrong would draw the wrong glyphs while
  ## claiming a clean hash.
  result = 0xcbf29ce484222325'u64
  for cell in 0 ..< BoardCells:
    result.mixHash(ord(sim.board.terrain[cell]))
    result.mixHash(ord(sim.board.item[cell]))
    result.mixHash(sim.board.flame[cell])
  for seat in 0 ..< SeatCount:
    let bomber = sim.bombers[seat]
    result.mixHash(seat)
    result.mixHash(bomber.x)
    result.mixHash(bomber.y)
    result.mixHash(if bomber.alive: 1 else: 0)
    result.mixHash(bomber.ammo)
    result.mixHash(bomber.blast)
    result.mixHash(if bomber.kick: 1 else: 0)
  for bomb in sim.bombs:
    result.mixHash(bomb.id)
    result.mixHash(bomb.x)
    result.mixHash(bomb.y)
    result.mixHash(bomb.fuse)
    result.mixHash(bomb.blast)
    result.mixHash(bomb.owner)
    result.mixHash(ord(bomb.velocity))
  for team in 0 ..< TeamCount:
    result.mixHash(sim.aliveOnTeam(team))
    result.mixHash(sim.teamKills[team])
    result.mixHash(sim.teamWood[team])
  result.mixHash(sim.tick)
  result.mixHash(sim.board.collapsedRings)
  for seat in 0 ..< SeatCount:
    result.mixHash(sim.mailbox.pending[seat].a)
    result.mixHash(sim.mailbox.pending[seat].b)

proc gameHashHex*(sim: SimServer): string =
  toHex(sim.gameHash())

proc parseHashHex*(text: string): uint64 =
  parseBiggestUInt("0x" & text).uint64
