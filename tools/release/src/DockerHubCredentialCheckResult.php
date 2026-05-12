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
    public DockerHubCredentialCheckStatus $status;
    public string $repository;
    public ?int $httpStatus;
    public ?string $detail;

    public function __construct(
        DockerHubCredentialCheckStatus $status,
        string $repository,
        ?int $httpStatus = null,
        ?string $detail = null,
    ) {
        // Defensively scrub CR/LF from caller-controlled strings before they
        // ever get formatted into a `::error::` / `::notice::` line. The
        // workflow-command syntax is line-based; an embedded newline could
        // inject a second command. Belt-and-braces — the bin layer also
        // validates repository against an owner/name pattern up front.
        $this->status = $status;
        $this->repository = $this->scrubLineBreaks($repository);
        $this->httpStatus = $httpStatus;
        $this->detail = $detail !== null ? $this->scrubLineBreaks($detail) : null;
    }

    private function scrubLineBreaks(string $value): string
    {
        return strtr($value, ["\r" => ' ', "\n" => ' ']);
    }

    /**
     * Map raw HTTP statuses from Docker Hub's login + repository read +
     * repository write probes to a result. Pure: no network. Tested directly.
     *
     * - $loginStatus is the POST /v2/users/login/ HTTP status (null if the
     *   request itself failed at the transport layer)
     * - $jwt is the token extracted from the login response (null if the
     *   response was unparseable JSON or missing the token field)
     * - $readStatus is the GET /v2/repositories/<repo>/ status (null if the
     *   step was not reached)
     * - $descriptionsParsed is whether the GET response body was usable JSON
     *   with the expected fields (null if read step not reached)
     * - $writeStatus is the no-op PATCH /v2/repositories/<repo>/ status
     *   (null if the step was not reached)
     */
    public static function interpret(
        string $repository,
        ?int $loginStatus,
        ?string $jwt,
        ?int $readStatus,
        ?bool $descriptionsParsed,
        ?int $writeStatus,
    ): self {
        if ($loginStatus === null) {
            return new self(DockerHubCredentialCheckStatus::NETWORK_ERROR, $repository);
        }
        if (in_array($jwt, [null, '', 'null'], true)) {
            return self::fromAuthFailure($repository, $loginStatus);
        }
        if ($readStatus === null) {
            return new self(DockerHubCredentialCheckStatus::NETWORK_ERROR, $repository);
        }
        if ($readStatus !== 200 || $descriptionsParsed !== true) {
            return self::fromAccessFailure($repository, $readStatus);
        }
        if ($writeStatus === null) {
            return new self(DockerHubCredentialCheckStatus::NETWORK_ERROR, $repository);
        }
        return self::fromWriteStatus($repository, $writeStatus);
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
                '::error::Login failed (HTTP ' . $this->httpStatusOrUnknown()
                . ') — DOCKERHUB_USERNAME / DOCKERHUB_TOKEN appear invalid.',
            DockerHubCredentialCheckStatus::INSUFFICIENT_SCOPE => sprintf(
                '::error::Login succeeded but the token lacks required scope on %s (HTTP %s). '
                . 'Verify R/W/D scope on this repository.',
                $this->repository,
                $this->httpStatusOrUnknown(),
            ),
            DockerHubCredentialCheckStatus::UNEXPECTED_RESPONSE => sprintf(
                '::error::Unexpected response from Docker Hub API for %s (HTTP %s). %s',
                $this->repository,
                $this->httpStatusOrUnknown(),
                $this->detail ?? 'Re-run, check status.docker.com, then re-evaluate.',
            ),
            DockerHubCredentialCheckStatus::NETWORK_ERROR => sprintf(
                '::error::Could not reach Docker Hub API for %s. %s',
                $this->repository,
                $this->detail ?? 'Re-run, check status.docker.com, then re-evaluate.',
            ),
        };
    }

    private static function fromAuthFailure(string $repository, int $loginStatus): self
    {
        return match (true) {
            in_array($loginStatus, [401, 403], true) =>
                new self(DockerHubCredentialCheckStatus::INVALID_CREDENTIAL, $repository, $loginStatus),
            default =>
                new self(DockerHubCredentialCheckStatus::UNEXPECTED_RESPONSE, $repository, $loginStatus),
        };
    }

    private static function fromAccessFailure(string $repository, int $readStatus): self
    {
        // 401 = JWT not accepted by this endpoint (rotate the credential).
        // 403 = JWT recognized but lacks scope on this repo (grant scope).
        // Distinct remediations, distinct statuses.
        return match ($readStatus) {
            401 => new self(DockerHubCredentialCheckStatus::INVALID_CREDENTIAL, $repository, 401),
            403 => new self(DockerHubCredentialCheckStatus::INSUFFICIENT_SCOPE, $repository, 403),
            default => new self(DockerHubCredentialCheckStatus::UNEXPECTED_RESPONSE, $repository, $readStatus),
        };
    }

    private static function fromWriteStatus(string $repository, int $writeStatus): self
    {
        return match ($writeStatus) {
            200 => new self(DockerHubCredentialCheckStatus::OK, $repository, 200),
            401 => new self(DockerHubCredentialCheckStatus::INVALID_CREDENTIAL, $repository, 401),
            403 => new self(DockerHubCredentialCheckStatus::INSUFFICIENT_SCOPE, $repository, 403),
            default => new self(DockerHubCredentialCheckStatus::UNEXPECTED_RESPONSE, $repository, $writeStatus),
        };
    }

    private function httpStatusOrUnknown(): string
    {
        return $this->httpStatus !== null ? (string) $this->httpStatus : '(unknown)';
    }
}
