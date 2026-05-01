<?php

declare(strict_types=1);

use Rector\Config\RectorConfig;

return RectorConfig::configure()
    ->withPaths([
        __DIR__ . '/src',
        __DIR__ . '/bin',
        __DIR__ . '/tests',
    ])
    ->withPhpVersion(Rector\ValueObject\PhpVersion::PHP_85)
    ->withPreparedSets(
        deadCode: true,
        codeQuality: true,
        typeDeclarations: true,
    )
    ->withCache('/tmp/rector');
