<?php

/**
 * Result of running SlotRotator: the set of files whose contents changed
 * (relative to the repo root) and per-file before/after snapshots so callers
 * can render a diff.
 *
 * @package   openemr-devops
 * @link      https://www.open-emr.org
 * @author    Michael A. Smith <michael@opencoreemr.com>
 * @copyright Copyright (c) 2026 OpenCoreEMR Inc.
 * @license   https://github.com/openemr/openemr-devops/blob/master/LICENSE GNU General Public License 3
 */

declare(strict_types=1);

namespace OpenEMR\Release;

final readonly class SlotRotationResult
{
    /**
     * @param list<string>                                $changedFiles  paths relative to repo root
     * @param array<string, array{before: string, after: string}> $snapshots keyed by relative path
     */
    public function __construct(
        public array $changedFiles,
        public array $snapshots,
    ) {
    }

    public function isNoOp(): bool
    {
        return $this->changedFiles === [];
    }
}
