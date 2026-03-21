<?php

/**
 * Wrapper around the gh CLI for GitHub API calls.
 *
 * @package   openemr
 * @link      https://www.open-emr.org
 * @author    Michael A. Smith <michael@opencoreemr.com>
 * @copyright Copyright (c) 2026 OpenCoreEMR Inc.
 * @license   https://github.com/openemr/openemr-devops/blob/master/LICENSE GNU General Public License 3
 */

declare(strict_types=1);

namespace OpenEMR\Release;

use Symfony\Component\Process\Process;

class GitHubApi
{
    public function __construct(
        private readonly string $repo = 'openemr/openemr',
    ) {
    }

    /**
     * Call a GitHub API endpoint via gh CLI and return decoded JSON.
     *
     * @return list<array<string, mixed>>
     */
    public function paginate(string $endpoint): array
    {
        $process = new Process([
            'gh', 'api', '--paginate', '--slurp',
            "/repos/{$this->repo}{$endpoint}",
        ]);
        $process->mustRun();

        $pages = json_decode($process->getOutput(), true);
        if (!is_array($pages)) {
            throw new \RuntimeException("Failed to parse JSON from gh api for {$endpoint}");
        }

        // --slurp wraps each page in an outer array: [[...page1...], [...page2...]]
        return array_merge(...$pages);
    }

    /**
     * Find a milestone number by its name.
     *
     * Search open milestones first, then closed.
     */
    public function findMilestone(string $name): int
    {
        foreach (['open', 'closed'] as $state) {
            $milestones = $this->paginate("/milestones?state={$state}&per_page=100");
            foreach ($milestones as $milestone) {
                if ($milestone['title'] === $name) {
                    return (int) $milestone['number'];
                }
            }
        }

        throw new \RuntimeException("Milestone not found: {$name}");
    }

    /**
     * Fetch all closed issues for a milestone.
     *
     * @return list<array<string, mixed>>
     */
    public function closedIssuesForMilestone(int $milestoneNumber): array
    {
        return $this->paginate("/issues?milestone={$milestoneNumber}&state=closed&per_page=100");
    }
}
