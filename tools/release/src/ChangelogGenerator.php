<?php

/**
 * Generate a changelog from the commit range between two git refs.
 *
 * Walk commits between base and head, resolve to merged PRs, parse
 * conventional commit prefixes from PR titles, and match published
 * GHSAs whose fix commits fall in the range.
 *
 * @package   openemr-devops
 * @link      https://www.open-emr.org
 * @author    Stephen Nielson <snielson@discoverandchange.com>
 * @author    Michael A. Smith <michael@opencoreemr.com>
 * @copyright Copyright (c) 2023 Discover and Change, Inc. <snielson@discoverandchange.com>
 * @copyright Copyright (c) 2026 OpenCoreEMR Inc.
 * @license   https://github.com/openemr/openemr-devops/blob/master/LICENSE GNU General Public License 3
 */

declare(strict_types=1);

namespace OpenEMR\Release;

/**
 * @phpstan-type CategorizedPr array{number: int, category: string, title: string, url: string, is_dev: bool}
 * @phpstan-type Advisory array{ghsa_id: string, severity: string, summary: string, url: string}
 */
class ChangelogGenerator
{
    private const CATEGORY_MAP = [
        'feat' => 'Added',
        'fix' => 'Fixed',
        'deps' => 'Dependencies',
    ];

    private const DEFAULT_CATEGORY = 'Changed';

    /** @var string */
    private const CC_PATTERN = '/^(feat|fix|deps|chore|refactor|docs|perf|test|ci|build|style)(\(.+?\))?!?:\s*(.+)$/i';

    public function __construct(
        private readonly GitHubApi $api,
    ) {
    }

    /**
     * Generate a changelog from the commit range between two refs.
     *
     * @param string $base Base ref (tag)
     * @param string $head Head ref (tag or branch)
     * @param ?string $title Version string for the heading (omit for body only)
     * @param bool $includeGhsa Include security advisories section
     */
    public function generate(string $base, string $head, ?string $title = null, bool $includeGhsa = true): string
    {
        $shas = $this->api->commitsBetweenRefs($base, $head);
        $prs = $this->api->prsForCommits($shas);

        $categorized = array_map($this->categorize(...), $prs);
        usort($categorized, static fn(array $a, array $b): int => strcasecmp($a['title'], $b['title']));

        $standard = array_values(array_filter($categorized, static fn(array $i): bool => !$i['is_dev']));
        $developer = array_values(array_filter($categorized, static fn(array $i): bool => $i['is_dev']));

        /** @var list<Advisory> $advisories */
        $advisories = [];
        if ($includeGhsa) {
            $prNumbers = array_map(static fn(array $pr): int => $pr['number'], $categorized);
            $advisories = $this->matchAdvisories($shas, $prNumbers);
        }

        $lines = [];
        if ($title !== null) {
            $lines[] = "## [{$title}] - " . date('Y-m-d');
            $lines[] = '';
        }

        if (count($advisories) > 0) {
            $lines = array_merge($lines, $this->formatAdvisories($advisories));
        }

        $lines = array_merge($lines, $this->formatPrs($standard));

        if (count($developer) > 0) {
            $lines[] = '### OpenEMR Developer Changes';
            $lines[] = '';
            $lines = array_merge($lines, $this->formatPrs($developer));
        }

        return implode("\n", $lines) . "\n";
    }

    /**
     * @param array{number: int, title: string, labels: list<array{name: string}>, url: string} $pr
     * @return CategorizedPr
     */
    private function categorize(array $pr): array
    {
        $title = $pr['title'];
        $category = self::DEFAULT_CATEGORY;

        if (preg_match(self::CC_PATTERN, $title, $matches) === 1) {
            $type = strtolower($matches[1]);
            $category = self::CATEGORY_MAP[$type] ?? self::DEFAULT_CATEGORY;
            $title = trim($matches[3]);
        }

        $isDev = false;
        foreach ($pr['labels'] as $label) {
            if ($label['name'] === 'developers') {
                $isDev = true;
                break;
            }
        }

        return [
            'number' => $pr['number'],
            'category' => $category,
            'title' => $title,
            'url' => $pr['url'],
            'is_dev' => $isDev,
        ];
    }

    /**
     * Match published GHSAs whose fix commits or PRs overlap with this release.
     *
     * @param list<string> $shas Commit SHAs in the release range
     * @param list<int> $prNumbers PR numbers in the release
     * @return list<Advisory>
     */
    private function matchAdvisories(array $shas, array $prNumbers): array
    {
        $allAdvisories = $this->api->publishedAdvisories();
        $shaSet = array_flip($shas);
        $prSet = array_flip($prNumbers);

        $severityOrder = ['critical' => 0, 'high' => 1, 'medium' => 2, 'low' => 3];

        /** @var list<Advisory> $matched */
        $matched = [];

        foreach ($allAdvisories as $advisory) {
            if (!$this->advisoryMatchesRange($advisory, $shaSet, $prSet)) {
                continue;
            }

            $matched[] = [
                'ghsa_id' => is_string($advisory['ghsa_id'] ?? null) ? $advisory['ghsa_id'] : '',
                'severity' => is_string($advisory['severity'] ?? null) ? $advisory['severity'] : 'unknown',
                'summary' => is_string($advisory['summary'] ?? null) ? $advisory['summary'] : '',
                'url' => is_string($advisory['html_url'] ?? null) ? $advisory['html_url'] : '',
            ];
        }

        usort($matched, static function (array $a, array $b) use ($severityOrder): int {
            $aOrder = $severityOrder[$a['severity']] ?? 99;
            $bOrder = $severityOrder[$b['severity']] ?? 99;
            $cmp = $aOrder <=> $bOrder;
            return $cmp !== 0 ? $cmp : strcasecmp($a['summary'], $b['summary']);
        });

        return $matched;
    }

    /**
     * Check if an advisory's references overlap with the commit/PR set.
     *
     * @param array<string, mixed> $advisory
     * @param array<string, int> $shaSet Flipped SHA array for O(1) lookup
     * @param array<int, int> $prSet Flipped PR number array for O(1) lookup
     */
    private function advisoryMatchesRange(array $advisory, array $shaSet, array $prSet): bool
    {
        /** @var list<array<string, mixed>> $references */
        $references = is_array($advisory['references'] ?? null) ? $advisory['references'] : [];

        foreach ($references as $ref) {
            $url = is_string($ref['url'] ?? null) ? $ref['url'] : '';

            // Match commit SHA references
            if (preg_match('#/commit/([0-9a-f]{40})#i', $url, $matches) === 1 && isset($shaSet[$matches[1]])) {
                return true;
            }

            // Match PR number references
            if (preg_match('#/pull/(\d+)#', $url, $matches) === 1 && isset($prSet[(int) $matches[1]])) {
                return true;
            }
        }

        return false;
    }

    /**
     * Format advisories as a Security Fixes section.
     *
     * @param list<Advisory> $advisories
     * @return list<string>
     */
    private function formatAdvisories(array $advisories): array
    {
        $lines = ['### Security Fixes', ''];

        foreach ($advisories as $advisory) {
            $severity = ucfirst($advisory['severity']);
            $lines[] = "  - [{$severity}] {$advisory['summary']} ([{$advisory['ghsa_id']}]({$advisory['url']}))";
        }

        $lines[] = '';
        return $lines;
    }

    /**
     * @param list<CategorizedPr> $prs
     * @return list<string>
     */
    private function formatPrs(array $prs): array
    {
        $sections = ['Added', 'Fixed', 'Changed', 'Dependencies'];
        $lines = [];

        foreach ($sections as $section) {
            $sectionLines = $this->formatByCategory($prs, $section);
            $lines = array_merge($lines, $sectionLines);
        }

        return $lines;
    }

    /**
     * @param list<CategorizedPr> $prs
     * @return list<string>
     */
    private function formatByCategory(array $prs, string $category): array
    {
        $matches = array_filter($prs, static fn(array $i): bool => $i['category'] === $category);
        if (count($matches) === 0) {
            return [];
        }

        $lines = ["### {$category}", ''];
        foreach ($matches as $pr) {
            $lines[] = "  - {$pr['title']} ([#{$pr['number']}]({$pr['url']}))";
        }
        $lines[] = '';

        return $lines;
    }
}
