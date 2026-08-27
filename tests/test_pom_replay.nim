## Replay tests: record -> re-derive for EVERY end reason, self-sufficiency of
## the bytes, determinism, the strict-UTF-8 JSON view, and the fixture version
## sweep.

import std/[json, os, osproc, strutils, unicode, unittest]
import helpers
import pommerman/[broadcast, replay_runtime]

proc rederive(bytes: string): tuple[
  player: ReplayPlayer, sim: SimServer, mismatch: int
] =
  var
    data = parseReplayBytes(bytes)
    initialized = initReplayRuntime(data, mismatchQuit = false)
  var
    player = initialized.player
    sim = initialized.sim
  sim.applyJoinRecords(data)
  for record in data.chats:
    sim.applyReplayChat(record.text)
  var guard = 0
  while player.frame <= player.maxFrame and guard < 100000:
    player.advanceReplayFrame(sim)
    inc guard
  (player, sim, player.hashMismatchTick)

suite "pommerman replay":

  test "record then re-derive, every end reason":
    ## wipe, tickCap, wallClock AND fault. A wall-clock or fault stop cannot be
    ## re-derived from sim state, so it is recorded as ONE load-bearing record
    ## applied by the same proc on both sides -- the particle-worlds scar was a
    ## stop banked outside the stepping proc, which hash-mismatched at the stop
    ## tick on every slow-LLM episode.
    block wipe:
      var config = testConfig(maxTicks = 144)
      var found = false
      for seed in [42, 7, 99, 5, 11]:
        config.seed = seed
        let run = runScriptedEpisode(config)
        if run.sim.gameLog[0].endRule != EndRuleWipe:
          continue
        found = true
        let redone = rederive(run.bytes)
        check redone.mismatch == -1
        check redone.sim.gameLog.len == run.sim.gameLog.len
        check redone.sim.scoreOf(0) == run.sim.scoreOf(0)
        check redone.sim.gameLog[0].alive == run.sim.gameLog[0].alive
        check redone.sim.gameLog[0].ticks == run.sim.gameLog[0].ticks
        check redone.sim.gameLog[0].endRule == run.sim.gameLog[0].endRule
        break
      check found

    block tickCap:
      ## Every seat hides forever with the rings disabled, so nobody dies and
      ## the game runs to the cap.
      var config = testConfig(maxTicks = 16)
      config.collapseTicks = @[]
      var sim = initSimServer(config)
      var state = initEpisodeState()
      var writer = openReplayWriter("", config.configJson())
      for seat in 0 ..< SeatCount:
        sim.admitSeat(seat, "")
      discard state.maybeStartFirstGame(sim, writer)
      while not state.finished and state.frame < 400:
        if sim.phase == Playing and sim.tick mod config.turnTicks == 0:
          for seat in 0 ..< SeatCount:
            var directive = defaultDirective()
            directive.order = BomberOrder(
              kind: okHide, target: -1, dir: -1, fromReply: true)
            sim.applyOrders(seat, directive)
            writer.writeOrder(state.frame,
              sim.tick div config.turnTicks + 1, seat, directive.order,
              directive.radio)
        discard state.advanceEpisodeFrame(sim, writer)
        discard state.maybeNextGame(sim, writer)
        inc state.frame
      state.finishEpisode(sim, writer)
      check sim.gameLog[0].endRule == EndRuleTickCap
      check sim.aliveOnTeam(TeamRed) == 2
      check sim.aliveOnTeam(TeamBlue) == 2
      let redone = rederive(writer.bytes())
      check redone.mismatch == -1
      check redone.sim.gameLog[0].endRule == EndRuleTickCap

    block wallClock:
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
      state.finishEpisode(sim, writer)
      check sim.gameLog[^1].endRule == EndRuleWallClock
      let redone = rederive(writer.bytes())
      check redone.mismatch == -1
      check redone.sim.gameLog[^1].endRule == EndRuleWallClock
      check redone.sim.gameLog[^1].alive == sim.gameLog[^1].alive

    block fault:
      ## A fault stop takes the same load-bearing path.
      var config = testConfig(maxTicks = 144)
      var engine = scriptedEngine(config)
      var sim = initSimServer(config)
      var state = initEpisodeState()
      var writer = openReplayWriter("", config.configJson())
      for seat in 0 ..< SeatCount:
        sim.admitSeat(seat, "")
      for _ in 0 ..< 12:
        discard state.runEpisodeFrame(sim, engine, writer, 0)
      sim.endReason = ReasonFault
      sim.stopDetail = "a tripped sim invariant, for the test"
      writer.writeStop(state.frame, EndRuleFault)
      sim.applyStop(EndRuleFault)
      state.finished = true
      inc state.frame
      state.finishEpisode(sim, writer)
      check sim.gameLog[^1].endRule == EndRuleFault
      let redone = rederive(writer.bytes())
      check redone.mismatch == -1
      check redone.sim.gameLog[^1].endRule == EndRuleFault

  test "a divergent bit is CAUGHT, at the tick it happens":
    ## The chain is only worth having if it fires. Corrupt one recorded hash and
    ## the re-derivation must report that exact tick.
    var config = testConfig(maxTicks = 48)
    let run = runScriptedEpisode(config)
    var data = parseReplayBytes(run.bytes)
    check data.hashes.len > 20
    let target = data.hashes[10].tick
    var bytes = run.bytes
    var at = 0
    var patched = false
    while at < bytes.len:
      let index = bytes.find("\x06", at)
      if index < 0:
        break
      at = index + 1
      if index + 13 > bytes.len:
        break
      var tick = 0
      for shift in 0 ..< 4:
        tick = tick or (int(uint8(bytes[index + 1 + shift])) shl (shift * 8))
      if tick == target:
        bytes[index + 5] = char(uint8(bytes[index + 5]) xor 0xff'u8)
        patched = true
        break
    check patched
    let redone = rederive(bytes)
    check redone.mismatch == target

  test "replay is self-sufficient":
    ## The bytes alone yield the seat names, the aliases, the teams, the policy
    ## kinds, the full config, the seed, every order record INCLUDING BOTH
    ## RADIO INTEGERS, every chat record and the result. No server is contacted.
    var config = testConfig(maxTicks = 48)
    config.seed = 1734029581
    var engine = scriptedEngine(config)
    engine.seats[0].label = "pommerman-firestarter"
    engine.seats[1].label = "pommerman-cornerman"
    let run = runHeadlessEpisode(config, engine, "")
    let data = parseReplayBytes(run.bytes)
    check data.gameName == GameName
    check data.gameVersion == GameVersion
    check data.configField("seed") == "1734029581"
    check data.configField("protocol") == ProtocolId
    check data.configField("boardSize") == $BoardSize
    check data.joins.len == SeatCount
    check data.orders.len >= SeatCount
    check data.gameStarts.len == 1
    check data.hashes.len >= data.frameCount - 2
    var sawRadio = false
    for record in data.orders:
      check record.radio.a >= RadioLow and record.radio.a <= RadioHigh
      check record.radio.b >= RadioLow and record.radio.b <= RadioHigh
      if record.radio.a != 1 or record.radio.b != 1:
        sawRadio = true
    check sawRadio
    var sawResult = false
    for record in data.chats:
      if "\"k\":\"result\"" in record.text:
        sawResult = true
        let results = parseJson(record.text)["results"]
        check results["reason"].getStr() == ReasonComplete
        check results["aliases"][0].getStr() == "RED-1"
        check results["policyKinds"].len == SeatCount
        check results["radioSent"].len == SeatCount
    check sawResult

  test "two episodes with the same seed and the same orders are identical":
    var config = testConfig(maxTicks = 96)
    let first = runScriptedEpisode(config)
    let second = runScriptedEpisode(config)
    check first.bytes == second.bytes
    check first.sim.scoreOf(0) == second.sim.scoreOf(0)

  test "the hash chain covers the whole episode, tick by tick":
    var config = testConfig(maxTicks = 96)
    let run = runScriptedEpisode(config)
    let data = parseReplayBytes(run.bytes)
    check data.hashes.len > 20
    for i in 1 ..< data.hashes.len:
      check data.hashes[i].tick > data.hashes[i - 1].tick
    var seenHashes: seq[uint64]
    for record in data.hashes:
      if record.value notin seenHashes:
        seenHashes.add(record.value)
    check seenHashes.len > data.hashes.len div 2

  test "replay_summary is strict UTF-8 JSON":
    ## Every capped field filled to EXACTLY its cap with 4-byte emoji, then
    ## read back through the stdlib-only Python view of the bytes.
    var config = testConfig(maxTicks = 40)
    var sim = initSimServer(config)
    var state = initEpisodeState()
    var writer = openReplayWriter("", config.configJson())
    var engine = scriptedEngine(config)
    for seat in 0 ..< SeatCount:
      sim.admitSeat(seat, "")
      writer.writeJoin(0, seat, seatAliasOf(seat), "")
      writer.writeChat(0, seat, registerRecord(
        seat, "pommerman-firestarter", "llm", "sapper"))
    discard state.maybeStartFirstGame(sim, writer)
    var say = ""
    for _ in 0 ..< 400:
      say.add("\u{1F525}")
    var notes = ""
    for _ in 0 ..< 600:
      notes.add("\u{1F6E1}")
    while not state.finished and state.frame < 4000:
      if sim.phase == Playing and sim.tick mod config.turnTicks == 0:
        let turnIndex = sim.tick div config.turnTicks + 1
        for seat in 0 ..< SeatCount:
          var directive = sapperDirective(sim, seat)
          directive.source = dsLlm
          directive.say = sanitizeSay(say)
          directive.notes = sanitizeLine(notes, MaxNoteRunes)
          check directive.say.runeLen <= MaxSayRunes
          sim.applyOrders(seat, directive)
          writer.writeOrder(state.frame, turnIndex, seat, directive.order,
            directive.radio)
          writer.writeChat(state.frame, seat,
            directive.boundedDirectiveRecord(
              turnIndex, seat, newJNull(), newJNull()))
      discard state.advanceEpisodeFrame(sim, writer)
      discard state.maybeNextGame(sim, writer)
      inc state.frame
    state.finishEpisode(sim, writer)
    let path = getTempDir() / "pom-summary-fixture.replay"
    writeFile(path, writer.bytes())
    let summaryPath = getTempDir() / "pom-summary-fixture.json"
    let command = "python3 " &
      quoteShell(repoRoot() / "tools/replay_summary.py") &
      " " & quoteShell(path) & " > " & quoteShell(summaryPath)
    let code = execCmd(command)
    check code == 0
    let raw = readFile(summaryPath)
    ## STRICT: no lone surrogates, no byte-truncated codepoints
    check raw.validateUtf8() == -1
    let summary = parseJson(raw)
    check summary["protocol"].getStr() == ProtocolId
    check summary["gameVersion"].getStr() == GameVersion
    check summary["tickCount"].getInt() > 0
    check summary["directives"].len > 0
    check summary["radio"].len > 0
    check summary["orders"].len > 0
    for directive in summary["directives"]:
      check directive["say"].getStr().validateUtf8() == -1
      check directive["say"].getStr().runeLen <= MaxSayRunes
    for order in summary["orders"]:
      check order["source"].getStr() == "llm"
    check summary["results"]["reason"].getStr() in
      [ReasonComplete, ReasonDeadline]
    removeFile(path)
    removeFile(summaryPath)

  test "every committed fixture carries the current GameVersion":
    ## The starter's sweep over tests/, kept: a fixture recorded against older
    ## rules fails HERE rather than three CI jobs later.
    var seen = 0
    for path in walkDirRec(repoRoot() / "tests"):
      if not path.endsWith(".replay"):
        continue
      inc seen
      let data = parseReplayBytes(readFile(path))
      checkpoint(path)
      check data.gameName == GameName
      check data.gameVersion == GameVersion
      check data.hashes.len > 0
      let redone = rederive(readFile(path))
      check redone.mismatch == -1
    ## The committed fixture is the replay CI's own docker-smoke produced,
    ## downloaded from the `smoke-replay` artifact and committed -- so it is a
    ## real, current-format episode of this game rather than a hand-written
    ## file that drifts from the writer.
    ## The committed fixture is a real episode of the CERTIFICATION FIXTURE's
    ## own config -- sapper x2 against camper x2, recorded through
    ## `episode.runHeadlessEpisode`, the same proc the live server drives -- so
    ## it cannot drift from the writer the way a hand-written file would.
    check seen >= 1
    check repoFileExists("tests/replays/pommerman.replay")
