# `tools/release/`

PHP foundation for OpenEMR's release tooling. Used by the workflows in
`.github/workflows/release-*.yml` and `ship-release.yml`, plus called locally
during release prep.

## Layout

```
tools/release/
├── bin/         CLI entrypoints (one Symfony Console SingleCommandApplication per file)
├── src/         Service classes + value objects (PSR-4: OpenEMR\Release\)
├── tests/       PHPUnit tests + in-memory fakes (PSR-4: OpenEMR\Release\Tests\)
├── contracts/   JSON schemas vendored across consumer repos
├── scripts/     Operational shell probes (App-token sanity checks etc.)
├── templates/   PR body / changelog Twig templates
├── Taskfile.yml Glue between workflows and the PHP CLIs (`task release:*`)
└── versions.yml The 3-slot rotation registry (current/next/dev)
```

Workflow steps in `.github/workflows/` are deliberately thin: mint App token,
checkout, run `task release:<name>`. All decision logic lives in PHP so it can
be unit-tested.

## Conventions

- **PHP 8.5**, `declare(strict_types=1)`, **PHPStan level 10 + strict-rules**, PSR12, license-header docblock on every file.
- **Service classes** are `final readonly class` with constructor-promoted DI. They shell out via `Symfony\Component\Process\Process::mustRun()` and throw `\RuntimeException` on failure.
- **Result objects** are `final readonly class` value objects exposing public promoted properties + a small predicate (`isValid()`, `isReady()`, `wasSuccessful()`). Methods return result objects rather than associative arrays so the call site is type-safe and tests can assert on shape.
- **gh as the network layer.** Network calls go through the `gh` CLI, which uses the ambient `GH_TOKEN` env var. Workflows mint a release App token via `actions/create-github-app-token@v1` and export it as `GH_TOKEN`. CLI authors don't handle auth themselves.
- **Pure helpers stay static.** Methods that don't need shell or network (string builders, predicate logic, JSON shape interpretation) are kept `static` so unit tests can exercise them directly.
- **Tests** live in `tests/` mirroring `src/` flat. HTTP-dependent classes are not unit-tested — pure helpers and orchestrators (with fake collaborators) are. See `tests/Fakes/` for the in-memory test doubles.

## Why are some of these classes so verbose?

A "wrap `gh` and merge a few PRs" service can read as ~600 lines of PHP before any meaningful logic shows up. That's not accidental:

- Every file pays a ~13-line tax for the license-header docblock + `declare(strict_types=1)` + namespace + class declaration.
- Each gh response gets a typed PHPDoc shape (`array{...}`) so PHPStan level 10 can verify field access. That's 5–15 lines per response shape, not per call.
- We use one **value object per result** (`PullRequestSnapshot`, `PullRequestReadiness`, `ShipReleaseStepResult`, etc.) instead of returning arrays. Roughly 30 lines per object — the price of keeping the type system honest at every layer boundary.
- Service classes that touch `gh` get an **interface + concrete impl + in-memory fake** (`PullRequestApi` / `GhPullRequestApi` / `FakePullRequestApi`). The interface seam roughly doubles the API-facing line count but is what makes the orchestrator unit-testable without a real GitHub.
- Defensive logic (preflight, ordering enforcement, downstream-wait, status retraction, base validation, exception handling per step) accumulates over review iterations. Each piece is small and justified individually; together they dominate the orchestrator file.

The smaller alternatives:
- A bash script invoking `gh pr view --json … | jq` would be ~200 lines, ship the happy path, and be brittle on every edge case the orchestrator now defends against. No tests.
- A single PHP file with no value objects, no interface, no fakes would land near 350 lines but cap at "trust live runs to verify."

The current shape is the cost of **PHPStan level 10 + strict tests + structured failure reporting**. Worth knowing before adding the next CLI.

## Adding a new CLI

1. Add `src/<Service>.php` (`final readonly class`, ctor-promoted DI). If it touches the network, define an interface and a concrete `Gh*` impl so tests can substitute a fake.
2. Add `src/<Service>Result.php` if it returns more than a primitive.
3. Add `bin/<command>.php` (Symfony Console `SingleCommandApplication`). Keep all logic in the service class; the bin file is just option parsing + result rendering.
4. Add a `release:<command>` entry in `Taskfile.yml` with `requires.vars` and `{{shellQuote .VAR}}` for every parameter.
5. Add tests in `tests/` — pure helpers tested directly, services tested via fake collaborators.
6. Add a workflow step that mints the App token and runs `task release:<command>`.
7. After merge, append the corresponding `Bash(task -d ~/dev/oce/...)` permission to `~/.claude/settings.json` (alphabetical).

## Running checks locally

```sh
composer test            # PHPUnit
composer phpstan         # level 10 + strict-rules
composer phpcs           # PSR12 + line-length
composer rector-check    # dry-run modernization checks
composer require-checker # composer.json declares every used symbol
composer check           # all five
composer fix             # phpcbf + rector-fix
```
