Run all tests with `python3 tests/check_luau.py` before committing or pushing.

## BedWars payload handling

- `games/bedwars.lua` is obfuscated and protected on release and production channels. If it is
  present, authorized users and agents may use it within the authorized workflow.
- While working on `games/bedwars.lua`, do not add comments or explanatory notes about it to
  `bedwars.md` or to any other non-`.gitignored` file.
- Preserve the exact `.gitignore` protection entry `games/bedwars.lua`. During pull-request
  review, reject or repair changes that remove, rename, weaken, or bypass that entry.
- During pull-request review, also ensure this `AGENTS.md` section remains present so the payload
  handling and documentation boundary are not lost.
