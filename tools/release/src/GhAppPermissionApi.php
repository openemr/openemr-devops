<?php

/**
 * gh-CLI implementation of AppPermissionApi. Authenticates via the ambient
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

final readonly class GhAppPermissionApi implements AppPermissionApi
{
    public function installationRepositories(): array
    {
        $process = new Process([
            'gh', 'api', '/installation/repositories',
            '--paginate', '--jq', '.repositories[].full_name',
        ]);
        $process->mustRun();

        $output = trim($process->getOutput());
        if ($output === '') {
            return [];
        }
        return explode("\n", $output);
    }

    public function repositoryFullName(string $owner, string $repoName): string
    {
        return $this->scalar(["/repos/{$owner}/{$repoName}"], '.full_name');
    }

    public function defaultBranch(string $owner, string $repoName): string
    {
        return $this->scalar(["/repos/{$owner}/{$repoName}"], '.default_branch');
    }

    public function branchHeadSha(string $owner, string $repoName, string $branch): string
    {
        return $this->scalar(
            ["/repos/{$owner}/{$repoName}/git/ref/heads/{$branch}"],
            '.object.sha',
        );
    }

    public function createBranch(string $owner, string $repoName, string $branch, string $sha): void
    {
        $process = new Process([
            'gh', 'api', '-X', 'POST', "/repos/{$owner}/{$repoName}/git/refs",
            '-f', "ref=refs/heads/{$branch}",
            '-f', "sha={$sha}",
        ]);
        $process->mustRun();
    }

    public function putFile(
        string $owner,
        string $repoName,
        string $path,
        string $content,
        string $message,
        string $branch,
    ): void {
        $process = new Process([
            'gh', 'api', '-X', 'PUT', "/repos/{$owner}/{$repoName}/contents/{$path}",
            '-f', "message={$message}",
            '-f', 'content=' . base64_encode($content),
            '-f', "branch={$branch}",
        ]);
        $process->mustRun();
    }

    public function openDraftPullRequest(
        string $owner,
        string $repoName,
        string $title,
        string $body,
        string $head,
        string $base,
    ): int {
        $number = $this->scalar([
            '-X', 'POST', "/repos/{$owner}/{$repoName}/pulls",
            '-f', "title={$title}",
            '-f', "body={$body}",
            '-f', "head={$head}",
            '-f', "base={$base}",
            '-F', 'draft=true',
        ], '.number');

        if (preg_match('/^\d+$/', $number) !== 1) {
            throw new \RuntimeException("Unexpected PR number from gh api: '{$number}'");
        }
        return (int) $number;
    }

    public function closePullRequest(string $owner, string $repoName, int $number): void
    {
        $process = new Process([
            'gh', 'api', '-X', 'PATCH', "/repos/{$owner}/{$repoName}/pulls/{$number}",
            '-f', 'state=closed',
        ]);
        $process->mustRun();
    }

    public function deleteBranch(string $owner, string $repoName, string $branch): void
    {
        $process = new Process([
            'gh', 'api', '-X', 'DELETE', "/repos/{$owner}/{$repoName}/git/refs/heads/{$branch}",
        ]);
        $process->mustRun();
    }

    /**
     * Run `gh api <args> --jq <filter>` and return the trimmed scalar output.
     *
     * @param list<string> $args
     */
    private function scalar(array $args, string $jq): string
    {
        $process = new Process(['gh', 'api', ...$args, '--jq', $jq]);
        $process->mustRun();
        return trim($process->getOutput());
    }
}
