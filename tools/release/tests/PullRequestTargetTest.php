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
use PHPUnit\Framework\TestCase;

final class PullRequestTargetTest extends TestCase
{
    public function testForReleaseProducesInfraConductorDocsInOrder(): void
    {
        $targets = PullRequestTarget::forRelease('8.1.0', 'rel-810');

        self::assertCount(3, $targets);
        self::assertSame(RoleLabel::Infra, $targets[0]->roleLabel);
        self::assertSame('openemr/openemr-devops', $targets[0]->repo);
        self::assertSame('release-rotation/auto', $targets[0]->branch);
        self::assertSame('master', $targets[0]->expectedBase);
        self::assertSame(1, $targets[0]->mergeOrder);

        self::assertSame(RoleLabel::Conductor, $targets[1]->roleLabel);
        self::assertSame('openemr/openemr', $targets[1]->repo);
        self::assertSame('release-prep/rel-810', $targets[1]->branch);
        self::assertSame('rel-810', $targets[1]->expectedBase);
        self::assertSame(2, $targets[1]->mergeOrder);

        self::assertSame(RoleLabel::Docs, $targets[2]->roleLabel);
        self::assertSame('openemr/website-openemr', $targets[2]->repo);
        self::assertSame('release-docs/8.1.0', $targets[2]->branch);
        self::assertSame('master', $targets[2]->expectedBase);
        self::assertSame(3, $targets[2]->mergeOrder);
    }
}
