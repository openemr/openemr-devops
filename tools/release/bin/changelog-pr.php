#!/usr/bin/env php
<?php

/**
 * Create CHANGELOG.md update PRs for release and master branches.
 *
 * @package   openemr-devops
 * @link      https://www.open-emr.org
 * @author    Michael A. Smith <michael@opencoreemr.com>
 * @copyright Copyright (c) 2026 OpenCoreEMR Inc.
 * @license   https://github.com/openemr/openemr-devops/blob/master/LICENSE GNU General Public License 3
 */

declare(strict_types=1);

require dirname(__DIR__) . '/vendor/autoload.php';

use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\OutputInterface;
use Symfony\Component\Console\SingleCommandApplication;
use Symfony\Component\Process\Process;

(new SingleCommandApplication())
    ->setName('changelog-pr')
    ->setDescription('Create CHANGELOG.md update PRs')
    ->addOption('version', null, InputOption::VALUE_REQUIRED, 'Version string (e.g., 8.0.0.3)')
    ->addOption('branches', null, InputOption::VALUE_REQUIRED, 'Comma-separated target branches')
    ->addOption('openemr-dir', null, InputOption::VALUE_REQUIRED, 'Path to openemr checkout')
    ->addOption('changelog-file', null, InputOption::VALUE_REQUIRED, 'Path to changelog entry file')
    ->addOption('repo', 'r', InputOption::VALUE_REQUIRED, 'GitHub repo', 'openemr/openemr')
    ->setCode(function (InputInterface $input, OutputInterface $output): int {
        /** @var string $version */
        $version = $input->getOption('version');
        /** @var string $openemrDir */
        $openemrDir = $input->getOption('openemr-dir');
        /** @var string $changelogFile */
        $changelogFile = $input->getOption('changelog-file');
        /** @var string $repo */
        $repo = $input->getOption('repo');
        /** @var string $branchesRaw */
        $branchesRaw = $input->getOption('branches');

        foreach (['version', 'branches', 'openemr-dir', 'changelog-file'] as $required) {
            if ($input->getOption($required) === null) {
                $output->writeln("<error>--{$required} is required</error>");
                return 1;
            }
        }

        if (!file_exists($changelogFile)) {
            $output->writeln("<error>Changelog file not found: {$changelogFile}</error>");
            return 1;
        }

        $changelogEntry = file_get_contents($changelogFile);
        if ($changelogEntry === false) {
            $output->writeln("<error>Cannot read: {$changelogFile}</error>");
            return 1;
        }

        $branches = explode(',', $branchesRaw);

        foreach ($branches as $branch) {
            $branch = trim($branch);
            $prBranch = "changelog-{$version}-{$branch}";

            // Check if PR already exists
            $check = new Process(
                ['gh', 'pr', 'list', '--repo', $repo, '--head', $prBranch, '--json', 'number', '--jq', 'length'],
            );
            $check->mustRun();
            if ((int) trim($check->getOutput()) > 0) {
                $output->writeln("PR already exists for <comment>{$prBranch}</comment>, skipping");
                continue;
            }

            // Create branch from target
            (new Process(['git', 'checkout', '-b', $prBranch, "origin/{$branch}"], $openemrDir))->mustRun();

            // Prepend changelog entry after the first heading line
            $existingChangelog = file_get_contents("{$openemrDir}/CHANGELOG.md");
            if ($existingChangelog === false) {
                $output->writeln("<error>Cannot read CHANGELOG.md in {$openemrDir}</error>");
                return 1;
            }
            $firstNewline = strpos($existingChangelog, "\n");
            if ($firstNewline === false) {
                $merged = $existingChangelog . "\n\n" . $changelogEntry;
            } else {
                $merged = substr($existingChangelog, 0, $firstNewline + 1)
                    . "\n" . $changelogEntry
                    . substr($existingChangelog, $firstNewline + 1);
            }
            file_put_contents("{$openemrDir}/CHANGELOG.md", $merged);

            // Commit, push, create PR
            (new Process(['git', 'add', 'CHANGELOG.md'], $openemrDir))->mustRun();
            (new Process(
                ['git', 'commit', '-m', "docs: add {$version} changelog"],
                $openemrDir,
            ))->mustRun();
            (new Process(['git', 'push', 'origin', $prBranch], $openemrDir))->mustRun();
            (new Process([
                'gh', 'pr', 'create',
                '--repo', $repo,
                '--base', $branch,
                '--head', $prBranch,
                '--title', "docs: add {$version} changelog",
                '--body', "Add changelog entry for {$version} release.",
            ]))->mustRun();

            $output->writeln("Created PR for <info>{$prBranch}</info> → {$branch}");

            // Return to previous branch
            (new Process(['git', 'checkout', '-'], $openemrDir))->mustRun();
        }

        return 0;
    })
    ->run();
