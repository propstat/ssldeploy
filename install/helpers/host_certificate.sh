#!/bin/sh
# =============================================================================
# ssldeploy - host certificate: credential collection + issuance + renewal
#
# Executed from: ssldeploy/install/  (sourced by install.sh)
#
# Entry point:
#   host_certificate_request   - full flow: collect DNS credentials, test
#                                them against ACME staging, issue the host
#                                certificate, set up cron-based renewal
#
# Internal functions (do not call directly from install.sh):
#   collect_dns_credentials    - interactive credential collection
#                                (also reused by the retry loop)
#   host_dns_certificate       - FQDN confirmation, staging test, issuance,
#                                renewal script + cron job
#   _hdc_*                     - shared helpers
#
# Reads:   ../dns/configurations/*.yaml
#          ../.env  (ssldeployMode, ACME_EMAIL, ...)
# Writes:  ../dns/credentials/host
#          ../dns/credentials/certificates/host.pem|host.key
#          ../certificateStorage/host/certificates/<fqdn>.* + host.crt/host.key
#          ../certificateStorage/host/acme-configurations/host.json
#          ../certificateStorage/host/accounts/ (lego ACME accounts)
#          /etc/cron.d/ssldeploy-renew (root) or user crontab entry
#
# POSIX sh compatible (dash, bash, busybox ash) - runs on Debian, Ubuntu,
# RHEL, Arch, Alpine and SUSE. Requires: awk, stty, mktemp, nano, lego.
# =============================================================================

# ==============================================================================
# credential collection
# ==============================================================================
collect_dns_credentials() {
    CONFIG_DIR="../dns/configurations"
    CRED_DIR="../dns/credentials"
    CERT_DIR="${CRED_DIR}/certificates"
    CRED_FILE="${CRED_DIR}/host"
    TAB="$(printf '\t')"

    # --- shared awk helper: extract a value from a 'key: "value"' YAML line ---
    AWK_VAL='
    function val(s) {
        sub(/^[[:space:]]*-?[[:space:]]*[A-Za-z_]+:[[:space:]]*/, "", s)
        if (s ~ /^"/) { sub(/^"/, "", s); sub(/".*$/, "", s) }
        else {
            sub(/[[:space:]]*#.*$/, "", s)
            gsub(/^[[:space:]]+/, "", s); gsub(/[[:space:]]+$/, "", s)
        }
        return s
    }'

    # --- sanity checks ----------------------------------------------------- #
    if [ ! -d "$CONFIG_DIR" ]; then
        printf 'ERROR: configuration directory %s not found.\n' "$CONFIG_DIR" >&2
        return 1
    fi
    command -v awk  >/dev/null 2>&1 || { printf 'ERROR: awk is required.\n'  >&2; return 1; }
    command -v nano >/dev/null 2>&1 || { printf 'ERROR: nano is required.\n' >&2; return 1; }

    tmp_prov="$(mktemp)" || return 1
    tmp_sets="$(mktemp)" || { rm -f "$tmp_prov"; return 1; }
    tmp_comp="$(mktemp)" || { rm -f "$tmp_prov" "$tmp_sets"; return 1; }

    # make sure terminal echo is restored and temp files removed on exit
    trap 'stty echo < /dev/tty 2>/dev/null; rm -f "$tmp_prov" "$tmp_sets" "$tmp_comp"' INT TERM

    # ======================================================================= #
    # 1. Parse all yaml files -> provider list (file, dns_name, friendlyName) #
    # ======================================================================= #
    : > "$tmp_prov"
    for f in "$CONFIG_DIR"/*.yaml "$CONFIG_DIR"/*.yml; do
        [ -f "$f" ] || continue
        awk -v FILE="$f" "$AWK_VAL"'
            /^dns_name:/         { name = val($0) }
            /^dns_friendlyName:/ { friendly = val($0) }
            END {
                if (name != "" && friendly != "")
                    print FILE "\t" name "\t" friendly
            }
        ' "$f" >> "$tmp_prov"
    done

    if [ ! -s "$tmp_prov" ]; then
        printf 'ERROR: no valid provider configurations found in %s.\n' "$CONFIG_DIR" >&2
        rm -f "$tmp_prov" "$tmp_sets" "$tmp_comp"; trap - INT TERM
        return 1
    fi

    # ======================================================================= #
    # 2. Let the user pick a DNS provider (list of dns_friendlyName)          #
    # ======================================================================= #
    printf '\nAvailable DNS providers:\n\n'
    i=0
    while IFS="$TAB" read -r p_file p_name p_friendly; do
        i=$((i + 1))
        printf '  %2d) %s\n' "$i" "$p_friendly"
    done < "$tmp_prov"
    prov_count=$i

    sel_prov=""
    while [ -z "$sel_prov" ]; do
        printf '\nSelect a DNS provider [1-%d]: ' "$prov_count"
        read -r answer < /dev/tty
        case "$answer" in
            *[!0-9]*|'') ;;
            *) [ "$answer" -ge 1 ] && [ "$answer" -le "$prov_count" ] && sel_prov=$answer ;;
        esac
        [ -z "$sel_prov" ] && printf 'Invalid selection.\n'
    done

    sel_line="$(awk -v N="$sel_prov" 'NR == N' "$tmp_prov")"
    yaml_file="${sel_line%%"$TAB"*}"
    rest="${sel_line#*"$TAB"}"
    dns_name="${rest%%"$TAB"*}"
    dns_friendly="${rest#*"$TAB"}"

    # ======================================================================= #
    # 3. Let the user pick a credential set of the selected provider          #
    # ======================================================================= #
    awk "$AWK_VAL"'
        BEGIN { OFS = "\t" }
        /^[[:space:]]*-[[:space:]]*dns_credentialSet_name:/ {
            flushset(); sname = val($0); sfriendly = ""; sdesc = ""
        }
        /dns_credentialSet_friendlyName:/ { sfriendly = val($0) }
        /dns_credentialSet_description:/  { sdesc = val($0) }
        END { flushset() }
        function flushset() {
            if (sname != "") { print sname, sfriendly, sdesc; sname = "" }
        }
    ' "$yaml_file" > "$tmp_sets"

    if [ ! -s "$tmp_sets" ]; then
        printf 'ERROR: no credential sets defined for %s.\n' "$dns_friendly" >&2
        rm -f "$tmp_prov" "$tmp_sets" "$tmp_comp"; trap - INT TERM
        return 1
    fi

    printf '\nCredential sets for %s:\n\n' "$dns_friendly"
    i=0
    while IFS="$TAB" read -r s_name s_friendly s_desc; do
        i=$((i + 1))
        printf '  %2d) %s\n      %s\n' "$i" "$s_friendly" "$s_desc"
    done < "$tmp_sets"
    set_count=$i

    sel_set=""
    while [ -z "$sel_set" ]; do
        printf '\nSelect a credential set [1-%d]: ' "$set_count"
        read -r answer < /dev/tty
        case "$answer" in
            *[!0-9]*|'') ;;
            *) [ "$answer" -ge 1 ] && [ "$answer" -le "$set_count" ] && sel_set=$answer ;;
        esac
        [ -z "$sel_set" ] && printf 'Invalid selection.\n'
    done

    sel_set_line="$(awk -v N="$sel_set" 'NR == N' "$tmp_sets")"
    set_name="${sel_set_line%%"$TAB"*}"

    # ======================================================================= #
    # 4. Extract the components of the selected credential set                #
    #    one line per component:                                              #
    #    argName TAB friendly TAB desc TAB type TAB secret TAB required TAB   #
    #    picklist ("friendly|desc|value;friendly|desc|value;...")             #
    # ======================================================================= #
    awk -v SET="$sel_set" "$AWK_VAL"'
        BEGIN { s = 0; OFS = "\t" }
        /^[[:space:]]*-[[:space:]]*dns_credentialSet_name:/ {
            s++
            if (s > SET) { flushcomp(); exit }
        }
        s == SET && (/dns_credentialSet_component_argumentName:/ || /dns_credentialSet_component_name:/) {
            flushcomp()
            arg = val($0); cfriendly = ""; cdesc = ""; ctype = "string"
            csecret = "false"; crequired = "false"; pick = ""
        }
        s == SET && /dns_credentialSet_component_friendlyName:/ { cfriendly  = val($0) }
        s == SET && /dns_credentialSet_component_description:/  { cdesc      = val($0) }
        s == SET && /dns_credentialSet_component_type:/         { ctype      = val($0) }
        s == SET && /dns_credentialSet_component_secret:/       { csecret    = tolower(val($0)) }
        s == SET && /dns_credentialSet_component_required:/     { crequired  = tolower(val($0)) }
        s == SET && /dns_credentialSet_component_picklistValue_friendlyName:/ { pfriendly = val($0) }
        s == SET && /dns_credentialSet_component_picklistValue_description:/  { pdesc     = val($0) }
        s == SET && /dns_credentialSet_component_picklistValue_value:/ {
            pv = val($0)
            pick = pick (pick == "" ? "" : ";") pfriendly "|" pdesc "|" pv
        }
        END { flushcomp() }
        function flushcomp() {
            if (arg != "") {
                print arg, cfriendly, cdesc, ctype, csecret, crequired, pick
                arg = ""
            }
        }
    ' "$yaml_file" > "$tmp_comp"

    if [ ! -s "$tmp_comp" ]; then
        printf 'ERROR: no components could be parsed for this credential set.\n' >&2
        printf 'Check %s for schema errors (expected key: dns_credentialSet_component_argumentName).\n' "$yaml_file" >&2
        exec 3<&- 2>/dev/null
        rm -f "$tmp_prov" "$tmp_sets" "$tmp_comp"; trap - INT TERM
        return 1
    fi

    # ======================================================================= #
    # 5. Collect the input for every component                                #
    # ======================================================================= #
    OUTPUT="dns_name=${dns_name}
dns_credentialSet_name=${set_name}"
    have_cert=0

    exec 3< "$tmp_comp"
    while IFS="$TAB" read -r arg cfriendly cdesc ctype csecret crequired pick <&3; do

        printf '\n--- %s (%s) ---\n' "$cfriendly" "$arg"
        [ -n "$cdesc" ] && printf '%s\n' "$cdesc"
        if [ "$crequired" = "true" ]; then
            printf 'This input is required.\n'
        else
            printf 'Optional - press Enter to skip.\n'
        fi

        value=""

        case "$ctype" in
            # ----------------------------------------------------------- #
            # certificate: collect PEM and key via nano                   #
            # ----------------------------------------------------------- #
            certificate)
                mkdir -p "$CERT_DIR"
                chmod 700 "$CERT_DIR"
                printf 'A text editor will open. Paste the CERTIFICATE (PEM), then save and exit (Ctrl+O, Enter, Ctrl+X).\n'
                printf 'Press Enter to open the editor...'
                read -r _dummy < /dev/tty
                touch "$CERT_DIR/host.pem" && chmod 600 "$CERT_DIR/host.pem"
                nano "$CERT_DIR/host.pem" < /dev/tty > /dev/tty 2>&1

                printf 'The editor will open again. Paste the PRIVATE KEY, then save and exit (Ctrl+O, Enter, Ctrl+X).\n'
                printf 'Press Enter to open the editor...'
                read -r _dummy < /dev/tty
                touch "$CERT_DIR/host.key" && chmod 600 "$CERT_DIR/host.key"
                nano "$CERT_DIR/host.key" < /dev/tty > /dev/tty 2>&1

                if [ "$crequired" = "true" ] && [ ! -s "$CERT_DIR/host.pem" ]; then
                    printf 'ERROR: required certificate was left empty. Aborting.\n' >&2
                    exec 3<&-
                    rm -f "$tmp_prov" "$tmp_sets" "$tmp_comp"; trap - INT TERM
                    return 1
                fi

                OUTPUT="${OUTPUT}
${arg}=./dns/credentials/certificate/host"
                have_cert=1
                continue
                ;;

            # ----------------------------------------------------------- #
            # picklist: numbered menu of the picklist values              #
            # ----------------------------------------------------------- #
            picklist)
                if [ -z "$pick" ]; then
                    printf 'WARNING: picklist without values, skipping.\n' >&2
                    continue
                fi
                i=0
                old_ifs=$IFS; IFS=';'
                for entry in $pick; do
                    IFS=$old_ifs
                    i=$((i + 1))
                    e_friendly="${entry%%|*}"
                    e_rest="${entry#*|}"
                    e_desc="${e_rest%%|*}"
                    printf '  %2d) %s\n      %s\n' "$i" "$e_friendly" "$e_desc"
                    IFS=';'
                done
                IFS=$old_ifs
                pick_count=$i

                while :; do
                    if [ "$crequired" = "true" ]; then
                        printf 'Select an option [1-%d]: ' "$pick_count"
                    else
                        printf 'Select an option [1-%d] (Enter to skip): ' "$pick_count"
                    fi
                    read -r answer < /dev/tty
                    if [ -z "$answer" ] && [ "$crequired" != "true" ]; then
                        value=""; break
                    fi
                    case "$answer" in
                        *[!0-9]*|'') printf 'Invalid selection.\n'; continue ;;
                    esac
                    if [ "$answer" -ge 1 ] && [ "$answer" -le "$pick_count" ]; then
                        entry="$(printf '%s' "$pick" | awk -v N="$answer" -F';' '{ print $N }')"
                        value="${entry##*|}"
                        break
                    fi
                    printf 'Invalid selection.\n'
                done
                ;;

            # ----------------------------------------------------------- #
            # string, email, url, integer: plain read                     #
            # ----------------------------------------------------------- #
            string|email|url|integer|*)
                while :; do
                    if [ "$csecret" = "true" ]; then
                        printf 'Your input will remain hidden.\n'
                        printf '%s: ' "$cfriendly"
                        stty -echo < /dev/tty
                        read -r value < /dev/tty
                        stty echo < /dev/tty
                        printf '\n'
                    else
                        printf '%s: ' "$cfriendly"
                        read -r value < /dev/tty
                    fi

                    if [ -z "$value" ]; then
                        if [ "$crequired" = "true" ]; then
                            printf 'This value can not be skipped.\n'
                            continue
                        fi
                        break
                    fi

                    if [ "$ctype" = "integer" ]; then
                        case "$value" in
                            *[!0-9]*)
                                printf 'Please enter a whole number.\n'
                                value=""; continue ;;
                        esac
                    fi
                    break
                done
                ;;
        esac

        # append one line per collected component (skipped optionals are omitted)
        if [ -n "$value" ]; then
            OUTPUT="${OUTPUT}
${arg}=${value}"
        fi
    done
    exec 3<&-

    # ======================================================================= #
    # 5b. DNS propagation check configuration                                 #
    #                                                                         #
    # The recursive-resolver (RNS) propagation check is ALWAYS suppressed:    #
    # local stub resolvers (e.g. systemd-resolved) negatively cache the       #
    # record and stall the check. The TXT record is verified against the      #
    # zone's authoritative servers instead. The resolver choice below is      #
    # used for DNS discovery (finding the authoritative servers, CNAME and    #
    # apex resolution).                                                       #
    # ======================================================================= #
    printf '\n--- DNS propagation check ---\n'
    printf 'Before validation, lego verifies that the challenge TXT record is\n'
    printf 'visible on the authoritative DNS servers of your zone.\n'
    printf 'Choose which DNS servers are used to resolve and discover them:\n\n'
    printf '  1) Authoritative DNS only (system resolvers for discovery)\n'
    printf '  2) Public DNS (Cloudflare 1.1.1.1 / Google 8.8.8.8)\n'
    printf '  3) Custom DNS servers\n\n'
    while :; do
        printf 'Select an option [1-3]: '
        read -r answer < /dev/tty
        case "$answer" in
            1|'')
                break
                ;;
            2)
                OUTPUT="${OUTPUT}
LEGO_DNS_RESOLVERS=1.1.1.1:53,8.8.8.8:53"
                break
                ;;
            3)
                while :; do
                    printf 'Custom DNS servers (comma-separated host:port): '
                    read -r resolvers < /dev/tty
                    case "$resolvers" in
                        '')
                            printf 'A custom server list can not be empty.\n' ;;
                        *[!]A-Za-z0-9.:,[-]*|*,,*|,*|*,)
                            printf 'Invalid server list (use host:port, comma-separated).\n' ;;
                        *)
                            OUTPUT="${OUTPUT}
LEGO_DNS_RESOLVERS=${resolvers}"
                            break ;;
                    esac
                done
                break
                ;;
            *) printf 'Invalid selection.\n' ;;
        esac
    done
    OUTPUT="${OUTPUT}
LEGO_DNS_PROPAGATION_DISABLE_RNS=true"
    unset resolvers

    # ======================================================================= #
    # 6. Write ../dns/credentials/host                                        #
    # ======================================================================= #
    mkdir -p "$CRED_DIR"
    chmod 700 "$CRED_DIR"
    umask_old="$(umask)"
    umask 077
    printf '%s\n' "$OUTPUT" > "$CRED_FILE"
    umask "$umask_old"
    chmod 600 "$CRED_FILE"

    printf '\nCredentials for "%s" written to %s\n' "$dns_friendly" "$CRED_FILE"
    [ "$have_cert" -eq 1 ] && printf 'Certificate material written to %s/host.pem and %s/host.key\n' "$CERT_DIR" "$CERT_DIR"

    rm -f "$tmp_prov" "$tmp_sets" "$tmp_comp"
    trap - INT TERM
    return 0
}

# ==============================================================================
# host certificate issuance + renewal
# ==============================================================================
# --------------------------------------------------------------------------- #
# internal: export all credential components from $CRED_FILE                  #
# sets: hdc_exported_vars, hdc_dns_provider                                   #
# --------------------------------------------------------------------------- #
_hdc_export_creds() {
    hdc_exported_vars=""
    hdc_dns_provider="$(awk -F'=' '$1 == "dns_name" { print $2; exit }' "$CRED_FILE")"
    if [ -z "$hdc_dns_provider" ]; then
        printf 'ERROR: dns_name missing in %s.\n' "$CRED_FILE" >&2
        return 1
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|'#'*|dns_name=*|dns_credentialSet_name=*) continue ;;
        esac
        key="${line%%=*}"
        case "$key" in
            *[!A-Za-z0-9_]*|'')
                printf 'WARNING: skipping malformed credential line (key: %s).\n' "$key" >&2
                continue
                ;;
        esac
        export "$key=${line#*=}"
        hdc_exported_vars="$hdc_exported_vars $key"
    done < "$CRED_FILE"
    unset line key

    if [ -z "$hdc_exported_vars" ]; then
        printf 'ERROR: no credential components found in %s.\n' "$CRED_FILE" >&2
        return 1
    fi

    # the recursive-resolver propagation check is always suppressed (local
    # stub resolvers negatively cache the record); credential files written
    # before this policy may lack the line, so default it here.
    if [ -z "$LEGO_DNS_PROPAGATION_DISABLE_RNS" ]; then
        export LEGO_DNS_PROPAGATION_DISABLE_RNS="true"
        hdc_exported_vars="$hdc_exported_vars LEGO_DNS_PROPAGATION_DISABLE_RNS"
    fi
    return 0
}

# --------------------------------------------------------------------------- #
# internal: unset the previously exported credential variables                #
# --------------------------------------------------------------------------- #
_hdc_unset_creds() {
    for key in $hdc_exported_vars; do
        unset "$key"
    done
    unset hdc_exported_vars key
}

# --------------------------------------------------------------------------- #
# internal: persist or replace a KEY=VALUE line in ../.env                    #
# --------------------------------------------------------------------------- #
_hdc_env_set() {
    _k="$1"; _v="$2"
    [ -f "$ENV_FILE" ] || : > "$ENV_FILE"
    _tmp="$(mktemp)" || return 1
    grep -v "^${_k}=" "$ENV_FILE" > "$_tmp" 2>/dev/null || true
    printf '%s=%s\n' "$_k" "$_v" >> "$_tmp"
    cat "$_tmp" > "$ENV_FILE"
    rm -f "$_tmp"
    unset _k _v _tmp
}

# --------------------------------------------------------------------------- #
# internal: prompt until a valid FQDN is entered; sets host_fqdn              #
# --------------------------------------------------------------------------- #
_hdc_read_fqdn() {
    while :; do
        printf 'Enter the fully qualified domain name of this host: '
        read -r answer < /dev/tty
        case "$answer" in
            *.*)
                case "$answer" in
                    *[!a-zA-Z0-9.-]*|-*|*-|.*|*.) printf 'Invalid domain name.\n' ;;
                    *) host_fqdn="$answer"; return 0 ;;
                esac
                ;;
            *)  printf 'Please enter a fully qualified domain name (host.example.com).\n' ;;
        esac
    done
}

# --------------------------------------------------------------------------- #
# main                                                                        #
# --------------------------------------------------------------------------- #
host_dns_certificate() {
    CRED_FILE="../dns/credentials/host"
    ENV_FILE="../.env"
    STORAGE_PATH="../certificateStorage/host"
    STAGING_URL="https://acme-staging-v02.api.letsencrypt.org/directory"
    CRON_FILE="/etc/cron.d/ssldeploy-renew"

    # --- locate lego (version is guaranteed by install_linux_dependencies) - #
    if command -v lego >/dev/null 2>&1; then
        LEGO_BIN="$(command -v lego)"
    else
        printf 'ERROR: lego binary not found. Run the dependency installation first.\n' >&2
        return 1
    fi

    if [ ! -f "$CRED_FILE" ]; then
        printf 'ERROR: %s not found. Run the credential setup first.\n' "$CRED_FILE" >&2
        return 1
    fi

    # ======================================================================= #
    # 1. Confirm (or change) the FQDN of this host                            #
    # ======================================================================= #
    # detect a *fully qualified* default: 'hostname -f' often returns only the
    # short hostname unless the resolver/hosts file is configured for FQDNs.
    # Fall back to assembling hostname + DNS domain; if the result is not a
    # valid FQDN (no dot / bad characters), offer no default and ask directly.
    host_fqdn="$(hostname -f 2>/dev/null)"
    case "$host_fqdn" in
        *.*) : ;;
        *)
            _h="$(hostname 2>/dev/null)"
            _d="$(hostname -d 2>/dev/null)"
            [ -z "$_d" ] && _d="$(dnsdomainname 2>/dev/null)"
            if [ -n "$_h" ] && [ -n "$_d" ]; then
                host_fqdn="${_h}.${_d}"
            else
                host_fqdn=""
            fi
            unset _h _d
            ;;
    esac
    # the default must pass the same validation as manual input
    case "$host_fqdn" in
        *.*)
            case "$host_fqdn" in
                *[!a-zA-Z0-9.-]*|-*|*-|.*|*.) host_fqdn="" ;;
            esac
            ;;
        *) host_fqdn="" ;;
    esac

    while :; do
        if [ -n "$host_fqdn" ]; then
            printf '\nThe certificate will be requested for: %s\n' "$host_fqdn"
            printf 'Is this fully qualified domain name correct? [Y/n]: '
            read -r answer < /dev/tty
            case "$answer" in
                ''|y|Y|yes|YES) break ;;
            esac
        fi
        _hdc_read_fqdn
        break
    done

    # --- ACME account e-mail ------------------------------------------------ #
    acme_email=""
    [ -f "$ENV_FILE" ] && acme_email="$(awk -F'=' '$1 == "ACME_EMAIL" { print $2; exit }' "$ENV_FILE")"
    while [ -z "$acme_email" ]; do
        printf 'E-mail address for the ACME account (expiry notices): '
        read -r answer < /dev/tty
        case "$answer" in
            *@*.*) acme_email="$answer" ;;
            *)     printf 'Please enter a valid e-mail address.\n' ;;
        esac
    done

    mkdir -p "$STORAGE_PATH"
    chmod 700 "$STORAGE_PATH"

    # ======================================================================= #
    # 2. Test issuance against the ACME staging directory                     #
    #    on failure -> offer to re-collect credentials and retry              #
    # ======================================================================= #
    while :; do
        _hdc_export_creds || return 1

        printf '\nTesting your DNS credentials against the Let'\''s Encrypt STAGING servers...\n'
        printf 'Provider: %s - Domain: %s\n\n' "$hdc_dns_provider" "$host_fqdn"

        # lego v5: all flags belong to the 'run' subcommand; --renew-force
        # guarantees a real DNS-01 challenge even if a previous staging
        # certificate still exists (otherwise 'run' would silently skip).
        "$LEGO_BIN" run \
            --accept-tos \
            --path "$STORAGE_PATH" \
            --email "$acme_email" \
            --dns "$hdc_dns_provider" \
            --domains "$host_fqdn" \
            --server "$STAGING_URL" \
            --always-deactivate-authorizations \
            --renew-force
        lego_rc=$?

        _hdc_unset_creds

        if [ "$lego_rc" -eq 0 ]; then
            printf '\nStaging test SUCCEEDED. Your DNS credentials are working.\n'
            break
        fi

        printf '\nStaging test FAILED (lego exit code %d).\n' "$lego_rc" >&2
        printf 'Common causes: wrong or under-privileged DNS credentials, or the\n' >&2
        printf 'domain does not belong to a zone the credentials can access.\n\n' >&2
        printf '  1) Re-enter the DNS credentials\n'
        printf '  2) Change the server name (currently: %s)\n' "$host_fqdn"
        printf '  3) Abort the host certificate setup\n\n'
        while :; do
            printf 'Select an option [1-3]: '
            read -r answer < /dev/tty
            case "$answer" in
                1)
                    if command -v collect_dns_credentials >/dev/null 2>&1; then
                        collect_dns_credentials || return 1
                    else
                        printf 'ERROR: collect_dns_credentials is not available in this shell.\n' >&2
                        return 1
                    fi
                    break
                    ;;
                2)
                    _hdc_read_fqdn
                    break
                    ;;
                3)
                    printf 'Aborting host certificate setup.\n' >&2
                    return "$lego_rc"
                    ;;
                *) printf 'Invalid selection.\n' ;;
            esac
        done
    done

    # ======================================================================= #
    # 2b. Keep the staging certificate or request a production one?           #
    # ======================================================================= #
    acme_server="$STAGING_URL"
    printf '\nA STAGING certificate for %s is now stored. It is NOT publicly trusted\n' "$host_fqdn"
    printf 'and only suitable for testing.\n\n'
    printf '  1) Keep the staging certificate (testing / development)\n'
    printf '  2) Request a production certificate now (publicly trusted)\n\n'
    while :; do
        printf 'Select an option [1-2]: '
        read -r answer < /dev/tty
        case "$answer" in
            1) break ;;
            2)
                _hdc_export_creds || return 1
                printf '\nRequesting a PRODUCTION certificate for %s...\n\n' "$host_fqdn"
                # The staging certificate must not be visible to lego during
                # the production request: lego would treat it as an ARI
                # renewal of the staging certificate, and the production CA
                # rejects the staging issuer ("Authority Key Identifier did
                # not match a known issuer"). Set the staging files aside so
                # this is a clean first issuance; restore them on failure.
                hdc_setaside="$STORAGE_PATH/.staging-setaside"
                rm -rf "$hdc_setaside"
                mkdir -p "$hdc_setaside"
                for f in "$STORAGE_PATH/certificates/$host_fqdn".*; do
                    [ -e "$f" ] && mv "$f" "$hdc_setaside/"
                done
                "$LEGO_BIN" run \
                    --accept-tos \
                    --path "$STORAGE_PATH" \
                    --email "$acme_email" \
                    --dns "$hdc_dns_provider" \
                    --domains "$host_fqdn" \
                    --always-deactivate-authorizations
                lego_rc=$?
                _hdc_unset_creds
                if [ "$lego_rc" -ne 0 ]; then
                    for f in "$hdc_setaside"/*; do
                        [ -e "$f" ] && mv "$f" "$STORAGE_PATH/certificates/"
                    done
                    rm -rf "$hdc_setaside"; unset hdc_setaside f
                    printf 'ERROR: production request failed (exit code %d).\n' "$lego_rc" >&2
                    printf 'The staging certificate has been restored and remains in place.\n' >&2
                    return "$lego_rc"
                fi
                rm -rf "$hdc_setaside"; unset hdc_setaside f
                acme_server="production"
                break
                ;;
            *) printf 'Invalid selection.\n' ;;
        esac
    done

    # ======================================================================= #
    # 3. Persist the settings needed for unattended renewal                   #
    # ======================================================================= #
    _hdc_env_set "ACME_EMAIL"  "$acme_email"
    _hdc_env_set "HOST_FQDN"   "$host_fqdn"
    _hdc_env_set "ACME_SERVER" "$acme_server"

    chmod 600 "$STORAGE_PATH/certificates/$host_fqdn.key" 2>/dev/null

    # stable filenames for the application / web server configuration:
    # lego always writes <fqdn>.crt/.key (renew depends on those names), so
    # host.crt/host.key are maintained as symlinks that follow every renewal.
    ln -sf "$host_fqdn.crt" "$STORAGE_PATH/certificates/host.crt"
    ln -sf "$host_fqdn.key" "$STORAGE_PATH/certificates/host.key"

    # the ACME certificate resource (<fqdn>.json) must stay in certificates/
    # for lego renew to find it; expose it under a stable name as a symlink.
    mkdir -p "$STORAGE_PATH/acme-configurations"
    chmod 700 "$STORAGE_PATH/acme-configurations"
    ln -sf "../certificates/$host_fqdn.json" "$STORAGE_PATH/acme-configurations/host.json"

    printf '\nCertificate stored:\n'
    printf '  Certificate: %s/certificates/host.crt\n' "$STORAGE_PATH"
    printf '  Private key: %s/certificates/host.key\n' "$STORAGE_PATH"

    # ======================================================================= #
    # 4. Daily renewal cron job (invokes lego directly for the host)          #
    # ======================================================================= #
    app_root="$(CDPATH= cd -- .. && pwd)"
    lego_abs="$LEGO_BIN"
    case "$lego_abs" in ../*) lego_abs="$app_root/${LEGO_BIN#../}" ;; esac

    storage_abs="$app_root/certificateStorage/host"
    cred_abs="$app_root/dns/credentials/host"

    if [ "$acme_server" = "production" ]; then
        server_arg=""
    else
        server_arg=" --server $STAGING_URL"
    fi

    # the credentials file is sourced with allexport so every KEY=VALUE line
    # (provider credentials, LEGO_* settings) reaches lego as environment.
    # lego v5 'run' issues or renews; ARI decides when a renewal is due,
    # --renew-days 30 is the fallback threshold if ARI is unavailable.
    renew_cmd="set -a; . $cred_abs; set +a; $lego_abs run --accept-tos --path $storage_abs --email $acme_email --dns $hdc_dns_provider --domains $host_fqdn$server_arg --always-deactivate-authorizations --renew-days 30"

    # random minute so not every install hits the CA at the same time
    cron_min="$(awk 'BEGIN { srand(); print int(rand() * 60) }')"

    # the installer is always executed by the flask user - renewals run as it
    cron_user="$(whoami)"
    if [ "$cron_user" = "root" ]; then
        cron_log="/var/log/ssldeploy-renew.log"
    else
        cron_log="$app_root/ssldeploy-renew.log"
    fi

    if [ "$(id -u)" -eq 0 ] && [ -d /etc/cron.d ]; then
        printf '# ssldeploy host certificate renewal (generated)\n%s 3 * * * %s %s >> %s 2>&1\n' \
            "$cron_min" "$cron_user" "$renew_cmd" "$cron_log" > "$CRON_FILE"
        chmod 644 "$CRON_FILE"
        printf '\nRenewal cron job installed: %s (daily at 03:%02d, runs as %s)\n' "$CRON_FILE" "$cron_min" "$cron_user"
    elif command -v crontab >/dev/null 2>&1; then
        # replace any previous ssldeploy host renewal entry, then append
        ( crontab -l 2>/dev/null | grep -vF "$storage_abs"
          printf '%s 3 * * * %s >> %s 2>&1\n' \
              "$cron_min" "$renew_cmd" "$cron_log" ) | crontab -
        printf '\nRenewal cron job installed in the crontab of %s (daily at 03:%02d).\n' "$cron_user" "$cron_min"
    else
        printf '\nWARNING: no cron facility found. Schedule this daily yourself:\n  %s\n' "$renew_cmd" >&2
    fi

    unset renew_cmd server_arg storage_abs cred_abs lego_abs app_root
    return 0
}

# =============================================================================
# entry point for install.sh
# =============================================================================
host_certificate_request() {
    collect_dns_credentials || return 1
    host_dns_certificate
}