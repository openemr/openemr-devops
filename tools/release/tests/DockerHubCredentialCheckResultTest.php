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
        $result = DockerHubCredentialCheckResult::interpret('openemr/openemr', null, null, null);

        self::assertSame(DockerHubCredentialCheckStatus::INVALID_CREDENTIAL, $result->status);
        self::assertFalse($result->isOk());
        self::assertStringContainsString('::error::Login returned no JWT', $result->toGithubActionsLine());
    }

    public function testInterpretRejectsLiteralStringNullJwt(): void
    {
        $result = DockerHubCredentialCheckResult::interpret('openemr/openemr', 'null', null, null);

        self::assertSame(DockerHubCredentialCheckStatus::INVALID_CREDENTIAL, $result->status);
    }

    public function testInterpretReturnsInsufficientScopeWhenReadFails(): void
    {
        $result = DockerHubCredentialCheckResult::interpret('openemr/openemr', 'jwt-value', 403, null);

        self::assertSame(DockerHubCredentialCheckStatus::INSUFFICIENT_SCOPE, $result->status);
        self::assertSame(403, $result->httpStatus);
        self::assertStringContainsString('lacks required scope on openemr/openemr', $result->toGithubActionsLine());
        self::assertStringContainsString('HTTP 403', $result->toGithubActionsLine());
    }

    public function testInterpretReturnsInsufficientScopeWhenReadSucceedsButWriteIs403(): void
    {
        $result = DockerHubCredentialCheckResult::interpret('openemr/openemr', 'jwt-value', 200, 403);

        self::assertSame(DockerHubCredentialCheckStatus::INSUFFICIENT_SCOPE, $result->status);
        self::assertSame(403, $result->httpStatus, 'httpStatus reflects the failing probe (write)');
        self::assertStringContainsString('R/W/D scope', $result->toGithubActionsLine());
    }

    public function testInterpretReturnsOkWhenBothReadAndWriteSucceed(): void
    {
        $result = DockerHubCredentialCheckResult::interpret('openemr/openemr', 'jwt-value', 200, 200);

        self::assertSame(DockerHubCredentialCheckStatus::OK, $result->status);
        self::assertTrue($result->isOk());
        self::assertSame(200, $result->httpStatus);
        self::assertStringContainsString(
            '::notice::Credential is valid for openemr/openemr',
            $result->toGithubActionsLine(),
        );
        self::assertStringContainsString('read + no-op write confirmed', $result->toGithubActionsLine());
    }

    public function testInterpretReturnsUnexpectedForOtherWriteStatus(): void
    {
        $result = DockerHubCredentialCheckResult::interpret('openemr/openemr', 'jwt-value', 200, 500);

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
