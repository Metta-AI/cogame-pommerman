## The decision layer: the per-turn loop that asks all four seats what their
## bomber does next, and always has an answer.
##
## Cadence: one turn every `turnTicks` (4 ticks), 36 turns per episode. At each
## turn the server builds ALL FOUR seats' request bodies and issues them as ONE
## PARALLEL BATCH -- this is a simultaneous-decision game, so querying seats one
## after another would quadruple the wall clock for nothing. At most 4 calls in
## flight; at most 4 x 36 x 2 = 288 calls an episode including retries.
##
## DEGRADE, NEVER HANG. Every wait is bounded: attempt 1 gets `attempt1Ms`, the
## single retry gets `retryMs`, and the whole turn sits inside a monotonic
## `turnBudgetMs` deadline. A provider throttle with no other candidate model
## skips the retry outright. On a second failure the seat plays the `sapper`
## scripted order for that turn and a `fallback` record names the cause. No
## failure mode leaves a bomber unactuated: the control layer always has an
## order -- this turn's, else last turn's, else `sapper`'s.

import std/[json, monotimes, os, strutils, times]
import curly
import sim, baselines, llm

type
  SeatPolicy* = object
    ## What one seat registered as. A seat that registers with neither field --
    ## or never registers at all -- is `sapper`.
    isLlm*: bool
    prompt*: string
    baseline*: Baseline
    label*: string
    registered*: bool

  DecisionEngine* = object
    client*: LlmClient
    seats*: array[SeatCount, SeatPolicy]
    notes*: array[SeatCount, string]
    lastBatchStart*: MonoTime
    batchStarted*: bool
    llmOff*: bool              ## the budget guard fired; scripted from here on
    lastView*: array[SeatCount, JsonNode]
    lastRadioIn*: array[SeatCount, JsonNode]
    params*: BaselineParams
      ## The swept tunables (tools/tune_baselines.nim). Held on the engine so
      ## the sweep can drive a whole episode with one candidate set without
      ## touching the shipped defaults.

proc initDecisionEngine*(config: GameConfig): DecisionEngine =
  result.client = newLlmClient(config)
  result.params = DefaultBaselineParams
  for seat in 0 ..< SeatCount:
    result.seats[seat].baseline = DefaultBaseline
    result.seats[seat].label = $DefaultBaseline
    result.lastView[seat] = newJNull()
    result.lastRadioIn[seat] = newJNull()

proc policyKind*(engine: DecisionEngine, seat: int): string =
  if seat >= 0 and seat < SeatCount and engine.seats[seat].isLlm: "llm"
  else: "scripted"

# ---------------------------------------------------------------------------
#  The per-seat observation
# ---------------------------------------------------------------------------

proc radioInJson*(sim: SimServer, seat: int): JsonNode =
  ## What this seat may read: its OWN partner's pair, exactly one turn late.
  ## The opposing team's pairs are NEVER in any observation, at any delay --
  ## `radio.receive` is the only path from a seat index to a pair and it checks
  ## the team on every call.
  let inbox = sim.mailbox.receive(teamOfSeat(seat), seat)
  if not inbox.has:
    return newJNull()
  %[inbox.pair.a, inbox.pair.b]

proc seatView*(
  engine: DecisionEngine, sim: SimServer, seat: int, includeNotes: bool
): JsonNode =
  ## Everything this seat may legitimately know. The whole board -- terrain,
  ## flames, every bomb with its fuse and blast, every dropped power-up, every
  ## bomber's position, ammo, blast and kick flag -- plus the DECODED danger
  ## grid. Hidden: the opposing team's radio integers, what lies under unbroken
  ## wood, every other seat's order/notes/prompt, and every seat's REAL policy
  ## and player name, including its own partner's.
  let
    team = teamOfSeat(seat)
    danger = sim.dangerNow(9)
    upcoming = nextCollapse(sim.config, sim.tick)
  var bombsNode = newJArray()
  for bomb in sim.bombs:
    bombsNode.add(%*{
      "x": bomb.x, "y": bomb.y, "fuse": bomb.fuse, "range": bomb.blast,
      "owner": seatAliasName(bomb.owner), "moving": $bomb.velocity})
  var bombersNode = newJArray()
  for other in 0 ..< SeatCount:
    ## Always all four, dead ones included, in the fixed alias order, so the
    ## array shape never changes.
    bombersNode.add(%*{
      "id": seatAliasName(other),
      "x": sim.bombers[other].x,
      "y": sim.bombers[other].y,
      "alive": sim.bombers[other].alive,
      "ammo": sim.bombers[other].ammo,
      "range": sim.bombers[other].blast,
      "kick": sim.bombers[other].kick})
  var enemies = newJArray()
  for other in 0 ..< SeatCount:
    if teamOfSeat(other) != team:
      enemies.add(%seatAliasName(other))
  var collapsed = newJArray()
  for ring in 1 .. sim.board.collapsedRings:
    collapsed.add(%ring)
  var boardRows = newJArray()
  for row in sim.board.terrainRows():
    boardRows.add(%row)
  var dangerRowsNode = newJArray()
  for row in danger.dangerRows():
    dangerRowsNode.add(%row)
  result = %*{
    "you": seatAliasName(seat),
    "team": TeamNamesUpper[team],
    "teammate": seatAliasName(partnerOfSeat(seat)),
    "enemies": enemies,
    "turn": sim.turnIndex,
    "of": sim.turnsPerGame(),
    "tick": sim.tick,
    "ticks_left": max(0, sim.config.maxTicks - sim.tick),
    "turn_ticks": sim.config.turnTicks,
    "collapse": {
      "next_tick": upcoming.tick,
      "next_ring": upcoming.ring,
      "collapsed_rings": collapsed
    },
    "legend": "# rigid  W wood  . passage  * flame  " &
      "e extra-bomb  r range  k kick",
    "board": boardRows,
    "danger": dangerRowsNode,
    "bombs": bombsNode,
    "bombers": bombersNode,
    "radio_from_teammate": radioInJson(sim, seat),
    "your_last_order": {
      "verb": $sim.directives[seat].order.kind,
      "arg": orderArgJson(sim.directives[seat].order)
    },
    "score_now": sim.teamScore(team)
  }
  if includeNotes:
    result["your_notes"] = %engine.notes[seat]

# ---------------------------------------------------------------------------
#  Records
# ---------------------------------------------------------------------------

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

proc installScripted(
  engine: var DecisionEngine, sim: var SimServer, seat: int,
  baseline: Baseline
) =
  var directive = scriptedDirective(sim, seat, baseline, engine.params)
  sim.applyOrders(seat, directive)

proc installFallback(
  engine: var DecisionEngine, sim: var SimServer, seat: int
) =
  var directive = fallbackDirective(sim, seat, engine.params)
  directive.say = ""
  sim.applyOrders(seat, directive)

proc turn*(
  engine: var DecisionEngine,
  sim: var SimServer,
  turnIndex, elapsedSeconds: int
): seq[string] =
  ## Runs ONE decision turn and installs every seat's order. Returns the replay
  ## chat records this turn produced. Never raises: every failure path ends in
  ## a legal order and a legal radio pair.
  let
    budget = initDuration(milliseconds = max(1, sim.config.turnBudgetMs))
    turnStart = getMonoTime()
  sim.turnIndex = turnIndex
  ## RADIO DELIVERY, step 2 of the turn: exactly one turn late, always,
  ## including when the partner fell back (a fallback still sends a pair).
  ## Done BEFORE any observation is built.
  sim.mailbox.deliver()
  engine.client.throttled = false

  # --- budget guard: settle EARLY rather than overrun -----------------------
  if not engine.llmOff:
    let turnSeconds = (sim.config.turnBudgetMs + 999) div 1000
    if elapsedSeconds + 2 * turnSeconds > sim.config.wallClockBudgetSeconds:
      engine.llmOff = true
      result.add(budgetGuardRecord(
        turnIndex, max(0, sim.config.wallClockBudgetSeconds - elapsedSeconds)))
      echo "pommerman: budget guard fired at turn ", turnIndex,
        "; remaining turns play scripted"

  # --- which seats need a call? --------------------------------------------
  var open: seq[int]
  for seat in 0 ..< SeatCount:
    engine.lastRadioIn[seat] = radioInJson(sim, seat)
    engine.lastView[seat] = engine.seatView(sim, seat, includeNotes = false)
    if engine.seats[seat].isLlm and not engine.llmOff and
        not engine.client.disabled:
      open.add(seat)
    elif engine.seats[seat].isLlm:
      ## An LLM seat that CANNOT call the LLM this turn is a fallback, not a
      ## scripted policy, and the cause enum names both reasons.
      engine.installFallback(sim, seat)
      let cause = if engine.llmOff: "budget_guard" else: "no_credentials"
      result.add(fallbackRecord(turnIndex, seat, 1, cause,
        "the LLM is unavailable for this turn; playing sapper"))
      echo "pommerman llm: seat ", seat, " falling back to sapper (", cause,
        ") on turn ", turnIndex
    else:
      engine.installScripted(sim, seat, engine.seats[seat].baseline)
      if not sim.joined[seat]:
        ## Nobody is home on this seat: its bomber is on autopilot for the
        ## whole episode, and the replay says WHY rather than looking like a
        ## deliberate scripted filler.
        result.add(fallbackRecord(turnIndex, seat, 1, "disconnected",
          "seat never joined; its bomber plays the scripted baseline"))

  # --- the rate floor -------------------------------------------------------
  # The Bedrock sidecar caps 30 requests/minute PER EPISODE and four seats at a
  # fast turn would sit well over it. Hold the START of consecutive batches
  # `turnSpacingMs` apart, which pins the episode at 4 x 60/10 = 24 req/min.
  if open.len > 0 and engine.batchStarted and sim.config.turnSpacingMs > 0:
    let since = (getMonoTime() - engine.lastBatchStart).inMilliseconds.int
    if since < sim.config.turnSpacingMs:
      sleep(min(sim.config.turnSpacingMs, sim.config.turnSpacingMs - since))
  if open.len > 0:
    engine.lastBatchStart = getMonoTime()
    engine.batchStarted = true

  # --- up to two PARALLEL batches ------------------------------------------
  var attempt = 0
  while open.len > 0 and attempt < 2:
    if engine.client.disabled:
      break
    if getMonoTime() - turnStart >= budget:
      for seat in open:
        result.add(fallbackRecord(
          turnIndex, seat, attempt + 1, "timeout",
          "per-turn budget exhausted before attempt " & $(attempt + 1)))
      break
    let deadlineMs =
      if attempt == 0: sim.config.attempt1Ms else: sim.config.retryMs
    var batch: RequestBatch
    for seat in open:
      var view = engine.seatView(sim, seat, includeNotes = true)
      var user = $view
      if attempt > 0:
        user.add("\n\nYour previous reply was not usable. Reply with ONLY " &
          "the JSON object described above, starting with '{', carrying " &
          "\"order\" and \"radio\".")
      let request = engine.client.requestFor(
        SystemPrompt, userMessage(engine.seats[seat].prompt, user))
      batch.post(request.url, request.headers, request.body, $seat)
    let started = getMonoTime()
    # curly hands the deadline to CURLOPT_TIMEOUT, whose granularity is WHOLE
    # SECONDS, so this conversion FLOORS. sim_config rejects a sub-second
    # value, so the floor is an identity: 8000 -> 8 s inside turnBudgetMs 12 s.
    let responses = engine.client.curl.makeRequests(
      batch, max(1, deadlineMs div 1000))
    let latency = (getMonoTime() - started).inMilliseconds.int
    var stillOpen: seq[int]
    for position, seat in open:
      var cause = "parse_error"
      let captured = seat
      try:
        let text = engine.client.textOf(
          responses[position].response, responses[position].error,
          batch[position].url)
        var directive = parseSeatDirective(
          extractJsonObject(text), seat, sim.directives[seat], sim.board,
          proc (target: int): bool = sim.bombers[target].alive,
          proc (): int =
            let near = sim.nearestEnemy(captured)
            if near >= 0: near else: partnerOfSeat(captured))
        directive.source = dsLlm
        directive.latencyMs = latency
        engine.notes[seat] = directive.notes
        sim.ordersRejected[seat] += directive.rejected
        sim.applyOrders(seat, directive)
      except CatchableError as error:
        if responses[position].error.len > 0:
          cause = (if "timeout" in responses[position].error.toLowerAscii():
                     "timeout" else: "transport_error")
        elif error.msg.startsWith("llm throttled"):
          cause = "throttled"
        result.add(fallbackRecord(
          turnIndex, seat, attempt + 1, cause, error.msg))
        echo "pommerman llm: seat ", seat, " attempt ", attempt + 1,
          " failed, falling back if it fails again: ", error.msg
        stillOpen.add(seat)
    open = stillOpen
    inc attempt
    if engine.client.throttled and open.len > 0:
      # FAIL FAST. The only model answered 429, so the retry batch would be
      # refused the same way.
      echo "pommerman llm: provider throttled with no other candidate; ",
        open.len, " seat(s) fall back for turn ", turnIndex
      break

  # --- anything still open plays sapper for this turn -----------------------
  for seat in open:
    engine.installFallback(sim, seat)
    let cause =
      if engine.client.disabled or engine.client.transport == ltNone:
        "no_credentials"
      elif engine.llmOff: "budget_guard"
      elif engine.client.throttled: "throttled"
      else: "parse_error"
    result.add(fallbackRecord(turnIndex, seat, 2, cause,
      "seat fell back to the sapper order"))
    ## "falling back" is the phrase phase 60 greps the GAME log for.
    echo "pommerman llm: seat ", seat, " falling back to sapper (", cause,
      ") on turn ", turnIndex
