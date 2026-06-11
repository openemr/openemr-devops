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

use OpenEMR\Release\CompatibilityNotesRenderer;
use PHPUnit\Framework\TestCase;

final class CompatibilityNotesRendererTest extends TestCase
{
    private const URL = 'https://github.com/openemr/openemr/tree/rel-810/ci';

    public function testRendersSectionWithKnownLabelsAndLink(): void
    {
        $section = (new CompatibilityNotesRenderer())->render(
            ['php' => '8.2', 'mariadb' => '10.6', 'mysql' => '5.7'],
            self::URL,
        );

        $expected = implode("\n", [
            '### Minimum supported versions',
            '',
            '- **PHP** 8.2+',
            '- **MariaDB** 10.6+',
            '- **MySQL** 5.7+',
            '',
            'See the [tested CI matrix](' . self::URL . ') for all tested version combinations.',
            '',
        ]);

        self::assertSame($expected, $section);
    }

    public function testUnknownComponentFallsBackToUcfirst(): void
    {
        $section = (new CompatibilityNotesRenderer())->render(['postgres' => '14.0'], self::URL);

        self::assertStringContainsString('- **Postgres** 14.0+', $section);
    }

    public function testEmptyMinimumsThrows(): void
    {
        $this->expectException(\RuntimeException::class);
        $this->expectExceptionMessage('empty minimums');

        (new CompatibilityNotesRenderer())->render([], self::URL);
    }
}
