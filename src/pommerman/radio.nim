## The private team radio: two integers in 1..8, stored on turn T and delivered
## to the sender's PARTNER -- and to nobody else -- on turn T+1.
##
## This module is the whole point of the coworld, so it is deliberately
## paranoid. Every write and every read goes through a proc that takes BOTH a
## team and a seat and checks `teamOfSeat(seat) == team`; a mismatch raises
## rather than silently reading the wrong index (the fog-of-war-boards
## 2026-08-27 scar: a per-seat structure written under the wrong index leaks
## and nothing notices).

import sim_types

type
  RadioPair* = object
    a*, b*: int

  RadioMailbox* = object
    pending*: array[SeatCount, RadioPair]    ## sent with this turn's order
    delivered*: array[SeatCount, RadioPair]  ## what the partner sent last turn
    hasDelivery*: array[SeatCount, bool]
    sentCount*: array[SeatCount, int]

func clampPair*(a, b: int): RadioPair {.inline.} =
  RadioPair(a: clamp(a, RadioLow, RadioHigh), b: clamp(b, RadioLow, RadioHigh))

func defaultPair*(): RadioPair {.inline.} =
  ## Turn 1's default for every seat.
  RadioPair(a: RadioLow, b: RadioLow)

proc initRadioMailbox*(): RadioMailbox =
  for seat in 0 ..< SeatCount:
    result.pending[seat] = defaultPair()
    result.delivered[seat] = defaultPair()
    result.hasDelivery[seat] = false
    result.sentCount[seat] = 0

proc assertSeatOnTeam(seat, team: int) =
  if seat < 0 or seat >= SeatCount:
    raise newException(SimGuardError, "radio: seat " & $seat & " is not a seat")
  if teamOfSeat(seat) != team:
    raise newException(SimGuardError,
      "radio: seat " & $seat & " is on team " & $teamOfSeat(seat) &
      ", not " & $team)

proc send*(mailbox: var RadioMailbox, team, seat: int, pair: RadioPair) =
  ## Stores the pair `seat` is sending this turn. Checked against the team the
  ## caller believes the seat is on.
  assertSeatOnTeam(seat, team)
  mailbox.pending[seat] = clampPair(pair.a, pair.b)
  inc mailbox.sentCount[seat]

proc deliver*(mailbox: var RadioMailbox) =
  ## Exactly one turn late, always: every seat's pending pair becomes its
  ## PARTNER's delivered pair, and nobody else's. Called once at the top of a
  ## command turn, before any observation is built.
  var next: array[SeatCount, RadioPair]
  var got: array[SeatCount, bool]
  for seat in 0 ..< SeatCount:
    let partner = partnerOfSeat(seat)
    assertSeatOnTeam(partner, teamOfSeat(seat))
    next[partner] = mailbox.pending[seat]
    got[partner] = mailbox.sentCount[seat] > 0
  for seat in 0 ..< SeatCount:
    mailbox.delivered[seat] = next[seat]
    mailbox.hasDelivery[seat] = got[seat]

proc receive*(
  mailbox: RadioMailbox, team, seat: int
): tuple[has: bool, pair: RadioPair] =
  ## What `seat` may read: its OWN partner's pair, one turn late. The opposing
  ## team's pairs are never reachable through this proc at all -- there is no
  ## code path from a seat index to a cross-team pending pair.
  assertSeatOnTeam(seat, team)
  (mailbox.hasDelivery[seat], mailbox.delivered[seat])

func lastSent*(mailbox: RadioMailbox, seat: int): RadioPair {.inline.} =
  ## Spectator side only (the scorebug plate and the board glyphs draw both
  ## teams' pairs -- the hiding is enforced in the observation builder, never
  ## in the renderer).
  mailbox.pending[seat]
