## Shared types, wire constants and the rune caps.
##
## GameVersion gates replay compatibility. The changelog comment below is
## PREPEND-ONLY (the starter's discipline, kept, with
## `tools/ci/check_gameversion.sh`): say what the number means and what it
## obsoletes, so two branches claiming one number are distinguishable.

import std/[strutils, unicode]

const
  GameVersion* = "1"
    ## GV1 (pommerman v1): Pommerman as a Coworld -- an 11x11 integer grid,
    ## four bombers seated 2v2 on the diagonals, one order per seat every four
    ## ticks, a two-integer private team radio and two collapsing rings.
    ## Obsoletes nothing.

  GameName* = "pommerman"
  ReplayMagic* = "COWLDPOM"
  ReplayFormatVersion* = 1'u16
  ProtocolId* = "pommerman/v1"

  MaxSayRunes* = 100
  MaxNoteRunes* = 200
  MaxPromptRunes* = 4000
  MaxPolicyLabelRunes* = 48
  MaxFallbackDetailRunes* = 200
  MaxStopDetailRunes* = 200
  MaxReplyBytes* = 8192
  MaxVerbRunes* = 8
  MaxTargetRunes* = 6
  MaxDirRunes* = 5
  MaxDirectiveRunes* = 900

  SeatCount* = 4
    ## Four bombers, always, in every variant and in the certification
    ## fixture. There is no other seating.
  TeamCount* = 2
  BoardSize* = 11
  BoardCells* = BoardSize * BoardSize

  RadioLow* = 1
  RadioHigh* = 8
    ## The radio alphabet: two integers, each in 1..8, exactly as upstream.

  MaxBombs* = 32
    ## Bomb object-pool ceiling: four bombers capped at five bombs each is 20,
    ## so the pool is sized above anything the rules can produce.
  MaxItems* = 24
  MaxFlames* = 128

  TargetFps* = 6
    ## Presentation frame rate AND the playback denominator: one tick per
    ## 167 ms at speed 1, so a 144-tick episode plays for 24 s -- long enough
    ## for `viewer_smoke.mjs --soak 10` to observe real advancement (the ecos
    ## 2026-08-23 scar) and slow enough to read an 8-tick fuse counting down.
  PlaybackSpeeds* = [1, 2, 4, 8]
    ## The speeds `chrome_common.js` has a chip command for. That file is
    ## copied BYTE FOR BYTE from the starter and its speed->command map has no
    ## 0.5 entry, so a half-speed chip would render inert; the design note's
    ## `[0.5, 1, 2, 4, 8]` is recorded as an errata in
    ## docs/plans/2026-08-27-pommerman-design.md.

  ReasonComplete* = "complete"
  ReasonDeadline* = "deadline"
  ReasonFault* = "fault"

  EndRuleWipe* = "wipe"
  EndRuleTickCap* = "tickCap"
  EndRuleWallClock* = "wallClock"
  EndRuleFault* = "fault"

  TeamRed* = 0
  TeamBlue* = 1
  TeamNames* = ["red", "blue"]
  TeamNamesUpper* = ["RED", "BLUE"]

  IdentityNames* = ["RED-1", "BLUE-1", "RED-2", "BLUE-2"]
    ## The ONLY names that appear in an observation, a prompt, an order, a
    ## `say` or a sprite label. Real policy names live spectator-side only.

type
  PommermanError* = object of CatchableError
  SimGuardError* = object of PommermanError
  ReplayError* = object of PommermanError

  Phase* = enum
    Lobby, Playing, GameOver

  SlotConfig* = object
    team*: string
    token*: string

  PlayerConfig* = object
    name*: string

  GameConfig* = object
    seed*: int
    numAgents*: int
    minPlayers*: int
    maxTicks*: int
    maxGames*: int
    turnTicks*: int
    bombFuse*: int
    flameLife*: int
    startAmmo*: int
    maxAmmo*: int
    startBlast*: int
    maxBlast*: int
    collapseTicks*: seq[int]
    dodgeHorizon*: int
    turnBudgetMs*: int
    turnSpacingMs*: int
    attempt1Ms*: int
    retryMs*: int
    wallClockBudgetSeconds*: int
    lobbyJoinTimeoutTicks*: int
    startWaitTicks*: int
    gameOverTicks*: int
    fastMode*: bool
    showPlayerLabels*: bool
    model*: string
    maxOutputTokens*: int
    players*: seq[PlayerConfig]
    slots*: seq[SlotConfig]
    tokens*: seq[string]

func teamOfSeat*(seat: int): int {.inline.} =
  ## Teams are fixed by SLOT PARITY and assigned by the server, never chosen
  ## by a policy: seats 0 and 2 are RED, seats 1 and 3 are BLUE. That, plus an
  ## exactly zero-sum team score, is this game's anti-collusion rule.
  seat mod 2

func partnerOfSeat*(seat: int): int {.inline.} =
  ## Partners sit on a diagonal, as upstream: 0<->2 and 1<->3.
  (seat + 2) mod SeatCount

func seatAliasName*(seat: int): string {.inline.} =
  IdentityNames[seat mod SeatCount]

func teamName*(team: int): string {.inline.} =
  TeamNames[team mod TeamCount]

proc truncateRunes*(text: string, limit: int): string =
  ## Cuts `text` to at most `limit` RUNES, on a rune boundary. The single
  ## place any recorded string is shortened. Byte truncation is forbidden
  ## anywhere on the path to the replay: a half-codepoint renders in a browser
  ## and then fails a strict UTF-8 parser.
  if limit <= 0:
    return ""
  if text.runeLen <= limit:
    return text
  text.runeSubStr(0, limit)

proc truncateBytes*(text: string, limit: int): string =
  ## Cuts `text` to at most `limit` BYTES, never mid-codepoint. For the one cap
  ## that is genuinely a byte budget -- how much of a provider reply is read
  ## before parsing -- where a rune cap would admit up to four times the bytes.
  if limit <= 0:
    return ""
  if text.len <= limit:
    return text
  var cut = limit
  while cut > 0 and (ord(text[cut]) and 0xC0) == 0x80:
    dec cut
  text[0 ..< cut]

proc sanitizeLine*(text: string, limit: int): string =
  ## A recorded free-text field: newlines collapse to spaces so one record
  ## stays one line, then the rune cap applies on a rune boundary.
  text.replace("\n", " ").replace("\r", " ").strip().truncateRunes(limit)

proc sanitizeSay*(text: string): string =
  ## The commander's spectator line. Rune-capped FIRST, then filtered to
  ## printable characters with braces excluded: the replay chat stream tells a
  ## control record from a plain line by a leading '{'.
  result = ""
  for rune in text.sanitizeLine(MaxSayRunes).runes:
    let value = int(rune)
    if value >= 32 and value != ord('{') and value != ord('}') and
        value != 127:
      result.add($rune)
  result = result.strip()
