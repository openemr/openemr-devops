<?php

/**
 * Open or update the long-lived rotation draft PR for the 3-slot model.
 *
 * Body markdown is built in {@see buildBody()} (pure, unit-testable). PR
 * lookup, create, and edit shell out to the gh CLI — that uses the ambient
 * GH_TOKEN env var, which the workflow sets to the release App's token.
 *
 * @package   openemr-devops
 * @link      https://www.open-emr.org
 * @author    Michael A. Smith <michael@opencoreemr.com>
 * @copyright Copyright (c) 2026 OpenCoreEMR Inc.
 * @license   https://github.com/openemr/openemr-devops/blob/master/LICENSE GNU General Public License 3
 */

declare(strict_types=1);

namespace OpenEMR\Release;

use Symfony\Component\Process\Process;

final readonly class RotationPrPublisher
{
    public function __construct(
        private string $branch,
        private string $base,
        private string $title = 'Release rotation (auto)',
    ) {
    }

    /**
     * Returns the PR number that was created or updated.
     */
    public function publish(string $body): int
    {
        $bodyFile = tempnam(sys_get_temp_dir(), 'rotation-pr-body-');
        if ($bodyFile === false) {
            throw new \RuntimeException('Failed to allocate temp file for PR body');
        }
        file_put_contents($bodyFile, $body);

        try {
            $existing = $this->findOpenPrNumber();
            if ($existing !== null) {
                $this->run(['gh', 'pr', 'edit', (string) $existing, '--body-file', $bodyFile]);
                return $existing;
            }
            $this->run([
                'gh', 'pr', 'create',
                '--draft',
                '--base', $this->base,
                '--head', $this->branch,
                '--title', $this->title,
                '--body-file', $bodyFile,
            ]);
            $created = $this->findOpenPrNumber();
            if ($created === null) {
                throw new \RuntimeException('PR was created but cannot be located by head/base');
            }
            return $created;
        } finally {
            @unlink($bodyFile);
        }
    }

    public static function stringOrEmpty(mixed $value): string
    {
        return is_string($value) ? $value : '';
    }

    public static function buildBody(
        string $trigger,
        string $runUrl,
        string $current,
        string $next,
        string $dev,
    ): string {
        $lines = [
            sprintf('Automated rotation triggered by `%s`.', $trigger),
            '',
        ];
        if ($runUrl !== '') {
            $lines[] = sprintf('Run: %s', $runUrl);
            $lines[] = '';
        }
        $lines[] = 'Slot assignments applied:';
        foreach (['current' => $current, 'next' => $next, 'dev' => $dev] as $slot => $value) {
            if ($value !== '') {
                $lines[] = sprintf('- %s=%s', $slot, $value);
            }
        }
        return implode("\n", $lines) . "\n";
    }

    private function findOpenPrNumber(): ?int
    {
        $process = new Process([
            'gh', 'pr', 'list',
            '--state', 'open',
            '--head', $this->branch,
            '--base', $this->base,
            '--json', 'number',
            '--jq', '.[0].number // ""',
        ]);
        $process->mustRun();
        $out = trim($process->getOutput());
        return $out === '' ? null : (int) $out;
    }

    /**
     * @param list<string> $argv
     */
    private function run(array $argv): void
    {
        $process = new Process($argv);
        $process->setTimeout(120.0);
        $process->mustRun();
    }
}
