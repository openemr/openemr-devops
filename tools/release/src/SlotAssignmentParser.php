<?php

/**
 * Translate CLI slot arguments into the full registry slot definition shape.
 *
 * Accepted forms per slot:
 *   - "8.1"                      → minor=8.1, full=8.1.0, branch=rel-810, docker_dir=8.1.0
 *   - "edge"                     → branch=master only (used for the dev slot)
 *   - "key=value,key=value,..."  → explicit override of an arbitrary subset
 *
 * @package   openemr-devops
 * @link      https://www.open-emr.org
 * @author    Michael A. Smith <michael@opencoreemr.com>
 * @copyright Copyright (c) 2026 OpenCoreEMR Inc.
 * @license   https://github.com/openemr/openemr-devops/blob/master/LICENSE GNU General Public License 3
 */

declare(strict_types=1);

namespace OpenEMR\Release;

final class SlotAssignmentParser
{
    /**
     * @return array<string, string>
     */
    public function parse(string $slot, string $raw): array
    {
        if (str_contains($raw, '=')) {
            return $this->parseKeyValue($raw);
        }
        if ($raw === 'edge') {
            return ['branch' => 'master'];
        }
        if (preg_match('/^(\d+)\.(\d+)$/', $raw, $m) !== 1) {
            throw new \InvalidArgumentException("Slot {$slot}: expected MAJOR.MINOR or 'edge', got: {$raw}");
        }
        $major = $m[1];
        $minorPart = $m[2];
        return [
            'minor' => "{$major}.{$minorPart}",
            'full' => "{$major}.{$minorPart}.0",
            'branch' => "rel-{$major}{$minorPart}0",
            'docker_dir' => "{$major}.{$minorPart}.0",
        ];
    }

    /**
     * Translate a `repository_dispatch` envelope (per dispatch.schema.json)
     * into the `--current=… --next=… --dev=…` shape that bin/rotate.php
     * wants. Returns a map keyed by slot name with bare CLI values
     * (MAJOR.MINOR strings or 'edge'); the workflow then re-invokes the
     * regular `parse()` path for each entry.
     *
     * Mapping:
     *   - openemr-rel-cut, openemr-rel-update → next=<minor of data.version>
     *   - openemr-tag                         → current=<minor of data.version>
     *   - openemr-docs-binaries               → no slot move (consumer event)
     *
     * @param array<string, mixed> $envelope
     * @return array<string, string>
     */
    public function fromDispatchPayload(string $eventType, array $envelope): array
    {
        $data = $envelope['data'] ?? null;
        if (!is_array($data)) {
            throw new \InvalidArgumentException("Dispatch envelope missing 'data' object");
        }
        if ($eventType === 'openemr-docs-binaries') {
            return [];
        }

        $version = $data['version'] ?? null;
        if (!is_string($version) || preg_match('/^(\d+)\.(\d+)\.\d+$/', $version, $m) !== 1) {
            throw new \InvalidArgumentException(
                "Dispatch '{$eventType}' missing or malformed data.version (expected MAJOR.MINOR.PATCH)",
            );
        }
        $minor = "{$m[1]}.{$m[2]}";

        return match ($eventType) {
            'openemr-rel-cut', 'openemr-rel-update' => ['next' => $minor],
            'openemr-tag' => ['current' => $minor],
            default => throw new \InvalidArgumentException("Unsupported dispatch event type: {$eventType}"),
        };
    }

    /**
     * @return array<string, string>
     */
    private function parseKeyValue(string $raw): array
    {
        $out = [];
        foreach (explode(',', $raw) as $pair) {
            [$key, $value] = array_pad(explode('=', $pair, 2), 2, '');
            $out[trim($key)] = trim($value);
        }
        return $out;
    }
}
