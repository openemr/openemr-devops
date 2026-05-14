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
use OpenEMR\Release\AnnouncementStepSummaryRenderer;
use PHPUnit\Framework\TestCase;

final class AnnouncementStepSummaryRendererTest extends TestCase
{
    private const TEMPLATE_DIR = __DIR__ . '/../templates';

    private string $outputDir = '';

    protected function setUp(): void
    {
        $this->outputDir = sys_get_temp_dir() . '/openemr-step-summary-' . bin2hex(random_bytes(8));
        if (!mkdir($this->outputDir, 0700, true)) {
            throw new \RuntimeException('Failed to create tmp dir: ' . $this->outputDir);
        }
        // Render the real per-channel files into the tmp dir using the
        // production renderer — keeps the summary test honest about what
        // it's summarizing.
        $rendered = (new AnnouncementRenderer(self::TEMPLATE_DIR))->renderAll([
            'version' => '8.1.0',
            'tag' => 'v8_1_0',
            'branch' => 'rel-810',
            'release_url' => 'https://github.com/openemr/openemr/releases/tag/v8_1_0',
            'release_notes_url' => 'https://www.open-emr.org/wiki/index.php/Release_Features#Version_8.1.0',
            'forum_url' => AnnouncementRenderer::FORUM_URL_PLACEHOLDER,
        ]);
        foreach ($rendered as $name => $body) {
            file_put_contents($this->outputDir . '/' . $name, $body);
        }
    }

    protected function tearDown(): void
    {
        $files = glob($this->outputDir . '/*');
        foreach ($files === false ? [] : $files as $path) {
            @unlink($path);
        }
        @rmdir($this->outputDir);
    }

    public function testRendersEachShortCopyChannel(): void
    {
        $summary = (new AnnouncementStepSummaryRenderer(self::TEMPLATE_DIR))
            ->render($this->outputDir, '8.1.0', 'v8_1_0', AnnouncementRenderer::FORUM_URL_PLACEHOLDER);

        self::assertStringContainsString('# Release announcement drafts — OpenEMR 8.1.0 (v8_1_0)', $summary);
        foreach (['Forum (Discourse)', 'Chat', 'X', 'Facebook', 'LinkedIn', 'Mailing list'] as $heading) {
            self::assertStringContainsString('## ' . $heading, $summary);
        }
    }

    public function testEmitsPlaceholderHintWhenForumUrlMissing(): void
    {
        $summary = (new AnnouncementStepSummaryRenderer(self::TEMPLATE_DIR))
            ->render($this->outputDir, '8.1.0', 'v8_1_0', AnnouncementRenderer::FORUM_URL_PLACEHOLDER);

        self::assertStringContainsString('Forum URL placeholder', $summary);
    }

    public function testSuppressesPlaceholderHintWhenForumUrlProvided(): void
    {
        $url = 'https://community.open-emr.org/t/openemr-8-1-0-released/12345';
        $summary = (new AnnouncementStepSummaryRenderer(self::TEMPLATE_DIR))
            ->render($this->outputDir, '8.1.0', 'v8_1_0', $url);

        self::assertStringNotContainsString('Forum URL placeholder', $summary);
    }

    public function testThrowsOnMissingChannelFile(): void
    {
        unlink($this->outputDir . '/x.txt');
        $renderer = new AnnouncementStepSummaryRenderer(self::TEMPLATE_DIR);

        $this->expectException(\RuntimeException::class);
        $this->expectExceptionMessage('Rendered channel missing');
        $renderer->render($this->outputDir, '8.1.0', 'v8_1_0', AnnouncementRenderer::FORUM_URL_PLACEHOLDER);
    }
}
