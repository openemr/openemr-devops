<?php

// unlocks the admin user and changes that password from the default of 'pass'
// to a user-supplied password

$newPassword = $argv[1];
$_GET['site'] = 'default';
$ignoreAuth=1;
require_once("/var/www/localhost/htdocs/openemr/interface/globals.php");

$currentPassword = "pass";

sqlStatement("UPDATE `users` SET `active` = 1 WHERE `id` = 1");

if (file_exists($GLOBALS['srcdir'] . "/authentication/password_change.php")) {
    // Older code (OpenEMR 5.0.2 and lower)
    $catchErrorMessage = "";
    require_once($GLOBALS['srcdir'] . "/authentication/password_change.php");
    update_password(1, 1, $currentPassword, $newPassword, $catchErrorMessage);
    if (!empty($catchErrorMessage)) {
        echo "ERROR: " . $catchErrorMessage . "\n";
    }
} else {
    // Newer code (OpenEMR 5.0.3 and higher)
    $unlockUpdatePassword = new OpenEMR\Common\Auth\AuthUtils();
    $unlockUpdatePassword->updatePassword(1, 1, $currentPassword, $newPassword);
    if (!empty($unlockUpdatePassword->getErrorMessage())) {
        echo "ERROR: " . $unlockUpdatePassword->getErrorMessage() . "\n";
    }
}
