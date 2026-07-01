#!/usr/bin/env bash
set -euo pipefail
REPO_URL="https://github.com/propstat/ssldeploy"
TARGET_DIR="$HOME/ssldeploy"
INSTALL_SCRIPT="$TARGET_DIR/install/install.sh"
SERVICE_NAME="ssldeploy"
RED=$'\e[0;31m'

# ==========================================
# LOGO
# ==========================================
cat << "EOF"
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
    echo "1) Update (WARNING EXPERIMENTAL)"
    echo "2) Remove"
    echo "3) Exit"
    read -rp "Choose [1-3]: " choice
else
    echo "SSLEDeploy not found. The installation process will begin."
fi

install() {
    echo "Installing / Updating..."

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
        
        # Change into the directory to work locally
        cd "$TARGET_DIR"
        
        # Create License File and Log Acceptance (to avoid duplicate request by install.sh)
        touch ".license"
        echo "License file created."
        echo "licenseAccepted=true" > ".license"
        echo "License Acceptance Logged."
        echo "Requesting License Key and Support Pin from Propstat."

        # Generate Unique SHA256 License Key and Request Support Pin
        echo "Detecting System Hardware UUID for License Key Generation."
        
        case "${OSTYPE:-}" in
            darwin*)
                MACHINE_ID=$(ioreg -d2 -c IOPlatformExpertDevice | awk -F\" '/IOPlatformUUID/ {print $4}')
                ;;
            *)
                if [ -f /etc/machine-id ]; then
                    MACHINE_ID=$(cat /etc/machine-id)
                elif [ -f /var/lib/dbus/machine-id ]; then
                    MACHINE_ID=$(cat /var/lib/dbus/machine-id)
                else
                    MACHINE_ID="unknown-fallback-id"
                fi
                ;;
        esac

        echo "Generating Additional Randomized License Key Components."
        TIMESTAMP=$(date +%s)
        RANDOM_6_DIGIT=$(head -c 512 /dev/urandom | tr -dc '0-9' | head -c 6)

        RAW_STRING="${MACHINE_ID}${TIMESTAMP}${RANDOM_6_DIGIT}"
        GENERATED_KEY=$(echo -n "$RAW_STRING" | shasum -a 256 | awk '{print $1}')

        TMP_RESPONSE_FILE=$(mktemp)
        echo "Requesting License Key from Propstat and Support Pin."
        HTTP_STATUS=$(curl -s -o "$TMP_RESPONSE_FILE" -w "%{http_code}" -X POST https://license.propstat.org/license/getlicense \
            -d "key=${GENERATED_KEY}" \
            -d "productSKU=${SERVICE_NAME}")

        if [ "$HTTP_STATUS" -eq 200 ] || [ "$HTTP_STATUS" -eq 201 ]; then
            # 5. Parse key, pin, and timestamp from the server's payload
            PARSED_KEY=$(awk -F ' *= *' '$1=="key"{print $2}' "$TMP_RESPONSE_FILE")
            PARSED_PIN=$(awk -F ' *= *' '$1=="pin"{print $2}' "$TMP_RESPONSE_FILE")
            PARSED_TIMESTAMP=$(awk -F ' *= *' '$1=="timestamp"{print $2}' "$TMP_RESPONSE_FILE")

            {
                echo "key = ${PARSED_KEY}"
                echo "pin = ${PARSED_PIN}"
                echo "timestamp = ${PARSED_TIMESTAMP}"
            } >> ".license"

            echo "License retrieved and bound successfully."
        else
            echo "Error: Server responded with status ${HTTP_STATUS}"
            cat "$TMP_RESPONSE_FILE"
        fi

        # Clean up temporary file
        rm -f "$TMP_RESPONSE_FILE"
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