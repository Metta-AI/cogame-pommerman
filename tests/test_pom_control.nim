## Bounded orders and legality on the scripted baselines, the fallback
## identity, the survival override, and the reply validator's repair rules.

import std/[json, random, strutils, unicode, unittest]
import helpers

const VerbNames = ["go", "bomb", "hunt", "break", "hide", "kick", "follow"]

proc validate(sim: SimServer, seat: int, directive: SeatDirective) =
  ## The reply schema, applied to a SCRIPTED directive: a verb in the enum,
  ## `go` coordinates on the board, a `hunt` target that is a LIVING ENEMY, a
  ## `kick` dir in the enum, a radio of exactly two integers in [1, 8], and a
  ## serialised directive within its cap.
  let order = directive.order
  check $order.kind in VerbNames
  check ($order.kind).runeLen <= MaxVerbRunes
  check directive.say.runeLen <= MaxSayRunes
  check directive.notes.runeLen <= MaxNoteRunes
  check directive.radio.a >= RadioLow and directive.radio.a <= RadioHigh
  check directive.radio.b >= RadioLow and directive.radio.b <= RadioHigh
  case order.kind
  of okGo:
    check order.x >= 0 and order.x < BoardSize
    check order.y >= 0 and order.y < BoardSize
  of okHunt:
    check order.target >= 0 and order.target < SeatCount
    check teamOfSeat(order.target) != teamOfSeat(seat)
    check sim.bombers[order.target].alive
  of okKick:
    check order.dir >= 0 and order.dir < DirNames.len
    check DirNames[order.dir].runeLen <= MaxDirRunes
  else:
    discard
  let record = directive.boundedDirectiveRecord(1, seat, newJNull(), newJNull())
  check record.runeLen <= MaxDirectiveRunes
  discard parseJson(record)

suite "pommerman control and baselines":

  test "baselines are bounded":
    ## 200 pseudo-random world states -- varying alive sets, ammo, blast, kick,
    ## live bombs, collapsed rings, both variants -- against BOTH baselines. A
    ## baseline that ever proposes an illegal or unbounded order fails the
    ## build.
    var rng = initRand(1234)
    for iteration in 0 ..< 200:
      let maxTicks = (if iteration mod 2 == 0: 144 else: 96)
      var sim = playingSim(maxTicks = maxTicks, seed = 1 + iteration)
      sim.tick = rng.rand(0 ..< maxTicks)
      for seat in 0 ..< SeatCount:
        sim.bombers[seat].x = 1 + rng.rand(0 .. 8)
        sim.bombers[seat].y = 1 + rng.rand(0 .. 8)
        if not isPassage(sim.board, sim.bombers[seat].x, sim.bombers[seat].y):
          sim.board.terrain[
            cellIndex(sim.bombers[seat].x, sim.bombers[seat].y)] = tPassage
        sim.bombers[seat].ammo = rng.rand(0 .. sim.config.maxAmmo)
        sim.bombers[seat].blast =
          sim.config.startBlast + rng.rand(0 .. 2)
        sim.bombers[seat].kick = rng.rand(0 .. 1) == 1
      ## never kill BOTH of a team: the baselines are only asked for orders in
      ## a live game, and a wiped team ends it
      sim.bombers[rng.rand(0 .. 1)].alive = rng.rand(0 .. 2) > 0
      if rng.rand(0 .. 2) == 0:
        sim.applyCollapse(1)
      for _ in 0 .. rng.rand(0 .. 5):
        let
          bx = 1 + rng.rand(0 .. 8)
          by = 1 + rng.rand(0 .. 8)
        if isPassage(sim.board, bx, by) and
            bombIndexAt(sim.bombs, bx, by) < 0:
          discard sim.addBomb(rng.rand(0 ..< SeatCount), bx, by,
            fuse = 1 + rng.rand(0 .. 8), blast = 2 + rng.rand(0 .. 3))
      for seat in 0 ..< SeatCount:
        if not sim.bombers[seat].alive:
          continue
        for baseline in [blSapper, blCamper]:
          let directive = scriptedDirective(sim, seat, baseline)
          checkpoint("iteration " & $iteration & " seat " & $seat &
            " baseline " & $baseline)
          validate(sim, seat, directive)
          check directive.say.len == 0
          check directive.notes.len == 0
          ## and the controller turns it into a LEGAL action
          sim.applyOrders(seat, directive)
      let danger = sim.dangerNow()
      for seat in 0 ..< SeatCount:
        if sim.bombers[seat].alive:
          let action = chooseAction(sim, seat, danger)
          check ord(action) >= ord(acStay) and ord(action) <= ord(acBomb)

  test "sapper walks its ladder":
    block bombsAnEnemyInLane:
      var sim = openBoard()
      sim.place(0, 5, 5, ammo = 1)
      sim.place(1, 6, 5)
      sim.place(2, 1, 1)
      sim.place(3, 9, 9)
      check sapperDirective(sim, 0).order.kind == okBomb
    block bombsWood:
      var sim = openBoard()
      sim.place(0, 5, 5, ammo = 1)
      sim.place(1, 1, 1)
      sim.place(2, 9, 1)
      sim.place(3, 9, 9)
      sim.board.terrain[cellIndex(5, 6)] = tWood
      check sapperDirective(sim, 0).order.kind == okBomb
    block goesForAPowerUp:
      var sim = openBoard()
      sim.place(0, 5, 5, ammo = 0)
      sim.place(1, 1, 1)
      sim.place(2, 9, 1)
      sim.place(3, 9, 9)
      sim.board.item[cellIndex(5, 8)] = ikIncrRange
      let directive = sapperDirective(sim, 0)
      check directive.order.kind == okGo
      check directive.order.x == 5 and directive.order.y == 8
    block huntsWhenNothingIsLeft:
      var sim = openBoard()
      sim.place(0, 5, 5, ammo = 0)
      sim.place(1, 1, 1)
      sim.place(2, 9, 1)
      sim.place(3, 9, 9)
      let directive = sapperDirective(sim, 0)
      check directive.order.kind == okHunt
      check teamOfSeat(directive.order.target) == TeamBlue
    block radioIsLegible:
      var sim = openBoard()
      sim.place(0, 5, 5, ammo = 3)
      sim.place(1, 6, 5)
      sim.place(2, 9, 1)
      sim.place(3, 9, 9)
      let pair = sapperDirective(sim, 0).radio
      check pair.a == 4               ## ammo + 1
      check pair.b == 2               ## one enemy within four cells, + 1

  test "camper is silent and cautious":
    block bombsOnlyAnAdjacentEnemy:
      var sim = openBoard()
      sim.place(0, 5, 5, ammo = 1)
      sim.place(1, 6, 5)
      sim.place(2, 9, 1)
      sim.place(3, 9, 9)
      let directive = camperDirective(sim, 0)
      check directive.order.kind == okBomb
      check directive.radio.a == 1 and directive.radio.b == 1
    block hidesWithNothingNear:
      var sim = openBoard()
      sim.place(0, 5, 5, ammo = 1)
      sim.place(1, 1, 1)
      sim.place(2, 9, 1)
      sim.place(3, 9, 9)
      check camperDirective(sim, 0).order.kind == okHide
    block refusesAWallWithOneExit:
      var sim = openBoard()
      sim.place(0, 1, 1, ammo = 1)
      sim.place(1, 9, 9)
      sim.place(2, 9, 1)
      sim.place(3, 1, 9)
      ## box the bomber in so only one orthogonal neighbour is open
      sim.board.terrain[cellIndex(2, 1)] = tWood
      sim.board.terrain[cellIndex(1, 2)] = tRigid
      check camperDirective(sim, 0).order.kind != okBomb

  test "the fallback IS the sapper proc":
    ## The decision engine's fallback and the published `sapper` baseline
    ## resolve to the same order, field for field, so they cannot drift.
    var rng = initRand(99)
    for iteration in 0 ..< 40:
      var sim = playingSim(seed = 3 + iteration)
      sim.tick = rng.rand(0 .. 130)
      for seat in 0 ..< SeatCount:
        sim.bombers[seat].ammo = rng.rand(0 .. 3)
        sim.bombers[seat].kick = rng.rand(0 .. 1) == 1
      for seat in 0 ..< SeatCount:
        let
          baseline = sapperDirective(sim, seat)
          fallback = fallbackDirective(sim, seat)
        check fallback.source == dsFallback
        check fallback.order.kind == baseline.order.kind
        check fallback.order.x == baseline.order.x
        check fallback.order.y == baseline.order.y
        check fallback.order.target == baseline.order.target
        check fallback.order.dir == baseline.order.dir
        check fallback.radio == baseline.radio

  test "the controller never suicides on its own order":
    ## For a spread of states, a controller asked to bomb / hunt / break either
    ## lays a bomb from which the escape BFS finds a safe cell, or lays none;
    ## and a bomber whose own cell is in danger always takes the escape step,
    ## whatever the order.
    var rng = initRand(4242)
    for iteration in 0 ..< 500:
      var sim = playingSim(seed = 5 + iteration mod 60)
      sim.tick = 1 + rng.rand(0 .. 100)
      for seat in 0 ..< SeatCount:
        sim.bombers[seat].ammo = 1 + rng.rand(0 .. 2)
        sim.bombers[seat].blast = 2 + rng.rand(0 .. 3)
      for _ in 0 .. rng.rand(0 .. 3):
        let
          bx = 1 + rng.rand(0 .. 8)
          by = 1 + rng.rand(0 .. 8)
        if isPassage(sim.board, bx, by) and bombIndexAt(sim.bombs, bx, by) < 0:
          discard sim.addBomb(rng.rand(0 ..< SeatCount), bx, by,
            fuse = 1 + rng.rand(0 .. 6), blast = 2 + rng.rand(0 .. 2))
      let verb = [okBomb, okHunt, okBreak][iteration mod 3]
      for seat in 0 ..< SeatCount:
        sim.setOrder(seat, verb,
          target = (if verb == okHunt: (seat + 1) mod SeatCount else: -1))
      let danger = sim.dangerNow()
      for seat in 0 ..< SeatCount:
        let action = chooseAction(sim, seat, danger)
        if action == acBomb:
          checkpoint("iteration " & $iteration & " seat " & $seat)
          check escapeExistsAfterBomb(sim, seat)
        if danger.firstDangerAt(sim.bombers[seat].x,
            sim.bombers[seat].y) >= 0:
          ## the override runs ahead of the order: a bomb is never laid from a
          ## burning cell
          check action != acBomb

    block deadEndStillKills:
      ## THE OVERRIDE IS NOT A SHIELD. A bomber boxed into a dead end with a
      ## lit fuse dies, which is exactly how Pommerman is won.
      var sim = openBoard()
      sim.place(0, 1, 1)
      sim.place(1, 9, 9)
      sim.place(2, 9, 1)
      sim.place(3, 1, 9)
      sim.board.terrain[cellIndex(2, 1)] = tRigid
      discard sim.addBomb(1, 1, 2, fuse = 1, blast = 3)
      let danger = sim.dangerNow()
      check danger.firstDangerAt(1, 1) >= 0
      let escape = escapeStep(sim, 0, danger)
      check not escape.found
      var idle: array[SeatCount, Action]
      inc sim.tick
      sim.resolveTick(idle)
      check not sim.bombers[0].alive

  test "a kick with nothing to shove is exactly `hide`":
    ## The Step C table says a `kick` that cannot fire -- no `kick` power-up, or
    ## no bomb in that direction -- behaves as `hide`. It does, and from a safe
    ## cell `hide` IS standing still: chooseAction only reaches Step C when the
    ## bomber's own cell is out of danger (Step B, the survival override,
    ## returns first otherwise), and hideTarget scores every cell that is never
    ## dangerous inside the horizon identically and breaks the tie by FEWEST
    ## STEPS -- which the bomber's own cell wins at zero. This test pins the
    ## equivalence rather than the resulting action, so a change to either
    ## branch that pulls them apart is red here.
    var rng = initRand(8080)
    var degraded = 0
    for iteration in 0 ..< 200:
      var sim = playingSim(seed = 3 + iteration mod 40)
      sim.tick = 1 + rng.rand(0 .. 100)
      for seat in 0 ..< SeatCount:
        sim.bombers[seat].ammo = rng.rand(0 .. 3)
        sim.bombers[seat].kick = rng.rand(0 .. 1) == 1
      for _ in 0 .. rng.rand(0 .. 3):
        let
          bx = 1 + rng.rand(0 .. 8)
          by = 1 + rng.rand(0 .. 8)
        if isPassage(sim.board, bx, by) and bombIndexAt(sim.bombs, bx, by) < 0:
          discard sim.addBomb(rng.rand(0 ..< SeatCount), bx, by,
            fuse = 1 + rng.rand(0 .. 6), blast = 2 + rng.rand(0 .. 2))
      let danger = sim.dangerNow()
      for seat in 0 ..< SeatCount:
        let me = sim.bombers[seat]
        if not me.alive:
          continue
        if danger.firstDangerAt(me.x, me.y) >= 0:
          continue                      ## Step B owns this state, not Step C
        for dir in 0 ..< DirOffsets.len:
          let offset = DirOffsets[dir]
          if me.kick and
              bombIndexAt(sim.bombs, me.x + offset.dx, me.y + offset.dy) >= 0:
            continue                    ## this kick really fires
          inc degraded
          sim.setOrder(seat, okKick, dir = dir)
          let kicked = chooseAction(sim, seat, danger)
          sim.setOrder(seat, okHide)
          checkpoint("iteration " & $iteration & " seat " & $seat &
            " dir " & DirNames[dir])
          check kicked == chooseAction(sim, seat, danger)
    check degraded > 500

  test "reply validation":
    var sim = playingSim()
    let previous = sapperDirective(sim, 0)
    var livingEnemies: set[uint8] = {1'u8, 3'u8}
    let nearest = sim.nearestEnemy(0)

    proc parse(node: JsonNode): SeatDirective =
      parseSeatDirective(node, 0, previous, sim.board, livingEnemies, nearest)

    block accepted:
      let directive = parse(parseJson("""{
        "order": {"verb": "hunt", "target": "BLUE-1"},
        "radio": [3, 7],
        "say": "boxing him against the SE lattice",
        "notes": "3 means I am out of ammo"
      }"""))
      check directive.order.kind == okHunt
      check directive.order.target == 1
      check directive.radio.a == 3 and directive.radio.b == 7
      check directive.say == "boxing him against the SE lattice"
      check directive.notes == "3 means I am out of ammo"
      check directive.rejected == 0

    block orderArray:
      ## An array is accepted and its FIRST element used.
      let directive = parse(parseJson(
        """{"order": [{"verb": "hide"}, {"verb": "bomb"}]}"""))
      check directive.order.kind == okHide

    block unknownVerbKeepsThePrevious:
      let directive = parse(parseJson("""{"order": {"verb": "teleport"}}"""))
      check directive.order.kind == previous.order.kind
      check directive.rejected == 1

    block deadHuntTargetRetargets:
      var dead = playingSim()
      dead.bombers[1].alive = false
      let directive = parseSeatDirective(
        parseJson("""{"order": {"verb": "hunt", "target": "BLUE-1"}}"""),
        0, previous, dead.board, {3'u8}, dead.nearestEnemy(0))
      check directive.order.kind == okHunt
      check directive.order.target == 3
      check directive.rejected == 1

    block coordinatesClamp:
      let directive = parse(parseJson(
        """{"order": {"verb": "go", "x": 9999, "y": -40}}"""))
      check directive.order.x >= 0 and directive.order.x < BoardSize
      check directive.order.y >= 0 and directive.order.y < BoardSize
      check isPassage(sim.board, directive.order.x, directive.order.y)
      check directive.rejected > 0

    block radioClampsAndRepeats:
      let clamped = parse(parseJson("""{"radio": [99, -3]}"""))
      check clamped.radio.a == RadioHigh
      check clamped.radio.b == RadioLow
      let malformed = parse(parseJson("""{"radio": [1]}"""))
      check malformed.radio == previous.radio
      check malformed.rejected == 1
      let missing = parse(parseJson("""{"order": {"verb": "hide"}}"""))
      check missing.radio == previous.radio

    block radioWithoutAnOrderIsUsable:
      ## The radio is a first-class output, not a rider on the order.
      let directive = parse(parseJson("""{"radio": [4, 4]}"""))
      check directive.radio.a == 4 and directive.radio.b == 4
      check directive.order.kind == previous.order.kind
      check not directive.order.fromReply

    block kickDirection:
      let ok = parse(parseJson(
        """{"order": {"verb": "kick", "dir": "left"}}"""))
      check ok.order.kind == okKick
      check DirNames[ok.order.dir] == "left"
      let bad = parse(parseJson(
        """{"order": {"verb": "kick", "dir": "sideways"}}"""))
      check bad.order.dir == -1
      check bad.rejected == 1

    block verbNormalisation:
      check parseOrderKind("  BREAK ").kind == okBreak
      check parseOrderKind("Hide").kind == okHide
      check parseOrderKind("FOLLOW").ok

    block nonObjectIsAHardFailure:
      expect DirectiveError:
        discard parse(parseJson("""[1, 2, 3]"""))
      expect DirectiveError:
        discard extractJsonObject("no braces at all here")

    block runeBoundaries:
      ## 4-byte emoji sitting EXACTLY on every cap. The cut lands on a rune
      ## boundary, so the record stays valid UTF-8 -- a byte cut here is what
      ## makes a replay render in a browser and then fail a strict parser.
      var say = ""
      for _ in 0 ..< 200:
        say.add("\u{1F525}")
      var notes = ""
      for _ in 0 ..< 400:
        notes.add("\u{1F6E1}")
      let directive = parse(%*{"say": say, "notes": notes, "radio": [2, 2]})
      check directive.say.runeLen == MaxSayRunes
      check directive.notes.runeLen == MaxNoteRunes
      check directive.say.validateUtf8() == -1
      check directive.notes.validateUtf8() == -1
      let record = directive.boundedDirectiveRecord(
        7, 0, newJNull(), newJNull())
      check record.validateUtf8() == -1
      check record.runeLen <= MaxDirectiveRunes
      discard parseJson(record)          ## still valid JSON after trimming

    block directiveRecordFitsWithAView:
      ## The observation is far bigger than the cap, so the bounded record must
      ## shed it rather than emit truncated JSON.
      var engine = initDecisionEngine(sim.config)
      var withView = previous
      withView.say = "x".repeat(90)
      let record = withView.boundedDirectiveRecord(
        3, 0, newJNull(), engine.seatView(sim, 0, includeNotes = false))
      check record.runeLen <= MaxDirectiveRunes
      discard parseJson(record)

    block fullCapSaySurvivesWithARealView:
      ## The record an LLM seat really writes: episode.runTurnIfDue always
      ## passes a REAL observation (decide.nim assigns lastView every turn), so
      ## a record measured with `view = newJNull()` proves nothing about the
      ## shipped path. A full-cap 100-rune `say` must reach the replay WITH the
      ## view beside it -- an emptied `say` is a spectator seeing none of what
      ## the model said, and the feed only emits a `say` event when it is
      ## non-empty (broadcast.nim).
      var engine = initDecisionEngine(sim.config)
      var say = ""
      for _ in 0 ..< MaxSayRunes:
        say.add("\u{1F525}")
      var spoken = previous
      spoken.source = dsLlm
      spoken.say = sanitizeSay(say)
      check spoken.say.runeLen == MaxSayRunes
      let view = engine.seatView(sim, 0, includeNotes = false)
      check view.kind == JObject
      let record = spoken.boundedDirectiveRecord(9, 0, %[3, 7], view)
      check record.runeLen <= MaxDirectiveRunes
      check record.validateUtf8() == -1
      let parsed = parseJson(record)
      check parsed["say"].getStr().runeLen == MaxSayRunes
      check parsed["say"].getStr() == spoken.say
      check parsed["view"].kind == JObject
      check parsed["view"]["you"].getStr() == seatAliasName(0)
      ## ...and with the bomb pool full, which is the widest observation the
      ## rules can produce. The view may shed here; the `say` never may.
      var crowded = sim
      for index in 0 ..< MaxBombs:
        discard crowded.addBomb(3, 9, 9, fuse = 8, blast = crowded.config.maxBlast)
      let crowdedRecord = spoken.boundedDirectiveRecord(
        9, 0, %[3, 7], engine.seatView(crowded, 0, includeNotes = false))
      check crowdedRecord.runeLen <= MaxDirectiveRunes
      let crowdedParsed = parseJson(crowdedRecord)
      check crowdedParsed["say"].getStr().runeLen == MaxSayRunes
      check crowdedParsed["view"].kind == JObject

    block replyByteCap:
      ## MaxReplyBytes is a BYTE budget: a rune cut there would admit up to
      ## 4 x 8192 bytes into parseJson.
      var emoji = ""
      while emoji.len <= MaxReplyBytes * 2:
        emoji.add("\u{1F525}")
      let cut = emoji.truncateBytes(MaxReplyBytes)
      check cut.len <= MaxReplyBytes
      check cut.len > MaxReplyBytes - 4
      check cut.validateUtf8() == -1

    block extractionIsTolerant:
      let fenced = "Here is my plan:\n```json\n" &
        "{\"order\":{\"verb\":\"break\"},\"radio\":[1,2]}\n```\nGood luck."
      let directive = parse(extractJsonObject(fenced))
      check directive.order.kind == okBreak
      check directive.radio.b == 2

    block neverUnactuated:
      ## Whatever the reply, the seat always has a legal order afterwards.
      for text in ["{}", """{"order":{}}""", """{"order":{"verb":""}}""",
                   """{"radio":"nonsense"}"""]:
        let directive = parse(parseJson(text))
        check $directive.order.kind in VerbNames

  test "baseline tuning is the swept pick":
    let tuning = parseJson(readRepoFile("tools/ci/baseline_tuning.json"))
    check DefaultBaselineParams.bombEnemyRange ==
      tuning["bombEnemyRange"].getInt()
    check DefaultBaselineParams.powerupSearch == tuning["powerupSearch"].getInt()
    check DefaultBaselineParams.dodgeHorizon == tuning["dodgeHorizon"].getInt()
    check DefaultBaselineParams.campExits == tuning["campExits"].getInt()
    check DefaultBaseline == blSapper
    ## anything unrecognised is the published default
    check parseBaseline("") == DefaultBaseline
    check parseBaseline("nonsense") == DefaultBaseline
    check parseBaseline("CAMPER") == blCamper
    check parseBaseline(" sapper ") == blSapper
