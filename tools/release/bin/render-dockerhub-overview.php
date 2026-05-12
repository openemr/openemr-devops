#!/usr/bin/env php
<?php

/**
 * Render the Docker Hub readme for openemr/openemr.
 *
 * Called from the build workflows after a successful image push; the rendered
 * output is fed to peter-evans/dockerhub-description, which PATCHes Docker
 * Hub's repo description endpoint.
 *
 * @package   openemr-devops
 * @link      https://www.open-emr.org
 * @author    Michael A. Smith <michael@opencoreemr.com>
 * @copyright Copyright (c) 2026 OpenCoreEMR Inc.
 * @license   https://github.com/openemr/openemr-devops/blob/master/LICENSE GNU General Public License 3
 */

declare(strict_types=1);

require dirname(__DIR__) . '/vendor/autoload.php';

use OpenEMR\Release\DockerHubOverviewRenderer;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\OutputInterface;
use Symfony\Component\Console\SingleCommandApplication;

(new SingleCommandApplication())
    ->setName('render-dockerhub-overview')
    ->setDescription('Render the Docker Hub readme for openemr/openemr from versions.yml')
    ->addOption(
        'repo',
        null,
        InputOption::VALUE_REQUIRED,
        'Path to the repo root',
        getcwd() === false ? '.' : getcwd(),
    )
    ->addOption(
        'registry',
        null,
        InputOption::VALUE_REQUIRED,
        'Path to versions.yml (defaults to <repo>/tools/release/versions.yml)',
    )
    ->addOption(
        'template-dir',
        null,
        InputOption::VALUE_REQUIRED,
        'Twig template directory (defaults to <repo>/tools/release/templates)',
    )
    ->addOption('output', 'o', InputOption::VALUE_REQUIRED, 'Output file (defaults to stdout)')
    ->setCode(function (InputInterface $input, OutputInterface $output): int {
        $repo = $input->getOption('repo');
        if (!is_string($repo) || $repo === '') {
            $output->writeln('<error>--repo is required</error>');
            return 1;
        }

        $registry = $input->getOption('registry');
        if (!is_string($registry) || $registry === '') {
            $registry = $repo . '/tools/release/versions.yml';
        }
        if (!is_file($registry)) {
            $output->writeln("<error>Registry not found: {$registry}</error>");
            return 1;
        }

        $templateDir = $input->getOption('template-dir');
        if (!is_string($templateDir) || $templateDir === '') {
            $templateDir = $repo . '/tools/release/templates';
        }
        if (!is_dir($templateDir)) {
            $output->writeln("<error>Template directory not found: {$templateDir}</error>");
            return 1;
        }

        $rendered = (new DockerHubOverviewRenderer($registry, $templateDir))->render();

        $target = $input->getOption('output');
        if (is_string($target) && $target !== '') {
            file_put_contents($target, $rendered);
            $output->writeln("Rendered to <info>{$target}</info>");
            return 0;
        }
        $output->write($rendered);
        return 0;
    })
    ->run();
