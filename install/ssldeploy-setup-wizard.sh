#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/propstat/ssldeploy"
TARGET_DIR="$HOME/ssldeploy"
INSTALL_SCRIPT="$TARGET_DIR/install/install.sh"
SERVICE_NAME="ssldeploy"

# ==========================================
# LOGO
# ==========================================
cat << "EOF"

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

EOF

echo "=== SSLEDeploy Manager ==="

# Detect existing install
if [ -d "$TARGET_DIR" ]; then
    echo "Directory already exists: $TARGET_DIR"
    echo "What do you want to do?"
    echo "1) Update / Re-install"
    echo "2) Remove"
    echo "3) Exit"
    read -rp "Choose [1-3]: " choice
else
    echo "SSLEDeploy not found. It will be installed."
    choice="install"
fi

install() {
    date +"Copyright %Y by Propstat"
    echo "Non commercial use is free of charge, please consult our license for commercial use."
    echo "License: https://github.com/propstat/ssldeploy"
    echo ""

    while true; do
        printf "Do you accept the license? (y/n): "
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

    echo "Installing / Updating..."

    # Safe clone or update
    if [ -d "$TARGET_DIR/.git" ]; then
        echo "Existing git repo detected → updating..."
        git -C "$TARGET_DIR" pull
    else
        echo "Cloning repository..."
        rm -rf "$TARGET_DIR"
        git clone "$REPO_URL" "$TARGET_DIR"
    fi

    # Validate install script exists
    if [ ! -f "$INSTALL_SCRIPT" ]; then
        echo "ERROR: install script not found: $INSTALL_SCRIPT"
        exit 1
    fi

    chmod +x "$INSTALL_SCRIPT"

    echo "Running install script..."
    "$INSTALL_SCRIPT"
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

    echo "Removed successfully."
}

case "$choice" in
    install)
        install
        ;;
    1)
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