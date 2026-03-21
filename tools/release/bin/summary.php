#!/usr/bin/env php
<?php

/**
 * Generate a release summary for GitHub step summary.
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

(new SingleCommandApplication())
    ->setName('summary')
    ->setDescription('Generate release summary for GitHub step summary')
    ->addOption('type', null, InputOption::VALUE_REQUIRED, 'Release type: "patch" or "full"')
    ->addOption('milestone', 'm', InputOption::VALUE_REQUIRED, 'Milestone name')
    ->addOption('output-dir', null, InputOption::VALUE_REQUIRED, 'Release artifacts directory', './release-output')
    ->addOption('output', 'o', InputOption::VALUE_REQUIRED, 'Output file (or GITHUB_STEP_SUMMARY)')
    ->setCode(function (InputInterface $input, OutputInterface $output): int {
        /** @var string $type */
        $type = $input->getOption('type');
        /** @var string $milestone */
        $milestone = $input->getOption('milestone');
        /** @var string $outputDir */
        $outputDir = $input->getOption('output-dir');

        foreach (['type', 'milestone'] as $required) {
            if ($input->getOption($required) === null) {
                $output->writeln("<error>--{$required} is required</error>");
                return 1;
            }
        }

        if (!in_array($type, ['patch', 'full'], true)) {
            $output->writeln('<error>--type must be "patch" or "full"</error>');
            return 1;
        }

        $lines = [];
        $lines[] = "## Release Summary: {$milestone}";
        $lines[] = '';

        // Include checksums if available
        foreach (['md5', 'sha256', 'sha512'] as $ext) {
            $globResult = glob("{$outputDir}/*.{$ext}");
            if ($globResult === false) {
                continue;
            }
            foreach ($globResult as $file) {
                $content = trim((string) file_get_contents($file));
                $lines[] = "**" . basename($file) . ":** `{$content}`";
            }
        }
        $lines[] = '';

        // Include changelog
        $changelogFile = "{$outputDir}/changelog.md";
        if (file_exists($changelogFile)) {
            $lines[] = trim((string) file_get_contents($changelogFile));
            $lines[] = '';
        }

        // Include changed files if patch
        $changedFilesPath = "{$outputDir}/changed-files.txt";
        if ($type === 'patch' && file_exists($changedFilesPath)) {
            $changedFiles = file($changedFilesPath, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
            if ($changedFiles !== false) {
                sort($changedFiles);
                $count = count($changedFiles);
                $lines[] = "<details><summary>Changed files ({$count})</summary>";
                $lines[] = '';
                $lines[] = '```';
                foreach ($changedFiles as $file) {
                    $lines[] = $file;
                }
                $lines[] = '```';
                $lines[] = '</details>';
                $lines[] = '';
            }
        }

        // Manual checklist
        $lines[] = '### Post-Release Checklist';
        $lines[] = '';
        $lines[] = '- [ ] Upload to SourceForge';
        $lines[] = '- [ ] Update Docker version files';
        $lines[] = '- [ ] Update website';
        $lines[] = '- [ ] Update wiki';
        $lines[] = '- [ ] Post announcement to community forum';
        $lines[] = '- [ ] Post announcement to chat';

        $content = implode("\n", $lines) . "\n";

        // Determine output destination
        /** @var ?string $outputFile */
        $outputFile = $input->getOption('output');
        $envSummary = getenv('GITHUB_STEP_SUMMARY');
        $target = $outputFile ?? ($envSummary !== false ? $envSummary : null);

        if ($target !== null) {
            file_put_contents($target, $content, FILE_APPEND);
            $output->writeln("Summary written to <info>{$target}</info>");
        } else {
            $output->write($content);
        }

        return 0;
    })
    ->run();
