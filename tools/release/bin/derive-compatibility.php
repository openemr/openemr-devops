#!/usr/bin/env php
<?php

/**
 * Emit a per-release tested-compatibility manifest (compatibility.json) derived
 * from a checked-out openemr/openemr release branch's CI test matrix.
 *
 * Thin CLI wrapper around OpenEMR\Release\CompatibilityDeriver; see that class
 * for the decode rules and rationale (they mirror ci/parse_docker_dir.sh).
 *
 * @package   openemr-devops
 * @link      https://www.open-emr.org
 * @author    Michael A. Smith <michael@opencoreemr.com>
 * @copyright Copyright (c) 2026 OpenCoreEMR Inc.
 * @license   https://github.com/openemr/openemr-devops/blob/master/LICENSE GNU General Public License 3
 */

declare(strict_types=1);

require dirname(__DIR__) . '/vendor/autoload.php';

use OpenEMR\Release\CompatibilityDeriver;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\OutputInterface;
use Symfony\Component\Console\SingleCommandApplication;

(new SingleCommandApplication())
    ->setName('derive-compatibility')
    ->setDescription('Derive the tested-compatibility manifest from the openemr CI matrix')
    ->addOption(
        'openemr-dir',
        null,
        InputOption::VALUE_REQUIRED,
        'Path to the checked-out openemr release branch (defaults to $OPENEMR_DIR)',
    )
    ->addOption('release-version', null, InputOption::VALUE_REQUIRED, 'Release version (e.g., 8.1.0)')
    ->addOption(
        'version-branch',
        null,
        InputOption::VALUE_REQUIRED,
        'Release branch for the CI matrix link (e.g., rel-810)',
    )
    ->addOption('repo', null, InputOption::VALUE_REQUIRED, 'GitHub repo hosting the CI matrix', 'openemr/openemr')
    ->addOption('out', null, InputOption::VALUE_REQUIRED, 'Output file path', './release-output/compatibility.json')
    ->setCode(function (InputInterface $input, OutputInterface $output): int {
        $openemrDirOption = $input->getOption('openemr-dir');
        $envOpenemrDir = getenv('OPENEMR_DIR');
        $openemrDir = is_string($openemrDirOption) && $openemrDirOption !== ''
            ? $openemrDirOption
            : (is_string($envOpenemrDir) ? $envOpenemrDir : '');
        if ($openemrDir === '') {
            $output->writeln('<error>--openemr-dir is required (or set $OPENEMR_DIR)</error>');
            return 1;
        }

        $versionOption = $input->getOption('release-version');
        if (!is_string($versionOption) || $versionOption === '') {
            $output->writeln('<error>--release-version is required</error>');
            return 1;
        }

        $versionBranchOption = $input->getOption('version-branch');
        if (!is_string($versionBranchOption) || $versionBranchOption === '') {
            $output->writeln('<error>--version-branch is required</error>');
            return 1;
        }

        $repoOption = $input->getOption('repo');
        $repo = is_string($repoOption) && $repoOption !== '' ? $repoOption : 'openemr/openemr';

        $testedMatrixUrl = sprintf(
            'https://github.com/%s/tree/%s/ci',
            $repo,
            $versionBranchOption,
        );

        $outOption = $input->getOption('out');
        $outPath = is_string($outOption) && $outOption !== ''
            ? $outOption
            : './release-output/compatibility.json';

        $ciDir = rtrim($openemrDir, '/') . '/ci';

        try {
            $manifest = (new CompatibilityDeriver($ciDir, $versionOption, $testedMatrixUrl))->derive();
        } catch (\RuntimeException $e) {
            $output->writeln(sprintf('<error>%s</error>', $e->getMessage()));
            return 1;
        }

        $json = json_encode($manifest, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR) . "\n";

        $outDir = dirname($outPath);
        if (!is_dir($outDir) && !mkdir($outDir, 0755, true) && !is_dir($outDir)) {
            $output->writeln("<error>Could not create output directory: {$outDir}</error>");
            return 1;
        }
        if (file_put_contents($outPath, $json) === false) {
            $output->writeln("<error>Could not write manifest to: {$outPath}</error>");
            return 1;
        }

        $output->writeln("<info>Wrote</info> {$outPath}");
        $output->write($json);
        return 0;
    })
    ->run();
