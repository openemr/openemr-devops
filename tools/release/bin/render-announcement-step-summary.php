#!/usr/bin/env php
<?php

/**
 * Render the GitHub Actions step-summary markdown for the
 * release-announcements workflow.
 *
 * Reads the per-channel files AnnouncementRenderer wrote into
 * --output-dir and emits the summary markdown to stdout (or --output);
 * the workflow appends it to $GITHUB_STEP_SUMMARY.
 *
 * @package   openemr-devops
 * @link      https://www.open-emr.org
 * @author    Michael A. Smith <michael@opencoreemr.com>
 * @copyright Copyright (c) 2026 OpenCoreEMR Inc.
 * @license   https://github.com/openemr/openemr-devops/blob/master/LICENSE GNU General Public License 3
 */

declare(strict_types=1);

require dirname(__DIR__) . '/vendor/autoload.php';

use OpenEMR\Release\AnnouncementRenderer;
use OpenEMR\Release\AnnouncementStepSummaryRenderer;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\ConsoleOutputInterface;
use Symfony\Component\Console\Output\OutputInterface;
use Symfony\Component\Console\SingleCommandApplication;

(new SingleCommandApplication())
    ->setName('render-announcement-step-summary')
    ->setDescription('Render the GitHub Actions step-summary markdown for the announcement drafts')
    ->addOption(
        'template-dir',
        null,
        InputOption::VALUE_REQUIRED,
        'Twig template directory (defaults to the binary\'s sibling templates/ dir)',
    )
    ->addOption('output-dir', null, InputOption::VALUE_REQUIRED, 'Directory containing the per-channel rendered files')
    ->addOption('release-version', null, InputOption::VALUE_REQUIRED, 'Release version (e.g. 8.1.0)')
    ->addOption('release-tag', null, InputOption::VALUE_REQUIRED, 'Annotated release tag (e.g. v8_1_0)')
    ->addOption(
        'forum-url',
        null,
        InputOption::VALUE_REQUIRED,
        'Forum URL value rendered into the summary; defaults to the placeholder',
        AnnouncementRenderer::FORUM_URL_PLACEHOLDER,
    )
    ->addOption('output', 'o', InputOption::VALUE_REQUIRED, 'Output file (defaults to stdout)')
    ->setCode(function (InputInterface $input, OutputInterface $output): int {
        $err = $output instanceof ConsoleOutputInterface ? $output->getErrorOutput() : $output;
        $templateDir = $input->getOption('template-dir');
        if (!is_string($templateDir) || $templateDir === '') {
            $templateDir = dirname(__DIR__) . '/templates';
        }

        foreach (['output-dir', 'release-version', 'release-tag'] as $required) {
            $value = $input->getOption($required);
            if (!is_string($value) || $value === '') {
                $err->writeln(sprintf('<error>--%s is required</error>', $required));
                return 1;
            }
        }
        /** @var string $outputDir */
        $outputDir = $input->getOption('output-dir');
        /** @var string $version */
        $version = $input->getOption('release-version');
        /** @var string $tag */
        $tag = $input->getOption('release-tag');
        $forumUrl = $input->getOption('forum-url');
        if (!is_string($forumUrl) || $forumUrl === '') {
            $forumUrl = AnnouncementRenderer::FORUM_URL_PLACEHOLDER;
        }

        $rendered = (new AnnouncementStepSummaryRenderer($templateDir))->render($outputDir, $version, $tag, $forumUrl);

        $target = $input->getOption('output');
        if (is_string($target) && $target !== '') {
            file_put_contents($target, $rendered);
            return 0;
        }
        $output->write($rendered);
        return 0;
    })
    ->run();
