## Shared test scaffolding: a configured sim, a headless episode, and the
## repo-root path resolution the tests read source files through.
##
## Every test runs from the repo ROOT (`nim r tests/<file>.nim`), which is what
## the source-grep gates and the manifest read depend on.

import std/[json, os, strutils]
import pommerman/[sim, baselines, decide, episode, replays, roster]

export sim, baselines, decide, episode, replays, roster

proc repoRoot*(): string =
  ## The repo root, resolved from THIS file rather than from the cwd, so a
  ## shard binary run from anywhere still finds the sources it greps.
  currentSourcePath().parentDir().parentDir()

proc readRepoFile*(relative: string): string =
  readFile(repoRoot() / relative)

proc repoFileExists*(relative: string): bool =
  fileExists(repoRoot() / relative)

proc testConfig*(maxTicks = 144, seed = 42): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.maxTicks = maxTicks
  result.turnTicks = 4
  result.turnSpacingMs = 0
  result.gameOverTicks = 1
  result.lobbyJoinTimeoutTicks = 1
  result.startWaitTicks = 0
  result.collapseTicks = @[maxTicks * 2 div 3, maxTicks * 5 div 6]
  result.players = @[
    PlayerConfig(name: "RED-1"), PlayerConfig(name: "BLUE-1"),
    PlayerConfig(name: "RED-2"), PlayerConfig(name: "BLUE-2")]
  result.slots = @[
    SlotConfig(team: "red"), SlotConfig(team: "blue"),
    SlotConfig(team: "red"), SlotConfig(team: "blue")]
  result.clampConfig()

proc playingSim*(maxTicks = 144, seed = 42): SimServer =
  ## A sim with the board generated, four bombers spawned and the game started.
  result = initSimServer(testConfig(maxTicks = maxTicks, seed = seed))
  result.applyGameStart(0)

proc openBoard*(maxTicks = 144): SimServer =
  ## A started game whose interior is entirely passage, so a unit test can place
  ## exactly the walls, bombs and bombers it wants to reason about. The border
  ## ring stays rigid -- every rule assumes a walled arena.
  result = playingSim(maxTicks)
  for y in 0 ..< BoardSize:
    for x in 0 ..< BoardSize:
      if ringOf(x, y) == 0:
        continue
      let at = cellIndex(x, y)
      result.board.terrain[at] = tPassage
      result.board.item[at] = ikNone
      result.board.hidden[at] = ikNone
      result.board.flame[at] = 0
      result.board.flameOwner[at] = -1
  for seat in 0 ..< SeatCount:
    result.bombers[seat].alive = false

proc place*(sim: var SimServer, seat, x, y: int, ammo = 1, blast = 2,
            kick = false) =
  sim.bombers[seat] = Bomber(
    x: x, y: y, ammo: ammo, blast: blast, kick: kick, alive: true)

proc addBomb*(sim: var SimServer, seat, x, y: int, fuse = 8, blast = 2,
              velocity = vNone): int =
  result = sim.nextBombId
  sim.bombs.add(Bomb(
    id: sim.nextBombId, x: x, y: y, fuse: fuse, blast: blast, owner: seat,
    velocity: velocity, placedTick: -1))
  inc sim.nextBombId

proc setOrder*(sim: var SimServer, seat: int, kind: OrderKind,
               x = 0, y = 0, target = -1, dir = -1) =
  sim.directives[seat].order = BomberOrder(
    kind: kind, x: x, y: y, target: target, dir: dir, fromReply: true)
  sim.haveDirective[seat] = true

proc scriptedEngine*(
  config: GameConfig, red = blSapper, blue = blCamper
): DecisionEngine =
  result = initDecisionEngine(config)
  for seat in 0 ..< SeatCount:
    let baseline = if teamOfSeat(seat) == TeamRed: red else: blue
    result.seats[seat].baseline = baseline
    result.seats[seat].label = $baseline

proc runScriptedEpisode*(
  config: GameConfig, replayPath = "",
  red = blSapper, blue = blCamper,
  joinSeats: set[uint8] = {0'u8, 1'u8, 2'u8, 3'u8}
): tuple[sim: SimServer, state: EpisodeState, bytes: string] =
  var engine = scriptedEngine(config, red, blue)
  runHeadlessEpisode(config, engine, replayPath, joinSeats)

proc stripNimComments*(source: string): string =
  ## Source with `#`/`##` comments removed, so a token grep asks about CODE.
  ## Naive about `#` inside string literals -- the sim modules the float gate
  ## covers contain none, and the gate itself asserts that.
  var lines: seq[string]
  for line in source.splitLines():
    var inString = false
    var kept = ""
    var i = 0
    while i < line.len:
      let ch = line[i]
      if ch == '"':
        inString = not inString
      if ch == '#' and not inString:
        break
      kept.add(ch)
      inc i
    lines.add(kept)
  lines.join("\n")

proc manifestJson*(): JsonNode =
  parseJson(readRepoFile("coworld_manifest_template.json"))
