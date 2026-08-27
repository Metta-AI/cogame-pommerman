## Join, auth, the two name spaces, and the results document.
##
## TWO NAME SPACES, and both are required. In-game the seats are `RED-1`,
## `BLUE-1`, `RED-2` and `BLUE-2`; those aliases are the only names that appear
## in an observation, a prompt, an order, a `say` or a sprite label, so a seat
## can never learn who its partner or its opponents are. The seats' REAL policy
## names live only in `results.names`, in the replay's join records and in the
## viewer's scorebug and endcard -- spectator side only, with
## `showPlayerLabels` false.

import std/[json, strutils]
import sim_types, sim_config, sim_state, replays

proc seatAliasOf*(slot: int): string =
  ## Identity-anonymous and fixed: seat 0 is RED-1 for the whole episode.
  IdentityNames[slot mod IdentityNames.len]

proc cleanPlayerName*(name: string): string =
  result = name.strip()
  for ch in result.mitems:
    if ch in {' ', '\t', '\n', '\r'}:
      ch = '_'

proc joinError*(sim: SimServer, slot: int, token: string): string =
  ## The rejection reason for bad roster credentials, or "" to admit.
  if slot < 0 or slot >= sim.config.numAgents:
    return "Player slot must be between 0 and " &
      $(sim.config.numAgents - 1) & "."
  if not sim.config.playerJoinAllowed(slot, token):
    return "Player token does not match configured slot " & $slot & "."
  ""

proc admitSeat*(sim: var SimServer, slot: int, name: string) =
  if slot < 0 or slot >= SeatCount:
    return
  sim.joined[slot] = true
  if name.len > 0:
    sim.seatNames[slot] = name
  elif sim.config.configuredPlayerName(slot).len > 0:
    sim.seatNames[slot] = sim.config.configuredPlayerName(slot)

proc seatsJoined*(sim: SimServer): int =
  for slot in 0 ..< sim.config.numAgents:
    if sim.joined[slot]:
      inc result

proc winnerNode(sim: SimServer): JsonNode =
  let team = sim.winnerTeam()
  if team < 0: newJNull() else: %TeamNamesUpper[team]

proc bomberResultsJson*(sim: SimServer): string =
  ## The CLOSED results schema, one entry per seat in every seat-indexed array.
  ## Adding a key means updating this proc, the manifest's `results_schema` and
  ## tools/ci/docker_smoke.sh's expected-key set in the same commit -- Coworld
  ## schemas are closed and undeclared keys are dropped.
  var
    names = newJArray()
    aliases = newJArray()
    teams = newJArray()
    scores = newJArray()
    win = newJArray()
    aliveNode = newJArray()
    killsNode = newJArray()
    deathsNode = newJArray()
    suicidesNode = newJArray()
    bombsNode = newJArray()
    woodNode = newJArray()
    kicksNode = newJArray()
    pickupsNode = newJArray()
    radioSentNode = newJArray()
    policyKinds = newJArray()
    llmTurns = newJArray()
    fallbackTurns = newJArray()
    ordersRejected = newJArray()
    deadSeats = newJArray()
  for seat in 0 ..< SeatCount:
    names.add(%sim.seatNames[seat])
    aliases.add(%seatAliasOf(seat))
    teams.add(%TeamNamesUpper[teamOfSeat(seat)])
    scores.add(%sim.scoreOf(seat))
    win.add(%(sim.scoreOf(seat) > 0))
    aliveNode.add(%sim.bombers[seat].alive)
    killsNode.add(%sim.seatKills[seat])
    deathsNode.add(%sim.seatDeaths[seat])
    suicidesNode.add(%sim.seatSuicides[seat])
    bombsNode.add(%sim.bombsPlaced[seat])
    woodNode.add(%sim.woodCleared[seat])
    kicksNode.add(%sim.kicks[seat])
    pickupsNode.add(%sim.pickups[seat])
    radioSentNode.add(%sim.mailbox.sentCount[seat])
    policyKinds.add(%sim.seatPolicyKind[seat])
    llmTurns.add(%sim.llmTurns[seat])
    fallbackTurns.add(%sim.fallbackTurns[seat])
    ordersRejected.add(%sim.ordersRejected[seat])
    deadSeats.add(%sim.deadSeats[seat])
  var
    teamScores = newJArray()
    teamAlive = newJArray()
    teamKills = newJArray()
    teamWood = newJArray()
  let final =
    if sim.gameLog.len > 0: sim.gameLog[^1]
    else: GameRecord(
      alive: [sim.aliveOnTeam(TeamRed), sim.aliveOnTeam(TeamBlue)],
      kills: sim.teamKills, wood: sim.teamWood, ticks: sim.tick)
  for team in 0 ..< TeamCount:
    teamScores.add(%sim.scoreOf(team))     ## seat `team` is on team `team`
    teamAlive.add(%final.alive[team])
    teamKills.add(%final.kills[team])
    teamWood.add(%final.wood[team])
  $(%*{
    "names": names,
    "aliases": aliases,
    "teams": teams,
    "scores": scores,
    "win": win,
    "winner": winnerNode(sim),
    "reason": sim.endReason,
    "endRule": (if sim.endRule.len > 0: sim.endRule else: EndRuleTickCap),
    "teamScores": teamScores,
    "teamAlive": teamAlive,
    "teamKills": teamKills,
    "teamWood": teamWood,
    "alive": aliveNode,
    "kills": killsNode,
    "deaths": deathsNode,
    "suicides": suicidesNode,
    "bombsPlaced": bombsNode,
    "woodCleared": woodNode,
    "kicks": kicksNode,
    "pickups": pickupsNode,
    "radioSent": radioSentNode,
    "finalTick": (if sim.gameLog.len > 0: sim.gameLog[^1].ticks else: sim.tick),
    "turnsPlayed": sim.turnsPlayed,
    "seed": sim.config.seed,
    "policyKinds": policyKinds,
    "llmTurns": llmTurns,
    "fallbackTurns": fallbackTurns,
    "ordersRejected": ordersRejected,
    "deadSeats": deadSeats,
    "stopDetail": sim.stopDetail.sanitizeLine(MaxStopDetailRunes)
  })

proc resultRecord*(sim: SimServer): string =
  ## The `result` control record: the whole results document, written once into
  ## the replay chat stream at episode end. It is what makes the replay
  ## self-sufficient -- without it the outcome exists only at
  ## COGAME_RESULTS_URI, which a spectator holding the bytes cannot read.
  "{\"k\":\"result\",\"results\":" & sim.bomberResultsJson() & "}"

proc playerFailurePayload*(slot: int, message: string): string =
  ## The platform's CLOSED player-failure payload: exactly `message` and
  ## `failed_policy_index`, nothing else. A third key makes the declaration
  ## unattributable, so the shape lives HERE, beside the results document.
  $(%*{"message": message, "failed_policy_index": slot})

proc applyJoinRecords*(sim: var SimServer, data: ReplayData) =
  ## Playback: the real seat names come back out of the join records, which is
  ## what lets the scorebug show them spectator-side.
  for record in data.joins:
    if record.slot >= 0 and record.slot < SeatCount:
      sim.seatNames[record.slot] = record.name
      sim.joined[record.slot] = true

proc applyReplayChat*(sim: var SimServer, text: string) =
  ## Playback: chat records are re-applied into NON-HASHED fields only. A
  ## `register` record restores the policy kind and label; a `fallback` bumps
  ## the seat's counter; a `directive` bumps llmTurns. None of this can affect
  ## the simulation.
  if text.len == 0 or text[0] != '{':
    return
  var node: JsonNode
  try:
    node = parseJson(text)
  except CatchableError:
    return
  if node.kind != JObject:
    return
  let kind = node{"k"}.getStr()
  let slot = node{"slot"}.getInt(-1)
  case kind
  of "register":
    if slot >= 0 and slot < SeatCount:
      sim.seatPolicyKind[slot] = node{"kind"}.getStr("scripted")
      sim.seatPolicyLabel[slot] = node{"policy"}.getStr()
      sim.registered[slot] = true
      if sim.seatPolicyLabel[slot].len > 0 and
          sim.seatNames[slot] == seatAliasOf(slot):
        sim.seatNames[slot] = sim.seatPolicyLabel[slot]
  of "fallback":
    if slot >= 0 and slot < SeatCount and node{"attempt"}.getInt(1) == 2:
      inc sim.fallbackTurns[slot]
  of "directive":
    if slot >= 0 and slot < SeatCount and node{"source"}.getStr() == "llm":
      inc sim.llmTurns[slot]
  of "result":
    let results = node{"results"}
    if not results.isNil and results.kind == JObject:
      sim.endReason = results{"reason"}.getStr(sim.endReason)
  else:
    discard
