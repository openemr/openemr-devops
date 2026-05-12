<?php

/**
 * Identifier for the three sibling release PRs orchestrated by ship-release.
 *
 * @package   openemr-devops
 * @link      https://www.open-emr.org
 * @author    Michael A. Smith <michael@opencoreemr.com>
 * @copyright Copyright (c) 2026 OpenCoreEMR Inc.
 * @license   https://github.com/openemr/openemr-devops/blob/master/LICENSE GNU General Public License 3
 */

declare(strict_types=1);

namespace OpenEMR\Release;

enum RoleLabel: string
{
    case Infra = 'infra';
    case Conductor = 'conductor';
    case Docs = 'docs';
}
