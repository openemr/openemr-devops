#!/bin/bash

# This handy tool will idle until OpenEMR launches its httpd and is thus considered ready for business.

 # wait a while for services to build    
until docker container ls | grep openemr/openemr >& /dev/null
do
    echo "waiting for container start..."
    sleep 5
done

until docker top $(docker ps | grep -- -openemr | cut -f 1 -d " ") | grep httpd &> /dev/null
do
    echo "waiting for service start..."
    sleep 20
done

exit 0