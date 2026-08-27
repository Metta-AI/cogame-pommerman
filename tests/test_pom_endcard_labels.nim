## The endcard and chrome VOCABULARY gate.
##
## A forked ctf endcard silently ships paintbot's words: nothing in the
## starter's tests, in `viewer_smoke.mjs` or in the label manifest covers
## spectator chrome STRINGS, because `labels.nim` deliberately scopes itself to
## the policy contract. So the re-labelings are enumerated in the design note
## and enforced here -- zero forbidden words, and every replacement present.

import std/[strutils, unittest]
import helpers

const
  Forbidden = ["Lives", "LIVES", "Clstr", "Cap<", "flag", "heart", "paint",
               "hopper", "hill", "POV", "spray", "grenade", "med kit",
               "trench"]
  # The design note's re-mapping table, left column -> right column:
  #   ec-thead Player/K/D/Clstr/Cap  ->  Bomber/Kills/Bombs/Wood/Radio
  #   fl-cap "Lives left"            ->  "Bombers left"
  #   momentum-label "LIVES LEAD"    ->  "BOMBERS STANDING"
  #   plate "lives-label Lives"      ->  "alive-label Alive"
  #   lk-cap hoppers/paint line      ->  "Lighting the fuses..."
  #   clock-caption locker room      ->  "Taking corners"
  #   mmwarn "recorded inputs"       ->  "recorded orders" (with the tick)
  #   btn-spoilers "flag story"      ->  "collapses"
  #   team words RED/BLUE            ->  kept: they are this game's real team
  #                                      names
  RequiredOnce = [
    "<span>Bomber</span>",
    "<span>Kills</span>",
    "<span>Bombs</span>",
    "<span>Wood</span>",
    "<span>Radio</span>",
    "Bombers left",
    "BOMBERS STANDING",
    "Taking corners",
    "kills / collapses / winner"
  ]
  # Present, but legitimately more than once, with the reason:
  #   alive-label              a CLASS: the markup that emits it plus its own
  #                            CSS rule and the .tiny rule that hides it
  #   Lighting the fuses       the curtain's static caption in markup, and the
  #                            first entry of the rotating prep-talk list
  #   showing recorded orders  the inherited static #mmwarn text, and the JS
  #                            that rewrites it with the mismatch tick
  RequiredPresent = [
    "alive-label",
    "Lighting the fuses",
    "showing recorded orders"
  ]

proc withoutComments(text: string): string =
  ## HTML comments, CSS comments and `//` line comments removed. A comment
  ## explaining what was deleted is documentation; a STRING the spectator reads
  ## is vocabulary, and only the latter is under test.
  var body = text
  for pair in [("<!--", "-->"), ("/*", "*/")]:
    let opener = pair[0]
    let closer = pair[1]
    var scan = 0
    while true:
      let start = body.find(opener, scan)
      if start < 0:
        break
      let stop = body.find(closer, start)
      if stop < 0:
        body = body[0 ..< start]
        break
      body = body[0 ..< start] & body[stop + closer.len .. ^1]
      scan = start
  var lines: seq[string]
  for line in body.splitLines():
    let at = line.find("//")
    if at >= 0 and line[0 ..< at].count('"') mod 2 == 0 and
        line[0 ..< at].count('\'') mod 2 == 0:
      lines.add(line[0 ..< at])
    else:
      lines.add(line)
  lines.join("\n")

suite "pommerman endcard labels":

  test "zero paintbot vocabulary outside comments":
    for path in ["client/replay_broadcast.html", "client/broadcast_core.js",
                 "client/page_script.js", "client/game_block.html"]:
      let text = withoutComments(readRepoFile(path))
      for word in Forbidden:
        if word in text:
          let at = text.find(word)
          checkpoint(path & " still says \"" & word & "\": ..." &
            text[max(0, at - 70) ..< min(text.len, at + 40)].replace("\n", " ") &
            "...")
          fail()

  test "every re-mapped string is present exactly once":
    ## Present is not enough: a re-mapping that ships BOTH words (the new
    ## caption added and the old one left behind in a second rule) reads as a
    ## pass to a presence check. So the count is asserted, over the page with
    ## comments stripped.
    let page = withoutComments(readRepoFile("client/replay_broadcast.html"))
    for wanted in RequiredOnce:
      let seen = page.count(wanted)
      if seen != 1:
        checkpoint("the re-mapped string appears " & $seen & " times, not 1: " &
          wanted)
        fail()
    for wanted in RequiredPresent:
      if wanted notin page:
        checkpoint("the re-mapped string is missing: " & wanted)
        fail()

  test "the team words RED and BLUE are kept":
    ## They are this game's REAL team names, so the re-mapping table keeps
    ## them where paintbot's vocabulary is replaced.
    let page = readRepoFile("client/replay_broadcast.html")
    check "TEAMS[lead].toUpperCase()" in page
    check "'red'" in page and "'blue'" in page

  test "the feed speaks plain language, not internal notation":
    let gameBlock = readRepoFile("client/game_block.html")
    for phrase in ["FIRST BLOOD", "KICKS A BOMB", "THE WALLS CLOSE IN",
                   "MISSED THE CALL", "BLOWS ITSELF UP",
                   "drops a bomb", "breaks a wall", "picks up",
                   "radios"]:
      checkpoint(phrase)
      check phrase in gameBlock
    ## the clock reads the command turn and the countdown to the next ring
    let script = readRepoFile("client/page_script.js")
    check "'turn ' + Math.max(1, pm.turn) + '/' + pm.turns" in script
    check "'tick ' + pm.tick + '/' + pm.maxTicks" in script
    check "walls close in" in script

  test "the two name spaces are respected in the chrome":
    ## The seat's REAL policy name is spectator side only; the in-game alias is
    ## what a seat ever sees. Both appear on the plate, and nothing in the
    ## board layer draws a real name.
    let script = readRepoFile("client/page_script.js")
    check "plate-name" in script
    check "teamHeadline" in script
    let core = readRepoFile("client/broadcast_core.js")
    ## the board renderer only ever reads cell/team/alias-free fields
    check "seat.name" notin core
    check "roster" notin core
    check "policies" notin core
