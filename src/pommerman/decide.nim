## Game-owned simultaneous turn exchange, action validation, and fallback.
## Player containers own scripted, prompt, Jev, or neural policy decisions.

import std/json
import sim, baselines, observation

type
  SeatPolicy* = object
    isLlm*: bool
    baseline*: Baseline
    label*: string
    registered*: bool

  ActionExchange* = proc(
    turn: int, views: array[SeatCount, JsonNode], deadlineMs: int
  ): array[SeatCount, JsonNode] {.closure.}

  DecisionEngine* = object
    seats*: array[SeatCount, SeatPolicy]
    notes*: array[SeatCount, string]
    lastView*: array[SeatCount, JsonNode]
    lastRadioIn*: array[SeatCount, JsonNode]
    params*: BaselineParams
    budgetGuardFired*: bool

proc initDecisionEngine*(): DecisionEngine =
  result.params = DefaultBaselineParams
  for seat in 0 ..< SeatCount:
    result.seats[seat].baseline = DefaultBaseline
    result.seats[seat].label = $DefaultBaseline
    result.lastView[seat] = newJNull()
    result.lastRadioIn[seat] = newJNull()

proc policyKind*(engine: DecisionEngine, seat: int): string =
  if seat >= 0 and seat < SeatCount and engine.seats[seat].isLlm: "llm"
  else: "scripted"

proc fallbackRecord*(
  turn, seat, attempt: int, cause, detail: string
): string =
  $(%*{
    "k": "fallback",
    "turn": turn,
    "slot": seat,
    "attempt": attempt,
    "cause": cause,
    "detail": detail.sanitizeLine(MaxFallbackDetailRunes)
  })

proc registerRecord*(seat: int, policy, kind, baseline: string): string =
  ## The REDACTED registration record. The seat's prompt is never written:
  ## only the policy label, the kind, and which baseline a scripted seat picked.
  $(%*{
    "k": "register",
    "slot": seat,
    "alias": seatAliasName(seat),
    "team": teamName(teamOfSeat(seat)),
    "policy": policy.truncateRunes(MaxPolicyLabelRunes),
    "kind": kind,
    "baseline": baseline
  })

proc budgetGuardRecord*(turn, remainingSeconds: int): string =
  $(%*{"k": "budget_guard", "turn": turn, "remaining_s": remainingSeconds})

# ---------------------------------------------------------------------------
#  The turn
# ---------------------------------------------------------------------------

proc turn*(
  engine: var DecisionEngine, sim: var SimServer,
  turnIndex, elapsedSeconds: int, exchange: ActionExchange = nil
): seq[string] =
  ## All four observations are made from the same pre-action state. The
  ## exchange sends them together and has one bounded deadline; no policy can
  ## see another seat's action before choosing its own.
  sim.turnIndex = turnIndex
  sim.mailbox.deliver()
  let turnSeconds = (sim.config.turnBudgetMs + 999) div 1000
  if elapsedSeconds + 2 * turnSeconds > sim.config.wallClockBudgetSeconds:
    if not engine.budgetGuardFired:
      result.add(budgetGuardRecord(turnIndex,
        max(0, sim.config.wallClockBudgetSeconds - elapsedSeconds)))
      engine.budgetGuardFired = true

  var views: array[SeatCount, JsonNode]
  for seat in 0 ..< SeatCount:
    engine.lastRadioIn[seat] = radioInJson(sim, seat)
    engine.lastView[seat] = seatView(sim, seat)
    views[seat] = seatView(sim, seat, engine.notes[seat],
      includeNotes = true)

  var replies: array[SeatCount, JsonNode]
  if exchange != nil and not engine.budgetGuardFired:
    replies = exchange(turnIndex, views, sim.config.turnBudgetMs)

  for seat in 0 ..< SeatCount:
    if exchange == nil and not engine.seats[seat].isLlm:
      sim.applyOrders(seat,
        scriptedDirective(sim, seat, engine.seats[seat].baseline,
          engine.params))
      if not sim.joined[seat]:
        result.add(fallbackRecord(turnIndex, seat, 1, "disconnected",
          "seat never joined; its bomber plays the scripted baseline"))
      continue
    let reply = replies[seat]
    if reply.isNil or reply.kind != JObject or
        reply{"action"}.isNil or reply{"action"}.kind != JObject:
      var directive = fallbackDirective(sim, seat, engine.params)
      directive.say = ""
      sim.applyOrders(seat, directive)
      let cause =
        if not sim.joined[seat]: "disconnected"
        elif engine.budgetGuardFired: "budget_guard"
        elif exchange == nil: "no_player"
        elif reply.isNil: "timeout"
        else: "parse_error"
      result.add(fallbackRecord(turnIndex, seat, 1, cause,
        "seat did not return a valid action before the turn deadline"))
      continue

    var livingEnemies: set[uint8]
    for other in 0 ..< SeatCount:
      if teamOfSeat(other) != teamOfSeat(seat) and sim.bombers[other].alive:
        livingEnemies.incl(uint8(other))
    let near = sim.nearestEnemy(seat)
    let fallbackTarget = if near >= 0: near else: (seat + 1) mod SeatCount
    let action = reply["action"]
    var directive = parseSeatDirective(action, seat,
      sim.directives[seat], sim.board, livingEnemies, fallbackTarget)
    directive.source =
      if reply{"source"}.getStr() == "fallback": dsFallback
      elif engine.seats[seat].isLlm: dsLlm
      else: dsScripted
    directive.latencyMs = max(0, reply{"latency_ms"}.getInt())
    engine.notes[seat] = directive.notes
    sim.ordersRejected[seat] += directive.rejected
    sim.applyOrders(seat, directive)
    if directive.source == dsFallback:
      result.add(fallbackRecord(turnIndex, seat, 1,
        reply{"cause"}.getStr("player_fallback"),
        "player used its policy fallback"))
