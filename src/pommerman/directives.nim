## The order schema: what a commander (LLM or scripted) may say for its ONE
## bomber, how a reply is parsed TOLERANTLY, and how an illegal field is
## REPAIRED rather than the reply dropped.
##
## Both policy kinds emit the same object through this one validator, which is
## what makes the bounded-orders test in tests/test_pom_control.nim meaningful.
##
## RUNE DISCIPLINE. Every cap here is measured in runes and every truncation
## lands on a rune boundary (`truncateRunes`). Byte slicing anywhere on the
## path to the replay is forbidden.

import std/[json, strutils, unicode]
import sim_types, board, bombs, radio

type
  OrderKind* = enum
    okGo = "go"
    okBomb = "bomb"
    okHunt = "hunt"
    okBreak = "break"
    okHide = "hide"
    okKick = "kick"
    okFollow = "follow"

  BomberOrder* = object
    kind*: OrderKind
    x*, y*: int          ## go: the cell to walk to
    target*: int         ## hunt: the seat index of a living enemy
    dir*: int            ## kick: an index into board.DirOffsets
    fromReply*: bool     ## the reply really named an order this turn

  DirectiveSource* = enum
    dsLlm = "llm"
    dsScripted = "scripted"
    dsFallback = "fallback"

  SeatDirective* = object
    ## One seat's whole output for one turn.
    order*: BomberOrder
    radio*: RadioPair
    say*: string         ## <= MaxSayRunes, spectator chatter
    notes*: string       ## <= MaxNoteRunes, private, echoed back next turn
    source*: DirectiveSource
    latencyMs*: int
    rejected*: int       ## fields repaired because they did not validate

  DirectiveError* = object of ValueError

func defaultOrder*(): BomberOrder =
  ## Turn 1's default for every seat is `break`.
  BomberOrder(kind: okBreak, target: -1, dir: -1)

func defaultDirective*(): SeatDirective =
  SeatDirective(
    order: defaultOrder(), radio: defaultPair(), source: dsScripted)

proc parseOrderKind*(text: string): tuple[ok: bool, kind: OrderKind] =
  ## Tolerant: lower-cased, hyphens and spaces normalised to `_`, capped at
  ## MaxVerbRunes BEFORE matching so an oversized verb can never be a match.
  ## An unrecognised verb reports `ok = false` so the caller repairs to the
  ## seat's PREVIOUS verb instead of inventing one.
  let key = text.strip().truncateRunes(MaxVerbRunes).toLowerAscii()
    .replace("-", "_").replace(" ", "_")
  for kind in OrderKind:
    if $kind == key:
      return (true, kind)
  (false, okBreak)

proc parseDir*(text: string): tuple[ok: bool, dir: int] =
  let key = text.strip().truncateRunes(MaxDirRunes).toLowerAscii()
  for index, name in DirNames:
    if name == key:
      return (true, index)
  (false, -1)

proc parseSeatAlias*(text: string): int =
  ## The seat index an alias names, or -1. Case-insensitive, capped at
  ## MaxTargetRunes before matching.
  let key = text.strip().truncateRunes(MaxTargetRunes).toUpperAscii()
  for seat in 0 ..< SeatCount:
    if IdentityNames[seat] == key:
      return seat
  -1

proc extractJsonObject*(text: string): JsonNode =
  ## The outermost balanced `{...}` in a model reply, tolerating markdown
  ## fences and any prose the model prefixed or suffixed. Falls back to
  ## first-brace..last-brace when the scan finds no balanced pair.
  var
    depth = 0
    start = -1
    inString = false
    escaped = false
  for i, ch in text:
    if inString:
      if escaped: escaped = false
      elif ch == '\\': escaped = true
      elif ch == '"': inString = false
      continue
    case ch
    of '"': inString = true
    of '{':
      if depth == 0: start = i
      inc depth
    of '}':
      if depth > 0:
        dec depth
        if depth == 0 and start >= 0:
          try:
            return parseJson(text[start .. i])
          except CatchableError:
            start = -1
    else: discard
  let
    first = text.find('{')
    last = text.rfind('}')
  if first < 0 or last <= first:
    var head = text.strip()
    if head.runeLen > 160:
      head = head.truncateRunes(160) & "..."
    raise newException(
      DirectiveError, "no JSON object in reply: " & head.replace("\n", " "))
  parseJson(text[first .. last])

proc readInt*(node: JsonNode): tuple[ok: bool, value: int] =
  if node.isNil:
    return (false, 0)
  case node.kind
  of JInt: (true, int(node.getBiggestInt()))
  of JFloat:
    let f = node.getFloat()
    if f != f or f > 1.0e9 or f < -1.0e9: (false, 0) else: (true, int(f))
  of JString:
    try: (true, int(parseFloat(node.getStr().strip())))
    except CatchableError: (false, 0)
  else: (false, 0)

proc orderEntry(payload: JsonNode): JsonNode =
  ## The reply's `order`. An object is the documented shape; an ARRAY is
  ## accepted and its FIRST element used (models emit both).
  let node = payload{"order"}
  if node.isNil:
    return nil
  if node.kind == JObject:
    return node
  if node.kind == JArray:
    for item in node:
      if item.kind == JObject:
        return item
    return nil
  nil

proc nearestPassable*(board: Board, x, y: int): tuple[x, y: int] =
  ## The nearest passable cell to (x, y), ties by lowest y then lowest x. Used
  ## to repair a `go` that names a wall.
  if isPassage(board, x, y):
    return (x, y)
  var
    bestX = -1
    bestY = -1
    bestDist = 0
  for cy in 0 ..< BoardSize:
    for cx in 0 ..< BoardSize:
      if not isPassage(board, cx, cy):
        continue
      let d = manhattan(cx, cy, x, y)
      if bestX < 0 or d < bestDist:
        bestX = cx
        bestY = cy
        bestDist = d
  if bestX < 0: (BoardSize div 2, BoardSize div 2) else: (bestX, bestY)

proc parseSeatDirective*(
  payload: JsonNode,
  seat: int,
  previous: SeatDirective,
  board: Board,
  livingEnemy: proc (target: int): bool {.closure.},
  nearestEnemy: proc (): int {.closure.}
): SeatDirective =
  ## Turns one parsed reply into a legal directive, REPAIRING every field the
  ## schema bounds rather than rejecting the reply:
  ##
  ## * no `order` at all -> the seat KEEPS last turn's order (and the radio
  ##   still goes out: the radio is a first-class output, not a rider);
  ## * an unknown verb -> the seat's PREVIOUS verb;
  ## * `go` coordinates -> clamped into [0, 10], then retargeted to the
  ##   nearest passable cell if they name a wall;
  ## * `hunt` on an unmatched or dead alias -> the nearest living enemy;
  ## * `kick` with no direction -> the seat behaves as `hide` (control.nim);
  ## * `radio` missing, the wrong length or non-numeric -> this seat's
  ##   PREVIOUS pair; each integer clamped into [1, 8];
  ## * `say` and `notes` rune-truncated at their caps.
  ##
  ## Raises DirectiveError only when the payload is not a JSON object -- the
  ## one condition the retry and then the scripted fallback exist for.
  if payload.isNil or payload.kind != JObject:
    raise newException(DirectiveError, "reply is not a JSON object")
  result = previous
  result.source = dsLlm
  result.rejected = 0
  result.order.fromReply = false
  result.say = sanitizeSay(payload{"say"}.getStr())
  result.notes = sanitizeLine(payload{"notes"}.getStr(), MaxNoteRunes)

  let radioNode = payload{"radio"}
  block radioBlock:
    if radioNode.isNil or radioNode.kind != JArray or radioNode.len != 2:
      if not radioNode.isNil:
        inc result.rejected
      break radioBlock
    let
      a = readInt(radioNode[0])
      b = readInt(radioNode[1])
    if not a.ok or not b.ok:
      inc result.rejected
      break radioBlock
    result.radio = clampPair(a.value, b.value)

  let entry = orderEntry(payload)
  if entry.isNil:
    return
  let verb = parseOrderKind(entry{"verb"}.getStr())
  var order = BomberOrder(
    kind: (if verb.ok: verb.kind else: previous.order.kind),
    target: -1, dir: -1, fromReply: true)
  if not verb.ok:
    inc result.rejected
  case order.kind
  of okGo:
    let
      rx = readInt(entry{"x"})
      ry = readInt(entry{"y"})
    if not rx.ok or not ry.ok:
      inc result.rejected
      order.x = previous.order.x
      order.y = previous.order.y
      if not isPassage(board, order.x, order.y):
        let repaired = nearestPassable(board, order.x, order.y)
        order.x = repaired.x
        order.y = repaired.y
    else:
      order.x = clamp(rx.value, 0, BoardSize - 1)
      order.y = clamp(ry.value, 0, BoardSize - 1)
      if order.x != rx.value or order.y != ry.value:
        inc result.rejected
      if not isPassage(board, order.x, order.y):
        inc result.rejected
        let repaired = nearestPassable(board, order.x, order.y)
        order.x = repaired.x
        order.y = repaired.y
  of okHunt:
    let named = parseSeatAlias(entry{"target"}.getStr())
    if named >= 0 and teamOfSeat(named) != teamOfSeat(seat) and
        livingEnemy(named):
      order.target = named
    else:
      inc result.rejected
      order.target = nearestEnemy()
  of okKick:
    let dir = parseDir(entry{"dir"}.getStr())
    if dir.ok:
      order.dir = dir.dir
    else:
      inc result.rejected
      order.dir = -1
  else:
    discard
  result.order = order

func orderArg*(order: BomberOrder): string =
  ## The order's argument as one short spectator-facing string.
  case order.kind
  of okGo: $order.x & "," & $order.y
  of okHunt: (if order.target >= 0: seatAliasName(order.target) else: "")
  of okKick: (if order.dir >= 0: DirNames[order.dir] else: "")
  else: ""

func orderArgJson*(order: BomberOrder): JsonNode =
  case order.kind
  of okGo: %*{"x": order.x, "y": order.y}
  of okHunt:
    if order.target >= 0: %seatAliasName(order.target) else: newJNull()
  of okKick:
    if order.dir >= 0: %DirNames[order.dir] else: newJNull()
  else: newJNull()

proc directiveRecord*(
  directive: SeatDirective,
  turn, seat: int,
  radioIn: JsonNode,
  view: JsonNode
): JsonNode =
  ## The replay chat record for one turn's directive. Re-applied at playback
  ## into NON-HASHED fields only: it drives the broadcast feed and
  ## tools/replay_summary.py and can never affect the simulation. `notes` is
  ## deliberately NOT in it -- it is private to the seat.
  %*{
    "k": "directive",
    "turn": turn,
    "slot": seat,
    "alias": seatAliasName(seat),
    "team": teamName(teamOfSeat(seat)),
    "source": $directive.source,
    "latency_ms": directive.latencyMs,
    "verb": $directive.order.kind,
    "arg": orderArgJson(directive.order),
    "radio": [directive.radio.a, directive.radio.b],
    "radio_in": radioIn,
    "say": directive.say.truncateRunes(MaxSayRunes),
    "view": view
  }

proc boundedDirectiveRecord*(
  directive: SeatDirective,
  turn, seat: int,
  radioIn: JsonNode,
  view: JsonNode
): string =
  ## The serialized record, guaranteed <= MaxDirectiveRunes. `say` is the only
  ## field that can grow, so it is the one that shrinks -- and the cut still
  ## lands on a rune boundary. The SERIALIZED string is never sliced: that
  ## would emit broken JSON, the exact failure the rune rule prevents.
  var trimmed = directive
  var carriedView = view
  result = $trimmed.directiveRecord(turn, seat, radioIn, carriedView)
  var guard = 0
  while result.runeLen > MaxDirectiveRunes and guard < 24:
    inc guard
    if trimmed.say.runeLen > 0:
      trimmed.say = trimmed.say.truncateRunes(max(0, trimmed.say.runeLen - 16))
    elif carriedView.kind != JNull:
      ## The observation is the big field. A record still over its cap with an
      ## empty `say` drops the view rather than emitting truncated JSON.
      carriedView = newJNull()
    else:
      break
    result = $trimmed.directiveRecord(turn, seat, radioIn, carriedView)
