#!/usr/bin/env php
<?php

/**
 * Translate a `repository_dispatch` envelope into the slot-assignment lines
 * that bin/rotate.php consumes via `--current=… --next=… --dev=…`.
 *
 * Reads the envelope from --payload-file (use '-' for stdin), pairs it with
 * --event-type, and prints lines:
 *
 *     current=<minor or empty>
 *     next=<minor or empty>
 *     dev=<minor or empty>
 *
 * Suitable for piping into $GITHUB_OUTPUT inside a workflow step.
 *
 * @package   openemr-devops
 * @link      https://www.open-emr.org
 * @author    Michael A. Smith <michael@opencoreemr.com>
 * @copyright Copyright (c) 2026 OpenCoreEMR Inc.
 * @license   https://github.com/openemr/openemr-devops/blob/master/LICENSE GNU General Public License 3
 */

declare(strict_types=1);

require dirname(__DIR__) . '/vendor/autoload.php';

use OpenEMR\Release\SlotAssignmentParser;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\OutputInterface;
use Symfony\Component\Console\SingleCommandApplication;

(new SingleCommandApplication())
    ->setName('derive-slots-from-dispatch')
    ->setDescription('Convert a repository_dispatch envelope into slot=<value> lines for rotate.php')
    ->addOption('event-type', null, InputOption::VALUE_REQUIRED, 'Dispatch event type (e.g. openemr-rel-cut)')
    ->addOption(
        'payload-file',
        null,
        InputOption::VALUE_REQUIRED,
        "Path to JSON envelope (use '-' for stdin)",
    )
    ->setCode(function (InputInterface $input, OutputInterface $output): int {
        $eventType = $input->getOption('event-type');
        if (!is_string($eventType) || $eventType === '') {
            $output->writeln('<error>--event-type is required</error>');
            return 1;
        }
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
        $envelope = json_decode($raw, true);
        if (!is_array($envelope)) {
            $output->writeln(sprintf('<error>Payload is not a JSON object: %s</error>', $payloadFile));
            return 1;
        }
        $normalized = [];
        foreach ($envelope as $key => $value) {
            if (!is_string($key)) {
                $output->writeln(sprintf('<error>Payload root has non-string key: %s</error>', $payloadFile));
                return 1;
            }
            $normalized[$key] = $value;
        }

        $assignments = (new SlotAssignmentParser())->fromDispatchPayload($eventType, $normalized);
        foreach (['current', 'next', 'dev'] as $slot) {
            $output->writeln(sprintf('%s=%s', $slot, $assignments[$slot] ?? ''));
        }
        return 0;
    })
    ->run();
