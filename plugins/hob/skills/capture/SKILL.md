---
name: capture
description: Capture a todo into the household's inbox through hob, right now, without a conversation about it. Use for "/hob:capture <what>", "remind me to", "add a todo", or "put that on my list".
argument-hint: <what needs doing>
---

Capture this as a todo with the hob server's `todo_create` tool: $ARGUMENTS

- One call, no questions. If what to capture is empty or unclear, take it from
  the conversation: the thing the person just said they would do later.
- Title: a verb first, and enough to make sense weeks from now.
- No `list` and no `backend`: it belongs in the inbox, and the person files it.
- Set `due_at`, `start_at`, `flagged`, or `tags` only if the person said so.
  "Tomorrow" or "next week" with no deadline is `start_at`, not `due_at`.
- If this came out of the work in this session, put what is needed to pick it
  up cold in `notes`: repository and branch, file and line, the failing
  command, a PR or issue link.
- Answer with one line: the title as filed and its id. If the tool fails, say
  what it said; do not retry.
