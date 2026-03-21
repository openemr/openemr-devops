<?php

/**
 * Node visitor that updates the default value of a globals.inc.php setting.
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
use PhpParser\Node\Expr\ArrayItem;
use PhpParser\Node\Scalar\String_;
use PhpParser\NodeVisitorAbstract;

class GlobalDefaultVisitor extends NodeVisitorAbstract
{
    private bool $found = false;

    public function __construct(
        private readonly string $key,
        private readonly string $value,
    ) {
    }

    public function wasFound(): bool
    {
        return $this->found;
    }

    public function leaveNode(Node $node): ?Node
    {
        if (!$node instanceof ArrayItem) {
            return null;
        }
        if (!$node->key instanceof String_ || $node->key->value !== $this->key) {
            return null;
        }
        if (!$node->value instanceof Node\Expr\Array_) {
            return null;
        }
        $defaultItem = $node->value->items[2] ?? null;
        if (!$defaultItem instanceof ArrayItem) {
            return null;
        }
        if (!$defaultItem->value instanceof String_) {
            return null;
        }
        $defaultItem->value->value = $this->value;
        $this->found = true;
        return $node;
    }
}
