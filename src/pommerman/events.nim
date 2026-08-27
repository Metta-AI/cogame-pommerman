## The tier-2 analysis stream: one JSON line per event plus the mandatory
## trailing summary row, written to COGAME_EVENTS_URI. Off unless the platform
## configured a destination, so a server nobody is analysing pays nothing.

import std/[json, strutils]
import sim_types

type
  SimEventKind* = enum
    BombPlaced = "bomb_placed"
    BombKicked = "bomb_kicked"
    Explosion = "explosion"
    WoodCleared = "wood_cleared"
    Pickup = "pickup"
    Death = "death"
    Collapse = "collapse"
    TurnStart = "turn_start"
    Directive = "directive"
    Radio = "radio"
    Fallback = "fallback"
    PhaseChange = "phase_change"

  SimEvent* = object
    kind*: SimEventKind
    tick*: int
    source*: int
    target*: int
    amount*: int
    x*, y*: int
    detail*: string

proc eventJson*(event: SimEvent): JsonNode =
  %*{
    "type": $event.kind,
    "tick": event.tick,
    "source": event.source,
    "target": event.target,
    "amount": event.amount,
    "x": event.x,
    "y": event.y,
    "detail": event.detail
  }

proc eventsJsonl*(events: seq[SimEvent], ticks: int): string =
  ## JSON lines, then the summary row. The summary is how a reader tells "this
  ## match had no events" from "the upload never happened".
  var lines: seq[string]
  for event in events:
    lines.add($event.eventJson())
  lines.add($(%*{
    "type": "summary",
    "ticks": ticks,
    "events": events.len,
    "gameVersion": GameVersion
  }))
  lines.join("\n") & "\n"
