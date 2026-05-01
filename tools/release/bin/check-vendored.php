#!/usr/bin/env php
<?php

/**
 * Fail if a consumer repo's vendored copies of cross-repo contracts have
 * drifted from the canonical sources here.
 *
 * Run by CI in consumer repos (openemr/openemr, openemr/website-openemr) to
 * catch the case where the canonical contract is updated but a vendored
 * copy is not refreshed.
 *
 * @package   openemr-devops
 * @link      https://www.open-emr.org
 * @author    Michael A. Smith <michael@opencoreemr.com>
 * @copyright Copyright (c) 2026 OpenCoreEMR Inc.
 * @license   https://github.com/openemr/openemr-devops/blob/master/LICENSE GNU General Public License 3
 */

declare(strict_types=1);

require dirname(__DIR__) . '/vendor/autoload.php';

use OpenEMR\Release\VendoredFileChecker;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\OutputInterface;
use Symfony\Component\Console\SingleCommandApplication;

(new SingleCommandApplication())
    ->setName('check-vendored')
    ->setDescription('Verify a consumer repo vendored copy matches the canonical contract')
    ->addOption(
        'canonical',
        null,
        InputOption::VALUE_REQUIRED,
        'Path to the canonical tools/release/ root',
        dirname(__DIR__),
    )
    ->addOption(
        'consumer',
        null,
        InputOption::VALUE_REQUIRED,
        'Path to the consumer repo dir holding the vendored copies',
    )
    ->setCode(function (InputInterface $input, OutputInterface $output): int {
        $canonical = $input->getOption('canonical');
        if (!is_string($canonical) || $canonical === '') {
            $output->writeln('<error>--canonical is required</error>');
            return 1;
        }
        if (!is_dir($canonical)) {
            $output->writeln(sprintf('<error>Canonical dir not found: %s</error>', $canonical));
            return 1;
        }

        $consumer = $input->getOption('consumer');
        if (!is_string($consumer) || $consumer === '') {
            $output->writeln('<error>--consumer is required</error>');
            return 1;
        }
        if (!is_dir($consumer)) {
            $output->writeln(sprintf('<error>Consumer dir not found: %s</error>', $consumer));
            return 1;
        }

        $issues = (new VendoredFileChecker($canonical, $consumer))->check();
        if ($issues === []) {
            $output->writeln(sprintf(
                '<info>✓</info> All %d vendored file(s) match canonical.',
                count(VendoredFileChecker::VENDORED_PATHS),
            ));
            return 0;
        }

        $output->writeln(sprintf('<error>✗</error> Vendored drift detected (%d issue(s)):', count($issues)));
        foreach ($issues as $issue) {
            $output->writeln(sprintf('  %s  [%s]  %s', $issue->relativePath, $issue->kind, $issue->message));
        }
        $output->writeln('');
        $output->writeln('Re-vendor each drifted file from the canonical openemr-devops checkout.');
        return 1;
    })
    ->run();
