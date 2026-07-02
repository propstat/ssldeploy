#!/bin/sh
# Source this file: . ./helpers/install_requirements.sh

install_linux_dependencies() {
    # Declare local variables to prevent polluting the user's parent shell environment
    # Note: local is widely supported by targeted distros' /bin/sh (dash, ash, bash)
    local SUDO_CMD="" ID="" ID_LIKE="" NAME="" FAMILY="" PKG_MAN=""
    local DEB_PKGS="" RHEL_PKGS="" SUSE_PKGS="" ARCH_PKGS="" ALPINE_PKGS=""
    local pkgs="" pkg=""

    # POSIX-compliant whitespace-separated package lists
    DEB_PKGS="python3 python3-pip python3-venv python3-dev libffi-dev libssl-dev build-essential libc-bin sqlite3"
    RHEL_PKGS="python3 python3-pip python3-devel libffi-devel openssl-devel gcc glibc-common sqlite"
    SUSE_PKGS="python3 python3-pip python3-devel libffi-devel libopenssl-devel gcc glibc sqlite3"
    ARCH_PKGS="python python-pip libffi openssl base-devel glibc sqlite"
    ALPINE_PKGS="python3 py3-pip python3-dev libffi-dev openssl-dev build-base libc-utils sqlite"

    cat << "EOF"

=========================================================
Installing Dependencies for SSLDeploy
=========================================================

The direct Linux Dependencies will now be installed.
You will be asked later if you prefer to run SSLDeploy
in any of the following two modes: 

1) Production including NGINX and hardened Firewall rules
   using gunicorn as the WSGI server (recommended for production)

2) Development mode with the built-in Flask development server
   (not recommended for production) including the tailwind-cli

Following packages will be installed based on your Linux
distribution:

- python3
- python3-pip
- python3-venv
- python3-dev
- libffi-dev
- libssl-dev
- build-essential
- libc-bin
- sqlite3

=========================================================

EOF
    read -n 1 -s -r -p "Press any key to continue"
    echo "Determining if SUDO is required..."
    if [ "$(id -u)" -ne 0 ]; then
        if command -v sudo >/dev/null 2>&1; then
            echo "Privilege escalation required. Prompting for sudo..."
            SUDO_CMD="sudo"
        else
            echo "Error: This script requires root privileges, but 'sudo' is not installed." >&2
            return 1
        fi
    fi

    echo "Identifying Distribution..."
    if [ -f /etc/os-release ]; then
        # Source the configuration file to load ID, ID_LIKE, and NAME in one go
        . /etc/os-release
    else
        echo "Error: Cannot detect OS distribution (/etc/os-release missing)." >&2
        return 1
    fi

    echo "Detected OS: $NAME"
    echo "Updating package manager and installing dependencies..."
    echo "--------------------------------------------------------"

    echo "Mapping OS to standard internal family names..."
    case "$ID" in
        ubuntu|debian)                  FAMILY="debian" ;;
        rhel|centos|fedora|rocky|alma)  FAMILY="rhel" ;;
        sles|opensuse*)                 FAMILY="suse" ;;
        arch)                           FAMILY="arch" ;;
        alpine)                         FAMILY="alpine" ;;
        *)
            # Fallback check via ID_LIKE
            case "$ID_LIKE" in
                *ubuntu*|*debian*)      FAMILY="debian" ;;
                *rhel*|*fedora*)        FAMILY="rhel" ;;
                *suse*)                 FAMILY="suse" ;;
                *arch*)                 FAMILY="arch" ;;
                *alpine*)               FAMILY="alpine" ;;
            esac
            ;;
    esac

    # Execute installation based on mapped family using POSIX expansion safely unquoted for word splitting
    case "$FAMILY" in
        debian)
            local DEBIAN_FRONTEND=noninteractive
            export DEBIAN_FRONTEND
            $SUDO_CMD apt-get update -y
            # Loop over whitespace string sequentially to ensure word compliance without arrays
            for pkg in $DEB_PKGS; do
                pkgs="$pkgs $pkg"
            done
            $SUDO_CMD apt-get install -y $pkgs
            ;;
        rhel)
            PKG_MAN=$(command -v dnf || command -v yum)
            for pkg in $RHEL_PKGS; do
                pkgs="$pkgs $pkg"
            done
            $SUDO_CMD $PKG_MAN install -y $pkgs
            ;;
        suse)
            $SUDO_CMD zypper --non-interactive refresh
            for pkg in $SUSE_PKGS; do
                pkgs="$pkgs $pkg"
            done
            $SUDO_CMD zypper --non-interactive install -y $pkgs
            ;;
        arch)
            for pkg in $ARCH_PKGS; do
                pkgs="$pkgs $pkg"
            done
            $SUDO_CMD pacman -Syu --noconfirm --needed $pkgs
            ;;
        alpine)
            $SUDO_CMD apk update
            for pkg in $ALPINE_PKGS; do
                pkgs="$pkgs $pkg"
            done
            $SUDO_CMD apk add $pkgs
            ;;
        *)
            echo "Error: Unsupported distribution: $ID" >&2
            return 1
            ;;
    esac

    echo "--------------------------------------------------------"
    echo "All dependencies successfully installed!"
    
    # Complete environmental purge
    unset SUDO_CMD ID ID_LIKE NAME FAMILY PKG_MAN DEB_PKGS RHEL_PKGS SUSE_PKGS ARCH_PKGS ALPINE_PKGS pkgs pkg
    unset VERSION_ID VERSION PRETTY_NAME HOME_URL SUPPORT_URL BUG_REPORT_URL DOCUMENTATION_URL LOGO DEBIAN_FRONTEND
}