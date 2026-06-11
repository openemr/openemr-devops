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

    public function testInjectsSectionAfterVersionHeading(): void
    {
        $openemrDir = $this->tmpDir . '/openemr';
        $this->matrixDir($openemrDir, 'apache_82_mariadb', 'mariadb:11.8.6');
        $this->matrixDir($openemrDir, 'apache_84_mysql', 'mysql:8.4.0');

        $notes = $this->tmpDir . '/changelog.md';
        file_put_contents($notes, "## [8.1.0] - 2026-06-10\n\n### Fixed\n\n- something\n");

        $process = $this->runCli([
            '--version-branch=rel-810',
            '--openemr-dir=' . $openemrDir,
            '--notes-file=' . $notes,
        ]);

        self::assertSame(0, $process->getExitCode(), $process->getOutput());

        $result = (string) file_get_contents($notes);
        $url = 'https://github.com/openemr/openemr/tree/rel-810/ci';
        $expected = implode("\n", [
            '## [8.1.0] - 2026-06-10',
            '',
            '### Minimum supported versions',
            '',
            '- **PHP** 8.2+',
            '- **MariaDB** 11.8+',
            '- **MySQL** 8.4+',
            '',
            'See the [tested CI matrix](' . $url . ') for all tested version combinations.',
            '',
            '### Fixed',
            '',
            '- something',
            '',
        ]);
        self::assertSame($expected, $result);
    }

    public function testPrependsWhenNoVersionHeading(): void
    {
        $openemrDir = $this->tmpDir . '/openemr';
        $this->matrixDir($openemrDir, 'apache_82_mariadb', 'mariadb:11.8.6');

        $notes = $this->tmpDir . '/changelog.md';
        file_put_contents($notes, "- bare body, no heading\n");

        $process = $this->runCli([
            '--version-branch=rel-810',
            '--openemr-dir=' . $openemrDir,
            '--notes-file=' . $notes,
        ]);

        self::assertSame(0, $process->getExitCode(), $process->getOutput());

        $result = (string) file_get_contents($notes);
        self::assertStringStartsWith('### Minimum supported versions', $result);
        self::assertStringContainsString('- bare body, no heading', $result);
    }

    public function testCustomRepoChangesMatrixUrlHost(): void
    {
        $openemrDir = $this->tmpDir . '/openemr';
        $this->matrixDir($openemrDir, 'apache_82_mariadb', 'mariadb:11.8.6');

        $notes = $this->tmpDir . '/changelog.md';
        file_put_contents($notes, "## [8.1.0]\n\nbody\n");

        $process = $this->runCli([
            '--version-branch=rel-721',
            '--repo=openemr/openemr-fork',
            '--openemr-dir=' . $openemrDir,
            '--notes-file=' . $notes,
        ]);

        self::assertSame(0, $process->getExitCode(), $process->getOutput());
        self::assertStringContainsString(
            'https://github.com/openemr/openemr-fork/tree/rel-721/ci',
            (string) file_get_contents($notes),
        );
    }

    public function testMissingVersionBranchFails(): void
    {
        $notes = $this->tmpDir . '/changelog.md';
        file_put_contents($notes, "## [8.1.0]\n\nbody\n");

        $process = $this->runCli([
            '--openemr-dir=' . $this->tmpDir,
            '--notes-file=' . $notes,
        ]);

        self::assertSame(1, $process->getExitCode());
        self::assertStringContainsString('--version-branch is required', $process->getOutput());
    }

    public function testMissingNotesFileFails(): void
    {
        $openemrDir = $this->tmpDir . '/openemr';
        $this->matrixDir($openemrDir, 'apache_82_mariadb', 'mariadb:11.8.6');

        $process = $this->runCli([
            '--version-branch=rel-810',
            '--openemr-dir=' . $openemrDir,
            '--notes-file=' . $this->tmpDir . '/does-not-exist.md',
        ]);

        self::assertSame(1, $process->getExitCode());
        self::assertStringContainsString('Notes file not found', $process->getOutput());
    }

    /**
     * @param list<string> $args
     */
    private function runCli(array $args): Process
    {
        $process = new Process(['php', self::BIN, ...$args]);
        $process->run();
        return $process;
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
