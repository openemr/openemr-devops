<?php

/**
 * Render the Docker Hub readme for openemr/openemr from versions.yml.
 *
 * The rendered output is what the build workflows push to Docker Hub via the
 * peter-evans/dockerhub-description action. Pure: same input → same output;
 * no filesystem side effects beyond reading the registry path.
 *
 * @package   openemr-devops
 * @link      https://www.open-emr.org
 * @author    Michael A. Smith <michael@opencoreemr.com>
 * @copyright Copyright (c) 2026 OpenCoreEMR Inc.
 * @license   https://github.com/openemr/openemr-devops/blob/master/LICENSE GNU General Public License 3
 */

declare(strict_types=1);

namespace OpenEMR\Release;

use Symfony\Component\Yaml\Yaml;
use Twig\Environment;
use Twig\Loader\FilesystemLoader;

final readonly class DockerHubOverviewRenderer
{
    public const TEMPLATE_NAME = 'dockerhub-overview.md.twig';

    public function __construct(
        private string $registryPath,
        private string $templateDir,
    ) {
    }

    public function render(): string
    {
        $registry = $this->loadRegistry();
        $twig = new Environment(
            new FilesystemLoader($this->templateDir),
            ['autoescape' => false],
        );
        return $twig->render(self::TEMPLATE_NAME, [
            'current' => $this->slot($registry, 'current'),
            'next' => $this->slot($registry, 'next'),
            'dev' => $this->slot($registry, 'dev'),
        ]);
    }

    /**
     * @return array<string, array<string, string>>
     */
    private function loadRegistry(): array
    {
        $parsed = Yaml::parseFile($this->registryPath);
        if (!is_array($parsed) || !isset($parsed['slots']) || !is_array($parsed['slots'])) {
            throw new \RuntimeException("Registry malformed: {$this->registryPath}");
        }
        /** @var array<string, array<string, string>> $slots */
        $slots = $parsed['slots'];
        return $slots;
    }

    /**
     * @param array<string, array<string, string>> $registry
     * @return array<string, string>
     */
    private function slot(array $registry, string $name): array
    {
        if (!isset($registry[$name])) {
            throw new \RuntimeException("Registry missing slot: {$name}");
        }
        return $registry[$name];
    }
}
