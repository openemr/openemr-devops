#!/usr/bin/env php
<?php

/**
 * Render per-channel release-announcement drafts to a directory.
 *
 * Wraps AnnouncementRenderer; called by .github/workflows/release-announcements.yml
 * on openemr-tag dispatch (or workflow_dispatch). Writes one file per channel
 * plus a synthesized mail.eml preview the maintainer can drag into a mail
 * client. No posting, no sending. See openemr/openemr-devops#719.
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
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\ConsoleOutputInterface;
use Symfony\Component\Console\Output\OutputInterface;
use Symfony\Component\Console\SingleCommandApplication;

(new SingleCommandApplication())
    ->setName('render-announcements')
    ->setDescription('Render per-channel release-announcement drafts')
    ->addOption(
        'template-dir',
        null,
        InputOption::VALUE_REQUIRED,
        'Twig template directory (defaults to the binary\'s sibling templates/ dir)',
    )
    ->addOption('output-dir', null, InputOption::VALUE_REQUIRED, 'Directory to write per-channel files into')
    ->addOption('release-version', null, InputOption::VALUE_REQUIRED, 'Release version (e.g. 8.1.0)')
    ->addOption('release-tag', null, InputOption::VALUE_REQUIRED, 'Annotated release tag (e.g. v8_1_0)')
    ->addOption('release-branch', null, InputOption::VALUE_REQUIRED, 'Release branch (e.g. rel-810)')
    ->addOption(
        'release-url',
        null,
        InputOption::VALUE_REQUIRED,
        'GitHub release URL (defaults to https://github.com/openemr/openemr/releases/tag/<tag>)',
    )
    ->addOption(
        'release-notes-url',
        null,
        InputOption::VALUE_REQUIRED,
        'Release-notes URL (defaults to the wiki Release Features anchor for the version)',
    )
    ->addOption(
        'forum-url',
        null,
        InputOption::VALUE_REQUIRED,
        'Per-release Discourse thread URL; left as a placeholder if not supplied',
        AnnouncementRenderer::FORUM_URL_PLACEHOLDER,
    )
    ->setCode(function (InputInterface $input, OutputInterface $output): int {
        $err = $output instanceof ConsoleOutputInterface ? $output->getErrorOutput() : $output;
        $templateDir = $input->getOption('template-dir');
        if (!is_string($templateDir) || $templateDir === '') {
            $templateDir = dirname(__DIR__) . '/templates';
        }
        if (!is_dir($templateDir)) {
            $err->writeln("<error>Template directory not found: {$templateDir}</error>");
            return 1;
        }

        $outputDir = $input->getOption('output-dir');
        if (!is_string($outputDir) || $outputDir === '') {
            $err->writeln('<error>--output-dir is required</error>');
            return 1;
        }
        if (!is_dir($outputDir) && !mkdir($outputDir, 0755, true) && !is_dir($outputDir)) {
            $err->writeln("<error>Failed to create output dir: {$outputDir}</error>");
            return 1;
        }

        foreach (['release-version', 'release-tag', 'release-branch'] as $required) {
            $value = $input->getOption($required);
            if (!is_string($value) || $value === '') {
                $err->writeln("<error>--{$required} is required</error>");
                return 1;
            }
        }

        /** @var string $version */
        $version = $input->getOption('release-version');
        /** @var string $tag */
        $tag = $input->getOption('release-tag');
        /** @var string $branch */
        $branch = $input->getOption('release-branch');

        $releaseUrl = $input->getOption('release-url');
        if (!is_string($releaseUrl) || $releaseUrl === '') {
            $releaseUrl = "https://github.com/openemr/openemr/releases/tag/{$tag}";
        }

        $releaseNotesUrl = $input->getOption('release-notes-url');
        if (!is_string($releaseNotesUrl) || $releaseNotesUrl === '') {
            $releaseNotesUrl = 'https://www.open-emr.org/wiki/index.php/Release_Features#Version_' . $version;
        }

        $forumUrl = $input->getOption('forum-url');
        if (!is_string($forumUrl) || $forumUrl === '') {
            $forumUrl = AnnouncementRenderer::FORUM_URL_PLACEHOLDER;
        }

        $context = [
            'version' => $version,
            'tag' => $tag,
            'branch' => $branch,
            'release_url' => $releaseUrl,
            'release_notes_url' => $releaseNotesUrl,
            'forum_url' => $forumUrl,
        ];

        $rendered = (new AnnouncementRenderer($templateDir))->renderAll($context);

        foreach ($rendered as $name => $body) {
            file_put_contents($outputDir . '/' . $name, $body);
            $output->writeln("Wrote <info>{$name}</info>");
        }

        // .eml is a preview only: oe-sender.js hard-codes Source and reads
        // recipients from DynamoDB; these headers exist so the maintainer can
        // open the file in a mail client to eyeball the rendered HTML.
        $emlHeaders = implode("\r\n", [
            'From: OpenEMR <no-reply@open-emr.org>',
            'To: OpenEMR Announce <announce@open-emr.org>',
            'Subject: ' . trim($rendered['mail.subject.txt']),
            'MIME-Version: 1.0',
            'Content-Type: text/html; charset=UTF-8',
            'Content-Transfer-Encoding: 8bit',
        ]);
        file_put_contents($outputDir . '/mail.eml', $emlHeaders . "\r\n\r\n" . $rendered['mail.html']);
        $output->writeln('Wrote <info>mail.eml</info> (preview)');

        return 0;
    })
    ->run();
