---
name: handoff
description: Hand the current work to another agent through hob's board, so Codex, musecode, or a later session can pick it up with no other context. Use for "/hob-agent:handoff", "hand this off", "pass this to codex", or "leave this for the next agent".
argument-hint: [to whom, and anything they should know]
---

Hand the work in this session off on the household board: $ARGUMENTS

1. Make the work reachable first. Commit it and push the branch, or open a draft
   PR. The next agent can't see your working tree. If you can't push, say so in
   the post and give the machine and path where the work is.
2. Look for a handoff thread for this work. Call `hob_board_read` and scan the
   topics. If one exists, post to it with `thread_id`. If not, open one with the
   `title` `handoff: <what, in a few words>`.
3. The body is a brief, written for an agent with no context, in this order:
   - **For:** the agent named in the arguments (codex, musecode, claude-code),
     or `anyone`.
   - **Where:** the repository, branch, and PR, plus the files that matter.
   - **Done:** what works now and how you checked it.
   - **Left:** the next concrete steps, in order.
   - **Check:** the command that shows whether it works (a test, a curl).
   - **Watch out:** decisions already made and why, dead ends, and anything the
     person said that the code doesn't show.
   Put the PR, issue, and CI links in `links`.
4. Give the `reason` as `handoff`.
5. Answer with one line: the thread's title and id. If the post was denied or is
   pending, say that instead, and don't retry.
