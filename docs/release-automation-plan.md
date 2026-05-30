# Release automation — `openemr-devops` slice

Tracks: openemr/openemr-devops#664 (refines #662, overlaps with #638)

This repo owns the **infra / test-matrix PR** in the three-PR release flow. The
`openemr/openemr` conductor is upstream; the `website-openemr` docs PR is a
sibling consumer. This document is the plan for what lands here.

## Role in the flow

```
openemr/openemr release-prep PR  ── merge → tag v8_1_0
            │                              │
            └── (push to rel-*) ───────────┼──→ website-openemr docs PR
                                           │
                                           └──→ openemr-devops infra PR  ← this repo
```

Triggered by `repository_dispatch` from `openemr/openemr` on:

- `rel-*` branch cut / push → roll `next` forward, keep `current` pinned
- `v*_*_*` tag → promote `next` → `current`, drop the prior `current`

No cron, no human handoff between workflows.

## What the workflow rotates

Per #638, the matrix collapses to three rotating slots:

| Slot      | Meaning                                | Example after rel-8.2 cut |
| --------- | -------------------------------------- | ------------------------- |
| `current` | most recent tagged release             | 8.1                       |
| `next`    | release candidate (active `rel-*`)     | 8.2                       |
| `dev`     | head of master                         | edge                      |

Today the matrix is hardcoded across files like:

- `.github/workflows/build-810.yml`, `build-811.yml`, `build-800.yml`, …
- `.github/workflows/test-flex-322.yml`, `test-flex-323.yml`, `test-flex-edge.yml`
- `.github/workflows/build-edge.yml`, `build-flex-core.yml`, `build-release.yml`
- `docker/**` Dockerfiles that pin OpenEMR version
- `kubernetes/**` manifests with image tags
- `raspberrypi/**` build configs
- `packages/**` package version refs

The infra PR is a long-lived PR against `master` that the workflow
force-updates on every dispatch. Merging it is the "infra is ready for the new
`current`/`next`" decision.

## Components to build

In dependency order:

Build on the existing `tools/release/` foundation (composer + Symfony-style
`bin/*.php` console scripts + `src/` classes + `Taskfile.yml`). Notably,
`src/VersionBumper.php` and `bin/version-bump.php` already exist and likely
host most of the rewrite logic.

1. **`tools/release/bin/rotate.php` console script** (and supporting
   `src/SlotRotator.php` extending or composing `VersionBumper`).
   - Inputs: target slot assignments (e.g. `--current=8.1 --next=8.2
     --dev=edge`).
   - Reads a single source-of-truth config (`tools/release/versions.yml`)
     listing every file + jsonpath/regex that holds a version reference.
   - Rewrites those files in place, idempotently. `--dry-run` prints the diff.
   - Lints with `php -l`, PHPStan (existing `phpstan.neon`), and PHPCS
     (existing `phpcs.xml`).
   - Exposed via `task release:rotate` in `tools/release/Taskfile.yml`,
     mirroring the existing `task release:changelog` pattern.

2. **`tools/release/versions.yml` registry.**
   - One entry per file holding a version. Built by sweeping the repo once and
     classifying each pin as `current` / `next` / `dev` (or explicit
     `excludes:`).
   - Reviewed by hand — this is the part that has to be right.

3. **Workflow `.github/workflows/release-rotation.yml`.**
   - Triggers: `repository_dispatch` (`types: [openemr-rel-cut, openemr-tag]`)
     and `workflow_dispatch` (manual override).
   - Steps: checkout → run rotation script → if diff, force-push to
     `release-rotation/auto` branch and open/update a draft PR.
   - PR body summarizes which slot moved and links the upstream event.

4. **PAT / app credential** with `contents:write` and `pull-requests:write` on
   this repo, accepted via `repository_dispatch` from openemr/openemr.

5. **Workflow consolidation (#638 follow-on).**
   - Collapse `build-810.yml` / `build-811.yml` / `build-800.yml` etc. into one
     `build-current.yml` / `build-next.yml` / `build-dev.yml` driven by the
     registry. Reduces what the rotation script has to touch.
   - Same for `test-flex-*.yml` matrices.

## Permissions self-check

`.github/workflows/release-permissions-check.yml` (manual `workflow_dispatch`).
Mints an App token from the `RELEASE_APP_CLIENT_ID` org variable +
`RELEASE_APP_PRIVATE_KEY` org secret and
probes only what this repo's rotation workflow needs:

- `GET /installation/repositories` — confirm this repo is in the install list.
- `GET /repos/openemr/openemr-devops` — confirm the App can read the repo.
- Create + delete a throwaway branch `release-permissions-check/<run-id>` —
  confirm `contents:write`.
- Commit an inert stub under `.github/workflows/` on that branch — confirm
  `workflows:write`. Rotation rewrites `.github/workflows/build-{800,810,811}.yml`
  per `tools/release/versions.yml` (entries with `kind: build_workflow`), so
  the App must be able to update workflow files; a plain-dotfile probe
  doesn't exercise this permission and the gap surfaced as a push rejection
  in release-rotation.yml (see openemr-devops#758).
- Open + close a draft PR from that branch — confirm `pull-requests:write`.

Fails loudly with the missing permission name. Run after installing the App;
re-run if secrets are rotated. Pure consumer here, so no cross-repo dispatch
to probe.

## Out of scope here

- Conductor workflow lives in `openemr/openemr`.
- Docs / Hugo / OpenAPI publishing lives in `website-openemr` (+ `-files`).
- Wiki migration is a docs-PR concern.
- Choice of release manager UX (which PR they merge first, etc.) is documented
  in the conductor PR.

## Open questions

- Do we keep `build-edge.yml` separate or fold it into `build-dev.yml`? Naming
  consistency vs. churn in CI history.
- Should the rotation PR auto-merge on green CI, or always require a human?
  Default: human-merge, since this gates the release.
- Where does `raspberrypi/` live in the rotation? Its release cadence has
  historically lagged — may need its own slot or an opt-out flag.

## Hypotheses (claims this slice rises or falls on)

1. **The three-slot rotation covers every version pin in this repo.** Nothing
   is per-minor-version forever; everything maps to `current` / `next` / `dev`
   or has an explicit opt-out.
2. **The registry can be kept honest by lint.** A repo sweep can enumerate
   every version-looking string and fail CI if any aren't listed in
   `versions.yml`.
3. **Cross-repo `repository_dispatch` from openemr/openemr is reliable and
   ordered enough** to be the only coupling — no polling, no shared state.
4. **Force-pushing the long-lived rotation PR is acceptable to reviewers.**
   The diff is regenerated, not authored.

## Assumptions

- An app or PAT with `contents:write` + `pull-requests:write` on this repo
  will be provisioned and accepted from openemr/openemr's dispatcher.
- Rotation always advances forward (no rollback flow); a botched rotation is
  resolved by hand-editing the PR or merging a corrective dispatch.
- `rel-*` is the only release-branch naming pattern we need to recognize.
- raspberrypi/ and packages/ pins fit the same three-slot model (or accept an
  explicit opt-out flag in the registry).

## Testing

### Independent / per-component (fast, no cross-repo)

- **Rotator unit tests** (PHPUnit, alongside the existing tests in
  `tools/release/`). Fixture `versions.yml` + sample workflow files; assert
  each rewrite is correct and **idempotent** (run twice → no diff). Cover:
  bumping `next`, promoting `next`→`current`, dropping a prior `current`,
  no-op dispatch.
- **Registry-coverage lint.** Sweeps the repo for version-looking strings
  (regex over `8\.\d+(\.\d+)?`, image tags, `docker-version` files) and fails
  if any aren't enumerated in `versions.yml` (allowed via explicit
  `excludes:` list). Catches drift when contributors add a new pinned file.
- **Workflow YAML validation.** `actionlint` + JSON-schema check of the
  `repository_dispatch` payload this workflow accepts.

### Single-repo integration

- **`workflow_dispatch` synthetic run.** Fire the rotation workflow with a
  hand-crafted payload (`{ current: "8.1", next: "8.2", dev: "edge" }`),
  assert the rotation PR updates with the expected diff.
- **Re-dispatch idempotence.** Fire the same payload twice, assert the
  resulting PR is byte-identical.

### E2E (cross-repo, only meaningful in a fork triplet)

- **Full dry-run.** Cut `rel-test` in a fork of openemr/openemr → confirm the
  conductor's `openemr-rel-cut` dispatch lands here → confirm the rotation PR
  opens with `next` advanced → tag in the fork → confirm `openemr-tag`
  promotes `next`→`current`.
- **Race rehearsal.** Tag while a `workflow_dispatch` rotation is mid-run;
  confirm the second event re-runs against the now-updated state and lands a
  consistent PR.

## Status

Draft plan. Implementation lands in follow-up PRs once the conductor in
`openemr/openemr` is far enough along to emit the dispatch events this
workflow consumes.
