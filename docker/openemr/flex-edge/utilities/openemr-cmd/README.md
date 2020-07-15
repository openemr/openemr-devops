# OpenEMR-Cmd Documentation

## Overview

OpenEMR-Cmd is similar to devtools, it helps deveployers to manage and troubleshooting openemr outside the docker,see more detail [here](https://github.com/openemr/openemr/blob/master/CONTRIBUTING.md).

## Implementation

1. Copy the script to local linux environment.

```
sudo vim /usr/local/bin/openemr-cmd
```

2. Apply executable permissions to the script.

```
sudo chmod +x /usr/local/bin/openemr-cmd
```

3. If the command openemr-cmd fails after installation, check your path. You can also create a symbolic link to /usr/bin or any other directory in your path:

```
sudo ln -s /usr/local/bin/openemr-cmd /usr/bin/openemr-cmd
```

4. Test the installation.

```
# openemr-cmd
Usage: openemr-cmd COMMAND [ARGS]
Commands:
  start-compose                Start docker-compose
  stop-compose                 Stop docker-compose
```
