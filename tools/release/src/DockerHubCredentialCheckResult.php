<?php

/**
 * Outcome of a Docker Hub credential check.
 *
 * @package   openemr-devops
 * @link      https://www.open-emr.org
 * @author    Michael A. Smith <michael@opencoreemr.com>
 * @copyright Copyright (c) 2026 OpenCoreEMR Inc.
 * @license   https://github.com/openemr/openemr-devops/blob/master/LICENSE GNU General Public License 3
 */

declare(strict_types=1);

namespace OpenEMR\Release;

final readonly class DockerHubCredentialCheckResult
{
    public function __construct(
        public DockerHubCredentialCheckStatus $status,
        public string $repository,
        public ?int $httpStatus = null,
    ) {
    }

    /**
     * Map raw HTTP responses from Docker Hub's login + repository read +
     * repository write probes to a result. Pure: no network. Tested directly.
     *
     * - $jwt is the token returned by /v2/users/login/ (null on auth failure)
     * - $readStatus is the GET /v2/repositories/<repo>/ status (null if we
     *   never reached that step)
     * - $writeStatus is the no-op PATCH /v2/repositories/<repo>/ status
     *   (null if we couldn't read the existing description and so couldn't
     *   send a no-op write)
     */
    public static function interpret(
        string $repository,
        ?string $jwt,
        ?int $readStatus,
        ?int $writeStatus,
    ): self {
        if (in_array($jwt, [null, '', 'null'], true)) {
            return new self(DockerHubCredentialCheckStatus::INVALID_CREDENTIAL, $repository);
        }
        if ($readStatus !== 200) {
            return new self(DockerHubCredentialCheckStatus::INSUFFICIENT_SCOPE, $repository, $readStatus);
        }
        return match ($writeStatus) {
            200 => new self(DockerHubCredentialCheckStatus::OK, $repository, 200),
            403 => new self(DockerHubCredentialCheckStatus::INSUFFICIENT_SCOPE, $repository, 403),
            default => new self(DockerHubCredentialCheckStatus::UNEXPECTED_RESPONSE, $repository, $writeStatus),
        };
    }

    public function isOk(): bool
    {
        return $this->status === DockerHubCredentialCheckStatus::OK;
    }

    /**
     * Format as a single GitHub-Actions workflow command line
     * (`::error::…` or `::notice::…`).
     */
    public function toGithubActionsLine(): string
    {
        return match ($this->status) {
            DockerHubCredentialCheckStatus::OK => sprintf(
                '::notice::Credential is valid for %s (read + no-op write confirmed).',
                $this->repository,
            ),
            DockerHubCredentialCheckStatus::INVALID_CREDENTIAL =>
                '::error::Login returned no JWT — DOCKERHUB_USERNAME / DOCKERHUB_TOKEN appear invalid.',
            DockerHubCredentialCheckStatus::INSUFFICIENT_SCOPE => sprintf(
                '::error::Login succeeded but the token lacks required scope on %s (HTTP %s). '
                . 'Verify R/W/D scope on this repository.',
                $this->repository,
                $this->httpStatus ?? '(unknown)',
            ),
            DockerHubCredentialCheckStatus::UNEXPECTED_RESPONSE => sprintf(
                '::error::Unexpected HTTP %s from Docker Hub API for %s.',
                $this->httpStatus ?? '(unknown)',
                $this->repository,
            ),
        };
    }
}
