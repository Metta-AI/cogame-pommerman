## Replay-only regression: use the committed certification fixture, with no
## decisions, model calls, newly recorded episodes or policy execution.
import std/[json, os, strutils, tables, unittest]
import pommerman/[observation, replay_runtime, replays, roster, sim]

proc fixture(): ReplayData =
  loadReplay(currentSourcePath().parentDir() / "replays" / "pommerman.replay")

suite "pommerman replay partner radio":
  test "recorded partner inboxes survive playback and seeks":
    let data = fixture()
    var expected = initTable[int, array[SeatCount, JsonNode]]()
    var commandFrames: seq[int]
    var mailbox = initRadioMailbox()
    for record in data.orders:
      if record.tick notin commandFrames:
        commandFrames.add(record.tick)
    for frame in commandFrames:
      mailbox.deliver()
      var inboxes: array[SeatCount, JsonNode]
      for seat in 0 ..< SeatCount:
        let inbox = mailbox.receive(teamOfSeat(seat), seat)
        inboxes[seat] =
          if inbox.has: %[inbox.pair.a, inbox.pair.b] else: newJNull()
      expected[frame] = inboxes
      for record in data.orders:
        if record.tick == frame:
          mailbox.send(teamOfSeat(record.slot), record.slot, record.radio)

    var initialized = initReplayRuntime(data, mismatchQuit = true)
    var player = initialized.player
    var sim = initialized.sim
    sim.applySeatIdentities(data)
    var recordedChecks = 0
    while true:
      let frame = player.frame - 1
      if expected.hasKey(frame):
        for seat in 0 ..< SeatCount:
          check radioInJson(sim, seat) == expected[frame][seat]
        for record in data.chats:
          if record.tick != frame or not record.text.startsWith("{"):
            continue
          let node = parseJson(record.text)
          if node{"k"}.getStr() == "directive":
            check node["radio_in"] == expected[frame][node["slot"].getInt()]
            inc recordedChecks
      if player.frame > player.maxFrame:
        break
      player.advanceReplayFrame(sim)
    check recordedChecks == 140
    check player.hashMismatchTick == -1
    check sim.tick == 138
    check [sim.scoreOf(0), sim.scoreOf(1), sim.scoreOf(2), sim.scoreOf(3)] ==
      [174, -174, 174, -174]

    # Scrub out of order: reset must rebuild the same previous-turn inbox,
    # and frames between command turns must not deliver the current turn early.
    for i in countdown(commandFrames.high, 0):
      let frame = commandFrames[i]
      for target in [frame, frame + 1, frame + 2, frame]:
        player.seekTo(sim, target)
        for seat in 0 ..< SeatCount:
          check radioInJson(sim, seat) == expected[frame][seat]
        check player.hashMismatchTick == -1

  test "opposing radio cannot influence a recipient's observation":
    let data = fixture()
    for seat in 0 ..< SeatCount:
      # Generated negative input: change only the opposing team's sent pairs
      # in memory. Its old hashes are deliberately removed; it is not being
      # certified as the retained replay or written as a new recording.
      var changed = data
      changed.hashes = @[]
      for order in changed.orders.mitems:
        if teamOfSeat(order.slot) != teamOfSeat(seat):
          order.radio = clampPair(8, 8)
      var a = initReplayRuntime(data, mismatchQuit = true)
      var b = initReplayRuntime(changed)
      for record in data.orders:
        if record.slot != seat:
          continue
        a.player.seekTo(a.sim, record.tick)
        b.player.seekTo(b.sim, record.tick)
        check seatView(a.sim, seat) == seatView(b.sim, seat)
      expect SimGuardError:
        discard b.sim.mailbox.receive(1 - teamOfSeat(seat), seat)
      expect SimGuardError:
        b.sim.mailbox.send(1 - teamOfSeat(seat), seat, defaultPair())
