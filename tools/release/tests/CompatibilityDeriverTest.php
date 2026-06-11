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

use OpenEMR\Release\CompatibilityDeriver;
use PHPUnit\Framework\TestCase;
use Symfony\Component\Process\Process;

final class CompatibilityDeriverTest extends TestCase
{
    private string $ciDir = '';

    protected function setUp(): void
    {
        $this->ciDir = sys_get_temp_dir() . '/openemr-compat-deriver-' . bin2hex(random_bytes(8));
        if (!mkdir($this->ciDir, 0700, true)) {
            throw new \RuntimeException('Failed to create tmp dir: ' . $this->ciDir);
        }
    }

    protected function tearDown(): void
    {
        if (is_dir($this->ciDir)) {
            (new Process(['rm', '-rf', $this->ciDir]))->run();
        }
    }

    public function testDerivesMinimumPerComponentPhpFirstThenSortedDbTypes(): void
    {
        $this->matrixDir('apache_82_mariadb', 'mariadb:11.8.6');
        $this->matrixDir('apache_84_mariadb', 'mariadb:10.6.4');
        $this->matrixDir('nginx_83_mysql', 'mysql:8.4.0');
        $this->matrixDir('apache_810_mysql', 'mysql:5.7.44');

        $minimums = (new CompatibilityDeriver($this->ciDir))->derive();

        self::assertSame([
            'php' => '8.2',
            'mariadb' => '10.6',
            'mysql' => '5.7',
        ], $minimums);
    }

    public function testComparesVersionsNumericallyNotLexically(): void
    {
        // Lexically '8.9' > '8.10'; version_compare must pick 8.9 as the min.
        $this->matrixDir('apache_89_mariadb', 'mariadb:11.0.0');
        $this->matrixDir('apache_810_mariadb', 'mariadb:11.0.0');

        $minimums = (new CompatibilityDeriver($this->ciDir))->derive();

        self::assertSame('8.9', $minimums['php']);
    }

    public function testStripsImageDigestBeforeDecoding(): void
    {
        $this->matrixDir(
            'apache_82_mariadb',
            'mariadb:11.8.6@sha256:' . str_repeat('a', 64),
        );

        $minimums = (new CompatibilityDeriver($this->ciDir))->derive();

        self::assertSame('11.8', $minimums['mariadb']);
    }

    public function testSkipsComposeSharedDirs(): void
    {
        $this->matrixDir('apache_82_mariadb', 'mariadb:11.8.6');
        $this->matrixDir('compose-shared-foo', 'mariadb:9.9.9');

        $minimums = (new CompatibilityDeriver($this->ciDir))->derive();

        self::assertSame('8.2', $minimums['php']);
        self::assertSame('11.8', $minimums['mariadb']);
    }

    public function testSkipsDirsWithoutDockerComposeYml(): void
    {
        $this->matrixDir('apache_82_mariadb', 'mariadb:11.8.6');
        // Mimic inferno/ (compose.yml, not docker-compose.yml) and a bare config dir.
        mkdir($this->ciDir . '/inferno', 0700, true);
        file_put_contents($this->ciDir . '/inferno/compose.yml', "services: {}\n");
        mkdir($this->ciDir . '/nginx', 0700, true);

        $minimums = (new CompatibilityDeriver($this->ciDir))->derive();

        self::assertSame('8.2', $minimums['php']);
        self::assertArrayNotHasKey('inferno', $minimums);
    }

    public function testMissingCiDirThrows(): void
    {
        $this->expectException(\RuntimeException::class);
        $this->expectExceptionMessage('CI directory not found');

        (new CompatibilityDeriver($this->ciDir . '/nope'))->derive();
    }

    public function testEmptyMatrixThrows(): void
    {
        $this->expectException(\RuntimeException::class);
        $this->expectExceptionMessage('No CI matrix directories found');

        (new CompatibilityDeriver($this->ciDir))->derive();
    }

    public function testUndecodablePhpDirNameThrows(): void
    {
        $this->matrixDir('apache_x_mariadb', 'mariadb:11.8.6');

        $this->expectException(\RuntimeException::class);
        $this->expectExceptionMessage('Cannot decode PHP version');

        (new CompatibilityDeriver($this->ciDir))->derive();
    }

    public function testMissingImageThrows(): void
    {
        $dir = $this->ciDir . '/apache_82_mariadb';
        mkdir($dir, 0700, true);
        file_put_contents($dir . '/docker-compose.yml', "services:\n  mysql: {}\n");

        $this->expectException(\RuntimeException::class);
        $this->expectExceptionMessage('Missing services.mysql.image');

        (new CompatibilityDeriver($this->ciDir))->derive();
    }

    private function matrixDir(string $name, string $image): void
    {
        $dir = $this->ciDir . '/' . $name;
        if (!mkdir($dir, 0700, true)) {
            throw new \RuntimeException('Failed to create matrix dir: ' . $dir);
        }
        file_put_contents(
            $dir . '/docker-compose.yml',
            "services:\n  mysql:\n    image: {$image}\n",
        );
    }
}
