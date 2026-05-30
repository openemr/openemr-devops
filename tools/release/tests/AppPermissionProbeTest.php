<?php

/**
 * @package   openemr-devops
 * @link      https://www.open-emr.org
 * @author    Michael A. Smith <michael@opencoreemr.com>
 * @copyright Copyright (c) 2026 OpenCoreEMR Inc.
 * @license   https://github.com/openemr/openemr-devops/blob/master/LICENSE GNU General Public License 3
 */

declare(strict_types=1);

namespace OpenEMR\Release\Tests;

use OpenEMR\Release\AppPermissionProbe;
use OpenEMR\Release\Tests\Fakes\FakeAppPermissionApi;
use PHPUnit\Framework\TestCase;

final class AppPermissionProbeTest extends TestCase
{
    private const OWNER = 'openemr';
    private const REPO = 'openemr-devops';
    private const BRANCH = 'release-permissions-check/123';
    private const RUN_ID = '123';

    private function probe(FakeAppPermissionApi $api): AppPermissionProbe
    {
        return new AppPermissionProbe($api);
    }

    /**
     * @return list<array{string}>
     *
     * @codeCoverageIgnore
     */
    public static function checkNameProvider(): array
    {
        return [
            ['installation'],
            ['metadata'],
            ['contents-write'],
            ['pull-requests-write'],
            ['cleanup'],
        ];
    }

    #[\PHPUnit\Framework\Attributes\DataProvider('checkNameProvider')]
    public function testCheckDispatchesEveryNameToAPassingResult(string $check): void
    {
        $api = new FakeAppPermissionApi();
        $api->installationRepositories = ['openemr/openemr-devops'];

        $result = $this->probe($api)->check($check, self::OWNER, self::REPO, self::BRANCH, self::RUN_ID);

        self::assertTrue($result->ok);
    }

    public function testCheckThrowsOnUnknownName(): void
    {
        $this->expectException(\InvalidArgumentException::class);

        $this->probe(new FakeAppPermissionApi())
            ->check('nope', self::OWNER, self::REPO, self::BRANCH, self::RUN_ID);
    }

    public function testInstallationPassesWhenRepoInList(): void
    {
        $api = new FakeAppPermissionApi();
        $api->installationRepositories = ['openemr/openemr', 'openemr/openemr-devops'];

        $result = $this->probe($api)->checkInstallation(self::OWNER, self::REPO);

        self::assertTrue($result->ok);
    }

    public function testInstallationFailsWhenRepoNotInList(): void
    {
        $api = new FakeAppPermissionApi();
        $api->installationRepositories = ['openemr/openemr'];

        $result = $this->probe($api)->checkInstallation(self::OWNER, self::REPO);

        self::assertFalse($result->ok);
        self::assertStringContainsString('not installed', $result->message);
    }

    public function testInstallationFailsWhenListingThrows(): void
    {
        $api = new FakeAppPermissionApi();
        $api->failOn('installationRepositories');

        $result = $this->probe($api)->checkInstallation(self::OWNER, self::REPO);

        self::assertFalse($result->ok);
        self::assertStringContainsString('not installed', $result->message);
    }

    public function testMetadataPasses(): void
    {
        $result = $this->probe(new FakeAppPermissionApi())->checkMetadata(self::OWNER, self::REPO);

        self::assertTrue($result->ok);
    }

    public function testMetadataFailsWhenReadThrows(): void
    {
        $api = new FakeAppPermissionApi();
        $api->failOn('repositoryFullName');

        $result = $this->probe($api)->checkMetadata(self::OWNER, self::REPO);

        self::assertFalse($result->ok);
        self::assertStringContainsString('metadata:read', $result->message);
    }

    public function testContentsWritePassesCommittingBothFiles(): void
    {
        $api = new FakeAppPermissionApi();

        $result = $this->probe($api)->checkContentsWrite(self::OWNER, self::REPO, self::BRANCH, self::RUN_ID);

        self::assertTrue($result->ok);
        self::assertSame([
            self::BRANCH . ' .permissions-check-' . self::RUN_ID,
            self::BRANCH . ' .github/workflows/permissions-check-' . self::RUN_ID . '.yml',
        ], $api->putFiles);
    }

    public function testContentsWriteFailsWhenBaseLookupThrows(): void
    {
        $api = new FakeAppPermissionApi();
        $api->failOn('defaultBranch');

        $result = $this->probe($api)->checkContentsWrite(self::OWNER, self::REPO, self::BRANCH, self::RUN_ID);

        self::assertFalse($result->ok);
        self::assertStringContainsString('metadata:read', $result->message);
    }

    public function testContentsWriteFailsWhenBranchCreateThrows(): void
    {
        $api = new FakeAppPermissionApi();
        $api->failOn('createBranch');

        $result = $this->probe($api)->checkContentsWrite(self::OWNER, self::REPO, self::BRANCH, self::RUN_ID);

        self::assertFalse($result->ok);
        self::assertStringContainsString('contents:write (branch create failed)', $result->message);
    }

    public function testContentsWriteFailsWhenPlainCommitThrows(): void
    {
        $api = new FakeAppPermissionApi();
        $api->failOn('putFile');

        $result = $this->probe($api)->checkContentsWrite(self::OWNER, self::REPO, self::BRANCH, self::RUN_ID);

        self::assertFalse($result->ok);
        self::assertStringContainsString('contents:write (commit failed)', $result->message);
    }

    public function testContentsWriteFailsWhenWorkflowFileRefused(): void
    {
        // The load-bearing case: contents:write succeeds but workflows:write is
        // absent, so only the .github/workflows/ commit is refused.
        $api = new FakeAppPermissionApi();
        $api->failOn('putWorkflowFile');

        $result = $this->probe($api)->checkContentsWrite(self::OWNER, self::REPO, self::BRANCH, self::RUN_ID);

        self::assertFalse($result->ok);
        self::assertStringContainsString('workflows:write', $result->message);
    }

    public function testPullRequestsWritePasses(): void
    {
        $api = new FakeAppPermissionApi();

        $result = $this->probe($api)->checkPullRequestsWrite(self::OWNER, self::REPO, self::BRANCH, self::RUN_ID);

        self::assertTrue($result->ok);
        self::assertTrue($api->closedPullRequest);
    }

    public function testPullRequestsWriteFailsWhenOpenThrows(): void
    {
        $api = new FakeAppPermissionApi();
        $api->failOn('openDraftPullRequest');

        $result = $this->probe($api)->checkPullRequestsWrite(self::OWNER, self::REPO, self::BRANCH, self::RUN_ID);

        self::assertFalse($result->ok);
        self::assertStringContainsString('pull-requests:write (draft PR open failed)', $result->message);
    }

    public function testPullRequestsWriteFailsWhenCloseThrows(): void
    {
        $api = new FakeAppPermissionApi();
        $api->failOn('closePullRequest');

        $result = $this->probe($api)->checkPullRequestsWrite(self::OWNER, self::REPO, self::BRANCH, self::RUN_ID);

        self::assertFalse($result->ok);
        self::assertStringContainsString('open but not close', $result->message);
    }

    public function testCleanupSwallowsDeleteFailure(): void
    {
        $api = new FakeAppPermissionApi();
        $api->failOn('deleteBranch');

        $result = $this->probe($api)->cleanup(self::OWNER, self::REPO, self::BRANCH);

        self::assertTrue($result->ok);
    }

    public function testCleanupDeletesBranch(): void
    {
        $api = new FakeAppPermissionApi();

        $result = $this->probe($api)->cleanup(self::OWNER, self::REPO, self::BRANCH);

        self::assertTrue($result->ok);
        self::assertTrue($api->deletedBranch);
    }
}
