# OpenEMR-Cmd Documentation

## Overview

OpenEMR-Cmd is similar to devtools, it helps developers to manage and troubleshoot openemr outside the docker,see more detail [here](https://github.com/openemr/openemr/blob/master/CONTRIBUTING.md).

## Implementation

1. Copy the script to local linux environment, create the bin directory if not exist.

```
mkdir ~/bin
curl -L https://raw.githubusercontent.com/openemr/openemr-devops/master/utilities/openemr-cmd/openemr-cmd > ~/bin/openemr-cmd
```

2. Apply executable permissions to the script.

```
chmod +x ~/bin/openemr-cmd
```

3. Test the installation.

```
# openemr-cmd
Usage: openemr-cmd COMMAND [ARGS]
Commands:
  --help                       Show the commands usage
  --version                    Show the openemr-cmd command version
```
