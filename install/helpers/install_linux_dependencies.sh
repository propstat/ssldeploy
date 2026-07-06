#!/bin/sh
# Source this file: . ./install_linux_dependencies.sh

install_linux_dependencies() {
    local SUDO_CMD="" ID="" ID_LIKE="" NAME="" FAMILY="" PKG_MAN=""
    local DEB_PKGS="" RHEL_PKGS="" SUSE_PKGS="" ARCH_PKGS="" ALPINE_PKGS=""
    local DEB_PROD_PKGS="" RHEL_PROD_PKGS="" SUSE_PROD_PKGS="" ARCH_PROD_PKGS="" ALPINE_PROD_PKGS=""
    local pkgs="" pkg=""

    # -------------------------
    # Read deployment mode
    # -------------------------
    if [ ! -f "../.env" ]; then
        echo "Error: ../.env missing" >&2
        return 1
    fi

    SSLDEPLOY_MODE=$(grep '^ssldeployMode=' ../.env | cut -d '=' -f2 | tr -d '\r')

    if [ -z "$SSLDEPLOY_MODE" ]; then
        echo "Error: ssldeployMode not set in .env" >&2
        return 1
    fi

    case "$SSLDEPLOY_MODE" in
        development|production)
            ;;
        *)
            echo "Error: unsupported ssldeployMode: $SSLDEPLOY_MODE" >&2
            return 1
            ;;
    esac

    echo "Deployment mode: $SSLDEPLOY_MODE"

    # -------------------------
    # Package definitions
    # -------------------------
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

    # -------------------------
    # Privileges
    # -------------------------
    echo "Checking privileges..."

    if [ "$(id -u)" -ne 0 ]; then
        if command -v sudo >/dev/null 2>&1; then
            SUDO_CMD="sudo"
        else
            echo "Error: sudo required but not installed." >&2
            return 1
        fi
    fi

    # -------------------------
    # OS detection
    # -------------------------
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
        *)
            echo "Unsupported OS: $ID" >&2
            return 1
            ;;
    esac

    # -------------------------
    # Base packages
    # -------------------------
    echo "Installing base packages..."

    pkgs=""

    case "$FAMILY" in
        debian)
            $SUDO_CMD apt-get update -y
            for pkg in $DEB_PKGS; do pkgs="$pkgs $pkg"; done
            $SUDO_CMD apt-get install -y $pkgs
            ;;
        rhel)
            PKG_MAN=$(command -v dnf || command -v yum)
            for pkg in $RHEL_PKGS; do pkgs="$pkgs $pkg"; done
            $SUDO_CMD "$PKG_MAN" install -y $pkgs
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
    # Production dependencies
    # -------------------------
    if [ "$SSLDEPLOY_MODE" = "production" ]; then
        echo "Installing production packages..."

        pkgs=""

        case "$FAMILY" in
            debian)
                for pkg in $DEB_PROD_PKGS; do pkgs="$pkgs $pkg"; done
                $SUDO_CMD apt-get install -y $pkgs
                ;;
            rhel)
                for pkg in $RHEL_PROD_PKGS; do pkgs="$pkgs $pkg"; done
                $SUDO_CMD "$PKG_MAN" install -y $pkgs
                ;;
            suse)
                for pkg in $SUSE_PROD_PKGS; do pkgs="$pkgs $pkg"; done
                $SUDO_CMD zypper --non-interactive install -y $pkgs
                ;;
            arch)
                for pkg in $ARCH_PROD_PKGS; do pkgs="$pkgs $pkg"; done
                $SUDO_CMD pacman -S --noconfirm --needed $pkgs
                ;;
            alpine)
                for pkg in $ALPINE_PROD_PKGS; do pkgs="$pkgs $pkg"; done
                $SUDO_CMD apk add $pkgs
                ;;
        esac
    fi

    # -------------------------
    # Tailwind CLI (development only)
    # -------------------------
    if [ "$SSLDEPLOY_MODE" = "development" ]; then

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

        # -------------------------
        # Determine Tailwind artifact
        # -------------------------
        ARCH=$(uname -m)

        case "$ARCH" in
            x86_64|amd64)
                ARCH="x64"
                ;;
            aarch64|arm64)
                ARCH="arm64"
                ;;
            *)
                echo "Unsupported arch: $ARCH" >&2
                return 1
                ;;
        esac

        OS="$(uname -s)"

        LIBC="gnu"
        if ldd --version 2>&1 | grep -qi musl; then
            LIBC="musl"
        fi

        case "$OS" in
            Linux)
                if [ "$LIBC" = "musl" ]; then
                    TAILWIND_RELEASE_BINARY_NAME="tailwindcss-linux-${ARCH}-musl"
                else
                    TAILWIND_RELEASE_BINARY_NAME="tailwindcss-linux-${ARCH}"
                fi
                ;;
            Darwin)
                TAILWIND_RELEASE_BINARY_NAME="tailwindcss-macos-${ARCH}"
                ;;
            *)
                echo "Unsupported OS: $OS" >&2
                return 1
                ;;
        esac

        # -------------------------
        # Download locations
        # -------------------------
        TAILWIND_DIR="../tools/tailwind"

        TAILWIND_BINARY_FILE="$TAILWIND_DIR/$TAILWIND_RELEASE_BINARY_NAME"

        TAILWIND_SYMLINK_FILE="$TAILWIND_DIR/tailwind-cli"

        TAILWIND_URL="https://github.com/tailwindlabs/tailwindcss/releases/download/v${TAILWIND_VERSION}/${TAILWIND_RELEASE_BINARY_NAME}"
        
        mkdir -p "$TAILWIND_DIR" || return 1

        # -------------------------
        # Download binary
        # -------------------------
        echo "Downloading Tailwind CLI..."
        echo "Version: $TAILWIND_VERSION"
        echo "TAILWIND URL: $TAILWIND_URL"
        rm -f "$TAILWIND_BINARY_FILE"

        if command -v curl >/dev/null 2>&1; then
            curl -L -o "$TAILWIND_BINARY_FILE" "$TAILWIND_URL" || return 1
        else
            wget -O "$TAILWIND_BINARY_FILE" "$TAILWIND_URL" || return 1
        fi

        chmod +x "$TAILWIND_BINARY_FILE" || return 1

        # -------------------------
        # Verify checksum
        # -------------------------
        echo "Verifying checksum..."

        TAILWIND_CHECKSUM_URL="https://github.com/tailwindlabs/tailwindcss/releases/download/v${TAILWIND_VERSION}/sha256sums.txt"

        TAILWIND_CHECKSUM_FILE="/tmp/tailwind.sha256"

        if curl -fsSL "$TAILWIND_CHECKSUM_URL" -o "$TAILWIND_CHECKSUM_FILE" 2>/dev/null || \
           wget -q "$TAILWIND_CHECKSUM_URL" -O "$TAILWIND_CHECKSUM_FILE" 2>/dev/null; then

            EXPECTED=$(grep " \./$TAILWIND_RELEASE_BINARY_NAME$" "$TAILWIND_CHECKSUM_FILE" | awk '{print $1}')

            if [ -z "$EXPECTED" ]; then
                echo "Error: checksum entry not found for $TAILWIND_RELEASE_BINARY_NAME" >&2
                return 1
            fi

            if command -v sha256sum >/dev/null 2>&1; then
                ACTUAL=$(sha256sum "$TAILWIND_BINARY_FILE" | awk '{print $1}')
            else
                ACTUAL=$(shasum -a 256 "$TAILWIND_BINARY_FILE" | awk '{print $1}')
            fi

            if [ "$EXPECTED" != "$ACTUAL" ]; then
                echo "Error: checksum mismatch" >&2
                return 1
            fi

            echo "Checksum verified."

        else
            echo "Warning: checksum file unavailable, skipping verification."
        fi

        # -------------------------
        # Create stable symlink
        # -------------------------
        echo "Creating Tailwind symlink..."

        rm -f "$TAILWIND_SYMLINK_FILE"

        ln -s "$TAILWIND_RELEASE_BINARY_NAME" "$TAILWIND_SYMLINK_FILE" || return 1

        echo "Tailwind CLI installed:"
        echo "$TAILWIND_SYMLINK_FILE -> $TAILWIND_RELEASE_BINARY_NAME"

    else
        echo "Skipping Tailwind CLI installation (production mode)."
    fi

    # -------------------------
    # Cleanup
    # -------------------------
    echo "All dependencies installed successfully!"

    unset SUDO_CMD ID ID_LIKE NAME FAMILY PKG_MAN
    unset pkgs pkg
    unset SSLDEPLOY_MODE

    unset DEB_PKGS RHEL_PKGS SUSE_PKGS ARCH_PKGS ALPINE_PKGS
    unset DEB_PROD_PKGS RHEL_PROD_PKGS SUSE_PROD_PKGS ARCH_PROD_PKGS ALPINE_PROD_PKGS

    unset TAILWIND_VERSION
    unset TAILWIND_RELEASE_BINARY_NAME
    unset TAILWIND_DIR
    unset TAILWIND_BINARY_FILE
    unset TAILWIND_SYMLINK_FILE
    unset TAILWIND_URL
    unset TAILWIND_CHECKSUM_URL
    unset TAILWIND_CHECKSUM_FILE
}