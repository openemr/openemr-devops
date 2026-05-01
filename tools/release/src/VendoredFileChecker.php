<?php

/**
 * Compare a consumer repo's vendored copies of cross-repo contracts against
 * the canonical sources in this repo. Used by CI in consumer repos
 * (openemr/openemr, openemr/website-openemr) to catch silent contract drift.
 *
 * Layout assumption: the consumer mirrors the canonical relative paths under
 * its vendored dir. A consumer that vendors to `vendored/openemr-devops/`
 * therefore has `vendored/openemr-devops/contracts/dispatch.schema.json` and
 * `vendored/openemr-devops/src/TagVerifier.php`.
 *
 * Equivalence is byte-for-byte (sha256). The vendored set is intentionally
 * small — it covers only what consumers need to validate dispatch payloads
 * and verify release tags without depending on this repo's autoloader.
 *
 * @package   openemr-devops
 * @link      https://www.open-emr.org
 * @author    Michael A. Smith <michael@opencoreemr.com>
 * @copyright Copyright (c) 2026 OpenCoreEMR Inc.
 * @license   https://github.com/openemr/openemr-devops/blob/master/LICENSE GNU General Public License 3
 */

declare(strict_types=1);

namespace OpenEMR\Release;

final readonly class VendoredFileChecker
{
    /**
     * Files consumers must vendor. Keep this list tight — every entry is an
     * obligation on every consumer repo's CI.
     */
    public const VENDORED_PATHS = [
        'contracts/dispatch.schema.json',
        'src/TagVerifier.php',
        'src/TagVerificationResult.php',
    ];

    public function __construct(
        private string $canonicalRoot,
        private string $consumerDir,
    ) {
    }

    /**
     * @return list<VendoredDriftIssue>
     */
    public function check(): array
    {
        $issues = [];
        foreach (self::VENDORED_PATHS as $rel) {
            $canonicalAbs = $this->canonicalRoot . '/' . $rel;
            $consumerAbs = $this->consumerDir . '/' . $rel;

            if (!is_file($canonicalAbs)) {
                $issues[] = new VendoredDriftIssue(
                    $rel,
                    'missing_canonical',
                    'Canonical file not found: ' . $canonicalAbs,
                );
                continue;
            }
            if (!is_file($consumerAbs)) {
                $issues[] = new VendoredDriftIssue(
                    $rel,
                    'missing_consumer',
                    'Consumer copy missing — vendor it from canonical at ' . $canonicalAbs,
                );
                continue;
            }
            if (hash_file('sha256', $canonicalAbs) !== hash_file('sha256', $consumerAbs)) {
                $issues[] = new VendoredDriftIssue(
                    $rel,
                    'drift',
                    'Consumer copy differs from canonical — re-vendor from ' . $canonicalAbs,
                );
            }
        }
        return $issues;
    }
}
