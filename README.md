Important Notes Before Running:

1.  **REPLACE PLACEHOLDERS**:
    *   `DOMAIN="your.domain.com"`: This *must* be your actual public domain name that points via DNS A/AAAA records to this server's IP address.
    *   `EMAIL="your@email.com"`: This is used by Let's Encrypt for urgent notices and recovery.
    *   `SERVER1_IP` and `SERVER2_IP`: Update these to the correct internal IP addresses of your backend web servers.
2.  **DNS Records**: Ensure your `DOMAIN` has a public A record (and AAAA if using IPv6) pointing to the public IP address of the server where you are running this script. Let's Encrypt needs this to verify domain ownership.
3.  **Firewall**: The script attempts to configure UFW if it's installed. If you use a different firewall (e.g., `firewalld` on CentOS/RHEL, or a cloud provider's security groups), you *must* manually ensure ports 80 and 443 are open to allow inbound traffic.
4.  **Backend Servers**: Your servers at `192.168.0.1` and `192.168.0.2` must be running a web server (like Nginx or Apache) and listening on port 80.
5.  **Running the Script**:
    *   Save the content above into a file, e.g., `setup_haproxy_le.sh`.
    *   Make it executable: `chmod +x setup_haproxy_le.sh`
    *   Run it: `sudo ./setup_haproxy_le.sh`
6.  **HTTP to HTTPS Redirect**: The lines for redirecting HTTP (port 80) to HTTPS are commented out in the HAProxy configuration. If you want this behavior, uncomment them within the script *before* running it.
7.  **Renewal Process**: The script sets up a daily cron job that attempts to renew certificates if they are nearing expiration. If successful, it rebuilds the HAProxy `.pem` file and gracefully reloads HAProxy.
8.  **Idempotency**: The script tries to be somewhat idempotent (e.g., checking for DH params), but it's primarily designed for initial setup. Running it multiple times might overwrite configurations.
9.  **Error Handling**: Basic error handling is included, but thorough debugging might require manual inspection of logs (`/var/log/syslog`, `journalctl -u haproxy`, `/var/log/certbot/`).
