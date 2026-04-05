#!/usr/bin/env php
<?php

/**
 * Generate a changelog from the commit range between two git refs.
 *
 * @package   openemr-devops
 * @link      https://www.open-emr.org
 * @author    Michael A. Smith <michael@opencoreemr.com>
 * @copyright Copyright (c) 2026 OpenCoreEMR Inc.
 * @license   https://github.com/openemr/openemr-devops/blob/master/LICENSE GNU General Public License 3
 */

declare(strict_types=1);

require dirname(__DIR__) . '/vendor/autoload.php';

use OpenEMR\Release\ChangelogGenerator;
use OpenEMR\Release\GitHubApi;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\OutputInterface;
use Symfony\Component\Console\SingleCommandApplication;

(new SingleCommandApplication())
    ->setName('changelog')
    ->setDescription('Generate changelog from a commit range')
    ->addOption('base', 'b', InputOption::VALUE_REQUIRED, 'Base ref (tag)')
    ->addOption('head', null, InputOption::VALUE_REQUIRED, 'Head ref (tag or branch)', 'HEAD')
    ->addOption('title', 't', InputOption::VALUE_REQUIRED, 'Version string for the heading')
    ->addOption('no-ghsa', null, InputOption::VALUE_NONE, 'Disable security advisories section')
    ->addOption('repo', 'r', InputOption::VALUE_REQUIRED, 'GitHub repo (owner/name)', 'openemr/openemr')
    ->addOption('output', 'o', InputOption::VALUE_REQUIRED, 'Output file path (omit for stdout)')
    ->setCode(function (InputInterface $input, OutputInterface $output): int {
        /** @var ?string $base */
        $base = $input->getOption('base');
        if ($base === null) {
            $output->writeln('<error>--base is required</error>');
            return 1;
        }

        /** @var string $head */
        $head = $input->getOption('head');
        /** @var ?string $title */
        $title = $input->getOption('title');
        $includeGhsa = $input->getOption('no-ghsa') !== true;

        /** @var string $repo */
        $repo = $input->getOption('repo');
        $api = new GitHubApi($repo);

        $output->writeln(
            "Generating changelog for <info>{$base}...{$head}</info>",
            OutputInterface::VERBOSITY_VERBOSE,
        );

        $generator = new ChangelogGenerator($api, $repo);
        $changelog = $generator->generate($base, $head, $title, $includeGhsa);

        /** @var ?string $outputFile */
        $outputFile = $input->getOption('output');
        if ($outputFile !== null) {
            $dir = dirname($outputFile);
            if (!is_dir($dir)) {
                mkdir($dir, 0755, true);
            }
            file_put_contents($outputFile, $changelog);
            $output->writeln("Changelog written to <info>{$outputFile}</info>");
        } else {
            $output->write($changelog);
        }

        return 0;
    })
    ->run();
