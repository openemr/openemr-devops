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

use OpenEMR\Release\SlotAssignmentParser;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;

final class SlotAssignmentParserTest extends TestCase
{
    public function testRelCutDispatchAdvancesNextSlot(): void
    {
        $envelope = $this->loadFixture('good-rel-cut.json');

        $assignments = (new SlotAssignmentParser())->fromDispatchPayload('openemr-rel-cut', $envelope);

        self::assertSame(['next' => '8.1'], $assignments);
    }

    public function testRelUpdateDispatchAdvancesNextSlot(): void
    {
        $envelope = $this->loadFixture('good-rel-update.json');

        $assignments = (new SlotAssignmentParser())->fromDispatchPayload('openemr-rel-update', $envelope);

        self::assertSame(['next' => '8.1'], $assignments);
    }

    public function testTagDispatchPromotesCurrentSlot(): void
    {
        $envelope = $this->loadFixture('good-tag.json');

        $assignments = (new SlotAssignmentParser())->fromDispatchPayload('openemr-tag', $envelope);

        self::assertSame(['current' => '8.1'], $assignments);
    }

    public function testDocsBinariesDispatchYieldsNoSlotMove(): void
    {
        $envelope = $this->loadFixture('good-docs-binaries.json');

        $assignments = (new SlotAssignmentParser())->fromDispatchPayload('openemr-docs-binaries', $envelope);

        self::assertSame([], $assignments);
    }

    public function testMissingDataObjectThrows(): void
    {
        $this->expectException(\InvalidArgumentException::class);
        $this->expectExceptionMessageMatches("/missing 'data' object/");

        (new SlotAssignmentParser())->fromDispatchPayload('openemr-tag', ['event' => 'openemr-tag']);
    }

    public function testMissingVersionThrows(): void
    {
        $this->expectException(\InvalidArgumentException::class);
        $this->expectExceptionMessageMatches('/data\.version/');

        (new SlotAssignmentParser())->fromDispatchPayload('openemr-rel-cut', ['data' => ['branch' => 'rel-810']]);
    }

    public function testMalformedVersionThrows(): void
    {
        $this->expectException(\InvalidArgumentException::class);
        $this->expectExceptionMessageMatches('/MAJOR\.MINOR\.PATCH/');

        (new SlotAssignmentParser())->fromDispatchPayload('openemr-tag', ['data' => ['version' => '8.1']]);
    }

    public function testUnsupportedEventTypeThrows(): void
    {
        $this->expectException(\InvalidArgumentException::class);
        $this->expectExceptionMessageMatches('/Unsupported dispatch event/');

        (new SlotAssignmentParser())->fromDispatchPayload(
            'openemr-mystery-event',
            ['data' => ['version' => '8.1.0']],
        );
    }

    /**
     * @param array<string, string> $expected
     */
    #[DataProvider('parseProvider')]
    public function testParseHandlesCliShorthandForms(string $slot, string $raw, array $expected): void
    {
        self::assertSame($expected, (new SlotAssignmentParser())->parse($slot, $raw));
    }

    /**
     * @return array<string, array{0: string, 1: string, 2: array<string, string>}>
     */
    public static function parseProvider(): array
    {
        return [
            'minor expands to slot tuple' => [
                'next',
                '8.2',
                ['minor' => '8.2', 'full' => '8.2.0', 'branch' => 'rel-820', 'docker_dir' => '8.2.0'],
            ],
            'edge maps to master branch' => ['dev', 'edge', ['branch' => 'master']],
            'key=value overrides apply verbatim' => [
                'current',
                'minor=8.0,full=8.0.0,patch=8.0.0.3,branch=rel-800,docker_dir=8.0.0',
                [
                    'minor' => '8.0',
                    'full' => '8.0.0',
                    'patch' => '8.0.0.3',
                    'branch' => 'rel-800',
                    'docker_dir' => '8.0.0',
                ],
            ],
        ];
    }

    public function testParseRejectsBadInput(): void
    {
        $this->expectException(\InvalidArgumentException::class);
        $this->expectExceptionMessageMatches("/expected MAJOR\.MINOR or 'edge'/");

        (new SlotAssignmentParser())->parse('next', 'banana');
    }

    /**
     * @return array<string, mixed>
     */
    private function loadFixture(string $name): array
    {
        $path = __DIR__ . '/fixtures/dispatch/' . $name;
        $raw = file_get_contents($path);
        if ($raw === false) {
            throw new \RuntimeException("Fixture not readable: {$path}");
        }
        $decoded = json_decode($raw, true);
        if (!is_array($decoded)) {
            throw new \RuntimeException("Fixture not a JSON object: {$path}");
        }
        $normalized = [];
        foreach ($decoded as $key => $value) {
            if (!is_string($key)) {
                throw new \RuntimeException("Fixture has non-string root key: {$path}");
            }
            $normalized[$key] = $value;
        }
        return $normalized;
    }
}
