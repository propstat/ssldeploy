#!/bin/sh
# ==========================================
# DEV Mode Helper
# This script is used to enable development mode for the SSLEDeploy project.
# It uses flask run instead of gunicorn to run the application and set the 
# which automatically sets the environment variable FLASK_ENV=development
# to enable debug mode and makes the tailwind binaries executable.
# ==========================================


