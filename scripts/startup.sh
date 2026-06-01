mkdir -p /home/mcs/docker/{backups,logs,servers,config,import}

cp /tmp/docker-compose.yml /home/mcs/docker-compose.yml

chown -R mcs:mcs /home/mcs

cd /home/mcs

docker-compose up -d