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

use OpenEMR\Release\PullRequestReadiness;
use OpenEMR\Release\PullRequestSnapshot;
use OpenEMR\Release\PullRequestTarget;
use OpenEMR\Release\ShipReleaseOrchestrator;
use OpenEMR\Release\ShipReleaseStepResult;
use OpenEMR\Release\ShipReleaseStepStatus;
use OpenEMR\Release\Tests\Fakes\FailingMergeApi;
use OpenEMR\Release\Tests\Fakes\FakeClock;
use OpenEMR\Release\Tests\Fakes\FakePullRequestApi;
use PHPUnit\Framework\TestCase;

final class ShipReleaseOrchestratorTest extends TestCase
{
    private const INFRA_REPO = 'openemr/openemr-devops';
    private const INFRA_BRANCH = 'release-rotation/auto';
    private const CONDUCTOR_REPO = 'openemr/openemr';
    private const CONDUCTOR_BRANCH = 'release-prep/rel-810';
    private const CONDUCTOR_BASE = 'rel-810';
    private const DOCS_REPO = 'openemr/website-openemr';
    private const DOCS_BRANCH = 'release-docs/8.1.0';

    /**
     * @return list<PullRequestTarget>
     */
    private function targets(): array
    {
        return PullRequestTarget::forRelease('8.1.0', 'rel-810');
    }

    private function ready(string $headSha): PullRequestReadiness
    {
        return new PullRequestReadiness($headSha, []);
    }

    private function open(int $number, string $head, string $base = 'master'): PullRequestSnapshot
    {
        return new PullRequestSnapshot($number, $head, $base, null);
    }

    private function merged(int $number, string $head, string $base = 'master'): PullRequestSnapshot
    {
        return new PullRequestSnapshot($number, $head, $base, new \DateTimeImmutable('2026-05-01T00:00:00Z'));
    }

    private function openConductor(): PullRequestSnapshot
    {
        return $this->open(202, 'sha-conductor', self::CONDUCTOR_BASE);
    }

    private function mergedConductor(): PullRequestSnapshot
    {
        return $this->merged(202, 'sha-conductor', self::CONDUCTOR_BASE);
    }

    public function testHappyPathMergesAllThreeInOrderAndPostsApprovalStatus(): void
    {
        $api = new FakePullRequestApi();
        $targets = $this->targets();
        $api->setSnapshot(self::INFRA_REPO, self::INFRA_BRANCH, $this->open(101, 'sha-infra'));
        $api->setSnapshot(self::CONDUCTOR_REPO, self::CONDUCTOR_BRANCH, $this->openConductor());
        $api->setSnapshot(self::DOCS_REPO, self::DOCS_BRANCH, $this->open(303, 'sha-docs-old'));
        // After conductor merge, the docs PR is re-rendered with a new head SHA.
        $api->setSnapshotAfterFinds(
            self::DOCS_REPO,
            self::DOCS_BRANCH,
            2,
            $this->open(303, 'sha-docs-new'),
        );
        $api->setReadiness(self::INFRA_REPO, 101, $this->ready('sha-infra'));
        $api->setReadiness(self::CONDUCTOR_REPO, 202, $this->ready('sha-conductor'));
        $api->setReadiness(self::DOCS_REPO, 303, $this->ready('sha-docs-new'));

        $result = (new ShipReleaseOrchestrator($api, new FakeClock()))->ship($targets);

        self::assertTrue($result->wasSuccessful());
        self::assertSame(
            [ShipReleaseStepStatus::MERGED, ShipReleaseStepStatus::MERGED, ShipReleaseStepStatus::MERGED],
            array_map(
                static fn (ShipReleaseStepResult $s): ShipReleaseStepStatus => $s->status,
                $result->steps,
            ),
        );
        self::assertSame(
            [['repo' => self::INFRA_REPO, 'number' => 101, 'expected' => 'sha-infra'],
                ['repo' => self::CONDUCTOR_REPO, 'number' => 202, 'expected' => 'sha-conductor'],
                ['repo' => self::DOCS_REPO, 'number' => 303, 'expected' => 'sha-docs-new']],
            $api->merges,
        );
        self::assertCount(3, $api->postedStatuses);
        self::assertSame(ShipReleaseOrchestrator::STATUS_CONTEXT, $api->postedStatuses[0]['context']);
        self::assertSame('sha-infra', $api->postedStatuses[0]['sha']);
        self::assertSame('sha-docs-new', $api->postedStatuses[2]['sha']);
    }

    public function testInfraAlreadyMergedSkipsThenContinues(): void
    {
        $api = new FakePullRequestApi();
        $api->setSnapshot(self::INFRA_REPO, self::INFRA_BRANCH, $this->merged(101, 'sha-infra'));
        $api->setSnapshot(self::CONDUCTOR_REPO, self::CONDUCTOR_BRANCH, $this->openConductor());
        $api->setSnapshot(self::DOCS_REPO, self::DOCS_BRANCH, $this->open(303, 'sha-docs'));
        $api->setReadiness(self::CONDUCTOR_REPO, 202, $this->ready('sha-conductor'));
        $api->setReadiness(self::DOCS_REPO, 303, $this->ready('sha-docs'));

        $result = (new ShipReleaseOrchestrator($api, new FakeClock()))->ship($this->targets());

        self::assertTrue($result->wasSuccessful());
        self::assertSame(ShipReleaseStepStatus::SKIPPED_ALREADY_MERGED, $result->steps[0]->status);
        self::assertSame(ShipReleaseStepStatus::MERGED, $result->steps[1]->status);
        self::assertSame(ShipReleaseStepStatus::MERGED, $result->steps[2]->status);
        self::assertCount(2, $api->merges);
    }

    public function testConductorBlockedAtPreflightMergesNothing(): void
    {
        $api = new FakePullRequestApi();
        $api->setSnapshot(self::INFRA_REPO, self::INFRA_BRANCH, $this->open(101, 'sha-infra'));
        $api->setSnapshot(self::CONDUCTOR_REPO, self::CONDUCTOR_BRANCH, $this->openConductor());
        $api->setSnapshot(self::DOCS_REPO, self::DOCS_BRANCH, $this->open(303, 'sha-docs'));
        $api->setReadiness(self::INFRA_REPO, 101, $this->ready('sha-infra'));
        $api->setReadiness(
            self::CONDUCTOR_REPO,
            202,
            new PullRequestReadiness('sha-conductor', ['check core-test conclusion=FAILURE']),
        );
        $api->setReadiness(self::DOCS_REPO, 303, $this->ready('sha-docs'));

        $result = (new ShipReleaseOrchestrator($api, new FakeClock()))->ship($this->targets());

        self::assertFalse($result->wasSuccessful());
        self::assertSame(ShipReleaseStepStatus::NOT_REACHED, $result->steps[0]->status);
        self::assertSame(ShipReleaseStepStatus::BLOCKED, $result->steps[1]->status);
        self::assertContains('check core-test conclusion=FAILURE', $result->steps[1]->reasons);
        self::assertSame(ShipReleaseStepStatus::NOT_REACHED, $result->steps[2]->status);
        self::assertSame([], $api->merges);
        self::assertSame([], $api->postedStatuses);
    }

    public function testInfraReadyButDocsBlockedAtPreflightMergesNothing(): void
    {
        $api = new FakePullRequestApi();
        $api->setSnapshot(self::INFRA_REPO, self::INFRA_BRANCH, $this->open(101, 'sha-infra'));
        $api->setSnapshot(self::CONDUCTOR_REPO, self::CONDUCTOR_BRANCH, $this->openConductor());
        $api->setSnapshot(self::DOCS_REPO, self::DOCS_BRANCH, $this->open(303, 'sha-docs'));
        $api->setReadiness(self::INFRA_REPO, 101, $this->ready('sha-infra'));
        $api->setReadiness(self::CONDUCTOR_REPO, 202, $this->ready('sha-conductor'));
        $api->setReadiness(self::DOCS_REPO, 303, new PullRequestReadiness(
            'sha-docs',
            ['reviewDecision=REVIEW_REQUIRED (need APPROVED)'],
        ));

        $result = (new ShipReleaseOrchestrator($api, new FakeClock()))->ship($this->targets());

        self::assertFalse($result->wasSuccessful());
        self::assertSame(ShipReleaseStepStatus::NOT_REACHED, $result->steps[0]->status);
        self::assertSame(ShipReleaseStepStatus::NOT_REACHED, $result->steps[1]->status);
        self::assertSame(ShipReleaseStepStatus::BLOCKED, $result->steps[2]->status);
        self::assertSame([], $api->merges);
    }

    public function testDocsFirstFatalRefusesToMergeAnything(): void
    {
        $api = new FakePullRequestApi();
        $api->setSnapshot(self::INFRA_REPO, self::INFRA_BRANCH, $this->open(101, 'sha-infra'));
        $api->setSnapshot(self::CONDUCTOR_REPO, self::CONDUCTOR_BRANCH, $this->openConductor());
        $api->setSnapshot(self::DOCS_REPO, self::DOCS_BRANCH, $this->merged(303, 'sha-docs'));

        $result = (new ShipReleaseOrchestrator($api, new FakeClock()))->ship($this->targets());

        self::assertFalse($result->wasSuccessful());
        self::assertNotNull($result->fatalReason);
        self::assertStringContainsString('docs-first', $result->fatalReason);
        self::assertSame([], $api->merges);
        foreach ($result->steps as $step) {
            self::assertSame(ShipReleaseStepStatus::NOT_REACHED, $step->status);
        }
    }

    public function testDryRunDoesNotMergeOrPostStatuses(): void
    {
        $api = new FakePullRequestApi();
        $api->setSnapshot(self::INFRA_REPO, self::INFRA_BRANCH, $this->open(101, 'sha-infra'));
        $api->setSnapshot(self::CONDUCTOR_REPO, self::CONDUCTOR_BRANCH, $this->openConductor());
        $api->setSnapshot(self::DOCS_REPO, self::DOCS_BRANCH, $this->open(303, 'sha-docs'));
        $api->setReadiness(self::INFRA_REPO, 101, $this->ready('sha-infra'));
        $api->setReadiness(self::CONDUCTOR_REPO, 202, $this->ready('sha-conductor'));
        $api->setReadiness(self::DOCS_REPO, 303, $this->ready('sha-docs'));

        $result = (new ShipReleaseOrchestrator($api, new FakeClock(), 600, true))->ship($this->targets());

        self::assertTrue($result->wasSuccessful());
        self::assertSame([], $api->merges);
        self::assertSame([], $api->postedStatuses);
        foreach ($result->steps as $step) {
            self::assertSame(ShipReleaseStepStatus::WOULD_MERGE, $step->status);
        }
    }

    public function testConductorAlreadyMergedRefetchesDocsBeforeMerging(): void
    {
        $api = new FakePullRequestApi();
        $api->setSnapshot(self::INFRA_REPO, self::INFRA_BRANCH, $this->open(101, 'sha-infra'));
        $api->setSnapshot(self::CONDUCTOR_REPO, self::CONDUCTOR_BRANCH, $this->mergedConductor());
        $api->setSnapshot(self::DOCS_REPO, self::DOCS_BRANCH, $this->open(303, 'sha-docs-stale'));
        $api->setReadiness(self::INFRA_REPO, 101, $this->ready('sha-infra'));
        $api->setReadinessSequence(self::DOCS_REPO, 303, [
            $this->ready('sha-docs-stale'),
            $this->ready('sha-docs-fresh'),
        ]);
        $api->setSnapshotAfterFinds(
            self::DOCS_REPO,
            self::DOCS_BRANCH,
            2,
            $this->open(303, 'sha-docs-fresh'),
        );

        $result = (new ShipReleaseOrchestrator($api, new FakeClock()))->ship($this->targets());

        self::assertTrue($result->wasSuccessful());
        self::assertSame(ShipReleaseStepStatus::MERGED, $result->steps[0]->status);
        self::assertSame(ShipReleaseStepStatus::SKIPPED_ALREADY_MERGED, $result->steps[1]->status);
        self::assertSame(ShipReleaseStepStatus::MERGED, $result->steps[2]->status);
        self::assertSame('sha-docs-fresh', $api->merges[1]['expected']);
    }

    public function testConductorAlreadyMergedBlocksDocsIfDownstreamStillInFlight(): void
    {
        $api = new FakePullRequestApi();
        $api->setSnapshot(self::INFRA_REPO, self::INFRA_BRANCH, $this->open(101, 'sha-infra'));
        $api->setSnapshot(self::CONDUCTOR_REPO, self::CONDUCTOR_BRANCH, $this->mergedConductor());
        $api->setSnapshot(self::DOCS_REPO, self::DOCS_BRANCH, $this->open(303, 'sha-docs'));
        $api->setReadiness(self::INFRA_REPO, 101, $this->ready('sha-infra'));
        $api->setReadinessSequence(self::DOCS_REPO, 303, [
            $this->ready('sha-docs'),
            new PullRequestReadiness('sha-docs', ['check core-test status=IN_PROGRESS']),
        ]);

        $result = (new ShipReleaseOrchestrator($api, new FakeClock()))->ship($this->targets());

        self::assertFalse($result->wasSuccessful());
        self::assertSame(ShipReleaseStepStatus::MERGED, $result->steps[0]->status);
        self::assertSame(ShipReleaseStepStatus::SKIPPED_ALREADY_MERGED, $result->steps[1]->status);
        self::assertSame(ShipReleaseStepStatus::BLOCKED, $result->steps[2]->status);
        self::assertContains('check core-test status=IN_PROGRESS', $result->steps[2]->reasons);
        self::assertCount(1, $api->merges);
    }

    public function testDownstreamWaitTimesOutAndReChecksReadiness(): void
    {
        $api = new FakePullRequestApi();
        $api->setSnapshot(self::INFRA_REPO, self::INFRA_BRANCH, $this->open(101, 'sha-infra'));
        $api->setSnapshot(self::CONDUCTOR_REPO, self::CONDUCTOR_BRANCH, $this->openConductor());
        $api->setSnapshot(self::DOCS_REPO, self::DOCS_BRANCH, $this->open(303, 'sha-docs'));
        $api->setReadiness(self::INFRA_REPO, 101, $this->ready('sha-infra'));
        $api->setReadiness(self::CONDUCTOR_REPO, 202, $this->ready('sha-conductor'));
        $api->setReadiness(self::DOCS_REPO, 303, $this->ready('sha-docs'));

        $clock = new FakeClock();
        $result = (new ShipReleaseOrchestrator($api, $clock, 30))->ship($this->targets());

        self::assertTrue($result->wasSuccessful());
        self::assertGreaterThanOrEqual(30, $clock->totalSlept);
        self::assertSame(ShipReleaseStepStatus::MERGED, $result->steps[2]->status);
    }

    public function testWrongBaseBranchBlocksWithoutMerging(): void
    {
        // Conductor PR exists but has been opened against `master` instead of
        // the expected `rel-810`. Refuse to merge it (would ship the wrong content).
        $api = new FakePullRequestApi();
        $api->setSnapshot(self::INFRA_REPO, self::INFRA_BRANCH, $this->open(101, 'sha-infra'));
        $api->setSnapshot(self::CONDUCTOR_REPO, self::CONDUCTOR_BRANCH, $this->open(202, 'sha-conductor', 'master'));
        $api->setSnapshot(self::DOCS_REPO, self::DOCS_BRANCH, $this->open(303, 'sha-docs'));
        $api->setReadiness(self::INFRA_REPO, 101, $this->ready('sha-infra'));
        $api->setReadiness(self::DOCS_REPO, 303, $this->ready('sha-docs'));

        $result = (new ShipReleaseOrchestrator($api, new FakeClock()))->ship($this->targets());

        self::assertFalse($result->wasSuccessful());
        self::assertSame(ShipReleaseStepStatus::BLOCKED, $result->steps[1]->status);
        self::assertStringContainsString('PR base is master, expected rel-810', $result->steps[1]->reasons[0]);
        self::assertSame([], $api->merges);
    }

    public function testTargetsAreSortedByMergeOrderRegardlessOfInputOrder(): void
    {
        // Pass targets in shuffled order; the orchestrator must still merge
        // infra → conductor → docs.
        $api = new FakePullRequestApi();
        $api->setSnapshot(self::INFRA_REPO, self::INFRA_BRANCH, $this->open(101, 'sha-infra'));
        $api->setSnapshot(self::CONDUCTOR_REPO, self::CONDUCTOR_BRANCH, $this->openConductor());
        $api->setSnapshot(self::DOCS_REPO, self::DOCS_BRANCH, $this->open(303, 'sha-docs-old'));
        $api->setSnapshotAfterFinds(
            self::DOCS_REPO,
            self::DOCS_BRANCH,
            2,
            $this->open(303, 'sha-docs-new'),
        );
        $api->setReadiness(self::INFRA_REPO, 101, $this->ready('sha-infra'));
        $api->setReadiness(self::CONDUCTOR_REPO, 202, $this->ready('sha-conductor'));
        $api->setReadiness(self::DOCS_REPO, 303, $this->ready('sha-docs-new'));

        $shuffled = $this->targets();
        $shuffled = [$shuffled[2], $shuffled[0], $shuffled[1]]; // docs, infra, conductor

        $result = (new ShipReleaseOrchestrator($api, new FakeClock()))->ship($shuffled);

        self::assertTrue($result->wasSuccessful());
        self::assertSame(
            [self::INFRA_REPO, self::CONDUCTOR_REPO, self::DOCS_REPO],
            array_column($api->merges, 'repo'),
        );
    }

    public function testMergeApiFailureReportsBlockedAndStopsSubsequentMerges(): void
    {
        // Simulate gh failing on the conductor merge (e.g. --match-head-commit
        // mismatch from a race). Infra still merges, conductor reports BLOCKED
        // with the gh error, docs is NOT_REACHED.
        $api = new FailingMergeApi('openemr/openemr', 202, 'gh: --match-head-commit does not match');
        $api->setSnapshot(self::INFRA_REPO, self::INFRA_BRANCH, $this->open(101, 'sha-infra'));
        $api->setSnapshot(self::CONDUCTOR_REPO, self::CONDUCTOR_BRANCH, $this->openConductor());
        $api->setSnapshot(self::DOCS_REPO, self::DOCS_BRANCH, $this->open(303, 'sha-docs'));
        $api->setReadiness(self::INFRA_REPO, 101, $this->ready('sha-infra'));
        $api->setReadiness(self::CONDUCTOR_REPO, 202, $this->ready('sha-conductor'));
        $api->setReadiness(self::DOCS_REPO, 303, $this->ready('sha-docs'));

        $result = (new ShipReleaseOrchestrator($api, new FakeClock()))->ship($this->targets());

        self::assertFalse($result->wasSuccessful());
        self::assertSame(ShipReleaseStepStatus::MERGED, $result->steps[0]->status);
        self::assertSame(ShipReleaseStepStatus::BLOCKED, $result->steps[1]->status);
        self::assertStringContainsString('--match-head-commit does not match', $result->steps[1]->reasons[0]);
        self::assertSame(ShipReleaseStepStatus::NOT_REACHED, $result->steps[2]->status);
    }
}
