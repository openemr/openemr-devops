<?php
require_once('/var/www/localhost/htdocs/openemr/vendor/autoload.php');
if (file_exists('/var/www/localhost/htdocs/openemr/library/authentication/password_hashing.php')) {
    // This is to support older code (OpenEMR 5.0.2 and lower)
    require_once('/var/www/localhost/htdocs/openemr/library/authentication/password_hashing.php');
}
// Set up default configuration settings
$installSettings = array();
$installSettings['iuser']                    = 'admin';
$installSettings['iuname']                   = 'Administrator';
$installSettings['iuserpass']                = 'pass';
$installSettings['igroup']                   = 'Default';
$installSettings['server']                   = 'localhost'; // mysql server
$installSettings['loginhost']                = 'localhost'; // php/apache server
$installSettings['port']                     = '3306';
$installSettings['root']                     = 'root';
$installSettings['rootpass']                 = 'BLANK';
$installSettings['login']                    = 'openemr';
$installSettings['pass']                     = 'openemr';
$installSettings['dbname']                   = 'openemr';
$installSettings['collate']                  = 'utf8mb4_general_ci';
$installSettings['site']                     = 'default';
$installSettings['source_site_id']           = 'BLANK';
$installSettings['clone_database']           = 'BLANK';
$installSettings['no_root_db_access']        = 'BLANK';
$installSettings['development_translations'] = 'BLANK';
// Collect parameters(if exist) for installation configuration settings
for ($i=1; $i < count($argv); $i++) {
    if ($argv[$i] == '-f' && isset($argv[$i+1])) {
        // Handle case where a single string contains all parameters
        $configString = $argv[$i+1];
        $configPairs = preg_split('/\s+/', trim($configString));
        foreach ($configPairs as $pair) {
            if (strpos($pair, '=') !== false) {
                list($index, $value) = explode('=', $pair, 2);
                $installSettings[$index] = $value;
            }
        }
        // Skip the next argument since we already processed it
        $i++;
    } else {
        // Handle standard key=value parameters
        $indexandvalue = explode("=", $argv[$i]);
        $index = $indexandvalue[0];
        $value = $indexandvalue[1] ?? '';
        $installSettings[$index] = $value;
    }
}
// Convert BLANK settings to empty
$tempInstallSettings = array();
foreach ($installSettings as $setting => $value) {
    if ($value == "BLANK") {
        $value = '';
    }
    $tempInstallSettings[$setting] = $value;
}
$installSettings = $tempInstallSettings;
// Install and configure OpenEMR using the Installer class
$installer = new Installer($installSettings);
if (! $installer->quick_install()) {
  // Failed, report error
    throw new Exception("ERROR: " . $installer->error_message . "\n");
} else {
  // Successful
    echo $installer->debug_message . "\n";
}
