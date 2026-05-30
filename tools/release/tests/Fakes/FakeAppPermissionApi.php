<?php

/**
 * In-memory AppPermissionApi for probe tests.
 *
 * Each method can be told to throw \RuntimeException (via failOn) to simulate
 * the corresponding permission being absent, so the probe's translation of a
 * failure into a named missing permission can be asserted without a live repo.
 *
 * @package   openemr-devops
 * @link      https://www.open-emr.org
 * @author    Michael A. Smith <michael@opencoreemr.com>
 * @copyright Copyright (c) 2026 OpenCoreEMR Inc.
 * @license   https://github.com/openemr/openemr-devops/blob/master/LICENSE GNU General Public License 3
 */

declare(strict_types=1);

namespace OpenEMR\Release\Tests\Fakes;

use OpenEMR\Release\AppPermissionApi;

class FakeAppPermissionApi implements AppPermissionApi
{
    /** @var list<string> */
    public array $installationRepositories = [];

    public string $defaultBranch = 'main';

    public int $pullRequestNumber = 42;

    /** @var list<string> branch+path pairs ("branch path") put so far */
    public array $putFiles = [];

    public bool $closedPullRequest = false;

    public bool $deletedBranch = false;

    /** @var array<string, bool> op name → whether the next call should throw */
    private array $failOn = [];

    public function failOn(string $op): void
    {
        $this->failOn[$op] = true;
    }

    public function installationRepositories(): array
    {
        $this->guard('installationRepositories');
        return $this->installationRepositories;
    }

    public function repositoryFullName(string $owner, string $repoName): string
    {
        $this->guard('repositoryFullName');
        return "{$owner}/{$repoName}";
    }

    public function defaultBranch(string $owner, string $repoName): string
    {
        $this->guard('defaultBranch');
        return $this->defaultBranch;
    }

    public function branchHeadSha(string $owner, string $repoName, string $branch): string
    {
        $this->guard('branchHeadSha');
        return 'base-sha';
    }

    public function createBranch(string $owner, string $repoName, string $branch, string $sha): void
    {
        $this->guard('createBranch');
    }

    public function putFile(
        string $owner,
        string $repoName,
        string $path,
        string $content,
        string $message,
        string $branch,
    ): void {
        // Distinguish the plain-dotfile commit from the workflow-file commit so a
        // test can fail only the .github/workflows/ write (the workflows:write gap).
        if (str_starts_with($path, '.github/workflows/')) {
            $this->guard('putWorkflowFile');
        } else {
            $this->guard('putFile');
        }
        $this->putFiles[] = "{$branch} {$path}";
    }

    public function openDraftPullRequest(
        string $owner,
        string $repoName,
        string $title,
        string $body,
        string $head,
        string $base,
    ): int {
        $this->guard('openDraftPullRequest');
        return $this->pullRequestNumber;
    }

    public function closePullRequest(string $owner, string $repoName, int $number): void
    {
        $this->guard('closePullRequest');
        $this->closedPullRequest = true;
    }

    public function deleteBranch(string $owner, string $repoName, string $branch): void
    {
        $this->guard('deleteBranch');
        $this->deletedBranch = true;
    }

    private function guard(string $op): void
    {
        if ($this->failOn[$op] ?? false) {
            throw new \RuntimeException("simulated {$op} failure");
        }
    }
}
