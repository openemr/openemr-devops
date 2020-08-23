# Portainer Documentation

## Overview

Portainer is a lightweight management UI which allows you to easily manage your different Docker environments (Docker hosts). For more detail, please refer to [Portainer](https://github.com/portainer/portainer).

## Implementation

1. Run the docker commands to setup the Portainer.
    - If you haven't already, [install Docker](https://docs.docker.com/install/)
```
docker volume create portainer_data
docker run -d -p 8000:8000 -p 9400:9000 --name=portainer --restart=always -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer
```


2. Access in browser: `http://<host ip>:9400`, login with user `admin` and create an initial password.


3. Choose `Local Manage the local Docker environment`, and click `Connect` button, and then it will show the dashboard.

![dashboard](https://github.com/reidliu41/test/blob/master/images/portainer.jpg)
