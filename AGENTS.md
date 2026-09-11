Run all tests with `python3 tests/check_luau.py` before committing or pushing.

## Executor documentation

- All executor documentation is available under `docs/executors/`.
- `getgenv()` accesses a table with a global, executor-only metatable that holds all keys and
  values for executor functions.

## Change authorization

- Do not modify, refactor, or otherwise change modules unless the user explicitly requests
  changes to those modules.
- Always ask for and receive explicit permission before building or applying patches, or before
  attempting an implementation or other proposed solution. Read-only inspection is allowed.
- A broad request to change, fix, implement, optimize, or refactor something authorizes planning
  and read-only inspection only. Before editing, show the user the exact proposed line-by-line
  changes as a patch and explicitly ask for permission to apply those line edits. Do not infer
  line-edit approval from the broader request.
- Approval applies only to the exact line edits shown. If implementation requires any additional
  or revised line edits, stop, show those edits, and obtain fresh explicit approval before
  applying them.

## Line-edit delegation

- The primary agent must inspect the relevant code and plan the exact line-by-line
  changes, then show the proposed patch to the user for explicit approval.
- After approval, delegate applying the exact approved line edits to a sub-agent
  using model `gpt-5.6-luna` with reasoning effort `max` to reduce token usage.
- Give the sub-agent the approved patch and necessary context. It must apply only
  those edits and report any issue requiring revised or additional changes.
- The primary agent must review the resulting diff against the approved patch
  and complete required validation.

## Public release boundary

- Never mention any antitamper system or its implementation in public-release code,
  documentation, changelogs, or other user-facing release artifacts.
- Never update `AGENTS.md` in the public repositories `scrxpted7327/pistonware-patches` or
  `themagicpiston/pistonware`.

## BedWars payload handling

- `games/bedwars.lua` is obfuscated and protected on release and production channels. If it is
  present, authorized users and agents may use it within the authorized workflow.
- While working on `games/bedwars.lua`, do not add comments or explanatory notes about it to
  `bedwars.md` or to any other non-`.gitignored` file.
- Preserve the exact `.gitignore` protection entry `games/bedwars.lua`. During pull-request
  review, reject or repair changes that remove, rename, weaken, or bypass that entry.
- During pull-request review, also ensure this `AGENTS.md` section remains present so the payload
  handling and documentation boundary are not lost.
