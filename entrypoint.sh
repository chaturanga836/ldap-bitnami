#!/bin/bash
set -e

# --- Variables ---
LDAP_DOMAIN=${LDAP_DOMAIN:-crypto.lake}
LDAP_ORG=${LDAP_ORGANISATION:-CryptoLake}
LDAP_ADMIN_PW=${LDAP_ADMIN_PASSWORD:-admin}
BASE_DN="dc=$(echo $LDAP_DOMAIN | sed 's/\./,dc=/g')"

TLS_CRT=${LDAP_TLS_CERT:-/etc/ldap/certs/tls.crt}
TLS_KEY=${LDAP_TLS_KEY:-/etc/ldap/certs/tls.key}
TLS_CA=${LDAP_TLS_CA_CRT:-/etc/ldap/certs/ca.crt}

# --- 0. Production Pre-Flight Checks ---
# Ensure cert directory exists (even if not mounted)
mkdir -p $(dirname "$TLS_CRT")

# Verify SSL files exist if initialization is needed
if [ ! -f "/var/lib/ldap/.init_done" ]; then
    for file in "$TLS_CRT" "$TLS_KEY" "$TLS_CA"; do
        if [ ! -f "$file" ]; then
            echo "ERROR: SSL file $file not found. Check your .env and volumes."
            exit 1
        fi
    done
fi

# Fix ownership for certs so the 'openldap' user can actually read them
# (Docker mounts often default to root:root)
chown openldap:openldap "$TLS_CRT" "$TLS_KEY" "$TLS_CA" || true
chmod 600 "$TLS_KEY" || true

# --- 1. First-Time Initialization ---
if [ ! -f "/var/lib/ldap/.init_done" ]; then
    echo "Initializing Production LDAP for $LDAP_DOMAIN..."
    HASHED_PW=$(slappasswd -s "$LDAP_ADMIN_PW")

    rm -rf /etc/ldap/slapd.d/*
    rm -rf /var/lib/ldap/*

    slapadd -n 0 -F /etc/ldap/slapd.d <<EOF
dn: cn=config
objectClass: olcGlobal
cn: config
olcTLSCACertificateFile: ${TLS_CA}
olcTLSCertificateFile: ${TLS_CRT}
olcTLSCertificateKeyFile: ${TLS_KEY}
olcTLSVerifyClient: never

dn: cn=schema,cn=config
objectClass: olcSchemaConfig
cn: schema

include: file:///etc/ldap/schema/core.ldif
include: file:///etc/ldap/schema/cosine.ldif
include: file:///etc/ldap/schema/inetorgperson.ldif
include: file:///etc/ldap/schema/nis.ldif

dn: olcDatabase={0}config,cn=config
objectClass: olcDatabaseConfig
olcDatabase: {0}config
olcRootDN: cn=admin,cn=config
olcRootPW: ${HASHED_PW}

dn: olcDatabase={1}mdb,cn=config
objectClass: olcDatabaseConfig
objectClass: olcMdbConfig
olcDatabase: {1}mdb
olcDbDirectory: /var/lib/ldap
olcSuffix: ${BASE_DN}
olcRootDN: cn=admin,${BASE_DN}
olcRootPW: ${HASHED_PW}
EOF

    chown -R openldap:openldap /etc/ldap/slapd.d /var/lib/ldap /run/slapd

    slapd -h "ldapi:///" -u openldap -g openldap -F /etc/ldap/slapd.d &
    sleep 2

    ldapadd -Q -Y EXTERNAL -H ldapi:/// <<EOF
dn: ${BASE_DN}
objectClass: top
objectClass: dcObject
objectClass: organization
o: ${LDAP_ORG}
dc: $(echo $LDAP_DOMAIN | cut -d. -f1)
EOF

    pkill -f slapd
    touch "/var/lib/ldap/.init_done"
    echo "LDAP bootstrapping successful."
fi

# --- 2. Permission Scrubbing ---
chown -R openldap:openldap /var/lib/ldap /etc/ldap/slapd.d /run/slapd

# --- 3. Start Production Daemon ---
echo "Starting slapd..."
exec /usr/sbin/slapd -h "ldap:/// ldaps:/// ldapi:///" -u openldap -g openldap -F /etc/ldap/slapd.d -d stats