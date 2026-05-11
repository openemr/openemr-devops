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
use OpenEMR\Release\Tests\Fakes\FakeClock;
use OpenEMR\Release\Tests\Fakes\FakePullRequestApi;
use PHPUnit\Framework\TestCase;

final class ShipReleaseOrchestratorTest extends TestCase
{
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

    private function merged(int $number, string $head): PullRequestSnapshot
    {
        return new PullRequestSnapshot($number, $head, 'master', new \DateTimeImmutable('2026-05-01T00:00:00Z'));
    }

    public function testHappyPathMergesAllThreeInOrderAndPostsApprovalStatus(): void
    {
        $api = new FakePullRequestApi();
        $targets = $this->targets();
        $api->setSnapshot('openemr/openemr-devops', 'release-rotation/auto', $this->open(101, 'sha-infra'));
        $api->setSnapshot('openemr/openemr', 'release-prep/rel-810', $this->open(202, 'sha-conductor'));
        $api->setSnapshot('openemr/website-openemr', 'release-docs/8.1.0', $this->open(303, 'sha-docs-old'));
        // After conductor merge, the docs PR is re-rendered with a new head SHA.
        $api->setSnapshotAfterFinds(
            'openemr/website-openemr',
            'release-docs/8.1.0',
            2,
            $this->open(303, 'sha-docs-new'),
        );
        $api->setReadiness(101, $this->ready('sha-infra'));
        $api->setReadiness(202, $this->ready('sha-conductor'));
        $api->setReadiness(303, $this->ready('sha-docs-new'));

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
            [['repo' => 'openemr/openemr-devops', 'number' => 101, 'expected' => 'sha-infra'],
                ['repo' => 'openemr/openemr', 'number' => 202, 'expected' => 'sha-conductor'],
                ['repo' => 'openemr/website-openemr', 'number' => 303, 'expected' => 'sha-docs-new']],
            $api->merges,
        );
        // Three approval statuses, one per merge, on the head SHA we merged.
        self::assertCount(3, $api->postedStatuses);
        self::assertSame(ShipReleaseOrchestrator::STATUS_CONTEXT, $api->postedStatuses[0]['context']);
        self::assertSame('sha-infra', $api->postedStatuses[0]['sha']);
        self::assertSame('sha-docs-new', $api->postedStatuses[2]['sha']);
    }

    public function testInfraAlreadyMergedSkipsThenContinues(): void
    {
        $api = new FakePullRequestApi();
        $api->setSnapshot('openemr/openemr-devops', 'release-rotation/auto', $this->merged(101, 'sha-infra'));
        $api->setSnapshot('openemr/openemr', 'release-prep/rel-810', $this->open(202, 'sha-conductor'));
        $api->setSnapshot('openemr/website-openemr', 'release-docs/8.1.0', $this->open(303, 'sha-docs'));
        $api->setReadiness(202, $this->ready('sha-conductor'));
        $api->setReadiness(303, $this->ready('sha-docs'));

        $result = (new ShipReleaseOrchestrator($api, new FakeClock()))->ship($this->targets());

        self::assertTrue($result->wasSuccessful());
        self::assertSame(ShipReleaseStepStatus::SKIPPED_ALREADY_MERGED, $result->steps[0]->status);
        self::assertSame(ShipReleaseStepStatus::MERGED, $result->steps[1]->status);
        self::assertSame(ShipReleaseStepStatus::MERGED, $result->steps[2]->status);
        self::assertCount(2, $api->merges);
    }

    public function testConductorBlockedStopsBeforeDocs(): void
    {
        $api = new FakePullRequestApi();
        $api->setSnapshot('openemr/openemr-devops', 'release-rotation/auto', $this->open(101, 'sha-infra'));
        $api->setSnapshot('openemr/openemr', 'release-prep/rel-810', $this->open(202, 'sha-conductor'));
        $api->setSnapshot('openemr/website-openemr', 'release-docs/8.1.0', $this->open(303, 'sha-docs'));
        $api->setReadiness(101, $this->ready('sha-infra'));
        $api->setReadiness(202, new PullRequestReadiness('sha-conductor', ['check core-test conclusion=FAILURE']));
        $api->setReadiness(303, $this->ready('sha-docs'));

        $result = (new ShipReleaseOrchestrator($api, new FakeClock()))->ship($this->targets());

        self::assertFalse($result->wasSuccessful());
        self::assertSame(ShipReleaseStepStatus::MERGED, $result->steps[0]->status);
        self::assertSame(ShipReleaseStepStatus::BLOCKED, $result->steps[1]->status);
        self::assertContains('check core-test conclusion=FAILURE', $result->steps[1]->reasons);
        self::assertSame(ShipReleaseStepStatus::NOT_REACHED, $result->steps[2]->status);
        self::assertCount(1, $api->merges);
    }

    public function testDocsFirstFatalRefusesToMergeAnything(): void
    {
        $api = new FakePullRequestApi();
        $api->setSnapshot('openemr/openemr-devops', 'release-rotation/auto', $this->open(101, 'sha-infra'));
        $api->setSnapshot('openemr/openemr', 'release-prep/rel-810', $this->open(202, 'sha-conductor'));
        $api->setSnapshot('openemr/website-openemr', 'release-docs/8.1.0', $this->merged(303, 'sha-docs'));

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
        $api->setSnapshot('openemr/openemr-devops', 'release-rotation/auto', $this->open(101, 'sha-infra'));
        $api->setSnapshot('openemr/openemr', 'release-prep/rel-810', $this->open(202, 'sha-conductor'));
        $api->setSnapshot('openemr/website-openemr', 'release-docs/8.1.0', $this->open(303, 'sha-docs'));
        $api->setReadiness(101, $this->ready('sha-infra'));
        $api->setReadiness(202, $this->ready('sha-conductor'));
        $api->setReadiness(303, $this->ready('sha-docs'));

        $result = (new ShipReleaseOrchestrator($api, new FakeClock(), 600, true))->ship($this->targets());

        self::assertTrue($result->wasSuccessful());
        self::assertSame([], $api->merges);
        self::assertSame([], $api->postedStatuses);
        foreach ($result->steps as $step) {
            self::assertSame(ShipReleaseStepStatus::WOULD_MERGE, $step->status);
        }
    }

    public function testDownstreamWaitTimesOutAndReChecksReadiness(): void
    {
        $api = new FakePullRequestApi();
        $api->setSnapshot('openemr/openemr-devops', 'release-rotation/auto', $this->open(101, 'sha-infra'));
        $api->setSnapshot('openemr/openemr', 'release-prep/rel-810', $this->open(202, 'sha-conductor'));
        // Docs PR head SHA never changes — simulates downstream workflow not firing.
        $api->setSnapshot('openemr/website-openemr', 'release-docs/8.1.0', $this->open(303, 'sha-docs'));
        $api->setReadiness(101, $this->ready('sha-infra'));
        $api->setReadiness(202, $this->ready('sha-conductor'));
        $api->setReadiness(303, $this->ready('sha-docs')); // still ready — proceed despite no flip

        $clock = new FakeClock();
        $result = (new ShipReleaseOrchestrator($api, $clock, 30))->ship($this->targets());

        self::assertTrue($result->wasSuccessful());
        self::assertGreaterThanOrEqual(30, $clock->totalSlept);
        self::assertSame(ShipReleaseStepStatus::MERGED, $result->steps[2]->status);
    }
}
