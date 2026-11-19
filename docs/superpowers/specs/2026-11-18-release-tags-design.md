# Tag and release every `plugin.json` version bump (#282)

## Intent

Claude Code updates an installed plugin only when `version` in `.claude-plugin/plugin.json` changes, and nothing marks which commit a version is: until 2026-11-18 the repository had no tag and no GitHub release, so `chore: bump to 0.7.3` was found only by its subject. A tag per version gives each one a commit, which get.sh follows next (#497, stacked on this). #285 D6 accepted tags on 2026-11-13 and, revised on 2026-11-18, has get.sh follow them; the owner seeded `v0.7.3` by hand on `90e6b04`, the 0.7.3 bump's merge commit.

## Goals

- On a push to `main` where `version` changed, CI creates tag `v<version>` on that merge commit and a GitHub release whose body lists the `feat:` and `fix:` subjects since the previous tag, with no manual step.
- A second run for a version whose tag exists fails and moves nothing.
- A push to `main` that touches `plugin.json` without changing `version` does nothing and passes.
- RELEASING.md, the installer spec, CLAUDE.md and README say tags exist and where they come from.

## Non-goals

- get.sh following tags, `HERMY_REF`: #497.
- Checksums, signed tags, a `--version` flag, a release check in `hermy doctor`.
- A manual rerun entry point (`workflow_dispatch`): a failed run is rerun from the Actions page; the self-test could not cover a second trigger.
- Backfilling tags for 0.6.0 to 0.7.2.

## Constraints

- No third-party action: ci.yml pins `actions/checkout` by SHA and nothing else; a release action would be a dependency to pin and audit. `gh` is on the runner image.
- CI may call GitHub APIs (the MCP-only rule covers skills, not CI).
- The logic is one `run:` block that reads its inputs from `env`, like `templates/hermy.yml`, so `scripts/selftest.sh` extracts and runs it against the stub `gh`, as it does the PR check's.
- The version is read by the same one-line `"version"` form `bin/hermy` and `selftest-core.sh` read by sed.
- Merges to `main` are merge commits (README), so `github.event.before` is the previous `main` tip and the tag lands on the merge commit, as the seed does.

## Approaches

- **A. One workflow, logic inline, release through `gh release create` (chosen).** `.github/workflows/release.yml`, `on: push` to `main` with `paths: [.claude-plugin/plugin.json]`, job-level `permissions: contents: write`, checkout pinned by SHA with `fetch-depth: 0` and `persist-credentials: false`, one `run:` block. `gh release create --target <sha>` creates the tag through the API under `GITHUB_TOKEN`, so the checkout needs no push credential. Testable by extraction; no new file outside `.github/`.
- **B. A script under `scripts/` the workflow calls.** The same logic as a file, run by `scripts/selftest.sh` directly. Rejected: it adds a script `bin/hermy` is not, outside the "only script that mutates" rule's spirit, and the extraction harness already exists for exactly this shape.
- **C. GitHub's generated notes (`--generate-notes`) or a release action.** Less shell. Rejected: the notes would be PR titles, which the issue does not ask for, and an action is a dependency; the owner chose the issue's text on 2026-11-18.

## Decided

- Inputs from `env`: `GH_TOKEN` (`github.token`), `REPO` (`github.repository`), `SHA` (`github.sha`), `BEFORE` (`github.event.before`).
- New version: `plugin.json` at `HEAD`. Old version: the file at `BEFORE`; `BEFORE` all zeros or not in history → `HEAD^`. Equal → print that nothing changed, exit 0.
- New version lower than the old by `sort -V` (a revert of a bump) → print that it went down, exit 0, before the tag check, since its tag is on `origin`.
- Tag `v<new>` on `origin` (`git ls-remote --exit-code --tags origin refs/tags/v<new>`) → `::error::` naming it, exit 1, nothing created or moved. `gh release create` alone would attach a release to the existing tag, so this check comes first.
- Previous tag: the newest `v[0-9]*` tag merged into `HEAD` whose version sorts below `v<new>` by `sort -V` (`git tag --merged HEAD -l 'v[0-9]*'` with `v<new>` added, sorted, the line before `v<new>`), so after a reverted release a lower bump's notes count from the last tag below it, not from the reverted one. Notes: subjects in `<prev>..HEAD` matching `^(feat|fix)(\(.*\))?:`, one per line; merge commits are left out by `git log --no-merges`, whatever their subject, since a merge titled like its PR matches. No previous tag → the body says it is the first tagged release, with no list.
- The list sits in a ```` ```text ```` fence, so a link or mention in a subject shows as text and pings no one; every line starts with `feat` or `fix`, so none closes the fence.
- Each CR in a subject becomes a space before the match: git keeps one mid-subject and Markdown reads it as a line end, which would let the rest of the subject close the fence.
- A previous tag and no matching subject → the body is one line saying there is no `feat:` or `fix:` change since it.
- The job runs in concurrency group `release` with `cancel-in-progress: false`, so two bumps merged close together run one after the other and the second's tag check sees the first's tag. GitHub keeps one waiting run per group and cancels the older waiting one, so a third bump close behind cancels the second's run, which is rerun from the Actions page like a failed one.
- A `v[0-9]*` tag not merged into `HEAD` above `v<new>` by `sort -V` (`git tag --no-merged HEAD -l 'v[0-9]*' --sort=-v:refname | head -1`), as when a failed or cancelled run is rerun after a later bump shipped → `--latest=false`, so the later release stays Latest. A higher tag merged into `HEAD`, a release since reverted, does not count.
- Then one `gh release create v<new> --target "$SHA" --title v<new> [--latest=false] --notes-file <file>`.
- Docs: RELEASING.md's line 3 (tags exist from `v0.7.3`; CI creates one per bump) and a step 7 line (the tag and release appear on merge; check them before the marketplace update); the installer spec's goal and non-goal lines amended to say tags exist and come from CI (#282), get.sh's behaviour left to #497; one clause in CLAUDE.md's release sentence and in README's release rule.
- Self-test, in `scripts/selftest.sh` next to the PR check's cases: extract the run block; a scratch repository with a bare `origin` and the stub `gh` logging its calls. Cases: version unchanged → exit 0, no `gh` call; changed and `v<new>` on `origin` → exit 1, no `gh` call; changed, no tag → exit 0, one `gh release create v<new> --target <sha>` call, the notes file holding exactly the `feat:`/`fix:` subjects since the previous tag; changed with no previous tag → the first-release body.

## Left to the builder

- The exact `env` names and the extraction `sed`, matching `templates/hermy.yml`'s shape so the same selftest pattern applies.
- How the stub `gh` records `release create` and its `--notes-file` content.
- Wording of the four doc edits.
