FROM debian:stable-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    slapd \
    ldap-utils \
    openssl \
    ca-certificates \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Match the user/group
RUN groupmod -g 911 openldap || groupadd -g 911 openldap && \
    usermod -u 911 -g 911 openldap || useradd -u 911 -g 911 openldap

# Create the internal certs directory
RUN mkdir -p /var/lib/ldap /etc/ldap/slapd.d /run/slapd /container/certs && \
    chown -R openldap:openldap /var/lib/ldap /etc/ldap/slapd.d /run/slapd /container/certs

EXPOSE 389 636

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]