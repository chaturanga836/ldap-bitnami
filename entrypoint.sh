#!/bin/bash
set -e

# --- Variables ---
LDAP_DOMAIN=${LDAP_DOMAIN:-crypto.lake}
LDAP_ORG=${LDAP_ORGANISATION:-CryptoLake}
LDAP_ADMIN_PW=${LDAP_ADMIN_PASSWORD:-admin}
BASE_DN="dc=$(echo $LDAP_DOMAIN | sed 's/\./,dc=/g')"

# Detect Environment for SSL
# If LDAP_EXTERNAL_IP is not provided, we detect the container IP
MY_IP=$(hostname -I | awk '{print $1}')
EXTERNAL_IP=${LDAP_EXTERNAL_IP:-$MY_IP}

# --- 0. SSL Generation (The "Docker Hub" Portability Fix) ---
mkdir -p /etc/ldap/certs
chown openldap:openldap /etc/ldap/certs

if [ ! -f "/etc/ldap/certs/tls.crt" ]; then
    echo "Generating dynamic certificate for $EXTERNAL_IP..."
    
    # Generate a temporary OpenSSL config
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

    # 1. Generate a CA (In a real Hub image, you could bake a static CA.key/crt here)
    openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
      -keyout /etc/ldap/certs/ca.key -out /etc/ldap/certs/ca.crt -subj "/CN=CryptoLake-Internal-CA"

    # 2. Generate Server Cert with the required Digital Signature bit (Fixes Ranger)
    openssl req -new -newkey rsa:2048 -nodes \
      -keyout /etc/ldap/certs/tls.key -out /tmp/tls.csr -config /tmp/openssl.cnf

    # 3. Sign it
    openssl x509 -req -in /tmp/tls.csr -CA /etc/ldap/certs/ca.crt -CAkey /etc/ldap/certs/ca.key \
      -CAcreateserial -out /etc/ldap/certs/tls.crt -days 365 -sha256 \
      -extfile /tmp/openssl.cnf -extensions v3_req
    
    chown openldap:openldap /etc/ldap/certs/*
fi

TLS_CA="/etc/ldap/certs/ca.crt"
TLS_CRT="/etc/ldap/certs/tls.crt"
TLS_KEY="/etc/ldap/certs/tls.key"

# --- 1. First-Time Initialization ---
if [ ! -f "/var/lib/ldap/.init_done" ]; then
    echo "Initializing LDAP for $LDAP_DOMAIN..."
    HASHED_PW=$(slappasswd -s "$LDAP_ADMIN_PW")

    # Initialize Config (Database 0)
    su -s /bin/bash openldap -c "slapadd -n 0 -F /etc/ldap/slapd.d" <<EOF
dn: cn=config
objectClass: olcGlobal
cn: config
olcTLSCACertificateFile: ${TLS_CA}
olcTLSCertificateFile: ${TLS_CRT}
olcTLSCertificateKeyFile: ${TLS_KEY}
olcTLSVerifyClient: never
# Enable modern ciphers for Trino 479, but maintain RSA for older cert compatibility
olcTLSCipherSuite: HIGH:MEDIUM:!SSLv2:!SSLv3:!TLSv1.3:RSA+AESGCM
olcTLSProtocolMin: 3.3
olcLogLevel: stats

dn: cn=module,cn=config
objectClass: olcModuleList
cn: module
olcModulePath: /usr/lib/ldap
olcModuleLoad: back_mdb

include: file:///etc/ldap/schema/core.ldif
include: file:///etc/ldap/schema/cosine.ldif
include: file:///etc/ldap/schema/inetorgperson.ldif

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
    su -s /bin/bash openldap -c "slapadd -n 1 -F /etc/ldap/slapd.d" <<EOF
dn: ${BASE_DN}
objectClass: top
objectClass: dcObject
objectClass: organization
o: ${LDAP_ORG}
dc: $(echo $LDAP_DOMAIN | cut -d. -f1)
EOF

    touch "/var/lib/ldap/.init_done"
fi

echo "Starting slapd..."
exec /usr/sbin/slapd -h "ldap:/// ldaps:/// ldapi:///" -u openldap -g openldap -F /etc/ldap/slapd.d -d stats