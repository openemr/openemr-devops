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

use PHPUnit\Framework\TestCase;
use Symfony\Component\Process\Process;

/**
 * The release-announcements workflow appends derive-announcement-inputs.php
 * stdout directly to $GITHUB_OUTPUT. Errors must therefore not leak into
 * stdout, or a failing run will write `<error>...</error>` lines into the
 * runner's output file and trigger an "Invalid format" step failure that
 * obscures the real error.
 */
final class DeriveAnnouncementInputsCliTest extends TestCase
{
    private const BIN = __DIR__ . '/../bin/derive-announcement-inputs.php';

    public function testValidFlagsWriteKeyValueLinesToStdoutOnly(): void
    {
        $process = new Process([
            'php',
            self::BIN,
            '--release-version=8.1.0',
            '--release-tag=v8_1_0',
            '--release-branch=rel-810',
            '--forum-url=https://example.com/thread',
        ]);
        $process->run();

        self::assertSame(0, $process->getExitCode(), 'expected success exit code');
        self::assertSame('', $process->getErrorOutput(), 'no stderr on success');
        self::assertSame(
            "version=8.1.0\ntag=v8_1_0\nbranch=rel-810\nforum_url=https://example.com/thread\n",
            $process->getOutput(),
        );
    }

    public function testValidationErrorsGoToStderrAndStdoutStaysEmpty(): void
    {
        $process = new Process([
            'php',
            self::BIN,
            '--release-version=8.1.0',
            '--release-tag=BAD',
            '--release-branch=rel-810',
        ]);
        $process->run();

        self::assertSame(1, $process->getExitCode(), 'expected failure exit code');
        self::assertSame('', $process->getOutput(), 'stdout must stay empty so $GITHUB_OUTPUT is not corrupted');
        self::assertStringContainsString('field tag does not match expected shape', $process->getErrorOutput());
    }

    public function testMissingRequiredFlagsGoToStderr(): void
    {
        $process = new Process(['php', self::BIN]);
        $process->run();

        self::assertSame(1, $process->getExitCode());
        self::assertSame('', $process->getOutput());
        self::assertStringContainsString('Provide either --payload-file', $process->getErrorOutput());
    }

    public function testMutuallyExclusiveSourcesRejected(): void
    {
        $process = new Process([
            'php',
            self::BIN,
            '--payload-file=-',
            '--release-version=8.1.0',
        ]);
        $process->setInput('{}');
        $process->run();

        self::assertSame(1, $process->getExitCode());
        self::assertSame('', $process->getOutput());
        self::assertStringContainsString('mutually exclusive', $process->getErrorOutput());
    }
}
