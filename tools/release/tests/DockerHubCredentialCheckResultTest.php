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
    public function testInterpretReturnsInvalidCredentialWhenJwtMissing(): void
    {
        $result = DockerHubCredentialCheckResult::interpret('openemr/openemr', null, null);

        self::assertSame(DockerHubCredentialCheckStatus::INVALID_CREDENTIAL, $result->status);
        self::assertFalse($result->isOk());
        self::assertStringContainsString('::error::Login returned no JWT', $result->toGithubActionsLine());
    }

    public function testInterpretRejectsLiteralStringNullJwt(): void
    {
        $result = DockerHubCredentialCheckResult::interpret('openemr/openemr', 'null', null);

        self::assertSame(DockerHubCredentialCheckStatus::INVALID_CREDENTIAL, $result->status);
    }

    public function testInterpretReturnsOkOnHttp200(): void
    {
        $result = DockerHubCredentialCheckResult::interpret('openemr/openemr', 'jwt-value', 200);

        self::assertSame(DockerHubCredentialCheckStatus::OK, $result->status);
        self::assertTrue($result->isOk());
        self::assertSame(200, $result->httpStatus);
        self::assertStringContainsString(
            '::notice::Credential is valid for openemr/openemr',
            $result->toGithubActionsLine(),
        );
    }

    public function testInterpretReturnsInsufficientScopeOnHttp403(): void
    {
        $result = DockerHubCredentialCheckResult::interpret('openemr/openemr', 'jwt-value', 403);

        self::assertSame(DockerHubCredentialCheckStatus::INSUFFICIENT_SCOPE, $result->status);
        self::assertFalse($result->isOk());
        self::assertStringContainsString('lacks access to openemr/openemr', $result->toGithubActionsLine());
        self::assertStringContainsString('R/W/D scope', $result->toGithubActionsLine());
    }

    public function testInterpretReturnsUnexpectedForOtherStatus(): void
    {
        $result = DockerHubCredentialCheckResult::interpret('openemr/openemr', 'jwt-value', 500);

        self::assertSame(DockerHubCredentialCheckStatus::UNEXPECTED_RESPONSE, $result->status);
        self::assertSame(500, $result->httpStatus);
        self::assertStringContainsString('Unexpected HTTP 500', $result->toGithubActionsLine());
    }

    public function testGithubActionsLineIsSingleLine(): void
    {
        foreach (DockerHubCredentialCheckStatus::cases() as $status) {
            $result = new DockerHubCredentialCheckResult($status, 'openemr/openemr', 200);
            self::assertStringNotContainsString("\n", $result->toGithubActionsLine(), $status->value);
        }
    }
}
