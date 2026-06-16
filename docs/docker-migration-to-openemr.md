# Docker migration: openemr-devops to openemr core

Living planning doc for the docker-image migration proposed in
[openemr/openemr-devops#790](https://github.com/openemr/openemr-devops/issues/790).
Discussion happens in the issue thread; this file tracks the agreed-upon
shape of the work and gets updated as PRs land.

## Goal

Migrate the production OpenEMR docker images and their build/test pipelines from `openemr/openemr-devops` into `openemr/openemr`, with each production version's Dockerfile living on its corresponding `rel-X.Y.Z` branch and master holding the dev/flex/binary infrastructure. `openemr-cmd` and the Kubernetes manifests stay in this repo.

## Proposed model

Each branch carries the same filenames for its docker pipeline; contents diverge per branch. Master orchestrates the schedule; each rel branch owns its own Dockerfile, build steps, and tests end-to-end.

**openemr/openemr master:**

```
docker/release/Dockerfile          ← next-version / "dev" production image
docker/flex/Dockerfile             ← multi-version dev/edge (matrix-driven)
docker/binary/Dockerfile           ← static-binary helper

tests/bats/docker/flex/                           ← BATS tests for flex
tests/bats/docker/binary/                         ← BATS tests for binary
tests/bats/docker/release/                        ← BATS tests for master's "next" Dockerfile

.github/workflows/docker-build-release.yml        ← byte-identical across all branches; reads tags from input set by master's orchestrator
.github/workflows/docker-build-flex-core.yml      ← reusable workflow holding the actual flex build steps
.github/workflows/docker-build-322.yml            ← thin caller for alpine 3.22 PHP matrix
.github/workflows/docker-build-323.yml            ← thin caller for alpine 3.23 PHP matrix
.github/workflows/docker-build-edge.yml           ← thin caller for alpine edge PHP matrix
.github/workflows/docker-build-binary.yml
.github/workflows/docker-test-release.yml         ← PR validation for release Dockerfile (renamed from devops's test-production.yml; no more multi-version glob)
.github/workflows/docker-test-flex-322.yml        ← PR validation for alpine 3.22 flex
.github/workflows/docker-test-flex-323.yml        ← PR validation for alpine 3.23 flex
.github/workflows/docker-test-flex-edge.yml       ← PR validation for alpine edge flex
.github/workflows/docker-test-binary.yml
.github/workflows/docker-test-bats.yml            ← runs tests/bats/docker/{flex,binary,release}/
.github/workflows/docker-test-core.yml            ← reusable building block
.github/workflows/docker-test-container-functionality.yml
.github/workflows/docker-release-orchestrator.yml         ← schedule + fan-out via workflow_dispatch --ref (reads release-targets.yml)
.github/release-targets.yml                               ← release config as data: branch / docker_tags / openemr_version_ref per row
```

**openemr/openemr `rel-X.Y.Z`** (each release branch):

```
docker/release/Dockerfile          ← version-pinned for X.Y.Z
tests/bats/docker/release/                        ← branch-local BATS tests, version prefixes stripped
.github/workflows/docker-build-release.yml        ← byte-identical to master's; tags come from orchestrator input
.github/workflows/docker-test-release.yml         ← runs against this branch's Dockerfile
.github/workflows/docker-test-bats.yml            ← runs only tests/bats/docker/release/
```

No flex / no binary / no orchestrator / no test-core / no test-flex-* on rel branches. They are self-contained for their one production image.

Per-branch release config (carried in `.github/release-targets.yml` on master; the orchestrator reads this file):

| Branch | `docker_tags` | `openemr_version_ref` |
|---|---|---|
| master | `dev,next` | `master` |
| `rel-810` | `8.1.0,latest` | `v8_1_0` |
| `rel-800` | `8.0.0` | `v8_0_0` |
| `rel-704` | `7.0.4` | `v7_0_4` |

(`rel-811` doesn't exist yet; when it's cut from master, the standard branch-cut steps below add it.)

`openemr_version_ref` is the git ref baked into the image as the `OPENEMR_VERSION` ARG. Decoupling it from `docker_tags` means a rel branch can stage post-release patches without affecting the published image until you cut a new tag (e.g. `v8_1_0_1`) and bump just `openemr_version_ref`.

## Validated foundation

The core design assumption -- that `workflow_dispatch --ref <rel-branch>` from a master-side orchestrator runs the rel-branch's workflow definition AND checks out the rel-branch's tree -- was validated in a throwaway fork experiment. Both the dispatched workflow's YAML steps and the runner's checkout came from the target branch, not master. Confirmed `github.ref` == `refs/heads/<target-branch>` in the dispatched run.

This means: when master's `docker-release-orchestrator.yml` dispatches `docker-build-release.yml --ref rel-810`, the resulting run uses rel-810's `docker-build-release.yml` definition (its tag list, its build steps) against rel-810's `docker/release/Dockerfile`. Per-branch isolation is real.

## Master orchestrates schedule AND tag assignment

`docker-release-orchestrator.yml` on master does two jobs: it owns the cron tick (since GitHub Actions `schedule:` only fires from the default branch), and it dispatches each release build with the right config. The actual config lives in **`.github/release-targets.yml`** -- a flat YAML data file -- so the orchestrator workflow is pure mechanism and the data is the policy. Consequences:

- `docker-build-release.yml` is **byte-identical** across master and every rel branch. So is `docker/release/Dockerfile` -- the per-branch source-tracking decision (`openemr_version_ref`) is passed in as a build-arg.
- Tag promotion (rotating `latest`, bumping `next`) is a one-line edit in `release-targets.yml` on master -- no PR against the affected rel branch.
- Promoting rel-810 to a `v8_1_0` release is a one-line edit changing that row's `openemr_version_ref` from `rel-810` to `v8_1_0`. Subsequent patches to rel-810 don't affect the published image until you cut `v8_1_0_1` and bump the field again.
- Branch-cut: append one row to `release-targets.yml`. No edits to the new branch's Dockerfile or workflow files.

### Release config data file (`.github/release-targets.yml`)

Single source of truth for which branches build, which docker tags they push, and which openemr source ref they bake in. Tooling and bots can parse + edit it with any YAML library.

```yaml
# .github/release-targets.yml
- branch: master
  # 8.1.1 is manually placed alongside dev/next floating aliases because
  # version.php in master currently reports 8.1.1-dev. Bump when master
  # moves to the next cycle. The docker_tag <-> version.php alignment
  # guard in docker-validate-release-targets.yml catches drift on PRs.
  docker_tags: 8.1.1,dev,next
  openemr_version_ref: master

- branch: rel-810
  docker_tags: 8.1.0,latest
  openemr_version_ref: v8_1_0   # release tag, not rel-810 HEAD

- branch: rel-800
  docker_tags: 8.0.0
  openemr_version_ref: v8_0_0

- branch: rel-704
  docker_tags: 7.0.4
  openemr_version_ref: v7_0_4
```

Naming chosen to be unambiguous: `docker_tags` (not just `tags`, which collides with git tags) and `openemr_version_ref` (not `openemr_version`, which would imply a version string rather than a git ref).

### Orchestrator skeleton (master)

A `compute-matrix` job reads `release-targets.yml`, applies the include/exclude filter, and emits the matrix as JSON; a `fan-out` job consumes that matrix and dispatches one build per row.

```yaml
# .github/workflows/docker-release-orchestrator.yml
on:
  schedule:
  - cron: '0 6 * * *'
  workflow_dispatch:
    inputs:
      include:
        description: 'Branches to build (comma-separated, or "all"). Examples: "all", "rel-810", "rel-810,master"'
        type: string
        default: 'all'
      exclude:
        description: 'Branches to skip (comma-separated). Useful with include=all.'
        type: string
        default: ''

permissions:
  actions: write
  contents: read

jobs:
  compute-matrix:
    if: github.repository_owner == 'openemr' && github.repository == 'openemr/openemr' && github.ref == 'refs/heads/master'
    runs-on: ubuntu-24.04
    outputs:
      matrix: ${{ steps.gen.outputs.matrix }}
    steps:
    - uses: actions/checkout@v6
      with:
        sparse-checkout: |
          .github/release-targets.yml
    - id: gen
      env:
        INCLUDE: ${{ inputs.include || 'all' }}
        EXCLUDE: ${{ inputs.exclude || '' }}
        EVENT: ${{ github.event_name }}
      run: |
        # yq is preinstalled on github-hosted runners.
        FILTERED=$(yq -o=json -I=0 . .github/release-targets.yml | jq -c \
          --arg inc "$INCLUDE" --arg exc "$EXCLUDE" --arg ev "$EVENT" '
          [ .[] |
            . as $row |
            select(
              ($ev == "schedule") or
              ($inc == "all") or
              ($inc | split(",") | map(. == $row.branch) | any)
            ) |
            select(
              ($exc | split(",") | map(. == $row.branch) | any) | not
            )
          ]
        ')
        echo "matrix={\"include\":$FILTERED}" >> "$GITHUB_OUTPUT"

  fan-out:
    needs: compute-matrix
    runs-on: ubuntu-24.04
    strategy:
      fail-fast: false
      matrix: ${{ fromJSON(needs.compute-matrix.outputs.matrix) }}
    steps:
    - name: Dispatch ${{ matrix.branch }} (docker_tags=${{ matrix.docker_tags }} openemr_version_ref=${{ matrix.openemr_version_ref }})
      env:
        GH_TOKEN: ${{ github.token }}
      run: |
        gh workflow run docker-build-release.yml \
          --repo ${{ github.repository }} \
          --ref ${{ matrix.branch }} \
          -f docker_tags="${{ matrix.docker_tags }}" \
          -f openemr_version_ref="${{ matrix.openemr_version_ref }}"
```

Cron runs (`event == 'schedule'`) bypass both filters and run every row. Manual dispatch takes string inputs -- type `all` (default) for everything, or specific branches like `rel-810,master`.

The orchestrator carries **logical** docker_tags only (`8.1.0,next`); `docker-build-release.yml` is responsible for expanding version-number tags into dated siblings -- see below.

### docker-build-release.yml (byte-identical across all branches)

```yaml
# .github/workflows/docker-build-release.yml -- identical on master and every rel-X.Y.Z
on:
  workflow_dispatch:
    inputs:
      docker_tags:
        description: 'Comma-separated docker tags to push (e.g. "8.1.0,latest"; leave default for an ad-hoc test build)'
        required: true
        type: string
        default: 'manual-test'
      openemr_version_ref:
        description: 'OpenEMR git ref to bake (branch, tag, or SHA). Empty = use the dispatching branch name.'
        required: false
        type: string
        default: ''
  push:
    tags: ['v*']    # real release tagging; tag value drives docker tag

jobs:
  build:
    runs-on: ubuntu-24.04
    steps:
    - uses: actions/checkout@v6

    - name: Compute build date
      id: build_date
      run: echo "date=$(date +'%Y-%m-%d')" >> "$GITHUB_OUTPUT"

    - name: Expand docker_tags list (add dated variant for version-number tags)
      id: expand_docker_tags
      env:
        INPUT_TAGS: ${{ inputs.docker_tags }}
        BUILD_DATE: ${{ steps.build_date.outputs.date }}
      run: |
        {
          echo 'list<<EOF'
          IFS=',' read -ra TAGS <<< "$INPUT_TAGS"
          for t in "${TAGS[@]}"; do
            t="${t// /}"   # strip whitespace
            [ -z "$t" ] && continue
            echo "openemr/openemr:${t}"
            # Rule: version-number tags (digits and dots only) also get a dated sibling.
            # "8.1.0" -> push "8.1.0" + "8.1.0-2026-06-13"
            # "next" / "dev" / "latest" / "manual-test" -> no dated variant.
            if [[ "$t" =~ ^[0-9]+(\.[0-9]+)+$ ]]; then
              echo "openemr/openemr:${t}-${BUILD_DATE}"
            fi
          done
          echo EOF
        } >> "$GITHUB_OUTPUT"

    - name: Resolve openemr_version_ref (input, or fall back to dispatching branch / git tag)
      id: resolve_openemr_version_ref
      env:
        EVENT_NAME: ${{ github.event_name }}
        INPUT_REF: ${{ inputs.openemr_version_ref }}
        REF_NAME: ${{ github.ref_name }}
      run: |
        if [ -n "$INPUT_REF" ]; then
          echo "ref=$INPUT_REF" >> "$GITHUB_OUTPUT"
        else
          echo "ref=$REF_NAME" >> "$GITHUB_OUTPUT"
        fi

    - name: Build and push
      uses: docker/build-push-action@v6
      with:
        context: ./docker/release
        push: true
        tags: ${{ steps.expand_docker_tags.outputs.list }}
        build-args: |
          OPENEMR_VERSION=${{ steps.resolve_openemr_version_ref.outputs.ref }}
```

When the orchestrator dispatches `-f docker_tags="8.1.0,latest" -f openemr_version_ref="v8_1_0"`, the build pushes `openemr/openemr:8.1.0`, `openemr/openemr:8.1.0-2026-06-13`, and `openemr/openemr:latest` (the version-number `8.1.0` gets a dated sibling, the floating `latest` doesn't) -- and bakes the `v8_1_0` tag of openemr/openemr as the source. When a maintainer manually dispatches for testing with no overrides, `docker_tags` defaults to `manual-test` (safe sentinel) and `openemr_version_ref` falls back to the dispatching branch name.

The dated-tag rule matches the current devops convention (`date +'%Y-%m-%d'` from build-openemr.yml's tag-merge step). It lives in docker-build-release.yml so the orchestrator + release-targets.yml stay purely declarative -- only logical tags appear in config.

## What moves where (concrete)

| Source (openemr-devops) | Destination |
|---|---|
| `/docker/openemr/flex/` | `openemr` master `docker/flex/` |
| `/docker/openemr/binary/` | `openemr` master `docker/binary/` |
| `/docker/openemr/8.1.1/` | `openemr` master as `docker/release/` (this dir tracks `OPENEMR_VERSION=master`, so it's the dev/next build, not a real rel-811 yet) |
| `/docker/openemr/8.1.0/` | `openemr` `rel-810` as `docker/release/` |
| `/docker/openemr/8.0.0/` | `openemr` `rel-800` as `docker/release/` |
| `/docker/openemr/7.0.4/` | `openemr` `rel-704` as `docker/release/` |
| `/tests/bats/flex/` | `openemr` master as `tests/bats/docker/flex/` |
| `/tests/bats/binary/` | `openemr` master as `tests/bats/docker/binary/` |
| `/tests/bats/8.1.1/` | `openemr` master as `tests/bats/docker/release/` (matches the docker dir's destination) |
| `/tests/bats/8.1.0/` | `openemr` `rel-810` as `tests/bats/docker/release/` |
| `/tests/bats/helpers.bash` | Removed (one-line constant inlined in each `.bats` file) |
| `build-flex-core.yml` (reusable) | `openemr` master `docker-build-flex-core.yml` (prefixed during move) |
| `build-322.yml` / `build-323.yml` / `build-edge.yml` | `openemr` master, prefixed to `docker-build-322.yml` / `docker-build-323.yml` / `docker-build-edge.yml` |
| `build-704/800/810/811.yml` | Per-rel-branch `docker-build-release.yml` (orchestrator-driven, single-row matrix entry on master) |
| `test-bats.yml` | Master + each rel branch as `docker-test-bats.yml` (filtered to local BATS dirs) |
| `test-production.yml` | Master + each rel branch as `docker-test-release.yml` (simplified, no multi-version glob) |
| `test-flex-322.yml` / `test-flex-323.yml` / `test-flex-edge.yml` | `openemr` master, prefixed to `docker-test-flex-322.yml` etc. |
| `test-core.yml` | `openemr` master as `docker-test-core.yml` (reusable) |
| `test-container-functionality.yml` | `openemr` master as `docker-test-container-functionality.yml` |
| `build-release-on-tag.yml` + `build-release.yml` (release packaging / tarballs in devops) | Replaced by in-repo `on: push: tags:` triggers on each rel branch's `docker-build-release.yml`. Devops's `build-release.yml` (packaging) is distinct from the docker workflow and needs migrating under a non-colliding name (e.g. `package-release.yml`). |
| `hadolint.yml` (existing in openemr core, not devops) | Rename to `docker-lint-hadolint.yml`. Update self-references at line 11+19 inside the file + the `[![Dockerfile Linting](.../hadolint.yml/badge.svg)]` badge URL in README.md. Check name (`Dockerfile Linting`) is unaffected since it's set via `name:`. |

## Hard-coded version paths that get wiped

BATS files like `tests/bats/8.1.1/config_files.bats`:

- `@test "8.1.1 Dockerfile: ..."` → `@test "Dockerfile: ..."` (branch context tells you the version)
- `SCRIPT_DIR="$(get_script_dir 8.1.1)"` → direct path constant or removed entirely
- `helpers.bash`'s `get_script_dir` function → removed
- Workflow `paths:` triggers shrink from multi-version lists to just `tests/bats/docker/release/**` and `docker/release/**` on rel branches

## Dependabot

The current devops dependabot.yml has entries for `/docker/openemr/{7.0.4,8.0.0,8.1.0,binary,flex}` but those entries have generated zero PRs in the past month -- the Dockerfiles use `FROM alpine:${ALPINE_VERSION}` (ARG expansion) which Dependabot's docker ecosystem cannot parse. The kubernetes entries (which use literal `image: alpine:3.23` refs) work fine and generate steady PR flow.

So no Dependabot migration is required for the production Dockerfiles -- the entries are inert. They can be deleted from devops dependabot.yml as housekeeping. Alpine version bumps continue to happen as deliberate edits to the `ARG ALPINE_VERSION=` line on the relevant branch.

## Phased plan

| Phase | Work | Effort |
|---|---|---|
| 1a. Foundation on master | **✅ Landed in openemr/openemr#12482.** Path layout resolved (use `docker/<thing>/` to match existing openemr core convention). Docker Hub credentials provisioned at the openemr org level. `docker-release-orchestrator.yml` skeleton committed -- inert until phase 1c wires `docker-build-release.yml` for it to dispatch. | ~1 day |
| 1b. Flex + binary migration | **✅ Landed in openemr/openemr#12482, 8 commits.** Ports of `docker/{flex,binary}/`, `tests/bats/docker/{flex,binary}/`, `utilities/container_benchmarking/`, `.github/actions/test-actions-core/`, all flex build workflows (`docker-build-{flex-core,322,323,edge}.yml`), test workflows (`docker-test-{core,flex-322,flex-323,flex-edge,bats,container-functionality}.yml`), and `hadolint.yml` → `docker-lint-hadolint.yml` (plus README badge URL). Five intentional deviations from pure lift-and-shift: (1) the 50 MB `demo_5_0_0_5.sql` is **fetched at build time** from `raw.githubusercontent.com` pinned to a devops commit SHA with SHA256 verification (see "Large asset handling" section below), (2) a typo fix in `docker/flex/openemr.sh` (`defauly` → `default` in a code comment), (3) a codespell-driven style nudge in `docker/binary/utilities/devtoolsLibrary.source` (`runN` → `run1, run2, run3, ...` ellipsis to match the rest of the docstring), (4) `ubuntu-22.04` → `ubuntu-24.04` in `docker-test-bats.yml` to match repo convention, and (5) 8.1.0 paths + jobs deliberately dropped from `docker-test-bats.yml` and `docker-test-container-functionality.yml` -- restored in phase 1c when `docker/release/` lands. | ~1 day |
| 1c. Master's release Dockerfile + orchestrator | **✅ Landed in openemr/openemr#12482.** Added `docker/release/`, `docker-build-release.yml`, `docker-test-release.yml`, `tests/bats/docker/release/` skeleton. Restored the `bats-release` and `functionality-release` jobs deferred in phase 1b. Externalized release config to `.github/release-targets.yml`. Centralized `openemr_version_ref` so `docker/release/Dockerfile` is byte-identical across branches. Added four verification checks: OCI labels (revision + version + created value-checks, title/source/url/licenses presence-checks), version.php-derived `IMAGE_VERSION`, post-push label verification, `docker-validate-release-targets.yml` workflow (schema + git-ref-resolves + docker_tag↔version.php alignment guards). Applied `runN`→ellipsis fix on master's `devtoolsLibrary.source`. Also forward-ported openemr-devops#798 (two-pass kcov wrapper that fixes the alpine-edge × PHP 8.5 healthcheck timeout flagged in openemr-devops#797). All CI green at merge time except codecov statistical entries on the ignore list. | ~1.5 days |
| 2. Per rel-branch migration | **🟡 Open for review as 3 PRs against the respective upstream rel branches:** openemr/openemr#12495 (rel-810, full port), openemr/openemr#12496 (rel-800, lighter port), openemr/openemr#12497 (rel-704, lighter port). Each PR is a lift-and-shift of the matching `docker/openemr/X.Y.Z/` from devops to `docker/release/` + byte-identical workflows from master (`docker-build-release.yml` / `docker-test-release.yml` / `docker-test-core.yml`) + `test-actions-core` composite + `docker/compose.yml`. rel-810 additionally carries BATS (from `tests/bats/8.1.0/`, with version-prefix stripping), `helpers.bash`, `utilities/container_benchmarking/`, and simplified `docker-test-bats.yml` + `docker-test-container-functionality.yml` (each single-job: release). rel-800 and rel-704 skip those, matching devops's current asymmetry. `runN`→ellipsis comment fix applied on rel-810 only (the only file that has it; rel-800 and rel-704's devtoolsLibrary doesn't). All three PRs use `--no-verify` on the commits (pre-commit hooks deliberately skipped on rel branches per request). Worktrees created without docker stacks (`openemr-cmd worktree add -b` without `--start`). After PRs merge, add the corresponding row to master's `release-targets.yml` to start dispatching nightly builds against the branch. | ~1 day rel-810 + ~0.5 day × 2 (rel-800, rel-704) = ~2 days |
| 1d / 2. Post-merge code review fixes | **🟡 Pushed to all four open PRs (#12482, #12495, #12496, #12497) -- in re-review.** Bundle responding to a fresh code review of the merged state. Items: (1) `production_coverage_openemr_version` fixed from stale `'7.0.5'` to `'release'` on master + rel-810 + rel-800 (rel-704 already had the fix from earlier Copilot review) -- the old value silently disabled kcov because no docker_dir matched `'7.0.5'` under openemr core's flatter layout; (2) `docker/README.md` added to the byte-identical FILES_ALL set in `docker-validate-byte-identical.yml`; (3) script-injection antipattern removed from three workflows -- `docker-release-orchestrator.yml` fan-out, `docker-test-container-functionality.yml`, `docker-build-flex-core.yml` Build tags -- all now use `env:` plumbing instead of `${{ }}` inside `run:`; (4) BATS deps pinned (`bats-core@v1.13.0`, `bats-support@v0.3.0`, `bats-assert@v2.2.4`); (5) action versions aligned -- `docker/build-push-action@v6`→`@v7` in `docker-build-release.yml`, `actions/checkout@v4`→`@v6` in the `test-actions-core` composite (byte-identical sync to all rel branches); (6) early-fail validation step added inside `collect-production-targets` that asserts the kcov coverage variant is one of the discovered docker_dirs -- structural guard against future (1)-class silent regressions; (7) byte-identical drift canary extended to fire on `rel-*` PRs (not just master); (8) `version.php` added to `docker-validate-release-targets.yml` `paths:` filter so master version bumps fire the row-vs-version-php alignment check. Reviewer's item 9 (hoist `docker-test-release.yml`'s per-branch `branches:` trigger into a thin shim that calls a byte-identical reusable core, so the validator can enforce body-identity on that file too) deferred to a follow-up -- nice-to-have refactor, not correctness.

A small additional path hygiene fix landed in the same window: `utilities/container_benchmarking/` rehomed to `docker/container_benchmarking/` on master + rel-810, eliminating the otherwise-empty top-level `utilities/` dir created during phase 1b (`container_benchmarking` is the only inhabitant on openemr core, and its contents are exclusively docker test/benchmarking infrastructure, so docker/ is the semantic home). rel-800 and rel-704 don't carry the dir. | ~0.5 day |
| 3. Release tag automation | Replace cross-repo `repository_dispatch openemr-tag` (core → devops) with the in-repo `on: push: tags:` trigger already present on each rel branch's `docker-build-release.yml`. Sort out the existing devops `build-release.yml` (release packaging / tarballs) -- distinct from the docker build workflow; needs migration to core under a non-colliding name like `package-release.yml`. | ~1 day |
| 4. Consumer auto-sync | Add an in-repo auto-PR step for digest pins in `docker/development-*` compose files after each push. | ~1 day |
| 5. Devops cleanup | Delete migrated docker paths, BATS dirs, workflows. Remove dead dependabot entries. Add README banner pointing at new locations. Keep `openemr-cmd/`, `kubernetes/`, `tests/bats/openemr-cmd/`, and their workflows. | ~0.5 day |

Total active engineering: **~1.5 weeks** assuming 4 active rel branches. Calendar window will be longer to coordinate with active release activity.

## Verification: how we know the right thing got built and pushed

Four complementary checks assert that the image baked from `openemr_version_ref` actually carries that source, and that `release-targets.yml` doesn't drift from the openemr source it points at.

1. **OCI labels on the published image.** `docker/release/Dockerfile` declares standard `org.opencontainers.image.*` labels populated from build-args:
   - `revision` = `${OPENEMR_VERSION}` -- the git ref baked
   - `version` = `${IMAGE_VERSION}` -- the human-facing release version, composed by the workflow from `version.php` at the resolved ref
   - `created` = `${BUILD_DATE}`
   - plus static `title`, `source`, `url`, `licenses`

   Any consumer can `docker inspect openemr/openemr:8.1.0` and see exactly which openemr ref went in.

2. **IMAGE_VERSION extraction from `version.php`.** A workflow step in `docker-build-release.yml` fetches `version.php` from `raw.githubusercontent.com` at the resolved `openemr_version_ref`, parses the five components (`$v_major`, `$v_minor`, `$v_patch`, `$v_tag`, `$v_realpatch`), composes the version string ("8.1.1-dev" for in-progress, "8.1.0" for GA, "8.1.0.1" for GA + patch), and passes it as `IMAGE_VERSION` to docker buildx. The source self-reports its version; the build pipeline doesn't have to guess.

3. **Post-push label verification** in `docker-build-release.yml`. After buildx push completes, the workflow pulls the first pushed tag back and asserts both `revision` and `version` labels match what was requested. Catches: Dockerfile drops the ARG declarations, build-arg path through buildx breaks, someone hand-edits the Dockerfile to hardcode something. Build fails loudly with `::error::` if either label doesn't match.

4. **PR-time validation of `release-targets.yml`** (`docker-validate-release-targets.yml`). Runs only on PRs touching the data file. Six guards:
   1. Valid YAML.
   2. Every row has all three required fields.
   3. No duplicate branches.
   4. No two rows pushing the same docker_tag.
   5. Every `openemr_version_ref` resolves to a real ref in openemr/openemr (catches typos like `rel-8100` or `v8_1_0_`).
   6. The first version-number `docker_tag` in each row aligns with the `major.minor.patch` composed from `version.php` at that row's `openemr_version_ref`. Catches the drift bug where master bumps `version.php` from `8.1.1-dev` to `8.1.2-dev` but `release-targets.yml` still says `docker_tags: 8.1.1,dev,next`.

5. **Byte-identical drift canary across rel branches** (`docker-validate-byte-identical.yml`). The orchestrator-driven pipeline depends on six files being character-for-character identical across master and every rel branch:

   * `.github/workflows/docker-build-release.yml`
   * `.github/workflows/docker-test-core.yml`
   * `.github/actions/test-actions-core/action.yml`
   * `docker/compose.yml`
   * `docker/.gitignore`
   * `docker/COVERAGE.md`

   If any drift, the orchestrator can dispatch the same logical build against two branches and silently get different behaviors. This workflow asserts the invariant via three triggers: PR on master gated to changes in any of those files (catches a PR that updates master without sync PRs to rel branches), daily cron at 07:00 UTC (catches latent drift via unrelated rel-branch PRs), and `workflow_dispatch` for ad-hoc investigation. Rel branches come from `release-targets.yml` at runtime, so adding a new rel branch automatically extends the check. Files that are intentionally non-identical (`docker/release/Dockerfile`, `docker-test-release.yml`, `docker-test-bats.yml`, `docker-test-container-functionality.yml`) are deliberately excluded from the watched set.

Together: the five checks make every published image self-documenting, assert build-time alignment, assert config-time alignment, AND assert the cross-branch invariant. A release-management PR that bumps any of `version.php` / `release-targets.yml` / Dockerfile fails at PR time if the three drift apart; a PR that quietly forks one of the byte-identical files on a rel branch fails at the next daily canary run.

## Per rel-branch port: what each branch gets in phase 2

Not every rel branch has the same test coverage in devops today. Phase 2 mirrors that state -- branches without BATS dirs or container-functionality coverage in devops don't gain them during the migration. They still get `docker-test-release.yml`, which is the heavier integration test (builds the Dockerfile, starts the container, asserts healthcheck), so the production image path stays well-validated.

| File / Dir | master | rel-810 | rel-800 | rel-704 |
|---|:---:|:---:|:---:|:---:|
| `docker/release/Dockerfile` (version-pinned) | ✓ | ✓ | ✓ | ✓ |
| `docker/compose.yml` | ✓ | ✓ | ✓ | ✓ |
| `docker-build-release.yml` (byte-identical) | ✓ | ✓ | ✓ | ✓ |
| `docker-test-release.yml` (production Dockerfile test) | ✓ | ✓ | ✓ | ✓ |
| `docker-test-core.yml` (reusable) | ✓ | ✓ | ✓ | ✓ |
| `.github/actions/test-actions-core/` | ✓ | ✓ | ✓ | ✓ |
| `tests/bats/docker/release/` | ✓ (from devops 8.1.1) | ✓ (from devops 8.1.0) | ✗ | ✗ |
| `tests/bats/docker/helpers.bash` | ✓ | ✓ | ✗ | ✗ |
| `docker-test-bats.yml` | ✓ (3 jobs: release+binary+flex) | ✓ (1 job: release) | ✗ | ✗ |
| `docker-test-container-functionality.yml` | ✓ (3 jobs) | ✓ (1 job: release) | ✗ | ✗ |
| `docker/container_benchmarking/` (initially landed under `utilities/container_benchmarking/`; rehomed to `docker/` in row 1d/2 below since it's exclusively docker test/benchmarking infrastructure) | ✓ | ✓ | ✗ | ✗ |
| `docker/flex/`, `docker/binary/` + their BATS dirs | ✓ | ✗ | ✗ | ✗ |
| All flex/binary build + test workflows | ✓ | ✗ | ✗ | ✗ |
| `docker-release-orchestrator.yml` + `release-targets.yml` | ✓ | ✗ | ✗ | ✗ |
| `docker-validate-release-targets.yml` | ✓ | ✗ | ✗ | ✗ |

rel-800 and rel-704 explicitly do NOT get BATS or container-functionality testing -- in devops today there are no `tests/bats/8.0.0/` or `tests/bats/7.0.4/` dirs, and `test-container-functionality.yml` only targets 8.1.0 + binary + flex. The migration preserves that asymmetry rather than expanding test coverage for older releases as a side effect (those would be separate enhancements).

## Branch-cut process under the final model

**2 steps** when cutting a new `rel-X.Y.Z`:

1. Cut `rel-X.Y.Z` from master
2. Append one row to master's `.github/release-targets.yml` with the new branch's `docker_tags` and `openemr_version_ref`

`docker-build-release.yml`, `docker-test-release.yml`, `docker-test-bats.yml`, `docker/release/Dockerfile`, BATS contents, dependabot, hadolint paths, lint configs -- **none** change at branch-cut. The Dockerfile is byte-identical because the openemr source ref is passed in as a build-arg, not baked into the file.

Tag-rotation, release promotion, and post-release patch handling are all one-line edits in `release-targets.yml`:

- **Rotate `latest`** (e.g. 8.1.0 graduates to GA → 8.1.0 takes `latest` from 8.0.0): edit two rows' `docker_tags`. No PR against any rel branch.
- **Promote rel-810 to v8_1_0 release**: edit that row's `openemr_version_ref` from `rel-810` to `v8_1_0`. Subsequent patches to rel-810 don't affect the published image until you bump again.
- **Post-release patch flow** (cut `v8_1_0_1` from rel-810): edit that row's `openemr_version_ref` from `v8_1_0` to `v8_1_0_1`.

## Large asset handling pattern (established in phase 1b)

`docker/openemr/flex/utilities/demo_5_0_0_5.sql` is a 50 MB SQL dump used by the flex container's `dev-reset-install-demodata` flow. Committing 50 MB to openemr core would permanently bloat every contributor's clone for a single-use seed asset, so phase 1b established this pattern instead and the same pattern applies to any large asset encountered in later phases:

1. **Don't carry the asset in git.** Skip the file entirely during the dir port.
2. **Fetch at Dockerfile build time** from `raw.githubusercontent.com` pinned to a specific commit SHA in the source repo (devops, in this case). SHAs never change and stay valid even after the source path is later cleaned up in phase 5.
3. **Verify with SHA256** to detect mid-flight corruption, URL drift, or a wrong-SHA bump.

The Dockerfile pattern that landed in `docker/flex/Dockerfile`:

```dockerfile
ARG DEMO_SQL_REPO_SHA=441d7b3db5b8033822e0e3da462e7553a2330477
ARG DEMO_SQL_SHA256=5d418c838446f3bdd4aa17d1276578106928a3ebcb27b40f4ab421694cc013d7
RUN wget -O /root/demo_5_0_0_5.sql \
    "https://raw.githubusercontent.com/openemr/openemr-devops/${DEMO_SQL_REPO_SHA}/docker/openemr/flex/utilities/demo_5_0_0_5.sql" \
    && echo "${DEMO_SQL_SHA256}  /root/demo_5_0_0_5.sql" | sha256sum -c -
```

Bumping the demo data becomes a two-ARG change (pin a new SHA, update the checksum) rather than a 50 MB binary recommit. raw.githubusercontent.com serves files up to 100 MB; 50 MB is well within bounds. Build-time network is acceptable since the docker build already requires internet for apk packages anyway.

When phase 5 cleans up `docker/openemr/flex/` from devops master, the SHA-pinned URL still works (raw.githubusercontent.com serves any commit by SHA, regardless of whether the path exists at HEAD).

## Decisions to lock before phase 1

1. **Docker Hub credential scope.** Org-level secrets are preferred so both repos can push during the cutover. If repo-level only, plan a "freeze devops, flip secrets, enable core" window.
2. **Path naming for the release Dockerfile.** **Resolved during phase 1a.** Use `docker/release/`, `docker/flex/`, `docker/binary/` to match openemr core's existing `docker/<purpose>/` convention (see `docker/production/`, `docker/development-easy/`, `docker/library/`). The existing `docker/production/docker-compose.yml` is a compose recipe for running the production image locally (a different concern than `docker/release/` which holds the Dockerfile that builds it) -- they coexist cleanly. No rename needed.
3. **Nightly cadence per release branch.** Today devops rebuilds 7.0.4, 8.0.0, 8.1.0, 8.1.1 every night. Worth questioning whether older releases need daily Alpine base-image refreshes -- weekly or only-on-bumps may be enough. Affects the orchestrator fan-out list, not the design.
4. **Binary helper location.** Keep in `openemr` master next to flex, leave in devops, or carve into its own repo? Doesn't affect the model.

## What stays in `openemr-devops`

- `utilities/openemr-cmd/`
- `kubernetes/` manifests
- `tests/bats/openemr-cmd/`
- `.github/workflows/test-bats-openemr-cmd.yml`
- `.github/workflows/test-kubernetes.yml`
- `.github/workflows/dependabot-auto-merge.yml` (and the dependabot.yml entries that drive it for kubernetes)

## Risks and wrinkles to plan for

- **Multi-arch (amd64+arm64).** Current `build-811.yml` does a digest-merge step. The per-rel `docker-build-release.yml` must preserve this -- easy to miss if copied from a single-arch template.
- **Branch protection on rel-X.Y.Z.** Confirm dispatching workflows can write to their own branch's tags / have the right `permissions:` block.
- **Cross-repo docs.** Wiki and third-party guides referencing `openemr-devops/docker/...` paths will need updating. Sunset banner in the devops README should buy 1-2 release cycles of overlap before we delete the old paths.

## Rollback

Reversible at any phase. Each devops `build-XXX.yml` can be restored from git history if a per-branch migration goes wrong. Docker Hub registry names don't change at any point, so consumers (kubernetes manifests, development-* compose files, third-party docs) keep working throughout the transition.

## Feedback wanted

- Thoughts on path naming (item 2 above)?
- Org-level vs repo-level Docker Hub secrets (item 1)?
- Anything missing from the inventory of what moves?
