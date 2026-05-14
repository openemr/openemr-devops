<?php

/**
 * @package   openemr-devops
 * @link      https://www.open-emr.org
 * @author    Michael A. Smith <michael@opencoreemr.com>
 * @copyright Copyright (c) 2026 OpenCoreEMR Inc.
 * @license   https://github.com/openemr/openemr-devops/blob/master/LICENSE GNU General Public License 3
 */

declare(strict_types=1);

namespace OpenEMR\Release\Tests;

use OpenEMR\Release\AnnouncementRenderer;
use PHPUnit\Framework\TestCase;

final class AnnouncementRendererTest extends TestCase
{
    private const TEMPLATE_DIR = __DIR__ . '/../templates';

    /**
     * @return array{
     *     version: string,
     *     tag: string,
     *     branch: string,
     *     release_url: string,
     *     release_notes_url: string,
     *     forum_url: string,
     * }
     */
    private function context(string $forumUrl = AnnouncementRenderer::FORUM_URL_PLACEHOLDER): array
    {
        return [
            'version' => '8.1.0',
            'tag' => 'v8_1_0',
            'branch' => 'rel-810',
            'release_url' => 'https://github.com/openemr/openemr/releases/tag/v8_1_0',
            'release_notes_url' => 'https://www.open-emr.org/wiki/index.php/Release_Features#Version_8.1.0',
            'forum_url' => $forumUrl,
        ];
    }

    public function testRendersAllChannels(): void
    {
        $rendered = (new AnnouncementRenderer(self::TEMPLATE_DIR))->renderAll($this->context());

        self::assertSame(
            array_keys(AnnouncementRenderer::CHANNELS),
            array_keys($rendered),
        );
        foreach ($rendered as $channel => $body) {
            self::assertNotSame('', trim($body), "{$channel} rendered empty");
        }
    }

    /**
     * Channels that link to the forum and should preserve / substitute the
     * placeholder. Mailing-list .subject doesn't link to the forum, and the
     * X channel can't fit the URL within 280 chars, so they're excluded.
     */
    private const FORUM_LINKING_CHANNELS = ['chat.md', 'facebook.txt', 'linkedin.txt', 'mail.html'];

    public function testForumUrlPlaceholderRoundTrips(): void
    {
        $rendered = (new AnnouncementRenderer(self::TEMPLATE_DIR))->renderAll($this->context());

        foreach (self::FORUM_LINKING_CHANNELS as $channel) {
            self::assertStringContainsString('{{FORUM_URL}}', $rendered[$channel], "{$channel} dropped placeholder");
        }
    }

    public function testForumUrlSubstitutesWhenProvided(): void
    {
        $url = 'https://community.open-emr.org/t/openemr-8-1-0-released/12345';
        $rendered = (new AnnouncementRenderer(self::TEMPLATE_DIR))->renderAll($this->context($url));

        foreach (self::FORUM_LINKING_CHANNELS as $channel) {
            self::assertStringContainsString($url, $rendered[$channel], "{$channel} missing forum URL");
            self::assertStringNotContainsString('{{FORUM_URL}}', $rendered[$channel], "{$channel} kept placeholder");
        }
    }

    public function testXFitsCharacterLimit(): void
    {
        $rendered = (new AnnouncementRenderer(self::TEMPLATE_DIR))->renderAll($this->context());

        // X counts URLs as a fixed 23 characters via t.co shortening, so
        // approximate the real limit by replacing each URL with 23 chars
        // before measuring. This is a loose sanity check, not an exact
        // reproduction of X's character-counting rules.
        $approx = preg_replace('#https?://\S+#', str_repeat('x', 23), trim($rendered['x.txt']));
        self::assertLessThanOrEqual(280, mb_strlen($approx ?? ''));
    }

    public function testMailSubjectIsSingleLine(): void
    {
        $rendered = (new AnnouncementRenderer(self::TEMPLATE_DIR))->renderAll($this->context());

        $subject = trim($rendered['mail.subject.txt']);
        // CR and LF both enable header injection in the .eml — reject either.
        self::assertStringNotContainsString("\n", $subject);
        self::assertStringNotContainsString("\r", $subject);
        self::assertStringContainsString('8.1.0', $subject);
    }

    public function testMailHtmlIncludesVersionAndReleaseNotesLink(): void
    {
        $rendered = (new AnnouncementRenderer(self::TEMPLATE_DIR))->renderAll($this->context());

        self::assertStringContainsString('OpenEMR 8.1.0 Released', $rendered['mail.html']);
        self::assertStringContainsString(
            'https://www.open-emr.org/wiki/index.php/Release_Features#Version_8.1.0',
            $rendered['mail.html'],
        );
    }

    public function testRenderIsDeterministic(): void
    {
        $renderer = new AnnouncementRenderer(self::TEMPLATE_DIR);

        self::assertSame($renderer->renderAll($this->context()), $renderer->renderAll($this->context()));
    }

    public function testThrowsOnMissingTemplateDir(): void
    {
        $renderer = new AnnouncementRenderer('/no/such/dir');

        $this->expectException(\RuntimeException::class);
        $renderer->renderAll($this->context());
    }
}
