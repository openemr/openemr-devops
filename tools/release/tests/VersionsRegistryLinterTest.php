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

use OpenEMR\Release\VersionsRegistryLinter;
use PHPUnit\Framework\TestCase;
use Symfony\Component\Process\Process;

final class VersionsRegistryLinterTest extends TestCase
{
    private string $tmpDir = '';
    private string $registryPath = '';

    protected function setUp(): void
    {
        $this->tmpDir = sys_get_temp_dir() . '/openemr-versions-linter-' . bin2hex(random_bytes(8));
        if (!mkdir($this->tmpDir, 0700, true)) {
            throw new \RuntimeException('Failed to create tmp dir: ' . $this->tmpDir);
        }
        $this->git(['init', '-q', '-b', 'main']);
        $this->seedBaseRegistry();
        $this->registryPath = $this->tmpDir . '/tools/release/versions.yml';
    }

    protected function tearDown(): void
    {
        $this->removeRecursive($this->tmpDir);
    }

    public function testCleanRepoProducesNoIssues(): void
    {
        $this->writeFileAndAdd('docker/openemr/8.1.0/Dockerfile', "ARG OPENEMR_VERSION=rel-810\n");
        $this->updateRegistry([
            ['path' => 'docker/openemr/8.1.0/Dockerfile', 'slot' => 'next'],
        ], []);

        $issues = (new VersionsRegistryLinter($this->tmpDir, $this->registryPath))->lint();

        self::assertSame([], $issues);
    }

    public function testUnregisteredFileWithImageTagIsFlagged(): void
    {
        $this->writeFileAndAdd(
            '.github/workflows/build-new.yml',
            "tags: openemr/openemr:8.3.0, openemr/openemr:next-next\n",
        );

        $issues = (new VersionsRegistryLinter($this->tmpDir, $this->registryPath))->lint();

        self::assertNotEmpty($issues);
        $paths = array_map(static fn(\OpenEMR\Release\LintIssue $i): string => $i->path, $issues);
        self::assertContains('.github/workflows/build-new.yml', $paths);
    }

    public function testUnregisteredFileWithBuildArgIsFlagged(): void
    {
        $this->writeFileAndAdd('docker/openemr/8.2.0/Dockerfile', "ARG OPENEMR_VERSION=rel-820\n");

        $issues = (new VersionsRegistryLinter($this->tmpDir, $this->registryPath))->lint();

        self::assertNotEmpty($issues);
        $paths = array_unique(array_map(static fn(\OpenEMR\Release\LintIssue $i): string => $i->path, $issues));
        self::assertContains('docker/openemr/8.2.0/Dockerfile', $paths);
    }

    public function testExcludedDirectoryIsSkipped(): void
    {
        $this->writeFileAndAdd('docker/openemr/obsolete/old/Dockerfile', "ARG OPENEMR_VERSION=rel-700\n");
        $this->updateRegistry([], [
            ['path' => 'docker/openemr/obsolete', 'reason' => 'frozen historical builds'],
        ]);

        $issues = (new VersionsRegistryLinter($this->tmpDir, $this->registryPath))->lint();

        self::assertSame([], $issues);
    }

    public function testExcludedExactPathIsSkipped(): void
    {
        $this->writeFileAndAdd('packages/standard/cfn/stack.py', "docker_version = ':7.0.3'\n");
        $this->updateRegistry([], [
            ['path' => 'packages/standard/cfn/stack.py', 'reason' => 'independent cadence'],
        ]);

        $issues = (new VersionsRegistryLinter($this->tmpDir, $this->registryPath))->lint();

        self::assertSame([], $issues);
    }

    public function testNonOpenemrVersionPinsAreNotFlagged(): void
    {
        $this->writeFileAndAdd(
            '.github/workflows/build-new.yml',
            "  - uses: actions/setup-php@v3\n    with:\n      php-version: '8.4'\n",
        );

        $issues = (new VersionsRegistryLinter($this->tmpDir, $this->registryPath))->lint();

        self::assertSame([], $issues, 'PHP/Alpine/etc. version pins must not trigger the linter');
    }

    public function testIssueRecordsLineNumberAndPatternKind(): void
    {
        $this->writeFileAndAdd(
            'docker/openemr/8.2.0/README.md',
            "# Header\n\nimage: openemr/openemr:8.2.0\n",
        );

        $issues = (new VersionsRegistryLinter($this->tmpDir, $this->registryPath))->lint();

        self::assertNotEmpty($issues);
        $first = $issues[0];
        self::assertSame('docker/openemr/8.2.0/README.md', $first->path);
        self::assertSame(3, $first->line);
        self::assertSame('docker_image_tag', $first->patternKind);
        self::assertSame('8.2.0', $first->matched);
    }

    private function seedBaseRegistry(): void
    {
        $this->writeFileAndAdd('tools/release/versions.yml', <<<'YAML'
        version: 1

        slots:
          current: { minor: "8.0", full: "8.0.0", branch: "rel-800", docker_dir: "8.0.0" }
          next:    { minor: "8.1", full: "8.1.0", branch: "rel-810", docker_dir: "8.1.0" }
          dev:     { minor: "8.1", full: "8.1.1", branch: "master",  docker_dir: "8.1.1" }

        files: []

        excludes: []
        YAML);
    }

    /**
     * @param list<array{path: string, slot: string}>  $files
     * @param list<array{path: string, reason: string}> $excludes
     */
    private function updateRegistry(array $files, array $excludes): void
    {
        $yaml = "version: 1\n\nslots:\n"
            . "  current: { minor: \"8.0\", full: \"8.0.0\", branch: \"rel-800\", docker_dir: \"8.0.0\" }\n"
            . "  next:    { minor: \"8.1\", full: \"8.1.0\", branch: \"rel-810\", docker_dir: \"8.1.0\" }\n"
            . "  dev:     { minor: \"8.1\", full: \"8.1.1\", branch: \"master\",  docker_dir: \"8.1.1\" }\n\n";

        $yaml .= "files:\n";
        if ($files === []) {
            $yaml .= "  []\n";
        } else {
            foreach ($files as $f) {
                $yaml .= sprintf("  - { path: %s, slot: %s }\n", $f['path'], $f['slot']);
            }
        }
        $yaml .= "\nexcludes:\n";
        if ($excludes === []) {
            $yaml .= "  []\n";
        } else {
            foreach ($excludes as $e) {
                $yaml .= sprintf("  - { path: %s, reason: \"%s\" }\n", $e['path'], $e['reason']);
            }
        }
        file_put_contents($this->registryPath, $yaml);
    }

    private function writeFileAndAdd(string $relPath, string $contents): void
    {
        $absPath = $this->tmpDir . '/' . $relPath;
        $dir = dirname($absPath);
        if (!is_dir($dir) && !mkdir($dir, 0700, true)) {
            throw new \RuntimeException("Failed to mkdir: {$dir}");
        }
        file_put_contents($absPath, $contents);
        $this->git(['add', $relPath]);
    }

    /**
     * @param list<string> $args
     */
    private function git(array $args): void
    {
        $process = new Process(['git', ...$args], $this->tmpDir, [
            'GIT_CONFIG_GLOBAL' => '/dev/null',
            'GIT_CONFIG_SYSTEM' => '/dev/null',
            'GIT_AUTHOR_NAME' => 'Test',
            'GIT_AUTHOR_EMAIL' => 'test@example.test',
            'GIT_COMMITTER_NAME' => 'Test',
            'GIT_COMMITTER_EMAIL' => 'test@example.test',
        ]);
        $process->mustRun();
    }

    private function removeRecursive(string $path): void
    {
        if (!is_dir($path)) {
            if (is_file($path) || is_link($path)) {
                unlink($path);
            }
            return;
        }
        $iterator = new \RecursiveIteratorIterator(
            new \RecursiveDirectoryIterator($path, \FilesystemIterator::SKIP_DOTS),
            \RecursiveIteratorIterator::CHILD_FIRST,
        );
        /** @var \SplFileInfo $entry */
        foreach ($iterator as $entry) {
            $entryPath = $entry->getPathname();
            if ($entry->isDir() && !$entry->isLink()) {
                rmdir($entryPath);
            } else {
                unlink($entryPath);
            }
        }
        rmdir($path);
    }
}
