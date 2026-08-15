#!/usr/bin/env bash

set -e

USER=nginx
if [ "$1" = "--root" ]; then
  USER=root
fi

docker exec -it -u $USER $(docker ps -qf name=nginx-router) /bin/bash

