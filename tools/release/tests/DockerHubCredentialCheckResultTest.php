<?php

/**
 * @package   openemr-devops
 * @link      https://www.open-emr.org
 * @author    Michael A. Smith <michael@opencoreemr.com>
 * @copyright Copyright (c) 2026 OpenCoreEMR Inc.
 * @license   https://github.com/openemr/openemr-devops/blob/master/LICENSE GNU General Public License 3
 */

declare(strict_types=1);

namespace OpenEMR\Release\Tests;

use OpenEMR\Release\DockerHubCredentialCheckResult;
use OpenEMR\Release\DockerHubCredentialCheckStatus;
use PHPUnit\Framework\TestCase;

final class DockerHubCredentialCheckResultTest extends TestCase
{
    private const REPO = 'openemr/openemr';

    public function testNetworkErrorWhenLoginStatusUnknown(): void
    {
        $result = DockerHubCredentialCheckResult::interpret(self::REPO, null, null, null, null, null);

        self::assertSame(DockerHubCredentialCheckStatus::NETWORK_ERROR, $result->status);
        self::assertStringContainsString('Could not reach Docker Hub', $result->toGithubActionsLine());
    }

    public function testInvalidCredentialOnLogin401(): void
    {
        $result = DockerHubCredentialCheckResult::interpret(self::REPO, 401, null, null, null, null);

        self::assertSame(DockerHubCredentialCheckStatus::INVALID_CREDENTIAL, $result->status);
        self::assertSame(401, $result->httpStatus);
        self::assertStringContainsString('HTTP 401', $result->toGithubActionsLine());
    }

    public function testInvalidCredentialOnLogin403(): void
    {
        $result = DockerHubCredentialCheckResult::interpret(self::REPO, 403, null, null, null, null);

        self::assertSame(DockerHubCredentialCheckStatus::INVALID_CREDENTIAL, $result->status);
    }

    public function testUnexpectedResponseOnLogin500(): void
    {
        $result = DockerHubCredentialCheckResult::interpret(self::REPO, 500, null, null, null, null);

        self::assertSame(DockerHubCredentialCheckStatus::UNEXPECTED_RESPONSE, $result->status);
        self::assertSame(500, $result->httpStatus);
        self::assertStringContainsString('HTTP 500', $result->toGithubActionsLine());
    }

    public function testUnexpectedResponseWhenLogin200ButNoJwt(): void
    {
        // Server returned 200 but the body wasn't parseable JSON or lacked the token field.
        $result = DockerHubCredentialCheckResult::interpret(self::REPO, 200, null, null, null, null);

        self::assertSame(DockerHubCredentialCheckStatus::UNEXPECTED_RESPONSE, $result->status);
    }

    public function testRejectsLiteralStringNullJwt(): void
    {
        $result = DockerHubCredentialCheckResult::interpret(self::REPO, 200, 'null', null, null, null);

        self::assertSame(DockerHubCredentialCheckStatus::UNEXPECTED_RESPONSE, $result->status);
    }

    public function testNetworkErrorWhenReadStatusUnknown(): void
    {
        $result = DockerHubCredentialCheckResult::interpret(self::REPO, 200, 'jwt', null, null, null);

        self::assertSame(DockerHubCredentialCheckStatus::NETWORK_ERROR, $result->status);
    }

    public function testInsufficientScopeOnRead403(): void
    {
        $result = DockerHubCredentialCheckResult::interpret(self::REPO, 200, 'jwt', 403, false, null);

        self::assertSame(DockerHubCredentialCheckStatus::INSUFFICIENT_SCOPE, $result->status);
        self::assertSame(403, $result->httpStatus);
    }

    public function testUnexpectedResponseOnRead404(): void
    {
        $result = DockerHubCredentialCheckResult::interpret(self::REPO, 200, 'jwt', 404, false, null);

        self::assertSame(DockerHubCredentialCheckStatus::UNEXPECTED_RESPONSE, $result->status);
        self::assertSame(404, $result->httpStatus);
    }

    public function testUnexpectedResponseOnRead500(): void
    {
        $result = DockerHubCredentialCheckResult::interpret(self::REPO, 200, 'jwt', 500, false, null);

        self::assertSame(DockerHubCredentialCheckStatus::UNEXPECTED_RESPONSE, $result->status);
    }

    public function testUnexpectedResponseWhenRead200ButUnparseable(): void
    {
        $result = DockerHubCredentialCheckResult::interpret(self::REPO, 200, 'jwt', 200, false, null);

        self::assertSame(DockerHubCredentialCheckStatus::UNEXPECTED_RESPONSE, $result->status);
    }

    public function testNetworkErrorWhenWriteStatusUnknown(): void
    {
        $result = DockerHubCredentialCheckResult::interpret(self::REPO, 200, 'jwt', 200, true, null);

        self::assertSame(DockerHubCredentialCheckStatus::NETWORK_ERROR, $result->status);
    }

    public function testInsufficientScopeWhenReadOkButWrite403(): void
    {
        $result = DockerHubCredentialCheckResult::interpret(self::REPO, 200, 'jwt', 200, true, 403);

        self::assertSame(DockerHubCredentialCheckStatus::INSUFFICIENT_SCOPE, $result->status);
        self::assertSame(403, $result->httpStatus, 'httpStatus reflects the failing probe (write)');
        self::assertStringContainsString('R/W/D scope', $result->toGithubActionsLine());
    }

    public function testOkWhenAllStepsSucceed(): void
    {
        $result = DockerHubCredentialCheckResult::interpret(self::REPO, 200, 'jwt', 200, true, 200);

        self::assertSame(DockerHubCredentialCheckStatus::OK, $result->status);
        self::assertTrue($result->isOk());
        self::assertSame(200, $result->httpStatus);
        self::assertStringContainsString('::notice::Credential is valid', $result->toGithubActionsLine());
        self::assertStringContainsString('read + no-op write confirmed', $result->toGithubActionsLine());
    }

    public function testUnexpectedResponseOnWrite500(): void
    {
        $result = DockerHubCredentialCheckResult::interpret(self::REPO, 200, 'jwt', 200, true, 500);

        self::assertSame(DockerHubCredentialCheckStatus::UNEXPECTED_RESPONSE, $result->status);
        self::assertSame(500, $result->httpStatus);
    }

    public function testGithubActionsLineIsSingleLine(): void
    {
        foreach (DockerHubCredentialCheckStatus::cases() as $status) {
            $result = new DockerHubCredentialCheckResult($status, self::REPO, 200, 'detail');
            self::assertStringNotContainsString("\n", $result->toGithubActionsLine(), $status->value);
        }
    }
}
