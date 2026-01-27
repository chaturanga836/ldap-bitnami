FROM debian:stable-slim

# Install OpenLDAP and necessary management tools
RUN apt-get update && apt-get install -y \
    slapd \
    ldap-utils \
    procps \
    gnutls-bin \
    ssl-cert \
    && rm -rf /var/lib/apt/lists/*

# Create necessary directories
RUN mkdir -p /var/lib/ldap /etc/ldap/slapd.d /etc/ldap/certs /run/slapd

# Expose privileged ports (389 for LDAP, 636 for LDAPS)
EXPOSE 389 636

COPY init-ldap.sh /usr/local/bin/init-ldap.sh
RUN chmod +x /usr/local/bin/init-ldap.sh

# We run as root to allow binding to ports < 1024 
# and full access to ldapi for configuration
CMD ["/bin/bash", "-c", "/usr/local/bin/init-ldap.sh && exec slapd -d stats -h 'ldap://0.0.0.0:389/ ldaps://0.0.0.0:636/ ldapi:///'"]