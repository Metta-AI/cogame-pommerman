## Pommerman player: scripted, prompt, or Jev over one private seat view.
## The game receives only metadata and ordinary actions; prompts and model
## credentials remain in this container.

import std/[json, monotimes, options, os, strutils, times]
import bitworld/spriteprotocol
import whisky
import pommerman/[sim_types, llm, model_pacing,
  player_policy, prompt_policy, jev_policy]

const
  ConnectAttempts = 240      ## 240 x 500 ms = 2 minutes of dialling.
  ConnectRetryMs = 500
  RegistrationResends = 10   ## re-sends after the first, ~1 s apart.
  ResendEveryFrames = 6
  ReconnectAttempts = 6

## The two caps below come from `pommerman/sim_types` -- the SAME constants and
## the SAME rune-boundary `truncateRunes` the server enforces them with, so
## 4000/48 exists once and cannot drift.

proc registrationBlob(kind, scripted, policy: string): string =
  let node = %*{
    "protocol": PlayerProtocolId,
    "policy": policy.truncateRunes(MaxPolicyLabelRunes),
    "kind": kind,
    "scripted": scripted
  }
  blobFromSpriteChat($node)

proc readyBlob(): string =
  ## The Sprite v1 player-ready packet (0x85). Legitimate here in a way it is
  ## separate from turn actions, which are sent in Sprite chat messages.
  ## The game waits for each command turn before advancing its next frame.
  result = newString(1)
  result[0] = char(0x85)

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL", getEnv("COGAMES_ENGINE_WS_URL"))
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  let
    prompt = getEnv("PLAYER_PROMPT").strip().truncateRunes(MaxPromptRunes)
    scripted = getEnv("PLAYER_SCRIPTED", "sapper").strip()
    jev = getEnv("PLAYER_JEV") == "1"
    kind = if jev: "jev" elif prompt.len > 0: "prompt" else: "scripted"
    label = block:
      let explicit = getEnv("PLAYER_POLICY_LABEL").strip()
      if explicit.len > 0: explicit
      elif jev: "jev"
      elif prompt.len > 0: "prompt"
      else: scripted
  var pacer = newModelPacer()
  let promptClient = if kind == "prompt":
    newLlmClient() else: nil
  echo "pommerman player: kind=", kind,
    " baseline=", scripted, " label=", label

  proc dial(attempts: int): WebSocket =
    ## Bounded dialling. The episode runner starts the players at the same
    ## instant as the game, so the first dial always lands on a closed port.
    for attempt in 0 ..< attempts:
      try:
        return newWebSocket(url)
      except CatchableError as error:
        if attempt == 0:
          echo "pommerman player: game not listening yet (", error.msg,
            "); retrying"
        sleep(ConnectRetryMs)
    nil

  var socket = dial(ConnectAttempts)
  if socket == nil:
    quit("pommerman player: game never accepted a connection", 1)
  echo "pommerman player: connected"

  # Each session is wrapped: whisky's receiveMessage RAISES on a close frame or
  # a truncated read (only a timeout returns none), and mummy's send only
  # QUEUES -- so the game's own quit(0) can outrun the flushed frame. A naive
  # player exits 1 on that race and fails certification intermittently
  # (cogame-raid 0.1.3). Exiting 0 on a dead socket is the fix.
  #
  # REGISTRATION IS RE-SENT, NOT SENT ONCE. Joins are slot-sequential, so a
  # seat whose slot is not the next open one is not admitted until the lower
  # slots have joined -- and the lobby sends frames to a socket before it is
  # admitted, so both the first registration and a single re-send keyed on the
  # first received frame can land while the seat has no index yet (paintball
  # round 3, 2026-08-25). This end keeps re-sending for the first ~10 s of
  # frames; registering twice is harmless, the server just re-reads the same
  # fields.
  var reconnects = 0
  while true:
    var sessionFrames = 0
    try:
      socket.send(registrationBlob(kind, scripted, label), BinaryMessage)
      var resends = 0
      while true:
        let received = socket.receiveMessage()
        if received.isNone:
          continue
        let packet = received.get()
        if packet.kind == TextMessage:
          let request = parseJson(packet.data)
          if request{"kind"}.getStr() == "decision":
            doAssert request["protocol"].getStr() == PlayerProtocolId
            let
              started = getMonoTime()
              view = request["observation"]
              budgetMs = request["deadline_ms"].getInt()
            var
              source = "scripted"
              cause = ""
              action: JsonNode
            case kind
            of "jev":
              if jevConfigured():
                action = chooseJevAction(view, pacer, budgetMs)
                source = "llm"
              else:
                action = scriptedAction(view, scripted)
                source = "fallback"
                cause = "no_credentials"
            of "prompt":
              if promptClient.disabled:
                action = scriptedAction(view, scripted)
                source = "fallback"
                cause = "no_credentials"
              else:
                action = choosePromptAction(promptClient, pacer, view,
                  prompt, budgetMs)
                source = "llm"
            else:
              action = scriptedAction(view, scripted)
            let reply = %*{
              "protocol": PlayerProtocolId,
              "kind": "action", "turn": request["turn"],
              "action": action, "source": source, "cause": cause,
              "latency_ms": (getMonoTime() - started).inMilliseconds.int
            }
            socket.send(blobFromSpriteChat($reply), BinaryMessage)
          continue
        inc sessionFrames
        if resends < RegistrationResends and
            sessionFrames mod ResendEveryFrames == 1:
          inc resends
          socket.send(registrationBlob(kind, scripted, label), BinaryMessage)
        socket.send(readyBlob(), BinaryMessage)
    except CatchableError as error:
      echo "pommerman player: socket closed (", error.msg, ")"
    # NEVER exit while the game is still serving: a seat that drops keeps its
    # bomber for the whole episode and revives on reconnect. Bounded on both
    # counts, so this can never outlive the game or spin.
    if sessionFrames == 0 or reconnects >= ReconnectAttempts:
      break
    inc reconnects
    echo "pommerman player: re-dialling the seat (attempt ", reconnects, ")"
    socket = dial(ReconnectAttempts)
    if socket == nil:
      echo "pommerman player: game is no longer listening, exiting cleanly"
      break
    echo "pommerman player: reconnected, re-registering"
  quit(0)
