#!/usr/bin/env php
<?php

/**
 * Apply OpenEMR slot rotation to versions.yml and the files it lists.
 *
 * Each slot accepts a target as either a minor version ("8.2") which is
 * expanded to a full slot definition by deterministic mapping, "edge"
 * (sets branch=master only — for the dev slot), or `key=value,...` for
 * explicit overrides. The rotator reads versions.yml, rewrites every pin
 * owned by changed slots, and updates versions.yml itself. Idempotent —
 * running twice with the same args is a no-op the second time.
 *
 * @package   openemr-devops
 * @link      https://www.open-emr.org
 * @author    Michael A. Smith <michael@opencoreemr.com>
 * @copyright Copyright (c) 2026 OpenCoreEMR Inc.
 * @license   https://github.com/openemr/openemr-devops/blob/master/LICENSE GNU General Public License 3
 */

declare(strict_types=1);

require dirname(__DIR__) . '/vendor/autoload.php';

use OpenEMR\Release\SlotAssignmentParser;
use OpenEMR\Release\SlotRotator;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\OutputInterface;
use Symfony\Component\Console\SingleCommandApplication;

(new SingleCommandApplication())
    ->setName('rotate')
    ->setDescription('Apply OpenEMR slot rotation per tools/release/versions.yml')
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
    ->addOption('current', null, InputOption::VALUE_REQUIRED, 'New value for the current slot (e.g. "8.1")')
    ->addOption('next', null, InputOption::VALUE_REQUIRED, 'New value for the next slot (e.g. "8.2")')
    ->addOption('dev', null, InputOption::VALUE_REQUIRED, 'New value for the dev slot (e.g. "8.2" or "edge")')
    ->addOption('dry-run', null, InputOption::VALUE_NONE, 'Print the diff and exit without writing')
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

        $parser = new SlotAssignmentParser();
        $assignments = [];
        foreach (['current', 'next', 'dev'] as $slot) {
            $raw = $input->getOption($slot);
            if (!is_string($raw) || $raw === '') {
                continue;
            }
            $assignments[$slot] = $parser->parse($slot, $raw);
        }
        if ($assignments === []) {
            $output->writeln('<comment>No slot assignments provided; nothing to do.</comment>');
            return 0;
        }

        $dryRun = (bool) $input->getOption('dry-run');
        $result = (new SlotRotator($repo, $registry))->rotate($assignments, $dryRun);

        if ($result->isNoOp()) {
            $output->writeln('<info>No changes required (already at target slot values).</info>');
            return 0;
        }

        foreach ($result->changedFiles as $path) {
            $output->writeln(($dryRun ? '[dry-run] ' : '') . 'changed: ' . $path);
        }
        return 0;
    })
    ->run();
