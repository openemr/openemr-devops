# OpenEMR Monitor Documentation

## Overview

OpenEMR Monitor is based on [Prometheus](https://prometheus.io/), [cAdvisor](https://github.com/google/cadvisor), [Grafana](https://grafana.com/), and [alertmanger](https://prometheus.io/docs/alerting/latest/alertmanager/) which helps administrator to monitor the status of containers.

## Implementation

Please follow the below steps to deploy, or download and run [monitor-installer](https://github.com/openemr/openemr-devops/tree/master/utilities/openemr-monitor/monitor-installer) script to deploy.

1. Run `git clone` it to your local machine.

```
git clone https://github.com/openemr/openemr-devops.git
cd openemr-devops/utilities/openemr-monitor
```

2. Modify the ip in [prometheus/prometheus.yml](https://github.com/openemr/openemr-devops/tree/master/utilities/openemr-monitor/prometheus/prometheus.yml) file and [grafana/provisioning/datasources/datasource.yml](https://github.com/openemr/openemr-devops/tree/master/utilities//openemr-monitor/grafana/provisioning/datasources/datasource.yml).

3. Modify the alert mail information in [alertmanager.yml](https://github.com/openemr/openemr-devops/tree/master/utilities/openemr-monitor/alertmanager.yml) file, or set the other alert methods.

4. Run `docker-compose up` from your command line until the log stop.
    - If you haven't already, [install Docker](https://docs.docker.com/install/) and [install compose](https://docs.docker.com/compose/install/) for your system.
	- If the firewall is enabled in your host, please make sure 3000, 3001, 3002, 3003 ports open.

### Web UI

 * Grafana: `http//<ip>:3000` and login with user `admin` password `admin`, and it import `ID 193` dashboard in [grafana/provisioning/datasources/dashboards](https://github.com/openemr/openemr-devops/tree/master/utilities//openemr-monitor/grafana/provisioning/dashboards)  by default.
 * Prometheus: `http//<ip>:3001`
 * cAdvisor: `http//<ip>:3002/metrics`
 * AlertManager `http//<ip>:3003` and define the rules in [prometheus/alert-rules.yml](https://github.com/openemr/openemr-devops/tree/master/utilities/openemr-monitor/prometheus/alert-rules.yml)
