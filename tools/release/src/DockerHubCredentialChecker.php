<?php

/**
 * Validate Docker Hub credentials against the API path that
 * peter-evans/dockerhub-description uses (PATCH /v2/repositories/<repo>/).
 *
 * Distinguishes "bad credential" from "credential lacks scope on this repo" —
 * a token can pass docker login (registry auth) and still 403 on the API
 * path, which is exactly the failure mode openemr/openemr-devops#714 had to
 * recover from.
 *
 * Verifies write scope by reading the current repo description fields and
 * issuing a no-op PATCH that writes the same values back. That exercises the
 * exact endpoint peter-evans/dockerhub-description uses; a read-only token
 * passes the GET but 403s on the PATCH. Side effect: bumps Docker Hub's
 * last-modified timestamp on the repo. The actual readme push does the same
 * thing every time it runs, so this is not a novel side effect.
 *
 * Internally tolerant of transport errors and unparseable responses (HTML
 * error pages, partial JSON, etc.) — both surface as a structured
 * DockerHubCredentialCheckResult so the workflow always emits exactly one
 * `::error::` or `::notice::` line.
 *
 * @package   openemr-devops
 * @link      https://www.open-emr.org
 * @author    Michael A. Smith <michael@opencoreemr.com>
 * @copyright Copyright (c) 2026 OpenCoreEMR Inc.
 * @license   https://github.com/openemr/openemr-devops/blob/master/LICENSE GNU General Public License 3
 */

declare(strict_types=1);

namespace OpenEMR\Release;

final readonly class DockerHubCredentialChecker
{
    private const DEFAULT_API_BASE = 'https://hub.docker.com/v2';

    public function __construct(
        private string $apiBase = self::DEFAULT_API_BASE,
    ) {
    }

    public function check(string $username, string $token, string $repository): DockerHubCredentialCheckResult
    {
        try {
            [$loginStatus, $jwt] = $this->mintJwt($username, $token);
        } catch (\RuntimeException $e) {
            return new DockerHubCredentialCheckResult(
                DockerHubCredentialCheckStatus::NETWORK_ERROR,
                $repository,
                detail: $e->getMessage(),
            );
        }
        if ($loginStatus !== 200 || $jwt === null) {
            return DockerHubCredentialCheckResult::interpret(
                $repository,
                $loginStatus,
                $jwt,
                null,
                null,
                null,
            );
        }

        try {
            [$readStatus, $descriptions] = $this->fetchDescriptions($jwt, $repository);
        } catch (\RuntimeException $e) {
            return new DockerHubCredentialCheckResult(
                DockerHubCredentialCheckStatus::NETWORK_ERROR,
                $repository,
                detail: $e->getMessage(),
            );
        }
        if ($readStatus !== 200 || $descriptions === null) {
            return DockerHubCredentialCheckResult::interpret(
                $repository,
                $loginStatus,
                $jwt,
                $readStatus,
                $descriptions !== null,
                null,
            );
        }

        try {
            $writeStatus = $this->probeWrite($jwt, $repository, $descriptions);
        } catch (\RuntimeException $e) {
            return new DockerHubCredentialCheckResult(
                DockerHubCredentialCheckStatus::NETWORK_ERROR,
                $repository,
                detail: $e->getMessage(),
            );
        }

        return DockerHubCredentialCheckResult::interpret(
            $repository,
            $loginStatus,
            $jwt,
            $readStatus,
            true,
            $writeStatus,
        );
    }

    /**
     * @return array{int, ?string}
     */
    private function mintJwt(string $username, string $token): array
    {
        try {
            $body = json_encode(['username' => $username, 'password' => $token], JSON_THROW_ON_ERROR);
        } catch (\JsonException $e) {
            // Encoding our own input shouldn't fail; treat as transport-level.
            throw new \RuntimeException('failed to encode login payload: ' . $e->getMessage(), 0, $e);
        }
        [$status, $responseBody] = $this->httpRequest('POST', $this->apiBase . '/users/login/', [
            'Content-Type: application/json',
        ], $body);

        if ($status !== 200) {
            return [$status, null];
        }
        try {
            $decoded = json_decode($responseBody, true, flags: JSON_THROW_ON_ERROR);
        } catch (\JsonException) {
            return [$status, null];
        }
        if (!is_array($decoded) || !isset($decoded['token']) || !is_string($decoded['token'])) {
            return [$status, null];
        }
        return [$status, $decoded['token']];
    }

    /**
     * @return array{int, ?array{description: string, full_description: string}}
     */
    private function fetchDescriptions(string $jwt, string $repository): array
    {
        [$status, $body] = $this->httpRequest('GET', $this->apiBase . '/repositories/' . $repository . '/', [
            'Authorization: JWT ' . $jwt,
        ]);
        if ($status !== 200) {
            return [$status, null];
        }
        try {
            $decoded = json_decode($body, true, flags: JSON_THROW_ON_ERROR);
        } catch (\JsonException) {
            return [$status, null];
        }
        if (!is_array($decoded)) {
            return [$status, null];
        }
        // Strict: if either field is missing or not a string, treat as a parse
        // failure rather than substituting empty strings. Substituting and then
        // PATCHing would clear the live description if the API shape ever
        // changed (e.g. description becomes nullable or gets renamed). Better
        // to surface UNEXPECTED_RESPONSE than to write garbage back.
        $description = $decoded['description'] ?? null;
        $fullDescription = $decoded['full_description'] ?? null;
        if (!is_string($description) || !is_string($fullDescription)) {
            return [$status, null];
        }
        return [$status, ['description' => $description, 'full_description' => $fullDescription]];
    }

    /**
     * @param array{description: string, full_description: string} $descriptions
     */
    private function probeWrite(string $jwt, string $repository, array $descriptions): int
    {
        try {
            $body = json_encode($descriptions, JSON_THROW_ON_ERROR);
        } catch (\JsonException $e) {
            throw new \RuntimeException('failed to encode patch payload: ' . $e->getMessage(), 0, $e);
        }
        [$status] = $this->httpRequest('PATCH', $this->apiBase . '/repositories/' . $repository . '/', [
            'Authorization: JWT ' . $jwt,
            'Content-Type: application/json',
        ], $body);
        return $status;
    }

    /**
     * @param non-empty-string $method
     * @param list<string> $headers
     * @return array{int, string}
     */
    private function httpRequest(string $method, string $url, array $headers, ?string $body = null): array
    {
        $ch = curl_init($url);
        if ($ch === false) {
            throw new \RuntimeException('curl_init failed');
        }
        curl_setopt_array($ch, [
            CURLOPT_CUSTOMREQUEST => $method,
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_HTTPHEADER => $headers,
            CURLOPT_TIMEOUT => 10,
        ]);
        if ($body !== null) {
            curl_setopt($ch, CURLOPT_POSTFIELDS, $body);
        }
        $response = curl_exec($ch);
        if ($response === false) {
            $error = curl_error($ch);
            throw new \RuntimeException("curl error for {$method} {$url}: {$error}");
        }
        /** @var int $status */
        $status = curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
        return [$status, is_string($response) ? $response : ''];
    }
}
