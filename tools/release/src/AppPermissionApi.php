<?php

/**
 * GitHub operations the release-App permission probe exercises. Kept narrow so
 * tests substitute a fake instead of standing up the gh CLI against a live repo.
 *
 * Implementations authenticate via the ambient GH_TOKEN (the workflow mints an
 * App token and exports it). Every method raises \RuntimeException when the
 * underlying call fails — the probe translates that into the specific missing
 * permission.
 *
 * @package   openemr-devops
 * @link      https://www.open-emr.org
 * @author    Michael A. Smith <michael@opencoreemr.com>
 * @copyright Copyright (c) 2026 OpenCoreEMR Inc.
 * @license   https://github.com/openemr/openemr-devops/blob/master/LICENSE GNU General Public License 3
 */

declare(strict_types=1);

namespace OpenEMR\Release;

interface AppPermissionApi
{
    /**
     * Every repository full_name (owner/name) the App's installation can reach.
     *
     * @return list<string>
     */
    public function installationRepositories(): array;

    /**
     * The repository's full_name (owner/name); proves metadata:read.
     */
    public function repositoryFullName(string $owner, string $repoName): string;

    /**
     * The repository's default branch name.
     */
    public function defaultBranch(string $owner, string $repoName): string;

    /**
     * The head commit SHA of a branch.
     */
    public function branchHeadSha(string $owner, string $repoName, string $branch): string;

    /**
     * Create a branch pointing at $sha; proves contents:write.
     */
    public function createBranch(string $owner, string $repoName, string $branch, string $sha): void;

    /**
     * Commit a file on a branch. Committing under .github/workflows/ additionally
     * requires workflows:write, which is the gap this probe surfaces.
     */
    public function putFile(
        string $owner,
        string $repoName,
        string $path,
        string $content,
        string $message,
        string $branch,
    ): void;

    /**
     * Open a draft PR and return its number; proves pull-requests:write.
     */
    public function openDraftPullRequest(
        string $owner,
        string $repoName,
        string $title,
        string $body,
        string $head,
        string $base,
    ): int;

    /**
     * Close a PR.
     */
    public function closePullRequest(string $owner, string $repoName, int $number): void;

    /**
     * Delete a branch. Best-effort cleanup; the probe ignores failures.
     */
    public function deleteBranch(string $owner, string $repoName, string $branch): void;
}
