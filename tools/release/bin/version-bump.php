#!/usr/bin/env php
<?php

/**
 * Bump version numbers in OpenEMR source files.
 *
 * @package   openemr-devops
 * @link      https://www.open-emr.org
 * @author    Michael A. Smith <michael@opencoreemr.com>
 * @copyright Copyright (c) 2026 OpenCoreEMR Inc.
 * @license   https://github.com/openemr/openemr-devops/blob/master/LICENSE GNU General Public License 3
 */

declare(strict_types=1);

require dirname(__DIR__) . '/vendor/autoload.php';

use OpenEMR\Release\VersionBumper;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\OutputInterface;
use Symfony\Component\Console\SingleCommandApplication;

(new SingleCommandApplication())
    ->setName('version-bump')
    ->setDescription('Bump version numbers in OpenEMR source files')
    ->addOption('mode', null, InputOption::VALUE_REQUIRED, 'Bump mode: "patch" or "full"')
    ->addOption('patch-number', null, InputOption::VALUE_REQUIRED, 'Patch number (required for patch mode)')
    ->addOption('version-file', null, InputOption::VALUE_REQUIRED, 'Path to version.php', 'version.php')
    ->addOption('globals-file', null, InputOption::VALUE_REQUIRED, 'Path to globals.inc.php', 'library/globals.inc.php')
    ->setCode(function (InputInterface $input, OutputInterface $output): int {
        /** @var ?string $mode */
        $mode = $input->getOption('mode');
        if (!in_array($mode, ['patch', 'full'], true)) {
            $output->writeln('<error>--mode must be "patch" or "full"</error>');
            return 1;
        }

        /** @var string $versionFile */
        $versionFile = $input->getOption('version-file');
        if (!file_exists($versionFile)) {
            $output->writeln("<error>Version file not found: {$versionFile}</error>");
            return 1;
        }

        $bumper = new VersionBumper();

        if ($mode === 'patch') {
            /** @var ?string $patchNumber */
            $patchNumber = $input->getOption('patch-number');
            if ($patchNumber === null) {
                $output->writeln('<error>--patch-number is required for patch mode</error>');
                return 1;
            }
            $bumper->bumpPatch($versionFile, $patchNumber);
            $output->writeln("Set \$v_realpatch to <info>{$patchNumber}</info> in {$versionFile}");
        } else {
            $bumper->clearDevTag($versionFile);
            $output->writeln("Removed <info>-dev</info> from \$v_tag in {$versionFile}");

            /** @var string $globalsFile */
            $globalsFile = $input->getOption('globals-file');
            if (file_exists($globalsFile)) {
                $bumper->setGlobalDefault($globalsFile, 'allow_debug_language', '0');
                $output->writeln("Set <info>allow_debug_language</info> default to '0' in {$globalsFile}");
            } else {
                $output->writeln("<comment>Globals file not found, skipping: {$globalsFile}</comment>");
            }
        }

        return 0;
    })
    ->run();
