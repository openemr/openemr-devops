<?php

/**
 * Apply slot reassignments to the OpenEMR version registry (versions.yml)
 * and to every file the registry says holds a pin for the affected slot.
 *
 * Idempotence is the load-bearing property here: the same arguments applied
 * twice produce zero changes the second pass. The release workflow re-fires
 * on every dispatch (sometimes redundantly), so a non-idempotent rotator
 * would churn the rotation PR.
 *
 * The rotation strategy is value substitution scoped by slot. For a slot
 * whose values change, every (oldValue → newValue) pair derived from the
 * slot definition is rewritten in the slot's pin files, with regex
 * negative-lookarounds preventing partial matches across version boundaries
 * (e.g. "8.1" inside "8.1.0").
 *
 * Additionally, when a slot's docker_dir changes, the slot symlink
 * docker/openemr/<slot> is re-pointed at the new version dir. That symlink is
 * the source of truth the consolidated build workflow (build-openemr.yml)
 * reads to resolve each slot's version, so flipping it is how a rotation moves
 * the build — no version strings live in the workflow itself.
 *
 * @package   openemr-devops
 * @link      https://www.open-emr.org
 * @author    Michael A. Smith <michael@opencoreemr.com>
 * @copyright Copyright (c) 2026 OpenCoreEMR Inc.
 * @license   https://github.com/openemr/openemr-devops/blob/master/LICENSE GNU General Public License 3
 */

declare(strict_types=1);

namespace OpenEMR\Release;

use Symfony\Component\Yaml\Yaml;

final readonly class SlotRotator
{
    public function __construct(
        private string $repoDir,
        private string $registryPath,
    ) {
    }

    /**
     * @param array<string, array<string, string>> $newSlots slot name → key/value map
     *                                                       (e.g. ['next' => ['minor' => '8.2', ...]])
     */
    public function rotate(array $newSlots, bool $dryRun = false): SlotRotationResult
    {
        $registry = $this->loadRegistry();
        $oldSlots = $registry['slots'];

        /** @var list<string> $changed */
        $changed = [];
        /** @var array<string, array{before: string, after: string}> $snapshots */
        $snapshots = [];

        foreach ($newSlots as $slotName => $newDef) {
            if (!isset($oldSlots[$slotName])) {
                throw new \InvalidArgumentException("Unknown slot: {$slotName}");
            }
            $oldDef = $oldSlots[$slotName];
            if ($oldDef === $newDef) {
                continue;
            }

            $replacements = $this->buildReplacements($oldDef, $newDef);
            $affected = $this->filesForSlot($registry['files'], $slotName);

            foreach ($affected as $relPath) {
                $absPath = $this->repoDir . '/' . $relPath;
                if (!is_file($absPath)) {
                    throw new \RuntimeException("Registry references missing file: {$relPath}");
                }
                $before = (string) file_get_contents($absPath);
                $after = $this->applyReplacements($before, $replacements);
                if ($after === $before) {
                    continue;
                }
                if (!$dryRun) {
                    file_put_contents($absPath, $after);
                }
                $changed[] = $relPath;
                $snapshots[$relPath] = ['before' => $before, 'after' => $after];
            }

            $newDockerDir = $newDef['docker_dir'] ?? '';
            if ($newDockerDir !== '' && $newDockerDir !== ($oldDef['docker_dir'] ?? '')) {
                $linkRel = 'docker/openemr/' . $slotName;
                $snapshot = $this->repointSlotSymlink($linkRel, $newDockerDir, $dryRun);
                if ($snapshot !== null) {
                    $changed[] = $linkRel;
                    $snapshots[$linkRel] = $snapshot;
                }
            }
        }

        $registryRel = $this->relativePath($this->registryPath);
        $regBefore = (string) file_get_contents($this->registryPath);
        $regAfter = $this->updateRegistrySlots($regBefore, $newSlots);
        if ($regAfter !== $regBefore) {
            if (!$dryRun) {
                file_put_contents($this->registryPath, $regAfter);
            }
            $changed[] = $registryRel;
            $snapshots[$registryRel] = ['before' => $regBefore, 'after' => $regAfter];
        }

        return new SlotRotationResult($changed, $snapshots);
    }

    /**
     * @return array{
     *     slots: array<string, array<string, string>>,
     *     files: list<array{path: string, slot: string, kinds?: list<string>}>
     * }
     */
    private function loadRegistry(): array
    {
        $parsed = Yaml::parseFile($this->registryPath);
        if (!is_array($parsed) || !isset($parsed['slots'], $parsed['files'])) {
            throw new \RuntimeException("Registry malformed: {$this->registryPath}");
        }
        /** @var array{slots: array<string, array<string, string>>, files: list<array{path: string, slot: string, kinds?: list<string>}>} $parsed */
        return $parsed;
    }

    /**
     * @param array<string, string>                                    $oldDef
     * @param array<string, string>                                    $newDef
     * @return array<string, string> old → new, ordered by old length descending
     */
    private function buildReplacements(array $oldDef, array $newDef): array
    {
        $pairs = [];
        foreach ($newDef as $key => $newValue) {
            if (!isset($oldDef[$key])) {
                continue;
            }
            $oldValue = $oldDef[$key];
            if ($oldValue === '' || $oldValue === $newValue) {
                continue;
            }
            $pairs[$oldValue] = $newValue;
        }
        uksort($pairs, static fn(string $a, string $b): int => strlen($b) - strlen($a));
        return $pairs;
    }

    /**
     * @param list<array{path: string, slot: string, kinds?: list<string>}> $files
     * @return list<string>
     */
    private function filesForSlot(array $files, string $slotName): array
    {
        $matched = [];
        foreach ($files as $entry) {
            if ($entry['slot'] === $slotName || $entry['slot'] === 'all') {
                $matched[] = $entry['path'];
            }
        }
        return $matched;
    }

    /**
     * @param array<string, string> $replacements
     */
    private function applyReplacements(string $content, array $replacements): string
    {
        foreach ($replacements as $old => $new) {
            $pattern = '/(?<![\w.])' . preg_quote($old, '/') . '(?![\w.])/';
            $result = preg_replace($pattern, $new, $content);
            if ($result === null) {
                throw new \RuntimeException("preg_replace failed for pattern: {$pattern}");
            }
            $content = $result;
        }
        return $content;
    }

    /**
     * Update versions.yml in place by rewriting the per-slot scalar lines under
     * the `slots:` block. Walks lines so that comments, blank lines, ordering,
     * and the rest of the file are preserved verbatim.
     *
     * @param array<string, array<string, string>> $newSlots
     */
    private function updateRegistrySlots(string $content, array $newSlots): string
    {
        $lines = explode("\n", $content);
        $inSlotsBlock = false;
        $currentSlot = null;
        foreach ($lines as $i => $line) {
            if (preg_match('/^slots:\s*$/', $line) === 1) {
                $inSlotsBlock = true;
                $currentSlot = null;
                continue;
            }
            if ($inSlotsBlock && preg_match('/^\S/', $line) === 1) {
                $inSlotsBlock = false;
                $currentSlot = null;
                continue;
            }
            if (!$inSlotsBlock) {
                continue;
            }
            if (preg_match('/^  (\w+):\s*$/', $line, $m) === 1) {
                $currentSlot = isset($newSlots[$m[1]]) ? $m[1] : null;
                continue;
            }
            if ($currentSlot === null) {
                continue;
            }
            if (preg_match('/^(    (\w+):\s*)"([^"]*)"(\s*)$/', $line, $m) === 1) {
                $key = $m[2];
                if (!isset($newSlots[$currentSlot][$key])) {
                    continue;
                }
                $lines[$i] = $m[1] . '"' . $newSlots[$currentSlot][$key] . '"' . $m[4];
            }
        }
        return implode("\n", $lines);
    }

    /**
     * Re-point a slot symlink (docker/openemr/<slot>) at the slot's new
     * docker_dir. This is the source of truth the consolidated build workflow
     * reads, replacing the old per-slot build-workflow pin rewriting. Returns a
     * before/after snapshot of the symlink target, or null if already correct
     * (idempotence).
     *
     * @return array{before: string, after: string}|null
     */
    private function repointSlotSymlink(string $linkRel, string $newTarget, bool $dryRun): ?array
    {
        $linkPath = $this->repoDir . '/' . $linkRel;
        $current = null;
        if (is_link($linkPath)) {
            $target = readlink($linkPath);
            $current = $target === false ? null : $target;
        }
        if ($current === $newTarget) {
            return null;
        }
        if (!$dryRun) {
            if (is_link($linkPath) || file_exists($linkPath)) {
                unlink($linkPath);
            }
            if (!symlink($newTarget, $linkPath)) {
                throw new \RuntimeException("Failed to re-point symlink: {$linkRel}");
            }
        }
        return ['before' => $current ?? '', 'after' => $newTarget];
    }

    private function relativePath(string $absPath): string
    {
        $prefix = rtrim($this->repoDir, '/') . '/';
        if (str_starts_with($absPath, $prefix)) {
            return substr($absPath, strlen($prefix));
        }
        return $absPath;
    }
}
