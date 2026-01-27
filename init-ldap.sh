#!/bin/bash
# init-ldap.sh

# --- 1. Set Defaults and Hash Password ---
# Fallback to 'admin/admin' if variables are empty
export ADMIN_USER="${LDAP_ADMIN_USER:-admin}"
export ADMIN_PW="${LDAP_ADMIN_PASSWORD:-admin}"
export BASE_DN="${LDAP_BASE_DN:-dc=crypto,dc=lake}"
export ORG="${LDAP_ORGANISATION:-CryptoLake}"
# Extract domain (e.g., 'crypto' from 'crypto.lake')
DOMAIN_PART="${LDAP_DOMAIN%%.*}"
export DC_PART="${DOMAIN_PART:-crypto}"

# Hash the plain text password for the database
export HASHED_PW=$(slappasswd -s "$ADMIN_PW")

echo "Initializing LDAP for $BASE_DN with Admin: $ADMIN_USER"

# --- 2. Start slapd temporarily ---
# We use -h "ldapi:///" to allow local root access via system sockets
slapd -h "ldapi:/// ldap://0.0.0.0:1389/" -d 0 &
sleep 2

# --- 3. Create the Base LDIF ---
cat <<EOF > /tmp/base.ldif
dn: ${BASE_DN}
objectClass: top
objectClass: dcObject
objectClass: organization
o: ${ORG}
dc: ${DC_PART}

dn: cn=${ADMIN_USER},${BASE_DN}
objectClass: simpleSecurityObject
objectClass: organizationalRole
cn: ${ADMIN_USER}
description: LDAP administrator
userPassword: ${HASHED_PW}
EOF

# --- 4. Add data using EXTERNAL Auth ---
# -Y EXTERNAL -H ldapi:/// tells OpenLDAP: 
# "I am the root user on this Linux box, let me in without a password."
ldapadd -Q -Y EXTERNAL -H ldapi:/// -f /tmp/base.ldif

# --- 5. Cleanup ---
pkill slapd
sleep 1
echo "LDAP Initialization Complete."