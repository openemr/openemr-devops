<?php

/**
 * AST-based version.php manipulator.
 *
 * Use php-parser to modify version variables without disturbing
 * formatting, comments, or other code in the file.
 *
 * @package   openemr-devops
 * @link      https://www.open-emr.org
 * @author    Michael A. Smith <michael@opencoreemr.com>
 * @copyright Copyright (c) 2026 OpenCoreEMR Inc.
 * @license   https://github.com/openemr/openemr-devops/blob/master/LICENSE GNU General Public License 3
 */

declare(strict_types=1);

namespace OpenEMR\Release;

use PhpParser\Node;
use PhpParser\Node\Expr\Assign;
use PhpParser\Node\Expr\Variable;
use PhpParser\Node\Scalar\String_;
use PhpParser\NodeTraverser;
use PhpParser\NodeVisitorAbstract;
use PhpParser\Parser;
use PhpParser\ParserFactory;
use PhpParser\PrettyPrinter\Standard;

class VersionBumper
{
    /**
     * Set $v_realpatch to the given value in a version.php file.
     */
    public function bumpPatch(string $file, string $patchNumber): self
    {
        return $this->setStringVariable($file, 'v_realpatch', $patchNumber);
    }

    /**
     * Remove '-dev' suffix from $v_tag for a production release.
     */
    public function clearDevTag(string $file): self
    {
        return $this->transformVariable($file, 'v_tag', static function (String_ $str): void {
            $str->value = str_replace('-dev', '', $str->value);
        });
    }

    /**
     * Set the default value of a globals.inc.php setting.
     *
     * Finds `'$key' => [... , '$value', ...]` in the globals array
     * and replaces the third element (index 2, the default value).
     */
    public function setGlobalDefault(string $file, string $key, string $value): self
    {
        [$code, $parser, $origStmts] = $this->parseFile($file);

        $visitor = new GlobalDefaultVisitor($key, $value);
        $traverser = new NodeTraverser();
        $traverser->addVisitor($visitor);

        $stmts = $traverser->traverse($origStmts);

        if (!$visitor->wasFound()) {
            throw new \RuntimeException("Global setting not found: {$key}");
        }

        $printer = new Standard();
        file_put_contents(
            $file,
            $printer->printFormatPreserving($stmts, $origStmts, $parser->getTokens()),
        );

        return $this;
    }

    private function setStringVariable(string $file, string $varName, string $value): self
    {
        return $this->transformVariable($file, $varName, static function (String_ $str) use ($value): void {
            $str->value = $value;
        });
    }

    /**
     * Apply a transformation to a string variable assignment in a PHP file.
     *
     * @param \Closure(String_): void $transform
     */
    private function transformVariable(string $file, string $varName, \Closure $transform): self
    {
        [$code, $parser, $origStmts] = $this->parseFile($file);

        $traverser = new NodeTraverser();
        $traverser->addVisitor(new class ($varName, $transform) extends NodeVisitorAbstract {
            /** @param \Closure(String_): void $transform */
            public function __construct(
                private readonly string $varName,
                private readonly \Closure $transform,
            ) {
            }

            public function leaveNode(Node $node): ?Node
            {
                if (!$node instanceof Node\Stmt\Expression) {
                    return null;
                }
                $expr = $node->expr;
                if (!$expr instanceof Assign) {
                    return null;
                }
                if (!$expr->var instanceof Variable || $expr->var->name !== $this->varName) {
                    return null;
                }
                if (!$expr->expr instanceof String_) {
                    return null;
                }
                ($this->transform)($expr->expr);
                return $node;
            }
        });

        $stmts = $traverser->traverse($origStmts);
        $printer = new Standard();
        file_put_contents(
            $file,
            $printer->printFormatPreserving($stmts, $origStmts, $parser->getTokens()),
        );

        return $this;
    }

    /**
     * @return array{string, Parser, array<Node\Stmt>}
     */
    private function parseFile(string $file): array
    {
        $code = file_get_contents($file);
        if ($code === false) {
            throw new \RuntimeException("Cannot read file: {$file}");
        }

        $parser = (new ParserFactory())->createForNewestSupportedVersion();
        $stmts = $parser->parse($code);
        if ($stmts === null) {
            throw new \RuntimeException("Failed to parse: {$file}");
        }

        return [$code, $parser, $stmts];
    }
}
