<?php

/**
 * Render the GitHub Actions step-summary markdown for the
 * release-announcements workflow from the per-channel files
 * AnnouncementRenderer wrote to disk.
 *
 * Reads `forum.md`, `chat.md`, `x.txt`, `facebook.txt`, `linkedin.txt`
 * out of the announcements output directory; the mailing-list channel
 * appears as a static section pointing at the uploaded artifacts.
 *
 * @package   openemr-devops
 * @link      https://www.open-emr.org
 * @author    Michael A. Smith <michael@opencoreemr.com>
 * @copyright Copyright (c) 2026 OpenCoreEMR Inc.
 * @license   https://github.com/openemr/openemr-devops/blob/master/LICENSE GNU General Public License 3
 */

declare(strict_types=1);

namespace OpenEMR\Release;

use Twig\Environment;
use Twig\Loader\FilesystemLoader;

final readonly class AnnouncementStepSummaryRenderer
{
    public const TEMPLATE_NAME = 'step-summary.md.twig';

    /**
     * Short-copy channels included inline in the step summary, in display
     * order. Each entry is [filename, heading, fenced-code language].
     * Mailing list isn't in this list — its section is static markdown
     * because the rendered HTML is too large to embed inline.
     *
     * @var list<array{filename: string, heading: string, fence: string}>
     */
    private const SHORT_COPY_CHANNELS = [
        ['filename' => 'forum.md', 'heading' => 'Forum (Discourse)', 'fence' => 'markdown'],
        ['filename' => 'chat.md', 'heading' => 'Chat', 'fence' => 'markdown'],
        ['filename' => 'x.txt', 'heading' => 'X', 'fence' => 'text'],
        ['filename' => 'facebook.txt', 'heading' => 'Facebook', 'fence' => 'text'],
        ['filename' => 'linkedin.txt', 'heading' => 'LinkedIn', 'fence' => 'text'],
    ];

    public function __construct(
        private string $templateDir,
    ) {
    }

    public function render(string $outputDir, string $version, string $tag, string $forumUrl): string
    {
        $announcementsDir = $this->templateDir . '/announcements';
        if (!is_dir($announcementsDir)) {
            throw new \RuntimeException("Announcements template dir not found: {$announcementsDir}");
        }

        $shortCopy = [];
        foreach (self::SHORT_COPY_CHANNELS as $channel) {
            $path = $outputDir . '/' . $channel['filename'];
            $body = @file_get_contents($path);
            if ($body === false) {
                throw new \RuntimeException("Rendered channel missing: {$path}");
            }
            $shortCopy[] = [
                'heading' => $channel['heading'],
                'fence' => $channel['fence'],
                'body' => rtrim($body, "\n"),
            ];
        }

        $twig = new Environment(
            new FilesystemLoader($announcementsDir),
            ['autoescape' => false],
        );
        return $twig->render(self::TEMPLATE_NAME, [
            'version' => $version,
            'tag' => $tag,
            'forum_url' => $forumUrl,
            'placeholder' => AnnouncementRenderer::FORUM_URL_PLACEHOLDER,
            'short_copy_channels' => $shortCopy,
        ]);
    }
}
