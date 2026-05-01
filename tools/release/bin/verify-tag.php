#!/usr/bin/env php
<?php

/**
 * Verify a release tag against the openemr-devops#664 spec.
 *
 * @package   openemr-devops
 * @link      https://www.open-emr.org
 * @author    Michael A. Smith <michael@opencoreemr.com>
 * @copyright Copyright (c) 2026 OpenCoreEMR Inc.
 * @license   https://github.com/openemr/openemr-devops/blob/master/LICENSE GNU General Public License 3
 */

declare(strict_types=1);

require dirname(__DIR__) . '/vendor/autoload.php';

use OpenEMR\Release\TagVerifier;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\OutputInterface;
use Symfony\Component\Console\SingleCommandApplication;

(new SingleCommandApplication())
    ->setName('verify-tag')
    ->setDescription('Verify a release tag is annotated and well-formed per openemr-devops#664')
    ->addOption(
        'repo',
        null,
        InputOption::VALUE_REQUIRED,
        'Path to the git repository containing the tag',
        getcwd() === false ? '.' : getcwd(),
    )
    ->addOption('tag', null, InputOption::VALUE_REQUIRED, 'Tag name to verify (e.g. v8_1_0)')
    ->setCode(function (InputInterface $input, OutputInterface $output): int {
        $repo = $input->getOption('repo');
        if (!is_string($repo) || $repo === '') {
            $output->writeln('<error>--repo is required</error>');
            return 1;
        }

        $tag = $input->getOption('tag');
        if (!is_string($tag) || $tag === '') {
            $output->writeln('<error>--tag is required</error>');
            return 1;
        }

        $result = (new TagVerifier($repo))->verify($tag);

        if ($result->isValid()) {
            $output->writeln(sprintf(
                '<info>✓</info> %s: annotated, version=%s date=%s merge=%s',
                $result->tagName,
                $result->version ?? '?',
                $result->date ?? '?',
                $result->mergeSha ?? '?',
            ));
            return 0;
        }

        $output->writeln(sprintf('<error>✗</error> %s failed verification:', $result->tagName));
        foreach ($result->errors as $err) {
            $output->writeln('  - ' . $err);
        }
        return 1;
    })
    ->run();
