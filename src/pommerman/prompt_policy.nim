## Claude prompt policy in the player container, over the seat observation.

import std/[json, monotimes, times]
import curly
import llm, directives, model_pacing

proc choosePromptAction*(
  client: LlmClient, pacer: var ModelPacer, view: JsonNode,
  prompt: string, budgetMs: int
): JsonNode =
  let started = getMonoTime()
  pacer.acquire(budgetMs)
  let remaining = budgetMs - (getMonoTime() - started).inMilliseconds.int
  let request = client.requestFor(SystemPrompt, userMessage(prompt, $view))
  let response = client.curl.post(request.url, request.headers, request.body,
    max(1, (remaining - 500) div 1000))
  extractJsonObject(client.textOf(response, "", request.url))
