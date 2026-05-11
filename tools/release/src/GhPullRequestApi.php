<?php

/**
 * gh-CLI implementation of PullRequestApi. Authenticates via the ambient
 * GH_TOKEN env var (the workflow mints an App token and exports it).
 *
 * @package   openemr-devops
 * @link      https://www.open-emr.org
 * @author    Michael A. Smith <michael@opencoreemr.com>
 * @copyright Copyright (c) 2026 OpenCoreEMR Inc.
 * @license   https://github.com/openemr/openemr-devops/blob/master/LICENSE GNU General Public License 3
 */

declare(strict_types=1);

namespace OpenEMR\Release;

use Symfony\Component\Process\Process;

final readonly class GhPullRequestApi implements PullRequestApi
{
    public function findByHead(string $repo, string $branch): ?PullRequestSnapshot
    {
        $process = new Process([
            'gh', 'pr', 'list',
            '--repo', $repo,
            '--head', $branch,
            '--state', 'all',
            '--limit', '1',
            '--json', 'number,headRefOid,baseRefName,mergedAt',
        ]);
        $process->mustRun();

        /** @var list<array{number: int, headRefOid: string, baseRefName: string, mergedAt: ?string}> $rows */
        $rows = json_decode(trim($process->getOutput()), true) ?? [];
        if ($rows === []) {
            return null;
        }
        $row = $rows[0];
        $mergedAt = ($row['mergedAt'] ?? null) !== null && $row['mergedAt'] !== ''
            ? new \DateTimeImmutable($row['mergedAt'])
            : null;
        return new PullRequestSnapshot(
            $row['number'],
            $row['headRefOid'],
            $row['baseRefName'],
            $mergedAt,
        );
    }

    public function getReadiness(string $repo, int $number): PullRequestReadiness
    {
        $process = new Process([
            'gh', 'pr', 'view', (string) $number,
            '--repo', $repo,
            '--json', 'isDraft,mergeable,mergeStateStatus,reviewDecision,'
                . 'statusCheckRollup,latestReviews,headRefOid',
        ]);
        $process->mustRun();

        /**
         * @var array{
         *     isDraft: bool,
         *     mergeable: string,
         *     mergeStateStatus: string,
         *     reviewDecision: ?string,
         *     statusCheckRollup: list<array<string, mixed>>,
         *     latestReviews: list<array{state: string, author?: array{login?: string}}>,
         *     headRefOid: string,
         * } $data
         */
        $data = json_decode(trim($process->getOutput()), true);

        $reasons = [];
        if ($data['isDraft']) {
            $reasons[] = 'PR is a draft';
        }
        if ($data['mergeable'] !== 'MERGEABLE') {
            $reasons[] = sprintf('mergeable=%s (need MERGEABLE)', $data['mergeable']);
        }
        if ($data['mergeStateStatus'] !== 'CLEAN') {
            $reasons[] = sprintf('mergeStateStatus=%s (need CLEAN)', $data['mergeStateStatus']);
        }
        if (($data['reviewDecision'] ?? null) !== 'APPROVED') {
            $reasons[] = sprintf(
                'reviewDecision=%s (need APPROVED)',
                $data['reviewDecision'] ?? 'null',
            );
        }
        foreach ($data['latestReviews'] as $review) {
            if ($review['state'] === 'CHANGES_REQUESTED') {
                $reasons[] = sprintf(
                    'CHANGES_REQUESTED review by %s',
                    $review['author']['login'] ?? 'unknown',
                );
            }
        }
        foreach ($data['statusCheckRollup'] as $check) {
            $reasons = array_merge($reasons, $this->checkBlockingReason($check));
        }
        return new PullRequestReadiness($data['headRefOid'], $reasons);
    }

    public function postCommitStatus(
        string $repo,
        string $sha,
        string $context,
        string $state,
        string $description,
        string $targetUrl,
    ): void {
        $argv = [
            'gh', 'api',
            "repos/{$repo}/statuses/{$sha}",
            '--method', 'POST',
            '-f', "state={$state}",
            '-f', "context={$context}",
            '-f', "description={$description}",
        ];
        if ($targetUrl !== '') {
            $argv[] = '-f';
            $argv[] = "target_url={$targetUrl}";
        }
        $process = new Process($argv);
        $process->mustRun();
    }

    public function squashMerge(string $repo, int $number, string $expectedHeadSha): string
    {
        $merge = new Process([
            'gh', 'pr', 'merge', (string) $number,
            '--repo', $repo,
            '--squash',
            '--match-head-commit', $expectedHeadSha,
        ]);
        $merge->setTimeout(300.0);
        $merge->mustRun();

        $view = new Process([
            'gh', 'pr', 'view', (string) $number,
            '--repo', $repo,
            '--json', 'mergeCommit',
            '--jq', '.mergeCommit.oid // ""',
        ]);
        $view->mustRun();
        $sha = trim($view->getOutput());
        if ($sha === '') {
            throw new \RuntimeException(
                "Merge of {$repo}#{$number} reported success but mergeCommit is empty",
            );
        }
        return $sha;
    }

    /**
     * @param array<string, mixed> $check
     * @return list<string>
     */
    private function checkBlockingReason(array $check): array
    {
        $name = is_string($check['name'] ?? null) ? $check['name'] : 'unknown';
        $context = is_string($check['context'] ?? null) ? $check['context'] : $name;

        // Check runs use status/conclusion; legacy commit statuses use state.
        if (isset($check['conclusion'])) {
            $conclusion = is_string($check['conclusion']) ? $check['conclusion'] : '';
            $status = is_string($check['status'] ?? null) ? $check['status'] : '';
            if ($status !== 'COMPLETED') {
                return [sprintf('check %s status=%s (need COMPLETED)', $name, $status)];
            }
            if (!in_array($conclusion, ['SUCCESS', 'NEUTRAL', 'SKIPPED'], true)) {
                return [sprintf('check %s conclusion=%s', $name, $conclusion)];
            }
            return [];
        }
        if (isset($check['state'])) {
            $state = is_string($check['state']) ? $check['state'] : '';
            if (!in_array($state, ['SUCCESS', 'EXPECTED'], true)) {
                return [sprintf('status %s state=%s', $context, $state)];
            }
        }
        return [];
    }
}
