#!/bin/bash

# When not limiting the open file descritors limit, the memory consumption of
# slapd is absurdly high. See https://github.com/docker/docker/issues/8231
ulimit -n 8192

set -e

function reconfigure() {
    echo "Reconfiguration..."
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

    # Note: The HDB backend will soon be deprecated in favor of the new mdb backend.
    # See: https://www.openldap.org/doc/admin24/backends.html
    cat <<-EOF > /tmp/slapd.debconf
slapd slapd/no_configuration boolean false
slapd slapd/password1 password ${SLAPD_PASSWORD}
slapd slapd/password2 password ${SLAPD_PASSWORD}
slapd shared/organization string ${SLAPD_ORGANIZATION}
slapd slapd/domain string ${SLAPD_DOMAIN}
slapd slapd/backend select MDB
slapd slapd/allow_ldap_v2 boolean false
slapd slapd/purge_database boolean false
slapd slapd/move_old_database boolean true
EOF
    debconf-set-selections < /tmp/slapd.debconf
    rm -rfv /var/backups/unknown-*.ldapdb
    dpkg-reconfigure -f noninteractive slapd

    dc_string=""

    IFS="."; declare -a dc_parts=(${SLAPD_DOMAIN}); unset IFS

    for dc_part in "${dc_parts[@]}"; do
      dc_string="$dc_string,dc=$dc_part"
    done

    base_string="BASE ${dc_string:1}"

    sed -i "s/^#BASE.*/${base_string}/g" /etc/ldap/ldap.conf
}

function restoreFromLdifFiles() {
    if [[ ! -e "/etc/ldap/prepopulate-config/config.ldif" ]]; then
      echo "Backup LDAP"
      mkdir -p /etc/ldap/prepopulate-config/ \
      && slapcat -n0 -F /etc/ldap/slapd.d -l /etc/ldap/prepopulate-config/config.ldif -o ldif-wrap=no \
      || return $?
    fi

    if [[ -n "$SLAPD_CONFIG_PASSWORD" ]]; then
      sed_safe_password=${SLAPD_CONFIG_PASSWORD//\//\\\/}

      cp -v /etc/ldap/prepopulate-config/config.ldif /tmp/config.ldif.backup \
      && sed -i -E \
        "/olcRootDN: cn=admin,cn=config/{n;s/((^olcRootPW:+.*$)|(^.*$))/olcRootPW: ${sed_safe_password}¤¤¤¤\3/}" \
        /etc/ldap/prepopulate-config/config.ldif \
      && sed -i -E \
        "s/¤¤¤¤([^\n])/\n\1/" \
        /etc/ldap/prepopulate-config/config.ldif \
      && sed -i -E \
        "s/¤¤¤¤//" \
        /etc/ldap/prepopulate-config/config.ldif \
      || return $?
    fi

    echo "Drop config database" \
    && rm -rf /etc/ldap/slapd.d/* \
    && echo "Import config database from: $(ls -ldh /etc/ldap/prepopulate-config/config.ldif)" \
    && slapadd -n0 -F /etc/ldap/slapd.d -l /etc/ldap/prepopulate-config/config.ldif \
    && chown -R openldap:openldap /etc/ldap/slapd.d/ /var/lib/ldap/ /var/run/slapd/ \
    || return $?

    if [[ -n "$SLAPD_ADDITIONAL_SCHEMAS" ]]; then
      IFS=","; declare -a schemas=(${SLAPD_ADDITIONAL_SCHEMAS}); unset IFS
      for schema in "${schemas[@]}"; do
        local schema_file="/etc/ldap/schema/${schema}.ldif"
        if [[ ! -e "$schema_file" ]]; then
          local file="/etc/ldap/schema/${schema}.schema"
          if [[ ! -e "$file" ]]; then
            echo "ERROR: schema '${schema}' not found"
            return 99
          fi
          /schema2ldif.sh "$file" "$(basename "$file" .schema | sed -r 's,^[0-9]+-,,')" \
          || return $?
        fi
        echo "Add schema: $(ls -ldh ${schema_file})"
        slapadd -n0 -F /etc/ldap/slapd.d -l "${schema_file}" \
        || return $?
      done
    fi

    if [[ -n "$SLAPD_ADDITIONAL_MODULES" ]]; then
      IFS=","; declare -a modules=(${SLAPD_ADDITIONAL_MODULES}); unset IFS

      for module in "${modules[@]}"; do
        local module_file="/etc/ldap/modules/${module}.ldif"

        if [[ "$module" == 'ppolicy' ]]; then
          SLAPD_PPOLICY_DN_PREFIX="${SLAPD_PPOLICY_DN_PREFIX:-cn=default,ou=policies}"
          sed -i "s/\(olcPPolicyDefault: \)PPOLICY_DN/\1${SLAPD_PPOLICY_DN_PREFIX}$dc_string/g" "$module_file" \
          || return $?
        fi

        echo "Add module: $(ls -ldh ${module_file})"
        slapadd -n0 -F /etc/ldap/slapd.d -l "$module_file" \
        || return $?
      done
    fi

    if [[ -d "/etc/ldap/prepopulate" ]]; then
      echo "LDAP setup data"
      ls -lh "/etc/ldap/prepopulate"
      pushd "/etc/ldap/prepopulate" > /dev/null
        for file in $(find . -name '*.schema'); do
          echo "Prepare schema: $file" \
          && /schema2ldif.sh "$file" "$(basename "$file" .schema | sed -r 's,^[0-9]+-,,')" \
          || return $?
        done
        for file in $(find /etc/ldap/prepopulate/ -name '*.ldif' | sort); do
          echo "slapadd: $file" \
          && slapadd -c -F /etc/ldap/slapd.d -l "$file" \
          || return $?
        done
        chown -R openldap:openldap /etc/ldap/slapd.d/ /var/lib/ldap/ /var/run/slapd/
        for file in $(find /etc/ldap/prepopulate/ -name '*.sh' -type f | sort); do
          echo "Run (as $(whoami)): $(ls -ldh "$file")" \
          && chmod -v +x "$file" \
          && "$file" \
          || return $?
        done
      popd > /dev/null
    fi
}

function restoreFromBackup() {
  local backupConfigFile="$1"
  local backupDataFile="$2"

  local targetDirConfig="/etc/ldap/slapd.d"
  local targetDirData="/var/lib/ldap"


  echo "# Purge existing config: " \
  && rm -rfv "${targetDirConfig}"/* \
  && echo "# Purge existing data: " \
  && rm -rfv "${targetDirData}"/* \
  && echo "# Restore config:" \
  && tar -xvf "$backupConfigFile" -C "${targetDirConfig}/" \
  && echo "# Restore data:" \
  && tar -xvf "$backupDataFile" -C "${targetDirData}/"
  return $?
}

function main() {
  SLAPD_FORCE_RECONFIGURE="${SLAPD_FORCE_RECONFIGURE:-false}"

  if [[ ! -d /etc/ldap/slapd.d || "$SLAPD_FORCE_RECONFIGURE" == "true" ]]; then
    reconfigure

    local backupConfigFile="$(ls /etc/ldap.dist/backup/config.slapd-backup.tar.* 2> /dev/null | tail -1)"
    local backupDataFile="$(ls /etc/ldap.dist/backup/data.slapd-backup.tar.* 2> /dev/null | tail -1)"
    if [[ -f "$backupConfigFile" ]] && [[ -f "$backupDataFile" ]]; then
      restoreFromBackup "$backupConfigFile" "$backupDataFile"
    else
      restoreFromLdifFiles
    fi
  else
    slapd_configs_in_env=$(env | grep 'SLAPD_')

    if [[ -n "${slapd_configs_in_env:+x}" ]]; then
      echo "Info: Container already configured, therefore ignoring SLAPD_xxx environment variables and preseed files"
    fi
  fi

  echo "# Restore ownership:" \
  && chown -v -R openldap:openldap /etc/ldap/slapd.d/ /var/lib/ldap/ /var/run/slapd/ \
  && echo "LDAP data ready" \
  && exec "$@"
  return $?
}

main "$@"
exit $?
