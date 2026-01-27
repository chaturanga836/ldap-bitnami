#!/bin/bash
set -e # Exit on any error

# 1. Variables with defaults
export ADMIN_USER="${LDAP_ADMIN_USER:-admin}"
export ADMIN_PW="${LDAP_ADMIN_PASSWORD:-admin}"
export BASE_DN="${LDAP_BASE_DN:-dc=crypto,dc=lake}"
export HASHED_PW=$(slappasswd -s "$ADMIN_PW")

# 2. Start slapd in background
slapd -h "ldapi:/// ldap://0.0.0.0:1389/" -d 0 &
sleep 3

# 3. CONFIGURE THE DATABASE (This fixes error 53)
# This tells slapd that it owns dc=crypto,dc=lake
cat <<EOF > /tmp/config.ldif
dn: olcDatabase={1}mdb,cn=config
changetype: modify
replace: olcSuffix
olcSuffix: ${BASE_DN}
-
replace: olcRootDN
olcRootDN: cn=${ADMIN_USER},${BASE_DN}
-
replace: olcRootPW
olcRootPW: ${HASHED_PW}
EOF

ldapmodify -Q -Y EXTERNAL -H ldapi:/// -f /tmp/config.ldif

# 4. ADD THE BASE STRUCTURE
cat <<EOF > /tmp/base.ldif
dn: ${BASE_DN}
objectClass: top
objectClass: dcObject
objectClass: organization
o: CryptoLake
dc: crypto
EOF

ldapadd -Q -Y EXTERNAL -H ldapi:/// -f /tmp/base.ldif

# 5. KILL THE TEMP PROCESS
pkill -f slapd
sleep 2