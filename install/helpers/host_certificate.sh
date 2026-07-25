#!/bin/sh
# =============================================================================
# ssldeploy - DNS provider credential collection
#
# Executed from: ssldeploy/install/
# Reads:         ../dns/configurations/*.yaml
# Writes:        ../dns/credentials/host
#                ../dns/credentials/certificates/host.pem
#                ../dns/credentials/certificates/host.key
#
# POSIX sh compatible (dash, bash, busybox ash) -> runs on Debian, Ubuntu,
# RHEL, Arch, Alpine and SUSE without bash-only features. Only awk, stty,
# mktemp and nano are required (all available via base/coreutils packages).
# =============================================================================

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
        s == SET && /dns_credentialSet_component_argumentName:/ {
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

    # ======================================================================= #
    # 5. Collect the input for every component                                #
    # ======================================================================= #
    OUTPUT="dns_name=${dns_name}"
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
    # 6. Write ../dns/credentials/host                                        #
    # ======================================================================= #
    mkdir -p "$CRED_DIR"
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