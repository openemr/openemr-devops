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

use OpenEMR\Release\SlotRotator;
use PHPUnit\Framework\TestCase;

final class SlotRotatorTest extends TestCase
{
    private string $tmpDir = '';
    private string $registryPath = '';

    protected function setUp(): void
    {
        $this->tmpDir = sys_get_temp_dir() . '/openemr-slot-rotator-' . bin2hex(random_bytes(8));
        if (!mkdir($this->tmpDir, 0700, true)) {
            throw new \RuntimeException('Failed to create tmp dir: ' . $this->tmpDir);
        }
        $this->seedFixtures();
        $this->registryPath = $this->tmpDir . '/tools/release/versions.yml';
    }

    protected function tearDown(): void
    {
        $this->removeRecursive($this->tmpDir);
    }

    public function testRotationAdvancesNextSlotAndRewritesPinFiles(): void
    {
        $rotator = new SlotRotator($this->tmpDir, $this->registryPath);

        $result = $rotator->rotate([
            'next' => [
                'minor' => '8.2',
                'full' => '8.2.0',
                'branch' => 'rel-820',
                'docker_dir' => '8.2.0',
            ],
        ]);

        self::assertFalse($result->isNoOp(), 'Rotation should have changed files');
        self::assertContains('docker/openemr/8.1.0/Dockerfile', $result->changedFiles);
        self::assertContains('docker/openemr/next', $result->changedFiles);
        self::assertContains('docker/openemr/OVERVIEW.md', $result->changedFiles);
        self::assertContains('tools/release/versions.yml', $result->changedFiles);

        $dockerfile = (string) file_get_contents($this->tmpDir . '/docker/openemr/8.1.0/Dockerfile');
        self::assertStringContainsString('ARG OPENEMR_VERSION=rel-820', $dockerfile);
        self::assertStringNotContainsString('rel-810', $dockerfile);

        self::assertSame(
            '8.2.0',
            readlink($this->tmpDir . '/docker/openemr/next'),
            'next symlink follows the slot docker_dir',
        );

        $registry = (string) file_get_contents($this->registryPath);
        self::assertStringContainsString('full: "8.2.0"', $registry);
        self::assertStringContainsString('branch: "rel-820"', $registry);
    }

    public function testRotationRepointsSlotSymlinkAndLeavesOtherSlotsAlone(): void
    {
        $rotator = new SlotRotator($this->tmpDir, $this->registryPath);

        $result = $rotator->rotate([
            'next' => [
                'minor' => '8.2',
                'full' => '8.2.0',
                'branch' => 'rel-820',
                'docker_dir' => '8.2.0',
            ],
        ]);

        self::assertContains('docker/openemr/next', $result->changedFiles);
        self::assertSame(
            ['before' => '8.1.0', 'after' => '8.2.0'],
            $result->snapshots['docker/openemr/next'],
        );

        $next = $this->tmpDir . '/docker/openemr/next';
        self::assertTrue(is_link($next), 'next must remain a symlink, not a regular file');
        self::assertSame('8.2.0', readlink($next));

        self::assertSame('8.0.0', readlink($this->tmpDir . '/docker/openemr/current'));
        self::assertSame('8.1.1', readlink($this->tmpDir . '/docker/openemr/dev'));
    }

    public function testSymlinkRepointIsIdempotent(): void
    {
        $rotator = new SlotRotator($this->tmpDir, $this->registryPath);
        $newNext = [
            'minor' => '8.2',
            'full' => '8.2.0',
            'branch' => 'rel-820',
            'docker_dir' => '8.2.0',
        ];

        $rotator->rotate(['next' => $newNext]);
        $second = $rotator->rotate(['next' => $newNext]);

        self::assertTrue($second->isNoOp(), 'Re-running with the same target must not touch the symlink');
        self::assertSame('8.2.0', readlink($this->tmpDir . '/docker/openemr/next'));
    }

    public function testSymlinkUntouchedWhenDockerDirUnchanged(): void
    {
        $rotator = new SlotRotator($this->tmpDir, $this->registryPath);

        // Move only the branch (an `edge`-style override); docker_dir stays put.
        $result = $rotator->rotate([
            'dev' => ['branch' => 'rel-820'],
        ]);

        self::assertNotContains('docker/openemr/dev', $result->changedFiles);
        self::assertSame('8.1.1', readlink($this->tmpDir . '/docker/openemr/dev'));
    }

    public function testDryRunDoesNotRepointSymlink(): void
    {
        $rotator = new SlotRotator($this->tmpDir, $this->registryPath);

        $result = $rotator->rotate(
            [
                'next' => [
                    'minor' => '8.2',
                    'full' => '8.2.0',
                    'branch' => 'rel-820',
                    'docker_dir' => '8.2.0',
                ],
            ],
            true,
        );

        self::assertArrayHasKey('docker/openemr/next', $result->snapshots);
        self::assertSame(
            '8.1.0',
            readlink($this->tmpDir . '/docker/openemr/next'),
            'dry-run must not move the symlink',
        );
    }

    public function testRotationIsIdempotent(): void
    {
        $rotator = new SlotRotator($this->tmpDir, $this->registryPath);
        $newNext = [
            'minor' => '8.2',
            'full' => '8.2.0',
            'branch' => 'rel-820',
            'docker_dir' => '8.2.0',
        ];

        $first = $rotator->rotate(['next' => $newNext]);
        self::assertFalse($first->isNoOp(), 'First rotation should have changed files');

        $second = $rotator->rotate(['next' => $newNext]);
        self::assertTrue($second->isNoOp(), 'Second rotation with same args should be a no-op');
        self::assertSame([], $second->changedFiles);
    }

    public function testNoOpDispatchAtCurrentSlotValuesChangesNothing(): void
    {
        $rotator = new SlotRotator($this->tmpDir, $this->registryPath);

        $result = $rotator->rotate([
            'next' => [
                'minor' => '8.1',
                'full' => '8.1.0',
                'branch' => 'rel-810',
                'docker_dir' => '8.1.0',
            ],
        ]);

        self::assertTrue($result->isNoOp(), 'Dispatching with the existing slot values must be a no-op');
    }

    public function testForwardRotationDoesNotCorruptOtherSlots(): void
    {
        $rotator = new SlotRotator($this->tmpDir, $this->registryPath);

        $rotator->rotate([
            'next' => [
                'minor' => '8.2',
                'full' => '8.2.0',
                'branch' => 'rel-820',
                'docker_dir' => '8.2.0',
            ],
        ]);

        $currentPath = $this->tmpDir . '/docker/openemr/8.0.0/Dockerfile';
        $current = (string) file_get_contents($currentPath);
        self::assertStringContainsString('--branch rel-800', $current, 'current slot Dockerfile must not change');

        $devPath = $this->tmpDir . '/docker/openemr/8.1.1/Dockerfile';
        $dev = (string) file_get_contents($devPath);
        self::assertStringContainsString('ARG OPENEMR_VERSION=master', $dev, 'dev slot Dockerfile must not change');
    }

    public function testDryRunReturnsDiffWithoutWritingFiles(): void
    {
        $rotator = new SlotRotator($this->tmpDir, $this->registryPath);
        $before = (string) file_get_contents($this->tmpDir . '/docker/openemr/8.1.0/Dockerfile');

        $result = $rotator->rotate(
            [
                'next' => [
                    'minor' => '8.2',
                    'full' => '8.2.0',
                    'branch' => 'rel-820',
                    'docker_dir' => '8.2.0',
                ],
            ],
            true,
        );

        self::assertFalse($result->isNoOp());
        $after = (string) file_get_contents($this->tmpDir . '/docker/openemr/8.1.0/Dockerfile');
        self::assertSame($before, $after, 'dry-run must not touch the file');
        self::assertArrayHasKey('docker/openemr/8.1.0/Dockerfile', $result->snapshots);
    }

    public function testUnknownSlotThrows(): void
    {
        $rotator = new SlotRotator($this->tmpDir, $this->registryPath);

        $this->expectException(\InvalidArgumentException::class);
        $rotator->rotate(['nightly' => ['minor' => '9.0']]);
    }

    public function testMissingPinFileThrows(): void
    {
        unlink($this->tmpDir . '/docker/openemr/8.1.0/Dockerfile');
        $rotator = new SlotRotator($this->tmpDir, $this->registryPath);

        $this->expectException(\RuntimeException::class);
        $this->expectExceptionMessageMatches('/Registry references missing file/');

        $rotator->rotate([
            'next' => [
                'minor' => '8.2',
                'full' => '8.2.0',
                'branch' => 'rel-820',
                'docker_dir' => '8.2.0',
            ],
        ]);
    }

    public function testReplacementAvoidsPartialVersionMatches(): void
    {
        file_put_contents(
            $this->tmpDir . '/docker/openemr/8.1.0/Dockerfile',
            "FROM alpine:3.21\nARG OPENEMR_VERSION=rel-810\n# version-like-but-not: 8.1.10 should stay\n",
        );
        $rotator = new SlotRotator($this->tmpDir, $this->registryPath);

        $rotator->rotate([
            'next' => [
                'minor' => '8.2',
                'full' => '8.2.0',
                'branch' => 'rel-820',
                'docker_dir' => '8.2.0',
            ],
        ]);

        $after = (string) file_get_contents($this->tmpDir . '/docker/openemr/8.1.0/Dockerfile');
        self::assertStringContainsString('8.1.10', $after, '8.1 inside 8.1.10 must NOT be rewritten');
        self::assertStringContainsString('rel-820', $after);
    }

    public function testRotationLeavesScriptdirShellcheckDirectiveIntact(): void
    {
        $rotator = new SlotRotator($this->tmpDir, $this->registryPath);

        $rotator->rotate([
            'current' => [
                'minor' => '8.2',
                'full' => '8.2.0',
                'branch' => 'rel-820',
                'docker_dir' => '8.2.0',
            ],
        ]);

        $script = (string) file_get_contents($this->tmpDir . '/docker/openemr/8.0.0/openemr.sh');
        self::assertStringContainsString(
            '# shellcheck source=SCRIPTDIR/env.stub',
            $script,
            'self-referential SCRIPTDIR directive must survive rotation byte-for-byte',
        );
        self::assertStringNotContainsString(
            'source=docker/openemr',
            $script,
            'rotation must never inject a version path into a shellcheck source directive',
        );
        self::assertStringContainsString(
            "echo 'init for docker/openemr/8.2.0'",
            $script,
            'sanity: the genuine rotating docker_dir token should have been rewritten',
        );
    }

    private function seedFixtures(): void
    {
        $this->writeFile('tools/release/versions.yml', <<<'YAML'
        version: 1

        slots:
          current:
            minor: "8.0"
            full: "8.0.0"
            branch: "rel-800"
            docker_dir: "8.0.0"
          next:
            minor: "8.1"
            full: "8.1.0"
            branch: "rel-810"
            docker_dir: "8.1.0"
          dev:
            minor: "8.1"
            full: "8.1.1"
            branch: "master"
            docker_dir: "8.1.1"

        files:
          - path: docker/openemr/8.0.0/Dockerfile
            slot: current
            kinds: [docker_clone_branch]
          - path: docker/openemr/8.0.0/openemr.sh
            slot: current
            kinds: [docker_dir_ref]
          - path: docker/openemr/8.1.0/Dockerfile
            slot: next
            kinds: [docker_arg_branch]
          - path: docker/openemr/8.1.1/Dockerfile
            slot: dev
            kinds: [docker_arg_branch]
          - path: docker/openemr/OVERVIEW.md
            slot: all
            kinds: [overview_table]

        excludes: []
        YAML);

        $this->writeFile(
            'docker/openemr/8.0.0/Dockerfile',
            "FROM alpine:3.21\nRUN git clone https://github.com/openemr/openemr.git --branch rel-800 --depth 1\n",
        );
        $this->writeFile('docker/openemr/8.1.0/Dockerfile', "FROM alpine:3.21\nARG OPENEMR_VERSION=rel-810\n");
        $this->writeFile('docker/openemr/8.1.1/Dockerfile', "FROM alpine:3.21\nARG OPENEMR_VERSION=master\n");

        // In-container init script for the current slot. It carries a rotating
        // docker_dir token (the path in the echo line) alongside a
        // self-referential `SCRIPTDIR` shellcheck directive that must never be
        // rewritten.
        $this->writeFile(
            'docker/openemr/8.0.0/openemr.sh',
            "#!/bin/sh\nset -e\n"
            . "# shellcheck source=SCRIPTDIR/env.stub\n. /root/env.stub\n"
            . "echo 'init for docker/openemr/8.0.0'\n",
        );

        $this->writeFile(
            'docker/openemr/OVERVIEW.md',
            "| 8.0.0 | latest |\n| 8.1.0 | next |\n| 8.1.1 | dev |\n",
        );

        // Slot symlinks: the source of truth the consolidated build workflow
        // resolves each slot's version from. Rotation re-points these (see
        // SlotRotator::repointSlotSymlink). Relative targets, as in the repo.
        symlink('8.0.0', $this->tmpDir . '/docker/openemr/current');
        symlink('8.1.0', $this->tmpDir . '/docker/openemr/next');
        symlink('8.1.1', $this->tmpDir . '/docker/openemr/dev');
    }

    private function writeFile(string $relPath, string $contents): void
    {
        $absPath = $this->tmpDir . '/' . $relPath;
        $dir = dirname($absPath);
        if (!is_dir($dir) && !mkdir($dir, 0700, true)) {
            throw new \RuntimeException("Failed to mkdir: {$dir}");
        }
        file_put_contents($absPath, $contents);
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
