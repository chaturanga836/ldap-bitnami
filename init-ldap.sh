#!/bin/bash
set -e

# --- 1. Load Variables from .env ---
export ADMIN_USER="${LDAP_ADMIN_USER:-admin}"
export ADMIN_PW="${LDAP_ADMIN_PASSWORD:-admin}"
export BASE_DN="${LDAP_BASE_DN:-dc=crypto,dc=lake}"
export ORG_NAME="${LDAP_ORGANISATION:-CryptoLake}"

# Hash the password for secure storage
export HASHED_PW=$(slappasswd -s "$ADMIN_PW")

# --- 2. Check for our CUSTOM flag, not just the file ---
if [ ! -f /var/lib/ldap/CUSTOM_INIT_DONE ]; then
    echo "Fresh start: Wiping default Debian LDAP data..."
    
    # Kill any accidentally running slapd
    pkill -9 slapd || true
    
    # Wipe the default 'nodomain' database created by apt-get
    rm -rf /var/lib/ldap/*
    rm -rf /etc/ldap/slapd.d/*
    
    # Re-create structure
    mkdir -p /var/lib/ldap /etc/ldap/slapd.d
    
    # Initialize the basic config structure from templates
    # This is required because we wiped the /etc/ldap/slapd.d/ directory
    slaptest -f /etc/ldap/slapd.conf -F /etc/ldap/slapd.d/ || echo "Using default schema"

    echo "Initializing Custom LDAP for ${BASE_DN}..."

    # Start slapd temporarily in background
    slapd -h "ldapi:///" -d 0 &
    sleep 3

    # 3. Configure the Database Backend
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
    # Note: dc needs just the 'crypto' part of 'dc=crypto,dc=lake'
    DOMAIN_PART=$(echo $BASE_DN | cut -d',' -f1 | cut -d'=' -f2)

    cat <<EOF > /tmp/base.ldif
dn: ${BASE_DN}
objectClass: top
objectClass: dcObject
objectClass: organization
o: ${ORG_NAME}
dc: ${DOMAIN_PART}
EOF

    ldapadd -Q -Y EXTERNAL -H ldapi:/// -f /tmp/base.ldif

    # 5. Cleanup
    pkill -f slapd
    sleep 2
    
    # Create the flag so we don't wipe data on the next restart!
    touch /var/lib/ldap/CUSTOM_INIT_DONE
    echo "LDAP successfully initialized."
else
    echo "Custom data found (CUSTOM_INIT_DONE exists). Starting slapd normally."
fi