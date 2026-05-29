#!/usr/bin/env php
<?php

/**
 * Build the full distribution tarball + zip for an official OpenEMR release.
 *
 * Thin CLI wrapper around OpenEMR\Release\PackageAssembler; see that class for
 * the build steps and rationale.
 *
 * @package   openemr-devops
 * @link      https://www.open-emr.org
 * @author    Michael A. Smith <michael@opencoreemr.com>
 * @copyright Copyright (c) 2026 OpenCoreEMR Inc.
 * @license   https://github.com/openemr/openemr-devops/blob/master/LICENSE GNU General Public License 3
 */

declare(strict_types=1);

require dirname(__DIR__) . '/vendor/autoload.php';

use OpenEMR\Release\PackageAssembler;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\OutputInterface;
use Symfony\Component\Console\SingleCommandApplication;

(new SingleCommandApplication())
    ->setName('package-assemble')
    ->setDescription('Build the full distribution tarball + zip for an official release')
    ->addOption('version', null, InputOption::VALUE_REQUIRED, 'Release version (e.g., 8.1.0)')
    ->addOption('openemr-dir', null, InputOption::VALUE_REQUIRED, 'Path to the checked-out openemr release branch')
    ->addOption('output-dir', null, InputOption::VALUE_REQUIRED, 'Output directory', './release-output')
    ->setCode(function (InputInterface $input, OutputInterface $output): int {
        $versionOption = $input->getOption('version');
        $openemrDirOption = $input->getOption('openemr-dir');
        $outputDirOption = $input->getOption('output-dir');

        if (!is_string($versionOption) || $versionOption === '') {
            $output->writeln('<error>--version is required</error>');
            return 1;
        }
        if (!is_string($openemrDirOption) || $openemrDirOption === '') {
            $output->writeln('<error>--openemr-dir is required</error>');
            return 1;
        }
        $outputDir = is_string($outputDirOption) && $outputDirOption !== ''
            ? rtrim($outputDirOption, '/')
            : './release-output';

        return (new PackageAssembler(
            $versionOption,
            rtrim($openemrDirOption, '/'),
            $outputDir,
            $output,
        ))->assemble();
    })
    ->run();
