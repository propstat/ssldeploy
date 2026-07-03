#!/bin/sh
# ==========================================
# Certificate Mode Helper
# This script is used to enable development mode for the SSLEDeploy project.
# It uses flask run instead of gunicorn to run the application and set the 
# which automatically sets the environment variable FLASK_ENV=development
# to enable debug mode and makes the tailwind binaries executable.
# ==========================================

mode_selector() {
    printf '# SSL Deploy - A Flask-based web application for managing SSL/TLS certificate deployments\n' > ../.env
    # Sets the FLASK_APP environment variable to ssldeploy.py in the .env file
    printf 'FLASK_APP=ssldeploy.py\n' >> ../.env
    # Sets the ssldeployMode environment variable in the .env file
    printf 'ssldeployMode=%s\n' "$ssldeploymode" >> ../.env
    printf "Successfully created ../.env with ssldeployMode=%s\n" "$ssldeploymode"
    unset answer ssldeploymode
}