# Remove doctor's dead PATH fallback check (#471)

## Why

`doctor`'s `hooks` line has an arm (`bin/hermy`, the `elif … grep -q 'command -v hermy'`) that reports a git hook falling back to a `hermy` on `PATH`. No release ever wrote that. The fallback was dropped in #182 (f94d353), before the rename, and the rename (#463) only swapped the literal. The arm sits behind the header gate, which only lets through hooks with the `# Written by hermy start: ` header, so it can never fire.

## Goals

- `doctor` no longer carries the dead arm.
- No test, comment or doc describes a `PATH` fallback that no release had.

## Non-goals

- Changing any other `hooks` check, or how `start` migrates `.git/hooks/coddy`.

## Approaches

- A. Remove the check. A hook from before the rename is still reported: with `core.hooksPath` at `.git/hooks/coddy`, `doctor` says "core.hooksPath is …, not hermy's directory". `start` rewrites those hooks and removes the old ones.
- B. Legacy read: look for the old `PATH` fallback in hooks under `.git/hooks/coddy` that carry `# Written by coddy start: `. That needs a new branch ahead of the `core.hooksPath` check, one more spelling the old-name check allows, and a new fixture, all for a project nobody has run `start` in since #182.

Chosen: A (user, 2026-11-18).

## Changes

- `bin/hermy`: drop the `command -v hermy` `elif` in `doctor`'s hooks loop. `tf` stays, because the in-project arm uses it.
- `scripts/selftest-core.sh`:
  - drop `oldhook()`, its `prob`, and the PATH-fallback wording in the comment above them;
  - drop the fake `command -v hermy` simulation before `start` (its comment, the `sed` loop and the two asserts on it), keeping the `start` call and the `HERMY_EXEC` assert after it, which already prove the rewrite.
- `CLAUDE.md`: drop "neither falling back to a `hermy` on `PATH`, as an older hermy's did," from the `doctor` description, keeping the sentence grammatical.
