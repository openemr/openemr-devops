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

use OpenEMR\Release\RotationPrPublisher;
use PHPUnit\Framework\TestCase;

final class RotationPrPublisherTest extends TestCase
{
    public function testBodyIncludesTriggerInBackticksAndRunUrl(): void
    {
        $body = RotationPrPublisher::buildBody(
            'openemr-rel-cut',
            'https://example.test/runs/42',
            '',
            '8.2',
            '',
        );

        self::assertStringContainsString('triggered by `openemr-rel-cut`', $body);
        self::assertStringContainsString('Run: https://example.test/runs/42', $body);
        self::assertStringContainsString('- next=8.2', $body);
        self::assertStringNotContainsString('- current=', $body);
        self::assertStringNotContainsString('- dev=', $body);
    }

    public function testBodyOmitsRunUrlSectionWhenAbsent(): void
    {
        $body = RotationPrPublisher::buildBody('workflow_dispatch', '', '8.1', '8.2', 'edge');

        self::assertStringNotContainsString('Run:', $body);
        self::assertStringContainsString('- current=8.1', $body);
        self::assertStringContainsString('- next=8.2', $body);
        self::assertStringContainsString('- dev=edge', $body);
    }

    public function testBodyHandlesAllSlotsEmpty(): void
    {
        $body = RotationPrPublisher::buildBody('workflow_dispatch', 'https://x.test/r/1', '', '', '');

        // Heading line + blank + Run line + blank + 'Slot assignments applied:' + trailing newline.
        self::assertStringContainsString('Slot assignments applied:', $body);
        self::assertStringEndsWith("\n", $body);
        self::assertStringNotContainsString('- ', $body);
    }
}
