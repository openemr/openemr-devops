<?php

/**
 * Render per-channel release-announcement drafts from Twig templates.
 *
 * Drafts only — no posting, no sending. The workflow that wraps this
 * renderer surfaces the output in $GITHUB_STEP_SUMMARY and as run
 * artifacts; a maintainer copy-pastes / forwards them to each channel.
 * See openemr/openemr-devops#719.
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

final readonly class AnnouncementRenderer
{
    /**
     * Channel name → template filename (relative to the announcements dir).
     *
     * The keys are also the output filenames stripped of `.twig`. mail.eml
     * is synthesized by the CLI from mail.html + mail.subject.
     */
    public const CHANNELS = [
        'forum.md' => 'forum.md.twig',
        'chat.md' => 'chat.md.twig',
        'x.txt' => 'x.txt.twig',
        'facebook.txt' => 'facebook.txt.twig',
        'linkedin.txt' => 'linkedin.txt.twig',
        'mail.html' => 'mail.html.twig',
        'mail.subject.txt' => 'mail.subject.txt.twig',
    ];

    public function __construct(
        private string $templateDir,
    ) {
    }

    /**
     * @param array{
     *     version: string,
     *     tag: string,
     *     branch: string,
     *     release_url: string,
     *     release_notes_url: string,
     *     forum_url: string,
     * } $context
     * @return array<string, string> channel-output-name → rendered content
     */
    public function renderAll(array $context): array
    {
        $announcementsDir = $this->templateDir . '/announcements';
        if (!is_dir($announcementsDir)) {
            throw new \RuntimeException("Announcements template dir not found: {$announcementsDir}");
        }
        $twig = new Environment(
            new FilesystemLoader($announcementsDir),
            ['autoescape' => false],
        );

        $rendered = [];
        foreach (self::CHANNELS as $output => $template) {
            $rendered[$output] = $twig->render($template, $context);
        }
        return $rendered;
    }
}
