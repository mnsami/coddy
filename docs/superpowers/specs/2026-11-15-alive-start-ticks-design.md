# alive compares start ticks on Linux (#445)

## Why

`alive` treats a lock's owner as running only while `ps -o lstart` for its pid matches, to the second, the start time recorded in the owner line. On Linux, `ps` derives that time from the wall clock. A clock correction on a freshly booted VM can move it by a second, so a running owner reads as gone and a second `claim` takes the lock. The claim-race self-test failed this way in 3 of 4 ubuntu-latest runs on 2026-11-14/15 (PRs #444 and #452), while macOS always passed.

## Goals

- On Linux, a running owner is never read as gone because of the clock.
- A pid reused by another process still reads as gone, as it does today.
- When the race test fails, it shows why.

## Non-goals

- macOS and other systems without `/proc`, where the race has never failed. They keep the current exact `lstart` check.
- The other `alive` callers' messages.
- #449.

## Anti-goals

- No owner line that 0.6.0 or 0.7.x would misread. The new field goes last, after the UTC start, where both readers ignore it.

## Approaches

- **A, chosen: start ticks on Linux.** Record the process's start in clock ticks since boot (`/proc/<pid>/stat` field 22), which no clock change moves, and compare those when both sides have them.
- B, ±2 s on `lstart`, was rejected. It needs BSD and GNU `date` parsing, and a clock step over 2 s still breaks it.
- C, pid only on Linux, was rejected. It brings back the reused-pid problem the start time exists for.

## Design

**bin/hermy**
- `ticks <pid>`: reads `/proc/<pid>/stat` with shell builtins, drops everything up to the last `) ` (the command name may hold spaces and parentheses), and prints field 22 (field 20 of the remainder) when it is all digits. It prints nothing otherwise, for example on macOS or with no `/proc`.
- `myline` appends `t<ticks>` as a fifth field, but only when the fourth (UTC start) field is written. A line without `ps` stays as it is now, so 0.6.0 never reads the ticks as its start.
- `owner` reads `read -r sid pid _ start tk _`. `tk` counts only when it matches `t[0-9]+`.
- `alive <pid> <start> [<tk>]`: when `tk` is set and `ticks <pid>` prints something, the result is whether they are equal. Otherwise it is unchanged. Every caller passes the owner's `tk`: `mine`, `status`, `guard`, `claim`, `push`, `sweep`, `drop`, `refresh` and `state`.

**Tests**
- The race test (`scripts/selftest.sh`, about line 331) captures each claim's stderr. When it fails, it prints `xr yr` and both stderr files.
- New tests, Linux only (they skip without `/proc/$$/stat`):
  - an owner line with the right ticks and a UTC start one second off reads as running: `claim` refuses, and `status` says running;
  - wrong ticks read as gone.
- A test that `claim` writes five fields where `/proc` exists, and four where it doesn't.

**Docs:** CLAUDE.md's Lock states names the fifth field and the tick comparison.

## Left to the builder

- Which existing self-tests that write owner lines by hand need a fifth field, and which keep four to cover lines from before this change.
- ponytail: ticks count from boot, so a lock that survives a reboot could be read as alive. That needs a new process with the same pid and the same tick count, which is accepted as negligible.
