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
        $jwt = $this->mintJwt($username, $token);
        $repoStatus = $jwt !== null
            ? $this->probeRepository($jwt, $repository)
            : null;
        return DockerHubCredentialCheckResult::interpret($repository, $jwt, $repoStatus);
    }

    private function mintJwt(string $username, string $token): ?string
    {
        $body = json_encode(['username' => $username, 'password' => $token], JSON_THROW_ON_ERROR);
        [$status, $responseBody] = $this->httpRequest('POST', $this->apiBase . '/users/login/', [
            'Content-Type: application/json',
        ], $body);

        if ($status !== 200) {
            return null;
        }
        $decoded = json_decode($responseBody, true, flags: JSON_THROW_ON_ERROR);
        if (!is_array($decoded) || !isset($decoded['token']) || !is_string($decoded['token'])) {
            return null;
        }
        return $decoded['token'];
    }

    private function probeRepository(string $jwt, string $repository): int
    {
        [$status] = $this->httpRequest('GET', $this->apiBase . '/repositories/' . $repository . '/', [
            'Authorization: JWT ' . $jwt,
        ]);
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
