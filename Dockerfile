# Stage 1: Build/Config (Optional if you have complex schemas)
FROM debian:stable-slim

# Install OpenLDAP and basic tools
RUN apt-get update && apt-get install -y \
    slapd \
    ldap-utils \
    gnutls-bin \
    ssl-cert \
    && rm -rf /var/lib/apt/lists/*

# Hardening Step 1: Run as a non-root user
# OpenLDAP usually creates an 'openldap' user. We will use that.
RUN mkdir -p /var/lib/ldap /etc/ldap/slapd.d /etc/ldap/certs /var/run/slapd /run/slapd && \
    chown -R openldap:openldap /var/lib/ldap /etc/ldap/slapd.d /etc/ldap/certs /var/run/slapd /run/slapd

# Hardening Step 2: Set up environment for LDAP SSL
# We will mount your certs here later
RUN mkdir -p /etc/ldap/certs && chown openldap:openldap /etc/ldap/certs

# Expose non-privileged ports (Standard for K8s readiness)
EXPOSE 1389 1636

USER openldap

# Start the daemon pointing to our config and data
# Change this:
# CMD ["slapd", "-d", "stats", "-h", "ldap://0.0.0.0:1389/ ldaps://0.0.0.0:1636/ ldapi:///"]

# To this:
CMD ["slapd", "-d", "stats", "-h", "ldap://0.0.0.0:1389/ ldaps://0.0.0.0:1636/"]