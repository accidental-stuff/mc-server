#!/bin/bash
set -e

apt-get update

apt-get install -y \
docker.io \
docker-compose \
rclone \
curl \
unzip

systemctl enable docker
systemctl start docker

id -u mcs >/dev/null 2>&1 || useradd -m -s /bin/bash mcs

mkdir -p /home/mcs/docker

chown -R mcs:mcs /home/mcs/docker