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

use PHPUnit\Framework\TestCase;
use Symfony\Component\Process\Process;

final class DeriveCompatibilityCliTest extends TestCase
{
    private const BIN = __DIR__ . '/../bin/derive-compatibility.php';

    private string $tmpDir = '';

    protected function setUp(): void
    {
        $this->tmpDir = sys_get_temp_dir() . '/openemr-compat-cli-' . bin2hex(random_bytes(8));
        if (!mkdir($this->tmpDir, 0700, true)) {
            throw new \RuntimeException('Failed to create tmp dir: ' . $this->tmpDir);
        }
    }

    protected function tearDown(): void
    {
        if (is_dir($this->tmpDir)) {
            (new Process(['rm', '-rf', $this->tmpDir]))->run();
        }
    }

    public function testWritesManifestWithMinimumsAndMatrixUrl(): void
    {
        $openemrDir = $this->tmpDir . '/openemr';
        $this->matrixDir($openemrDir, 'apache_82_mariadb', 'mariadb:11.8.6');
        $this->matrixDir($openemrDir, 'apache_84_mysql', 'mysql:8.4.0');
        $out = $this->tmpDir . '/compatibility.json';

        $process = new Process([
            'php',
            self::BIN,
            '--release-version=8.1.0',
            '--version-branch=rel-810',
            '--openemr-dir=' . $openemrDir,
            '--out=' . $out,
        ]);
        $process->run();

        self::assertSame(0, $process->getExitCode(), $process->getOutput());
        self::assertFileExists($out);

        $manifest = json_decode((string) file_get_contents($out), true, 512, JSON_THROW_ON_ERROR);
        self::assertSame([
            'version' => '8.1.0',
            'php' => ['min' => '8.2'],
            'mariadb' => ['min' => '11.8'],
            'mysql' => ['min' => '8.4'],
            'tested_matrix_url' => 'https://github.com/openemr/openemr/tree/rel-810/ci',
        ], $manifest);
    }

    public function testCustomRepoChangesMatrixUrlHost(): void
    {
        $openemrDir = $this->tmpDir . '/openemr';
        $this->matrixDir($openemrDir, 'apache_82_mariadb', 'mariadb:11.8.6');
        $out = $this->tmpDir . '/compatibility.json';

        $process = new Process([
            'php',
            self::BIN,
            '--release-version=8.1.0',
            '--version-branch=rel-721',
            '--repo=openemr/openemr-fork',
            '--openemr-dir=' . $openemrDir,
            '--out=' . $out,
        ]);
        $process->run();

        self::assertSame(0, $process->getExitCode(), $process->getOutput());
        $manifest = json_decode((string) file_get_contents($out), true, 512, JSON_THROW_ON_ERROR);
        self::assertIsArray($manifest);
        self::assertSame(
            'https://github.com/openemr/openemr-fork/tree/rel-721/ci',
            $manifest['tested_matrix_url'],
        );
    }

    public function testMissingVersionBranchFails(): void
    {
        $process = new Process([
            'php',
            self::BIN,
            '--release-version=8.1.0',
            '--openemr-dir=' . $this->tmpDir,
        ]);
        $process->run();

        self::assertSame(1, $process->getExitCode());
        self::assertStringContainsString('--version-branch is required', $process->getOutput());
    }

    public function testMissingReleaseVersionFails(): void
    {
        $process = new Process([
            'php',
            self::BIN,
            '--version-branch=rel-810',
            '--openemr-dir=' . $this->tmpDir,
        ]);
        $process->run();

        self::assertSame(1, $process->getExitCode());
        self::assertStringContainsString('--release-version is required', $process->getOutput());
    }

    private function matrixDir(string $openemrDir, string $name, string $image): void
    {
        $dir = $openemrDir . '/ci/' . $name;
        if (!is_dir($dir) && !mkdir($dir, 0700, true)) {
            throw new \RuntimeException('Failed to create matrix dir: ' . $dir);
        }
        file_put_contents(
            $dir . '/docker-compose.yml',
            "services:\n  mysql:\n    image: {$image}\n",
        );
    }
}
