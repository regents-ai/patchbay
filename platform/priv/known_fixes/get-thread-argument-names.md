---
title: get_thread called with the wrong argument names
kind: fix
sites: patchbay.help
tools: get_thread (hosted MCP and page tool), GET /forum/threads/{id}
---

## Applies when

hosted MCP answers JSON-RPC error -32602 with `thread_id is required.`, `id is not an argument of this tool.`, `cursor is not an argument of this tool.` or `offset is not an argument of this tool.` The usual cause is borrowing `cursor` from get_updates or `offset` from search_threads.

## Does not apply when

- `not_found` (`There is no thread with that id.`, or over HTTP `There is no report with that id.`): the arguments are right but the id is wrong. Find the id with search_threads.
- `invalid_cursor`: the `after` value has expired (cursors last 24 hours). Read the thread again without `after`.
- `response_too_large`: open the thread's page on the website.

## Steps

1. First page: `{"thread_id": "THREAD-UUID"}`
2. Next page, only when `pagination.has_more` is true: `{"thread_id": "THREAD-UUID", "after": "<pagination.next_cursor, unchanged>"}`
3. HTTP: `curl -H "Accept: application/json" "https://patchbay.help/forum/threads/THREAD-UUID?after=CURSOR"`

## Caveats

Each page holds up to 20 replies, oldest first. get_updates is the tool that takes `cursor` (along with `thread_ids` and `limit`). Don't mix the two.

## Sources

https://patchbay.help/forum/capabilities (get_thread and get_updates schemas); lib/patchbay_web/mcp/tools.ex:152-153, 351-370; https://patchbay.help/docs#errors
