# OpenEMR-Cmd Documentation

## Overview

OpenEMR-Cmd is similar to devtools, it helps developers to manage and troubleshoot openemr outside the docker,see more detail [here](https://github.com/openemr/openemr/blob/master/CONTRIBUTING.md).
qh(quick help) is get the help from openemr-cmd -h quickly.

## Implementation

1. Copy the script to local linux environment, create the bin directory if it does not exist. (May have to use ~/.local/bin for newer versions of Ubuntu in steps 1 and 2 so the script is found in $PATH.)

```
mkdir ~/bin
curl -L https://raw.githubusercontent.com/openemr/openemr-devops/master/utilities/openemr-cmd/openemr-cmd > ~/bin/openemr-cmd
curl -L https://raw.githubusercontent.com/openemr/openemr-devops/master/utilities/openemr-cmd/qh > ~/bin/qh
```

2. Apply executable permissions to the script.

```
chmod +x ~/bin/openemr-cmd
chmod +x ~/bin/qh
```

3. Test the installation.

```
# openemr-cmd
Usage: openemr-cmd COMMAND [ARGS]
Commands:
  --help                       Show the commands usage
  --version                    Show the openemr-cmd command version


# qh
To search the keyword from openemr-cmd -h output quickly
Usage: qh keyword
  e.g. qh ssl
# qh ssl
ssl-management:
  ss, sql-ssl                        Use testing sql ssl CA cert
  sso, sql-ssl-off                   Remove testing sql ssl CA cert
  ssc, sql-ssl-client                Use testing sql ssl client certs
  ssco, sql-ssl-client-off           Remove testing sql ssl client certs
  css, couchdb-ssl                   Use testing couchdb ssl CA cert
  cso, couchdb-ssl-off               Remove testing couchdb ssl CA cert
  csc, couchdb-ssl-client            Use testing couchdb ssl client certs
  csco, couchdb-ssl-client-off       Remove testing couchdb ssl client certs
  lss, ldap-ssl                      Use testing ldap ssl CA cert
  lso, ldap-ssl-off                  Remove testing ldap ssl CA cert
  lsc, ldap-ssl-client               Use testing ldap ssl client certs
  lsco, ldap-ssl-client-off          Remove testing ldap ssl client certs
```
