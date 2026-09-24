## Persistent numeric decision bridge for Metta RL and native PufferLib.

import std/[json, os]
import pommerman/[sim, baselines, decide, directives, llm]

const
  Variants = ["teams", "blitz"]
  Verbs = ["break", "bomb", "go", "hunt", "hide", "kick", "follow"]
  Terrain = [".", "#", "W", "*", "e", "r", "k"]
  Motion = ["none", "up", "down", "left", "right"]

proc seedOf(value: string): int =
  var hash = 2166136261'u32
  for ch in value:
    hash = (hash xor uint32(ord(ch))) * 16777619'u32
  int(hash and 0x7fffffff'u32)

proc options(width: int): JsonNode =
  result = newJArray()
  for value in 0 ..< width:
    result.add(%value)

proc heads(view: JsonNode): JsonNode =
  var enemies = newJArray()
  for alias in view["enemies"]:
    let other = parseSeatAlias(alias.getStr())
    enemies.add(if view["bombers"][other]["alive"].getBool(): alias
      else: newJNull())
  %*[
    {"name": "verb", "choices": Verbs},
    {"name": "target", "choices": enemies},
    {"name": "x", "choices": options(BoardSize)},
    {"name": "y", "choices": options(BoardSize)},
    {"name": "dir", "choices": DirNames},
    {"name": "radio_a", "choices": [1, 2, 3, 4, 5, 6, 7, 8]},
    {"name": "radio_b", "choices": [1, 2, 3, 4, 5, 6, 7, 8]}
  ]

proc teacherAction(directive: SeatDirective, view: JsonNode): JsonNode =
  var target = view["enemies"][0]
  if not view["bombers"][parseSeatAlias(target.getStr())]["alive"].getBool():
    target = view["enemies"][1]
  if directive.order.kind == okHunt:
    target = %seatAliasName(directive.order.target)
  %*{
    "verb": $directive.order.kind, "target": target,
    "x": directive.order.x, "y": directive.order.y,
    "dir": (if directive.order.dir >= 0: DirNames[directive.order.dir]
      else: DirNames[0]),
    "radio_a": directive.radio.a, "radio_b": directive.radio.b
  }

proc decision(engine: DecisionEngine, game: SimServer, seat, id: int): JsonNode =
  let view = engine.seatView(game, seat, includeNotes = false)
  let catalog = heads(view)
  var fields = newJObject()
  for head in catalog:
    var legal = newJArray()
    for choice in head["choices"]:
      if choice.kind != JNull: legal.add(choice)
    fields[head["name"].getStr()] = %*{"enum": legal}
  let messageView = engine.seatView(game, seat, includeNotes = true)
  %*{
    "kind": "decision", "game": "pommerman", "decision_id": id,
    "seat": seat, "engine_seat": seat, "turn": game.turnIndex,
    "semantic_view": view, "inbox": [],
    "messages": [
      {"role": "system", "content": SystemPrompt},
      {"role": "user", "content": userMessage("", $messageView)}
    ],
    "speech_messages": [],
    "action_schema": {"type": "object", "properties": fields,
      "required": ["verb", "target", "x", "y", "dir", "radio_a", "radio_b"]},
    "typed_question": newJNull()
  }

proc code(value: string, catalog: openArray[string]): int =
  for index, choice in catalog:
    if value == choice: return index
  raise newException(ValueError, "unknown visible cell value: " & value)

proc encoding(engine: DecisionEngine, game: SimServer,
              seat, id: int, variant: string): JsonNode =
  let view = engine.seatView(game, seat, includeNotes = false)
  var values = newJArray()
  for name in Variants:
    values.add(%(if name == variant: 1 else: 0))
  for other in 0 ..< SeatCount:
    values.add(%(if other == seat: 1 else: 0))
  for key in ["turn", "of", "tick", "ticks_left", "score_now"]:
    values.add(view[key])
  for key in ["next_tick", "next_ring"]:
    values.add(view["collapse"][key])
  let radio = view["radio_from_teammate"]
  values.add(%(if radio.kind == JArray: radio[0].getInt() else: 0))
  values.add(%(if radio.kind == JArray: radio[1].getInt() else: 0))
  values.add(%code(view["your_last_order"]["verb"].getStr(), Verbs))
  for row in view["board"]:
    doAssert row.getStr().len == BoardSize
    for ch in row.getStr():
      values.add(%code($ch, Terrain))
  for row in view["danger"]:
    doAssert row.getStr().len == BoardSize
    for ch in row.getStr():
      values.add(%(if ch == '.': -1 else: ord(ch) - ord('0')))
  for bomber in view["bombers"]:
    for key in ["x", "y", "ammo", "range"]:
      values.add(bomber[key])
    values.add(%(if bomber["alive"].getBool(): 1 else: 0))
    values.add(%(if bomber["kick"].getBool(): 1 else: 0))
  var fuse, blast, owner, moving: array[BoardCells, int]
  for bomb in view["bombs"]:
    let at = bomb["y"].getInt() * BoardSize + bomb["x"].getInt()
    fuse[at] = bomb["fuse"].getInt()
    blast[at] = bomb["range"].getInt()
    owner[at] = parseSeatAlias(bomb["owner"].getStr()) + 1
    moving[at] = code(bomb["moving"].getStr(), Motion)
  for at in 0 ..< BoardCells:
    for value in [fuse[at], blast[at], owner[at], moving[at]]:
      values.add(%value)
  %*{"decision_id": id, "values": values,
    "action_heads": heads(view)}

when isMainModule:
  let args = commandLineParams()
  if args.len != 2:
    quit("usage: pommerman-train-bridge MANIFEST VARIANT", 1)
  let variant = args[1]
  let manifest = parseFile(args[0])
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = copy(entry["game_config"])
  doAssert variantConfig.kind == JObject
  var
    game: SimServer
    engine: DecisionEngine
    teacher: array[SeatCount, SeatDirective]
    seat = 0
    id = 0
    baselineOffset = 0
  while not stdin.endOfFile:
    let request = parseJson(stdin.readLine())
    var response: JsonNode
    case request["kind"].getStr()
    of "reset":
      doAssert request["players"].getInt() == SeatCount
      let seed = seedOf(request["seed"].getStr())
      variantConfig["seed"] = %seed
      var config = defaultGameConfig()
      config.update($variantConfig)
      game = initSimServer(config)
      game.applyGameStart(0)
      game.turnIndex = 1
      game.mailbox.deliver()
      engine = default(DecisionEngine)
      baselineOffset = seed mod 2
      for other in 0 ..< SeatCount:
        let baseline = if (baselineOffset + other) mod 2 == 0:
          blSapper else: blCamper
        teacher[other] = scriptedDirective(game, other, baseline)
      seat = 0
      id = 0
      response = engine.decision(game, seat, id)
    of "encode":
      doAssert game.phase == Playing
      response = engine.encoding(game, seat, id, variant)
    of "teacher":
      doAssert game.phase == Playing
      let view = engine.seatView(game, seat, includeNotes = false)
      response = %*{"response": $teacherAction(teacher[seat], view)}
    of "step":
      doAssert game.phase == Playing and request["decision_id"].getInt() == id
      let chosen = parseJson(request["response"].getStr())
      let view = engine.seatView(game, seat, includeNotes = false)
      for head in heads(view):
        let name = head["name"].getStr()
        doAssert chosen[name] in head["choices"], "action is masked: " & name
      let reply = %*{
        "order": {"verb": chosen["verb"], "target": chosen["target"],
          "x": chosen["x"], "y": chosen["y"], "dir": chosen["dir"]},
        "radio": [chosen["radio_a"], chosen["radio_b"]],
        "say": "", "notes": ""
      }
      var livingEnemies: set[uint8]
      for other in 0 ..< SeatCount:
        if teamOfSeat(other) != teamOfSeat(seat) and game.bombers[other].alive:
          livingEnemies.incl(uint8(other))
      let directive = parseSeatDirective(reply, seat, game.directives[seat],
        game.board, livingEnemies, game.nearestEnemy(seat))
      game.applyOrders(seat, directive)
      inc seat
      if seat == SeatCount:
        inc game.turnsPlayed
        while game.phase == Playing:
          game.advanceFrame()
          if game.tick mod game.config.turnTicks == 0:
            break
        if game.phase == Playing:
          game.turnIndex = game.tick div game.config.turnTicks + 1
          game.mailbox.deliver()
          for other in 0 ..< SeatCount:
            let baseline = if (baselineOffset + other) mod 2 == 0:
              blSapper else: blCamper
            teacher[other] = scriptedDirective(game, other, baseline)
        seat = 0
      inc id
      var observation: JsonNode
      if game.phase == GameOver:
        var scores = newJObject()
        for other in 0 ..< SeatCount:
          scores[$other] = %game.scoreOf(other)
        observation = %*{"kind": "terminal", "scores": scores}
      else:
        observation = engine.decision(game, seat, id)
      response = %*{"kind": "accepted", "action": chosen,
        "observation": observation}
    else:
      raise newException(ValueError, "unknown command: " & request["kind"].getStr())
    stdout.writeLine($response)
    stdout.flushFile()
