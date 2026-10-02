#!/bin/bash
# Valheim server install script (Ubuntu 24.04, runs as root via user data)
set -euxo pipefail

# Log everything so you can debug later: sudo cat /var/log/valheim-setup.log
exec > >(tee -a /var/log/valheim-setup.log) 2>&1

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get upgrade -y
apt-get install -y unzip apt-transport-https ca-certificates curl gnupg lsb-release

# ---- Docker's official apt repository (the original script never added this,
# ---- so "apt install docker-ce" had nothing to install) ----
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
apt-get update

# ---- Install AWS CLI ----
if ! command -v aws >/dev/null 2>&1; then
  cd /tmp
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
  unzip -q awscliv2.zip
  ./aws/install
fi

# Work out the region from instance metadata (IMDSv2) so the CLI knows where to talk
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
export AWS_DEFAULT_REGION=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)

# ---- Random server password, stored encrypted in Parameter Store ----
VHPW=$(openssl rand -hex 10)

# Stack name written by the user data script, used to make the parameter name unique
STACKNAME=$(</tmp/mcParamName.txt)
PARAMNAME=mcValheimPW-$STACKNAME

aws ssm put-parameter --name "$PARAMNAME" --value "$VHPW" --type "SecureString" --overwrite

# ---- Install Docker (with the compose plugin: use "docker compose", not "docker-compose") ----
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
usermod -aG docker ubuntu   # lets the ubuntu user run docker without sudo (after re-login)

# ---- Valheim server config ----
mkdir -p /usr/games/serverconfig/valheim/{saves,server,backups}
# The mbround18 image runs as UID/GID 1000, so it needs to own the volume folders
chown -R 1000:1000 /usr/games/serverconfig/valheim
cd /usr/games/serverconfig

# Unquoted EOF on purpose so $VHPW is expanded
cat > docker-compose.yml <<EOF
services:
  valheim:
    image: mbround18/valheim:3
    user: "1000:1000"
    restart: unless-stopped
    stop_signal: SIGINT
    stop_grace_period: 2m
    ports:
      - "2456:2456/udp"
      - "2457:2457/udp"
      - "2458:2458/udp"
    environment:
      PORT: 2456
      NAME: "MyAWSGamingServer"
      WORLD: "Dedicated"
      PASSWORD: "$VHPW"
      TZ: "Europe/London"
      PUBLIC: 1
      AUTO_UPDATE: 1
      AUTO_UPDATE_SCHEDULE: "0 1 * * *"
      AUTO_BACKUP: 1
      AUTO_BACKUP_SCHEDULE: "*/15 * * * *"
      AUTO_BACKUP_REMOVE_OLD: 1
      AUTO_BACKUP_DAYS_TO_LIVE: 3
      AUTO_BACKUP_ON_UPDATE: 1
      AUTO_BACKUP_ON_SHUTDOWN: 1
      LD_LIBRARY_PATH: "/home/steam/valheim/linux64:/home/steam/valheim"
    volumes:
      - ./valheim/saves:/home/steam/.config/unity3d/IronGate/Valheim
      - valheim_server_files:/home/steam/valheim
      - ./valheim/backups:/home/steam/backups

volumes:
  valheim_server_files:

EOF

# -d runs it in the background (the original "up" blocked the script forever).
# restart: unless-stopped + docker enabled at boot replaces the old @reboot cron job.
docker compose up -d
