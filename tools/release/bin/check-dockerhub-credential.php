#!/usr/bin/env php
<?php

/**
 * Validate DOCKERHUB_USERNAME / DOCKERHUB_TOKEN against the Docker Hub API
 * path that peter-evans/dockerhub-description uses.
 *
 * Manual smoke test invoked from the dockerhub-credential-check workflow.
 * Exits non-zero on failure with a `::error::` line; on success emits a
 * `::notice::` line.
 *
 * @package   openemr-devops
 * @link      https://www.open-emr.org
 * @author    Michael A. Smith <michael@opencoreemr.com>
 * @copyright Copyright (c) 2026 OpenCoreEMR Inc.
 * @license   https://github.com/openemr/openemr-devops/blob/master/LICENSE GNU General Public License 3
 */

declare(strict_types=1);

require dirname(__DIR__) . '/vendor/autoload.php';

use OpenEMR\Release\DockerHubCredentialChecker;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\OutputInterface;
use Symfony\Component\Console\SingleCommandApplication;

(new SingleCommandApplication())
    ->setName('check-dockerhub-credential')
    ->setDescription('Validate DOCKERHUB_USERNAME / DOCKERHUB_TOKEN for the readme-push API path')
    ->addOption(
        'repository',
        null,
        InputOption::VALUE_REQUIRED,
        'Docker Hub repository (owner/name)',
        'openemr/openemr',
    )
    ->setCode(function (InputInterface $input, OutputInterface $output): int {
        $username = getenv('DOCKERHUB_USERNAME');
        $token = getenv('DOCKERHUB_TOKEN');
        if (!is_string($username) || $username === '') {
            $output->writeln('::error::DOCKERHUB_USERNAME env var is required');
            return 1;
        }
        if (!is_string($token) || $token === '') {
            $output->writeln('::error::DOCKERHUB_TOKEN env var is required');
            return 1;
        }
        /** @var string $repository */
        $repository = $input->getOption('repository');
        if (preg_match('#^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9._-]+$#', $repository) !== 1) {
            $output->writeln('::error::--repository must match owner/name (alphanumeric, dot, underscore, dash).');
            return 1;
        }

        $result = (new DockerHubCredentialChecker())->check($username, $token, $repository);
        $output->writeln($result->toGithubActionsLine());
        return $result->isOk() ? 0 : 1;
    })
    ->run();
