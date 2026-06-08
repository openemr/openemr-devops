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

use OpenEMR\Release\DockerHubOverviewRenderer;
use PHPUnit\Framework\TestCase;

final class DockerHubOverviewRendererTest extends TestCase
{
    private const TEMPLATE_DIR = __DIR__ . '/../templates';

    private string $tmpDir = '';
    private string $registryPath = '';

    protected function setUp(): void
    {
        $this->tmpDir = sys_get_temp_dir() . '/openemr-overview-renderer-' . bin2hex(random_bytes(8));
        if (!mkdir($this->tmpDir, 0700, true)) {
            throw new \RuntimeException('Failed to create tmp dir: ' . $this->tmpDir);
        }
        $this->registryPath = $this->tmpDir . '/versions.yml';
        file_put_contents($this->registryPath, $this->fixtureRegistry());
    }

    protected function tearDown(): void
    {
        @unlink($this->registryPath);
        @rmdir($this->tmpDir);
    }

    public function testRendersAllSlotScalars(): void
    {
        $rendered = (new DockerHubOverviewRenderer($this->registryPath, self::TEMPLATE_DIR))->render();

        self::assertStringContainsString('Current production OpenEMR version is 8.0.0.3', $rendered);
        self::assertStringContainsString('`8.0.0`, `8.0.0.3`, `latest`', $rendered);
        self::assertStringContainsString('docker/openemr/8.0.0/Dockerfile', $rendered);
        self::assertStringContainsString('`8.1.0`, `next`', $rendered);
        self::assertStringContainsString('docker/openemr/8.1.0/Dockerfile', $rendered);
        self::assertStringContainsString('`8.1.1-dev`, `dev`', $rendered);
        self::assertStringContainsString('docker/openemr/8.1.1/Dockerfile', $rendered);
    }

    public function testRendersDatedTagExplanation(): void
    {
        $rendered = (new DockerHubOverviewRenderer($this->registryPath, self::TEMPLATE_DIR))->render();

        self::assertStringContainsString('immutable `X.Y.Z-YYYY-MM-DD` tag', $rendered);
        self::assertStringContainsString('hub.docker.com/r/openemr/openemr/tags', $rendered);
    }

    public function testRendersLegacyAndFlexTracksUnconditionally(): void
    {
        $rendered = (new DockerHubOverviewRenderer($this->registryPath, self::TEMPLATE_DIR))->render();

        self::assertStringContainsString('`7.0.4`, `7.0.4.0`', $rendered);
        self::assertStringContainsString('`flex-3.23-php-8.5`', $rendered);
        self::assertStringContainsString('`flex-edge-php-8.5`', $rendered);
    }

    public function testRenderIsDeterministic(): void
    {
        $renderer = new DockerHubOverviewRenderer($this->registryPath, self::TEMPLATE_DIR);

        self::assertSame($renderer->render(), $renderer->render());
    }

    public function testThrowsOnMalformedRegistry(): void
    {
        file_put_contents($this->registryPath, "not: a: valid: yaml\n");
        $renderer = new DockerHubOverviewRenderer($this->registryPath, self::TEMPLATE_DIR);

        $this->expectException(\RuntimeException::class);
        $renderer->render();
    }

    public function testThrowsOnMissingSlot(): void
    {
        file_put_contents($this->registryPath, "slots:\n  current:\n    full: \"8.0.0\"\n");
        $renderer = new DockerHubOverviewRenderer($this->registryPath, self::TEMPLATE_DIR);

        $this->expectException(\RuntimeException::class);
        $this->expectExceptionMessage('Registry missing slot: next');
        $renderer->render();
    }

    private function fixtureRegistry(): string
    {
        return <<<'YAML'
        version: 1

        slots:
          current:
            minor: "8.0"
            full: "8.0.0.3"
            branch: "rel-800"
            docker_dir: "8.0.0"
          next:
            minor: "8.1"
            full: "8.1.0"
            branch: "rel-810"
            docker_dir: "8.1.0"
          dev:
            minor: "8.1"
            full: "8.1.1-dev"
            branch: "master"
            docker_dir: "8.1.1"
        YAML;
    }
}
