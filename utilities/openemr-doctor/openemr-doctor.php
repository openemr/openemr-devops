<?php

/**
 * OpenEMR install doctor: why a blank page, an error 500, a failed setup or a broken
 * screen after copying or moving an install.
 *
 * On the server, with the PHP your web server uses:
 *
 *     php openemr-doctor.php --openemr=/var/www/html/openemr [--site=default] [--facts=DIR_OR_URL] [--skip=NAME,...] [--debug]
 *
 * Or, to check the web server's own PHP (it can differ from the command line's), copy this
 * file into the OpenEMR folder under a name with a random part of your own, such as
 * openemr-doctor-7f3a9c2e41b8d605.php, and open http://localhost/openemr/<that name> in a
 * browser on the server itself. It answers no one else. Delete it when you are done.
 *
 * It compares the install with the facts for its release (generated from OpenEMR's source and
 * downloaded from DOCTOR_FACTS below, or read from --facts=DIR on a server without internet), with
 * what the install's own composer.json asks for, and with what OpenEMR needs to start. It only
 * reads: nothing in the install or its database is changed. It never prints passwords or keys.
 *
 * Written for PHP 5.4 and later, so that it can explain a PHP that is too old instead of
 * failing to start on it. --skip (or ?skip= in the browser) leaves checks out by name (documents,
 * local-changes-php and the rest: see $doctorChecks below and the README); each prints a SKIP line.
 * Exit code: 1 if any check fails, else 0. --debug (or ?debug=1 in the
 * browser) also prints where each fact came from and how much of it there was, and the timings.
 *
 * @license GPL-3.0-or-later
 */

// The error display this PHP is set up with, read before the doctor sets its own below: the php.ini
// check reports these, not the doctor's.
$phpDisplayErrors = (string)ini_get('display_errors');
$phpErrorReporting = error_reporting();
error_reporting(E_ALL);
// This copy: its version and the day it was released (gen/check.py: the same version as the scripts').
define('DOCTOR_VERSION', '0.5.3');
define('DOCTOR_DATE', '2026-11-06');
// The doctor's home: where openemr-doctor-docker.sh downloads the newest doctor from, and where this
// copy looks for a newer one of itself. OPENEMR_DOCTOR_HOME overrides it.
define('DOCTOR_HOME', 'https://raw.githubusercontent.com/openemr/openemr-devops/master/utilities/openemr-doctor');
// The release facts, a setting of their own: a folder beside this file (openemr-doctor-facts/), else
// the generator's own output, else the published copy, updated from OpenEMR's release tags every day.
define('DOCTOR_FACTS', 'https://raw.githubusercontent.com/anun333/openemr-reference/main/site/preflight');
$factsDefault = DOCTOR_FACTS;
foreach (array(dirname(__FILE__) . '/openemr-doctor-facts', dirname(__FILE__) . '/../site/preflight') as $dir) {
    if (is_file("$dir/releases.json")) {
        $factsDefault = $dir;
        break;
    }
}
define('DOCTOR_FACTS_DEFAULT', $factsDefault);

$web = PHP_SAPI !== 'cli';
if ($web) {
    // Only the server itself, not through a proxy that says it forwards, and only under a name of
    // your own: a proxy on this server that adds no forwarding header (nginx's proxy_pass doesn't by
    // default) makes every visitor look local, so the random part of the file's name is the key.
    $addr = isset($_SERVER['REMOTE_ADDR']) ? $_SERVER['REMOTE_ADDR'] : '';
    $proxied = isset($_SERVER['HTTP_X_FORWARDED_FOR']) || isset($_SERVER['HTTP_FORWARDED']) || isset($_SERVER['HTTP_X_REAL_IP']);
    $keyed = (bool)preg_match('/^openemr-doctor-[A-Za-z0-9]{12,}\.php$/', basename(__FILE__));
    if (!in_array($addr, array('127.0.0.1', '::1', '::ffff:127.0.0.1'), true) || $proxied || !$keyed) {
        header('HTTP/1.1 403 Forbidden');
        header('Content-Type: text/plain; charset=utf-8');
        echo "The OpenEMR install doctor only answers a browser on this server (http://localhost/...), under a name of your own.\n";
        if (!$keyed) {
            echo 'Rename this file with a random part of 12 or more letters and digits, such as openemr-doctor-' . substr(sha1(uniqid((string)mt_rand(), true)), 0, 16) . ".php, and open that name.\n";
        }
        echo "Delete this file when you are done with it.\n";
        exit;
    }
    header('Content-Type: text/plain; charset=utf-8');
    ini_set('display_errors', '1');
    $root = dirname(__FILE__);
    $site = isset($_GET['site']) ? preg_replace('/[^A-Za-z0-9._-]/', '', (string)$_GET['site']) : 'default';
    $factsBase = DOCTOR_FACTS_DEFAULT;
    $debug = !empty($_GET['debug']);
    $skipList = isset($_GET['skip']) ? array((string)$_GET['skip']) : array();
} else {
    ini_set('display_errors', 'stderr');
    $opts = getopt('', array('openemr:', 'site:', 'facts:', 'skip:', 'list-checks', 'help', 'debug'));
    if (isset($opts['help']) || (empty($opts['openemr']) && !isset($opts['list-checks']))) {
        fwrite(STDERR, "usage: php openemr-doctor.php --openemr=/path/to/openemr [--site=default] [--facts=DIR_OR_URL] [--skip=NAME,...] [--debug] | --list-checks\n");
        exit(2);
    }
    $skipList = isset($opts['skip']) ? (array)$opts['skip'] : array();
    $root = rtrim(isset($opts['openemr']) ? (string)$opts['openemr'] : '', '/\\');
    $site = isset($opts['site']) ? (string)$opts['site'] : 'default';
    $factsBase = isset($opts['facts']) ? rtrim((string)$opts['facts'], '/') : DOCTOR_FACTS_DEFAULT;
    $debug = isset($opts['debug']);
}
define('DOCTOR_DEBUG', $debug);
define('DOCTOR_START', microtime(true));

/** With --debug: what the doctor decided and why, prefixed so it can't be mistaken for a check. */
function debug($message)
{
    if (DOCTOR_DEBUG) {
        echo 'DEBUG ' . sprintf('%6.2fs', microtime(true) - DOCTOR_START) . ' ' . $message . "\n";
    }
}

// The checks --skip can leave out, by name. The install, the release facts, the site, setup and the
// database connection aren't among them: every other check needs them.
$doctorChecks = array(
    'php' => 'PHP', 'php-security' => 'PHP security', 'php-extensions' => 'PHP extensions', 'php-ini' => 'php.ini',
    'php-libraries' => 'PHP libraries', 'page-assets' => 'Page assets', 'files' => 'Files', 'local-changes' => 'Local changes',
    'local-changes-php' => 'Local changes on this PHP', 'documents-folder' => 'Documents folder', 'database-server' => 'Database server',
    'database-version' => 'Database version', 'theme' => 'Theme', 'error-display' => 'Error display', 'modules' => 'Modules',
    'encryption-keys' => 'Encryption keys', 'documents' => 'Documents', 'api-keys' => 'API keys',
);
if (!$web && isset($opts['list-checks'])) {
    // The names --skip takes, one per line, for openemr-upgrade.sh and for people.
    echo implode("\n", array_keys($doctorChecks)), "\n";
    exit(0);
}
$skip = array();
foreach ($skipList as $list) {
    foreach (explode(',', (string)$list) as $name) {
        $name = trim($name);
        if ($name === '') {
            continue;
        }
        if (!isset($doctorChecks[$name])) {
            $known = "no check named '" . preg_replace('/[^a-z0-9-]/', '', $name) . "' to skip; the names are " . implode(', ', array_keys($doctorChecks));
            if ($web) {
                echo "$known\n";
                exit;
            }
            fwrite(STDERR, "--skip: $known\n");
            exit(2);
        }
        $skip[$name] = true;
    }
}
$skipped = array();
/** Whether the check named $name is left out (--skip); says so when it is. */
function skipped($name)
{
    global $skip, $skipped, $doctorChecks;
    if (!isset($skip[$name])) {
        return false;
    }
    echo 'SKIP  ' . $doctorChecks[$name] . ": left out (--skip=$name)\n";
    $skipped[] = $name;
    return true;
}

$results = array();
function report($status, $check, $detail, $fix = '')
{
    global $results;
    $results[] = $status;
    echo str_pad($status, 5) . ' ' . $check . ': ' . $detail . "\n";
    if ($fix !== '') {
        echo '      ' . $fix . "\n";
    }
}

function facts($base, $name)
{
    if ($base === '') {
        return null;
    }
    $context = stream_context_create(array('http' => array('timeout' => 15, 'user_agent' => 'openemr-doctor')));
    $started = microtime(true);
    $raw = @file_get_contents($base . '/' . $name . '.json', false, $context);
    if ($raw === false) {
        debug("facts $name.json: not read from $base");
        return null;
    }
    $data = json_decode($raw, true);
    debug("facts $name.json: " . strlen($raw) . ' bytes from ' . $base . sprintf(' in %.2fs', microtime(true) - $started) . (is_array($data) ? '' : ', not valid JSON'));
    return is_array($data) ? $data : null;
}

/** The variables a PHP config file sets, without running it in this scope. */
function readConfig($path, $names)
{
    $read = function ($__path) {
        include $__path;
        return get_defined_vars();
    };
    $vars = $read($path);
    return array_intersect_key($vars, array_flip($names));
}

/**
 * The version of the doctor at its home ($home/openemr-doctor.php), from the first 8 KB of that
 * file, or null when it can't be read (offline, blocked, or anything unexpected).
 */
function homeVersion($home)
{
    $context = stream_context_create(array('http' => array('timeout' => 5, 'user_agent' => 'openemr-doctor')));
    $fp = @fopen($home . '/openemr-doctor.php', 'r', false, $context);
    if ($fp === false) {
        return null;
    }
    $head = (string)stream_get_contents($fp, 8192);
    fclose($fp);
    return preg_match("/^define\\('DOCTOR_VERSION', '([0-9]+(?:\\.[0-9]+)*)'\\);\$/m", $head, $m) ? $m[1] : null;
}

/** How many days ago this copy was released (DOCTOR_DATE). gmmktime, which needs no time zone: PHP 5 warns without one. */
function doctorAgeDays()
{
    $d = array_map('intval', explode('-', DOCTOR_DATE));
    return max(0, (int)floor((time() - gmmktime(0, 0, 0, $d[1], $d[2], $d[0])) / 86400));
}

function versionKey($v)
{
    return array_map('intval', explode('.', $v));
}

function cmpVersion($a, $b)
{
    $x = versionKey($a);
    $y = versionKey($b);
    for ($i = 0; $i < max(count($x), count($y)); $i++) {
        $p = isset($x[$i]) ? $x[$i] : 0;
        $q = isset($y[$i]) ? $y[$i] : 0;
        if ($p !== $q) {
            return $p < $q ? -1 : 1;
        }
    }
    return 0;
}

/**
 * The lowest PHP a Composer constraint allows, as X.Y.Z: '>=8.3.0' (every OpenEMR release so far),
 * '^8.2', '~8.1', '8.2.*', '>=7.4 <8.3', '^7.4 || ^8.0'. Null when it can't tell (a form it doesn't
 * read, or an alternative with no lower bound).
 */
function phpFloor($constraint)
{
    $floor = null;
    $constraint = preg_replace('/(>=|<=|!=|==|>|<|=|\^|~)\s+/', '$1', trim((string)$constraint));
    foreach (preg_split('/\s*\|\|?\s*/', $constraint) as $alternative) {
        $low = null;
        foreach (preg_split('/\s*,\s*|\s+/', trim($alternative)) as $term) {
            if (preg_match('/^(<|!=)/', $term)) {
                continue; // an upper bound, or one version left out
            }
            if (!preg_match('/^(?:>=|>|\^|~|==?)?v?([0-9]+)(?:\.([0-9]+))?(?:\.([0-9]+))?(?:\.\*)?$/', $term, $m)) {
                return null;
            }
            $v = $m[1] . '.' . (isset($m[2]) && $m[2] !== '' ? $m[2] : '0') . '.' . (isset($m[3]) && $m[3] !== '' ? $m[3] : '0');
            $low = $low === null || cmpVersion($v, $low) > 0 ? $v : $low;
        }
        if ($low === null) {
            return null;
        }
        $floor = $floor === null || cmpVersion($low, $floor) < 0 ? $low : $floor;
    }
    return $floor;
}

/**
 * Whether a Composer constraint allows a PHP version, upper bounds included: '>=7.2 <8.0' and
 * '^7.3 || ^8.0' (which stops before 9.0) allow 7.4.33 but not 9.0.0; '~8.1.0' stops before 8.2.
 * Null when it can't tell (a form it doesn't read, or an exact version).
 */
function phpAllows($constraint, $version)
{
    $constraint = preg_replace('/(>=|<=|!=|==|>|<|=|\^|~)\s+/', '$1', trim((string)$constraint));
    foreach (preg_split('/\s*\|\|?\s*/', $constraint) as $alternative) {
        $allows = true;
        foreach (preg_split('/\s*,\s*|\s+/', trim($alternative)) as $term) {
            if (!preg_match('/^(>=|<=|!=|==?|>|<|\^|~)?v?([0-9]+)(?:\.([0-9]+))?(?:\.([0-9]+))?(\.\*)?$/', $term, $m)) {
                return null;
            }
            $op = $m[1];
            $given = isset($m[4]) && $m[4] !== '' ? 3 : (isset($m[3]) && $m[3] !== '' ? 2 : 1);
            $x = (int)$m[2];
            $y = $given > 1 ? (int)$m[3] : 0;
            $low = "$x.$y." . ($given > 2 ? (int)$m[4] : 0);
            $wild = isset($m[5]) && $m[5] !== '';
            $cmp = cmpVersion($version, $low);
            if ($wild || $op === '^' || $op === '~') {
                // A range from $low up to (not including) the next major, or the next minor for
                // ~X.Y.Z and X.Y.*.
                $high = ($wild && $given === 2) || ($op === '~' && $given === 3) ? $x . '.' . ($y + 1) . '.0' : ($x + 1) . '.0.0';
                $ok = $cmp >= 0 && cmpVersion($version, $high) < 0;
            } elseif ($op === '>=' || $op === '>' || $op === '<=' || $op === '<' || $op === '!=') {
                $ok = ($op === '>=' && $cmp >= 0) || ($op === '>' && $cmp > 0) || ($op === '<=' && $cmp <= 0) || ($op === '<' && $cmp < 0) || ($op === '!=' && $cmp !== 0);
            } else {
                return null; // an exact version: Composer reads '8.2' as 8.2.0.0 alone
            }
            $allows = $allows && $ok;
        }
        if ($allows) {
            return true;
        }
    }
    return false;
}

/** What the install's own composer.json requires: array('php' => constraint, 'floor' => X.Y.Z or null, 'extensions' => names), or null without one. */
function ownComposer($root)
{
    $raw = is_readable("$root/composer.json") ? @file_get_contents("$root/composer.json") : false;
    $json = $raw === false ? null : json_decode($raw, true);
    if (!is_array($json) || !isset($json['require']) || !is_array($json['require'])) {
        return null;
    }
    $extensions = array();
    foreach (array_keys($json['require']) as $name) {
        if (strpos((string)$name, 'ext-') === 0) {
            $extensions[] = substr((string)$name, 4);
        }
    }
    sort($extensions);
    $php = isset($json['require']['php']) ? (string)$json['require']['php'] : '';
    return array('php' => $php, 'floor' => $php !== '' ? phpFloor($php) : null, 'extensions' => $extensions);
}

/**
 * Whether this install's sql/patch.sql changes anything in the database: a line that isn't a
 * comment (--), a #If/#EndIf directive or blank. Null when it can't be read.
 */
function patchSqlHasStatements($root)
{
    $sql = is_readable("$root/sql/patch.sql") ? @file_get_contents("$root/sql/patch.sql") : false;
    return $sql === false ? null : (bool)preg_match('/^(?![ \t]*(?:--|#))[ \t]*\S/m', $sql);
}

/** A php.ini size in bytes; -1 for unlimited. */
function bytes($v)
{
    $v = trim((string)$v);
    if ($v === '' || $v === '-1') {
        return -1.0;
    }
    $n = (float)$v;
    switch (strtoupper(substr($v, -1))) {
        case 'G':
            return $n * 1073741824;
        case 'M':
            return $n * 1048576;
        case 'K':
            return $n * 1024;
    }
    return (float)$n;
}

/** Whether OpenEMR's own PHP (not vendor/, node_modules/ or sites/) uses a class or function of the intl extension. */
function codeUsesIntl($root)
{
    $tokens = array('Normalizer::', 'IntlDateFormatter', 'NumberFormatter', 'Locale::', 'Collator', 'MessageFormatter',
        'Transliterator', 'IntlCalendar', 'grapheme_', 'idn_to_');
    $skip = array('vendor', 'node_modules', 'sites', '.git');
    $dirs = new RecursiveIteratorIterator(new RecursiveCallbackFilterIterator(
        new RecursiveDirectoryIterator($root, FilesystemIterator::SKIP_DOTS),
        function ($file, $key, $iterator) use ($skip) {
            return !($iterator->hasChildren() && in_array($file->getFilename(), $skip, true));
        }
    ), RecursiveIteratorIterator::LEAVES_ONLY, RecursiveIteratorIterator::CATCH_GET_CHILD); // past a folder it can't open
    foreach ($dirs as $file) {
        if (substr($file->getFilename(), -4) !== '.php' || !$file->isReadable()) {
            continue;
        }
        $content = (string)file_get_contents($file->getPathname());
        foreach ($tokens as $token) {
            if (strpos($content, $token) !== false) {
                return true;
            }
        }
    }
    return false;
}

/**
 * The database server's certificate, read the way a MySQL client starts SSL: its greeting,
 * an SSL request, then the TLS handshake. Unverified, to see what it holds. Returns the
 * certificate, or why it couldn't be read.
 */
function serverCertificate($host, $port)
{
    $context = stream_context_create(array('ssl' => array('verify_peer' => false, 'verify_peer_name' => false, 'allow_self_signed' => true, 'capture_peer_cert' => true)));
    $socket = @stream_socket_client("tcp://$host:$port", $errno, $errstr, 10, STREAM_CLIENT_CONNECT, $context);
    if (!$socket) {
        return "nothing answered at $host:$port ($errstr)";
    }
    stream_set_timeout($socket, 10);
    $header = (string)fread($socket, 4);
    if (strlen($header) < 4) {
        fclose($socket);
        return 'the server sent no greeting';
    }
    $length = ord($header[0]) | (ord($header[1]) << 8) | (ord($header[2]) << 16);
    $greeting = '';
    while (strlen($greeting) < $length && !feof($socket)) {
        $greeting .= (string)fread($socket, $length - strlen($greeting));
    }
    if ($greeting === '' || ord($greeting[0]) === 0xff) {
        fclose($socket);
        return 'the server refused the connection before SSL';
    }
    // SSLRequest: CLIENT_PROTOCOL_41 | CLIENT_SSL | CLIENT_SECURE_CONNECTION, max packet, utf8, zeros.
    $payload = pack('V', 0x0200 | 0x0800 | 0x8000) . pack('V', 16777216) . chr(33) . str_repeat("\0", 23);
    fwrite($socket, substr(pack('V', strlen($payload)), 0, 3) . chr(1) . $payload);
    $method = defined('STREAM_CRYPTO_METHOD_ANY_CLIENT') ? STREAM_CRYPTO_METHOD_ANY_CLIENT : STREAM_CRYPTO_METHOD_TLS_CLIENT;
    if (!@stream_socket_enable_crypto($socket, true, $method)) {
        fclose($socket);
        return 'the SSL handshake with the server failed';
    }
    $params = stream_context_get_params($socket);
    fclose($socket);
    return isset($params['options']['ssl']['peer_certificate']) ? $params['options']['ssl']['peer_certificate'] : 'the server sent no certificate';
}

/** Whether a certificate name (an exact name, a *.wildcard or an IP) covers the host. */
function certificateNameMatches($name, $host)
{
    $name = strtolower($name);
    $host = strtolower($host);
    if ($name === $host) {
        return true;
    }
    if (substr($name, 0, 2) === '*.' && strpos($host, '.') !== false) {
        return substr($host, strpos($host, '.')) === substr($name, 1);
    }
    return false;
}

/** Why PHP refused the server's certificate: the CA, the name, or neither it can see. */
function sslDiagnosis($host, $port, $ca)
{
    $generic = "Either documents/certificates/mysql-ca isn't the CA that signed the server's certificate, or the host '$host' in sqlconf.php isn't a name in that certificate (PHP checks both).";
    if (!function_exists('openssl_x509_parse')) {
        return $generic . ' (The openssl extension is missing, so the doctor can\'t tell which.)';
    }
    $cert = serverCertificate($host, $port);
    if (is_string($cert)) {
        return $generic . " (The doctor couldn't read the server's certificate: $cert.)";
    }
    $info = openssl_x509_parse($cert);
    // The names PHP checks the host against: the certificate's DNS and IP names, and its Common Name
    // only when it has no DNS name (PHP 8.2 and 8.4 refuse a Common Name match beside a DNS name).
    $names = array();
    $hasDns = false;
    if (isset($info['extensions']['subjectAltName'])) {
        foreach (explode(',', $info['extensions']['subjectAltName']) as $alt) {
            $alt = trim($alt);
            if (preg_match('/^(DNS|IP Address):(.+)$/', $alt, $m)) {
                $names[] = trim($m[2]);
                $hasDns = $hasDns || $m[1] === 'DNS';
            }
        }
    }
    if (!$hasDns && isset($info['subject']['CN'])) {
        $names[] = (string)$info['subject']['CN'];
    }
    $names = array_values(array_unique($names));
    $issuer = isset($info['issuer']['CN']) ? (string)$info['issuer']['CN'] : 'an unnamed issuer';
    $caInfo = @openssl_x509_parse((string)@file_get_contents($ca));
    $caName = is_array($caInfo) && isset($caInfo['subject']['CN']) ? (string)$caInfo['subject']['CN'] : 'mysql-ca';
    if (openssl_x509_checkpurpose($cert, X509_PURPOSE_ANY, array($ca)) !== true) {
        return "The server's certificate was issued by '$issuer', and documents/certificates/mysql-ca ('$caName') didn't sign it. Put the server's own CA certificate in mysql-ca (Google Cloud SQL: the instance's server CA, from its Connections page).";
    }
    foreach ($names as $name) {
        if (certificateNameMatches($name, $host)) {
            return "The server's certificate is signed by mysql-ca and names '$host', so the refusal is something else: check the certificate's dates, and mysql-cert and mysql-key.";
        }
    }
    return "The server's certificate names " . (count($names) > 0 ? "'" . implode("', '", $names) . "'" : 'nothing') . ", not '$host' in sqlconf.php, and PHP checks the name. Connect by one of those names, or through the database's own connector (Google Cloud SQL from Cloud Run: its Cloud SQL connection or the Auth Proxy, which encrypt without these files).";
}

function listSome($items, $n = 5)
{
    return implode(', ', array_slice($items, 0, $n)) . (count($items) > $n ? ' and ' . (count($items) - $n) . ' more' : '');
}

/** Whether a php.ini switch is on: its value now, or the value given (one read before the doctor changed it). */
function iniOn($name, $value = null)
{
    return in_array(strtolower($value === null ? (string)ini_get($name) : (string)$value), array('1', 'on', 'yes', 'true', 'stdout', 'stderr'), true);
}

// ------------------------------------------------------------ the install

if (!is_file("$root/version.php")) {
    $msg = "$root doesn't look like an OpenEMR folder (no version.php)";
    if ($web) {
        echo $msg . "\nCopy this file into the OpenEMR folder itself (the one with version.php and setup.php).\n";
        exit;
    }
    fwrite(STDERR, $msg . "\n");
    exit(2);
}
// A version.php that doesn't parse stops PHP 7 and later with a ParseError, said below as the
// Version check's failure (PHP 5 stops at the include, with PHP's own message).
$code = array();
$codeError = '';
if (is_readable("$root/version.php")) {
    try {
        $code = readConfig("$root/version.php", array('v_major', 'v_minor', 'v_patch', 'v_realpatch', 'v_database', 'v_tag'));
    } catch (ParseError $e) {
        $codeError = 'line ' . $e->getLine() . ': ' . $e->getMessage();
    }
}
// Everything below depends on the version: say so plainly when it can't be read, instead of
// comparing an empty one with the facts.
$versionKnown = isset($code['v_major'], $code['v_minor'], $code['v_patch']) && is_numeric($code['v_major']) && is_numeric($code['v_minor']) && is_numeric($code['v_patch']);
$current = $versionKnown ? $code['v_major'] . '.' . $code['v_minor'] . '.' . $code['v_patch'] : '0.0.0';
$patch = isset($code['v_realpatch']) ? (int)$code['v_realpatch'] : 0;
// A release has an empty tag; a build from the development branch says -dev (or -rc1 ...).
$tag = isset($code['v_tag']) ? trim((string)$code['v_tag']) : '';

echo "OpenEMR install doctor: $root (site $site), OpenEMR " . ($versionKnown ? "$current$tag" . ($patch ? " patch $patch" : '') : '(version unknown)') . "\n";
echo ($web ? 'Checked by the web server\'s PHP' : 'Checked by the command-line PHP') . ', ' . PHP_VERSION . ' (' . PHP_SAPI . ")\n";
echo 'Doctor ' . DOCTOR_VERSION . ' of ' . DOCTOR_DATE . "\n\n";
$home = getenv('OPENEMR_DOCTOR_HOME');
$home = is_string($home) && $home !== '' ? rtrim($home, '/') : DOCTOR_HOME;
debug('doctor ' . DOCTOR_VERSION . ' of ' . DOCTOR_DATE . ", home $home");

// The newest doctor is at its home, and this copy never updates itself: say when the home has a
// newer one, or, when it can't look (no internet, or told not to), how old this copy is. With the
// facts from a local folder it doesn't look: a server without internet makes no extra request.
$noCheck = getenv('OPENEMR_DOCTOR_NO_UPDATE_CHECK');
$noCheck = is_string($noCheck) && $noCheck !== '';
$homeVersion = !$noCheck && preg_match('#^https?://#', $factsBase) ? homeVersion($home) : null;
debug('the doctor at its home: ' . ($noCheck ? 'not asked (OPENEMR_DOCTOR_NO_UPDATE_CHECK)' : ($homeVersion === null ? 'not read' : $homeVersion)));
$age = doctorAgeDays();
if ($homeVersion !== null && cmpVersion($homeVersion, DOCTOR_VERSION) > 0) {
    report('NOTE', 'Doctor', "a newer doctor, $homeVersion, is at $home; this one is " . DOCTOR_VERSION . ' of ' . DOCTOR_DATE,
        "Download $home/openemr-doctor.php and run it again.");
} elseif ($homeVersion === null && !$noCheck) {
    report('NOTE', 'Doctor', 'this copy is ' . ($age === 0 ? 'from today' : ($age === 1 ? '1 day old' : "$age days old")) . ' (' . DOCTOR_DATE . '), and '
        . (preg_match('#^https?://#', $factsBase) ? "it couldn't reach $home to look for a newer one" : 'with the facts from a folder it doesn\'t look for a newer one'),
        "A newer one may be out: the newest is $home/openemr-doctor.php.");
}

if (!$versionKnown) {
    $who = function_exists('posix_geteuid') && function_exists('posix_getpwuid') ? posix_getpwuid(posix_geteuid()) : null;
    $who = is_array($who) ? $who['name'] : "this PHP's user";
    report('FAIL', 'Version', is_file("$root/version.php")
        ? ($codeError !== '' ? "version.php doesn't parse ($codeError)" : (is_readable("$root/version.php") ? "version.php doesn't set the version (v_major, v_minor, v_patch)" : "$who can't read version.php (" . substr(sprintf('%o', fileperms("$root/version.php")), -4) . ')'))
        : 'version.php is missing',
        'OpenEMR reads its version from it on every page. Make the web server\'s user able to read OpenEMR\'s files, or copy version.php again from the package. The checks that depend on the release are skipped.');
}
$releases = $versionKnown ? facts($factsBase, 'releases') : null;
$base = null;
$f = null;
if (!$versionKnown) {
    debug('release facts not read: the version is unknown');
} elseif ($releases === null) {
    $online = preg_match('#^https?://#', $factsBase);
    report('NOTE', 'Release facts', $online ? "couldn't download them from $factsBase" . (ini_get('allow_url_fopen') ? '' : ' (allow_url_fopen is off)') . (extension_loaded('openssl') ? '' : ' (openssl is missing)') : "not found at $factsBase",
        'The checks that need them (files, packages, page assets, the tested PHP and databases) are skipped; the rest still run, the PHP and extension checks from this install\'s composer.json. For a server without internet, copy the facts (' . DOCTOR_FACTS . ') into a folder named openemr-doctor-facts beside this file, or pass --facts=that folder.');
} else {
    foreach ($releases as $r) {
        if (cmpVersion($r, $current) <= 0) {
            $base = $r;
        }
    }
    $f = $base !== null ? facts($factsBase, $base) : null;
    if ($base === null) {
        report('NOTE', 'Release facts', "$current is older than any release with facts (" . $releases[0] . '); release checks skipped');
    } elseif ($f === null) {
        report('NOTE', 'Release facts', "can't read the facts for $base; release checks skipped");
    } elseif ($tag !== '') {
        report('NOTE', 'Release facts', "$current$tag is an unreleased build; comparing it with $base, the closest release with facts",
            "Files and packages it no longer has since $base show as missing, so those are notes here, not failures.");
    } elseif ($base !== $current) {
        report('NOTE', 'Release facts', "$current isn't a release with facts yet; using $base, the closest earlier one",
            "Files and packages $current removed show as missing, so those are notes here, not failures. The facts gain each new release within a day.");
    }
}
// Compared with another release than the one installed: what that release has and this one dropped
// looks missing, so missing files, packages and assets can't be called failures.
$approx = $f !== null && ($base !== $current || $tag !== '');
debug('version ' . $current . ($tag !== '' ? " tag $tag" : ' (no tag)') . ($patch ? " patch $patch" : '') . ', database version ' . (isset($code['v_database']) ? $code['v_database'] : '?')
    . '; facts from ' . $factsBase . '; compared with ' . ($base === null ? 'nothing' : $base) . ($approx ? ' (another release, so missing files are notes)' : ''));

// A patched install has the patch tag's files: Docker images are built from it, and a patch
// zip adds and overwrites but never deletes. Patches remove files (7.0.3 patch 4 dropped
// the old login templates), so compare with the patch's facts when there are some.
$label = "OpenEMR $base";
$fileFacts = $base !== null ? $base . '-files' : null;
$composerList = ($f !== null && isset($f['composer'])) ? $f['composer'] : null;
$assetList = ($f !== null && isset($f['assets'])) ? $f['assets'] : null;
if ($f !== null && $patch > 0 && $base === $current) {
    if (isset($f['patches'][$patch])) {
        $label = "OpenEMR $base patch $patch";
        $fileFacts = "$base-p$patch-files";
        $composerList = $f['patches'][$patch]['composer'];
        $assetList = $f['patches'][$patch]['assets'];
    } else {
        report('NOTE', 'Release facts', "none for patch $patch of $base; comparing files with $base as released, so files the patch removed may show as missing");
        $approx = true;
    }
}

// ------------------------------------------------------------ PHP
// Forum: a PHP too old fails with a parse error before OpenEMR can say anything
// (t/24361, t/24365, t/24048); one newer than tested breaks too (t/24282, t/26030, t/26133).

$phpShort = PHP_MAJOR_VERSION . '.' . PHP_MINOR_VERSION;
// The install's own composer.json says which PHP and extensions its code needs. It is what the
// facts are read from, so it answers without them, and it is newer than the facts for a release
// they don't have yet. With both, the higher PHP floor counts, and a lower one is said.
$own = $versionKnown ? ownComposer($root) : null;
$ownFloor = $own !== null ? $own['floor'] : null;
debug("this install's composer.json: " . ($own === null ? 'not read' : "php '" . $own['php'] . "' (from " . ($ownFloor === null ? '?' : $ownFloor) . '), ' . count($own['extensions']) . ' extensions'));
if (skipped('php')) {
    // left out
} elseif ($f !== null || $ownFloor !== null) {
    $need = $f !== null ? $f['php'] : $ownFloor;
    $needBy = $f !== null ? "OpenEMR $base needs" : "this install's composer.json asks for";
    if ($f !== null && $ownFloor !== null && cmpVersion($ownFloor, $need) > 0) {
        $need = $ownFloor;
        $needBy = "this install's composer.json asks for";
    } elseif ($f !== null && $ownFloor !== null && cmpVersion($ownFloor, $need) < 0) {
        report('NOTE', 'PHP', "this install's composer.json asks for PHP " . $own['php'] . ", lower than the $need OpenEMR $base needs",
            "It was changed here, or comes from another release than version.php's. The doctor checks against $need.");
    }
    $tested = $f !== null && isset($f['ci_php']) ? $f['ci_php'] : array();
    // The floor above, and also any upper bound composer.json sets ('>=7.2 <8.0', '^7.3 || ^8.0').
    $allowed = $own !== null && $own['php'] !== '' ? phpAllows($own['php'], PHP_MAJOR_VERSION . '.' . PHP_MINOR_VERSION . '.' . PHP_RELEASE_VERSION) : null;
    if (cmpVersion(PHP_VERSION, $need) < 0) {
        report('FAIL', 'PHP', PHP_VERSION . " is too old: $needBy $need or later",
            $web ? 'This is the PHP the web server runs. Install a newer PHP and point the web server at it.'
                 : 'Install a newer PHP. If `php -v` shows a newer one than the web page does, the web server is using a different PHP: open this doctor from a browser on the server to check that one.');
    } elseif ($allowed === false) {
        report('WARN', 'PHP', PHP_VERSION . " is outside what this install's composer.json allows (php '" . $own['php'] . "')",
            'Its code was written for the versions it names, and can break on this one. Use a PHP it allows, or upgrade OpenEMR.');
    } elseif ($tested !== array() && cmpVersion($phpShort, end($tested)) > 0) {
        report('WARN', 'PHP', PHP_VERSION . " is newer than any PHP OpenEMR $base was tested with (" . implode(', ', $tested) . ')',
            'Newer PHP versions remove things older code relies on. Use a tested version, or upgrade OpenEMR.');
    } else {
        report('PASS', 'PHP', PHP_VERSION . " ($needBy $need or later" . ($tested ? '; tested with ' . implode(', ', $tested) : '') . ')');
    }
} else {
    report('NOTE', 'PHP', PHP_VERSION . ' (no release facts to compare with, and no composer.json that says)');
}

// PHP's security advisories, checked against the PHP the doctor runs on. php-security.json in the
// facts (hand-written from PHP's own announcements, each citing its page) lists them, so a new
// advisory is a change to the facts, not to the doctor; the list below, the one this copy was
// released with, is used without the facts. Distributions patch PHP without changing its number
// (Ubuntu 24.04 keeps 8.3.6), so for their builds a low number is only a warning. They don't mark
// the build in PHP itself (PHP_EXTRA_VERSION is empty on Ubuntu and Debian): it's found in the
// package database instead. Alpine's php8x packages, which OpenEMR's Docker images use, and PHP
// built from source (the official php images) carry PHP's own number.
$phpSecurityBuiltIn = array(
    // php2shell: unauthenticated remote code execution, actively exploited; OpenEMR's notice is t/27152.
    array('name' => 'php2shell', 'date' => '2026-10-21', 'cves' => array('CVE-2026-109618', 'CVE-2026-109619'),
        'impact' => 'remote code execution without logging in, actively exploited',
        'source' => 'https://www.php.net/archive/2026.php#2026-10-21-5', 'notice' => 'https://community.open-emr.org/t/27152',
        'fixed' => array('8.5' => '8.5.12', '8.4' => '8.4.27', '8.3' => '8.3.36', '8.2' => '8.2.35')),
);

/** Whether php-security.json's advisories are in the form this doctor reads. */
function advisoriesReadable($data)
{
    if (!is_array($data) || !isset($data['advisories']) || !is_array($data['advisories']) || $data['advisories'] === array()) {
        return false;
    }
    foreach ($data['advisories'] as $a) {
        if (!is_array($a) || !isset($a['name'], $a['date'], $a['cves'], $a['source'], $a['fixed']) || !is_string($a['name']) || $a['name'] === ''
            || !is_string($a['date']) || !preg_match('/^\d{4}-\d{2}-\d{2}$/', $a['date']) || !is_array($a['cves'])
            || !is_string($a['source']) || !preg_match('#^https://#', $a['source']) || !is_array($a['fixed']) || $a['fixed'] === array()) {
            return false;
        }
        foreach ($a['fixed'] as $branch => $version) {
            if (!preg_match('/^\d+\.\d+$/', (string)$branch) || !is_string($version) || strpos($version, $branch . '.') !== 0 || !preg_match('/^\d+\.\d+\.\d+$/', $version)) {
                return false;
            }
        }
    }
    return true;
}

/** The advisories' names, CVEs and the highest fix for this branch, for the report lines. */
function advisoryWords($list, $branch)
{
    $names = array();
    $cves = array();
    $fixed = '0';
    $top = $list[0];
    foreach ($list as $a) {
        $names[] = $a['name'];
        $cves = array_merge($cves, $a['cves']);
        if (isset($a['fixed'][$branch]) && cmpVersion($a['fixed'][$branch], $fixed) > 0) {
            $fixed = $a['fixed'][$branch];
            $top = $a;
        }
    }
    return array('names' => implode(' and ', $names), 'cves' => implode(', ', array_unique($cves)), 'fixed' => $fixed, 'top' => $top,
        'impact' => isset($top['impact']) && is_string($top['impact']) && $top['impact'] !== '' ? ': ' . $top['impact'] : '');
}

$apkName = 'php' . PHP_MAJOR_VERSION . PHP_MINOR_VERSION;
$apkDb = @is_readable('/lib/apk/db/installed') ? (string)@file_get_contents('/lib/apk/db/installed') : '';
$fromApk = $apkDb !== '' && strpos($apkDb, "\nP:$apkName\n") !== false;
$debName = 'php' . $phpShort . '-common';
$dpkg = @is_readable('/var/lib/dpkg/status') ? (string)@file_get_contents('/var/lib/dpkg/status') : '';
$debAt = $dpkg !== '' ? strpos("\n" . $dpkg, "\nPackage: $debName\n") : false;
$debVersion = ($debAt !== false && preg_match('/\nVersion: (\S+)/', substr("\n" . $dpkg, $debAt + 1, 2000), $m)) ? $m[1] : '';
$fromDistro = !$fromApk && ($debAt !== false || (@is_file('/etc/redhat-release') && strpos(PHP_BINARY, '/usr/bin/') === 0));
$build = $debVersion !== '' ? " (package $debName $debVersion)" : ($fromDistro ? ' (a distribution build)' : '');
if (!skipped('php-security')) {
    $advisories = $phpSecurityBuiltIn;
    $securityFacts = facts($factsBase, 'php-security');
    if ($securityFacts !== null && advisoriesReadable($securityFacts)) {
        $advisories = array_values($securityFacts['advisories']);
    } elseif ($securityFacts !== null) {
        report('NOTE', 'PHP security', "php-security.json in the facts isn't in a form this doctor reads, so it checks against the advisories it was released with",
            "A newer doctor may read it: $home/openemr-doctor.php.");
    }
    debug('PHP security: ' . count($advisories) . ' advisories, ' . ($advisories === $phpSecurityBuiltIn ? "this doctor's own list" : 'from php-security.json'));
    $affected = array();
    $covered = array();
    $newest = $advisories[0];
    foreach ($advisories as $a) {
        if (isset($a['fixed'][$phpShort])) {
            $covered[] = $a;
            if (cmpVersion(PHP_VERSION, $a['fixed'][$phpShort]) < 0) {
                $affected[] = $a;
            }
        }
        $newest = strcmp($a['date'], $newest['date']) > 0 ? $a : $newest;
    }
    $branches = array_keys($newest['fixed']);
    usort($branches, 'cmpVersion');
    $oldest = $branches[0];
    $span = $oldest . ' to ' . end($branches);
    if ($affected !== array()) {
        $w = advisoryWords($affected, $phpShort);
        $fixed = $w['fixed'];
        if ($fromApk) {
            report('FAIL', 'PHP security', PHP_VERSION . " is older than $fixed, PHP's fix for {$w['names']} ({$w['cves']}{$w['impact']})",
                "This PHP is Alpine's $apkName package, as in OpenEMR's Docker images. Update it in place: apk update && apk upgrade \$(apk info -q | grep '^$apkName'), then restart the container; recreating it brings the old PHP back until the image is rebuilt. If apk finds nothing newer, this image's Alpine gets no fix: "
                . (isset($w['top']['notice']) && is_string($w['top']['notice']) ? "move to an image OpenEMR's notice lists as fixed ({$w['top']['notice']})." : "move to an image with PHP $fixed or later."));
        } elseif ($fromDistro) {
            report('WARN', 'PHP security', PHP_VERSION . "$build is numbered below $fixed, PHP's fix for {$w['names']} ({$w['cves']})",
                "Distributions fix PHP without changing its version number. Check your distribution's security notice for {$w['cves']} and that its update is installed.");
        } else {
            report('FAIL', 'PHP security', PHP_VERSION . " is older than $fixed, PHP's fix for {$w['names']} ({$w['cves']}{$w['impact']})",
                "Update PHP to $fixed or later ({$w['top']['source']}). Until then, keep OpenEMR off the public internet.");
        }
    } elseif (cmpVersion($phpShort, $oldest) < 0) {
        report('WARN', 'PHP security', "PHP $phpShort gets no security fixes from PHP; the {$newest['name']} fixes ({$newest['date']}) went to $span only",
            $fromDistro ? 'Check that your distribution still supports this PHP and has a notice for ' . implode(', ', $newest['cves']) . '.' : "Move to a PHP that PHP still supports ($oldest or later).");
    } elseif ($covered !== array()) {
        $parts = array();
        foreach ($covered as $a) {
            $parts[] = $a['name'] . ' (' . implode(', ', $a['cves']) . '; ' . $a['fixed'][$phpShort] . ')';
        }
        report('PASS', 'PHP security', PHP_VERSION . " has PHP's " . (count($parts) === 1 ? 'fix' : 'fixes') . ' for ' . implode(' and ', $parts));
    } else {
        report('NOTE', 'PHP security', PHP_VERSION . " is newer than the branches in the {$newest['name']} advisory ($span)");
    }
}
if (!$web) {
    report('NOTE', 'Which PHP', 'this is the command-line PHP (' . PHP_BINARY . ', settings from ' . (php_ini_loaded_file() ?: 'no php.ini') . ')',
        'The web server can run a different PHP with different settings. To check that one, copy this file into the OpenEMR folder as openemr-doctor-<12 or more random letters and digits>.php, open it as http://localhost/<openemr folder>/<that name> on the server, then delete it.');
}

// Extensions: the release's composer.json requirements, or OpenEMR setup's own four plus
// intl. Forum: intl missing shows the calendar as "Unknown" and stops setup (t/25453,
// t/25214, t/26800); setup.php checks only xml, mysqli, mbstring and openssl.
$why = array(
    'intl' => 'without it the calendar shows "Unknown" and setup can stop with a fatal error',
    'mysqli' => 'OpenEMR can\'t reach its database without it',
    'openssl' => 'encryption, logins and the API need it',
    'mbstring' => 'text handling fails without it',
    'xml' => 'setup and C-CDA need it',
    'sodium' => 'encryption needs it',
    'gd' => 'images and charts need it',
);
// intl is in the fallback from 7.0.0 on: OpenEMR's own code uses it from 7.0.3 (Normalizer in
// library/sanitize.inc.php), and the forum's intl failures are all on 7.0.3 or later. 5.0.2 and
// 6.1.0 use no intl class, and 5.0.2's own Docker image ships without it, so before 7.0.0 it is
// required only if this install's code uses it.
$baseline = array('xml', 'mysqli', 'mbstring', 'openssl');
$intlWhy = '';
if (cmpVersion($current, '7.0.0') >= 0) {
    $baseline[] = 'intl';
    $intlWhy = ' and intl';
} elseif (!isset($skip['php-extensions']) && codeUsesIntl($root)) { // only that check uses it
    $baseline[] = 'intl';
    $intlWhy = ' and intl, which this install\'s code uses';
}
// The release's list, from the facts; else, or when the facts are another release's, the install's
// own composer.json; else setup's own.
if ($f !== null && $f['extensions'] !== array() && !$approx) {
    $wanted = $f['extensions'];
    $wantedFrom = " by $base";
} elseif ($own !== null && $own['extensions'] !== array()) {
    $wanted = $own['extensions'];
    $wantedFrom = " by this install's composer.json";
} elseif ($f !== null && $f['extensions'] !== array()) {
    $wanted = $f['extensions'];
    $wantedFrom = " by $base";
} else {
    $wanted = $baseline;
    $wantedFrom = $f !== null ? " ($base's composer.json lists none, so OpenEMR setup's own four$intlWhy)"
        : ($own !== null ? " (this install's composer.json lists none, so OpenEMR setup's own four$intlWhy)" : " (OpenEMR setup's own four$intlWhy)");
}
$missing = array();
foreach ($wanted as $ext) {
    if (!extension_loaded($ext)) {
        $missing[] = $ext;
    }
}
if (skipped('php-extensions')) {
    // left out
} elseif ($missing === array()) {
    report('PASS', 'PHP extensions', count($wanted) . ' required' . $wantedFrom . ', all loaded');
} else {
    $notes = array();
    foreach ($missing as $ext) {
        if (isset($why[$ext])) {
            $notes[] = "$ext: " . $why[$ext];
        }
    }
    report('FAIL', 'PHP extensions', 'missing: ' . implode(', ', $missing) . ($notes ? ' (' . implode('; ', $notes) . ')' : ''),
        'Install them for the PHP the web server uses (Linux: the php-' . $missing[0] . ' package; XAMPP or Windows: uncomment extension=' . $missing[0] . ' in php.ini), then restart the web server.');
}

// php.ini. Forum: errors shown on the page break it (t/24048). The limits are the ones
// OpenEMR's setup recommends (setup.php: max_input_vars 3000, max_execution_time 60,
// post_max_size 30M, memory_limit 512M).
if (!skipped('php-ini')) {
    $where = $web ? '' : ' (command-line settings; the web server has its own, so check from the browser)';
    $iniLevel = $web ? 'WARN' : 'NOTE';
    if (iniOn('display_errors', $phpDisplayErrors) && ($phpErrorReporting & E_DEPRECATED)) {
        report($iniLevel, 'Error display', 'PHP prints warnings and deprecation notices into pages' . $where,
            'A notice printed into a page can blank it or break the screens that load data in the background. Set display_errors = Off in php.ini (errors still go to the log).');
    }
    $limits = array();
    if ((int)ini_get('max_input_vars') < 3000) {
        $limits[] = 'max_input_vars ' . ini_get('max_input_vars') . ' (3000)';
    }
    if ($web && (int)ini_get('max_execution_time') !== 0 && (int)ini_get('max_execution_time') < 60) {
        $limits[] = 'max_execution_time ' . ini_get('max_execution_time') . ' (60)';
    }
    $post = bytes(ini_get('post_max_size'));
    $memory = bytes(ini_get('memory_limit'));
    if ($post >= 0 && $post < 30 * 1048576) {
        $limits[] = 'post_max_size ' . ini_get('post_max_size') . ' (30M)';
    }
    if ($memory >= 0 && $memory < 512 * 1048576) {
        $limits[] = 'memory_limit ' . ini_get('memory_limit') . ' (512M)';
    }
    if (!iniOn('file_uploads')) {
        $limits[] = 'file_uploads Off (On)';
    }
    if ($limits === array()) {
        report('PASS', 'php.ini', 'meets the limits OpenEMR\'s setup recommends' . $where);
    } else {
        report($iniLevel, 'php.ini', 'below what OpenEMR\'s setup recommends: ' . implode(', ', $limits) . $where,
            'Raise them in php.ini and restart the web server. On shared hosting where you can\'t, setup can stop part-way (t/25023).');
    }
    if ($web) {
        $save = session_save_path() ?: sys_get_temp_dir();
        if (!is_writable($save)) {
            report('FAIL', 'Sessions', "PHP can't write its session folder ($save)", 'Logins fail without it. Make it writable by the web server, or set session.save_path in php.ini.');
        }
    }
}

// ------------------------------------------------------------ the files
// Forum: missing files blank the page or stop it with "Class not found" (t/25717: a
// templates folder lost while patching; t/23699: an upload that didn't finish); a tree
// without its built assets shows an unstyled login whose button does nothing (t/26790).

if (skipped('php-libraries')) {
    // left out
} elseif (!is_file("$root/vendor/autoload.php")) {
    report('FAIL', 'PHP libraries', 'vendor/ is missing: this looks like source code from git, not a release package',
        'Download the release package (it includes vendor/ and the built assets), or run composer install --no-dev and npm ci && npm run build in this folder.');
} elseif ($composerList !== null) {
    $lib = array();
    $mods = array();
    foreach ($composerList as $pkg) {
        if (!is_dir("$root/" . $pkg[0])) {
            if ($pkg[1] === 'openemr-module') {
                $mods[] = basename($pkg[0]);
            } else {
                $lib[] = substr($pkg[0], 7);
            }
        }
    }
    debug('PHP libraries: ' . count($composerList) . " packages in the facts for $label, " . count($lib) . ' missing, ' . count($mods) . ' modules missing');
    if (count($composerList) < 20) {
        report('WARN', 'Release facts', "the Composer list for $label has only " . count($composerList) . ' packages, which looks incomplete', 'Missing packages may go unnoticed. Download the facts again, or pass --facts= a full copy of site/preflight.');
    }
    if ($lib !== array()) {
        report($approx ? 'NOTE' : 'FAIL', 'PHP libraries', count($lib) . ' of the ' . count($composerList) . " packages $label installs with Composer are missing from vendor/: " . listSome($lib),
            $approx ? "Expected if $current$tag no longer uses them. If OpenEMR misbehaves, copy vendor/ again from the same build." : 'The upload or copy of vendor/ didn\'t finish. Copy vendor/ again from the release package.');
    } else {
        report('PASS', 'PHP libraries', 'all ' . count($composerList) . " packages $label installs with Composer are present");
    }
    if ($mods !== array()) {
        report('WARN', 'Modules', 'Composer installs ' . implode(', ', $mods) . ' into interface/modules/custom_modules/, and it isn\'t there',
            'Only matters if you use it. The release package includes it; some builds copy only vendor/ and leave it out.');
    }
}

if (!skipped('page-assets') && $assetList !== null) {
    $gone = array();
    foreach ($assetList as $a) {
        if (!is_file("$root/$a")) {
            $gone[] = $a;
        }
    }
    debug('Page assets: ' . count($assetList) . " in the facts for $label, " . count($gone) . ' missing');
    if ($gone !== array()) {
        report($approx ? 'NOTE' : 'FAIL', 'Page assets', count($gone) . ' of the ' . count($assetList) . ' files every page loads are missing: ' . listSome($gone),
            ($approx ? "$label's list, so a build that renamed them looks the same. " : '') . 'They come from the npm build, not from git. Without them the login page looks broken and its button does nothing. Use the release package, or run npm ci && npm run build.');
    } else {
        report('PASS', 'Page assets', 'the ' . count($assetList) . ' built files every page loads are present');
    }
}

// Files the release package ships from git. Folders nothing runs from are optional. The
// setup and upgrade scripts are removed once setup is done by the Docker image (openemr.sh
// cleanup_setup_scripts) and by careful admins, so their absence is reported, not failed.
$setupScripts = array('admin.php', 'setup.php', 'acl_upgrade.php', 'sql_patch.php', 'sql_upgrade.php', 'ippf_upgrade.php');
$removedScripts = array();
$optionalDirs = array('Documentation', 'contrib', 'tests', 'ci', '.github', '.phpstan', 'docker', 'docs', 'tools', 'swagger', 'ccdaservice', 'scripts', 'webpack', 'sites');
$manifest = $fileFacts !== null ? facts($factsBase, $fileFacts) : null;
if ($fileFacts !== null && $f !== null && $manifest === null) {
    report('NOTE', 'Files', "the file list for $label ($fileFacts.json) isn't in the facts; files not checked");
}
if (!skipped('files') && $manifest !== null) {
    $required = array();
    $optional = 0;
    $total = 0;
    foreach ($manifest['dirs'] as $dir => $names) {
        $top = $dir === '' ? '' : strtok($dir, '/');
        foreach ($names as $name) {
            $path = $dir === '' ? $name : "$dir/$name";
            $total++;
            if (is_file("$root/$path")) { // a folder where a file should be is as good as missing
                continue;
            }
            if ($dir === '' && in_array($name, $setupScripts, true)) {
                $removedScripts[] = $name;
                continue;
            }
            $isOptional = $dir === '' ? !preg_match('/\.php$|^\.htaccess$/', $name) : in_array($top, $optionalDirs, true);
            if ($isOptional) {
                $optional++;
            } else {
                $required[] = $path;
            }
        }
    }
    debug("Files: $total in the facts for $label, " . count($required) . " missing, $optional optional missing, " . count($removedScripts) . ' setup scripts removed');
    if ($total < 1000) {
        report('WARN', 'Release facts', "the file list for $label has only $total files, which looks incomplete", 'Missing files may go unnoticed. Download the facts again, or pass --facts= a full copy of site/preflight.');
    }
    if ($required !== array()) {
        $areas = array();
        foreach ($required as $p) {
            $parts = explode('/', $p);
            $area = count($parts) > 2 ? $parts[0] . '/' . $parts[1] : $parts[0];
            $areas[$area] = isset($areas[$area]) ? $areas[$area] + 1 : 1;
        }
        arsort($areas);
        $byArea = array();
        foreach (array_slice($areas, 0, 5, true) as $area => $n) {
            $byArea[] = "$area ($n)";
        }
        report($approx ? 'NOTE' : 'FAIL', 'Files', count($required) . " files of the $label package are missing, in " . implode(', ', $byArea) . '. For example: ' . listSome($required, 3),
            $approx ? "Expected for files $current$tag removed or moved since $base. If OpenEMR misbehaves, copy the same build again." : 'Copy the package again (or unpack the patch into this folder, not a subfolder). A partial upload or copy is the usual cause.');
    } else {
        report('PASS', 'Files', "all $total files of the $label package that it runs from are present" . ($optional ? " ($optional optional ones, documentation or tooling, are not)" : ''));
    }
    if ($removedScripts !== array()) {
        report('NOTE', 'Setup scripts', 'removed after setup, as the Docker image does: ' . implode(', ', $removedScripts),
            'Fine for a running install. Copy sql_upgrade.php (and sql_patch.php) back from the package before the next upgrade or patch.');
    }
}

// ------------------------------------------------------------ local changes
// A shipped file whose content differs from the release ($label's git blob hashes,
// <release>[-p<N>]-hashes.json) was edited on this server: by a quick fix, a customization,
// or a patch unpacked over the wrong release. Edited files are named, and edited PHP files are
// parsed with this PHP (7.0 and later can): one that doesn't parse blanks every page that
// loads it. Only when the facts are for exactly this release and patch, or every file the
// patch changed would show as edited. sites/ is this install's own and isn't compared.
$hashFacts = ($fileFacts !== null && $base === $current && ($patch === 0 || strpos($fileFacts, "-p$patch-") !== false))
    ? preg_replace('/-files$/', '-hashes', $fileFacts) : null;
// Left out (--skip=local-changes), the hashes aren't even downloaded.
$localOff = $hashFacts !== null && $manifest !== null && skipped('local-changes');
$hashes = !$localOff && $hashFacts !== null && $manifest !== null ? facts($factsBase, $hashFacts) : null;
if (!$localOff && $hashFacts !== null && $manifest !== null && ($hashes === null || !isset($hashes['dirs']))) {
    report('NOTE', 'Local changes', "the file hashes for $label ($hashFacts.json) aren't in the facts; edited files not checked");
}
if ($hashes !== null && isset($hashes['dirs'])) {
    $compared = 0;
    $edited = array();
    $unparsable = array();
    $unparsablePaths = array();
    $unreadable = array();
    foreach ($hashes['dirs'] as $dir => $names) {
        foreach ($names as $name => $sha) {
            $path = $dir === '' ? $name : "$dir/$name";
            $file = "$root/$path";
            if (strpos($path, 'sites/') === 0 || !is_file($file) || is_link($file)) {
                continue;
            }
            if (!is_readable($file)) {
                $unreadable[] = $path; // not compared, and not scanned as an empty file
                continue;
            }
            $compared++;
            $content = (string)file_get_contents($file);
            if (substr(sha1('blob ' . strlen($content) . "\0" . $content), 0, strlen($sha)) === $sha) {
                continue;
            }
            $edited[] = $path;
            // PHP 7.0+ only, behind defined('TOKEN_PARSE'); PHP 5 never reaches it.
            // phpcs:disable PHPCompatibility.FunctionUse.NewFunctionParameters, PHPCompatibility.Constants.NewConstants, PHPCompatibility.Classes.NewClasses
            if (preg_match('/\.(php|inc|phtml)$/i', $path) && defined('TOKEN_PARSE')) {
                try {
                    token_get_all($content, TOKEN_PARSE);
                } catch (ParseError $e) {
                    $unparsable[] = "$path line " . $e->getLine() . ' (' . $e->getMessage() . ')';
                    $unparsablePaths[$path] = true;
                }
            }
            // phpcs:enable
        }
    }
    if ($unparsable !== array()) {
        report('FAIL', 'Local changes', count($unparsable) . ' edited ' . (count($unparsable) === 1 ? "file of OpenEMR's own doesn't" : "files of OpenEMR's own don't") . ' parse with this PHP: ' . listSome($unparsable, 3),
            "Every page that loads one is blank or an error 500. Fix the line, or put back the file from the $label package.");
    }
    // What a parse can't see: a call PHP has removed parses, and fails only when its line runs.
    // scan.php (php-upgrade-catalogue, pinned beside this file) reads the edited files that parse
    // for everything PHP has removed or changed up to this PHP; it never runs them, and a use
    // behind function_exists() and the like isn't counted.
    $scanEdited = array();
    foreach ($edited as $path) {
        if (preg_match('/\.(php|inc|phtml)$/i', $path) && !isset($unparsablePaths[$path])) {
            $scanEdited[] = "$root/$path";
        }
    }
    $scanTool = dirname(__FILE__) . '/scan.php';
    $scanPhp = PHP_MAJOR_VERSION . '.' . PHP_MINOR_VERSION;
    $scanOff = $scanEdited !== array() && skipped('local-changes-php');
    $scanFacts = !$scanOff && $scanEdited !== array() && is_file($scanTool) ? facts($factsBase, 'php-changes') : null;
    if ($scanOff) {
        // left out
    } elseif ($scanEdited !== array() && !is_file($scanTool)) {
        report('NOTE', 'Local changes on this PHP', 'scan skipped: put scan.php beside this file (it comes with this file\'s release) to check the ' . count($scanEdited) . ' edited PHP files for what PHP has removed');
    } elseif ($scanEdited !== array() && $scanFacts === null) {
        report('NOTE', 'Local changes on this PHP', 'the facts have no php-changes.json, so the ' . count($scanEdited) . ' edited PHP files weren\'t checked for what PHP has removed');
    } elseif ($scanFacts !== null) {
        require_once $scanTool;
        $scanMissing = array();
        $scanDefs = upgradeScanFiles(array_values(array_filter(array("$root/vendor", "$root/library", "$root/src"), 'is_dir')), $scanMissing);
        $scanStarted = microtime(true);
        $scanResult = upgradeScanRun($scanFacts, null, $scanPhp, $scanEdited, $scanDefs);
        debug('Local changes on this PHP: ' . count($scanEdited) . ' edited files scanned, ' . count($scanDefs) . ' read for polyfills, '
            . sprintf('%.1fs', microtime(true) - $scanStarted) . ', php-upgrade-catalogue ' . $scanResult['scanner'] . ', facts ' . $scanResult['facts']);
        $scanBad = array();
        $scanKinds = array('wontload' => "won't load", 'fatal' => 'error when it runs', 'silent' => 'works differently');
        foreach ($scanResult['findings'] as $x) {
            if ($x['guard'] === null && isset($scanKinds[$x['kind']])) {
                $scanBad[] = substr($x['file'], strlen($root) + 1) . ' line ' . $x['line'] . ' ' . $x['name'] . ' (' . $scanKinds[$x['kind']] . ')';
            }
        }
        $scanStops = $scanResult['counts']['wontload'] + $scanResult['counts']['fatal'];
        if ($scanStops > 0) {
            report('FAIL', 'Local changes on this PHP', ($scanStops === 1 ? '1 use' : "$scanStops uses") . ' in edited files of OpenEMR\'s own won\'t load or stop with an error on PHP ' . $scanPhp . ': ' . listSome($scanBad, 4),
                "A page that loads one is blank, or fails when it reaches that line. Fix it, or put back the file from the $label package.");
        } elseif ($scanBad !== array()) {
            report('WARN', 'Local changes on this PHP', (count($scanBad) === 1 ? '1 use' : count($scanBad) . ' uses') . ' in edited files work differently on PHP ' . $scanPhp . ': ' . listSome($scanBad, 4));
        } else {
            report('PASS', 'Local changes on this PHP', (count($scanEdited) === 1 ? 'the edited PHP file uses' : 'the ' . count($scanEdited) . ' edited PHP files use') . ' nothing PHP ' . $scanPhp . ' has removed');
        }
        $scanDeprecated = (array)$scanResult['deprecated_by_name'];
        if ($scanDeprecated !== array()) {
            $scanTop = array();
            foreach (array_slice($scanDeprecated, 0, 6, true) as $scanName => $scanN) {
                $scanTop[] = "$scanName ($scanN)";
            }
            $scanD = $scanResult['counts']['deprecated'];
            report('NOTE', 'Local changes on this PHP', ($scanD === 1 ? '1 use' : "$scanD uses") . ' deprecated on PHP ' . $scanPhp . ' still ' . ($scanD === 1 ? 'works' : 'work') . ', with a warning: ' . implode(', ', $scanTop) . (count($scanDeprecated) > 6 ? ', ...' : ''));
        }
        if ($scanResult['beyond_facts']) {
            report('NOTE', 'Local changes on this PHP', 'the PHP changes known cover PHP up to ' . $scanResult['facts_cover'] . ', so what PHP ' . $scanPhp . ' itself changes isn\'t checked yet');
        }
    }
    if ($unreadable !== array()) {
        $who = function_exists('posix_geteuid') && function_exists('posix_getpwuid') ? posix_getpwuid(posix_geteuid()) : null;
        $who = is_array($who) ? $who['name'] : "this PHP's user";
        report('WARN', 'Local changes', count($unreadable) . " of OpenEMR's own files can't be read by $who, so they weren't compared: " . listSome($unreadable, 5),
            'If the web server runs as this user, every page that loads one fails. Make OpenEMR\'s files readable by the web server\'s user.');
    }
    // version.php is one of them, and the doctor stops earlier without it, so $compared > 0.
    if ($edited === array()) {
        report('PASS', 'Local changes', "all $compared files of the $label package that are here are as released");
    } else {
        report('NOTE', 'Local changes', count($edited) . " of OpenEMR's own files differ from $label as released: " . listSome($edited, 8),
            'Edited here, or copied from another release. If a screen broke after one was changed, compare it with the package\'s copy.');
    }
}

// ------------------------------------------------------------ the site

if (!is_file("$root/sites/$site/sqlconf.php")) {
    $sites = array();
    foreach (glob("$root/sites/*/sqlconf.php") ?: array() as $s) {
        $sites[] = basename(dirname($s));
    }
    report('FAIL', 'Site', "there is no sites/$site/sqlconf.php" . ($sites ? '; sites here: ' . implode(', ', $sites) : ''),
        $sites ? 'Run the doctor with --site=' . $sites[0] . ' (or ?site=' . $sites[0] . ' in the browser).' : 'The sites folder is missing or incomplete. Copy it from the package (new install) or the old server (move).');
    summary($results);
}
try {
    $db = readConfig("$root/sites/$site/sqlconf.php", array('host', 'port', 'login', 'pass', 'dbase', 'config'));
} catch (ParseError $e) {
    // The line only: PHP's message quotes the code there, which can be part of the password.
    report('FAIL', 'Setup', "sites/$site/sqlconf.php doesn't parse (a syntax error on line " . $e->getLine() . ')',
        'OpenEMR reads it on every page, so every page is blank or an error 500. Fix that line, or put back the file from a backup.');
    summary($results);
}
if (!isset($db['config']) || (int)$db['config'] !== 1) {
    if (!is_file("$root/setup.php")) {
        report('FAIL', 'Setup', "sites/$site/sqlconf.php says setup hasn't finished, and setup.php is missing", 'Copy setup.php from the package, then open it in the browser.');
    } else {
        report('NOTE', 'Setup', "sites/$site/sqlconf.php says setup hasn't finished (\$config is not 1)",
            'Open setup.php in the browser to finish it. If setup stopped part-way, the PHP error log says why; the checks above cover the usual causes.');
    }
}

// Permissions. Forum: unreadable keys and certificates (t/24855).
$docs = "$root/sites/$site/documents";
if (skipped('documents-folder')) {
    // left out
} elseif (!is_dir($docs)) {
    report('FAIL', 'Documents folder', "sites/$site/documents is missing", 'It holds uploaded documents, the encryption keys and certificates. Copy it from the package (new install) or the old server (move).');
} elseif ($web) {
    $ro = array();
    foreach (array('', '/logs_and_misc/methods', '/certificates', '/temp') as $sub) {
        if (is_dir($docs . $sub) && !is_writable($docs . $sub)) {
            $ro[] = "documents$sub";
        }
    }
    if ($ro !== array()) {
        report('FAIL', 'Documents folder', 'the web server can\'t write ' . implode(', ', $ro), 'Give the web server\'s user ownership of sites/' . $site . '/documents (Linux: chown -R www-data or apache).');
    } else {
        report('PASS', 'Documents folder', 'the web server can write it');
    }
} else {
    $owner = function_exists('posix_getpwuid') ? posix_getpwuid(fileowner($docs)) : false;
    $name = $owner ? $owner['name'] : (string)fileowner($docs);
    $perms = substr(sprintf('%o', fileperms($docs)), -3);
    if ($name === 'root' && !(fileperms($docs) & 0x0012)) {
        report('WARN', 'Documents folder', "sites/$site/documents belongs to root ($perms)", 'The web server usually runs as www-data, apache or nginx and then can\'t save uploads, keys or certificates. Give its user ownership.');
    } else {
        report('NOTE', 'Documents folder', "owned by $name ($perms); the browser check confirms what the web server can write");
    }
}

if (!isset($db['config']) || (int)$db['config'] !== 1) {
    summary($results);
}

// ------------------------------------------------------------ the database

if (!class_exists('mysqli')) {
    report('FAIL', 'Database', 'can\'t check: the mysqli extension is missing (see PHP extensions)');
    summary($results);
}
if (function_exists('mysqli_report')) {
    mysqli_report(MYSQLI_REPORT_OFF);
}
$host = isset($db['host']) ? (string)$db['host'] : 'localhost';
$port = isset($db['port']) ? (int)$db['port'] : 3306;

// MySQL over SSL, as OpenEMR connects: the server's CA certificate at
// documents/certificates/mysql-ca turns it on, and mysql-cert with mysql-key adds a client
// certificate. PHP then checks the server's certificate against the CA and the host in
// sqlconf.php, and either failure is reported only as error 2002 (forum: t/27148).
$ca = "$docs/certificates/mysql-ca";
$clientCert = "$docs/certificates/mysql-cert";
$clientKey = "$docs/certificates/mysql-key";
$ssl = is_file($ca);
$hasCert = is_file($clientCert);
$hasKey = is_file($clientKey);
if ($ssl) {
    $pem = array('mysql-ca' => array($ca, 'CERTIFICATE'));
    if ($hasCert) {
        $pem['mysql-cert'] = array($clientCert, 'CERTIFICATE');
    }
    if ($hasKey) {
        $pem['mysql-key'] = array($clientKey, 'PRIVATE KEY');
    }
    foreach ($pem as $name => $file) {
        $text = is_readable($file[0]) ? (string)@file_get_contents($file[0]) : null;
        if ($text === null) {
            report('FAIL', 'Database SSL', "documents/certificates/$name can't be read by " . ($web ? 'the web server' : 'this user'),
                'OpenEMR reads it on every page. Give the web server read access to it.');
        } elseif (strpos($text, '-----BEGIN') === false || strpos($text, $file[1] . '-----') === false) {
            report('FAIL', 'Database SSL', "documents/certificates/$name isn't a PEM " . strtolower($file[1]),
                'It must be the text form, starting with -----BEGIN ' . $file[1] . '-----, not a .der or .p12 file.');
        }
    }
    if ($hasCert !== $hasKey) {
        $one = $hasCert ? 'mysql-cert' : 'mysql-key';
        $other = $hasCert ? 'mysql-key' : 'mysql-cert';
        if (cmpVersion($current, '8.1.0') >= 0) {
            report('FAIL', 'Database SSL', "documents/certificates has $one without $other",
                "OpenEMR 8.1 and later refuse to connect (\"You need both or neither\"). Add $other, or remove $one to connect with the CA alone.");
        } else {
            report('WARN', 'Database SSL', "documents/certificates has $one without $other",
                'This OpenEMR ignores a client certificate without its key and connects with the CA alone.');
        }
    }
} elseif ($hasCert || $hasKey) {
    report('WARN', 'Database SSL', 'documents/certificates has ' . ($hasCert ? 'mysql-cert' : 'mysql-key') . ' but no mysql-ca',
        'OpenEMR uses SSL only when mysql-ca is there, so it connects without SSL and ignores the client certificate.');
}

$mysqli = mysqli_init();
$mysqli->options(MYSQLI_OPT_CONNECT_TIMEOUT, 10);
$flags = 0;
if ($ssl) {
    $withClient = $hasCert && $hasKey;
    $mysqli->ssl_set($withClient ? $clientKey : null, $withClient ? $clientCert : null, $ca, null, null);
    $flags = MYSQLI_CLIENT_SSL;
}
$ok = false;
try {
    $ok = @$mysqli->real_connect($host, isset($db['login']) ? $db['login'] : '', isset($db['pass']) ? $db['pass'] : '', isset($db['dbase']) ? $db['dbase'] : '', $port, null, $flags);
} catch (Exception $e) {
    $ok = false;
}
if (!$ok) {
    // Forum: the database stopped or never started (t/23921, t/26432); shared hosting
    // names (t/25245); SSL (t/27148).
    $errno = mysqli_connect_errno();
    $message = (string)mysqli_connect_error();
    if ($ssl && $errno === 2002 && stripos($message, 'SSL') !== false) {
        report('FAIL', 'Database', "can't connect with sites/$site/sqlconf.php over SSL (error 2002, \"$message\")", sslDiagnosis($host, $port, $ca));
        summary($results);
    }
    $hints = array(
        1045 => 'The user name or password in sites/' . $site . '/sqlconf.php is wrong, or that user may not connect from this server'
            . ($ssl ? ', or needs a client certificate (REQUIRE X509) that documents/certificates doesn\'t hold.' : ', or must connect with SSL (REQUIRE SSL), which OpenEMR uses only when documents/certificates/mysql-ca holds the server\'s CA certificate.'),
        1044 => 'The user in sqlconf.php has no access to database ' . (isset($db['dbase']) ? $db['dbase'] : '') . '.',
        1049 => 'Database ' . (isset($db['dbase']) ? $db['dbase'] : '') . ' doesn\'t exist on that server. On shared hosting the real name usually has your account name in front.',
        2002 => "Nothing answers at $host:$port. Is the database server running? (XAMPP: start MySQL in the control panel.) With 'localhost' PHP uses a socket file; try 127.0.0.1 instead.",
        2003 => "Nothing answers at $host:$port. Is the database server running, and on that port?",
        2005 => "The database host name '$host' doesn't resolve from this server.",
        2054 => 'The database asks for a login method this PHP doesn\'t support (MySQL 8 caching_sha2_password with an old PHP).',
        3159 => 'The database only accepts encrypted connections, and OpenEMR uses SSL only when sites/' . $site . '/documents/certificates/mysql-ca holds the server\'s CA certificate. Put it there.',
    );
    report('FAIL', 'Database', "can't connect with sites/$site/sqlconf.php (error $errno)",
        isset($hints[$errno]) ? $hints[$errno] : 'Check host, port, user and database in sqlconf.php against the database server.');
    summary($results);
}
if ($ssl) {
    $cipher = $mysqli->query("SHOW STATUS LIKE 'Ssl_cipher'");
    $row = $cipher ? $cipher->fetch_row() : null;
    if (is_array($row) && isset($row[1]) && $row[1] !== '') {
        report('PASS', 'Database', "connected to $host:$port over SSL ($row[1])");
    } else {
        report('WARN', 'Database', "connected to $host:$port, but not over SSL although documents/certificates/mysql-ca is there",
            'The server may not support SSL. OpenEMR\'s traffic to it is not encrypted.');
    }
} else {
    report('PASS', 'Database', "connected to $host:$port");
}

// A query a check needs: its rows, or, when the database refuses it, that check's FAIL with the
// database's own error and null. mysqli_report is off, so a refusal would otherwise read as an
// empty table and pass.
$q = function ($sql, $check, $fix = '') use ($mysqli) {
    $res = $mysqli->query($sql);
    if (!($res instanceof mysqli_result)) {
        report('FAIL', $check, 'the database refused the query this check needs (error ' . $mysqli->errno . ': ' . $mysqli->error . ')',
            $fix !== '' ? $fix : 'A table is missing or damaged, or the user in sqlconf.php lacks rights on it.');
        return null;
    }
    $rows = array();
    while (($row = $res->fetch_assoc())) {
        $rows[] = $row;
    }
    return $rows;
};
$rows = $q('SELECT VERSION() AS v', 'Database server');
$server = $rows ? (string)$rows[0]['v'] : '';
$flavor = stripos($server, 'mariadb') !== false ? 'mariadb' : 'mysql';
$label = $flavor === 'mariadb' ? 'MariaDB' : 'MySQL';
$short = preg_match('/^(\d+)\.(\d+)/', $server, $m) ? "$m[1].$m[2]" : $server;
if (!skipped('database-server') && $f !== null && $server !== '') {
    $tested = array();
    foreach ($f['ci_databases'] as $pair) {
        if ($pair[0] === $flavor) {
            $tested[] = $pair[1];
        }
    }
    usort($tested, 'cmpVersion');
    if (in_array($short, $tested, true)) {
        report('PASS', 'Database server', "$label $short, which CI tested OpenEMR $base with");
    } elseif ($tested !== array() && cmpVersion($short, $tested[0]) < 0) {
        report('WARN', 'Database server', "$label $short is older than any $label CI tested OpenEMR $base with (" . implode(', ', $tested) . ')', 'Not tested is not the same as broken, but upgrade the database server if anything fails.');
    } else {
        report('NOTE', 'Database server', "$label $short (CI tested OpenEMR $base with $label " . ($tested ? implode(', ', $tested) : 'none') . ')');
    }
}

// Code and database versions. Forum: a patch's files copied without sql_patch.php, or an
// upgrade's without sql_upgrade.php (t/26790, t/26133, t/24492).
$ver = skipped('database-version') ? null : $q('SELECT * FROM version LIMIT 1', 'Database version', 'Setup didn\'t finish, or this database isn\'t OpenEMR\'s.');
if ($ver === null) {
    // left out, or refused (said by $q)
} elseif ($ver === array()) {
    report('FAIL', 'Database version', 'the version table is empty', 'Setup didn\'t finish, or this database isn\'t OpenEMR\'s.');
} else {
    $v = $ver[0];
    $dbPatch = isset($v['v_realpatch']) ? (int)$v['v_realpatch'] : 0;
    if (!isset($code['v_database'])) {
        report('NOTE', 'Database version', "the database is at {$v['v_major']}.{$v['v_minor']}.{$v['v_patch']} (database version {$v['v_database']}); the code's version is unknown (see Version)");
    } elseif ((int)$v['v_database'] < (int)$code['v_database']) {
        report('FAIL', 'Database version', "the code is $current (database version {$code['v_database']}) but the database is at {$v['v_major']}.{$v['v_minor']}.{$v['v_patch']} (database version {$v['v_database']})",
            'Open sql_upgrade.php in the browser and upgrade from the version the database is at' . (is_file("$root/sql_upgrade.php") ? '.' : ' (copy it from the package first; it was removed).'));
    } elseif ((int)$v['v_database'] > (int)$code['v_database']) {
        report('FAIL', 'Database version', "the database (version {$v['v_database']}) is newer than the code ({$code['v_database']})", 'The code was rolled back without the database. Put matching code and database back.');
    } elseif ($patch > $dbPatch && patchSqlHasStatements($root) === false) {
        // The same database version, and the code at a later patch. A patch's database changes are
        // in sql/patch.sql, which sql_patch.php applies. Each patch's patch.sql holds every patch of
        // its release so far (a release's own is comments only), so one with nothing but comments
        // means no patch up to this one changed the database (7.0.3 patches 1 to 3, 8.0.0 patches
        // 1 to 3): only the patch number is behind. That is what the doctor relies on, not the
        // database version: patches don't always raise it (7.0.1 patch 1 and 7.0.2 patches 1 to 3
        // added columns and tables at the same v_database). With statements in patch.sql they may
        // not have run (each is conditional, and that can't be read from here), so that is a FAIL.
        report('NOTE', 'Database version', "patch $patch's files are in place and the database says patch $dbPatch, but sql/patch.sql changes nothing in the database, so only the patch number is behind",
            'Nothing is missing from the tables. sql_patch.php, if it is still here, would record the patch number and add defaults for any settings the patch added.');
    } elseif ($patch > $dbPatch) {
        report('FAIL', 'Database version', "patch $patch's files are in place but the database is at patch $dbPatch", 'Open sql_patch.php in the browser to finish the patch' . (is_file("$root/sql_patch.php") ? '.' : ' (copy it from the patch first; it was removed).'));
    } elseif ($patch < $dbPatch) {
        // sql_patch.php records the patch number version.php says, so a database ahead of the code
        // had the later patch applied, and the code went back to an earlier one since.
        report('WARN', 'Database version', "the database is at patch $dbPatch but the code is at patch $patch (both at database version {$v['v_database']})",
            "The code was put back to an earlier patch, or restored from an older copy, while the database kept the later one. Unpack patch $dbPatch into this folder again; its fixes are missing until then.");
    } else {
        report('PASS', 'Database version', "the database matches the code (database version {$v['v_database']}" . ($patch ? ", patch $patch" : '') . ')');
    }
}

$globals = array();
foreach ($q("SELECT gl_name, gl_value FROM globals WHERE gl_index = 0 AND gl_name IN ('css_header', 'user_debug', 'user_php_debug', 'rest_api', 'rest_fhir_api', 'rest_portal_api')", 'Settings') ?: array() as $g) {
    $globals[$g['gl_name']] = (string)$g['gl_value'];
}
// The theme stylesheet the login page and every screen load (public/themes, built by npm).
if (!skipped('theme') && isset($globals['css_header']) && $globals['css_header'] !== '') {
    $css = basename($globals['css_header']);
    if (!is_file("$root/public/themes/$css")) {
        report('FAIL', 'Theme', "the chosen theme public/themes/$css is missing" . (glob("$root/public/themes/*.css") ? '' : ', and public/themes has no stylesheets at all'),
            'Screens show without styling. The themes come from the npm build; use the release package or run npm ci && npm run build.');
    } else {
        report('PASS', 'Theme', "public/themes/$css is present");
    }
}
// Showing PHP errors on pages. Up to 8.0.x the setting was user_debug (above 1); from
// 8.2.0, user_php_debug (interface/globals.php). Forum: t/27005.
$phpDebugKey = ($f !== null && isset($f['settings']['user_php_debug'])) ? 'user_php_debug' : 'user_debug';
$phpDebugOn = $phpDebugKey === 'user_php_debug' ? (int)(isset($globals['user_php_debug']) ? $globals['user_php_debug'] : 0) > 0
    : (int)(isset($globals['user_debug']) ? $globals['user_debug'] : 0) > 1;
if ($phpDebugOn && !skipped('error-display')) {
    $loc = ($f !== null && isset($f['settings'][$phpDebugKey])) ? ' (Administration > Config > ' . $f['settings'][$phpDebugKey]['section'] . ' > ' . $f['settings'][$phpDebugKey]['label'] . ')' : '';
    report('WARN', 'Error display', "OpenEMR's $phpDebugKey setting is on, so PHP errors are shown on pages$loc", 'A message printed into a page can blank it. Turn it off once you have read the error.');
}

// Modules. An active module whose files are missing can stop OpenEMR starting; from 7.0.4
// OpenEMR switches such a module off (src/Core/ModulesApplication.php). Forum: t/25702.
$lost = array();
foreach (skipped('modules') ? array() : ($q('SELECT mod_directory, type FROM modules WHERE mod_active = 1', 'Modules') ?: array()) as $mod) {
    $dir = (int)$mod['type'] === 1 ? "$root/interface/modules/zend_modules/module/" . $mod['mod_directory']
        : "$root/interface/modules/custom_modules/" . $mod['mod_directory'] . '/openemr.bootstrap.php';
    if (!file_exists($dir)) {
        $lost[] = $mod['mod_directory'];
    }
}
if ($lost !== array()) {
    report(cmpVersion($current, '7.0.4') < 0 ? 'FAIL' : 'WARN', 'Modules', 'switched on, but their files are missing: ' . implode(', ', $lost),
        cmpVersion($current, '7.0.4') < 0 ? 'This can stop OpenEMR from starting. Copy the module back, or set mod_active = 0 for it in the modules table.'
            : 'OpenEMR switches them off at the next start. Copy them back if you use them.');
}

// Encryption keys. OpenEMR keeps one set in the keys table and one in
// documents/logs_and_misc/methods, encrypted with the first. A missing drive key is
// silently replaced by a new one, after which existing encrypted data can't be read
// (src/Common/Crypto/CryptoGen.php collectDriveKey). Forum: "Decryption failed HMAC"
// (t/25795), keys after an upgrade or move (t/27005).
if (!skipped('encryption-keys') && ($keyRows = $q('SELECT name, value FROM `keys`', 'Encryption keys')) !== null) {
    $versions = array('one', 'two', 'three', 'four', 'five', 'six', 'seven');
    $dbKeys = array();
    foreach ($keyRows as $k) {
        if (preg_match('/^(' . implode('|', $versions) . ')[ab]$/', $k['name'])) {
            $dbKeys[$k['name']] = base64_decode((string)$k['value']);
        }
    }
    $methods = "$docs/logs_and_misc/methods";
    $driveKeys = array();
    foreach (glob("$methods/*") ?: array() as $file) {
        if (preg_match('/^(' . implode('|', $versions) . ')[ab]$/', basename($file))) {
            $driveKeys[basename($file)] = $file;
        }
    }
    if ($dbKeys === array() && $driveKeys === array()) {
        report('PASS', 'Encryption keys', 'none yet; OpenEMR creates them the first time it encrypts something');
    } elseif ($driveKeys === array()) {
        report('FAIL', 'Encryption keys', 'the database has encryption keys (' . implode(', ', array_keys($dbKeys)) . ") but sites/$site/documents/logs_and_misc/methods has none",
            'If this install was copied or moved, copy that folder from the old server before anyone uses it: OpenEMR will otherwise make new keys, and everything already encrypted becomes unreadable.');
    } elseif ($dbKeys === array()) {
        report('FAIL', 'Encryption keys', 'the keys folder has keys (' . implode(', ', array_keys($driveKeys)) . ') but the database has none',
            'The database comes from a different install than the documents folder, or its keys table wasn\'t restored. Restore the matching pair.');
    } else {
        $bad = array();
        $unpaired = array();
        $unreadable = array();
        foreach ($driveKeys as $name => $file) {
            if (!is_readable($file)) {
                $unreadable[] = $name;
                continue;
            }
            $content = (string)file_get_contents($file);
            $prefix = substr($content, 0, 3);
            if (!preg_match('/^\d{3}$/', $prefix) || (int)$prefix <= 4) {
                continue; // versions 1-4 store the key on its own, with nothing to match
            }
            // OpenEMR decrypts it with the database's two keys of that version: a, the key, and b,
            // its HMAC key (CryptoGen coreDecrypt). b is checked against the file; a must be there.
            $keyVersion = (int)$prefix <= count($versions) ? $versions[(int)$prefix - 1] : '';
            if ($keyVersion === '' || !isset($dbKeys[$keyVersion . 'a'], $dbKeys[$keyVersion . 'b'])) {
                $unpaired[] = $name;
                continue;
            }
            $raw = base64_decode(substr($content, 3), true);
            $ok = $raw !== false && strlen($raw) > 64 && hash_hmac('sha384', substr($raw, 48), $dbKeys[$keyVersion . 'b'], true) === substr($raw, 0, 48);
            if (!$ok) {
                $bad[] = $name;
            }
        }
        if ($unreadable !== array()) {
            report($web ? 'FAIL' : 'NOTE', 'Encryption keys', ($web ? 'the web server' : 'this user') . ' can\'t read ' . implode(', ', $unreadable) . ' in the keys folder',
                $web ? 'Give the web server\'s user ownership of sites/' . $site . '/documents.' : 'Run the doctor as root or as the web server\'s user to check them.');
        } elseif ($bad !== array() || $unpaired !== array()) {
            report('FAIL', 'Encryption keys', 'the keys folder and the database don\'t belong together: ' . implode(', ', array_merge($bad, $unpaired)) . ' can\'t be unlocked with the database\'s keys',
                'The database and sites/' . $site . '/documents come from different installs or different backups. Restore a matching pair; encrypted data can\'t be read until then.');
        } else {
            report('PASS', 'Encryption keys', count($driveKeys) . ' in the keys folder, and they match the database\'s keys');
        }
    }
}

// Documents whose files aren't where OpenEMR looks: under this site's documents folder,
// by the last path_depth parts of the stored URL (library/classes/Document.class.php
// get_filesystem_filepath). Forum: documents listed but not opening after a move (t/26815).
$onDisk = "FROM documents WHERE storagemethod = 0 AND type = 'file_url' AND deleted = 0";
if (!skipped('documents') && ($count = $q("SELECT COUNT(*) AS n $onDisk", 'Documents')) !== null) {
    $total = (int)$count[0]['n'];
    $couch = $q('SELECT COUNT(*) AS n FROM documents WHERE storagemethod = 1 AND deleted = 0', 'Documents');
    $absent = array();
    $checked = 0;
    $deadline = microtime(true) + 20;
    $res = $mysqli->query("SELECT id, url, path_depth $onDisk ORDER BY id", MYSQLI_USE_RESULT);
    while ($res && ($d = $res->fetch_assoc())) {
        $parts = explode('/', preg_replace('|^(.*)://|', '', (string)$d['url']));
        $file = array_pop($parts);
        $sub = array_slice($parts, -max(1, (int)$d['path_depth']));
        if (!file_exists($docs . '/' . implode('/', $sub) . '/' . $file)) {
            $absent[] = $d['id'];
        }
        $checked++;
        if (microtime(true) > $deadline) {
            break;
        }
    }
    if ($res) {
        $res->free();
    }
    if ($total > 0 && !$res) {
        report('FAIL', 'Documents', 'the database refused the query this check needs (error ' . $mysqli->errno . ': ' . $mysqli->error . ')',
            'A table is missing or damaged, or the user in sqlconf.php lacks rights on it.');
    } elseif ($total === 0) {
        report('PASS', 'Documents', 'no documents stored on disk yet');
    } elseif ($absent !== array()) {
        report('WARN', 'Documents', count($absent) . " of $checked documents checked have no file in sites/$site/documents (document ids " . listSome($absent, 5) . ')',
            'After a move, copy sites/' . $site . '/documents from the old server. The list shows them, but they open blank.');
    } elseif ($checked < $total) {
        report('NOTE', 'Documents', "the first $checked of $total documents have their file; it stopped after 20 seconds, so the other " . ($total - $checked) . ' weren\'t checked');
    } else {
        report('PASS', 'Documents', "all $checked documents checked have their file");
    }
    if ($couch !== null && (int)$couch[0]['n'] > 0) {
        report('NOTE', 'Documents', $couch[0]['n'] . ' documents are stored in CouchDB; not checked');
    }
}

// API certificates, only when an API is on. Forum: "Unable to read key from file" (t/24855).
$apiOn = (isset($globals['rest_api']) && $globals['rest_api'] === '1') || (isset($globals['rest_fhir_api']) && $globals['rest_fhir_api'] === '1')
    || (isset($globals['rest_portal_api']) && $globals['rest_portal_api'] === '1');
if ($apiOn && !skipped('api-keys')) {
    $certs = array();
    foreach (array('oaprivate.key', 'oapublic.key') as $k) {
        if (!is_file("$docs/certificates/$k") || ($web && !is_readable("$docs/certificates/$k"))) {
            $certs[] = $k;
        }
    }
    if ($certs !== array()) {
        report('WARN', 'API keys', 'an API is on but documents/certificates/' . implode(' and ', $certs) . ($web ? ' is missing or unreadable' : ' is missing'),
            'API logins fail with "Unable to read key from file". After a move, copy the certificates folder; otherwise OpenEMR recreates them when the web server can write the folder.');
    } else {
        report('PASS', 'API keys', 'the API\'s key pair is present');
    }
}

summary($results);

function summary($results)
{
    global $skip, $skipped;
    // A check left out that the doctor didn't reach (it stopped early, or the check runs only when
    // there is something to check) says so too, so every name given to --skip is in the report.
    foreach (array_keys($skip) as $name) {
        if (!in_array($name, $skipped, true)) {
            skipped($name);
        }
    }
    $fails = count(array_keys($results, 'FAIL', true));
    $warns = count(array_keys($results, 'WARN', true));
    debug(count($results) . ' results: ' . count(array_keys($results, 'PASS', true)) . ' pass, ' . count(array_keys($results, 'NOTE', true)) . " note, $warns warn, $fails fail");
    echo "\n" . ($fails ? "Fix the $fails failed check(s) first." : 'No blocking problems found.') . ($warns ? " $warns warning(s) to read." : '')
        . ($skipped ? ' ' . count($skipped) . ' check(s) left out with --skip, so not checked: ' . implode(', ', $skipped) . '.' : '') . "\n";
    $log = (string)ini_get('error_log');
    echo "A blank page or an error 500 always leaves a line in the PHP error log"
        . ($log !== '' ? " (this PHP writes to $log)" : ' (often the web server\'s error log: /var/log/apache2/error.log, /var/log/httpd/error_log, C:\\xampp\\apache\\logs\\error.log)')
        . ". Reload the broken page, then read the newest lines.\n";
    if (PHP_SAPI !== 'cli') {
        echo "\nDelete " . basename(__FILE__) . " from the OpenEMR folder now.\n";
        exit;
    }
    exit($fails ? 1 : 0);
}
