<?php

/**
 * In-memory PullRequestApi for orchestrator tests.
 *
 * @package   openemr-devops
 * @link      https://www.open-emr.org
 * @author    Michael A. Smith <michael@opencoreemr.com>
 * @copyright Copyright (c) 2026 OpenCoreEMR Inc.
 * @license   https://github.com/openemr/openemr-devops/blob/master/LICENSE GNU General Public License 3
 */

declare(strict_types=1);

namespace OpenEMR\Release\Tests\Fakes;

use OpenEMR\Release\PullRequestApi;
use OpenEMR\Release\PullRequestReadiness;
use OpenEMR\Release\PullRequestSnapshot;

final class FakePullRequestApi implements PullRequestApi
{
    /** @var array<string, ?PullRequestSnapshot> */
    private array $snapshotsByKey = [];

    /** @var array<int, PullRequestReadiness> */
    private array $readinessByNumber = [];

    /** @var array<int, string> merge SHAs by PR number */
    private array $mergeShas = [];

    /** @var list<array{repo: string, sha: string, context: string, state: string}> */
    public array $postedStatuses = [];

    /** @var list<array{repo: string, number: int, expected: string}> */
    public array $merges = [];

    /** @var array<string, PullRequestSnapshot> snapshots installed by setSnapshotAfterFinds() */
    private array $snapshotAfterFind = [];

    /** @var array<string, int> */
    private array $findCalls = [];

    public function setSnapshot(string $repo, string $branch, ?PullRequestSnapshot $snapshot): void
    {
        $this->snapshotsByKey[$this->key($repo, $branch)] = $snapshot;
    }

    /**
     * After the Nth call to findByHead for this repo+branch, swap to a new snapshot.
     * Used to simulate the docs PR being re-rendered by the conductor merge.
     */
    public function setSnapshotAfterFinds(
        string $repo,
        string $branch,
        int $afterNCalls,
        PullRequestSnapshot $snapshot,
    ): void {
        $this->snapshotAfterFind[$this->key($repo, $branch) . '|' . $afterNCalls] = $snapshot;
    }

    public function setReadiness(int $number, PullRequestReadiness $readiness): void
    {
        $this->readinessByNumber[$number] = $readiness;
    }

    public function setMergeSha(int $number, string $sha): void
    {
        $this->mergeShas[$number] = $sha;
    }

    public function findByHead(string $repo, string $branch): ?PullRequestSnapshot
    {
        $key = $this->key($repo, $branch);
        $this->findCalls[$key] = ($this->findCalls[$key] ?? 0) + 1;
        $swap = $this->snapshotAfterFind[$key . '|' . $this->findCalls[$key]] ?? null;
        if ($swap !== null) {
            $this->snapshotsByKey[$key] = $swap;
        }
        return $this->snapshotsByKey[$key] ?? null;
    }

    public function getReadiness(string $repo, int $number): PullRequestReadiness
    {
        if (!isset($this->readinessByNumber[$number])) {
            throw new \RuntimeException("No readiness configured for PR #{$number}");
        }
        return $this->readinessByNumber[$number];
    }

    public function postCommitStatus(
        string $repo,
        string $sha,
        string $context,
        string $state,
        string $description,
        string $targetUrl,
    ): void {
        $this->postedStatuses[] = [
            'repo' => $repo,
            'sha' => $sha,
            'context' => $context,
            'state' => $state,
        ];
    }

    public function squashMerge(string $repo, int $number, string $expectedHeadSha): string
    {
        $this->merges[] = ['repo' => $repo, 'number' => $number, 'expected' => $expectedHeadSha];
        return $this->mergeShas[$number] ?? "merge-sha-{$number}";
    }

    private function key(string $repo, string $branch): string
    {
        return $repo . '|' . $branch;
    }
}
