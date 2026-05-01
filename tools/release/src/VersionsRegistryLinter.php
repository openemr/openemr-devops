<?php

/**
 * Lint the repo against the versions.yml registry: every file containing an
 * OpenEMR version pin must be listed in `files:` (under rotation) or
 * `excludes:` (with a reason for opting out). This catches the case where a
 * contributor adds a new file with a version reference and forgets to update
 * the registry — without lint, the rotation workflow would silently miss it.
 *
 * Patterns scanned (all OpenEMR-specific, to keep false positives down so
 * `excludes:` doesn't have to enumerate every Alpine/PHP/MySQL pin in the
 * repo):
 *
 *   - `openemr/openemr:<tag>`       Docker image reference
 *   - `OPENEMR_VERSION=<value>`     build arg
 *   - `--branch <rel-NNN>`          git clone branch
 *   - `rel-NNN`                     bare release-branch reference
 *   - `docker/openemr/<dir>`        path reference
 *
 * @package   openemr-devops
 * @link      https://www.open-emr.org
 * @author    Michael A. Smith <michael@opencoreemr.com>
 * @copyright Copyright (c) 2026 OpenCoreEMR Inc.
 * @license   https://github.com/openemr/openemr-devops/blob/master/LICENSE GNU General Public License 3
 */

declare(strict_types=1);

namespace OpenEMR\Release;

use Symfony\Component\Process\Process;
use Symfony\Component\Yaml\Yaml;

final readonly class VersionsRegistryLinter
{
    /**
     * Patterns that signal an OpenEMR version pin. Keys are kind labels for
     * reporting; values are PCRE patterns where capture group 1 is the matched
     * value to surface in the lint message.
     */
    private const PATTERNS = [
        'docker_image_tag' => '#openemr/openemr:([\w.-]+)#',
        'build_arg' => '/OPENEMR_VERSION=([\w.-]+)/',
        'clone_branch' => '/--branch\s+(rel-\d+)/',
        'rel_branch_ref' => '/(?<![\w-])(rel-\d{2,4})(?![\w])/',
        'docker_dir_ref' => '#(?<![\w/])docker/openemr/([\d.]+)(?![\w])#',
    ];

    public function __construct(
        private string $repoDir,
        private string $registryPath,
    ) {
    }

    /**
     * @return list<LintIssue>
     */
    public function lint(): array
    {
        $registry = $this->loadRegistry();
        $covered = array_column($registry['files'], 'path');
        $excluded = array_column($registry['excludes'], 'path');

        $registryRel = $this->relativeRegistryPath();
        $issues = [];
        foreach ($this->trackedFiles() as $relPath) {
            if ($relPath === $registryRel) {
                continue;
            }
            if (in_array($relPath, $covered, true)) {
                continue;
            }
            if ($this->isExcluded($relPath, $excluded)) {
                continue;
            }
            foreach ($this->scanFile($relPath) as $issue) {
                $issues[] = $issue;
            }
        }
        return $issues;
    }

    /**
     * @return array{files: list<array{path: string}>, excludes: list<array{path: string}>}
     */
    private function loadRegistry(): array
    {
        $parsed = Yaml::parseFile($this->registryPath);
        if (!is_array($parsed)) {
            throw new \RuntimeException("Registry malformed: {$this->registryPath}");
        }
        $files = $parsed['files'] ?? [];
        $excludes = $parsed['excludes'] ?? [];
        if (!is_array($files) || !is_array($excludes)) {
            throw new \RuntimeException("Registry files/excludes must be lists: {$this->registryPath}");
        }
        /** @var array{files: list<array{path: string}>, excludes: list<array{path: string}>} $out */
        $out = ['files' => array_values($files), 'excludes' => array_values($excludes)];
        return $out;
    }

    /**
     * @return list<string>
     */
    private function trackedFiles(): array
    {
        $process = new Process(['git', 'ls-files', '-z'], $this->repoDir);
        $process->mustRun();
        $raw = $process->getOutput();
        if ($raw === '') {
            return [];
        }
        return array_values(array_filter(
            explode("\0", $raw),
            static fn(string $s): bool => $s !== '',
        ));
    }

    /**
     * @param list<string> $excluded
     */
    private function isExcluded(string $path, array $excluded): bool
    {
        foreach ($excluded as $entry) {
            if ($path === $entry) {
                return true;
            }
            if (str_starts_with($path, $entry . '/')) {
                return true;
            }
        }
        return false;
    }

    /**
     * @return list<LintIssue>
     */
    private function scanFile(string $relPath): array
    {
        $absPath = $this->repoDir . '/' . $relPath;
        if (!is_file($absPath)) {
            return [];
        }
        if ($this->looksBinary($relPath)) {
            return [];
        }
        $content = (string) file_get_contents($absPath);
        if ($content === '') {
            return [];
        }

        $issues = [];
        $lines = explode("\n", $content);
        foreach ($lines as $idx => $line) {
            foreach (self::PATTERNS as $kind => $pattern) {
                if (preg_match_all($pattern, $line, $matches, PREG_SET_ORDER) === 0) {
                    continue;
                }
                foreach ($matches as $m) {
                    $issues[] = new LintIssue($relPath, $idx + 1, $line, $m[1], $kind);
                }
            }
        }
        return $issues;
    }

    private function looksBinary(string $relPath): bool
    {
        return preg_match('/\.(png|jpe?g|gif|ico|woff2?|ttf|eot|pdf|zip|gz|bz2|tar|jar|class)$/i', $relPath) === 1;
    }

    private function relativeRegistryPath(): string
    {
        $prefix = rtrim($this->repoDir, '/') . '/';
        if (str_starts_with($this->registryPath, $prefix)) {
            return substr($this->registryPath, strlen($prefix));
        }
        return $this->registryPath;
    }
}
