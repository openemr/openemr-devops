# OpenEMR Docker Testing

## Workflow: Production Docker Test (test-prod.yml)

The `test-prod.yml` workflow verifies that the production OpenEMR Docker images can be built correctly and function with a database connection. These images have the OpenEMR code embedded within them and are identified by version numbers (e.g., 7.0.4).

The workflow performs the following steps:

1. Builds OpenEMR Docker images defined in docker/openemr for numbered versions (e.g., 6.1.0, 7.0.4)
2. Sets up a test environment using Docker Compose with:
   - MariaDB 11.4 database
   - OpenEMR container connected to the database
3. Verifies that the web server is responding correctly
4. Runs the OpenEMR installation process
5. Executes multiple test suites including unit, fixtures, services, validators, and controllers tests

### Triggers for Production Tests

The workflow runs automatically when:
- Files in the `docker/openemr/[0-9]*.[0-9]*.[0-9]/**` directory are changed on the main branch
- A pull request targeting the main branch changes files in the numbered version directories

## Workflow: Flex Docker Test (test-flex.yml)

The `test-flex.yml` workflow tests the development-oriented "flex" Docker images. Unlike production images, flex builds don't embed the OpenEMR code within the image - they're designed for development purposes where the code is mounted separately.

The workflow performs the following steps:

1. Checks out both the openemr-devops repository and the OpenEMR code repository
2. Builds the flex Docker images defined in docker/openemr
3. Sets up a test environment using Docker Compose with:
   - MariaDB database
   - OpenEMR container with mounted code
4. Verifies that the web server is responding correctly

### Triggers for Flex Tests

The workflow runs automatically when:
- Files in the `docker/openemr/**` directory are changed on the main branch
- A pull request targeting the main branch changes files in the docker/openemr directory
