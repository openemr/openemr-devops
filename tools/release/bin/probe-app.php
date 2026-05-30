#!/usr/bin/env php
<?php

/**
 * Probe one release-App permission and report the specific one that is missing.
 *
 * Invoked per-check by release-permissions-check.yml, which exports
 * OWNER/REPO_NAME/BRANCH/RUN_ID/GH_TOKEN — each option defaults from its
 * matching env var so the workflow needs no extra wiring.
 *
 * @package   openemr-devops
 * @link      https://www.open-emr.org
 * @author    Michael A. Smith <michael@opencoreemr.com>
 * @copyright Copyright (c) 2026 OpenCoreEMR Inc.
 * @license   https://github.com/openemr/openemr-devops/blob/master/LICENSE GNU General Public License 3
 */

declare(strict_types=1);

require dirname(__DIR__) . '/vendor/autoload.php';

use OpenEMR\Release\AppPermissionProbe;
use OpenEMR\Release\GhAppPermissionApi;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\OutputInterface;
use Symfony\Component\Console\SingleCommandApplication;

$env = static function (string $name): ?string {
    $value = getenv($name);
    return $value === false || $value === '' ? null : $value;
};

(new SingleCommandApplication())
    ->setName('probe-app')
    ->setDescription('Probe a single release-App permission and report the missing one by name')
    ->addOption(
        'check',
        null,
        InputOption::VALUE_REQUIRED,
        'Which permission to probe: installation|metadata|contents-write|pull-requests-write|cleanup',
    )
    ->addOption('owner', null, InputOption::VALUE_REQUIRED, 'Repository owner', $env('OWNER'))
    ->addOption('repo-name', null, InputOption::VALUE_REQUIRED, 'Repository name', $env('REPO_NAME'))
    ->addOption('branch', null, InputOption::VALUE_REQUIRED, 'Throwaway probe branch', $env('BRANCH'))
    ->addOption('run-id', null, InputOption::VALUE_REQUIRED, 'Workflow run id', $env('RUN_ID'))
    ->setCode(function (InputInterface $input, OutputInterface $output): int {
        $check = $input->getOption('check');
        $owner = $input->getOption('owner');
        $repoName = $input->getOption('repo-name');
        $branch = $input->getOption('branch');
        $runId = $input->getOption('run-id');

        $checks = ['installation', 'metadata', 'contents-write', 'pull-requests-write', 'cleanup'];
        if (!is_string($check) || !in_array($check, $checks, true)) {
            $output->writeln('<error>--check must be one of: ' . implode('|', $checks) . '</error>');
            return 1;
        }
        if (!is_string($owner) || $owner === '') {
            $output->writeln('<error>--owner is required</error>');
            return 1;
        }
        if (!is_string($repoName) || $repoName === '') {
            $output->writeln('<error>--repo-name is required</error>');
            return 1;
        }

        $needsBranch = ['contents-write', 'pull-requests-write', 'cleanup'];
        if (in_array($check, $needsBranch, true) && (!is_string($branch) || $branch === '')) {
            $output->writeln('<error>--branch is required for ' . $check . '</error>');
            return 1;
        }

        $needsRunId = ['contents-write', 'pull-requests-write'];
        if (in_array($check, $needsRunId, true) && (!is_string($runId) || $runId === '')) {
            $output->writeln('<error>--run-id is required for ' . $check . '</error>');
            return 1;
        }

        // Already validated above for the checks that consume them; the guard
        // keeps the values typed as string for the unrelated checks.
        $branchArg = is_string($branch) ? $branch : '';
        $runIdArg = is_string($runId) ? $runId : '';

        $probe = new AppPermissionProbe(new GhAppPermissionApi());
        $result = $probe->check($check, $owner, $repoName, $branchArg, $runIdArg);

        if ($result->ok) {
            $output->writeln('<info>✓</info> ' . $result->message);
            return 0;
        }
        // GitHub annotation, so the missing permission surfaces in the run's
        // Annotations panel rather than only the raw log.
        $output->writeln('::error::' . $result->message);
        return 1;
    })
    ->run();
