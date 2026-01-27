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
mkdir -p $(dirname "$TLS_CRT")

# Only check for certs if we haven't initialized yet
if [ ! -f "/var/lib/ldap/.init_done" ]; then
    for file in "$TLS_CRT" "$TLS_KEY" "$TLS_CA"; do
        if [ ! -f "$file" ]; then
            echo "ERROR: SSL file $file not found. Check your .env and volumes."
            exit 1
        fi
    done
fi

# Set strict permissions on the private key
chown openldap:openldap "$TLS_CRT" "$TLS_KEY" "$TLS_CA" || true
chmod 600 "$TLS_KEY" || true

# --- 1. First-Time Initialization ---
if [ ! -f "/var/lib/ldap/.init_done" ]; then
    echo "Initializing Production LDAP for $LDAP_DOMAIN..."
    HASHED_PW=$(slappasswd -s "$LDAP_ADMIN_PW")

    # Clear any junk from failed attempts
    rm -rf /etc/ldap/slapd.d/*
    rm -rf /var/lib/ldap/*

    # A. Initialize Config (Database 0)
    # This sets up the server settings, modules, and SSL
    slapadd -n 0 -F /etc/ldap/slapd.d <<EOF
dn: cn=config
objectClass: olcGlobal
cn: config
olcTLSCACertificateFile: ${TLS_CA}
olcTLSCertificateFile: ${TLS_CRT}
olcTLSCertificateKeyFile: ${TLS_KEY}
olcTLSVerifyClient: never

dn: cn=module,cn=config
objectClass: olcModuleList
cn: module
olcModulePath: /usr/lib/ldap
olcModuleLoad: back_mdb
olcModuleLoad: back_monitor

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

    # B. Initialize Base Domain (Database 1)
    # This creates the actual "dc=crypto,dc=lake" structure offline
    slapadd -n 1 -F /etc/ldap/slapd.d <<EOF
dn: ${BASE_DN}
objectClass: top
objectClass: dcObject
objectClass: organization
o: ${LDAP_ORG}
dc: $(echo $LDAP_DOMAIN | cut -d. -f1)
EOF

    touch "/var/lib/ldap/.init_done"
    echo "LDAP bootstrapping successful."
fi

# --- 2. Final Permission Scrubbing ---
# Ensures the 'openldap' user (UID 911) owns everything before start
chown -R openldap:openldap /var/lib/ldap /etc/ldap/slapd.d /run/slapd

# --- 3. Start Production Daemon ---
echo "Starting slapd..."
# -h "ldap:/// ldaps:/// ldapi:///" opens 389, 636, and local socket
# -d stats provides useful production logging
exec /usr/sbin/slapd -h "ldap:/// ldaps:/// ldapi:///" -u openldap -g openldap -F /etc/ldap/slapd.d -d stats