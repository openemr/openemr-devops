<?php

/**
 * Merges the three release PRs (infra → conductor → docs) in strict order.
 *
 * Skips PRs already merged so the same trigger handles partial-merge recovery.
 * Stops at the first non-ready PR without merging, so a half-finished release
 * never originates here. Detects the one unrecoverable case — docs merged
 * before conductor — and refuses to do anything; that recovery is documented
 * in the runbook (see issue #705).
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
            return new ShipReleaseResult(
                $this->markAllNotReached($targets),
                $fatal,
            );
        }

        $steps = [];
        $stopReason = null;
        $mergedThisRun = [];

        foreach ($targets as $target) {
            if ($stopReason !== null) {
                $steps[] = $this->notReachedStep($target, $stopReason);
                continue;
            }

            // The conductor's merge fires repository_dispatch handlers that
            // re-render the docs PR. Wait for that effect to land (or time
            // out), then re-snapshot before deciding readiness.
            if (
                $target->roleLabel === 'docs'
                && in_array('conductor', $mergedThisRun, true)
            ) {
                $snapshots[$target->roleLabel] = $this->awaitDownstreamUpdate(
                    $target,
                    $snapshots[$target->roleLabel] ?? null,
                );
            }

            $snapshot = $snapshots[$target->roleLabel] ?? null;
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

            $readiness = $this->api->getReadiness($target->repo, $snapshot->number);
            if (!$readiness->isReady()) {
                $steps[] = $this->blockedStep($target, $snapshot->number, $readiness->blockingReasons);
                $stopReason = sprintf('%s PR is not ready', $target->roleLabel);
                continue;
            }

            if ($this->dryRun) {
                $steps[] = new ShipReleaseStepResult(
                    $target,
                    ShipReleaseStepStatus::WOULD_MERGE,
                    $snapshot->number,
                    null,
                    [],
                );
                continue;
            }

            $this->api->postCommitStatus(
                $target->repo,
                $readiness->headRefOid,
                self::STATUS_CONTEXT,
                'success',
                self::STATUS_DESCRIPTION,
                $this->statusTargetUrl,
            );
            $mergeSha = $this->api->squashMerge(
                $target->repo,
                $snapshot->number,
                $readiness->headRefOid,
            );
            $steps[] = new ShipReleaseStepResult(
                $target,
                ShipReleaseStepStatus::MERGED,
                $snapshot->number,
                $mergeSha,
                [],
            );
            $mergedThisRun[] = $target->roleLabel;
        }

        return new ShipReleaseResult($steps);
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
     * Poll until the docs PR head SHA differs from the snapshot taken before
     * the conductor merge, or until the timeout elapses. Either way, return a
     * fresh snapshot — readiness is re-checked after this.
     */
    private function awaitDownstreamUpdate(
        PullRequestTarget $target,
        ?PullRequestSnapshot $before,
    ): ?PullRequestSnapshot {
        if (!$before instanceof \OpenEMR\Release\PullRequestSnapshot) {
            return null;
        }
        $deadline = $this->clock->now()->getTimestamp() + $this->downstreamTimeoutSeconds;
        $current = $before;
        while ($this->clock->now()->getTimestamp() < $deadline) {
            $current = $this->api->findByHead($target->repo, $target->branch);
            if (!$current instanceof \OpenEMR\Release\PullRequestSnapshot) {
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
     * @param list<PullRequestTarget> $targets
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
