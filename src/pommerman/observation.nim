## Public board state and private seat state exposed to one ordinary player.
## Teammate radio is delivered by the simulation one turn after it is sent.

import std/json
import sim

proc radioInJson*(sim: SimServer, seat: int): JsonNode =
  ## Only this seat's partner's pair is visible.
  let inbox = sim.mailbox.receive(teamOfSeat(seat), seat)
  if not inbox.has:
    return newJNull()
  %[inbox.pair.a, inbox.pair.b]

proc seatView*(
  sim: SimServer, seat: int, notes = "", includeNotes = false
): JsonNode =
  ## The board, danger, self/partner/enemy aliases, and this seat's private
  ## radio and notes. Opposing radio and other seats' notes stay hidden.
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
    result["your_notes"] = %notes
