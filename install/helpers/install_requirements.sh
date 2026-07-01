#!/usr/bin/env bash
# source this file: . ./install_requirements.sh

parsing_os_release() {
    # No 'local' keyword; variables are global but prefixed to avoid naming collisions
    _key="$1"
    grep -E "^${_key}=" /etc/os-release | sed -e 's/^[^=]*=//' -e 's/^"//' -e 's/"$//'
}

install_dependencies() {
    # Determine if sudo is needed
    SUDO_CMD=""
    if [ "$(id -u)" -ne 0 ]; then
        if command -v sudo >/dev/null 2>&1; then
            echo "Privilege escalation required. Prompting for sudo..."
            SUDO_CMD="sudo"
        else
            echo "Error: This script requires root privileges, but 'sudo' is not installed." >&2
            return 1
        fi
    fi

    # Detect the distribution using /etc/os-release
    if [ -f /etc/os-release ]; then
        OS=$(parsing_os_release "ID")
        LIKE=$(parsing_os_release "ID_LIKE")
        NAME=$(parsing_os_release "NAME")
    else
        echo "Error: Cannot detect OS distribution (/etc/os-release missing)." >&2
        return 1
    fi

    echo "Detected OS: $NAME"
    echo "Updating package manager and installing dependencies..."
    echo "--------------------------------------------------------"

    case "$OS" in
        ubuntu|debian)
            DEBIAN_FRONTEND=noninteractive
            export DEBIAN_FRONTEND
            $SUDO_CMD apt-get update -y
            $SUDO_CMD apt-get install -y python3 python3-pip python3-venv python3-dev libffi-dev libssl-dev build-essential libc-bin sqlite3
            ;;

        rhel|centos|fedora|rocky|almalinux)
            PKG_MAN=$(command -v dnf || command -v yum)
            $SUDO_CMD $PKG_MAN install -y python3 python3-pip python3-devel libffi-devel openssl-devel gcc glibc-common sqlite
            ;;

        sles|opensuse*)
            $SUDO_CMD zypper --non-interactive refresh
            $SUDO_CMD zypper --non-interactive install python3 python3-pip python3-devel libffi-devel libopenssl-devel gcc glibc sqlite3
            ;;

        arch)
            $SUDO_CMD pacman -Syu --noconfirm --needed python python-pip libffi openssl base-devel glibc sqlite
            ;;

        *)
            # Fallback on ID_LIKE using POSIX-compliant string matching instead of regex [[ =~ ]]
            case "$LIKE" in
                *ubuntu*|*debian*)
                    DEBIAN_FRONTEND=noninteractive
                    export DEBIAN_FRONTEND
                    $SUDO_CMD apt-get update -y && $SUDO_CMD apt-get install -y python3 python3-pip python3-venv python3-dev libffi-dev libssl-dev build-essential libc-bin sqlite3
                    ;;
                *rhel*|*fedora*)
                    PKG_MAN=$(command -v dnf || command -v yum)
                    $SUDO_CMD $PKG_MAN install -y python3 python3-pip python3-devel libffi-devel openssl-devel gcc glibc-common sqlite
                    ;;
                *suse*)
                    $SUDO_CMD zypper --non-interactive install python3 python3-pip python3-devel libffi-devel libopenssl-devel gcc glibc sqlite3
                    ;;
                *arch*)
                    $SUDO_CMD pacman -Syu --noconfirm --needed python python-pip libffi openssl base-devel glibc sqlite
                    ;;
                *)
                    echo "Error: Unsupported distribution: $OS" >&2
                    return 1
                    ;;
            esac
            ;;
    esac

    echo "--------------------------------------------------------"
    echo "All dependencies successfully installed!"
}