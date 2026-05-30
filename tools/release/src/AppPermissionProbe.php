<?php

/**
 * Exercises each permission the release App needs and reports the specific one
 * that is missing. Translates the low-level \RuntimeException raised by the
 * AppPermissionApi into the GitHub permission name a release manager can act on
 * (the same messages the previous shell probes emitted).
 *
 * @package   openemr-devops
 * @link      https://www.open-emr.org
 * @author    Michael A. Smith <michael@opencoreemr.com>
 * @copyright Copyright (c) 2026 OpenCoreEMR Inc.
 * @license   https://github.com/openemr/openemr-devops/blob/master/LICENSE GNU General Public License 3
 */

declare(strict_types=1);

namespace OpenEMR\Release;

final readonly class AppPermissionProbe
{
    public function __construct(
        private AppPermissionApi $api,
    ) {
    }

    /**
     * Dispatch by check name. The CLI validates the name before calling, so an
     * unknown name here is a programmer error and raises \UnhandledMatchError.
     */
    public function check(
        string $check,
        string $owner,
        string $repoName,
        string $branch,
        string $runId,
    ): AppPermissionResult {
        return match ($check) {
            'installation' => $this->checkInstallation($owner, $repoName),
            'metadata' => $this->checkMetadata($owner, $repoName),
            'contents-write' => $this->checkContentsWrite($owner, $repoName, $branch, $runId),
            'pull-requests-write' => $this->checkPullRequestsWrite($owner, $repoName, $branch, $runId),
            'cleanup' => $this->cleanup($owner, $repoName, $branch),
            default => throw new \InvalidArgumentException("unknown check: {$check}"),
        };
    }

    public function checkInstallation(string $owner, string $repoName): AppPermissionResult
    {
        $notInstalled = "release App is not installed on {$owner}/{$repoName}";
        try {
            $repos = $this->api->installationRepositories();
        } catch (\RuntimeException) {
            // A failed listing and an empty list mean the same thing to a
            // release manager: the App can't see this repo.
            return AppPermissionResult::failure($notInstalled);
        }

        if (!in_array("{$owner}/{$repoName}", $repos, true)) {
            return AppPermissionResult::failure($notInstalled);
        }
        return AppPermissionResult::ok("release App is installed on {$owner}/{$repoName}");
    }

    public function checkMetadata(string $owner, string $repoName): AppPermissionResult
    {
        try {
            $this->api->repositoryFullName($owner, $repoName);
        } catch (\RuntimeException) {
            return AppPermissionResult::failure("release App lacks metadata:read on {$owner}/{$repoName}");
        }
        return AppPermissionResult::ok("release App has metadata:read on {$owner}/{$repoName}");
    }

    public function checkContentsWrite(
        string $owner,
        string $repoName,
        string $branch,
        string $runId,
    ): AppPermissionResult {
        try {
            $defaultBranch = $this->api->defaultBranch($owner, $repoName);
            $baseSha = $this->api->branchHeadSha($owner, $repoName, $defaultBranch);
        } catch (\RuntimeException) {
            return AppPermissionResult::failure("release App lacks metadata:read on {$owner}/{$repoName}");
        }

        try {
            $this->api->createBranch($owner, $repoName, $branch, $baseSha);
        } catch (\RuntimeException) {
            return AppPermissionResult::failure('release App lacks contents:write (branch create failed)');
        }

        try {
            $this->api->putFile(
                $owner,
                $repoName,
                ".permissions-check-{$runId}",
                "permissions-check {$runId}\n",
                "permissions-check {$runId}",
                $branch,
            );
        } catch (\RuntimeException) {
            return AppPermissionResult::failure('release App lacks contents:write (commit failed)');
        }

        // Committing under .github/workflows/ additionally requires
        // workflows:write. Rotation rewrites build-{800,810,811}.yml, so this is
        // the gap that broke release-rotation.yml; a plain-dotfile probe misses
        // it. The stub is name-only with no `on:` trigger, so it never runs.
        try {
            $this->api->putFile(
                $owner,
                $repoName,
                ".github/workflows/permissions-check-{$runId}.yml",
                "name: permissions-check {$runId}\n",
                "permissions-check workflow {$runId}",
                $branch,
            );
        } catch (\RuntimeException) {
            return AppPermissionResult::failure('release App lacks workflows:write (workflow-file commit refused)');
        }

        return AppPermissionResult::ok('release App has contents:write and workflows:write');
    }

    public function checkPullRequestsWrite(
        string $owner,
        string $repoName,
        string $branch,
        string $runId,
    ): AppPermissionResult {
        try {
            $defaultBranch = $this->api->defaultBranch($owner, $repoName);
        } catch (\RuntimeException) {
            return AppPermissionResult::failure("release App lacks metadata:read on {$owner}/{$repoName}");
        }

        try {
            $number = $this->api->openDraftPullRequest(
                $owner,
                $repoName,
                "permissions-check {$runId}",
                "Probe run {$runId}; auto-closed by release-permissions-check workflow.",
                $branch,
                $defaultBranch,
            );
        } catch (\RuntimeException) {
            return AppPermissionResult::failure('release App lacks pull-requests:write (draft PR open failed)');
        }

        try {
            $this->api->closePullRequest($owner, $repoName, $number);
        } catch (\RuntimeException) {
            return AppPermissionResult::failure('release App can open but not close PRs');
        }

        return AppPermissionResult::ok('release App has pull-requests:write');
    }

    public function cleanup(string $owner, string $repoName, string $branch): AppPermissionResult
    {
        try {
            $this->api->deleteBranch($owner, $repoName, $branch);
        } catch (\RuntimeException) {
            // Best-effort: a leftover throwaway branch is harmless and the next
            // run uses a fresh run-id, so a failed delete must not fail the job.
        }
        return AppPermissionResult::ok("cleaned up {$branch}");
    }
}
