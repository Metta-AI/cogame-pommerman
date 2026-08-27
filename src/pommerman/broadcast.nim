## The broadcast layer: the per-frame state packet the viewer chrome consumes,
## the roster block, and `stepEvents` -- the derived event stream.
##
## The thirteen event kinds are DERIVED from state deltas and from the replay's
## chat records during playback, so they cost no replay bytes and are identical
## live and in replay:
##
##   turn {n}          order {seat, verb, arg}    radio {seat, team, a, b}
##   say {seat, text}  fallback {seat, cause}     bomb {seat, x, y, fuse, range}
##   kick {seat,x,y,dir}  pickup {seat,kind,x,y}  wood {x, y, team}
##   firstblood {killer, victim}                  death {victim,killer,cause,x,y}
##   collapse {ring, tick}                        end {reason, winner, alive}
##
## Only `firstblood`, `kick`, `death`, `collapse`, `fallback` and `end` become
## scrubber BEATS; the rest drive the feed (a hundred bomb markers would make
## the scrubber unreadable).

import std/[json, strutils]
import sim, replays, replay_runtime, roster, global

type
  BroadcastTracker* = object
    firstBloodSeen*: bool
    sentOnce*: bool

proc initBroadcastTracker*(): BroadcastTracker =
  discard

proc phaseText*(phase: Phase): string =
  case phase
  of Lobby: "lobby"
  of Playing: "playing"
  of GameOver: "gameover"

proc stepEvents*(
  sim: SimServer, tracker: var BroadcastTracker, chats: seq[ChatRecord]
): JsonNode =
  ## Everything that happened in the frame just stepped, in one array. A pure
  ## function of the sim delta plus the frame's chat records.
  result = newJArray()
  for bomb in sim.lastBombs:
    result.add(%*{
      "k": "bomb", "seat": bomb.seat, "x": bomb.x, "y": bomb.y,
      "fuse": bomb.fuse, "range": bomb.blast})
  for kick in sim.lastKicks:
    result.add(%*{
      "k": "kick", "seat": kick.seat, "x": kick.x, "y": kick.y,
      "dir": DirNames[kick.dir]})
  for pickup in sim.lastPickups:
    let kind =
      case pickup.kind
      of ikExtraBomb: "EXTRA BOMB"
      of ikIncrRange: "BLAST RANGE"
      of ikKick: "KICK"
      of ikNone: ""
    result.add(%*{
      "k": "pickup", "seat": pickup.seat, "kind": kind,
      "x": pickup.x, "y": pickup.y})
  for wood in sim.lastWood:
    result.add(%*{
      "k": "wood", "x": wood.x, "y": wood.y, "team": teamName(wood.team)})
  for death in sim.lastDeaths:
    if not tracker.firstBloodSeen and death.killer >= 0 and
        teamOfSeat(death.killer) != teamOfSeat(death.victim):
      tracker.firstBloodSeen = true
      result.add(%*{
        "k": "firstblood", "killer": death.killer, "victim": death.victim})
    result.add(%*{
      "k": "death", "victim": death.victim, "killer": death.killer,
      "cause": death.cause, "x": death.x, "y": death.y})
  if sim.lastCollapse > 0:
    result.add(%*{
      "k": "collapse", "ring": sim.lastCollapse, "tick": sim.tick})
  for record in chats:
    if record.text.len == 0 or record.text[0] != '{':
      continue
    var node: JsonNode
    try:
      node = parseJson(record.text)
    except CatchableError:
      continue
    if node.kind != JObject:
      continue
    case node{"k"}.getStr()
    of "directive":
      let slot = node{"slot"}.getInt(0)
      result.add(%*{"k": "turn", "n": node{"turn"}.getInt(0)})
      result.add(%*{
        "k": "order", "seat": slot, "verb": node{"verb"}.getStr(),
        "arg": (block:
          let arg = node{"arg"}
          if arg.isNil or arg.kind == JNull: ""
          elif arg.kind == JObject:
            $arg{"x"}.getInt() & "," & $arg{"y"}.getInt()
          else: arg.getStr())})
      let pair = node{"radio"}
      if not pair.isNil and pair.kind == JArray and pair.len == 2:
        result.add(%*{
          "k": "radio", "seat": slot, "team": node{"team"}.getStr(),
          "a": pair[0].getInt(), "b": pair[1].getInt()})
      let say = node{"say"}.getStr()
      if say.len > 0:
        result.add(%*{"k": "say", "seat": slot, "text": say})
    of "fallback":
      result.add(%*{
        "k": "fallback", "seat": node{"slot"}.getInt(0),
        "cause": node{"cause"}.getStr()})
    else:
      discard
  if sim.phase == GameOver and sim.gameOverHold == 1:
    result.add(%*{
      "k": "end",
      "reason": sim.endRule,
      "winner": sim.winnerTeam(),
      "alive": [sim.aliveOnTeam(TeamRed), sim.aliveOnTeam(TeamBlue)]})

proc rosterJson*(sim: SimServer): JsonNode =
  ## One entry per seat, in the shape chrome_common's naming and momentum code
  ## already reads. `name` is the REAL policy name (spectator side only);
  ## `alias` is the in-game anonymous name.
  result = newJArray()
  for seat in 0 ..< SeatCount:
    result.add(%*{
      "s": seat,
      "name": sim.seatNames[seat],
      "alias": seatAliasOf(seat),
      "pol": sim.seatNames[seat],
      "team": teamName(teamOfSeat(seat)),
      "lives": (if sim.bombers[seat].alive: 1 else: 0),
      "alive": sim.bombers[seat].alive,
      "kind": sim.seatPolicyKind[seat]
    })

proc teamsJson(sim: SimServer): JsonNode =
  ## `teams[team].lives` is the team's LIVING BOMBER COUNT, which is what makes
  ## chrome_common's momentum graph the bombers-standing sparkline with no
  ## change to that byte-identical file.
  result = newJObject()
  for team in 0 ..< TeamCount:
    var names = newJArray()
    var aliases = newJArray()
    var fallback = false
    for seat in 0 ..< SeatCount:
      if teamOfSeat(seat) != team:
        continue
      names.add(%sim.seatNames[seat])
      aliases.add(%seatAliasOf(seat))
      if sim.fallbackTurns[seat] > 0:
        fallback = true
    let leader = (if team == TeamRed: 0 else: 1)
    result[teamName(team)] = %*{
      "lives": sim.aliveOnTeam(team),
      "policies": names,
      "aliases": aliases,
      "alive": sim.aliveOnTeam(team),
      "kills": sim.teamKills[team],
      "wood": sim.teamWood[team],
      "score": sim.scoreOf(leader),
      "radio": [sim.mailbox.lastSent(leader).a,
                sim.mailbox.lastSent(leader).b],
      "fallback": fallback
    }

proc seatsJson(sim: SimServer): JsonNode =
  result = newJArray()
  for seat in 0 ..< SeatCount:
    let pair = sim.mailbox.lastSent(seat)
    result.add(%*{
      "slot": seat,
      "alias": seatAliasOf(seat),
      "name": sim.seatNames[seat],
      "team": teamName(teamOfSeat(seat)),
      "alive": sim.bombers[seat].alive,
      "ammo": sim.bombers[seat].ammo,
      "range": sim.bombers[seat].blast,
      "kick": sim.bombers[seat].kick,
      "kills": sim.seatKills[seat],
      "bombs": sim.bombsPlaced[seat],
      "wood": sim.woodCleared[seat],
      "radio": [pair.a, pair.b],
      "fallbacks": sim.fallbackTurns[seat],
      "kind": sim.seatPolicyKind[seat]
    })

proc endcardJson(sim: SimServer): JsonNode =
  if sim.gameLog.len == 0:
    return newJNull()
  let record = sim.gameLog[^1]
  var seats = newJArray()
  for seat in 0 ..< SeatCount:
    let pair = sim.mailbox.lastSent(seat)
    seats.add(%*{
      "alias": seatAliasOf(seat),
      "name": sim.seatNames[seat],
      "team": teamName(teamOfSeat(seat)),
      "kills": sim.seatKills[seat],
      "bombs": sim.bombsPlaced[seat],
      "wood": sim.woodCleared[seat],
      "radio": [pair.a, pair.b],
      "alive": sim.bombers[seat].alive
    })
  %*{
    "seats": seats,
    "scores": [sim.scoreOf(0), sim.scoreOf(1)],
    "alive": [record.alive[TeamRed], record.alive[TeamBlue]],
    "kills": [record.kills[TeamRed], record.kills[TeamBlue]],
    "wood": [record.wood[TeamRed], record.wood[TeamBlue]],
    "endRule": record.endRule,
    "ticks": record.ticks,
    "winner": sim.winnerTeam(),
    "reason": sim.endReason,
    "complete": true
  }

proc buildStateJson*(
  sim: SimServer,
  player: ReplayPlayer,
  tracker: var BroadcastTracker,
  events: JsonNode,
  live: bool
): string =
  ## One frame. The chrome fields (`t`, `st`, `mx`, `mt`, `ph`, `pl`, `sp`,
  ## `teams`, `roster`, `lulls`, `beats`, `lead`) are the starter's, so
  ## `chrome_common.js` drives the clock, the transport, the scrubber, the
  ## beats and the momentum graph unchanged. Everything this game adds lives
  ## under `pm`.
  let
    startFrame =
      if player.gameStartFrames.len > 0: player.gameStartFrames[0] else: 0
    axisTick = if live: sim.tick else: max(0, player.frame - 1)
    axisStart = if live: 0 else: startFrame
    axisMax =
      if live: max(1, sim.config.maxTicks)
      else: max(startFrame + 1, player.maxFrame)
    upcoming = nextCollapse(sim.config, sim.tick)
  var node = %*{
    "t": axisTick,
    "st": axisStart,
    "mx": axisMax,
    "mt": sim.config.maxTicks,
    "ph": phaseText(sim.phase),
    "lob": max(0, sim.config.lobbyJoinTimeoutTicks - sim.lobbyTicks),
    "pl": player.playing,
    "lp": player.looping,
    "sk": player.skipLulls,
    "ff": player.fastForward,
    "sp": player.playbackSpeed(),
    "en": true,
    "pov": -1,
    "teams": teamsJson(sim),
    "roster": rosterJson(sim),
    "gv": GameVersion,
    "pm": {
      "board": boardJson(sim),
      "turn": sim.turnIndex,
      "turns": sim.turnsPerGame(),
      "tick": sim.tick,
      "maxTicks": sim.config.maxTicks,
      "bombs": bombsJson(sim),
      "danger": dangerJson(sim),
      "bombers": bombersJson(sim),
      "deaths": deathsJson(sim),
      "scorch": scorchJson(sim),
      "seats": seatsJson(sim),
      "alive": [sim.aliveOnTeam(TeamRed), sim.aliveOnTeam(TeamBlue)],
      "kills": [sim.teamKills[TeamRed], sim.teamKills[TeamBlue]],
      "wood": [sim.teamWood[TeamRed], sim.teamWood[TeamBlue]],
      "collapse": {"nextTick": upcoming.tick, "nextRing": upcoming.ring},
      "mismatchTick": player.hashMismatchTick,
      "endcard": endcardJson(sim),
      "events": events
    }
  }
  if not tracker.sentOnce and not live:
    tracker.sentOnce = true
    node["lulls"] = player.lullsJson()
    node["beats"] = player.beatsJson()
    node["lead"] = player.leadJson()
  if live:
    node["live"] = %true
  $node
