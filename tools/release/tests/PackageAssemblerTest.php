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

use OpenEMR\Release\PackageAssembler;
use PHPUnit\Framework\TestCase;
use Symfony\Component\Console\Output\BufferedOutput;

final class PackageAssemblerTest extends TestCase
{
    private string $tmpDir = '';

    protected function setUp(): void
    {
        $this->tmpDir = sys_get_temp_dir() . '/openemr-package-assembler-' . bin2hex(random_bytes(8));
        if (!mkdir($this->tmpDir, 0700, true)) {
            throw new \RuntimeException('Failed to create tmp dir: ' . $this->tmpDir);
        }
    }

    protected function tearDown(): void
    {
        if (is_dir($this->tmpDir)) {
            rmdir($this->tmpDir);
        }
    }

    public function testMissingOpenemrDirReturnsError(): void
    {
        $output = new BufferedOutput();
        $assembler = new PackageAssembler('8.1.0', $this->tmpDir . '/does-not-exist', $this->tmpDir, $output);

        self::assertSame(1, $assembler->assemble());
        self::assertStringContainsString('OpenEMR directory not found', $output->fetch());
    }

    public function testMissingBuildXmlReturnsError(): void
    {
        $output = new BufferedOutput();
        $assembler = new PackageAssembler('8.1.0', $this->tmpDir, $this->tmpDir, $output);

        self::assertSame(1, $assembler->assemble());
        self::assertStringContainsString('build.xml not found', $output->fetch());
    }
}
