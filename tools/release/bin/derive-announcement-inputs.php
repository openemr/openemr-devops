#!/usr/bin/env php
<?php

/**
 * Translate an `openemr-tag` repository_dispatch envelope into the
 * `version=` / `tag=` / `branch=` lines the release-announcements
 * workflow appends to $GITHUB_OUTPUT.
 *
 * Validation lives in AnnouncementDispatchPayload (mirrors the canonical
 * dispatch.schema.json patterns); a missing or malformed field aborts
 * the step instead of producing artifacts that reference "null".
 *
 * @package   openemr-devops
 * @link      https://www.open-emr.org
 * @author    Michael A. Smith <michael@opencoreemr.com>
 * @copyright Copyright (c) 2026 OpenCoreEMR Inc.
 * @license   https://github.com/openemr/openemr-devops/blob/master/LICENSE GNU General Public License 3
 */

declare(strict_types=1);

require dirname(__DIR__) . '/vendor/autoload.php';

use OpenEMR\Release\AnnouncementDispatchPayload;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\OutputInterface;
use Symfony\Component\Console\SingleCommandApplication;

(new SingleCommandApplication())
    ->setName('derive-announcement-inputs')
    ->setDescription('Convert an openemr-tag dispatch envelope into key=value lines for the announcements workflow')
    ->addOption(
        'payload-file',
        null,
        InputOption::VALUE_REQUIRED,
        "Path to JSON envelope (use '-' for stdin)",
    )
    ->setCode(function (InputInterface $input, OutputInterface $output): int {
        $payloadFile = $input->getOption('payload-file');
        if (!is_string($payloadFile) || $payloadFile === '') {
            $output->writeln('<error>--payload-file is required (use - for stdin)</error>');
            return 1;
        }

        if ($payloadFile === '-') {
            $raw = (string) file_get_contents('php://stdin');
        } else {
            if (!is_file($payloadFile)) {
                $output->writeln(sprintf('<error>Payload file not found: %s</error>', $payloadFile));
                return 1;
            }
            $contents = file_get_contents($payloadFile);
            if ($contents === false) {
                $output->writeln(sprintf('<error>Payload file unreadable: %s</error>', $payloadFile));
                return 1;
            }
            $raw = $contents;
        }
        if ($raw === '') {
            $output->writeln(sprintf('<error>Empty payload from: %s</error>', $payloadFile));
            return 1;
        }

        try {
            $envelope = json_decode($raw, true, 512, JSON_THROW_ON_ERROR);
            $payload = AnnouncementDispatchPayload::fromEnvelope($envelope);
        } catch (\JsonException $e) {
            $output->writeln(sprintf('<error>Payload is not valid JSON: %s</error>', $e->getMessage()));
            return 1;
        } catch (\RuntimeException $e) {
            $output->writeln(sprintf('<error>%s</error>', $e->getMessage()));
            return 1;
        }

        $output->writeln(sprintf('version=%s', $payload->version));
        $output->writeln(sprintf('tag=%s', $payload->tag));
        $output->writeln(sprintf('branch=%s', $payload->branch));
        return 0;
    })
    ->run();
