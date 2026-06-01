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

use OpenEMR\Release\PullRequestTarget;
use OpenEMR\Release\RoleLabel;
use OpenEMR\Release\ShipReleaseResult;
use OpenEMR\Release\ShipReleaseStepResult;
use OpenEMR\Release\ShipReleaseStepStatus;
use OpenEMR\Release\ShipReleaseSummaryRenderer;
use PHPUnit\Framework\TestCase;

final class ShipReleaseSummaryRendererTest extends TestCase
{
    public function testRendersHeaderModeAndResult(): void
    {
        $result = new ShipReleaseResult([
            $this->step(RoleLabel::Infra, 'openemr/openemr-devops', ShipReleaseStepStatus::MERGED, 11, 'abc1234'),
            $this->step(RoleLabel::Conductor, 'openemr/openemr', ShipReleaseStepStatus::MERGED, 22, 'def5678'),
            $this->step(RoleLabel::Docs, 'openemr/website-openemr', ShipReleaseStepStatus::MERGED, 33, 'aaa9999'),
        ]);

        $md = ShipReleaseSummaryRenderer::render('8.1.0', 'rel-810', false, $result);

        self::assertStringContainsString('## Ship Release — 8.1.0 (rel-810)', $md);
        self::assertStringContainsString('- **Mode:** live', $md);
        self::assertStringContainsString('- **Result:** ✅ success', $md);
        self::assertStringContainsString('| Role | Repo | PR | Status | Detail |', $md);
        self::assertStringContainsString(
            '| infra | `openemr/openemr-devops` '
            . '| [#11](https://github.com/openemr/openemr-devops/pull/11) | ✅ merged | `abc1234` |',
            $md,
        );
    }

    public function testDryRunModeAndWouldMerge(): void
    {
        $result = new ShipReleaseResult([
            $this->step(RoleLabel::Infra, 'openemr/openemr-devops', ShipReleaseStepStatus::WOULD_MERGE, 11, null),
        ]);

        $md = ShipReleaseSummaryRenderer::render('8.1.0', 'rel-810', true, $result);

        self::assertStringContainsString('- **Mode:** dry run (no merges performed)', $md);
        self::assertStringContainsString(
            '| infra | `openemr/openemr-devops` '
            . '| [#11](https://github.com/openemr/openemr-devops/pull/11) | ✅ would merge | — |',
            $md,
        );
    }

    public function testFailureWithFatalReasonAndBlockedReasons(): void
    {
        $result = new ShipReleaseResult(
            [
                $this->step(
                    RoleLabel::Conductor,
                    'openemr/openemr',
                    ShipReleaseStepStatus::BLOCKED,
                    22,
                    null,
                    ['not mergeable', 'required check failing'],
                ),
            ],
            'docs PR shipped FINAL with no tag',
        );

        $md = ShipReleaseSummaryRenderer::render('8.1.0', 'rel-810', false, $result);

        self::assertStringContainsString('- **Result:** ❌ failure', $md);
        self::assertStringContainsString('> ❌ **Fatal:** docs PR shipped FINAL with no tag', $md);
        self::assertStringContainsString('❌ blocked | not mergeable<br>required check failing |', $md);
    }

    public function testMissingPrRendersDash(): void
    {
        $result = new ShipReleaseResult([
            $this->step(RoleLabel::Docs, 'openemr/website-openemr', ShipReleaseStepStatus::NOT_REACHED, null, null),
        ]);

        $md = ShipReleaseSummaryRenderer::render('8.1.0', 'rel-810', false, $result);

        self::assertStringContainsString('| docs | `openemr/website-openemr` | — | · not reached | — |', $md);
    }

    /**
     * @param list<string> $reasons
     */
    private function step(
        RoleLabel $role,
        string $repo,
        ShipReleaseStepStatus $status,
        ?int $prNumber,
        ?string $mergeSha,
        array $reasons = [],
    ): ShipReleaseStepResult {
        return new ShipReleaseStepResult(
            new PullRequestTarget($repo, 'branch', 'master', $role, $role->value === 'infra' ? 1 : 2),
            $status,
            $prNumber,
            $mergeSha,
            $reasons,
        );
    }
}
