#!/usr/bin/env php
<?php

/**
 * Open or update the long-lived rotation draft PR.
 *
 * Authenticates via the ambient GH_TOKEN env var (the workflow mints an App
 * token and exports it before invoking this script).
 *
 * @package   openemr-devops
 * @link      https://www.open-emr.org
 * @author    Michael A. Smith <michael@opencoreemr.com>
 * @copyright Copyright (c) 2026 OpenCoreEMR Inc.
 * @license   https://github.com/openemr/openemr-devops/blob/master/LICENSE GNU General Public License 3
 */

declare(strict_types=1);

require dirname(__DIR__) . '/vendor/autoload.php';

use OpenEMR\Release\RotationPrPublisher;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\OutputInterface;
use Symfony\Component\Console\SingleCommandApplication;

(new SingleCommandApplication())
    ->setName('open-rotation-pr')
    ->setDescription('Open or update the long-lived rotation draft PR')
    ->addOption('branch', null, InputOption::VALUE_REQUIRED, 'Rotation branch name (head)')
    ->addOption('base', null, InputOption::VALUE_REQUIRED, 'Base branch (e.g. master)')
    ->addOption('title', null, InputOption::VALUE_REQUIRED, 'PR title', 'Release rotation (auto)')
    ->addOption('trigger', null, InputOption::VALUE_REQUIRED, 'Dispatch type or trigger label', 'workflow_dispatch')
    ->addOption('run-url', null, InputOption::VALUE_REQUIRED, 'Workflow run URL', '')
    ->addOption('current', null, InputOption::VALUE_REQUIRED, 'New current slot (for body)', '')
    ->addOption('next', null, InputOption::VALUE_REQUIRED, 'New next slot (for body)', '')
    ->addOption('dev', null, InputOption::VALUE_REQUIRED, 'New dev slot (for body)', '')
    ->setCode(function (InputInterface $input, OutputInterface $output): int {
        $branch = RotationPrPublisher::stringOrEmpty($input->getOption('branch'));
        $base = RotationPrPublisher::stringOrEmpty($input->getOption('base'));
        if ($branch === '' || $base === '') {
            $output->writeln('<error>--branch and --base are required</error>');
            return 1;
        }

        $body = RotationPrPublisher::buildBody(
            RotationPrPublisher::stringOrEmpty($input->getOption('trigger')),
            RotationPrPublisher::stringOrEmpty($input->getOption('run-url')),
            RotationPrPublisher::stringOrEmpty($input->getOption('current')),
            RotationPrPublisher::stringOrEmpty($input->getOption('next')),
            RotationPrPublisher::stringOrEmpty($input->getOption('dev')),
        );
        $publisher = new RotationPrPublisher(
            $branch,
            $base,
            RotationPrPublisher::stringOrEmpty($input->getOption('title')),
        );
        $number = $publisher->publish($body);
        $output->writeln(sprintf('<info>✓</info> rotation PR #%d updated', $number));
        return 0;
    })
    ->run();
