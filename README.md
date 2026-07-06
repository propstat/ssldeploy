> [!CAUTION]
> This app is under active development and not considered stable as of today.
> We aim for support for Ubuntu Server, RHEL AND SUSE.

# ssldeploy
![Screenshot of SSL Deploy Admin Dashboard](/documentation/screenshots/screenshot-admin-dashboard.png)
A flask based web interface to deploy let's encrypt certificates to various services without compromising domain management credentials.

## Introduction
**Let's encrypt** and **certbot** have dramatically improved the availability of certificates. Unfortunately, DNS authentication is today one of he leading means of distributing the certificates, frequently at the expense of a good security strategy. **ssldeploy** allows you to centralize the DNS authentication, certificate creation and deployment of your SSL certificates in a safe part of your network, distant from the edge. To keep the package simple, easy to backup and portable SQLlite was chosen given that even if used for 1000s of servers, the effective processing and I/O effort is negligible. 

## Features
1. Certificate creation via Certbot and Certbot DNS
2. Deployment of certificates to taget systems
3. Certificate Check on target
4. Self Servicing and Approval Processes for Certificates
5. Single Sign-On Supported for Google and Microsoft with Group Level Privilege Assignment

## Limitations

### Let's Encrypt Rate Limitations
Let's Encrypt limit certificates in multiple ways. The most important one is a limit of [50 certificates per domain](https://letsencrypt.org/docs/rate-limits/).
To request an increase of rate limits [visit this link](https://isrg.formstack.com/forms/rate_limit_adjustment_request).

## How do I run this

### Installation

Run following command to start the installation wizard (requires internet connection). You will be able to select the development or production mode 
during installation with the appropriate dependencies automatically installed. 

```bash
sh -c 'tmp=$(mktemp) || exit 1; url="https://raw.githubusercontent.com/propstat/ssldeploy/main/install/ssldeploy-setup-wizard.sh"; url="$url?nocache=$(date +%s)"; if command -v curl >/dev/null 2>&1; then curl -fsSL "$url" -o "$tmp"; elif command -v wget >/dev/null 2>&1; then wget -qO "$tmp" "$url"; else echo "Error: need curl or wget" >&2; exit 1; fi; chmod +x "$tmp"; sh "$tmp"'
```

### Development & Debug Mode

> [!CAUTION]
> While you can develop on MacOS (as we personally do) you should always test on supported Linux systems.  

1. Navigate to the folder.
2. Activate venv with `source venv/bin/activate`.
3. Define the python.py as FLASK_APP by `export FLASK_APP=ssldeploy.py`.
4. `flask run` will run on your localhost at the default python port (usually http://127.0.0.1:5000/) with --debug and tailwind-cli by default enabled. Werkzeug will actively avoid duplicate instances of tailwind. 

If you have made modifications to css and templates run `./tools/tailwind/tailwindcss-macos-arm64-v430 -i ./tools/tailwind/input.css -o ./static/css/ssldeploy.css --watch` or your O/S equivalent.

### Known Issues

#### Tailwind Cli on MacOS 
MacOS does have the nasty habbit to reject unsigned packages, as @tailwindlabs does not sign the package, you might have to move it out of quarantine. MacOS will report the file as "damaged" asking you to delete it. 
Issue #9 describes the issue at extend.

![Error when launching tailwind-cli on macOS](/documentation/screenshots/knownissues-error-tailwindcli-macos.png)

```bash
cd ./tools/tailwind/tailwind-macos-*-v*** # Replace * with your architecture and version
xattr -l tailwind-macos-*-v*** # Replace * with your architecture and version
xattr -d com.apple.quarantine tailwind-macos-*-v*** # Replace * with your architecture and version
chmod +x tailwind-macos-*-v*** # Replace * with your architecture and version
./tailwindcss-macos-arm64 --help # Test if you can run the file without errors now. 
```

## Why is this better than the alternatives?

## What security precautions have been taken to secure your credentials and certificates?

DNS authentication credentials, target system credentials and certificates are not available on the front-end. While you can create, update and delete credentials, viewing them remains impossible in lack of endpoints. 

## Supported DNS creation

# Privacy
You can find the fully privacy agreement on https://propstat.org/privacy.

# License 

## SSL Deploy
This software is covered by a source available license, commercial use requires you to contact us to discuss a commercial license. 

## UI / UX
We have made extensive use of Tailwind Plus components. Any commercial use requires you to purchase a proper Tailwind license. 
The full license and restrictions we adhere to can be found in the full [Tailwind License](https://tailwindcss.com/plus/license).
More information about purchasing Tailwind can be found on the [Tailwind website](https://tailwindcss.com/plus#pricing).
