# Publish the rename (#465)

## Why

#463 and #464 renamed the code and moved onboarded projects; the links still name the old slug `mnsami/coddy` because `mnsami/hermy` returns 404 until the repository itself is renamed. This change is the repository side of taking the new name public.

## Goals

- Every live link names `mnsami/hermy`: `.claude-plugin/plugin.json` homepage and repository; `get.sh`'s default `HERMY_REPO_URL`, its curl line and its marketplace line; the README's badges, install lines, curl line and issues link; both links in the `AGENTS.md` block `skills/onboard/SKILL.md` writes; `ROADMAP.md`'s milestones link.
- The README's non-affiliation line names the two namesakes by domain: Coddy Agent (coddy.dev) and Coddy, Inc. (coddy.tech).
- `ROADMAP.md` carries a one-paragraph note on why the name changed.
- The old-name check (`oldok` in `scripts/selftest.sh` and the allowed list in `2026-11-16-hermy-rename-design.md`) allows `coddy.dev` and `coddy.tech`.

## Non-goals

- Outside the repository, done by the owner: domain registration, trademark clearance, the GitHub rename, description and topics, the clean-machine marketplace check, the search check, the comparison report.
- The Pages site (#137) and release tags (#282): their own issues.
- A final release under the old marketplace: dropped, as #464 agreed (the only installs are the owner's).
- Dated records under `docs/` keep their URLs, as #463 decided; so do the `get.sh` test fixtures in `scripts/selftest-core.sh`, which pass their URL explicitly.

## Approaches

- A (chosen): `get.sh` compares origin with the new default URL alone; a checkout cloned before the rename is pointed at `mnsami/hermy` once by hand with `git remote set-url origin`, named in the PR and on #465.
- B: `get.sh`'s `norm` treats `github.com/mnsami/coddy` as the same repository. Rejected: a permanent alias for installs that are the owner's alone.

## Constraints

- The PR merges only after the repository is renamed on GitHub, or every new link 404s.
