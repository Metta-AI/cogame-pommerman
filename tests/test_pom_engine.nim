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

  test "four seat views exchange ordinary actions before application":
    var config = testConfig(maxTicks = 24)
    var sim = initSimServer(config)
    var engine = initDecisionEngine()
    engine.seats[0].isLlm = true
    for seat in 0 ..< SeatCount:
      sim.admitSeat(seat, "")
    sim.applyGameStart(0)
    var calls = 0
    let exchange: ActionExchange = proc(
      turn: int, views: array[SeatCount, JsonNode], deadlineMs: int
    ): array[SeatCount, JsonNode] =
      inc calls
      check deadlineMs == config.turnBudgetMs
      check views[0]["slot"].getInt() == 0
      check views[0]["you"].getStr() == "RED-1"
      if turn == 1:
        for seat in 0 ..< SeatCount:
          check views[seat]["radio_from_teammate"].kind == JNull
      else:
        check views[0]["your_notes"].getStr() == "private-0"
        check views[2]["radio_from_teammate"] == %*[1, 8]
        check views[1]["radio_from_teammate"] != %*[1, 8]
      for seat in 0 ..< SeatCount - 1:
        result[seat] = %*{
          "action": {
            "order": {"verb": "hide"}, "radio": [seat + 1, 8],
            "say": "seat " & $seat, "notes": "private-" & $seat
          },
          "source": "llm", "latency_ms": 12
        }
    let first = engine.turn(sim, 1, 0, exchange)
    check calls == 1
    check first.len == 1
    check sim.directives[0].source == dsLlm
    check sim.directives[1].source == dsScripted
    check sim.directives[3].source == dsFallback
    check sim.directives[0].radio == clampPair(1, 8)
    check sim.directives[0].say == "seat 0"
    discard engine.turn(sim, 2, 0, exchange)
    check calls == 2

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
    check disconnected == run.sim.turnsPlayed
    ## `fallbackTurns` counts a POLICY that failed to answer, and the empty
    ## seat never had one: it plays the scripted baseline from the first tick,
    ## so its directives are `scripted`, not `fallback`. Conflating the two
    ## would make an absent seat look like an LLM that timed out on every turn
    ## in results.fallbackTurns, which is the number phase 60 reads. The fact
    ## is carried instead by deadSeats[3], the closed failure payload above and
    ## one `disconnected` record per turn -- all asserted here.
    check run.sim.fallbackTurns[3] == 0
    check run.sim.llmTurns[3] == 0

  test "a model seat with no player response counts as a fallback, not a score":
    ## With no external player exchange, every model turn is a
    ## fallback and both are COUNTABLE -- llmTurns 0 with fallbackTurns 0 for
    ## an episode that was nothing but fallbacks is the bug this asserts
    ## against.
    var config = testConfig(maxTicks = 48)
    var engine = initDecisionEngine()
    engine.seats[0].isLlm = true
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
    var engine = initDecisionEngine()
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
    var engine = initDecisionEngine()
    engine.seats[0].isLlm = true            ## no external reply: it falls back
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
    config.turnBudgetMs = 18000
    var engine = initDecisionEngine()
    for seat in 0 ..< SeatCount:
      engine.seats[seat].isLlm = true
    var sim = initSimServer(config)
    sim.applyGameStart(0)
    let records = engine.turn(sim, 1, 0)
    check engine.budgetGuardFired
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

  test "the LIVE frame hands its chat records to the feed":
    ## The live /global packet's feed is built by broadcast.stepEvents from the
    ## frame's chat records. Playback reads them out of the replay; live, the
    ## only source is EpisodeFrame.records -- when that stayed empty the local
    ## spectator saw no turn, order, radio, say or fallback line at all.
    var config = testConfig(maxTicks = 48)
    var sim = initSimServer(config)
    var engine = scriptedEngine(config)
    var state = initEpisodeState()
    var writer = openReplayWriter("", config.configJson())
    for seat in 0 ..< SeatCount:
      sim.admitSeat(seat, "")
    var tracker = initBroadcastTracker()
    var kinds: HashSet[string]
    var says = 0
    var guard = 0
    while sim.phase == Playing or (guard < 40 and sim.phase == Lobby):
      inc guard
      if guard > 400:
        break
      let frame = state.runEpisodeFrame(sim, engine, writer, 0)
      if frame.records.len > 0:
        ## one record per seat, plus whatever the turn itself produced
        check frame.records.len >= SeatCount
        var directives = 0
        for record in frame.records:
          if parseJson(record.text){"k"}.getStr() == "directive":
            inc directives
        check directives == SeatCount
      for event in stepEvents(sim, tracker, frame.records):
        kinds.incl(event{"k"}.getStr())
        if event{"k"}.getStr() == "say":
          inc says
    checkpoint("feed kinds: " & $kinds)
    for kind in ["turn", "order", "radio"]:
      checkpoint(kind)
      check kind in kinds
    ## the scripted baselines are silent, so no `say` line is expected here --
    ## what matters is that the records reached the feed at all
    check says == 0

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
    ## `sp` is the number the page compares its speed chips against, so it
    ## carries the half step as 0.5 rather than rounding it into 1x
    check packet["sp"].getFloat() == 1.0
    var half = initialized.player
    var halfSim = initialized.sim
    half.applyCommand(halfSim, "5")
    check parseJson(buildStateJson(
      halfSim, half, tracker, newJArray(), false))["sp"].getFloat() == 0.5
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
