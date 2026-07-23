#!/bin/sh
set -euo pipefail
REPO_URL="https://github.com/propstat/ssldeploy"
TARGET_DIR="$HOME/ssldeploy"
INSTALL_SCRIPT="$TARGET_DIR/install/install.sh"
SERVICE_NAME="ssldeploy"
RED=$(printf '\033[0;31m')
NC=$(printf '\033[0m')

# ==========================================
# LOGO
# ==========================================
cat << EOF


=========================================================

            il*%%%%*             i%%%%%%%           
           iiiI*%%%%%           iii*%%%%*%          
          iiiiii%%%%%%         iiiii%*%%%*%         
         iiiiiii %%%%%%       iiiiii %*%%%%%        
        iiiiiii   *%%%%%%   iiiiiii   **%%%%*       
       iiiiiii     *%%%%%% iiiiiii     %*%%%%*      
      iiiiiii       **%%%**iiiiii       *%%%%*%     
     iiiiiii         *%%%%*<iiii         **%%%**    
    iiiiiii           %*%%%**ii           *%%%%*%   
   iiiiiiiiiiiiiiiiiiii%%%%%%*%%%%%%%%%%%%%%%%%%%*  
  iiiiiiiiiiiiiiiiiiiiii%*%%%%%%%%%%%%%%%%%%%%%%%%* 
 iiiiiiiiiiiiiiiiiiiiiiii**%%%%%%%%%%%%%%%%%%%%%%%%%
                                                   
iiiii  iiiiii iiiiii  iiiii  iiiiii iiiiii  iii  iiiiii
ii  ii ii  ii ii  ii  ii  ii  ii     ii    ii ii   ii  
iiiii  iiiiii ii  ii  iiiii     ii   ii   iiiiiii  ii  
ii     ii  ii iiiiii  ii     iiiiii  ii   ii   ii  ii  

=========================================================
SSL Deploy Setup Wizard
=========================================================
Non-Commercial use is free of charge, please consult our
license for commercial use.
License: https://github.com/propstat/ssldeploy
=========================================================
${RED}YOU ARE DOWNLOADING MATERIAL COVERED BY COPYRIGHT AND${NC}
${RED}LICENSED UNDER THE PROPSTAT LICENSE. DO NOT CONTINUE IF${NC}
${RED}YOU DO NOT AGREE TO THE LICENSE TERMS.${NC}
=========================================================
EOF

while true; do
    printf "Do you want to continue? (y/n): "
    read -r reply

    case "$reply" in
        y|Y|yes|YES|Yes)
            break
            ;;
        n|N|no|NO|No)
            echo "Installation aborted."
            exit 0
            ;;
        *)
            echo "Invalid option. Please try again."
            ;;
    esac
done

# Detect existing install (Safe from set -e)
# Update Logic is not written yet
choice="install"
if [ -d "$TARGET_DIR" ]; then
    echo "Directory already exists: $TARGET_DIR"
    echo "What do you want to do?"
    echo "1) Update (NOT IMPLEMENTED YET)"
    echo "2) Remove"
    echo "3) Exit"
    read -rp "Choose [1-3]: " choice
else
    echo "SSLDeploy not found. The installation process will begin."
fi

install() {
    echo "Starting installation..."

    # Safe clone or update
    if [ -d "$TARGET_DIR/.git" ]; then
        echo "Existing git repo detected → updating..."
        # git -C "$TARGET_DIR" pull is not yet implemented
        echo "Coming soon..."
    else
        echo "Cloning repository..."
        
        # Step out of the target directory to prevent missing CWD errors
        cd "$HOME"
        
        rm -rf "$TARGET_DIR"
        git clone "$REPO_URL" "$TARGET_DIR"
        cd "$TARGET_DIR"
    fi

    # Validate install script exists
    if [ ! -f "$INSTALL_SCRIPT" ]; then
        echo "ERROR: install script not found: $INSTALL_SCRIPT"
        exit 1
    fi

    chmod +x "$INSTALL_SCRIPT"

    echo "Running install script..."
    # cd directly into the installer folder so its internal paths don't break
    cd "$TARGET_DIR/install"
    ./install.sh
}

remove() {
    echo "Stopping and removing service (if exists)..."
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl list-unit-files | grep -q "^${SERVICE_NAME}.service"; then
            systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
            systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
            systemctl daemon-reload || true
            echo "Service removed."
        else
            echo "Service not found."
        fi
    else
        echo "systemd not found, skipping service removal."
    fi

    echo "Deleting $TARGET_DIR..."
    rm -rf "$TARGET_DIR"
    # -------------------------
    # Remove lego binary
    # -------------------------
    echo "Removing lego binary..."

    LEGO_SYSTEM_FILE="/usr/local/bin/lego"

    if [ -f "$LEGO_SYSTEM_FILE" ]; then
        SUDO_CMD=""
        if [ "$(id -u)" -ne 0 ]; then
            if command -v sudo >/dev/null 2>&1; then
                SUDO_CMD="sudo"
            elif command -v doas >/dev/null 2>&1; then
                SUDO_CMD="doas"
            else
                echo "Warning: cannot remove $LEGO_SYSTEM_FILE (no sudo/doas)." >&2
            fi
        fi

        if [ "$(id -u)" -eq 0 ] || [ -n "$SUDO_CMD" ]; then
            if $SUDO_CMD rm -f "$LEGO_SYSTEM_FILE"; then
                echo "Removed $LEGO_SYSTEM_FILE"
            else
                echo "Warning: failed to remove $LEGO_SYSTEM_FILE" >&2
            fi
        fi
    else
        echo "Lego binary not found, skipping."
    fi

    unset LEGO_SYSTEM_FILE SUDO_CMD

    echo "Removed successfully."
}

case "$choice" in
    install|1)
        install
        ;;
    2)
        remove
        ;;
    3)
        echo "Exit."
        exit 0
        ;;
    *)
        echo "Invalid option."
        exit 1
        ;;
esac