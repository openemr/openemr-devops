<?php

/**
 * One drift finding from VersionsRegistryLinter: a file that contains an
 * OpenEMR version pin but is neither listed in `files:` nor `excludes:`
 * in versions.yml.
 *
 * @package   openemr-devops
 * @link      https://www.open-emr.org
 * @author    Michael A. Smith <michael@opencoreemr.com>
 * @copyright Copyright (c) 2026 OpenCoreEMR Inc.
 * @license   https://github.com/openemr/openemr-devops/blob/master/LICENSE GNU General Public License 3
 */

declare(strict_types=1);

namespace OpenEMR\Release;

final readonly class LintIssue
{
    public function __construct(
        public string $path,
        public int $line,
        public string $lineContent,
        public string $matched,
        public string $patternKind,
    ) {
    }
}
