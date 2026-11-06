<?php

/**
 * php-upgrade-catalogue's scanner: finds code that a newer PHP removed, changed or deprecated,
 * from the catalogue's facts (php-changes.json).
 *
 *     php scan.php --facts=php-changes.json [--php=FROM:TO | --php=TO] [--json] [--stdin] [--defs=PATH]... [PATH...]
 *
 *   --php=7.4:8.3  what changes between PHP 7.4 and 8.3 (versions after 7.4, up to 8.3)
 *   --php=8.5      everything the facts know up to PHP 8.5: does this code work on 8.5?
 *                  Without --php, TO is the PHP running this file.
 *   --stdin        read the files to scan from standard input, one path per line
 *   --defs=PATH    also look here for definitions of removed symbols (polyfills), without
 *                  reporting on it: an install's root, say, while only its changed files are scanned
 *   --json         one record per finding (see README)
 *
 * PATH is a file or a folder (its .php, .inc and .phtml files). It reads files and never runs
 * them, so it works on code the current PHP still loads and the target won't. A use behind
 * function_exists(), is_callable(), defined(), class_exists() or extension_loaded(), or of a
 * symbol the code defines itself (a polyfill), is listed with its guard and not counted.
 *
 * One file, no Composer; PHP 5.4 and later, so it runs on the PHP a site has now. Including it
 * defines UpgradeScan and the upgradeScan*() functions and does nothing else.
 * Exit code: 1 if anything unguarded won't load or is fatal, else 0; 2 on bad arguments or facts.
 *
 * @license GPL-3.0-or-later
 */

class UpgradeScan
{
    const VERSION = '0.1.0';

    /** @var array token name => id; ids this PHP doesn't have get unique negative stand-ins */
    private static $t = array();
    private $facts;
    private $versions;
    private $defined = array('functions' => array(), 'classes' => array(), 'constants' => array());
    public $findings = array();

    public static function tokenIds()
    {
        $names = array('T_STRING', 'T_WHITESPACE', 'T_COMMENT', 'T_DOC_COMMENT', 'T_INLINE_HTML', 'T_OPEN_TAG',
            'T_OPEN_TAG_WITH_ECHO', 'T_CLOSE_TAG', 'T_VARIABLE', 'T_FUNCTION', 'T_FN', 'T_CLASS', 'T_INTERFACE', 'T_TRAIT',
            'T_ENUM', 'T_NEW', 'T_EXTENDS', 'T_IMPLEMENTS', 'T_INSTANCEOF', 'T_CATCH', 'T_CONST', 'T_NAMESPACE',
            'T_NS_SEPARATOR', 'T_NAME_FULLY_QUALIFIED', 'T_NAME_QUALIFIED', 'T_NAME_RELATIVE', 'T_OBJECT_OPERATOR',
            'T_NULLSAFE_OBJECT_OPERATOR', 'T_DOUBLE_COLON', 'T_CONSTANT_ENCAPSED_STRING', 'T_DOUBLE_CAST', 'T_INT_CAST',
            'T_BOOL_CAST', 'T_STRING_CAST', 'T_UNSET_CAST', 'T_CURLY_OPEN', 'T_DOLLAR_OPEN_CURLY_BRACES', 'T_MATCH',
            'T_DOUBLE_ARROW', 'T_LOGICAL_AND', 'T_LOGICAL_OR', 'T_LOGICAL_XOR', 'T_PLUS_EQUAL', 'T_MINUS_EQUAL',
            'T_MUL_EQUAL', 'T_DIV_EQUAL', 'T_CONCAT_EQUAL', 'T_MOD_EQUAL', 'T_AND_EQUAL', 'T_OR_EQUAL', 'T_XOR_EQUAL',
            'T_SL_EQUAL', 'T_SR_EQUAL', 'T_POW_EQUAL', 'T_COALESCE_EQUAL', 'T_RETURN', 'T_ECHO', 'T_PRINT', 'T_YIELD',
            'T_YIELD_FROM', 'T_THROW', 'T_CASE', 'T_ELSE', 'T_AS', 'T_PUBLIC', 'T_PROTECTED', 'T_PRIVATE', 'T_READONLY',
            'T_ELLIPSIS', 'T_ATTRIBUTE', 'T_ARRAY', 'T_CALLABLE', 'T_STATIC', 'T_USE');
        foreach ($names as $i => $n) {
            self::$t[$n] = defined($n) ? constant($n) : -1 - $i;
        }
    }

    private static function is($tok, $name)
    {
        return $tok !== null && $tok[0] === self::$t[$name];
    }

    /** $from null: every version the facts have up to $to. */
    public function __construct($facts, $from, $to)
    {
        $this->facts = $facts;
        $this->versions = array();
        foreach ($facts['versions'] as $v => $entry) {
            if (($from === null || version_compare($v, $from, '>')) && version_compare($v, $to, '<=')) {
                $this->versions[$v] = $entry;
            }
        }
    }

    /** A pattern matching any symbol name in scope, to skip definition files that can't matter. */
    public function namesPattern()
    {
        $names = array();
        foreach ($this->versions as $entry) {
            foreach (array('functions', 'classes', 'constants') as $kind) {
                foreach ($entry['removed'][$kind] as $name => $ext) {
                    $names[$name] = true;
                }
            }
            foreach ($entry['deprecated']['functions'] as $name => $ext) {
                $names[$name] = true;
            }
        }
        if (!$names) {
            return null;
        }
        $quoted = array();
        foreach (array_keys($names) as $name) {
            $quoted[] = preg_quote($name, '/');
        }
        return '/\b(' . implode('|', $quoted) . ')\b/i';
    }

    /** Significant tokens as array(id, text, line): no whitespace, comments or inline HTML;
     *  a closing tag counts as ';'. */
    public static function tokens($code)
    {
        $out = array();
        $line = 1;
        foreach (token_get_all($code) as $tok) {
            if (is_array($tok)) {
                $line = $tok[2];
                $id = $tok[0];
                if ($id === self::$t['T_WHITESPACE'] || $id === self::$t['T_COMMENT'] || $id === self::$t['T_DOC_COMMENT']
                    || $id === self::$t['T_INLINE_HTML'] || $id === self::$t['T_OPEN_TAG'] || $id === self::$t['T_OPEN_TAG_WITH_ECHO']) {
                    $line += substr_count($tok[1], "\n");
                    continue;
                }
                if ($id === self::$t['T_CLOSE_TAG']) {
                    $out[] = array(';', ';', $line);
                } else {
                    $out[] = array($id, $tok[1], $line);
                }
                $line += substr_count($tok[1], "\n");
            } else {
                $out[] = array($tok, $tok, $line);
            }
        }
        return $out;
    }

    /** The global name a name token refers to, or null if it's namespaced: 'each' for each,
     *  \each; null for Foo\each. $start is set to the index where the name begins. */
    private static function globalName($toks, $i, &$start)
    {
        $tok = $toks[$i];
        $start = $i;
        if (self::is($tok, 'T_NAME_FULLY_QUALIFIED')) {
            $name = substr($tok[1], 1);
            return strpos($name, '\\') === false ? $name : null;
        }
        if (!self::is($tok, 'T_STRING')) {
            return null;
        }
        $prev = $i > 0 ? $toks[$i - 1] : null;
        if (self::is($prev, 'T_NS_SEPARATOR')) {
            $before = $i > 1 ? $toks[$i - 2] : null;
            if (self::is($before, 'T_STRING') || self::is($before, 'T_NAMESPACE')) {
                return null;
            }
            $start = $i - 1;
        }
        return $tok[1];
    }

    /** First pass over every file: what the scanned code defines itself. */
    public function collect($toks)
    {
        $classDepth = array();
        $depth = 0;
        $pendingClass = false;
        $n = count($toks);
        for ($i = 0; $i < $n; $i++) {
            $tok = $toks[$i];
            $id = $tok[0];
            $prev = $i > 0 ? $toks[$i - 1] : null;
            if ($id === '{' || self::is($tok, 'T_CURLY_OPEN') || self::is($tok, 'T_DOLLAR_OPEN_CURLY_BRACES')) {
                $depth++;
                if ($pendingClass && $id === '{') {
                    $classDepth[] = $depth;
                    $pendingClass = false;
                }
            } elseif ($id === '}') {
                if ($classDepth && end($classDepth) === $depth) {
                    array_pop($classDepth);
                }
                $depth--;
            } elseif ((self::is($tok, 'T_CLASS') || self::is($tok, 'T_INTERFACE') || self::is($tok, 'T_TRAIT') || self::is($tok, 'T_ENUM'))
                && !self::is($prev, 'T_DOUBLE_COLON')) {
                $pendingClass = true;
                if (!self::is($prev, 'T_NEW') && isset($toks[$i + 1]) && self::is($toks[$i + 1], 'T_STRING')) {
                    $this->defined['classes'][strtolower($toks[$i + 1][1])] = true;
                }
            } elseif (self::is($tok, 'T_FUNCTION') && !($classDepth && end($classDepth) === $depth)) {
                $j = $i + 1;
                if (isset($toks[$j]) && $toks[$j][0] === '&') {
                    $j++;
                }
                if (isset($toks[$j]) && (self::is($toks[$j], 'T_STRING') || self::is($toks[$j], 'T_MATCH'))) {
                    $this->defined['functions'][strtolower($toks[$j][1])] = true;
                }
            } elseif (self::is($tok, 'T_STRING') && strtolower($tok[1]) === 'define' && isset($toks[$i + 2])
                && $toks[$i + 1][0] === '(' && self::is($toks[$i + 2], 'T_CONSTANT_ENCAPSED_STRING')) {
                $this->defined['constants'][substr($toks[$i + 2][1], 1, -1)] = true;
            } elseif (self::is($tok, 'T_CONST') && !$classDepth && isset($toks[$i + 1]) && self::is($toks[$i + 1], 'T_STRING')) {
                $this->defined['constants'][$toks[$i + 1][1]] = true;
            }
        }
    }

    /** One finding. kind: wontload, fatal, silent or deprecated. guard: null, or what was seen
     *  (function_exists, is_callable, defined, class_exists, extension_loaded, polyfill). */
    private function add($file, $line, $php, $rule, $name, $kind, $message, $guard = null)
    {
        $this->findings[] = array('file' => $file, 'line' => $line, 'kind' => $kind, 'rule' => $rule,
            'name' => $name, 'php' => $php, 'guard' => $guard, 'message' => $message);
    }

    /** Where a removed symbol of this kind and name went, or null. */
    private function removedIn($kind, $name)
    {
        foreach ($this->versions as $v => $entry) {
            $key = ($kind === 'functions' || $kind === 'classes') ? strtolower($name) : $name;
            if (isset($entry['removed'][$kind][$key])) {
                return array($v, $entry['removed'][$kind][$key], in_array($entry['removed'][$kind][$key], $entry['extensions_removed'], true));
            }
        }
        return null;
    }

    private function deprecatedIn($name)
    {
        foreach ($this->versions as $v => $entry) {
            if (isset($entry['deprecated']['functions'][strtolower($name)])) {
                return array($v, $entry['deprecated']['functions'][strtolower($name)]);
            }
        }
        return null;
    }

    private function wants($rule)
    {
        foreach ($this->versions as $v => $entry) {
            foreach ($entry['syntax'] as $r) {
                if ($r['id'] === $rule) {
                    return array($v, $r);
                }
            }
        }
        return null;
    }

    /** Second pass: one file's findings. */
    public function scan($file, $toks)
    {
        $guards = array('functions' => array(), 'classes' => array(), 'constants' => array(), 'extensions' => array());
        $guardFns = array('function_exists' => 'functions', 'is_callable' => 'functions', 'class_exists' => 'classes',
            'defined' => 'constants', 'extension_loaded' => 'extensions');
        $namespaced = false;
        $n = count($toks);
        for ($i = 0; $i < $n; $i++) {
            $tok = $toks[$i];
            if (self::is($tok, 'T_STRING') && isset($guardFns[strtolower($tok[1])]) && isset($toks[$i + 2])
                && $toks[$i + 1][0] === '(' && self::is($toks[$i + 2], 'T_CONSTANT_ENCAPSED_STRING')) {
                $kind = $guardFns[strtolower($tok[1])];
                $name = substr($toks[$i + 2][1], 1, -1);
                $guards[$kind][$kind === 'constants' ? $name : strtolower($name)] = strtolower($tok[1]);
            }
            if (self::is($tok, 'T_NAMESPACE') && isset($toks[$i + 1]) && !self::is($toks[$i + 1], 'T_NS_SEPARATOR')) {
                $namespaced = true;
            }
        }
        $this->symbols($file, $toks, $guards);
        $this->syntax($file, $toks, $namespaced);
    }

    private function symbols($file, $toks, $guards)
    {
        $iniFns = array('ini_set' => 1, 'ini_get' => 1, 'ini_restore' => 1, 'ini_alter' => 1);
        $n = count($toks);
        for ($i = 0; $i < $n; $i++) {
            $tok = $toks[$i];
            $start = $i;
            $name = self::globalName($toks, $i, $start);
            if ($name === null) {
                continue;
            }
            $prev = $start > 0 ? $toks[$start - 1] : null;
            $next = isset($toks[$i + 1]) ? $toks[$i + 1] : null;
            if (self::is($prev, 'T_OBJECT_OPERATOR') || self::is($prev, 'T_NULLSAFE_OBJECT_OPERATOR') || self::is($prev, 'T_FUNCTION')
                || self::is($prev, 'T_CONST') || ($prev !== null && $prev[0] === '&' && $start > 1 && self::is($toks[$start - 2], 'T_FUNCTION'))
                || self::is($prev, 'T_CLASS') || self::is($prev, 'T_INTERFACE') || self::is($prev, 'T_TRAIT')) {
                continue;
            }
            $lower = strtolower($name);
            if ($next !== null && $next[0] === '(' && !self::is($prev, 'T_DOUBLE_COLON') && !self::is($prev, 'T_NEW')) {
                // a function call
                if (isset($iniFns[$lower]) && isset($toks[$i + 2]) && self::is($toks[$i + 2], 'T_CONSTANT_ENCAPSED_STRING')) {
                    $setting = substr($toks[$i + 2][1], 1, -1);
                    $r = $this->removedIn('ini', $setting);
                    if ($r) {
                        $this->add($file, $tok[2], $r[0], 'removed-ini', $setting, 'silent',
                            "the $setting setting is gone from PHP {$r[0]}: $lower() returns false and nothing changes");
                    }
                }
                $guard = isset($this->defined['functions'][$lower]) ? 'polyfill'
                    : (isset($guards['functions'][$lower]) ? $guards['functions'][$lower] : null);
                $r = $this->removedIn('functions', $name);
                if ($r) {
                    if ($guard === null && isset($guards['extensions'][$r[1]])) {
                        $guard = 'extension_loaded';
                    }
                    $what = $r[2] ? "$name(): the {$r[1]} extension left PHP in {$r[0]} (it's on PECL)" : "$name() is gone from PHP {$r[0]} ({$r[1]})";
                    $this->add($file, $tok[2], $r[0], $r[2] ? 'extension-removed' : 'removed-function', $name, 'fatal',
                        "$what: \"Call to undefined function\" when this line runs", $guard);
                    continue;
                }
                $d = $this->deprecatedIn($name);
                if ($d) {
                    $this->add($file, $tok[2], $d[0], 'deprecated-function', $name, 'deprecated',
                        "$name() is deprecated from PHP {$d[0]} ({$d[1]}): it works, with a deprecation notice", $guard);
                }
                continue;
            }
            // a class: new X, X::, extends X, implements X, instanceof X, catch (X
            $classUse = self::is($prev, 'T_NEW') || self::is($prev, 'T_EXTENDS') || self::is($prev, 'T_IMPLEMENTS')
                || self::is($prev, 'T_INSTANCEOF') || ($next !== null && self::is($next, 'T_DOUBLE_COLON'))
                || ($prev !== null && $prev[0] === '(' && $start > 1 && self::is($toks[$start - 2], 'T_CATCH'))
                || ($prev !== null && $prev[0] === ',' && $this->inImplements($toks, $start));
            if ($classUse) {
                $r = $this->removedIn('classes', $name);
                if ($r) {
                    $guard = isset($this->defined['classes'][$lower]) ? 'polyfill'
                        : (isset($guards['classes'][$lower]) ? $guards['classes'][$lower]
                        : (isset($guards['extensions'][$r[1]]) ? 'extension_loaded' : null));
                    $this->add($file, $tok[2], $r[0], $r[2] ? 'extension-removed' : 'removed-class', $name, 'fatal',
                        "class $name is gone from PHP {$r[0]} ({$r[1]}): \"Class not found\" when this line runs", $guard);
                }
                continue;
            }
            if (self::is($prev, 'T_DOUBLE_COLON')) {
                continue;
            }
            $r = $this->removedIn('constants', $name);
            if ($r) {
                $guard = isset($this->defined['constants'][$name]) ? 'polyfill'
                    : (isset($guards['constants'][$name]) ? $guards['constants'][$name]
                    : (isset($guards['extensions'][$r[1]]) ? 'extension_loaded' : null));
                $this->add($file, $tok[2], $r[0], $r[2] ? 'extension-removed' : 'removed-constant', $name, 'fatal',
                    "the constant $name is gone from PHP {$r[0]} ({$r[1]}): an \"Undefined constant\" error when this line runs", $guard);
            }
        }
    }

    private function inImplements($toks, $i)
    {
        for ($j = $i - 1; $j >= 0; $j--) {
            $id = $toks[$j][0];
            if (self::is($toks[$j], 'T_IMPLEMENTS')) {
                return true;
            }
            if ($id !== ',' && !self::is($toks[$j], 'T_STRING') && !self::is($toks[$j], 'T_NS_SEPARATOR')
                && !self::is($toks[$j], 'T_NAME_QUALIFIED') && !self::is($toks[$j], 'T_NAME_FULLY_QUALIFIED')) {
                return false;
            }
        }
        return false;
    }

    private function rule($file, $line, $rule, $name, $what)
    {
        $w = $this->wants($rule);
        if ($w) {
            $this->add($file, $line, $w[0], $rule, $name, $w[1]['kind'], $what);
        }
    }

    private function syntax($file, $toks, $namespaced)
    {
        $n = count($toks);
        $classes = array();      // open class bodies: array(depth, name, line, ctorLine, hasConstruct, kind)
        $depth = 0;
        $pendingClass = null;
        // nested ternaries: per nesting level, state 0 (none), 1 (inside a ternary's middle,
        // with a count of open '?'), 2 (after a complete ternary: another '?' here is nested
        // without parentheses, unless every one at this level is the short ?: form)
        $levels = array(array(0, 0, true));
        $resets = array('T_DOUBLE_ARROW', 'T_LOGICAL_AND', 'T_LOGICAL_OR', 'T_LOGICAL_XOR', 'T_PLUS_EQUAL', 'T_MINUS_EQUAL',
            'T_MUL_EQUAL', 'T_DIV_EQUAL', 'T_CONCAT_EQUAL', 'T_MOD_EQUAL', 'T_AND_EQUAL', 'T_OR_EQUAL', 'T_XOR_EQUAL',
            'T_SL_EQUAL', 'T_SR_EQUAL', 'T_POW_EQUAL', 'T_COALESCE_EQUAL', 'T_RETURN', 'T_ECHO', 'T_PRINT', 'T_YIELD',
            'T_YIELD_FROM', 'T_THROW', 'T_CASE', 'T_ELSE', 'T_AS');
        $resetIds = array();
        foreach ($resets as $r) {
            $resetIds[self::$t[$r]] = true;
        }
        $skip = -1;
        for ($i = 0; $i < $n; $i++) {
            $tok = $toks[$i];
            $id = $tok[0];
            $prev = $i > 0 ? $toks[$i - 1] : null;
            $next = isset($toks[$i + 1]) ? $toks[$i + 1] : null;
            $top = count($levels) - 1;

            // nesting
            if ($id === '(' || $id === '[' || $id === '{' || self::is($tok, 'T_CURLY_OPEN') || self::is($tok, 'T_DOLLAR_OPEN_CURLY_BRACES')) {
                if ($id === '{' && $prev !== null && $this->offsetBefore($toks, $i)) {
                    $this->rule($file, $tok[2], 'curly-offset', '{}', 'string or array offset with {}: write [] (a parse error from PHP 8.0)');
                }
                if ($id === '{' || self::is($tok, 'T_CURLY_OPEN') || self::is($tok, 'T_DOLLAR_OPEN_CURLY_BRACES')) {
                    $depth++;
                    $levels[$top] = array(0, 0, true);
                    if ($pendingClass !== null && $id === '{') {
                        $pendingClass[0] = $depth;
                        $classes[] = $pendingClass;
                        $pendingClass = null;
                    }
                }
                if (self::is($tok, 'T_DOLLAR_OPEN_CURLY_BRACES')) {
                    $this->rule($file, $tok[2], 'dollar-brace-interpolation', '${', '"${var}" in a string: write "{$var}" (deprecated from PHP 8.2)');
                }
                $levels[] = array(0, 0, true);
                continue;
            }
            if ($id === ')' || $id === ']' || $id === '}') {
                if (count($levels) > 1) {
                    array_pop($levels);
                }
                if ($id === '}') {
                    $levels[count($levels) - 1] = array(0, 0, true);
                    if ($classes) {
                        $c = end($classes);
                        if ($c[0] === $depth) {
                            array_pop($classes);
                            if ($c[3] !== null && !$c[4] && !$namespaced && $c[5] === 'class') {
                                $this->rule($file, $c[3], 'php4-constructor', $c[1],
                                    "class {$c[1]}'s constructor {$c[1]}() is no longer called from PHP 8.0, with no error: rename it __construct()");
                            }
                        }
                    }
                    $depth--;
                }
                continue;
            }

            // nested ternaries
            if ($i === $skip) {
                continue;
            }
            if ($id === '?') {
                $short = $next !== null && $next[0] === ':';
                $lv = $levels[$top];
                if ($lv[0] === 2 && !($short && $lv[2])) {
                    $this->rule($file, $tok[2], 'nested-ternary', '?:', 'a ternary nested without parentheses: add them (an error from PHP 8.0, so the file won\'t load)');
                    $levels[$top] = array(0, 0, true);
                } elseif ($short) {
                    if ($lv[0] !== 1) {
                        $levels[$top] = array(2, 0, $lv[0] === 2 ? $lv[2] : true);
                    }
                    $skip = $i + 1;
                } elseif ($lv[0] === 1) {
                    $levels[$top][1]++;
                } else {
                    $levels[$top] = array(1, 1, true);
                }
                continue;
            }
            if ($id === ':') {
                $lv = $levels[$top];
                if ($lv[0] === 1) {
                    $levels[$top] = $lv[1] > 1 ? array(1, $lv[1] - 1, true) : array(2, 0, false);
                } else {
                    $levels[$top] = array(0, 0, true);
                }
                continue;
            }
            if ($id === ';' || $id === ',' || $id === '=' || isset($resetIds[$id])) {
                $levels[$top] = array(0, 0, true);
            }

            // classes and their PHP 4 style constructors
            if ((self::is($tok, 'T_CLASS') || self::is($tok, 'T_INTERFACE') || self::is($tok, 'T_TRAIT') || self::is($tok, 'T_ENUM'))
                && !self::is($prev, 'T_DOUBLE_COLON')) {
                $named = !self::is($prev, 'T_NEW') && $next !== null && self::is($next, 'T_STRING');
                $kind = self::is($tok, 'T_CLASS') ? 'class' : 'other';
                $pendingClass = array(0, $named ? $next[1] : '', $tok[2], null, false, $named ? $kind : 'other');
                continue;
            }
            if (self::is($tok, 'T_FUNCTION')) {
                $j = $i + 1;
                if (isset($toks[$j]) && $toks[$j][0] === '&') {
                    $j++;
                }
                $fname = isset($toks[$j]) && (self::is($toks[$j], 'T_STRING') || self::is($toks[$j], 'T_MATCH')) ? $toks[$j][1] : null;
                $inClass = $classes && end($classes) && $classes[count($classes) - 1][0] === $depth;
                if ($fname !== null && $inClass) {
                    $c = &$classes[count($classes) - 1];
                    if (strcasecmp($fname, '__construct') === 0) {
                        $c[4] = true;
                    } elseif ($c[1] !== '' && strcasecmp($fname, $c[1]) === 0) {
                        $c[3] = $toks[$j][2];
                    }
                    unset($c);
                } elseif ($fname !== null) {
                    if (strcasecmp($fname, '__autoload') === 0) {
                        $this->rule($file, $toks[$j][2], 'autoload-function', '__autoload', 'function __autoload(): use spl_autoload_register() (PHP 8.0 refuses to compile the file)');
                    } elseif (strcasecmp($fname, 'match') === 0) {
                        $this->rule($file, $toks[$j][2], 'match-name', 'match', 'a function named match: rename it (match is a keyword from PHP 8.0, so the file won\'t load)');
                    }
                }
                $this->params($file, $toks, $i);
                continue;
            }
            if (self::is($tok, 'T_FN')) {
                $this->params($file, $toks, $i);
                continue;
            }
            // match(…) called as a function: only visible to a PHP 7 tokenizer, where it is T_STRING
            if (self::is($tok, 'T_STRING') && strcasecmp($tok[1], 'match') === 0 && $next !== null && $next[0] === '('
                && !self::is($prev, 'T_OBJECT_OPERATOR') && !self::is($prev, 'T_DOUBLE_COLON') && !self::is($prev, 'T_FUNCTION')
                && !self::is($prev, 'T_NULLSAFE_OBJECT_OPERATOR') && !self::is($prev, 'T_NEW')
                && !(self::is($prev, 'T_NS_SEPARATOR') && $i > 1 && self::is($toks[$i - 2], 'T_STRING'))) {
                $this->rule($file, $tok[2], 'match-name', 'match', 'a call to a function named match: rename it (match is a keyword from PHP 8.0, so the file won\'t load)');
                continue;
            }

            // casts and backticks
            $cast = strtolower(preg_replace('/\s+/', '', $tok[1]));
            if (self::is($tok, 'T_DOUBLE_CAST') && $cast === '(real)') {
                $this->rule($file, $tok[2], 'real-cast', '(real)', '(real) cast: write (float) (a parse error from PHP 8.0)');
            } elseif (self::is($tok, 'T_UNSET_CAST')) {
                $this->rule($file, $tok[2], 'unset-cast', '(unset)', '(unset) cast: assign null instead (PHP 8.0 refuses to compile the file)');
            } elseif ((self::is($tok, 'T_BOOL_CAST') && $cast === '(boolean)') || (self::is($tok, 'T_INT_CAST') && $cast === '(integer)')
                || (self::is($tok, 'T_DOUBLE_CAST') && $cast === '(double)') || (self::is($tok, 'T_STRING_CAST') && $cast === '(binary)')) {
                $canonical = array('(boolean)' => '(bool)', '(integer)' => '(int)', '(double)' => '(float)', '(binary)' => '(string)');
                $this->rule($file, $tok[2], 'noncanonical-cast', $cast, "$cast cast: write {$canonical[$cast]} (deprecated from PHP 8.5)");
            } elseif ($id === '`') {
                $this->rule($file, $tok[2], 'backtick', '`', 'the backtick operator: call shell_exec() (deprecated from PHP 8.5)');
                // skip to the closing backtick
                for ($i++; $i < $n && $toks[$i][0] !== '`'; $i++) {
                }
            }
        }
    }

    /** Is the '{' at $i an offset, as in $s{0}, $a[1]{2}, $o->p{3}? */
    private function offsetBefore($toks, $i)
    {
        $prev = $toks[$i - 1];
        if (self::is($prev, 'T_VARIABLE') || $prev[0] === ']') {
            return !($i > 1 && (self::is($toks[$i - 2], 'T_CLASS') || self::is($toks[$i - 2], 'T_FUNCTION')));
        }
        if (self::is($prev, 'T_STRING') && $i > 1) {
            $before = $toks[$i - 2];
            return self::is($before, 'T_OBJECT_OPERATOR') || self::is($before, 'T_NULLSAFE_OBJECT_OPERATOR');
        }
        return false;
    }

    /** Parameters typed without null but defaulting to null: implicitly nullable. */
    private function params($file, $toks, $i)
    {
        $n = count($toks);
        for ($j = $i + 1; $j < $n && $toks[$j][0] !== '('; $j++) {
            if ($toks[$j][0] === '{' || $toks[$j][0] === ';') {
                return;
            }
        }
        $depth = 0;
        $param = array();
        // brackets and what's inside them (defaults like array(), attributes) are left out:
        // only a default of exactly `null` matters here
        for ($j++; $j < $n; $j++) {
            $id = $toks[$j][0];
            if ($id === '(' || $id === '[' || self::is($toks[$j], 'T_ATTRIBUTE')) {
                $depth++;
                continue;
            }
            if ($id === ')' || $id === ']') {
                if ($depth === 0) {
                    $this->param($file, $param);
                    return;
                }
                $depth--;
                continue;
            }
            if ($depth === 0 && $id === ',') {
                $this->param($file, $param);
                $param = array();
                continue;
            }
            if ($depth === 0) {
                $param[] = $toks[$j];
            }
        }
    }

    private function param($file, $param)
    {
        $type = array();
        $k = 0;
        $m = count($param);
        for (; $k < $m; $k++) {
            $p = $param[$k];
            if (self::is($p, 'T_VARIABLE') || $p[0] === '&' || self::is($p, 'T_ELLIPSIS')) {
                break;
            }
            if (self::is($p, 'T_PUBLIC') || self::is($p, 'T_PROTECTED') || self::is($p, 'T_PRIVATE') || self::is($p, 'T_READONLY')) {
                continue;
            }
            $type[] = $p;
        }
        while ($k < $m && !self::is($param[$k], 'T_VARIABLE')) {
            $k++;
        }
        // a type, then the variable, '=' and exactly one token: null
        if (!$type || !isset($param[$k + 1], $param[$k + 2]) || $param[$k + 1][0] !== '=' || isset($param[$k + 3])) {
            return;
        }
        if (!self::is($param[$k + 2], 'T_STRING') || strtolower($param[$k + 2][1]) !== 'null') {
            return;
        }
        if ($type[0][0] === '?') {
            return;
        }
        foreach ($type as $t) {
            if (self::is($t, 'T_STRING') && in_array(strtolower($t[1]), array('null', 'mixed'), true)) {
                return;
            }
        }
        $text = '';
        foreach ($type as $t) {
            $text .= $t[1];
        }
        $this->rule($file, $param[$k][2], 'implicit-nullable', $param[$k][1],
            "parameter $text {$param[$k][1]} = null: write ?$text (deprecated from PHP 8.4)");
    }
}

/** The files under each path: a file as given, a folder's .php, .inc and .phtml files.
 *  Paths that don't exist are put in $missing. */
function upgradeScanFiles($paths, &$missing)
{
    $files = array();
    $missing = array();
    foreach ($paths as $path) {
        if (is_file($path)) {
            $files[] = $path;
        } elseif (is_dir($path)) {
            $it = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($path, FilesystemIterator::SKIP_DOTS));
            foreach ($it as $f) {
                if ($f->isFile() && preg_match('/\.(php|inc|phtml)$/i', $f->getFilename())) {
                    $files[] = $f->getPathname();
                }
            }
        } else {
            $missing[] = $path;
        }
    }
    $files = array_values(array_unique($files));
    sort($files);
    return $files;
}

/** "8.3" from "8.3" or "8.3.12"; null if it isn't a version. */
function upgradeScanVersion($v)
{
    return preg_match('/^(\d+)\.(\d+)(\.\d+)?$/', $v, $m) ? $m[1] . '.' . $m[2] : null;
}

/**
 * Scans $files for what changes from PHP $from (null: from the start of the facts) to $to,
 * looking for definitions (polyfills) in $files and in $defs, and returns what --json prints,
 * as an array. For tools that include this file: they choose the files and word the report.
 */
function upgradeScanRun($facts, $from, $to, $files, $defs = array())
{
    UpgradeScan::tokenIds();
    $scan = new UpgradeScan($facts, $from, $to);
    // Two passes, each file tokenized once per pass: holding every file's tokens between them
    // would take gigabytes on a large codebase. A definitions-only file that never mentions a
    // symbol in scope can't define one, so it isn't tokenized.
    $pattern = $scan->namesPattern();
    $scanned = array_flip($files);
    foreach ($files as $f) {
        $scan->collect(UpgradeScan::tokens((string)file_get_contents($f)));
    }
    foreach ($defs as $f) {
        if (isset($scanned[$f])) {
            continue;
        }
        $code = (string)file_get_contents($f);
        if ($pattern !== null && preg_match($pattern, $code)) {
            $scan->collect(UpgradeScan::tokens($code));
        }
    }
    foreach ($files as $f) {
        $scan->scan($f, UpgradeScan::tokens((string)file_get_contents($f)));
    }
    $counts = array('wontload' => 0, 'fatal' => 0, 'silent' => 0, 'deprecated' => 0, 'guarded' => 0);
    $deprecated = array();
    foreach ($scan->findings as $x) {
        if ($x['guard'] !== null) {
            $counts['guarded']++;
            continue;
        }
        $counts[$x['kind']]++;
        if ($x['kind'] === 'deprecated') {
            $deprecated[$x['name']] = isset($deprecated[$x['name']]) ? $deprecated[$x['name']] + 1 : 1;
        }
    }
    if ($deprecated) {
        // most first, then by name, the same on every PHP (sorting is stable only from 8.0)
        $names = array_keys($deprecated);
        $numbers = array_values($deprecated);
        array_multisort($numbers, SORT_DESC, $names, SORT_ASC);
        $deprecated = array_combine($names, $numbers);
    }
    $covers = isset($facts['covers']['to']) ? $facts['covers']['to'] : null;
    return array(
        'schema' => 'php-upgrade-catalogue scan 1',
        'scanner' => UpgradeScan::VERSION,
        'facts' => isset($facts['version']) ? $facts['version'] : null,
        'php' => array('from' => $from, 'to' => $to),
        'facts_cover' => $covers,
        'beyond_facts' => $covers !== null && version_compare($to, $covers, '>'),
        'files' => count($files),
        'counts' => $counts,
        'deprecated_by_name' => (object)$deprecated,
        'findings' => $scan->findings,
    );
}

if (PHP_SAPI === 'cli' && isset($argv[0]) && realpath($argv[0]) === realpath(__FILE__)) {
    $usage = "usage: php scan.php --facts=php-changes.json [--php=FROM:TO | --php=TO] [--json] [--stdin] [--defs=PATH]... [PATH...]\n";
    $factsFile = null;
    $php = null;
    $json = false;
    $stdin = false;
    $paths = array();
    $defPaths = array();
    foreach (array_slice($argv, 1) as $arg) {
        if (strpos($arg, '--facts=') === 0) {
            $factsFile = substr($arg, 8);
        } elseif (strpos($arg, '--php=') === 0) {
            $php = substr($arg, 6);
        } elseif (strpos($arg, '--defs=') === 0) {
            $defPaths[] = substr($arg, 7);
        } elseif ($arg === '--json') {
            $json = true;
        } elseif ($arg === '--stdin') {
            $stdin = true;
        } elseif ($arg === '--version') {
            echo UpgradeScan::VERSION, "\n";
            exit(0);
        } elseif ($arg === '--help' || $arg === '-h') {
            echo $usage;
            exit(0);
        } elseif (strpos($arg, '--') === 0) {
            fwrite(STDERR, "unknown option: $arg\n$usage");
            exit(2);
        } else {
            $paths[] = $arg;
        }
    }
    if ($stdin) {
        while (($line = fgets(STDIN)) !== false) {
            $line = rtrim($line, "\r\n");
            if ($line !== '') {
                $paths[] = $line;
            }
        }
    }
    if ($factsFile === null || (!$paths && !$stdin)) {
        fwrite(STDERR, $usage);
        exit(2);
    }
    if ($php === null) {
        $from = null;
        $to = PHP_MAJOR_VERSION . '.' . PHP_MINOR_VERSION;
    } elseif (strpos($php, ':') !== false) {
        $parts = explode(':', $php, 2);
        $from = upgradeScanVersion($parts[0]);
        $to = upgradeScanVersion($parts[1]);
    } else {
        $from = null;
        $to = upgradeScanVersion($php);
    }
    if ($to === null || ($php !== null && strpos($php, ':') !== false && $from === null)) {
        fwrite(STDERR, "--php takes FROM:TO or TO, as versions like 7.4 or 8.3.12: got $php\n");
        exit(2);
    }
    if ($from !== null && version_compare($from, $to, '>=')) {
        fwrite(STDERR, "--php=$php: FROM must be older than TO\n");
        exit(2);
    }
    $facts = is_file($factsFile) ? json_decode((string)file_get_contents($factsFile), true) : null;
    if (!is_array($facts) || !isset($facts['schema'], $facts['versions']) || strpos($facts['schema'], 'php-upgrade-catalogue php-changes ') !== 0) {
        fwrite(STDERR, "not a php-upgrade-catalogue facts file: $factsFile\n");
        exit(2);
    }
    $files = upgradeScanFiles($paths, $missing);
    $defs = upgradeScanFiles($defPaths, $missingDefs);
    if ($missing || $missingDefs) {
        fwrite(STDERR, 'not found: ' . implode(', ', array_merge($missing, $missingDefs)) . "\n");
        exit(2);
    }
    $result = upgradeScanRun($facts, $from, $to, $files, $defs);
    if ($json) {
        echo json_encode($result, defined('JSON_UNESCAPED_SLASHES') ? JSON_UNESCAPED_SLASHES : 0), "\n";
    } else {
        foreach ($result['findings'] as $x) {
            echo "{$x['file']}:{$x['line']}  PHP {$x['php']}  {$x['kind']}  {$x['message']}" . ($x['guard'] !== null ? "  [not counted: {$x['guard']}]" : '') . "\n";
        }
        $c = $result['counts'];
        echo $result['files'] . ' files checked for PHP ' . ($from === null ? '' : "$from to ") . "$to: {$c['wontload']} won't load, "
            . "{$c['fatal']} fatal, {$c['silent']} silent, {$c['deprecated']} deprecated, {$c['guarded']} guarded (not counted)\n";
        if ($result['beyond_facts']) {
            echo "note: the facts cover PHP up to {$result['facts_cover']}; what PHP $to changes after that isn't checked\n";
        }
    }
    exit($result['counts']['wontload'] + $result['counts']['fatal'] > 0 ? 1 : 0);
}
