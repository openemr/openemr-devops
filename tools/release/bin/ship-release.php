#!/usr/bin/env php
<?php

/**
 * Merge the three release PRs (infra → conductor → docs) in order.
 *
 * Authenticates via the ambient GH_TOKEN env var. The workflow mints a release
 * App token with PR-write on all three repos and exports it before invoking.
 *
 * @package   openemr-devops
 * @link      https://www.open-emr.org
 * @author    Michael A. Smith <michael@opencoreemr.com>
 * @copyright Copyright (c) 2026 OpenCoreEMR Inc.
 * @license   https://github.com/openemr/openemr-devops/blob/master/LICENSE GNU General Public License 3
 */

declare(strict_types=1);

require dirname(__DIR__) . '/vendor/autoload.php';

use OpenEMR\Release\GhPullRequestApi;
use OpenEMR\Release\PullRequestTarget;
use OpenEMR\Release\ShipReleaseOptions;
use OpenEMR\Release\ShipReleaseOrchestrator;
use OpenEMR\Release\ShipReleaseRenderer;
use OpenEMR\Release\SystemClock;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\OutputInterface;
use Symfony\Component\Console\SingleCommandApplication;

(new SingleCommandApplication())
    ->setName('ship-release')
    ->setDescription('Merge the three release PRs in order (issue #705)')
    ->addOption('version', null, InputOption::VALUE_REQUIRED, 'Release version (e.g. 8.1.0)')
    ->addOption('rel-branch', null, InputOption::VALUE_REQUIRED, 'Release branch name (e.g. rel-810)')
    ->addOption('dry-run', null, InputOption::VALUE_NONE, 'Check readiness without merging or posting status')
    ->addOption(
        'timeout-seconds',
        null,
        InputOption::VALUE_REQUIRED,
        'Max seconds to wait for docs PR to update after conductor merges',
        '600',
    )
    ->addOption('status-target-url', null, InputOption::VALUE_REQUIRED, 'target_url for the ship-approved status', '')
    ->setCode(function (InputInterface $input, OutputInterface $output): int {
        $version = ShipReleaseOptions::asString($input, 'version');
        $relBranch = ShipReleaseOptions::asString($input, 'rel-branch');
        if ($version === '' || $relBranch === '') {
            $output->writeln('<error>--version and --rel-branch are required</error>');
            return 1;
        }
        $timeoutRaw = ShipReleaseOptions::asString($input, 'timeout-seconds');
        if (!ctype_digit($timeoutRaw) || (int) $timeoutRaw < 1) {
            $output->writeln('<error>--timeout-seconds must be a positive integer</error>');
            return 1;
        }

        $orchestrator = new ShipReleaseOrchestrator(
            new GhPullRequestApi(),
            new SystemClock(),
            (int) $timeoutRaw,
            (bool) $input->getOption('dry-run'),
            ShipReleaseOptions::asString($input, 'status-target-url'),
        );
        $result = $orchestrator->ship(PullRequestTarget::forRelease($version, $relBranch));
        ShipReleaseRenderer::render($output, $result);
        return $result->wasSuccessful() ? 0 : 1;
    })
    ->run();
