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

use OpenEMR\Release\VendoredDriftIssue;
use OpenEMR\Release\VendoredFileChecker;
use PHPUnit\Framework\TestCase;

final class VendoredFileCheckerTest extends TestCase
{
    private string $canonicalRoot = '';
    private string $consumerDir = '';

    protected function setUp(): void
    {
        $this->canonicalRoot = sys_get_temp_dir() . '/openemr-vendored-canon-' . bin2hex(random_bytes(8));
        $this->consumerDir = sys_get_temp_dir() . '/openemr-vendored-consumer-' . bin2hex(random_bytes(8));
        if (!mkdir($this->canonicalRoot, 0700, true) || !mkdir($this->consumerDir, 0700, true)) {
            throw new \RuntimeException('Failed to create tmp dirs');
        }
        foreach (VendoredFileChecker::VENDORED_PATHS as $rel) {
            $this->writeFile($this->canonicalRoot, $rel, "canonical:{$rel}\n");
        }
    }

    protected function tearDown(): void
    {
        $this->removeRecursive($this->canonicalRoot);
        $this->removeRecursive($this->consumerDir);
    }

    public function testMatchingCopiesProduceNoIssues(): void
    {
        foreach (VendoredFileChecker::VENDORED_PATHS as $rel) {
            $this->writeFile($this->consumerDir, $rel, "canonical:{$rel}\n");
        }

        $issues = (new VendoredFileChecker($this->canonicalRoot, $this->consumerDir))->check();

        self::assertSame([], $issues);
    }

    public function testDriftedCopyIsFlagged(): void
    {
        foreach (VendoredFileChecker::VENDORED_PATHS as $rel) {
            $this->writeFile($this->consumerDir, $rel, "canonical:{$rel}\n");
        }
        $this->writeFile($this->consumerDir, 'src/TagVerifier.php', "stale-content\n");

        $issues = (new VendoredFileChecker($this->canonicalRoot, $this->consumerDir))->check();

        self::assertCount(1, $issues);
        self::assertSame('src/TagVerifier.php', $issues[0]->relativePath);
        self::assertSame('drift', $issues[0]->kind);
    }

    public function testMissingConsumerCopyIsFlagged(): void
    {
        $copy = VendoredFileChecker::VENDORED_PATHS;
        array_pop($copy);
        foreach ($copy as $rel) {
            $this->writeFile($this->consumerDir, $rel, "canonical:{$rel}\n");
        }

        $issues = (new VendoredFileChecker($this->canonicalRoot, $this->consumerDir))->check();

        self::assertCount(1, $issues);
        self::assertSame('missing_consumer', $issues[0]->kind);
    }

    public function testMissingCanonicalIsFlagged(): void
    {
        unlink($this->canonicalRoot . '/contracts/dispatch.schema.json');
        foreach (VendoredFileChecker::VENDORED_PATHS as $rel) {
            $this->writeFile($this->consumerDir, $rel, "canonical:{$rel}\n");
        }

        $issues = (new VendoredFileChecker($this->canonicalRoot, $this->consumerDir))->check();

        self::assertCount(1, $issues);
        self::assertSame('contracts/dispatch.schema.json', $issues[0]->relativePath);
        self::assertSame('missing_canonical', $issues[0]->kind);
    }

    public function testMultipleDriftKindsReportedTogether(): void
    {
        $this->writeFile($this->consumerDir, 'contracts/dispatch.schema.json', "stale\n");

        $issues = (new VendoredFileChecker($this->canonicalRoot, $this->consumerDir))->check();

        self::assertCount(count(VendoredFileChecker::VENDORED_PATHS), $issues);
        $kinds = array_map(static fn(VendoredDriftIssue $i): string => $i->kind, $issues);
        self::assertContains('drift', $kinds);
        self::assertContains('missing_consumer', $kinds);
    }

    public function testCanonicalListContainsContractAndTagFiles(): void
    {
        self::assertContains('contracts/dispatch.schema.json', VendoredFileChecker::VENDORED_PATHS);
        self::assertContains('src/TagVerifier.php', VendoredFileChecker::VENDORED_PATHS);
        self::assertContains('src/TagVerificationResult.php', VendoredFileChecker::VENDORED_PATHS);
    }

    private function writeFile(string $root, string $rel, string $contents): void
    {
        $abs = $root . '/' . $rel;
        $dir = dirname($abs);
        if (!is_dir($dir) && !mkdir($dir, 0700, true)) {
            throw new \RuntimeException("Failed to mkdir: {$dir}");
        }
        file_put_contents($abs, $contents);
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
