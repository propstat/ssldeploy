#!/bin/sh
# Source this file: . ./helpers/openbao_configuration.sh
#
# Public entry points:
#   openbao_deployment_notice   - explain the two modes (print before prompting)
#   openbao_local_installation  - install and configure OpenBao on this host
#   openbao_remote_installation - configure against an OpenBao on another host
#   openbao_print_policies      - emit the definitions an external OpenBao
#                                 administrator needs (delegated deployments)
#
# The two installation entry points are independent and mutually exclusive, so
# install.sh can branch with confirm_continue:
#
#   openbao_deployment_notice
#   confirm_continue -y \
#       -startmsg="Do you want to run OpenBao on this host?" \
#       -endmsg="OpenBao configuration complete." \
#       on_yes="openbao_local_installation || exit 1" \
#       on_no="openbao_remote_installation || exit 1"
#
# Runs AFTER install_linux_dependencies and BEFORE host_certificate_request
# (which reads DNS credentials from the vault configured here). This file owns
# the OpenBao binary end to end - install_linux_dependencies.sh does NOT touch
# OpenBao.
#
# Both entry points converge on the same result: two AppRole identities on
# disk, and openbaoDeployment / openbaoAddress / openbaoCaCert / openbaoMount
# written to ../.env.
#
#   ../openbao/credentials/create/  - Flask web UI  (create/update/delete)
#   ../openbao/credentials/read/    - cron renewal  (read only)
#
# POSIX sh only - note that "read -s" is a bash/zsh extension and is NOT used;
# echo suppression goes through stty against /dev/tty. External dependencies:
# awk, stty, mktemp, tar, coreutils.

# --------------------------------------------------------------------------- #
# internal: persist or replace a KEY=VALUE line in ../.env                     #
# --------------------------------------------------------------------------- #
_obc_env_set() {
    _k="$1"; _v="$2"
    [ -f "$OBC_ENV_FILE" ] || : > "$OBC_ENV_FILE"
    _tmp="$(mktemp)" || return 1
    grep -v "^${_k}=" "$OBC_ENV_FILE" > "$_tmp" 2>/dev/null || true
    printf '%s=%s\n' "$_k" "$_v" >> "$_tmp"
    cat "$_tmp" > "$OBC_ENV_FILE"
    rm -f "$_tmp"
    unset _k _v _tmp
}

# --------------------------------------------------------------------------- #
# internal: read a KEY from ../.env (empty when absent)                        #
# --------------------------------------------------------------------------- #
_obc_env_get() {
    [ -f "$OBC_ENV_FILE" ] || return 0
    grep "^${1}=" "$OBC_ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '\r'
}

# --------------------------------------------------------------------------- #
# internal: prompt for a secret without echoing it                             #
#           sets obc_secret; caller must unset it                              #
#                                                                              #
# stty is pointed at /dev/tty explicitly. Without the redirect it acts on      #
# stdin, which is not the terminal when the installer is driven from a pipe -  #
# the error is then swallowed and the secret echoes in clear text. The INT     #
# trap restores echo if the user interrupts mid-prompt, so Ctrl-C does not     #
# leave the terminal silently broken.                                          #
# --------------------------------------------------------------------------- #
_obc_read_secret() {
    printf '%s' "$1"
    stty -echo < /dev/tty 2>/dev/null
    trap 'stty echo < /dev/tty 2>/dev/null; trap - INT; return 130' INT
    read -r obc_secret < /dev/tty
    trap - INT
    stty echo < /dev/tty 2>/dev/null
    printf '\n'
}

# --------------------------------------------------------------------------- #
# internal: shared setup - paths, service identity, privilege escalation       #
#           called first by both installation entry points                     #
# --------------------------------------------------------------------------- #
_obc_context() {
    OBC_ENV_FILE="../.env"
    OBC_CRED_DIR="../openbao/credentials"
    OBC_CONF_DIR="/etc/ssldeploy"
    OBC_CONF_FILE="/etc/ssldeploy/openbao.hcl"
    OBC_UNSEAL_KEY="/etc/ssldeploy/unseal.key"
    OBC_UNSEAL_HOOK="/etc/ssldeploy/unseal.sh"
    OBC_DATA_DIR="/var/lib/openbao"
    OBC_SYSTEM_FILE="/usr/local/bin/bao"
    OBC_SVC_USER="openbao"
    OBC_FLASK_USER="$(whoami)"
    OBC_PROVISION="self"

    OBC_SUDO=""
    if [ "$(id -u)" -ne 0 ]; then
        if command -v sudo >/dev/null 2>&1; then
            OBC_SUDO="sudo"
        elif command -v doas >/dev/null 2>&1; then
            OBC_SUDO="doas"
        else
            printf 'ERROR: sudo or doas required but not installed.\n' >&2
            return 1
        fi
    fi

    return 0
}

# --------------------------------------------------------------------------- #
# internal: release the shared variables                                       #
#           called last by both installation entry points                      #
# --------------------------------------------------------------------------- #
_obc_cleanup() {
    unset OBC_ENV_FILE OBC_CRED_DIR OBC_CONF_DIR OBC_CONF_FILE
    unset OBC_UNSEAL_KEY OBC_UNSEAL_HOOK OBC_DATA_DIR
    unset OBC_SYSTEM_FILE OBC_SVC_USER OBC_FLASK_USER OBC_SUDO
    unset OBC_DEPLOYMENT OBC_ADDRESS OBC_CACERT OBC_MOUNT OBC_PROVISION
    unset OBC_VERSION OBC_ARCHIVE_NAME OBC_TOOL_DIR
    unset OBC_ARCHIVE_FILE OBC_BINARY_FILE OBC_URL OBC_PINNED_SHA
    unset BAO_TOKEN
    unset answer
    return 0
}

# --------------------------------------------------------------------------- #
# internal: download, verify and install the pinned OpenBao binary             #
#                                                                              #
# Needed by BOTH entry points: the CLI is the only jq-free way to read a       #
# single secret field from a shell script, so it is installed even when the    #
# vault itself lives on another machine.                                       #
# --------------------------------------------------------------------------- #
_obc_install_binary() {
    printf 'Installing OpenBao...\n'

    if [ ! -f ./.install ]; then
        printf 'ERROR: ./.install missing\n' >&2
        return 1
    fi

    if [ ! -f ./.checksums ]; then
        printf 'ERROR: ./.checksums missing\n' >&2
        return 1
    fi

    OBC_VERSION=$(grep '^supported_openbao=' ./.install | cut -d '=' -f2 | tr -d '\r"'\''')

    if [ -z "$OBC_VERSION" ]; then
        printf 'ERROR: OpenBao version not defined in ./.install\n' >&2
        return 1
    fi

    # Idempotent: same policy as lego. A distro-packaged bao is left in place;
    # /usr/local/bin precedes /usr/bin in PATH so the pinned build wins.
    if bao version 2>/dev/null | grep -q "v${OBC_VERSION}"; then
        printf 'OpenBao %s already installed, skipping download.\n' "$OBC_VERSION"
        return 0
    fi

    # -------------------------
    # Determine artifact
    # -------------------------
    _arch=$(uname -m)

    case "$_arch" in
        x86_64|amd64)  _arch="amd64" ;;
        aarch64|arm64) _arch="arm64" ;;
        *)
            # Upstream also publishes armv6, ppc64le, riscv64 and s390x
            # builds; add them here and to ./.checksums if ever needed.
            printf 'ERROR: unsupported arch: %s\n' "$_arch" >&2
            unset _arch
            return 1
            ;;
    esac

    _os="$(uname -s)"

    case "$_os" in
        Linux)  _os="linux"  ;;
        Darwin) _os="darwin" ;;
        *)
            printf 'ERROR: unsupported OS: %s\n' "$_os" >&2
            unset _arch _os
            return 1
            ;;
    esac

    # Upstream names the archive openbao_<ver>_<os>_<arch>.tar.gz. The binary
    # inside is called "bao". Note the openbao-hsm_* artifacts published
    # alongside: the trailing anchor in the checksum grep below keeps those
    # and the .sbom.json siblings from matching.
    OBC_ARCHIVE_NAME="openbao_${OBC_VERSION}_${_os}_${_arch}.tar.gz"

    unset _arch _os

    # -------------------------
    # Download locations
    # -------------------------
    OBC_TOOL_DIR="../tools/openbao"
    OBC_ARCHIVE_FILE="$OBC_TOOL_DIR/$OBC_ARCHIVE_NAME"
    OBC_BINARY_FILE="$OBC_TOOL_DIR/bao"
    OBC_URL="https://github.com/openbao/openbao/releases/download/v${OBC_VERSION}/${OBC_ARCHIVE_NAME}"

    mkdir -p "$OBC_TOOL_DIR" || return 1

    # -------------------------
    # Resolve the pinned checksum BEFORE downloading
    # -------------------------
    # The pin in ./.checksums is the trust anchor: it is version-controlled,
    # so nothing fetched at install time is trusted on its own. A missing pin
    # is a hard failure, never a silent skip.
    OBC_PINNED_SHA=$(grep " ${OBC_ARCHIVE_NAME}$" ./.checksums | awk '{print $1}')

    if [ -z "$OBC_PINNED_SHA" ]; then
        printf 'ERROR: no pinned checksum for %s in ./.checksums\n' "$OBC_ARCHIVE_NAME" >&2
        printf 'Add it before installing (see upstream checksums.txt).\n' >&2
        return 1
    fi

    # -------------------------
    # Download archive
    # -------------------------
    printf 'Version: %s\n' "$OBC_VERSION"
    printf 'OPENBAO URL: %s\n' "$OBC_URL"
    rm -f "$OBC_ARCHIVE_FILE"

    if command -v curl >/dev/null 2>&1; then
        curl -fL -o "$OBC_ARCHIVE_FILE" "$OBC_URL" || return 1
    else
        wget -O "$OBC_ARCHIVE_FILE" "$OBC_URL" || return 1
    fi

    # -------------------------
    # Verify against the pinned checksum
    # -------------------------
    printf 'Verifying checksum against pin...\n'

    if command -v sha256sum >/dev/null 2>&1; then
        _actual=$(sha256sum "$OBC_ARCHIVE_FILE" | awk '{print $1}')
    else
        _actual=$(shasum -a 256 "$OBC_ARCHIVE_FILE" | awk '{print $1}')
    fi

    if [ "$OBC_PINNED_SHA" != "$_actual" ]; then
        printf 'ERROR: checksum mismatch against pinned value\n' >&2
        rm -f "$OBC_ARCHIVE_FILE"
        unset _actual
        return 1
    fi

    unset _actual
    printf 'Pinned checksum verified.\n'

    # -------------------------
    # Optional: GPG signature of upstream checksums.txt
    # -------------------------
    # Runs only when gpg AND the repo-vendored public key are both present.
    # The key must come from the repo - fetching it from openbao.org at
    # install time would trust the same origin as the artifact it vouches
    # for. Skipped (not failed) when gpg is absent, because the pin above
    # already gates the install. To make this mandatory, add gnupg to the
    # package lists in install_linux_dependencies.sh (gnupg on Debian/Arch/
    # Alpine, gnupg2 on RHEL, gpg2 on SUSE) and turn the skip into a return 1.
    _gpg_key="./keys/openbao-gpg-pub.asc"
    _gpg_bin=""

    if command -v gpg2 >/dev/null 2>&1; then
        _gpg_bin="gpg2"
    elif command -v gpg >/dev/null 2>&1; then
        _gpg_bin="gpg"
    fi

    if [ -n "$_gpg_bin" ] && [ -f "$_gpg_key" ]; then
        printf 'Verifying upstream signature...\n'

        _sum_url="https://github.com/openbao/openbao/releases/download/v${OBC_VERSION}/checksums.txt"
        _sig_url="${_sum_url}.gpgsig"
        _sum_file="/tmp/openbao.sha256"
        _sig_file="/tmp/openbao.sha256.gpgsig"
        _gnupghome="$(mktemp -d)" || return 1
        chmod 700 "$_gnupghome"

        if curl -fsSL "$_sum_url" -o "$_sum_file" 2>/dev/null && \
           curl -fsSL "$_sig_url" -o "$_sig_file" 2>/dev/null; then

            if ! GNUPGHOME="$_gnupghome" "$_gpg_bin" --batch --quiet \
                    --import "$_gpg_key"; then
                printf 'ERROR: could not import vendored OpenBao public key\n' >&2
                rm -rf "$_gnupghome"
                rm -f "$OBC_ARCHIVE_FILE" "$_sum_file" "$_sig_file"
                return 1
            fi

            if ! GNUPGHOME="$_gnupghome" "$_gpg_bin" --batch --quiet \
                    --verify "$_sig_file" "$_sum_file" 2>/dev/null; then
                printf 'ERROR: signature verification of checksums.txt failed\n' >&2
                rm -rf "$_gnupghome"
                rm -f "$OBC_ARCHIVE_FILE" "$_sum_file" "$_sig_file"
                return 1
            fi

            _upstream=$(grep " ${OBC_ARCHIVE_NAME}$" "$_sum_file" | awk '{print $1}')

            if [ "$_upstream" != "$OBC_PINNED_SHA" ]; then
                printf 'ERROR: signed upstream checksum disagrees with ./.checksums\n' >&2
                printf 'Upstream: %s\n' "$_upstream" >&2
                printf 'Pinned:   %s\n' "$OBC_PINNED_SHA" >&2
                rm -rf "$_gnupghome"
                rm -f "$OBC_ARCHIVE_FILE" "$_sum_file" "$_sig_file"
                unset _upstream
                return 1
            fi

            unset _upstream
            printf 'Signature verified, pin matches upstream.\n'
        else
            printf 'Warning: could not fetch checksums.txt or its signature.\n' >&2
            printf 'Continuing on the pinned checksum alone.\n' >&2
        fi

        rm -rf "$_gnupghome"
        rm -f "$_sum_file" "$_sig_file"
        unset _gnupghome _sum_url _sig_url _sum_file _sig_file
    else
        printf 'Skipping signature check (gpg or vendored key unavailable).\n'
    fi

    unset _gpg_key _gpg_bin

    # -------------------------
    # Extract binary
    # -------------------------
    printf 'Extracting OpenBao binary...\n'

    rm -f "$OBC_BINARY_FILE"

    tar -xzf "$OBC_ARCHIVE_FILE" -C "$OBC_TOOL_DIR" bao || return 1

    chmod +x "$OBC_BINARY_FILE" || return 1

    rm -f "$OBC_ARCHIVE_FILE"

    # -------------------------
    # Install system-wide
    # -------------------------
    printf 'Installing OpenBao system-wide...\n'

    $OBC_SUDO install -m 0755 "$OBC_BINARY_FILE" "$OBC_SYSTEM_FILE" || return 1

    # -------------------------
    # Runtime check
    # -------------------------
    # Upstream publishes no musl build. On Alpine a glibc-linked binary fails
    # here rather than much later as a confusing "not found" from cron.
    if ! "$OBC_SYSTEM_FILE" version >/dev/null 2>&1; then
        printf 'ERROR: %s will not execute on this system.\n' "$OBC_SYSTEM_FILE" >&2
        printf 'Likely a libc mismatch. On Alpine, install the distro package\n' >&2
        printf 'instead: apk add openbao openbao-openrc\n' >&2
        $OBC_SUDO rm -f "$OBC_SYSTEM_FILE"
        return 1
    fi

    printf 'OpenBao installed: %s\n' "$OBC_SYSTEM_FILE"
    return 0
}

# --------------------------------------------------------------------------- #
# internal: prompt for the KV mount and export the client environment          #
# --------------------------------------------------------------------------- #
_obc_prompt_mount() {
    printf 'KV mount point [ssldeploy]: '
    read -r answer < /dev/tty
    OBC_MOUNT="${answer:-ssldeploy}"

    BAO_ADDR="$OBC_ADDRESS"
    export BAO_ADDR

    if [ -n "$OBC_CACERT" ]; then
        BAO_CACERT="$OBC_CACERT"
        export BAO_CACERT
    fi

    return 0
}

# --------------------------------------------------------------------------- #
# internal: wait until the vault API answers, or fail                          #
# --------------------------------------------------------------------------- #
_obc_wait_api() {
    _tries=0
    while [ "$_tries" -lt 30 ]; do
        bao status >/dev/null 2>&1
        _rc=$?
        # 0 = unsealed, 2 = sealed. Both mean the listener answered.
        if [ "$_rc" -eq 0 ] || [ "$_rc" -eq 2 ]; then
            unset _tries _rc
            return 0
        fi
        _tries=$((_tries + 1))
        sleep 1
    done
    unset _tries _rc
    printf 'ERROR: OpenBao at %s did not respond within 30s.\n' "$BAO_ADDR" >&2
    return 1
}

# --------------------------------------------------------------------------- #
# internal: create the system user, data dir and configuration (local only)    #
# --------------------------------------------------------------------------- #
_obc_local_provision() {
    printf 'Creating OpenBao system user and directories...\n'

    # useradd is absent on Alpine (adduser) - try both.
    if ! id "$OBC_SVC_USER" >/dev/null 2>&1; then
        if command -v useradd >/dev/null 2>&1; then
            $OBC_SUDO useradd --system --home-dir "$OBC_DATA_DIR" \
                --shell /sbin/nologin "$OBC_SVC_USER" || return 1
        elif command -v adduser >/dev/null 2>&1; then
            $OBC_SUDO adduser -S -H -h "$OBC_DATA_DIR" \
                -s /sbin/nologin "$OBC_SVC_USER" || return 1
        else
            printf 'ERROR: neither useradd nor adduser is available.\n' >&2
            return 1
        fi
    fi

    $OBC_SUDO mkdir -p "$OBC_DATA_DIR" "$OBC_CONF_DIR" || return 1
    $OBC_SUDO chown "$OBC_SVC_USER":"$OBC_SVC_USER" "$OBC_DATA_DIR" || return 1
    $OBC_SUDO chmod 700 "$OBC_DATA_DIR" || return 1
    $OBC_SUDO chmod 755 "$OBC_CONF_DIR" || return 1

    # The listener binds to loopback with TLS disabled ON PURPOSE. ssldeploy
    # exists to obtain certificates; requiring a valid certificate before the
    # vault can start would be circular, and a self-signed one adds trust
    # plumbing without adding trust. Traffic never leaves the host. A vault
    # that must be reachable over the network belongs in remote mode, behind
    # a properly certified listener managed by its own operator.
    printf 'Writing %s...\n' "$OBC_CONF_FILE"

    _tmp="$(mktemp)" || return 1
    cat > "$_tmp" <<EOF
ui = false

storage "file" {
  path = "$OBC_DATA_DIR"
}

listener "tcp" {
  address     = "127.0.0.1:8200"
  tls_disable = 1
}

# mlock requires CAP_IPC_LOCK, which is not portable across the six supported
# distributions (notably OpenRC on Alpine). Swap is instead constrained by the
# service definition on systemd; on Alpine, disable or encrypt swap manually.
disable_mlock = true
EOF

    $OBC_SUDO install -m 0644 -o root -g root "$_tmp" "$OBC_CONF_FILE" || return 1
    rm -f "$_tmp"
    unset _tmp

    return 0
}

# --------------------------------------------------------------------------- #
# internal: write the unseal hook (local only)                                 #
#           root-owned, never readable by the Flask user                       #
# --------------------------------------------------------------------------- #
_obc_local_unseal_hook() {
    printf 'Installing unseal hook...\n'

    _tmp="$(mktemp)" || return 1
    cat > "$_tmp" <<EOF
#!/bin/sh
# ssldeploy OpenBao unseal hook - invoked by the service manager as root.
# Never called by cron and never by the Flask user.
BAO_ADDR="$OBC_ADDRESS"
export BAO_ADDR

KEY_FILE="$OBC_UNSEAL_KEY"

# A missing key is fatal, not a no-op. Exiting 0 here would let the service
# manager report the unit as healthy while the vault sits sealed, and nothing
# would complain until a renewal failed weeks later.
if [ ! -r "\$KEY_FILE" ]; then
    echo "ssldeploy: unseal key \$KEY_FILE missing or unreadable" >&2
    exit 1
fi

# The service manager reports the process as started before the listener is
# accepting connections. Retry briefly rather than racing it.
tries=0
while [ "\$tries" -lt 30 ]; do
    $OBC_SYSTEM_FILE status >/dev/null 2>&1
    rc=\$?
    [ "\$rc" -eq 0 ] && exit 0
    [ "\$rc" -eq 2 ] && break
    tries=\$((tries + 1))
    sleep 1
done

# Propagate the exit code: a non-zero ExecStartPost marks the unit failed,
# which is exactly the visibility wanted here.
$OBC_SYSTEM_FILE operator unseal -non-interactive "\$(cat "\$KEY_FILE")" >/dev/null
exit \$?
EOF

    $OBC_SUDO install -m 0700 -o root -g root "$_tmp" "$OBC_UNSEAL_HOOK" || return 1
    rm -f "$_tmp"
    unset _tmp

    return 0
}

# --------------------------------------------------------------------------- #
# internal: write and enable the service definition (local only)               #
# --------------------------------------------------------------------------- #
_obc_local_service() {
    if command -v systemctl >/dev/null 2>&1; then
        printf 'Installing systemd unit...\n'

        _tmp="$(mktemp)" || return 1
        cat > "$_tmp" <<EOF
[Unit]
Description=OpenBao (ssldeploy)
Documentation=https://openbao.org/docs/
After=network-online.target
Wants=network-online.target
ConditionFileNotEmpty=$OBC_CONF_FILE

[Service]
User=$OBC_SVC_USER
Group=$OBC_SVC_USER
ExecStart=$OBC_SYSTEM_FILE server -config=$OBC_CONF_FILE
ExecReload=/bin/kill --signal HUP \$MAINPID
ExecStartPost=$OBC_UNSEAL_HOOK
KillSignal=SIGINT
Restart=on-failure
RestartSec=5
# Upstream hardening: keep vault memory out of swap.
MemorySwapMax=0
NoNewPrivileges=yes
ProtectSystem=full
ProtectHome=read-only
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF

        $OBC_SUDO install -m 0644 -o root -g root "$_tmp" \
            /etc/systemd/system/openbao.service || return 1
        rm -f "$_tmp"
        unset _tmp

        $OBC_SUDO systemctl daemon-reload || return 1
        $OBC_SUDO systemctl enable openbao >/dev/null 2>&1 || return 1
        $OBC_SUDO systemctl restart openbao || return 1

    elif command -v rc-update >/dev/null 2>&1; then
        printf 'Installing OpenRC service...\n'

        _tmp="$(mktemp)" || return 1
        cat > "$_tmp" <<EOF
#!/sbin/openrc-run

name="openbao"
description="OpenBao (ssldeploy)"
command="$OBC_SYSTEM_FILE"
command_args="server -config=$OBC_CONF_FILE"
command_user="$OBC_SVC_USER:$OBC_SVC_USER"
command_background="yes"
pidfile="/run/openbao.pid"

depend() {
    need net
}

start_post() {
    $OBC_UNSEAL_HOOK || return 1
}
EOF

        $OBC_SUDO install -m 0755 -o root -g root "$_tmp" \
            /etc/init.d/openbao || return 1
        rm -f "$_tmp"
        unset _tmp

        $OBC_SUDO rc-update add openbao default >/dev/null 2>&1 || return 1
        $OBC_SUDO rc-service openbao restart || return 1

    else
        printf 'ERROR: neither systemd nor OpenRC found; cannot manage the service.\n' >&2
        return 1
    fi

    return 0
}

# --------------------------------------------------------------------------- #
# internal: initialise and unseal a local vault                                #
#           sets obc_token; caller must unset it                               #
# --------------------------------------------------------------------------- #
_obc_local_init() {
    _obc_wait_api || return 1

    if bao status 2>/dev/null | grep -q 'Initialized.*true'; then
        printf '\nThis vault is already initialised.\n'
        _obc_read_secret 'Enter a token with privileges to create policies and roles: '
        obc_token="$obc_secret"
        unset obc_secret
        [ -n "$obc_token" ] || {
            printf 'ERROR: a token is required.\n' >&2
            return 1
        }
        return 0
    fi

    printf '\nInitialising the vault...\n'

    # One key share, not a quorum. A 3-of-5 threshold whose shares all live in
    # one file on one disk is not a quorum - it is one secret split across more
    # lines. Be honest about the trust model instead.
    _init_out="$(mktemp)" || return 1
    chmod 600 "$_init_out"

    if ! bao operator init -key-shares=1 -key-threshold=1 > "$_init_out" 2>&1; then
        printf 'ERROR: vault initialisation failed:\n' >&2
        cat "$_init_out" >&2
        rm -f "$_init_out"
        return 1
    fi

    _unseal_key=$(grep -i 'Unseal Key 1:' "$_init_out" | awk '{print $NF}')
    obc_token=$(grep -i 'Initial Root Token:' "$_init_out" | awk '{print $NF}')

    rm -f "$_init_out"
    unset _init_out

    if [ -z "$_unseal_key" ] || [ -z "$obc_token" ]; then
        printf 'ERROR: could not parse the initialisation output.\n' >&2
        unset _unseal_key
        return 1
    fi

    # Root-owned, mode 0400, deliberately NOT the Flask user: a compromised
    # Flask process can talk to the API under its AppRole policy, but cannot
    # unseal and cannot decrypt a stolen data directory.
    printf 'Storing the unseal key...\n'

    _tmp="$(mktemp)" || return 1
    printf '%s\n' "$_unseal_key" > "$_tmp"
    $OBC_SUDO install -m 0400 -o root -g root "$_tmp" "$OBC_UNSEAL_KEY" || return 1
    rm -f "$_tmp"
    unset _tmp

    printf 'Unsealing...\n'
    bao operator unseal -non-interactive "$_unseal_key" >/dev/null || return 1

    unset _unseal_key
    return 0
}

# --------------------------------------------------------------------------- #
# internal: collect credentials for a remote vault                             #
#           sets OBC_PROVISION to self|delegated                               #
# --------------------------------------------------------------------------- #
_obc_remote_credentials() {
    cat << 'EOF'

--- Remote credential provisioning ---

[1] Self-service   You supply a token with privileges to create the KV mount,
                   the policies and the AppRoles. This installer provisions
                   everything. The token is used in memory and never written
                   to disk.

[2] Delegated      Your OpenBao administrator has already created the mount,
                   the ssldeploy-create and ssldeploy-read policies, and the
                   matching AppRoles. You supply only the role_id and
                   secret_id for each. No privileged token is needed on this
                   host. Choose this if you do not administer the vault.
                   Run openbao_print_policies to produce the instructions
                   your administrator needs.

EOF

    while :; do
        printf 'Select [1-2]: '
        read -r answer < /dev/tty
        case "$answer" in
            1) OBC_PROVISION="self"      ; break ;;
            2) OBC_PROVISION="delegated" ; break ;;
            *) printf 'Invalid selection.\n' ;;
        esac
    done

    if [ "$OBC_PROVISION" = "self" ]; then
        _obc_read_secret 'Token with policy/role creation privileges: '
        obc_token="$obc_secret"
        unset obc_secret
        [ -n "$obc_token" ] || {
            printf 'ERROR: a token is required.\n' >&2
            return 1
        }
        return 0
    fi

    # --- delegated: collect one credential pair per role ------------------ #
    mkdir -p "$OBC_CRED_DIR" || return 1
    chmod 700 "$OBC_CRED_DIR" || return 1

    _obc_collect_pair ssldeploy-create "$OBC_CRED_DIR/create" || return 1
    _obc_collect_pair ssldeploy-read   "$OBC_CRED_DIR/read"   || return 1
    return 0
}

# --------------------------------------------------------------------------- #
# internal: collect and store one AppRole credential pair                      #
#           $1 = role name (display only), $2 = credential directory           #
# --------------------------------------------------------------------------- #
_obc_collect_pair() {
    _role="$1"
    _dir="$2"

    printf '\nCredentials for %s\n' "$_role"

    # role_id is an identifier, not a secret - echo it so typos are visible.
    while :; do
        printf '  role_id: '
        read -r _role_id < /dev/tty
        [ -n "$_role_id" ] && break
        printf '  role_id cannot be empty.\n'
    done

    printf '  Is the secret_id response-wrapped? [y/N]: '
    read -r answer < /dev/tty

    case "$answer" in
        y|Y)
            # Single-use, short-TTL delivery. If the unwrap fails because the
            # token was already consumed, the secret was intercepted - treat
            # that as a security event, not a typo.
            _obc_read_secret '  wrapping token: '
            _secret_id=$(bao unwrap -field=secret_id "$obc_secret" 2>/dev/null)
            unset obc_secret
            if [ -z "$_secret_id" ]; then
                printf 'ERROR: could not unwrap. If the token was valid and\n' >&2
                printf 'unused, this means it has already been consumed by\n' >&2
                printf 'someone else. Ask for a new one and investigate.\n' >&2
                unset _role _dir _role_id _secret_id
                return 1
            fi
            ;;
        *)
            _obc_read_secret '  secret_id: '
            _secret_id="$obc_secret"
            unset obc_secret
            ;;
    esac

    if [ -z "$_secret_id" ]; then
        printf 'ERROR: secret_id cannot be empty.\n' >&2
        unset _role _dir _role_id _secret_id
        return 1
    fi

    mkdir -p "$_dir" || return 1
    chmod 700 "$_dir" || return 1

    printf '%s\n' "$_role_id"   > "$_dir/role_id"   || return 1
    printf '%s\n' "$_secret_id" > "$_dir/secret_id" || return 1

    chmod 600 "$_dir/role_id" "$_dir/secret_id" || return 1
    chown "$OBC_FLASK_USER":"$OBC_FLASK_USER" \
        "$_dir" "$_dir/role_id" "$_dir/secret_id" 2>/dev/null || true

    unset _role _dir _role_id _secret_id
    return 0
}

# --------------------------------------------------------------------------- #
# internal: enable the KV v2 mount if it is not already present                #
# --------------------------------------------------------------------------- #
_obc_enable_mount() {
    if bao secrets list 2>/dev/null | grep -q "^${OBC_MOUNT}/"; then
        printf 'KV mount %s already enabled.\n' "$OBC_MOUNT"
        return 0
    fi

    printf 'Enabling KV v2 mount at %s...\n' "$OBC_MOUNT"
    bao secrets enable -path="$OBC_MOUNT" kv-v2 >/dev/null || return 1
    return 0
}

# --------------------------------------------------------------------------- #
# internal: write both policies                                                #
# --------------------------------------------------------------------------- #
_obc_write_policies() {
    printf 'Writing policies...\n'

    # KV v2 delete is not a single path. Granting "delete" on data/ alone does
    # not delete - soft delete, undelete, destroy and metadata removal each
    # live on their own path and each needs an explicit capability.
    _tmp="$(mktemp)" || return 1
    cat > "$_tmp" <<EOF
path "$OBC_MOUNT/data/*" {
  capabilities = ["create", "read", "update", "delete"]
}

path "$OBC_MOUNT/delete/*" {
  capabilities = ["update"]
}

path "$OBC_MOUNT/undelete/*" {
  capabilities = ["update"]
}

path "$OBC_MOUNT/destroy/*" {
  capabilities = ["update"]
}

path "$OBC_MOUNT/metadata/*" {
  capabilities = ["list", "read", "delete"]
}
EOF
    bao policy write ssldeploy-create "$_tmp" >/dev/null || return 1
    rm -f "$_tmp"

    _tmp="$(mktemp)" || return 1
    cat > "$_tmp" <<EOF
path "$OBC_MOUNT/data/*" {
  capabilities = ["read"]
}

path "$OBC_MOUNT/metadata/*" {
  capabilities = ["list", "read"]
}
EOF
    bao policy write ssldeploy-read "$_tmp" >/dev/null || return 1
    rm -f "$_tmp"
    unset _tmp

    return 0
}

# --------------------------------------------------------------------------- #
# internal: create one AppRole and write its credentials to disk               #
#           $1 = role name, $2 = credential directory                          #
# --------------------------------------------------------------------------- #
_obc_write_role() {
    _role="$1"
    _dir="$2"

    printf 'Creating role %s...\n' "$_role"

    # secret_id_ttl=0 and secret_id_num_uses=0 are deliberate. An expiring
    # secret_id means cron silently stops renewing certificates months later,
    # on a system whose entire purpose is preventing expiry. The long-lived
    # credential is the secret_id on disk; the token it mints is short.
    bao write "auth/approle/role/$_role" \
        token_policies="$_role" \
        token_ttl=10m \
        token_max_ttl=30m \
        secret_id_ttl=0 \
        secret_id_num_uses=0 >/dev/null || return 1

    _role_id=$(bao read -field=role_id "auth/approle/role/$_role/role-id") || return 1
    _secret_id=$(bao write -f -field=secret_id "auth/approle/role/$_role/secret-id") || return 1

    if [ -z "$_role_id" ] || [ -z "$_secret_id" ]; then
        printf 'ERROR: could not obtain credentials for %s.\n' "$_role" >&2
        unset _role _dir _role_id _secret_id
        return 1
    fi

    mkdir -p "$_dir" || return 1
    chmod 700 "$_dir" || return 1

    printf '%s\n' "$_role_id"   > "$_dir/role_id"   || return 1
    printf '%s\n' "$_secret_id" > "$_dir/secret_id" || return 1

    chmod 600 "$_dir/role_id" "$_dir/secret_id" || return 1
    chown "$OBC_FLASK_USER":"$OBC_FLASK_USER" \
        "$_dir" "$_dir/role_id" "$_dir/secret_id" 2>/dev/null || true

    unset _role _dir _role_id _secret_id
    return 0
}

# --------------------------------------------------------------------------- #
# internal: mount + policies + roles, for self-service provisioning            #
#           no-op when the administrator already provisioned the vault         #
# --------------------------------------------------------------------------- #
_obc_provision() {
    if [ "$OBC_PROVISION" != "self" ]; then
        printf 'Skipping provisioning (credentials supplied by the administrator).\n'
        return 0
    fi

    _obc_enable_mount   || return 1
    _obc_write_policies || return 1

    printf 'Enabling AppRole authentication...\n'
    if ! bao auth list 2>/dev/null | grep -q '^approle/'; then
        bao auth enable approle >/dev/null || return 1
    fi

    mkdir -p "$OBC_CRED_DIR" || return 1
    chmod 700 "$OBC_CRED_DIR" || return 1

    _obc_write_role ssldeploy-create "$OBC_CRED_DIR/create" || return 1
    _obc_write_role ssldeploy-read   "$OBC_CRED_DIR/read"   || return 1

    return 0
}

# --------------------------------------------------------------------------- #
# internal: prove both roles behave as scoped                                  #
#                                                                              #
# This matters most in delegated mode, where the policies were written by      #
# someone else and cannot be read back without privilege.                      #
# --------------------------------------------------------------------------- #
_obc_verify_roles() {
    printf '\nVerifying role scopes...\n'

    _saved_token="$BAO_TOKEN"

    # --- create role: must be able to write, read and destroy ------------- #
    BAO_TOKEN=$(bao write -field=token auth/approle/login \
        role_id="$(cat "$OBC_CRED_DIR/create/role_id")" \
        secret_id="$(cat "$OBC_CRED_DIR/create/secret_id")") || return 1
    export BAO_TOKEN

    if ! bao kv put -mount="$OBC_MOUNT" _ssldeploy_selftest probe=ok >/dev/null 2>&1; then
        printf 'ERROR: ssldeploy-create cannot write.\n' >&2
        return 1
    fi

    if [ "$(bao kv get -mount="$OBC_MOUNT" -field=probe _ssldeploy_selftest 2>/dev/null)" != "ok" ]; then
        printf 'ERROR: ssldeploy-create cannot read back what it wrote.\n' >&2
        return 1
    fi

    # --- read role: must read, and must NOT write ------------------------- #
    BAO_TOKEN=$(bao write -field=token auth/approle/login \
        role_id="$(cat "$OBC_CRED_DIR/read/role_id")" \
        secret_id="$(cat "$OBC_CRED_DIR/read/secret_id")") || return 1
    export BAO_TOKEN

    if [ "$(bao kv get -mount="$OBC_MOUNT" -field=probe _ssldeploy_selftest 2>/dev/null)" != "ok" ]; then
        printf 'ERROR: ssldeploy-read cannot read.\n' >&2
        return 1
    fi

    # Asserting the negative matters more than asserting the positive: a
    # silently over-privileged read role defeats the whole split and would
    # otherwise pass unnoticed.
    if bao kv put -mount="$OBC_MOUNT" _ssldeploy_selftest probe=escalated >/dev/null 2>&1; then
        printf 'ERROR: ssldeploy-read was able to WRITE. Policy is too broad.\n' >&2
        return 1
    fi

    # --- clean up the probe as the create role ---------------------------- #
    BAO_TOKEN=$(bao write -field=token auth/approle/login \
        role_id="$(cat "$OBC_CRED_DIR/create/role_id")" \
        secret_id="$(cat "$OBC_CRED_DIR/create/secret_id")") || return 1
    export BAO_TOKEN

    bao kv metadata delete -mount="$OBC_MOUNT" _ssldeploy_selftest >/dev/null 2>&1 || {
        printf 'ERROR: ssldeploy-create cannot destroy metadata.\n' >&2
        return 1
    }

    BAO_TOKEN="$_saved_token"
    export BAO_TOKEN
    unset _saved_token

    printf 'Both roles verified.\n'
    return 0
}

# --------------------------------------------------------------------------- #
# internal: restart the service and confirm it comes back unsealed             #
# --------------------------------------------------------------------------- #
_obc_verify_unseal() {
    printf '\nVerifying automatic unseal across a restart...\n'

    if command -v systemctl >/dev/null 2>&1; then
        $OBC_SUDO systemctl restart openbao || return 1
    else
        $OBC_SUDO rc-service openbao restart || return 1
    fi

    _tries=0
    while [ "$_tries" -lt 30 ]; do
        if bao status 2>/dev/null | grep -q 'Sealed.*false'; then
            unset _tries
            printf 'Vault came back unsealed on its own.\n'
            return 0
        fi
        _tries=$((_tries + 1))
        sleep 1
    done
    unset _tries

    # If this does not work during installation it will certainly not work
    # unattended at 03:00 after a reboot. Fail here, loudly, while someone
    # is watching.
    printf 'ERROR: the vault did not unseal automatically after a restart.\n' >&2
    printf 'Certificate renewal would fail silently after any reboot.\n' >&2
    return 1
}

# --------------------------------------------------------------------------- #
# internal: write the resolved configuration to ../.env                        #
# --------------------------------------------------------------------------- #
_obc_persist_env() {
    _obc_env_set openbaoDeployment "$OBC_DEPLOYMENT" || return 1
    _obc_env_set openbaoAddress    "$OBC_ADDRESS"    || return 1
    _obc_env_set openbaoCaCert     "$OBC_CACERT"     || return 1
    _obc_env_set openbaoMount      "$OBC_MOUNT"      || return 1
    return 0
}

# --------------------------------------------------------------------------- #
# public: explain the two deployment modes                                     #
#         print this before prompting with confirm_continue                    #
# --------------------------------------------------------------------------- #
openbao_deployment_notice() {
    cat << 'EOF'

=========================================================
OpenBao Configuration
=========================================================

ssldeploy stores DNS provider credentials in OpenBao rather
than in the application database.

[y/Y] Local     OpenBao runs on this host. It is installed as
                a service, initialised, and unsealed
                automatically at boot by a root-owned hook.
                The unseal key is stored at
                /etc/ssldeploy/unseal.key (root, 0400) and
                must NEVER be included in a backup that also
                contains /var/lib/openbao - doing so removes
                the benefit of encryption at rest entirely.

[n/N] Remote    OpenBao runs on another machine. No service is
                installed here. Recommended where available:
                a reboot of THIS host cannot then stall
                renewal. Note that ssldeploy holds no unseal
                key for a remote vault - a reboot of the VAULT
                host stalls renewal until its own operator
                unseals it.

=========================================================

EOF
    return 0
}

# --------------------------------------------------------------------------- #
# public: install and configure OpenBao on this host                           #
# --------------------------------------------------------------------------- #
openbao_local_installation() {
    _obc_context || return 1

    OBC_DEPLOYMENT="local"
    OBC_ADDRESS="http://127.0.0.1:8200"
    OBC_CACERT=""

    # --- binary ----------------------------------------------------------- #
    _obc_install_binary || return 1

    # --- mount and client environment ------------------------------------- #
    _obc_prompt_mount || return 1

    # --- service, then initialise and unseal ------------------------------ #
    _obc_local_provision   || return 1
    _obc_local_unseal_hook || return 1
    _obc_local_service     || return 1
    _obc_local_init        || return 1

    BAO_TOKEN="$obc_token"
    export BAO_TOKEN
    unset obc_token

    # --- mount, policies, roles ------------------------------------------- #
    _obc_provision    || return 1
    _obc_verify_roles || return 1
    _obc_persist_env  || return 1

    # --- drop the bootstrap token, then prove unseal survives a restart --- #
    printf '\nRevoking the initial root token...\n'
    printf 'AppRole is from now on the only standing authentication.\n'
    printf 'Generate a new root token with "bao operator generate-root"\n'
    printf 'and the unseal key if you ever need administrative access.\n'
    bao token revoke -self >/dev/null 2>&1 || true
    unset BAO_TOKEN

    _obc_verify_unseal || return 1

    cat << EOF

=========================================================
IMPORTANT
=========================================================

  $OBC_UNSEAL_KEY  (root, 0400)

This file unseals the vault. Encryption at rest only
protects you if this key never travels alongside
$OBC_DATA_DIR. Exclude it from every backup, image
and snapshot that contains the vault data.

=========================================================

EOF

    printf 'OpenBao configuration complete.\n'
    printf 'Credentials: %s/{create,read}\n' "$OBC_CRED_DIR"

    _obc_cleanup
    return 0
}

# --------------------------------------------------------------------------- #
# public: configure against an OpenBao running on another host                 #
# --------------------------------------------------------------------------- #
openbao_remote_installation() {
    _obc_context || return 1

    OBC_DEPLOYMENT="remote"

    # --- binary (the CLI is how we talk to the remote vault) -------------- #
    _obc_install_binary || return 1

    # --- address and CA certificate --------------------------------------- #
    while :; do
        printf 'OpenBao address (https://host:8200): '
        read -r answer < /dev/tty
        case "$answer" in
            https://*) OBC_ADDRESS="$answer"; break ;;
            http://*)  printf 'A remote vault must use https.\n' ;;
            *)         printf 'Enter a full URL, e.g. https://vault.example.com:8200\n' ;;
        esac
    done

    printf 'CA certificate path (blank to use the system trust store): '
    read -r answer < /dev/tty
    if [ -n "$answer" ] && [ ! -f "$answer" ]; then
        printf 'ERROR: %s does not exist.\n' "$answer" >&2
        return 1
    fi
    OBC_CACERT="$answer"

    # --- mount and client environment ------------------------------------- #
    _obc_prompt_mount || return 1

    # --- reachability ------------------------------------------------------ #
    _obc_wait_api || return 1

    if bao status 2>/dev/null | grep -q 'Sealed.*true'; then
        printf 'ERROR: the remote vault is sealed. Unseal it and re-run.\n' >&2
        return 1
    fi

    # --- credentials: privileged token, or pre-provisioned AppRoles ------- #
    _obc_remote_credentials || return 1

    if [ "$OBC_PROVISION" = "self" ]; then
        BAO_TOKEN="$obc_token"
        export BAO_TOKEN
        unset obc_token
    fi

    _obc_provision    || return 1
    _obc_verify_roles || return 1
    _obc_persist_env  || return 1

    unset BAO_TOKEN

    if [ "$OBC_PROVISION" = "self" ]; then
        printf '\nThe bootstrap token was used in memory only and never written to disk.\n'
    fi

    cat << 'EOF'

=========================================================
IMPORTANT - remote deployment
=========================================================

ssldeploy holds no unseal key for this vault. If the vault
host restarts, certificate renewal stalls until its own
operator unseals it.

If the AppRole secret_ids were created with a TTL or a use
count, renewal will fail once they expire. ssldeploy cannot
read those settings back and cannot warn you. Confirm with
your OpenBao administrator that both roles were created
with secret_id_ttl=0 and secret_id_num_uses=0.

=========================================================

EOF

    printf 'OpenBao configuration complete.\n'
    printf 'Credentials: %s/{create,read}\n' "$OBC_CRED_DIR"

    _obc_cleanup
    return 0
}

# --------------------------------------------------------------------------- #
# public: print the definitions an external OpenBao administrator needs        #
#         usage: openbao_print_policies [mount]   (default: ssldeploy)         #
# --------------------------------------------------------------------------- #
openbao_print_policies() {
    _mount="${1:-ssldeploy}"

    cat <<EOF
# =========================================================================== #
# ssldeploy - OpenBao preparation for delegated (remote) deployments
#
# Run these as an OpenBao administrator on the vault host, then hand the
# operator the four values printed at the end.
# =========================================================================== #

# --- 1. KV v2 mount --------------------------------------------------------
bao secrets enable -path=$_mount kv-v2

# --- 2. Policies -----------------------------------------------------------
# KV v2 delete is spread over four paths. Granting "delete" on data/ alone
# does NOT delete: soft delete, undelete, destroy and metadata removal each
# need their own capability.

bao policy write ssldeploy-create - <<'POLICY'
path "$_mount/data/*" {
  capabilities = ["create", "read", "update", "delete"]
}

path "$_mount/delete/*" {
  capabilities = ["update"]
}

path "$_mount/undelete/*" {
  capabilities = ["update"]
}

path "$_mount/destroy/*" {
  capabilities = ["update"]
}

path "$_mount/metadata/*" {
  capabilities = ["list", "read", "delete"]
}
POLICY

bao policy write ssldeploy-read - <<'POLICY'
path "$_mount/data/*" {
  capabilities = ["read"]
}

path "$_mount/metadata/*" {
  capabilities = ["list", "read"]
}
POLICY

# --- 3. AppRole auth -------------------------------------------------------
bao auth enable approle

# secret_id_ttl=0 and secret_id_num_uses=0 are REQUIRED, not defaults.
# An expiring secret_id makes certificate renewal fail silently months after
# installation. ssldeploy cannot read these settings back without privilege
# and therefore cannot warn about them.

bao write auth/approle/role/ssldeploy-create \\
    token_policies=ssldeploy-create \\
    token_ttl=10m \\
    token_max_ttl=30m \\
    secret_id_ttl=0 \\
    secret_id_num_uses=0

bao write auth/approle/role/ssldeploy-read \\
    token_policies=ssldeploy-read \\
    token_ttl=10m \\
    token_max_ttl=30m \\
    secret_id_ttl=0 \\
    secret_id_num_uses=0

# --- 4. Hand over four values ----------------------------------------------
# role_id is an identifier and may be sent in the clear.

bao read -field=role_id auth/approle/role/ssldeploy-create/role-id
bao read -field=role_id auth/approle/role/ssldeploy-read/role-id

# secret_id is a credential. Prefer response wrapping: the wrapping token is
# single use, so a failed unwrap on the ssldeploy host proves interception
# rather than a typo. Send each token over a separate channel from the
# role_id, and generate them shortly before the installation runs.

bao write -wrap-ttl=5m -f auth/approle/role/ssldeploy-create/secret-id
bao write -wrap-ttl=5m -f auth/approle/role/ssldeploy-read/secret-id

# If response wrapping is not an option, generate the raw values instead:
#
#   bao write -f -field=secret_id auth/approle/role/ssldeploy-create/secret-id
#   bao write -f -field=secret_id auth/approle/role/ssldeploy-read/secret-id

# --- 5. Listener requirements ----------------------------------------------
# The ssldeploy host connects over https. Either the listener certificate
# chains to a CA in the host trust store, or the operator supplies a CA
# bundle path during installation (written to .env as openbaoCaCert).
#
# The vault must be UNSEALED before installation starts, and must be unsealed
# again after every restart of the vault host. ssldeploy holds no unseal key
# for a remote vault and cannot do this for you.
# =========================================================================== #
EOF

    unset _mount
    return 0
}