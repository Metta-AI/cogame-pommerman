## End-to-end episodes, driven through the SAME `episode.nim` frame proc the
## live server calls -- so the test and production can never run two different
## loops.

import std/[json, os, sets, strutils, unittest]
import helpers
import pommerman/[broadcast, replay_runtime]

proc resultKeys(sim: SimServer): HashSet[string] =
  for key, _ in parseJson(sim.bomberResultsJson()).pairs:
    result.incl(key)

suite "pommerman engine":

  test "episode writes artifacts":
    let path = getTempDir() / "pom-engine-episode.replay"
    removeFile(path)
    var config = testConfig(maxTicks = 144)
    let run = runScriptedEpisode(config, path)
    check fileExists(path)
    check getFileSize(path) > 1000
    let results = parseJson(run.sim.bomberResultsJson())
    check results["reason"].getStr() == ReasonComplete
    var total = 0
    for entry in results["scores"]:
      total += entry.getInt()
    check total == 0
    ## both teammates share a score
    check results["scores"][0].getInt() == results["scores"][2].getInt()
    check results["scores"][1].getInt() == results["scores"][3].getInt()
    check results["aliases"][0].getStr() == "RED-1"
    check results["aliases"][1].getStr() == "BLUE-1"
    check results["aliases"][2].getStr() == "RED-2"
    check results["aliases"][3].getStr() == "BLUE-2"
    check results["teams"][0].getStr() == "RED"
    check results["teams"][1].getStr() == "BLUE"
    check results["endRule"].getStr() in
      [EndRuleWipe, EndRuleTickCap, EndRuleWallClock]
    check results["radioSent"][0].getInt() > 0
    ## the results key set equals the manifest's results_schema key set EXACTLY
    var declared: HashSet[string]
    for key, _ in manifestJson()["game"]["results_schema"]["properties"].pairs:
      declared.incl(key)
    check resultKeys(run.sim) == declared
    removeFile(path)

  test "both variants play a whole episode":
    ## Not just the fixture's config: a config-scaled construct that fits the
    ## small fixture and breaks the big variant is exactly the collab-cooking
    ## 0.1.1 failure.
    for variant in manifestJson()["variants"]:
      var config = defaultGameConfig()
      config.update($variant["game_config"])
      config.turnSpacingMs = 0
      config.gameOverTicks = 1
      config.lobbyJoinTimeoutTicks = 1
      config.startWaitTicks = 0
      config.seed = 1234
      let run = runScriptedEpisode(config)
      checkpoint(variant["id"].getStr())
      check run.state.finished
      check run.sim.gameLog.len == 1
      check run.sim.endReason == ReasonComplete
      check run.sim.turnsPlayed > 0
      var total = 0
      for seat in 0 ..< SeatCount:
        total += run.sim.scoreOf(seat)
      check total == 0

  test "no seat can stall":
    ## A seat that connects then never answers, and a seat that never connects
    ## at all, both produce a finished episode inside the wall-clock budget,
    ## with fallbackTurns counted, deadSeats set, and exactly one closed-schema
    ## failure payload.
    var config = testConfig(maxTicks = 48)
    let run = runScriptedEpisode(config, joinSeats = {0'u8, 1'u8, 2'u8})
    check run.state.finished
    check run.sim.gameLog.len == 1
    check run.sim.endReason == ReasonComplete
    check run.sim.deadSeats[3]
    check not run.sim.deadSeats[0]
    check run.state.failureSlot == 3
    let payload = parseJson(playerFailurePayload(
      run.state.failureSlot,
      "player slot 3 never joined the lobby within 1 lobby ticks; its bomber " &
      "plays the sapper baseline"))
    var keys: HashSet[string]
    for key, _ in payload.pairs:
      keys.incl(key)
    check keys == ["message", "failed_policy_index"].toHashSet()
    check payload["failed_policy_index"].getInt() == 3
    check payload["message"].getStr().len > 0
    ## and every turn of the empty seat is recorded with cause `disconnected`
    var disconnected = 0
    for record in parseReplayBytes(run.bytes).chats:
      if "\"k\":\"fallback\"" in record.text:
        let node = parseJson(record.text)
        check node["slot"].getInt() == 3
        check node["cause"].getStr() == "disconnected"
        inc disconnected
    check disconnected > 0

  test "an LLM seat with no credentials counts as a fallback, not a score":
    ## The client disables itself with no credentials, so every turn is a
    ## fallback and both are COUNTABLE -- llmTurns 0 with fallbackTurns 0 for
    ## an episode that was nothing but fallbacks is the bug this asserts
    ## against.
    var config = testConfig(maxTicks = 48)
    var engine = initDecisionEngine(config)
    engine.seats[0].isLlm = true
    engine.seats[0].prompt = "win by not dying"
    engine.seats[0].label = "firestarter"
    for seat in 1 ..< SeatCount:
      engine.seats[seat].baseline = blSapper
    let run = runHeadlessEpisode(config, engine, "")
    check run.sim.llmTurns[0] == 0
    check run.sim.fallbackTurns[0] > 0
    check run.sim.fallbackTurns[1] == 0
    check run.sim.endReason == ReasonComplete
    check run.sim.gameLog.len == 1

  test "a missing register record is loud":
    ## The grf-football scar: a lost register packet made a champion play
    ## scripted for a whole episode with latency_ms 0 and no error anywhere.
    ## A seat that joined but never registered is named in the log and reported
    ## in `unregistered`, with policyKinds scripted and deadSeats false.
    var config = testConfig(maxTicks = 24)
    var sim = initSimServer(config)
    var engine = initDecisionEngine(config)
    var state = initEpisodeState()
    var writer = openReplayWriter("", config.configJson())
    for seat in 0 ..< SeatCount:
      sim.admitSeat(seat, "")
      if seat != 2:
        sim.registered[seat] = true
    discard state.maybeStartFirstGame(sim, writer)
    check state.unregistered == @[2]
    check sim.seatPolicyKind[2] == "scripted"
    check not sim.deadSeats[2]

  test "the tier-2 event stream emits every kind it declares":
    var config = testConfig(maxTicks = 144)
    var sim = initSimServer(config)
    sim.collectEvents = true
    sim.applyGameStart(0)
    var engine = initDecisionEngine(config)
    engine.seats[0].isLlm = true            ## no credentials: it falls back
    engine.seats[0].prompt = "hold the centre"
    var state = initEpisodeState()
    var writer = openReplayWriter("", config.configJson())
    for seat in 0 ..< SeatCount:
      sim.admitSeat(seat, "")
    var guard = 0
    while sim.phase == Playing and guard < 4000:
      discard state.runEpisodeFrame(sim, engine, writer, 0)
      inc guard
    var kinds: HashSet[string]
    for event in sim.events:
      kinds.incl($event.kind)
    checkpoint("emitted kinds: " & $kinds)
    for kind in ["turn_start", "fallback", "directive", "radio", "bomb_placed",
                 "explosion", "wood_cleared", "collapse", "phase_change"]:
      checkpoint(kind)
      check kind in kinds
    ## the mandatory summary row still closes the stream
    let stream = eventsJsonl(sim.events, sim.tick)
    check "\"type\":\"summary\"" in stream
    check stream.endsWith("\n")

  test "budget guard settles early":
    ## With the guard forced (a wall-clock budget smaller than two turns), the
    ## LLM is switched off for the rest of the episode, a budget_guard record
    ## names the turn, and the episode still ends `complete` -- not `deadline`.
    var config = testConfig(maxTicks = 48)
    config.wallClockBudgetSeconds = 10
    config.turnBudgetMs = 12000
    var engine = initDecisionEngine(config)
    for seat in 0 ..< SeatCount:
      engine.seats[seat].isLlm = true
      engine.seats[seat].prompt = "hunt"
    var sim = initSimServer(config)
    sim.applyGameStart(0)
    let records = engine.turn(sim, 1, 0)
    check engine.llmOff
    var sawGuard = false
    for record in records:
      if "\"k\":\"budget_guard\"" in record:
        sawGuard = true
        check parseJson(record)["turn"].getInt() == 1
    check sawGuard
    let run = runHeadlessEpisode(config, engine, "")
    check run.sim.endReason == ReasonComplete

  test "the wall-clock stop settles and reports deadline":
    var config = testConfig(maxTicks = 144)
    var engine = scriptedEngine(config)
    var sim = initSimServer(config)
    var state = initEpisodeState()
    var writer = openReplayWriter("", config.configJson())
    for seat in 0 ..< SeatCount:
      sim.admitSeat(seat, "")
    for _ in 0 ..< 20:
      discard state.runEpisodeFrame(sim, engine, writer, 0)
    discard state.runEpisodeFrame(
      sim, engine, writer, config.wallClockBudgetSeconds)
    check state.stopped
    check state.finished
    check sim.endReason == ReasonDeadline
    check sim.gameLog[^1].endRule == EndRuleWallClock
    check sim.stopDetail.len > 0
    state.finishEpisode(sim, writer)
    let results = parseJson(sim.bomberResultsJson())
    check results["reason"].getStr() == ReasonDeadline
    var total = 0
    for entry in results["scores"]:
      total += entry.getInt()
    check total == 0

  test "the state packet the viewer consumes is well formed":
    var config = testConfig(maxTicks = 48)
    let run = runScriptedEpisode(config)
    var
      data = parseReplayBytes(run.bytes)
      initialized = initReplayRuntime(data)
      tracker = initBroadcastTracker()
    let packet = parseJson(buildStateJson(
      initialized.sim, initialized.player, tracker, newJArray(), false))
    for key in ["t", "st", "mx", "mt", "ph", "pl", "sp", "en", "teams",
                "roster", "pm", "lulls", "beats", "lead"]:
      checkpoint(key)
      check packet.hasKey(key)
    for key in ["board", "bombs", "danger", "bombers", "seats", "alive",
                "kills", "wood", "turn", "turns", "tick", "maxTicks",
                "collapse", "mismatchTick", "events", "endcard"]:
      checkpoint("pm." & key)
      check packet["pm"].hasKey(key)
    ## chrome_common's momentum graph reads teams[team].lives, which is the
    ## team's LIVING BOMBER COUNT here
    check packet["teams"]["red"].hasKey("lives")
    check packet["lead"]["teams"][0].getStr() == "red"
    check packet["roster"].len == SeatCount
    check packet["pm"]["seats"].len == SeatCount
    check packet["pm"]["bombers"].len == SeatCount
    check packet["pm"]["board"]["terrain"].len == BoardSize
    check packet["pm"]["danger"].len == BoardSize
    ## the board rows are 11 characters and never draw a bomb or a bomber
    for row in packet["pm"]["board"]["terrain"]:
      check row.getStr().len == BoardSize
      for ch in row.getStr():
        check ch in {'#', 'W', '.', '*', 'e', 'r', 'k'}
