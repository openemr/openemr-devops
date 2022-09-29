# OpenEMR-Cmd Documentation

## Overview

OpenEMR-Cmd is similar to devtools, it helps developers to manage and troubleshoot openemr outside the docker,see more detail [here](https://github.com/openemr/openemr/blob/master/CONTRIBUTING.md).
OpenEMR-Cmd-H is getting the help from openemr-cmd -h quickly.

## Implementation

1. Copy the script to local linux environment, create the bin directory if it does not exist. (May have to use ~/.local/bin for newer versions of Ubuntu in steps 1 and 2 so the script is found in $PATH.)

```
mkdir ~/bin
curl -L https://raw.githubusercontent.com/openemr/openemr-devops/master/utilities/openemr-cmd/openemr-cmd > ~/bin/openemr-cmd
curl -L https://raw.githubusercontent.com/openemr/openemr-devops/master/utilities/openemr-cmd/openemr-cmd-h > ~/bin/openemr-cmd-h
```

2. Apply executable permissions to the script.

```
chmod +x ~/bin/openemr-cmd
chmod +x ~/bin/openemr-cmd-h
```

3. Test the installation.

```
# openemr-cmd
Usage: openemr-cmd COMMAND [ARGS]
Commands:
  --help                       Show the commands usage
  --version                    Show the openemr-cmd command version


# openemr-cmd-h
To search the keyword from openemr-cmd -h output quickly
  Usage: openemr-cmd-h keyword
  e.g.   openemr-cmd-h ssl
  h                         openemr-cmd -h
  docker                    docker-management
  php                       php-management
  test                      test-management
  sweep                     sweep-management
  reset                     reset-management
  backup                    backup-management
  ssl                       ssl-management
  mul                       multisite-management
  api                       api-management
  com                       computational-health-informatics
  webroot                   webroot-management
  others                    others
  keyword                   grep from openemr-cmd -h

# openemr-cmd-h test
test-management:
  ut, unit-test                      To run unit testing
  at, api-test                       To run api testing
  et, e2e-test                       To run e2e testing
  st, services-test                  To run services testing
  ft, fixtures-test                  To run fixtures testing
  vt, validators-test                To run validators testing
  ct, controllers-test               To run controllers testing
  ctt, common-test                   To run common testing
```
