#!/bin/bash
set -euo pipefail

# Log everything
exec > /var/log/userdata.log 2>&1

echo "=== USER DATA START $(date) ==="

# Update packages
DEBIAN_FRONTEND=noninteractive apt-get update -y

# Install nginx
DEBIAN_FRONTEND=noninteractive apt-get install -y nginx

# Create health check location in Nginx config
cat > /etc/nginx/sites-available/default << 'NGINXEOF'
server {
    listen 80;
    server_name _;

    root /var/www/html;
    index index.html;

    location /health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }

    location / {
        try_files $uri $uri/ =404;
    }
}
NGINXEOF

TOKEN=$(curl -s --fail -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

INSTANCE_ID=$(curl -s --fail -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)

PRIVATE_IP=$(curl -s --fail -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/local-ipv4)

mkdir -p /var/www/html

# Create HTML page
cat > /var/www/html/index.html << EOF
<!DOCTYPE html>
<html>
  <head>
    <title>Week 13 Load Balancing & Auto Scaling</title>
  </head>
  <body>
    <h1>Abou</h1>
    <p>week 13: Load Balancing and Auto Scaling</p>
    <p>Instance ID: $INSTANCE_ID</p>
    <p>Private IP: $PRIVATE_IP</p>
    <p>Deployed at: $(date)</p>
  </body>
</html>
EOF

# Validate config
nginx -t

# Start nginx
systemctl restart nginx
systemctl enable nginx
systemctl daemon-reexec

cat > /var/log/deploy_info.txt <<EOF
Timestamp = $(date +%F_%H-%M-%S)
INSTANCE_ID = $INSTANCE_ID
PRIVATE_IP = $PRIVATE_IP
EOF

echo "=== USER DATA END $(date) ==="
