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

# Check if folder exists
if [ -d "$TARGET_DIR" ]; then
    echo "Directory $TARGET_DIR already exists."
    echo "What do you want to do?"
    echo "1) Update / Re-install (not implemented yet)"
    echo "2) Remove"
    echo "3) Exit"
    read -rp "Choose [1-3]: " choice
else
    echo "SSLEDeploy not found. It will be installed."
    choice="install"
fi

install() {
    # ==========================================
    # Copyright & License Warning
    # ==========================================

    date +"Copyright 2026 - YYYY by Propstat"
    echo "Non commercial use is free of charge, please consult our license for commercial use."
    echo "The license is available at https://github.com/propstat/ssldeploy"

    # ==========================================
    # Accept License
    # ==========================================

    while true; do
        echo "Do you accept the license?"
        echo "Type Y(es) to continue or N(o) to abort."
        read -p "#? " reply

        case $reply in
            1 | Yes | yes | y | Y ) 
                make install
                break
                ;;
            2 | No | no | n | N ) 
                echo "Installation aborted."
                exit 0
                ;;
            * ) 
                echo "Invalid option. Please try again."
                echo ""
                ;;
        esac
    done
    echo "Cloning repository..."
    git clone "$REPO_URL" "$TARGET_DIR"

    echo "Making install script executable..."
    chmod +x "$INSTALL_SCRIPT"

    echo "Running install script..."
    "$INSTALL_SCRIPT"
}

remove() {
    echo "Stopping and removing service (if exists)..."

    if command -v systemctl >/dev/null 2>&1; then
        if systemctl list-units --type=service | grep -q "${SERVICE_NAME}"; then
            sudo systemctl stop "${SERVICE_NAME}" || true
            sudo systemctl disable "${SERVICE_NAME}" || true
            sudo systemctl daemon-reload || true
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
        echo "Update / Re-install selected (not implemented yet)."
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