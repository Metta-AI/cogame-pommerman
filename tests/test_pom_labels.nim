## The label contract: the emitted sprite/plate/beat vocabulary equals
## tests/label_manifest.txt, and nothing in it can leak an identity.

import std/[algorithm, json, sequtils, strutils, unittest]
import helpers
import pommerman/[labels, decide]

suite "pommerman labels":

  test "the manifest is the emitted vocabulary":
    check labelManifest() == readRepoFile("tests/label_manifest.txt")
    let vocabulary = emittedLabels()
    check vocabulary.len == vocabulary.deduplicate().len
    check vocabulary == vocabulary.sorted()

  test "the two name spaces":
    ## Aliases are identity-anonymous and fixed for the whole episode, so a
    ## seat can never learn who its partner or its opponents are from a label.
    ## showPlayerLabels is false, so no in-board sprite can leak an identity.
    check seatAliasOf(0) == "RED-1"
    check seatAliasOf(1) == "BLUE-1"
    check seatAliasOf(2) == "RED-2"
    check seatAliasOf(3) == "BLUE-2"
    check IdentityNames.len == SeatCount
    for seat in 0 ..< SeatCount:
      check seatAliasName(seat) in emittedLabels()

  test "showPlayerLabels is false in every shipped config":
    for name in ["teams", "blitz"]:
      var found = false
      for variant in manifestJson()["variants"]:
        if variant["id"].getStr() == name:
          found = true
          check variant["game_config"]["showPlayerLabels"].getBool() == false
      checkpoint(name)
      check found
    check manifestJson()["certification"]["game_config"][
      "showPlayerLabels"].getBool() == false

  test "the observation and the prompt carry NO real name":
    ## The one place an identity could leak into a decision -- including the
    ## seat's OWN partner's name, which is what makes the radio a real
    ## coordination problem rather than a pre-agreed protocol.
    var config = testConfig()
    var engine = initDecisionEngine(config)
    var sim = initSimServer(config)
    sim.seatNames[0] = "daveey"
    sim.seatNames[1] = "daveey-1"
    sim.seatNames[2] = "Baseline (1)"
    sim.seatNames[3] = "Baseline (2)"
    sim.applyGameStart(0)
    for seat in 0 ..< SeatCount:
      let view = $engine.seatView(sim, seat, includeNotes = true)
      checkpoint("seat " & $seat)
      check "daveey" notin view
      check "Baseline" notin view
      for other in 0 ..< SeatCount:
        check seatAliasName(other) in view

  test "the system prompt names the aliases and never a policy":
    check "RED-1" in SystemPrompt or "BLUE-1" in SystemPrompt
    check "daveey" notin SystemPrompt
    check "PARTNER" in SystemPrompt
    check "radio" in SystemPrompt.toLowerAscii()
