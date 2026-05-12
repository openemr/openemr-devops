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
     * Map raw HTTP responses from the Docker Hub login + repository endpoints
     * to a result. Pure: no network. Tested directly.
     */
    public static function interpret(string $repository, ?string $jwt, ?int $repoStatus): self
    {
        if (in_array($jwt, [null, '', 'null'], true)) {
            return new self(DockerHubCredentialCheckStatus::INVALID_CREDENTIAL, $repository);
        }
        return match ($repoStatus) {
            200 => new self(DockerHubCredentialCheckStatus::OK, $repository, 200),
            403 => new self(DockerHubCredentialCheckStatus::INSUFFICIENT_SCOPE, $repository, 403),
            default => new self(DockerHubCredentialCheckStatus::UNEXPECTED_RESPONSE, $repository, $repoStatus),
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
                "::notice::Credential is valid for %s (read access confirmed).",
                $this->repository,
            ),
            DockerHubCredentialCheckStatus::INVALID_CREDENTIAL =>
                '::error::Login returned no JWT — DOCKERHUB_USERNAME / DOCKERHUB_TOKEN appear invalid.',
            DockerHubCredentialCheckStatus::INSUFFICIENT_SCOPE => sprintf(
                "::error::Login succeeded but the token lacks access to %s. Verify R/W/D scope.",
                $this->repository,
            ),
            DockerHubCredentialCheckStatus::UNEXPECTED_RESPONSE => sprintf(
                "::error::Unexpected HTTP %s from Docker Hub API for %s.",
                $this->httpStatus ?? '(unknown)',
                $this->repository,
            ),
        };
    }
}
