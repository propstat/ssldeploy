#!/bin/sh
# ==========================================
# Certificate Mode Helper
# This script is used to enable development mode for the SSLEDeploy project.
# It uses flask run instead of gunicorn to run the application and set the 
# which automatically sets the environment variable FLASK_ENV=development
# to enable debug mode and makes the tailwind binaries executable.
# ==========================================

mode_selector() {
    # 1. Standard POSIX prompt (works flawlessly on BusyBox/Alpine)
    printf "Is this a production deployment? (y/n): "
    read -r answer

    # 2. POSIX case matching (supported by dash, bash, and busybox ash)
    case "$answer" in
        [Yy]* ) ssldeploymode="production";;
        * )     ssldeploymode="development";;
    esac

    # 3. Chained printf to guarantee NO trailing/leading space issues in any environment
    printf '# SSL Deploy - A Flask-based web application for managing SSL/TLS certificate deployments\n' > ../.env
    printf 'FLASK_APP=ssldeploy.py\n' >> ../.env
    printf 'ssldeployMode=%s\n' "$ssldeploymode" >> ../.env

    printf "Successfully created ../.env with ssldeployMode=%s\n" "$ssldeploymode"
    
    # 4. Clean up environment variables to prevent leakage
    unset answer ssldeploymode
}