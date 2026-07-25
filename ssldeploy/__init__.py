import os
import subprocess
import threading
from pathlib import Path

from flask import Flask
from config import Config
from flask_sqlalchemy import SQLAlchemy
from flask_migrate import Migrate
from flask_login import LoginManager


# 1. Detect if we are running via `flask run`
def is_flask_dev():
    return os.environ.get("FLASK_RUN_FROM_CLI") == "true"


# 2. FORCE Debug mode always when using `flask run`
# Environment variables require strings, so we use the string "true"
if is_flask_dev():
    os.environ["FLASK_DEBUG"] = "true"


ssldeploy = Flask(__name__)
ssldeploy.config.from_object(Config)


# Initialize database and migration objects after app is created
db = SQLAlchemy(ssldeploy)
migrate = Migrate(ssldeploy, db)


# Flask configuration dicts require Python booleans, so we use True
if is_flask_dev():
    ssldeploy.config["DEBUG"] = True


# Application root directory
APP_ROOT = Path(__file__).resolve().parent.parent


# Tailwind paths
TAILWIND_BINARY = APP_ROOT / "tools" / "tailwind" / "tailwind-cli"
TAILWIND_INPUT = APP_ROOT / "tools" / "tailwind" / "input.css"
TAILWIND_OUTPUT = APP_ROOT / "ssldeploy" / "static" / "css" / "ssldeploy.css"


def run_tailwind():
    """
    Start Tailwind CLI watcher in development mode.
    The installer guarantees the binary exists at:
    ./tools/tailwind/tailwind-cli
    """

    if not TAILWIND_BINARY.exists():
        raise FileNotFoundError(
            f"Tailwind CLI missing: {TAILWIND_BINARY}. "
            "Please run the installer again."
        )

    subprocess.run(
        [
            str(TAILWIND_BINARY),
            "-i",
            str(TAILWIND_INPUT),
            "-o",
            str(TAILWIND_OUTPUT),
            "--watch",
        ],
        check=True,
    )


def start_tailwind_if_dev():
    if is_flask_dev():
        # Werkzeug sets this to "true" only for the main reloader process
        if os.environ.get("WERKZEUG_RUN_MAIN") == "true":
            t = threading.Thread(target=run_tailwind)
            t.daemon = True
            t.start()


# Start Tailwind (guarded to only run during `flask run` + main reloader thread)
start_tailwind_if_dev()


# Clean logging blocks
if is_flask_dev():
    if os.environ.get("WERKZEUG_RUN_MAIN") == "true":
        ssldeploy.logger.info(
            "⚡ Dev mode: Tailwind + Flask debug enabled"
        )
else:
    # Gunicorn ignores WERKZEUG_RUN_MAIN and lands safely here
    ssldeploy.logger.info(
        "🚀 Production mode: Gunicorn active (Tailwind disabled)"
    )


from ssldeploy import routes, models