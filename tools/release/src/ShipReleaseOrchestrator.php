<?php

/**
 * Merges the three release PRs (infra → conductor → docs) in strict order.
 *
 * Two-phase: a preflight pass evaluates every unmerged target's readiness and
 * refuses to merge anything if any unmerged PR is not ready (issue #705 step
 * 3 + 5: "no partial merges from the workflow itself"). PRs already merged
 * are skipped so the same trigger handles partial-merge recovery from outside
 * causes (e.g. an admin-overridden direct merge).
 *
 * Detects the one unrecoverable case — docs merged before conductor — and
 * refuses to do anything; that recovery is documented in the runbook.
 *
 * @package   openemr-devops
 * @link      https://www.open-emr.org
 * @author    Michael A. Smith <michael@opencoreemr.com>
 * @copyright Copyright (c) 2026 OpenCoreEMR Inc.
 * @license   https://github.com/openemr/openemr-devops/blob/master/LICENSE GNU General Public License 3
 */

declare(strict_types=1);

namespace OpenEMR\Release;

final readonly class ShipReleaseOrchestrator
{
    public const STATUS_CONTEXT = 'release/ship-approved';
    public const STATUS_DESCRIPTION = 'Approved by ship-release workflow';
    private const POLL_INTERVAL_SECONDS = 15;

    public function __construct(
        private PullRequestApi $api,
        private Clock $clock,
        private int $downstreamTimeoutSeconds = 600,
        private bool $dryRun = false,
        private string $statusTargetUrl = '',
    ) {
    }

    /**
     * @param list<PullRequestTarget> $targets infra → conductor → docs (sorted by mergeOrder)
     */
    public function ship(array $targets): ShipReleaseResult
    {
        $snapshots = $this->snapshotAll($targets);

        $fatal = $this->detectDocsFirst($targets, $snapshots);
        if ($fatal !== null) {
            return new ShipReleaseResult($this->markAllNotReached($targets), $fatal);
        }

        // Preflight: evaluate every unmerged target before any merge so a later
        // blocker can't cause earlier ones to ship as a partial merge.
        $preflight = $this->preflight($targets, $snapshots);
        if ($preflight['hasBlocker']) {
            return new ShipReleaseResult($preflight['steps']);
        }

        if ($this->dryRun) {
            return new ShipReleaseResult($this->dryRunSteps($targets, $snapshots));
        }

        return new ShipReleaseResult($this->executeMerges($targets, $snapshots, $preflight['readiness']));
    }

    /**
     * @param list<PullRequestTarget> $targets
     * @return array<string, ?PullRequestSnapshot>
     */
    private function snapshotAll(array $targets): array
    {
        $out = [];
        foreach ($targets as $target) {
            $out[$target->roleLabel] = $this->api->findByHead($target->repo, $target->branch);
        }
        return $out;
    }

    /**
     * Probe every unmerged target's readiness. If any is missing or blocked,
     * return per-target step results with no merges performed.
     *
     * @param  list<PullRequestTarget>             $targets
     * @param  array<string, ?PullRequestSnapshot> $snapshots
     * @return array{
     *     hasBlocker: bool,
     *     steps: list<ShipReleaseStepResult>,
     *     readiness: array<string, PullRequestReadiness>,
     * }
     */
    private function preflight(array $targets, array $snapshots): array
    {
        $readiness = [];
        $blocked = [];
        foreach ($targets as $target) {
            $snapshot = $snapshots[$target->roleLabel] ?? null;
            if ($snapshot === null) {
                $blocked[$target->roleLabel] = ['no PR found for branch ' . $target->branch];
                continue;
            }
            if ($snapshot->isMerged()) {
                continue;
            }
            $check = $this->api->getReadiness($target->repo, $snapshot->number);
            $readiness[$target->roleLabel] = $check;
            if (!$check->isReady()) {
                $blocked[$target->roleLabel] = $check->blockingReasons;
            }
        }

        $steps = [];
        foreach ($targets as $target) {
            $snapshot = $snapshots[$target->roleLabel] ?? null;
            if ($snapshot !== null && $snapshot->isMerged()) {
                $steps[] = new ShipReleaseStepResult(
                    $target,
                    ShipReleaseStepStatus::SKIPPED_ALREADY_MERGED,
                    $snapshot->number,
                    null,
                    [],
                );
                continue;
            }
            if (isset($blocked[$target->roleLabel])) {
                $steps[] = new ShipReleaseStepResult(
                    $target,
                    ShipReleaseStepStatus::BLOCKED,
                    $snapshot?->number,
                    null,
                    $blocked[$target->roleLabel],
                );
                continue;
            }
            // Ready, but preflight failed elsewhere — we won't merge it now.
            if ($blocked !== []) {
                $steps[] = new ShipReleaseStepResult(
                    $target,
                    ShipReleaseStepStatus::NOT_REACHED,
                    $snapshot?->number,
                    null,
                    ['preflight blocker on another PR — no merges performed'],
                );
            }
        }

        return ['hasBlocker' => $blocked !== [], 'steps' => $steps, 'readiness' => $readiness];
    }

    /**
     * Build the dry-run report — preflight already passed, so each unmerged
     * target is "would merge" and merged ones stay "skipped".
     *
     * @param  list<PullRequestTarget>             $targets
     * @param  array<string, ?PullRequestSnapshot> $snapshots
     * @return list<ShipReleaseStepResult>
     */
    private function dryRunSteps(array $targets, array $snapshots): array
    {
        $steps = [];
        foreach ($targets as $target) {
            $snapshot = $snapshots[$target->roleLabel] ?? null;
            if ($snapshot !== null && $snapshot->isMerged()) {
                $steps[] = new ShipReleaseStepResult(
                    $target,
                    ShipReleaseStepStatus::SKIPPED_ALREADY_MERGED,
                    $snapshot->number,
                    null,
                    [],
                );
                continue;
            }
            $steps[] = new ShipReleaseStepResult(
                $target,
                ShipReleaseStepStatus::WOULD_MERGE,
                $snapshot?->number,
                null,
                [],
            );
        }
        return $steps;
    }

    /**
     * Real merge pass. Preflight has already validated that every unmerged
     * target was ready at snapshot time. The docs PR gets a fresh readiness
     * check after the conductor's downstream effect re-renders it.
     *
     * @param  list<PullRequestTarget>             $targets
     * @param  array<string, ?PullRequestSnapshot> $snapshots
     * @param  array<string, PullRequestReadiness> $readiness  preflight readiness, by role
     * @return list<ShipReleaseStepResult>
     */
    private function executeMerges(array $targets, array $snapshots, array $readiness): array
    {
        $steps = [];
        $stopReason = null;
        $mergedThisRun = [];

        foreach ($targets as $target) {
            if ($stopReason !== null) {
                $steps[] = $this->notReachedStep($target, $stopReason);
                continue;
            }

            $snapshot = $snapshots[$target->roleLabel] ?? null;
            // Preflight already filtered missing PRs.
            if ($snapshot === null) {
                $steps[] = $this->blockedStep($target, null, ['no PR found for branch ' . $target->branch]);
                $stopReason = sprintf('%s PR is missing', $target->roleLabel);
                continue;
            }
            if ($snapshot->isMerged()) {
                $steps[] = new ShipReleaseStepResult(
                    $target,
                    ShipReleaseStepStatus::SKIPPED_ALREADY_MERGED,
                    $snapshot->number,
                    null,
                    [],
                );
                continue;
            }

            // The conductor merge fires repository_dispatch handlers that re-render
            // the docs PR. Two cases need a fresh state read before merging docs:
            //   - conductor merged in *this* run: poll until head SHA flips (or
            //     time out), then re-check readiness against the new SHA.
            //   - conductor was already merged when we started (recovery case):
            //     re-check readiness right now in case the previous run's
            //     downstream re-render is still in flight. Don't poll — if the
            //     PR isn't ready, fail fast and the operator re-runs.
            $stepReadiness = $readiness[$target->roleLabel] ?? null;
            if ($target->roleLabel === 'docs') {
                $refresh = $this->refreshDocsBeforeMerge($target, $snapshot, $snapshots, $mergedThisRun);
                if ($refresh !== null) {
                    [$refreshedSnapshot, $refreshedReadiness, $refreshStopReason, $blockingReasons] = $refresh;
                    if ($refreshStopReason !== null) {
                        $steps[] = $this->blockedStep($target, $refreshedSnapshot?->number, $blockingReasons);
                        $stopReason = $refreshStopReason;
                        continue;
                    }
                    // refresh succeeded — both fields are guaranteed non-null
                    if (!$refreshedSnapshot instanceof PullRequestSnapshot || $refreshedReadiness === null) {
                        throw new \LogicException('refreshDocsBeforeMerge returned inconsistent tuple');
                    }
                    $snapshot = $refreshedSnapshot;
                    $stepReadiness = $refreshedReadiness;
                }
            }

            if ($stepReadiness === null) {
                throw new \LogicException(
                    "ship-release: missing preflight readiness for {$target->roleLabel}",
                );
            }

            $this->api->postCommitStatus(
                $target->repo,
                $stepReadiness->headRefOid,
                self::STATUS_CONTEXT,
                'success',
                self::STATUS_DESCRIPTION,
                $this->statusTargetUrl,
            );
            $mergeSha = $this->api->squashMerge($target->repo, $snapshot->number, $stepReadiness->headRefOid);
            $steps[] = new ShipReleaseStepResult(
                $target,
                ShipReleaseStepStatus::MERGED,
                $snapshot->number,
                $mergeSha,
                [],
            );
            $mergedThisRun[] = $target->roleLabel;
        }

        return $steps;
    }

    /**
     * @param list<PullRequestTarget>             $targets
     * @param array<string, ?PullRequestSnapshot> $snapshots
     */
    private function detectDocsFirst(array $targets, array $snapshots): ?string
    {
        $docs = $snapshots['docs'] ?? null;
        $conductor = $snapshots['conductor'] ?? null;
        if ($docs === null || !$docs->isMerged()) {
            return null;
        }
        if ($conductor !== null && $conductor->isMerged()) {
            return null;
        }
        $conductorTarget = $this->findRequired($targets, 'conductor');
        $docsTarget = $this->findRequired($targets, 'docs');
        return sprintf(
            'docs PR (%s#%d, branch %s) was merged before conductor PR (%s, branch %s).'
            . ' This is the unrecoverable docs-first case from issue #705 — the docs page'
            . ' shipped FINAL with no tag. See the release runbook for manual reconciliation.',
            $docsTarget->repo,
            $docs->number,
            $docsTarget->branch,
            $conductorTarget->repo,
            $conductorTarget->branch,
        );
    }

    /**
     * @param list<PullRequestTarget> $targets
     */
    private function findRequired(array $targets, string $role): PullRequestTarget
    {
        foreach ($targets as $target) {
            if ($target->roleLabel === $role) {
                return $target;
            }
        }
        throw new \LogicException("ship-release targets list is missing role: {$role}");
    }

    /**
     * Two cases need a fresh state read before merging docs:
     *   - conductor merged in *this* run: poll until head SHA flips (or time
     *     out), then re-check readiness against the new SHA.
     *   - conductor was already merged when we started (recovery case): re-check
     *     readiness right now in case the previous run's downstream re-render
     *     is still in flight. Don't poll — if not ready, fail fast and the
     *     operator re-runs.
     *
     * Returns null when no refresh is needed. Otherwise returns a tuple
     * [snapshot, readiness, stopReason, blockingReasons]:
     *   - on success, snapshot + readiness are non-null and stopReason is null
     *   - on failure, stopReason is non-null and blockingReasons populated;
     *     snapshot may be null if the PR has disappeared
     *
     * @param  array<string, ?PullRequestSnapshot> $snapshots
     * @param  list<string>                        $mergedThisRun
     * @return array{0: ?PullRequestSnapshot, 1: ?PullRequestReadiness, 2: ?string, 3: list<string>}|null
     */
    private function refreshDocsBeforeMerge(
        PullRequestTarget $target,
        PullRequestSnapshot $current,
        array $snapshots,
        array $mergedThisRun,
    ): ?array {
        $conductorJustMerged = in_array('conductor', $mergedThisRun, true);
        $conductorPreviouslyMerged = ($snapshots['conductor'] ?? null)?->isMerged() ?? false;
        if (!$conductorJustMerged && !$conductorPreviouslyMerged) {
            return null;
        }
        $fresh = $conductorJustMerged
            ? $this->awaitDownstreamUpdate($target, $current)
            : $this->api->findByHead($target->repo, $target->branch);
        if (!$fresh instanceof PullRequestSnapshot) {
            return [null, null, 'docs PR disappeared before merge', ['docs PR disappeared before merge']];
        }
        $readiness = $this->api->getReadiness($target->repo, $fresh->number);
        if (!$readiness->isReady()) {
            $stopReason = $conductorJustMerged
                ? 'docs PR not ready after conductor downstream update'
                : 'docs PR not ready (re-checked after conductor was already merged)';
            return [$fresh, null, $stopReason, $readiness->blockingReasons];
        }
        return [$fresh, $readiness, null, []];
    }

    /**
     * Poll until the docs PR head SHA differs from the snapshot taken before
     * the conductor merge, or until the timeout elapses. Either way, return a
     * fresh snapshot — readiness is re-checked after this.
     */
    private function awaitDownstreamUpdate(
        PullRequestTarget $target,
        PullRequestSnapshot $before,
    ): ?PullRequestSnapshot {
        $deadline = $this->clock->now()->getTimestamp() + $this->downstreamTimeoutSeconds;
        $current = $before;
        while ($this->clock->now()->getTimestamp() < $deadline) {
            $current = $this->api->findByHead($target->repo, $target->branch);
            if (!$current instanceof PullRequestSnapshot) {
                return null;
            }
            if ($current->headRefOid !== $before->headRefOid) {
                return $current;
            }
            $this->clock->sleep(self::POLL_INTERVAL_SECONDS);
        }
        return $current;
    }

    /**
     * @param  list<PullRequestTarget> $targets
     * @return list<ShipReleaseStepResult>
     */
    private function markAllNotReached(array $targets): array
    {
        $out = [];
        foreach ($targets as $target) {
            $out[] = $this->notReachedStep($target, 'fatal precondition');
        }
        return $out;
    }

    private function notReachedStep(PullRequestTarget $target, string $reason): ShipReleaseStepResult
    {
        return new ShipReleaseStepResult(
            $target,
            ShipReleaseStepStatus::NOT_REACHED,
            null,
            null,
            [$reason],
        );
    }

    /**
     * @param list<string> $reasons
     */
    private function blockedStep(PullRequestTarget $target, ?int $number, array $reasons): ShipReleaseStepResult
    {
        return new ShipReleaseStepResult(
            $target,
            ShipReleaseStepStatus::BLOCKED,
            $number,
            null,
            $reasons,
        );
    }
}
