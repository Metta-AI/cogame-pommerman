## The baseline sweep's pick, and the head-to-head evidence behind it.

import std/[json, unittest]
import helpers
import "../tools/tune_baselines"

suite "pommerman baseline tuning":

  test "the shipped defaults are the swept pick":
    let tuning = parseJson(readRepoFile("tools/ci/baseline_tuning.json"))
    check DefaultBaselineParams.bombEnemyRange ==
      tuning["bombEnemyRange"].getInt()
    check DefaultBaselineParams.powerupSearch ==
      tuning["powerupSearch"].getInt()
    check DefaultBaselineParams.dodgeHorizon ==
      tuning["dodgeHorizon"].getInt()
    check DefaultBaselineParams.campExits == tuning["campExits"].getInt()
    ## the shipped dodge horizon is also the shipped CONFIG default, so the
    ## controller the sweep measured is the controller that ships
    check DefaultBaselineParams.dodgeHorizon ==
      defaultGameConfig().dodgeHorizon

  test "the shipped pick is a cell of the swept grid":
    ## The grid the tool walks, over a short horizon so the shard stays fast.
    ## `ci.yml` re-runs `tools/tune_baselines.nim --check` at the horizon the
    ## pick was tuned at and fails if the pick has fallen out of the top half,
    ## so a controller change that invalidates it is red there rather than in a
    ## ladder round.
    let ranking = sweepBaselines(maxTicks = 48, seeds = @[42])
    check ranking.len == 54
    var rank = -1
    for i, entry in ranking:
      if entry.params == DefaultBaselineParams:
        rank = i
    checkpoint("shipped pick ranks " & $rank & " of " & $ranking.len &
      "; best " & $ranking[0].params & " at " & $ranking[0].score)
    check rank >= 0

  test "sapper is a real opponent, not a walkover":
    ## `sapper` is the server-side fallback, so a champion that loses a turn to
    ## a timeout must not thereby lose the game. It out-plays the deliberately
    ## passive `camper` across the map draws, and the formula stays exactly
    ## zero-sum.
    var total = 0
    for seed in [1, 7, 42, 99]:
      let head = headToHead(DefaultBaselineParams, seed = seed, maxTicks = 144)
      checkpoint("seed " & $seed & ": sapper " & $head.sapper &
        " camper " & $head.camper)
      check head.sapper + head.camper == 0
      total += head.sapper
    checkpoint("sapper total over four draws: " & $total)
    check total >= 0
