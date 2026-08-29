## The JS wire-constants block: the handful of engine constants the browser
## chrome must agree with (playback speeds, the playback tick rate, the rune
## caps the text layout reserves room for). Rendered ONCE, from the same Nim
## consts the engine runs on; server.nim splices the block into every served
## client page and tools/gen_wire_constants.nim emits it for the static wasm
## bundle. Clients read `window.POM_WIRE`.

import std/strutils
import sim_types, replay_runtime

proc jsSpeedArray(values: openArray[int]): string =
  ## The chip row the page renders: the half-speed step (`speedIndex ==
  ## replay_runtime.HalfSpeedIndex`) first, then the whole-number speeds the
  ## array indexes.
  result = "[0.5"
  for v in values:
    result.add ","
    result.add $v
  result.add "]"

const WireConstantsJs* =
  "window.POM_WIRE={speeds:" & jsSpeedArray(PlaybackSpeeds) &
  ",fps:" & $TargetFps &
  ",tickRate:" & $TicksPerSecondBase &
  ",maxSayRunes:" & $MaxSayRunes &
  ",seats:" & $SeatCount &
  ",boardSize:" & $BoardSize &
  ",radioLow:" & $RadioLow &
  ",radioHigh:" & $RadioHigh &
  ",gameVersion:\"" & GameVersion & "\"" &
  "};"

const WireConstantsMarker* = "<!-- WIRE_CONSTANTS -->"
  ## The placeholder the client HTML carries where the block belongs (before
  ## any script that reads window.POM_WIRE).

proc spliceWireConstants*(page: string): string =
  ## Replaces the marker with the inline constants script. A page without the
  ## marker passes through unchanged.
  page.replace(WireConstantsMarker,
    "<script>" & WireConstantsJs & "</script>")
