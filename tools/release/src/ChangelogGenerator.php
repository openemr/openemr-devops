<?php

/**
 * Generate a changelog from GitHub milestone issues.
 *
 * Categorize issues by title prefix (feat: → Added, bug: → Fixed, others → Changed)
 * and separate issues labeled "developers" into their own section.
 *
 * Extracted from openemr/openemr CreateReleaseChangelogCommand by Stephen Nielson.
 *
 * @package   openemr
 * @link      https://www.open-emr.org
 * @author    Stephen Nielson <snielson@discoverandchange.com>
 * @author    Michael A. Smith <michael@opencoreemr.com>
 * @copyright Copyright (c) 2023 Discover and Change, Inc. <snielson@discoverandchange.com>
 * @copyright Copyright (c) 2026 OpenCoreEMR Inc.
 * @license   https://github.com/openemr/openemr-devops/blob/master/LICENSE GNU General Public License 3
 */

declare(strict_types=1);

namespace OpenEMR\Release;

class ChangelogGenerator
{
    /**
     * @param list<array<string, mixed>> $issues Raw issues from the GitHub API
     * @return array{number: int, category: string, title: string, url: string, is_dev: bool}
     */
    private static function categorize(array $issue): array
    {
        $title = (string) $issue['title'];
        $category = 'bug';

        $parts = explode(':', $title, 2);
        if (count($parts) > 1) {
            $category = trim($parts[0]);
            $title = trim($parts[1]);
        }

        $isDev = false;
        foreach ($issue['labels'] ?? [] as $label) {
            if ($label['name'] === 'developers') {
                $isDev = true;
                break;
            }
        }

        return [
            'number' => (int) $issue['number'],
            'category' => $category,
            'title' => $title,
            'url' => (string) $issue['html_url'],
            'is_dev' => $isDev,
        ];
    }

    /**
     * Generate a markdown changelog for the given milestone.
     *
     * @param list<array<string, mixed>> $issues Raw issues from the GitHub API
     */
    public function generate(string $milestone, int $milestoneNumber, string $repo, array $issues): string
    {
        $categorized = array_map(self::categorize(...), $issues);
        usort($categorized, fn(array $a, array $b): int => strcasecmp($a['title'], $b['title']));

        $standard = array_values(array_filter($categorized, fn(array $i): bool => !$i['is_dev']));
        $developer = array_values(array_filter($categorized, fn(array $i): bool => $i['is_dev']));

        $lines = [];
        $lines[] = "## [{$milestone}](https://github.com/{$repo}/milestone/{$milestoneNumber}?closed=1) - " . date('Y-m-d');
        $lines[] = '';
        $lines = array_merge($lines, self::formatIssues($standard));

        if (count($developer) > 0) {
            $lines[] = '### OpenEMR Developer Changes';
            $lines[] = '';
            $lines = array_merge($lines, self::formatIssues($developer));
        }

        return implode("\n", $lines) . "\n";
    }

    /**
     * @param list<array{number: int, category: string, title: string, url: string, is_dev: bool}> $issues
     * @return list<string>
     */
    private static function formatIssues(array $issues): array
    {
        return array_merge(
            self::formatByCategory($issues, 'feat', 'Added'),
            self::formatByCategory($issues, 'bug', 'Fixed'),
            self::formatOther($issues),
        );
    }

    /**
     * @param list<array{number: int, category: string, title: string, url: string, is_dev: bool}> $issues
     * @return list<string>
     */
    private static function formatByCategory(array $issues, string $category, string $heading): array
    {
        $matches = array_filter($issues, fn(array $i): bool => $i['category'] === $category);
        if (count($matches) === 0) {
            return [];
        }

        $lines = ["### {$heading}", ''];
        foreach ($matches as $issue) {
            $lines[] = "  - {$issue['title']} ([#{$issue['number']}]({$issue['url']}))";
        }
        $lines[] = '';

        return $lines;
    }

    /**
     * @param list<array{number: int, category: string, title: string, url: string, is_dev: bool}> $issues
     * @return list<string>
     */
    private static function formatOther(array $issues): array
    {
        $matches = array_filter($issues, fn(array $i): bool => !in_array($i['category'], ['feat', 'bug'], true));
        if (count($matches) === 0) {
            return [];
        }

        $lines = ['### Changed', ''];
        foreach ($matches as $issue) {
            $lines[] = "  - {$issue['title']} ([#{$issue['number']}]({$issue['url']}))";
        }
        $lines[] = '';

        return $lines;
    }
}
