#!/bin/bash
set -e

# --- Variables ---
LDAP_DOMAIN=${LDAP_DOMAIN:-crypto.lake}
LDAP_ORG=${LDAP_ORGANISATION:-CryptoLake}
LDAP_ADMIN_PW=${LDAP_ADMIN_PASSWORD:-admin}
BASE_DN="dc=$(echo $LDAP_DOMAIN | sed 's/\./,dc=/g')"

# Detect Environment for SSL
MY_IP=$(hostname -I | awk '{print $1}')
EXTERNAL_IP=${LDAP_EXTERNAL_IP:-$MY_IP}

# --- 0. Permission Pre-fix ---
mkdir -p /etc/ldap/certs /etc/ldap/slapd.d /var/lib/ldap /run/slapd
chown -R openldap:openldap /etc/ldap/certs /etc/ldap/slapd.d /var/lib/ldap /run/slapd

# --- 1. SSL Priority Logic ---
# We check the mounted locations, but we will ALWAYS copy them to the 
# hardcoded internal paths to ensure the LDAP config never breaks.
USER_KEY=${LDAP_TLS_KEY:-/etc/ldap/certs/tls.key}
USER_CRT=${LDAP_TLS_CERT:-/etc/ldap/certs/tls.crt}
USER_CA=${LDAP_TLS_CA_CRT:-/etc/ldap/certs/ca.crt}

if [ ! -f "$USER_KEY" ]; then
    echo "No custom certificates found. Generating auto-signed certs..."
    # (Generation logic remains the same, outputting to /etc/ldap/certs/...)
    cat > /tmp/openssl.cnf <<EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no
[req_distinguished_name]
CN = $EXTERNAL_IP
[v3_req]
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = IP:$EXTERNAL_IP, IP:127.0.0.1, DNS:localhost, DNS:ldap-server
EOF
    openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
      -keyout /etc/ldap/certs/ca.key -out /etc/ldap/certs/ca.crt -subj "/CN=CryptoLake-Internal-CA"
    openssl req -new -newkey rsa:2048 -nodes \
      -keyout /etc/ldap/certs/tls.key -out /tmp/tls.csr -config /tmp/openssl.cnf
    openssl x509 -req -in /tmp/tls.csr -CA /etc/ldap/certs/ca.crt -CAkey /etc/ldap/certs/ca.key \
      -CAcreateserial -out /etc/ldap/certs/tls.crt -days 365 -sha256 \
      -extfile /tmp/openssl.cnf -extensions v3_req
else
    echo "Custom certificates detected. Syncing to internal paths..."
    cp "$USER_KEY" /etc/ldap/certs/tls.key
    cp "$USER_CRT" /etc/ldap/certs/tls.crt
    cp "$USER_CA" /etc/ldap/certs/ca.crt
fi

chown -R openldap:openldap /etc/ldap/certs
chmod 600 /etc/ldap/certs/tls.key
chmod 644 /etc/ldap/certs/tls.crt /etc/ldap/certs/ca.crt

# --- 2. First-Time Initialization ---
if [ ! -f "/var/lib/ldap/.init_done" ]; then
    echo "Cleaning up directories for fresh install..."
    rm -rf /etc/ldap/slapd.d/*
    rm -rf /var/lib/ldap/*
    
    echo "Initializing LDAP for $LDAP_DOMAIN..."
    HASHED_PW=$(slappasswd -s "$LDAP_ADMIN_PW")

    # Initialize Config (Database 0)
    # Using HARDCODED paths for SSL to prevent variable expansion errors
    slapadd -n 0 -F /etc/ldap/slapd.d <<EOF
dn: cn=config
objectClass: olcGlobal
cn: config
olcTLSCACertificateFile: /etc/ldap/certs/ca.crt
olcTLSCertificateFile: /etc/ldap/certs/tls.crt
olcTLSCertificateKeyFile: /etc/ldap/certs/tls.key
olcTLSVerifyClient: never
olcTLSCipherSuite: HIGH:MEDIUM:RSA+AESGCM
olcTLSProtocolMin: 3.3
olcLogLevel: stats

dn: cn=module,cn=config
objectClass: olcModuleList
cn: module
olcModulePath: /usr/lib/ldap
olcModuleLoad: back_mdb

include: /etc/ldap/schema/core.ldif
include: /etc/ldap/schema/cosine.ldif
include: /etc/ldap/schema/inetorgperson.ldif

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

    # Initialize Base Domain
    slapadd -n 1 -F /etc/ldap/slapd.d <<EOF
dn: ${BASE_DN}
objectClass: top
objectClass: dcObject
objectClass: organization
o: ${LDAP_ORG}
dc: $(echo $LDAP_DOMAIN | cut -d. -f1)
EOF

    chown -R openldap:openldap /etc/ldap/slapd.d /var/lib/ldap
    touch "/var/lib/ldap/.init_done"
    chown openldap:openldap /var/lib/ldap/.init_done
fi

echo "Starting slapd..."
exec /usr/sbin/slapd -h "ldap:/// ldaps:/// ldapi:///" -u openldap -g openldap -F /etc/ldap/slapd.d -d stats