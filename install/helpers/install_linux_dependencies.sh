#!/bin/sh
# Source this file: . ./install_linux_dependencies.sh

install_linux_dependencies() {
    local SUDO_CMD="" ID="" ID_LIKE="" NAME="" FAMILY="" PKG_MAN=""
    local DEB_PKGS="" RHEL_PKGS="" SUSE_PKGS="" ARCH_PKGS="" ALPINE_PKGS=""
    local DEB_PROD_PKGS="" RHEL_PROD_PKGS="" SUSE_PROD_PKGS="" ARCH_PROD_PKGS="" ALPINE_PROD_PKGS=""
    local DEB_DEV_PKGS="" RHEL_DEV_PKGS="" SUSE_DEV_PKGS="" ARCH_DEV_PKGS="" ALPINE_DEV_PKGS=""
    local pkgs="" pkg=""

    DEB_PKGS="python3 python3-pip python3-venv python3-dev libffi-dev libssl-dev build-essential libc-bin sqlite3 certbot curl"
    RHEL_PKGS="python3 python3-pip python3-devel libffi-devel openssl-devel gcc glibc-common sqlite certbot curl"
    SUSE_PKGS="python3 python3-pip python3-devel libffi-devel libopenssl-devel gcc glibc sqlite3 certbot curl"
    ARCH_PKGS="python python-pip libffi openssl base-devel glibc sqlite certbot curl"
    ALPINE_PKGS="python3 py3-pip python3-dev libffi-dev openssl-dev build-base libc-utils sqlite certbot curl"

    DEB_PROD_PKGS="nginx ufw gunicorn"
    RHEL_PROD_PKGS="nginx firewalld python3-gunicorn"
    SUSE_PROD_PKGS="nginx firewalld python3-gunicorn"
    ARCH_PROD_PKGS="nginx ufw gunicorn"
    ALPINE_PROD_PKGS="nginx ufw py3-gunicorn"

    DEB_DEV_PKGS="git-lfs"
    RHEL_DEV_PKGS="git-lfs"
    SUSE_DEV_PKGS="git-lfs"
    ARCH_DEV_PKGS="git-lfs"
    ALPINE_DEV_PKGS="git-lfs"

    echo "Checking privileges..."
    if [ "$(id -u)" -ne 0 ]; then
        if command -v sudo >/dev/null 2>&1; then
            SUDO_CMD="sudo"
        else
            echo "Error: sudo required but not installed." >&2
            return 1
        fi
    fi

    echo "Detecting OS..."
    if [ -f /etc/os-release ]; then
        . /etc/os-release
    else
        echo "Error: missing /etc/os-release" >&2
        return 1
    fi

    case "$ID" in
        ubuntu|debian) FAMILY="debian" ;;
        rhel|centos|fedora|rocky|alma) FAMILY="rhel" ;;
        sles|opensuse*) FAMILY="suse" ;;
        arch) FAMILY="arch" ;;
        alpine) FAMILY="alpine" ;;
        *) echo "Unsupported OS: $ID" >&2; return 1 ;;
    esac

    echo "Installing base packages..."
    case "$FAMILY" in
        debian)
            $SUDO_CMD apt-get update -y
            for pkg in $DEB_PKGS; do pkgs="$pkgs $pkg"; done
            $SUDO_CMD apt-get install -y $pkgs
            ;;
        rhel)
            PKG_MAN=$(command -v dnf || command -v yum)
            for pkg in $RHEL_PKGS; do pkgs="$pkgs $pkg"; done
            $SUDO_CMD $PKG_MAN install -y $pkgs
            ;;
        suse)
            $SUDO_CMD zypper --non-interactive refresh
            for pkg in $SUSE_PKGS; do pkgs="$pkgs $pkg"; done
            $SUDO_CMD zypper --non-interactive install -y $pkgs
            ;;
        arch)
            for pkg in $ARCH_PKGS; do pkgs="$pkgs $pkg"; done
            $SUDO_CMD pacman -Syu --noconfirm --needed $pkgs
            ;;
        alpine)
            $SUDO_CMD apk update
            for pkg in $ALPINE_PKGS; do pkgs="$pkgs $pkg"; done
            $SUDO_CMD apk add $pkgs
            ;;
    esac

    # -------------------------
    # Tailwind CLI INSTALLER
    # -------------------------
    echo "Installing Tailwind CLI..."

    if [ ! -f ./.install ]; then
        echo "Error: ./.install missing" >&2
        return 1
    fi

    TAILWIND_VERSION=$(grep '^supported_tailwind-cli=' ./.install | cut -d '=' -f2)

    if [ -z "$TAILWIND_VERSION" ]; then
        echo "Error: Tailwind version not defined" >&2
        return 1
    fi

    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64|amd64) ARCH="x64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *) echo "Unsupported arch: $ARCH" >&2; return 1 ;;
    esac

    OS="$(uname -s)"
    LIBC="gnu"
    if ldd --version 2>&1 | grep -qi musl; then
        LIBC="musl"
    fi

    case "$OS" in
        Linux)
            if [ "$LIBC" = "musl" ]; then
                FILE="tailwindcss-linux-${ARCH}-musl"
            else
                FILE="tailwindcss-linux-${ARCH}"
            fi
            ;;
        Darwin)
            FILE="tailwindcss-macos-${ARCH}"
            ;;
        *)
            echo "Unsupported OS: $OS" >&2
            return 1
            ;;
    esac

    TAILWIND_DIR="../tools/tailwind"
    TAILWIND_FILE="$TAILWIND_DIR/tailwind-cli"
    TAILWIND_URL="https://github.com/tailwindlabs/tailwindcss/releases/download/v${TAILWIND_VERSION}/${FILE}"

    mkdir -p "$TAILWIND_DIR" || return 1

    echo "Downloading Tailwind CLI..."
    rm -f "$TAILWIND_FILE"

    if command -v curl >/dev/null 2>&1; then
        curl -L -o "$TAILWIND_FILE" "$TAILWIND_URL" || return 1
    else
        wget -O "$TAILWIND_FILE" "$URL" || return 1
    fi

    chmod +x "$TAILWIND_FILE" || return 1

    echo "Optional checksum verification..."

    TAILWIND_CHECKSUM_URL="https://github.com/tailwindlabs/tailwindcss/releases/download/v${TAILWIND_VERSION}/sha256sums.txt"
    TAILWIND_CHECKSUM_FILE="/tmp/tailwind.sha256"

    if curl -fsSL "$TAILWIND_CHECKSUM_URL" -o "$TAILWIND_CHECKSUM_FILE" 2>/dev/null || \
       wget -q "$TAILWIND_CHECKSUM_URL" -O "$TAILWIND_CHECKSUM_FILE" 2>/dev/null; then

        EXPECTED=$(grep " $FILE\$" "$TAILWIND_CHECKSUM_FILE" | awk '{print $1}')

        if [ -n "$EXPECTED" ]; then
            if command -v sha256sum >/dev/null 2>&1; then
                ACTUAL=$(sha256sum "$TAILWIND_FILE" | awk '{print $1}')
            else
                ACTUAL=$(shasum -a 256 "$TAILWIND_FILE" | awk '{print $1}')
            fi

            if [ "$EXPECTED" != "$ACTUAL" ]; then
                echo "Error: checksum mismatch" >&2
                return 1
            fi

            echo "Checksum verified."
        else
            echo "Warning: checksum not found, skipping verification."
        fi
    else
        echo "Warning: no checksum file found, skipping verification."
    fi

    echo "Tailwind CLI installed at $TAILWIND_FILE"

    echo "Cleaning up variables..."
    unset SUDO_CMD ID ID_LIKE NAME FAMILY PKG_MAN pkgs pkg
    unset DEB_PKGS RHEL_PKGS SUSE_PKGS ARCH_PKGS ALPINE_PKGS
    unset DEB_PROD_PKGS RHEL_PROD_PKGS SUSE_PROD_PKGS ARCH_PROD_PKGS ALPINE_PROD_PKGS
    unset DEB_DEV_PKGS RHEL_DEV_PKGS SUSE_DEV_PKGS ARCH_DEV_PKGS ALPINE_DEV_PKGS
    unset TAILWIND_VERSION TAILWIND_DIR TAILWIND_FILE TAILWIND_URL TAILWIND_CHECKSUM_URL TAILWIND_CHECKSUM_FILE
    echo "All dependencies installed successfully!"
}