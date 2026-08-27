## Claude-backed bomber command. A policy is just a prompt: the game server
## composes the seat's decoded board plus that seat's PLAYER_PROMPT and asks
## Claude what its bomber does for the next four ticks and what two integers it
## sends its partner.
##
## Forked from `coworld-ctf/src/ctf/llm.nim` behaviour for behaviour -- the
## credential ladder, the Bedrock model choice, the fence-tolerant JSON
## extraction and the rune-boundary truncation are all that file's, because
## they are all scar tissue from real hosted failures.
##
## pommerman is a SIMULTANEOUS-decision game, so ALL FOUR seats' calls go out as
## ONE parallel batch per turn (`curly.makeRequests`). Seats are never queried
## sequentially: that is what keeps 36 turns inside the wall clock.
##
## Credentials, in order of preference:
##   Bedrock sidecar (AWS_ENDPOINT_URL_BEDROCK_RUNTIME + AWS_BEARER_TOKEN_BEDROCK)
##   ANTHROPIC_API_KEY
##   ANTHROPIC_API_KEY_URI
## With none of them the client disables itself and every turn falls back to
## the scripted layer INSTANTLY, with no network wait -- which is what lets
## offline certification finish in seconds.

import std/[json, os, strutils]
import bitworld/runtime
import curly
import sim_types

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"

type
  LlmTransport* = enum
    ltNone, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl*: Curly
    transport*: LlmTransport
    apiKey: string
    bedrockEndpoint: string
    bedrockModels: seq[string]
    bedrockModel: int
    bedrockToken: string
    model*: string
    maxOutputTokens*: int
    disabled*: bool
    throttled*: bool
      ## The provider answered 429 and there is no other candidate model to
      ## rotate to. The seat FAILS FAST to the scripted layer for that turn
      ## instead of burning the turn budget on a retry that cannot land.

  LlmError* = object of ValueError

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "pommerman llm: failed to fetch ANTHROPIC_API_KEY_URI: ", error.msg
    result = ""

proc bedrockModelIds(): seq[string] =
  ## ONE candidate. `us.anthropic.claude-sonnet-4-5` and `-4-6` are
  ## deliberately NOT candidates: both time out on every sidecar call (raid
  ## round 2, 2026-08-23; paintball 0.1.2), and with no second candidate a 429
  ## sets `throttled` and the seat fails fast for that turn rather than burning
  ## the turn budget on a retry that cannot land. BEDROCK_MODEL pins one.
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  @["us.anthropic.claude-haiku-4-5-20251001-v1:0"]

proc tryNextBedrockModel(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "pommerman llm: ", client.bedrockModels[client.bedrockModel - 1],
    " unusable (", why, "); falling back to ",
    client.bedrockModels[client.bedrockModel]
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: (if config.model.len > 0: config.model
            else: "claude-haiku-4-5-20251001"),
    maxOutputTokens: max(1, config.maxOutputTokens)
  )
  let
    bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
    bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION", getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "pommerman llm: bedrock transport, model ",
      result.bedrockModels[result.bedrockModel]
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "pommerman llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    ## The exact phrase phase 60 greps the GAME log for, alongside
    ## "falling back": "LLM provider is unavailable".
    echo "pommerman llm: no credentials - the LLM provider is unavailable; ",
      "every turn is falling back to the scripted layer"

proc requestFor*(
  client: LlmClient, system, user: string
): tuple[url: string, headers: HttpHeaders, body: string] =
  ## One Messages-API request, shaped for whichever transport is live.
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  else:
    body["model"] = %client.model
    ## Only the Claude 5 / Opus tiers accept an effort setting; Haiku 4.5
    ## rejects the whole request with a 400 if it is present.
    if "haiku" notin client.model and "4-5" notin client.model:
      body["output_config"] = %*{"effort": "low"}
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc textOf*(
  client: LlmClient, response: Response, error, url: string
): string =
  ## The text of one batched reply, or an LlmError describing why there is
  ## none. At most MaxReplyBytes are read before parsing.
  if error.len > 0:
    raise newException(LlmError, "llm transport: " & error)
  if response.code == 401 or response.code == 403:
    ## RUNE-safe: this text becomes `fallback.detail` in the replay, and a
    ## provider body is arbitrary bytes.
    let detail = response.body.truncateRunes(MaxFallbackDetailRunes)
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(LlmError, "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(
      LlmError,
      "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = response.body.truncateRunes(MaxFallbackDetailRunes)
    if not client.tryNextBedrockModel("throttled"):
      client.throttled = true
    raise newException(LlmError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(LlmError, "anthropic error " & $response.code & ": " &
      response.body.truncateRunes(MaxFallbackDetailRunes))
  var body = response.body
  if body.len > MaxReplyBytes:
    ## MaxReplyBytes is a BYTE budget, so the cut is a byte cut -- landed on a
    ## codepoint boundary, never mid-rune.
    body = body.truncateBytes(MaxReplyBytes)
  let payload = parseJson(body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(LlmError, "anthropic refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(LlmError, "reply cut off at max_tokens before any " &
      "JSON: " & result.truncateRunes(160).replace("\n", " "))

const SystemPrompt* = """
You command ONE bomber in a 2v2 bomb-and-dodge match on an 11x11 walled grid. You and
one PARTNER are a team; two opponents are the other team. You did not choose your
partner and you will never learn which policy it is.

THE BOARD, EVERY TURN
- "board" is 11 rows of 11 characters: # rigid wall, W wooden wall, . floor,
  * fire, and e/r/k for the three power-ups (extra bomb, +1 blast range, kick).
- "danger" is the same grid decoded for you: a digit is how many ticks until that
  cell catches fire, counting chain reactions and the closing walls. A '.' is safe
  for at least 10 ticks. Standing on a digit 0 or 1 kills you.
- "bombs" lists every live bomb with its fuse and blast range. "bombers" lists all
  four of us with ammo, blast range and whether we have kick.

THE RULES
- A bomb has an 8-tick fuse and clears its own cell plus (range - 1) cells in each of
  the four directions, stopping at the first wall. Wood is destroyed; rigid stops it.
  Fire lasts 2 ticks and kills instantly - you, your partner, anyone.
- You start with 1 bomb and range 2. Breaking wood reveals power-ups; walk onto one
  to take it. Extra bomb, +1 range, and kick (kick lets you shove a bomb you walk
  into down a clear lane).
- One command turn is 4 ticks. You give ONE order; a controller executes it tick by
  tick and will ALWAYS pull you out of fire first if it can. It will refuse to lay a
  bomb it cannot see an escape from. It cannot save you from a trap with no exit.
- At tick 96 the outer ring of floor turns to wall and crushes anyone on it. At tick
  120 the next ring goes. From then on the arena is the middle 5x5.
- Your team wins by killing BOTH opponents. Blowing yourself or your partner up costs
  your team the same as being killed. The game ends at tick 144.

THE RADIO
- Every turn you send your PARTNER two integers, each 1 to 8. Your partner receives
  them on the FOLLOWING turn. The opponents NEVER see them.
- The game assigns these numbers NO meaning. Any meaning is whatever you and your
  partner manage to establish while under fire. Your partner may be running a
  completely different policy from yours, so: send something SIMPLE, send it
  CONSISTENTLY, and read your partner's pair against what you can see it actually
  doing on the board. A code nobody can decode is worth nothing.

YOUR ORDERS - exactly one per turn, executed until you change it:
- {"verb":"break"}                    walk to the nearest wood and bomb it
- {"verb":"bomb"}                     bomb where you stand right now, then retreat
- {"verb":"go","x":5,"y":5}           walk to that cell (it also picks up anything on the way)
- {"verb":"hunt","target":"BLUE-1"}   close on that enemy and bomb when it is in your blast lane
- {"verb":"hide"}                     move to the safest reachable cell and sit
- {"verb":"kick","dir":"left"}        shove the bomb on your left down the lane
- {"verb":"follow"}                   move to your partner and break wood beside it

REPLY FORMAT
Reply with ONE JSON object and NOTHING else. Your reply MUST begin with { and end
with }. No prose, no markdown, no code fences.
{"order":{"verb":"break"},"radio":[3,7],"say":"<=100 chars","notes":"<=200 chars"}
"say" is shown to spectators. "notes" comes back to you next turn and to nobody else.
An order you omit repeats; a radio pair you omit repeats.
"""

proc operatorBlock*(prompt: string): string =
  ## The seat's own PLAYER_PROMPT, under a heading that tells the model how
  ## much weight it carries. Never echoed into the replay or the results.
  if prompt.len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules; always reply in the requested format):\n" &
    prompt.truncateRunes(MaxPromptRunes) & "\n\n"

proc userMessage*(operatorPrompt: string, viewJson: string): string =
  ## The user message: the operator's guidance, a blank line, then the seat's
  ## own observation. Built server-side (see decide.nim).
  operatorBlock(operatorPrompt) & viewJson
