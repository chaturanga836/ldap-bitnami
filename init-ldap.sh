#!/bin/bash
set -e

# --- 1. Load Variables from .env ---
export ADMIN_USER="${LDAP_ADMIN_USER:-admin}"
export ADMIN_PW="${LDAP_ADMIN_PASSWORD:-admin}"
export BASE_DN="${LDAP_BASE_DN:-dc=crypto,dc=lake}"
export ORG_NAME="${LDAP_ORGANISATION:-CryptoLake}"

# Hash the password for secure storage
export HASHED_PW=$(slappasswd -s "$ADMIN_PW")

# --- 2. Check if already initialized ---
if [ ! -f /var/lib/ldap/data.mdb ]; then
    echo "Initializing LDAP as Root on Port 389..."

    # Start slapd temporarily in background
    slapd -h "ldapi:///" -d 0 &
    sleep 3

    # 3. Configure the Database Backend (Fixes Error 53 & 50)
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

    # 4. Create the Base Domain Entry
    cat <<EOF > /tmp/base.ldif
dn: ${BASE_DN}
objectClass: top
objectClass: dcObject
objectClass: organization
o: ${ORG_NAME}
dc: ${BASE_DN%%,*}
EOF

    ldapadd -Q -Y EXTERNAL -H ldapi:/// -f /tmp/base.ldif

    # 5. Cleanup temporary process
    pkill -f slapd
    sleep 2
    echo "LDAP successfully initialized."
else
    echo "Persistent data found. Skipping initialization."
fi