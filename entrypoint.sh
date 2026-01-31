#!/bin/bash
set -e

# --- Variables ---
LDAP_DOMAIN=${LDAP_DOMAIN:-crypto.lake}
LDAP_ORG=${LDAP_ORGANISATION:-CryptoLake}
LDAP_ADMIN_PW=${LDAP_ADMIN_PASSWORD:-admin}
BASE_DN="dc=$(echo $LDAP_DOMAIN | sed 's/\./,dc=/g')"

# Ensure these match the paths inside the container exactly
TLS_CRT=${LDAP_TLS_CERT}
TLS_KEY=${LDAP_TLS_KEY}
TLS_CA=${LDAP_TLS_CA_CRT}

# --- 0. Pre-Flight ---
# Ensure directories exist and have correct ownership before slapadd
mkdir -p /var/lib/ldap /etc/ldap/slapd.d /run/slapd
chown -R openldap:openldap /var/lib/ldap /etc/ldap/slapd.d /run/slapd

# --- 1. First-Time Initialization ---
if [ ! -f "/var/lib/ldap/.init_done" ]; then
    echo "Initializing Production LDAP for $LDAP_DOMAIN..."
    HASHED_PW=$(slappasswd -s "$LDAP_ADMIN_PW")

    rm -rf /etc/ldap/slapd.d/*
    rm -rf /var/lib/ldap/*

    # A. Initialize Config (Database 0)
    # CRITICAL: We run this AS the openldap user using 'su' to avoid permission issues
    su -s /bin/bash openldap -c "slapadd -n 0 -F /etc/ldap/slapd.d" <<EOF

dn: cn=config
objectClass: olcGlobal
cn: config
olcTLSCACertificateFile: ${TLS_CA}
olcTLSCertificateFile: ${TLS_CRT}
olcTLSCertificateKeyFile: ${TLS_KEY}
olcTLSVerifyClient: never
olcLogLevel: stats
# USE OPENSSL SYNTAX HERE:
olcTLSCipherSuite: ECDHE-RSA-AES256-GCM-SHA384:ECDHE-RSA-AES128-GCM-SHA256:RSA+AESGCM:HIGH:!aNULL:!eNULL:!TLSv1.3
olcTLSProtocolMin: 3.3

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
olcDbIndex: objectClass eq
olcDbIndex: cn,sn,uid pres,eq,sub
EOF

    # B. Initialize Base Domain (Database 1)
    su -s /bin/bash openldap -c "slapadd -n 1 -F /etc/ldap/slapd.d" <<EOF
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

# Final ownership check
chown -R openldap:openldap /var/lib/ldap /etc/ldap/slapd.d /run/slapd /etc/ldap/certs

echo "Starting slapd..."
exec /usr/sbin/slapd -h "ldap:/// ldaps:/// ldapi:///" -u openldap -g openldap -F /etc/ldap/slapd.d -d stats