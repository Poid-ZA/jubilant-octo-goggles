#!/bin/bash

# --- Configuration Variables ---
DOMAIN="your.domain.com"                  # !!! REPLACE THIS with your actual domain name !!!
EMAIL="your@email.com"                    # !!! REPLACE THIS with your contact email for Let's Encrypt !!!
HAPROXY_CFG="/etc/haproxy/haproxy.cfg"
HAPROXY_CERT_DIR="/etc/haproxy/certs"
HAPROXY_DH_PARAM="/etc/ssl/private/dhparam.pem"
LE_CERT_DIR="/etc/letsencrypt/live/${DOMAIN}"
COMBINED_PEM="${HAPROXY_CERT_DIR}/${DOMAIN}.pem"
SERVER1_IP="192.168.0.1"
SERVER2_IP="192.168.0.2"

# --- Functions ---

log_message() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') - $1"
}

exit_on_error() {
    if [ $? -ne 0 ]; then
        log_message "ERROR: $1"
        exit 1
    fi
}

# --- Script Start ---

log_message "Starting HAProxy and Certbot setup..."

# 1. Update and Install Prerequisites
log_message "Updating system and installing HAProxy and Certbot..."
sudo apt update -y
exit_on_error "Failed to update system."
sudo apt install -y haproxy certbot openssl
exit_on_error "Failed to install HAProxy, Certbot, or OpenSSL."

# 2. Stop HAProxy (if running) temporarily for Certbot standalone mode
log_message "Stopping HAProxy service for Certbot to acquire certificate..."
sudo systemctl stop haproxy || true # Use || true to prevent script from failing if HAProxy isn't running yet
log_message "HAProxy stopped."

# 3. Obtain Let's Encrypt Certificate
log_message "Attempting to obtain Let's Encrypt certificate for ${DOMAIN}..."
sudo certbot certonly --standalone -d "${DOMAIN}" --non-interactive --agree-tos -m "${EMAIL}" --keep-until-expiring
exit_on_error "Certbot failed to obtain a certificate. Check your domain's DNS A/AAAA records and firewall."
log_message "Certificate obtained successfully from Let's Encrypt."

# 4. Create HAProxy combined .pem file
log_message "Creating combined .pem file for HAProxy..."
sudo mkdir -p "${HAPROXY_CERT_DIR}"
sudo bash -c "cat ${LE_CERT_DIR}/fullchain.pem ${LE_CERT_DIR}/privkey.pem > ${COMBINED_PEM}"
exit_on_error "Failed to combine certificate files."
sudo chmod 600 "${COMBINED_PEM}"
log_message "Combined .pem file created at ${COMBINED_PEM}"

# 5. Generate Diffie-Hellman Parameters (for better security)
log_message "Generating Diffie-Hellman parameters (this might take a few minutes)..."
sudo mkdir -p /etc/ssl/private
if [ ! -f "${HAPROXY_DH_PARAM}" ]; then
    sudo openssl dhparam -out "${HAPROXY_DH_PARAM}" 2048
    exit_on_error "Failed to generate DH parameters."
    sudo chmod 600 "${HAPROXY_DH_PARAM}"
    log_message "DH parameters generated at ${HAPROXY_DH_PARAM}"
else
    log_message "DH parameters already exist, skipping generation."
fi


# 6. Write HAProxy Configuration
log_message "Writing HAProxy configuration to ${HAPROXY_CFG}..."
sudo bash -c "cat <<EOF > ${HAPROXY_CFG}
global
    log /dev/log    local0 notice
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin expose-fd listeners
    stats timeout 30s
    user haproxy
    group haproxy
    daemon

    ca-base /etc/ssl/certs
    crt-base /etc/ssl/private

    ssl-default-bind-ciphers ECDHE+AESGCM:DHE+AESGCM:ECDHE+AES256:DHE+AES256:ECDHE+AES128:DHE+AES128:RSA+AESGCM:RSA+AES:!aNULL:!MD5:!DSS
    ssl-default-bind-options no-sslv3 no-tlsv10 no-tlsv11
    ssl-default-dh-param ${HAPROXY_DH_PARAM}

defaults
    mode    http
    log     global
    option  httplog
    option  dontlognull
    timeout connect 5000ms
    timeout client  50000ms
    timeout server  50000ms

frontend https_frontend
    bind *:443 ssl crt ${COMBINED_PEM} alpn h2,http/1.1
    # Uncomment the two lines below to redirect HTTP (port 80) to HTTPS
    # bind *:80
    # redirect scheme https code 301 if !{ ssl_fc }

    acl is_backend_up nbsrv(web_servers) gt 0
    use_backend web_servers if is_backend_up
    http-request deny deny_status 503 if !is_backend_up

backend web_servers
    mode http
    balance roundrobin
    option httpchk GET / # Health check by requesting the root path
    server s1 ${SERVER1_IP}:80 check
    server s2 ${SERVER2_IP}:80 check
EOF"
exit_on_error "Failed to write HAProxy configuration."
log_message "HAProxy configuration written."

# 7. Enable and Start HAProxy Service
log_message "Enabling and starting HAProxy service..."
sudo systemctl enable haproxy
sudo systemctl start haproxy
exit_on_error "Failed to start HAProxy service. Check configuration for errors: 'sudo haproxy -c -f ${HAPROXY_CFG}'"
log_message "HAProxy service started and enabled."

# 8. Setup Certbot Renewal Script and Cron Job
log_message "Setting up Certbot renewal script and cron job..."

RENEWAL_SCRIPT_PATH="/usr/local/bin/renew_haproxy_cert.sh"

sudo bash -c "cat <<EOF > ${RENEWAL_SCRIPT_PATH}
#!/bin/bash

log_message() {
    echo \"\$(date +'%Y-%m-%d %H:%M:%S') - \$1\"
}

log_message \"Running Certbot renewal for ${DOMAIN}...\"

# Attempt to renew the certificate
if sudo certbot renew --quiet; then
    log_message \"Certbot renewal successful. Rebuilding HAProxy .pem file.\"
    # Recreate the combined .pem file
    sudo bash -c \"cat ${LE_CERT_DIR}/fullchain.pem ${LE_CERT_DIR}/privkey.pem > ${COMBINED_PEM}\"
    if [ \$? -eq 0 ]; then
        sudo chmod 600 ${COMBINED_PEM}
        log_message \"Combined .pem file updated. Reloading HAProxy.\"
        # Reload HAProxy to pick up the new certificate
        sudo systemctl reload haproxy
        if [ \$? -eq 0 ]; then
            log_message \"HAProxy reloaded successfully.\"
        else
            log_message \"ERROR: Failed to reload HAProxy after certificate renewal.\"
        fi
    else
        log_message \"ERROR: Failed to recreate combined .pem file after certificate renewal.\"
    fi
else
    log_message \"Certbot renewal failed or no certificates needed renewal.\"
fi
EOF"
exit_on_error "Failed to create renewal script."

sudo chmod +x "${RENEWAL_SCRIPT_PATH}"
log_message "Renewal script created at ${RENEWAL_SCRIPT_PATH}"

# Add to crontab for automatic renewal
# This will run daily at a random time to avoid server overload
CRON_JOB="0 0 * * * root ${RENEWAL_SCRIPT_PATH} >> /var/log/certbot-haproxy-renewal.log 2>&1"
(sudo crontab -l 2>/dev/null | grep -F "${RENEWAL_SCRIPT_PATH}") || (echo "${CRON_JOB}" | sudo tee -a /etc/crontab > /dev/null)
exit_on_error "Failed to add renewal script to crontab."
log_message "Certbot renewal cron job added. Renewals will run daily."

# 9. Firewall Configuration (UFW example)
log_message "Configuring firewall (UFW) to allow HTTP (80) and HTTPS (443)..."
if command -v ufw &> /dev/null; then
    sudo ufw allow 80/tcp
    sudo ufw allow 443/tcp
    sudo ufw enable
    log_message "UFW enabled and ports 80, 443 allowed."
else
    log_message "UFW not found. Please manually open ports 80 and 443 in your firewall."
fi

log_message "HAProxy and Certbot setup complete!"
log_message "Access your HAProxy load balancer at https://${DOMAIN}"
