#!/bin/sh
# Source this file: . ./license_request.sh

# ==========================================
# Script Variables
# ==========================================
LICENSE_FILE="../.licensekey"
SERVICE_NAME="ssldeploy"
SYSTEM_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || echo "default-uuid")
TIMESTAMP=$(date +%s)
RANDOM_6_DIGIT=$(awk 'BEGIN{srand();print int(rand()*900000)+100000}')

# ==========================================
# License Key Generation and Support Pin Request
# ==========================================

license_request() {

    echo "Generating license request..."
    
    # Check if the license file already exists in app root folder
    if [ -f "$LICENSE_FILE" ]; then
        echo "License file already exists at $LICENSE_FILE. Skipping license request."
    else
        echo "Requesting license from Propstat..."
        # Generate Unique SHA256 License Key and Request Support Pin
        RAW_STRING="${SYSTEM_UUID}-${TIMESTAMP}-${RANDOM_6_DIGIT}"
        GENERATED_KEY=$(echo -n "$RAW_STRING" | shasum -a 256 | awk '{print $1}')

        TMP_RESPONSE_FILE=$(mktemp)
        HTTP_STATUS=$(curl -s -o "$TMP_RESPONSE_FILE" -w "%{http_code}" -X POST https://license.propstat.org/license/getlicense \
            -d "key=${GENERATED_KEY}" \
            -d "productSKU=${SERVICE_NAME}")

        if [ "$HTTP_STATUS" -eq 200 ]; then
            PARSED_KEY=$(awk -F ' *= *' '$1=="key"{print $2}' "$TMP_RESPONSE_FILE")
            PARSED_PIN=$(awk -F ' *= *' '$1=="pin"{print $2}' "$TMP_RESPONSE_FILE")
            PARSED_TIMESTAMP=$(awk -F ' *= *' '$1=="timestamp"{print $2}' "$TMP_RESPONSE_FILE")

            {
                echo "key = ${PARSED_KEY}"
                echo "pin = ${PARSED_PIN}"
                echo "timestamp = ${PARSED_TIMESTAMP}"
            } >> "$LICENSE_FILE"

            echo "License retrieved and bound successfully."
        else
            echo "Error: Server responded with status ${HTTP_STATUS}"
            cat "$TMP_RESPONSE_FILE"
        fi

        # Clean up temporary file
        rm -f "$TMP_RESPONSE_FILE"
    fi

    echo "License has been successfully generated and stored in $LICENSE_FILE."
    unset SYSTEM_UUID TIMESTAMP RANDOM_6_DIGIT RAW_STRING GENERATED_KEY TMP_RESPONSE_FILE HTTP_STATUS PARSED_KEY PARSED_PIN PARSED_TIMESTAMP

}