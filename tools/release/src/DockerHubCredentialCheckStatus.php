<?php

/**
 * @package   openemr-devops
 * @link      https://www.open-emr.org
 * @author    Michael A. Smith <michael@opencoreemr.com>
 * @copyright Copyright (c) 2026 OpenCoreEMR Inc.
 * @license   https://github.com/openemr/openemr-devops/blob/master/LICENSE GNU General Public License 3
 */

declare(strict_types=1);

namespace OpenEMR\Release;

enum DockerHubCredentialCheckStatus: string
{
    case OK = 'ok';
    case INVALID_CREDENTIAL = 'invalid_credential';
    case INSUFFICIENT_SCOPE = 'insufficient_scope';
    case UNEXPECTED_RESPONSE = 'unexpected_response';
    case NETWORK_ERROR = 'network_error';
}
