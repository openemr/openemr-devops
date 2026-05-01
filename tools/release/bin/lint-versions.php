#!/usr/bin/env php
<?php

/**
 * Fail if any tracked file contains an OpenEMR version pin that isn't
 * enumerated in tools/release/versions.yml (under `files:` or `excludes:`).
 *
 * Run by CI on every PR; catches contributors who add a new pinned file
 * without registering it in the rotation system.
 *
 * @package   openemr-devops
 * @link      https://www.open-emr.org
 * @author    Michael A. Smith <michael@opencoreemr.com>
 * @copyright Copyright (c) 2026 OpenCoreEMR Inc.
 * @license   https://github.com/openemr/openemr-devops/blob/master/LICENSE GNU General Public License 3
 */

declare(strict_types=1);

require dirname(__DIR__) . '/vendor/autoload.php';

use OpenEMR\Release\VersionsRegistryLinter;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\OutputInterface;
use Symfony\Component\Console\SingleCommandApplication;

(new SingleCommandApplication())
    ->setName('lint-versions')
    ->setDescription('Verify every OpenEMR version pin is enumerated in versions.yml')
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

        $issues = (new VersionsRegistryLinter($repo, $registry))->lint();
        if ($issues === []) {
            $output->writeln('<info>✓</info> No drifted version pins.');
            return 0;
        }

        $output->writeln(sprintf('<error>✗</error> Found %d unregistered pin(s):', count($issues)));
        foreach ($issues as $issue) {
            $output->writeln(sprintf(
                '  %s:%d  [%s]  %s',
                $issue->path,
                $issue->line,
                $issue->patternKind,
                $issue->matched,
            ));
        }
        $output->writeln('');
        $output->writeln('Add each file to `files:` (under rotation) or `excludes:` (with reason) in versions.yml.');
        return 1;
    })
    ->run();
