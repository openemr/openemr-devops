# OpenEMR-Cmd Documentation

## Overview

OpenEMR-Cmd is similar to devtools, it helps deveployers to manage and troubleshooting openemr outside the docker,see more detail [here](https://github.com/openemr/openemr/blob/master/CONTRIBUTING.md).

## Implementation

1. Copy the script to local linux environment.

```
mkdir /home/<username>/bin
sudo vim /home/<username>/openemr-cmd
```

2. Apply executable permissions to the script.

```
sudo chmod +x /home/<username>/openemr-cmd
```

3. Test the installation.

```
# openemr-cmd
Usage: openemr-cmd COMMAND [ARGS]
Commands:
  build-themes                 Make changes to any files on your local file system
  php-log                      To check PHP error logs
```
