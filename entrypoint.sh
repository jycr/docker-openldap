#!/bin/bash

# When not limiting the open file descritors limit, the memory consumption of
# slapd is absurdly high. See https://github.com/docker/docker/issues/8231
ulimit -n 8192

set -e

SLAPD_FORCE_RECONFIGURE="${SLAPD_FORCE_RECONFIGURE:-false}"

first_run=true

if [[ -f "/var/lib/ldap/DB_CONFIG" ]]; then 
    first_run=false
fi

if [[ ! -d /etc/ldap/slapd.d || "$SLAPD_FORCE_RECONFIGURE" == "true" ]]; then

    if [[ -z "$SLAPD_PASSWORD" ]]; then
        echo -n >&2 "Error: Container not configured and SLAPD_PASSWORD not set. "
        echo >&2 "Did you forget to add -e SLAPD_PASSWORD=... ?"
        exit 1
    fi

    if [[ -z "$SLAPD_DOMAIN" ]]; then
        echo -n >&2 "Error: Container not configured and SLAPD_DOMAIN not set. "
        echo >&2 "Did you forget to add -e SLAPD_DOMAIN=... ?"
        exit 1
    fi

    SLAPD_ORGANIZATION="${SLAPD_ORGANIZATION:-${SLAPD_DOMAIN}}"

    cp -r /etc/ldap.dist/* /etc/ldap

	# Note: The hdb backend will soon be deprecated in favor of the new mdb backend.
	# See: https://www.openldap.org/doc/admin24/backends.html
    cat <<-EOF > /tmp/slapd.conf
        slapd slapd/no_configuration boolean false
        slapd slapd/password1 password $SLAPD_PASSWORD
        slapd slapd/password2 password $SLAPD_PASSWORD
        slapd shared/organization string $SLAPD_ORGANIZATION
        slapd slapd/domain string $SLAPD_DOMAIN
        slapd slapd/backend select MDB
        slapd slapd/allow_ldap_v2 boolean false
        slapd slapd/purge_database boolean false
        slapd slapd/move_old_database boolean true
EOF
    cat /tmp/slapd.conf | debconf-set-selections
    rm -rfv /var/backups/unknown-*.ldapdb
    dpkg-reconfigure -f noninteractive slapd

    dc_string=""

    IFS="."; declare -a dc_parts=($SLAPD_DOMAIN); unset IFS

    for dc_part in "${dc_parts[@]}"; do
        dc_string="$dc_string,dc=$dc_part"
    done

    base_string="BASE ${dc_string:1}"

    sed -i "s/^#BASE.*/${base_string}/g" /etc/ldap/ldap.conf

    if [[ -n "$SLAPD_CONFIG_PASSWORD" ]]; then
        password_hash=`slappasswd -s "${SLAPD_CONFIG_PASSWORD}"`

        sed_safe_password_hash=${password_hash//\//\\\/}

        slapcat -n0 -F /etc/ldap/slapd.d -l /tmp/config.ldif
        sed -i "s/\(olcRootDN: cn=admin,cn=config\)/\1\nolcRootPW: ${sed_safe_password_hash}/g" /tmp/config.ldif
        rm -rf /etc/ldap/slapd.d/*
        slapadd -n0 -F /etc/ldap/slapd.d -l /tmp/config.ldif
        rm /tmp/config.ldif
    fi

    for file in `find /etc/ldap/schema/ -name '*.schema'`; do
        if [ ! -e "/etc/ldap/schema/$(basename "$file" .schema).ldif" ]; then
            /schema2ldif.sh "$file" "$(basename "$file" .schema | sed -r 's,^[0-9]+-,,')"
        fi
    done
    if [[ -n "$SLAPD_ADDITIONAL_SCHEMAS" ]]; then
        IFS=","; declare -a schemas=($SLAPD_ADDITIONAL_SCHEMAS); unset IFS

        for schema in "${schemas[@]}"; do
            slapadd -n0 -F /etc/ldap/slapd.d -l "/etc/ldap/schema/${schema}.ldif"
        done
    fi

    if [[ -n "$SLAPD_ADDITIONAL_MODULES" ]]; then
        IFS=","; declare -a modules=($SLAPD_ADDITIONAL_MODULES); unset IFS

        for module in "${modules[@]}"; do
             module_file="/etc/ldap/modules/${module}.ldif"

             if [ "$module" == 'ppolicy' ]; then
                 SLAPD_PPOLICY_DN_PREFIX="${SLAPD_PPOLICY_DN_PREFIX:-cn=default,ou=policies}"

                 sed -i "s/\(olcPPolicyDefault: \)PPOLICY_DN/\1${SLAPD_PPOLICY_DN_PREFIX}$dc_string/g" $module_file
             fi

             slapadd -n0 -F /etc/ldap/slapd.d -l "$module_file"
        done
    fi
else
    slapd_configs_in_env=`env | grep 'SLAPD_'`

    if [ -n "${slapd_configs_in_env:+x}" ]; then
        echo "Info: Container already configured, therefore ignoring SLAPD_xxx environment variables and preseed files"
    fi
fi

if [[ "$first_run" == "true" ]]; then
    if [[ -d "/etc/ldap/prepopulate" ]]; then
        pushd "/etc/ldap/prepopulate" > /dev/null
            for file in `find . -name '*.schema'`; do
                /schema2ldif.sh "$file" "$(basename "$file" .schema | sed -r 's,^[0-9]+-,,')"
            done
            for file in `find /etc/ldap/prepopulate/ -name '*.ldif' | sort`; do
                echo "slapadd: $file"
                slapadd -F /etc/ldap/slapd.d -l "$file"
            done
        popd > /dev/null
    fi
fi

chown -R openldap:openldap /etc/ldap/slapd.d/ /var/lib/ldap/ /var/run/slapd/

echo "LDAP data ready"

exec "$@"
