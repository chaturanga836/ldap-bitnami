FROM debian:stable-slim

# Install OpenLDAP and required tools for SSL and healthchecks
RUN apt-get update && apt-get install -y --no-install-recommends \
    slapd \
    ldap-utils \
    openssl \
    ca-certificates \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Create dedicated user/group (Borrowing Osixia's 911/911 convention)
RUN groupmod -g 911 openldap && \
    usermod -u 911 -g 911 openldap

# Setup required directories with correct ownership
RUN mkdir -p /var/lib/ldap /etc/ldap/slapd.d /run/slapd /container/certs && \
    chown -R openldap:openldap /var/lib/ldap /etc/ldap/slapd.d /run/slapd

# Production hardening: expose standard ports
EXPOSE 389 636

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# We start as root to handle potential permission fixes, 
# but slapd will drop to the 'openldap' user immediately.
ENTRYPOINT ["/entrypoint.sh"]