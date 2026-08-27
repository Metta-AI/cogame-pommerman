## The label vocabulary contract: every string this game can put on a sprite, a
## plate, a beat button or a feed row, enumerated in one place.
##
## `tests/label_manifest.txt` is the pinned copy and `test_pom_labels.nim`
## asserts the two agree, so a label change has to be regenerated in the same
## commit. The vocabulary is deliberately scoped to the ANONYMOUS name space:
## no real policy name is ever a label (showPlayerLabels is false), which is
## the anti-collusion half of the two-name-space rule.

import std/[algorithm, sequtils, strutils]
import sim_types, bombs, directives

proc emittedLabels*(): seq[string] =
  for seat in 0 ..< SeatCount:
    result.add(seatAliasName(seat))
  for team in 0 ..< TeamCount:
    result.add(TeamNames[team])
    result.add(TeamNamesUpper[team])
  for kind in OrderKind:
    result.add($kind)
  for name in DirNames:
    result.add(name)
  for kind in ["firstblood", "kick", "death", "collapse", "fallback", "end"]:
    result.add(kind)
  for kind in ["plain", "crown"]:
    result.add(kind)
  result.sort()
  result = result.deduplicate(isSorted = true)

proc labelManifest*(): string =
  emittedLabels().join("\n") & "\n"
