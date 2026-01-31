#!/bin/bash
set -e

# --- Variables ---
LDAP_DOMAIN=${LDAP_DOMAIN:-crypto.lake}
LDAP_ORG=${LDAP_ORGANISATION:-CryptoLake}
LDAP_ADMIN_PW=${LDAP_ADMIN_PASSWORD:-admin}
BASE_DN="dc=$(echo $LDAP_DOMAIN | sed 's/\./,dc=/g')"

TARGET_KEY=${LDAP_TLS_KEY:-/etc/ldap/certs/tls.key}
TARGET_CRT=${LDAP_TLS_CERT:-/etc/ldap/certs/tls.crt}
TARGET_CA=${LDAP_TLS_CA_CRT:-/etc/ldap/certs/ca.crt}

# --- 0. Permission Pre-fix ---
mkdir -p /etc/ldap/slapd.d /var/lib/ldap /run/slapd
chown -R openldap:openldap /etc/ldap/slapd.d /var/lib/ldap /run/slapd

# --- 1. Initialization ---
if [ ! -f "/var/lib/ldap/.init_done" ]; then
    echo "Cleaning up directories for fresh install..."
    rm -rf /etc/ldap/slapd.d/*
    rm -rf /var/lib/ldap/*
    
    echo "Initializing LDAP for $LDAP_DOMAIN..."
    HASHED_PW=$(slappasswd -s "$LDAP_ADMIN_PW")

    # STEP 1: Global Config & Modules
    cat <<EOF > /tmp/00-config.ldif
dn: cn=config
objectClass: olcGlobal
cn: config
olcTLSCACertificateFile: $TARGET_CA
olcTLSCertificateFile: $TARGET_CRT
olcTLSCertificateKeyFile: $TARGET_KEY
olcTLSVerifyClient: never
olcTLSCipherSuite: HIGH:MEDIUM:RSA+AESGCM
olcTLSProtocolMin: 3.3
olcLogLevel: stats

dn: cn=module,cn=config
objectClass: olcModuleList
cn: module
olcModulePath: /usr/lib/ldap
olcModuleLoad: back_mdb
EOF
    slapadd -n 0 -F /etc/ldap/slapd.d -l /tmp/00-config.ldif

# STEP 2: Explicitly load schemas
    echo "Loading core schemas..."
    slapadd -n 0 -F /etc/ldap/slapd.d -l /etc/ldap/schema/core.ldif
    slapadd -n 0 -F /etc/ldap/slapd.d -l /etc/ldap/schema/cosine.ldif
    slapadd -n 0 -F /etc/ldap/slapd.d -l /etc/ldap/schema/nis.ldif           # <--- ADD THIS
    slapadd -n 0 -F /etc/ldap/slapd.d -l /etc/ldap/schema/inetorgperson.ldif

    # STEP 2.1: Add MemberOf support (Required for your backend /api/users/{username}/groups)
    cat <<EOF > /tmp/00-modules.ldif
dn: cn=module{1},cn=config
objectClass: olcModuleList
cn: module{1}
olcModulePath: /usr/lib/ldap
olcModuleLoad: memberof.la
olcModuleLoad: refint.la
EOF
    slapadd -n 0 -F /etc/ldap/slapd.d -l /tmp/00-modules.ldif

# Updated STEP 3: Databases + Overlays
    cat <<EOF > /tmp/01-db.ldif
dn: olcDatabase={0}config,cn=config
objectClass: olcDatabaseConfig
olcDatabase: {0}config
olcRootDN: cn=admin,cn=config
olcRootPW: $HASHED_PW

dn: olcDatabase={1}mdb,cn=config
objectClass: olcDatabaseConfig
objectClass: olcMdbConfig
olcDatabase: {1}mdb
olcDbDirectory: /var/lib/ldap
olcSuffix: $BASE_DN
olcRootDN: cn=admin,$BASE_DN
olcRootPW: $HASHED_PW
olcDbIndex: objectClass eq
olcDbIndex: cn,sn,uid pres,eq,sub

# --- Enable MemberOf Overlay ---
dn: olcOverlay={0}memberof,olcDatabase={1}mdb,cn=config
objectClass: olcConfig
objectClass: olcMemberOf
objectClass: olcOverlayConfig
objectClass: top
olcOverlay: {0}memberof

# --- Enable Referential Integrity ---
# (Ensures if you delete a user, they are removed from groups automatically)
dn: olcOverlay={1}refint,olcDatabase={1}mdb,cn=config
objectClass: olcConfig
objectClass: olcOverlayConfig
objectClass: olcRefintConfig
objectClass: top
olcOverlay: {1}refint
olcRefintAttribute: member memberUid
EOF
    slapadd -n 0 -F /etc/ldap/slapd.d -l /tmp/01-db.ldif

    # STEP 4: Root Entry
    cat <<EOF > /tmp/02-data.ldif
dn: $BASE_DN
objectClass: top
objectClass: dcObject
objectClass: organization
o: $LDAP_ORG
dc: $(echo $LDAP_DOMAIN | cut -d. -f1)
EOF
    slapadd -n 1 -F /etc/ldap/slapd.d -l /tmp/02-data.ldif

    chown -R openldap:openldap /etc/ldap/slapd.d /var/lib/ldap
    touch "/var/lib/ldap/.init_done"
fi

echo "Starting slapd..."
exec /usr/sbin/slapd -h "ldap:/// ldaps:/// ldapi:///" -u openldap -g openldap -F /etc/ldap/slapd.d -d stats