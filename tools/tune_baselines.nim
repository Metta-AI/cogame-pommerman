## The baseline tuning sweep. Not a guess: the four tunables come from a
## head-to-head grid, and `tools/ci/baseline_tuning.json` records the pick that
## `tests/test_pom_tuning.nim` then pins.
##
##   nim c -r --path:src tools/tune_baselines.nim            # print the sweep
##   nim c -r --path:src tools/tune_baselines.nim --check    # verify the pick
##
## Both baselines are scripted and the sim is deterministic, so a handful of
## seeds per cell is the whole measurement -- there is nothing to average over
## beyond the map draw.

import std/[json, os, strformat, strutils]
import ../src/pommerman/[sim, baselines, decide, episode]

export sim, baselines

type
  SweepEntry* = object
    params*: BaselineParams
    score*: int

const SweepSeeds* = [1, 7, 42, 99]
  ## Four map draws per cell: the map is the only randomness, so a cell's score
  ## is the sum over these draws and nothing else varies.

proc paramsConfig(seed, maxTicks: int): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.maxTicks = maxTicks
  result.maxGames = 1
  result.turnTicks = 4
  result.turnSpacingMs = 0
  result.gameOverTicks = 1
  result.lobbyJoinTimeoutTicks = 1
  result.startWaitTicks = 0
  result.collapseTicks = @[maxTicks * 2 div 3, maxTicks * 5 div 6]
  result.players = @[
    PlayerConfig(name: "RED-1"), PlayerConfig(name: "BLUE-1"),
    PlayerConfig(name: "RED-2"), PlayerConfig(name: "BLUE-2")]
  result.clampConfig()

proc runPair(
  params: BaselineParams, seed, maxTicks: int
): tuple[sapper, camper: int] =
  ## `sapper` (with these params) on RED against `camper` on BLUE, as one
  ## episode. Returns each team's score, which is exactly zero-sum.
  var config = paramsConfig(seed, maxTicks)
  config.dodgeHorizon = params.dodgeHorizon
  var engine = initDecisionEngine(config)
  for seat in 0 ..< SeatCount:
    engine.seats[seat].baseline =
      if teamOfSeat(seat) == TeamRed: blSapper else: blCamper
    engine.seats[seat].label = $engine.seats[seat].baseline
  engine.params = params
  let run = runHeadlessEpisode(config, engine, "")
  (run.sim.scoreOf(0), run.sim.scoreOf(1))

proc headToHead*(
  params: BaselineParams, seed = 42, maxTicks = 144
): tuple[sapper, camper: int] =
  runPair(params, seed, maxTicks)

proc sweepBaselines*(
  maxTicks = 144, seeds: seq[int] = @SweepSeeds
): seq[SweepEntry] =
  ## The grid: bomb-lane reach x power-up search radius x dodge horizon x camp
  ## exits, ranked by the `sapper` team's zero-sum score against `camper`,
  ## summed over the four map seeds.
  for reach in [1, 2, 3]:
    for search in [4, 8, 12]:
      for horizon in [4, 6, 8]:
        for exits in [1, 2]:
          let params = BaselineParams(
            bombEnemyRange: reach, powerupSearch: search,
            dodgeHorizon: horizon, campExits: exits)
          var total = 0
          for seed in seeds:
            total += runPair(params, seed, maxTicks).sapper
          result.add(SweepEntry(params: params, score: total))
  # insertion sort, descending: the grid is 54 entries and a dependency-free
  # sort keeps the ordering identical on every platform
  for i in 1 ..< result.len:
    let cur = result[i]
    var j = i - 1
    while j >= 0 and result[j].score < cur.score:
      result[j + 1] = result[j]
      dec j
    result[j + 1] = cur

when isMainModule:
  let check = "--check" in commandLineParams()
  let ranking = sweepBaselines()
  echo "bombRange powerupSearch dodgeHorizon campExits  score(sapper v camper)"
  for entry in ranking:
    echo &"{entry.params.bombEnemyRange:>9} {entry.params.powerupSearch:>13} " &
      &"{entry.params.dodgeHorizon:>12} {entry.params.campExits:>10}  " &
      &"{entry.score:>6}"
  let recorded = parseJson(readFile(
    currentSourcePath().parentDir().parentDir() /
      "tools/ci/baseline_tuning.json"))
  let pick = BaselineParams(
    bombEnemyRange: recorded["bombEnemyRange"].getInt(),
    powerupSearch: recorded["powerupSearch"].getInt(),
    dodgeHorizon: recorded["dodgeHorizon"].getInt(),
    campExits: recorded["campExits"].getInt())
  echo "shipped pick: ", pick
  if pick != DefaultBaselineParams:
    quit("tools/ci/baseline_tuning.json disagrees with DefaultBaselineParams", 1)
  if check:
    var rank = -1
    for i, entry in ranking:
      if entry.params == pick:
        rank = i
    if rank < 0:
      quit("the shipped pick is not in the swept grid", 1)
    if rank > ranking.len div 2:
      quit("the shipped pick ranks " & $rank & " of " & $ranking.len &
        "; re-sweep and update tools/ci/baseline_tuning.json", 1)
    echo "shipped pick ranks ", rank, " of ", ranking.len, ": ok"
