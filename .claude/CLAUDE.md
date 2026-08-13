# CLAUDE.md — SSLDeploy

## Project Overview

SSLDeploy is a Flask-based web/API application for managing DNS-01 ACME certificate issuance and deployment.

The project is intended to provide a controlled interface around the ACME client `lego`, while keeping DNS credentials and deployment credentials in the secrets manager OpenBao.

Primary repository:

- GitHub: `https://github.com/propstat/ssldeploy`

## Core Goals

When modifying SSLDeploy, preserve these principles:

1. **Security first**
   - Never expose DNS credentials, deployment credentials, private keys, API tokens, passwords, or OpenBao credentials in logs, API responses, HTML, exceptions, Git history, or test output.
   - Do not put secrets directly into source code.
   - Prefer environment/configuration references and OpenBao for persistent secrets.
   - Avoid unnecessarily broad permissions for credentials.
   - Validate all user-controlled input.

2. **DNS-01 only**
   - SSLDeploy is designed around DNS-01 ACME validation.
   - Do not introduce HTTP-01 or TLS-ALPN-01 workflows unless explicitly requested.

3. **Non-root operation where possible**
   - Certificate requests and application operations should not require root unless the specific deployment target requires privileged access.
   - Do not assume that the application runs as root other than unsealing openbao at boot.

4. **Reproducibility**
   - Prefer deterministic configuration and explicit dependencies.
   - Keep development, test, and production behavior clearly separated.

5. **Backward compatibility**
   - Avoid breaking existing CLI/API behavior unless the change explicitly requires it.
   - Preserve existing configuration names and data formats when practical.

6. **Easy Install via Shell**
   - the ssldeploy-setup-wizard.sh allows to invoke install.sh to install the application easily
   - the environment is setup through install.sh and the scripts in the /install/helpers folder
   - the application should run on Ubuntu, Debian, SEL, Redhat, Arch and Alpine

---

## Technology Stack

The application currently uses or is expected to use:

- Python
- Flask
- Flask-WTF
- SQLAlchemy
- SQLite by default
- Jinja2 templates
- Tailwind CSS via the standalone `tailwind-cli` binary
- ACME clients, primarily `lego`
- OpenBao for secrets
- Linux/POSIX shell integration
- PAM authentication
- Planned/optional LDAP and Active Directory authentication
- GitHub Actions for CI

Do not introduce a Node/npm dependency merely to use Tailwind. The project uses the standalone Tailwind CLI.

---

## Repository Structure

Follow the existing repository structure rather than inventing new top-level directories.

Important areas include:

- Flask application code
- `routes.py` — HTTP routes
- `forms.py` — Flask-WTF forms
- Jinja templates
- static assets
- Tailwind assets/configuration
- tests
- shell/CLI integration
- certificate and credential storage configuration

Before making structural changes, inspect the repository and follow existing conventions.

---

## Flask Application

### Application configuration

Configuration is environment-driven, with `.env` used during local development.

Never commit:

- `.env`
- generated Flask `SECRET_KEY`
- OpenBao tokens
- DNS API credentials
- deployment credentials
- ACME account private keys
- TLS private keys

If a new secret configuration value is required:

1. Add it to the appropriate example/configuration documentation.
2. Keep the real value out of Git.
3. Validate it at application startup or at the point where it is required.
4. Do not silently fall back to an insecure default.

### SECRET_KEY

The Flask `SECRET_KEY` must be generated securely and supplied through configuration.

Do not use:

- predictable strings
- repository constants
- timestamps
- usernames
- domain names

Do not print the secret during debugging.

### Database

SQLAlchemy/SQLite is used by default.

Database paths must be configurable and must not depend on the current working directory unless that is explicitly the established project behavior.

Use migrations or the project's existing database mechanism when changing persistent schema.

---

## Authentication

The administrative interface is protected authentication.

The current authentication model includes a realm selection concept:

- `pam`
- `ldap`
- `ad`

PAM is currently the primary implemented authentication mechanism.

Relevant form fields include:

- `admin_login_username`
- `admin_login_password`
- `admin_login_rememberme`
- `admin_login_realm`

Do not weaken authentication to make tests or development easier.

### PAM

PAM authentication should be performed through the existing Flask/PAM integration.

Do not implement password verification manually.

### LDAP / Active Directory

LDAP/AD support should use configurable:

- server/domain
- bind user
- bind password
- base DN
- administrator group

Do not hard-code organization-specific LDAP information.

The intended administrator group is:

`SSL Deploy Administrators`

Treat LDAP/AD credentials as secrets.

---

## Authorization

Distinguish authentication from authorization.

A successfully authenticated user must not automatically receive unrestricted access to every secret or deployment operation.

Sensitive operations include:

- creating DNS credential secrets
- deleting DNS credential secrets
- reading credentials
- modifying deployment targets
- deleting deployment credentials
- requesting certificates
- triggering deployments

Prefer explicit authorization checks at the server side.

Never rely on hiding UI controls as an authorization mechanism.

---

## OpenBao

OpenBao is the preferred secret store for long-lived DNS and deployment credentials.

### Secret types

SSLDeploy may need to store:

1. DNS provider credentials used to complete ACME DNS-01 challenges.
2. Deployment target credentials used to install certificates.
3. Other provider-specific secrets required by deployment integrations.

Certificate/private-key material should not automatically be treated as equivalent to credentials. Follow the project's explicit storage design for certificate material.

### OpenBao access model

The Flask application needs privileges to:

- create secrets
- delete secrets
- manage the relevant secret metadata/path

The certificate-requesting shell/CLI side should normally have a much narrower capability:

- read the required secret

Do not give the shell client create/delete/admin privileges merely because the Flask application has them.

### OpenBao credentials

The credential used by Flask to access OpenBao is itself a secret.

Do not store it:

- in the Git repository
- in source code
- in HTML
- in SQLite
- in command-line arguments where it can appear in process listings
- in application logs

Prefer a mechanism appropriate to the deployment environment, such as a protected environment variable, file descriptor, systemd credential, workload identity, or equivalent secret injection mechanism.

### Secret paths

Do not expose raw OpenBao paths directly to untrusted users.

Use an application-level identifier and map it to an allowed secret path.

Validate paths to prevent traversal or access outside the application's configured secret namespace.

---

## ACME / Certificate Handling

SSLDeploy is focused on DNS-01 ACME issuance.

The project may use `lego` as the underlying ACME client.

When invoking an ACME client:

- construct arguments without shell interpolation where possible
- avoid logging credential arguments
- use temporary files with restrictive permissions when a credential file is unavoidable
- clean up temporary credential files
- verify file ownership and permissions
- do not pass secrets in URLs
- do not expose private keys in API responses unless explicitly required

### DNS credentials

DNS credentials must be provider-specific.

Do not assume that all providers use the same credential format.

Provider configuration should remain extensible.

When adding a provider:

1. Check whether the underlying ACME client supports it.
2. Follow its documented credential mechanism.
3. Keep provider-specific configuration isolated.
4. Add tests for credential creation/read/delete behavior.
5. Ensure secrets are not exposed by logs or error messages.

---

## Certificate Deployment

Deployment targets may include systems such as:

- web servers
- appliances
- servers
- management interfaces

Deployment credentials must be stored separately from DNS credentials.

A certificate request should not automatically imply unrestricted deployment privileges.

Deployment code must:

- validate the target
- authenticate securely
- verify TLS appropriately
- avoid disabling certificate verification globally
- avoid logging credentials
- handle partial deployment failures
- report useful but non-sensitive errors

---

## Shell / CLI Interface

Certificate requests may be initiated from a shell environment.

The shell client should be treated as a lower-trust consumer of secrets.

Preferred flow:

1. Authenticate to SSLDeploy/OpenBao using a narrowly scoped credential.
2. Retrieve only the required DNS/deployment secret.
3. Use it for the requested operation.
4. Avoid writing it to persistent storage.
5. Remove temporary material after use.

Do not put long-lived privileged OpenBao credentials directly into shell scripts.

Use quoting that is safe for POSIX shells.

Do not assume Bash-specific syntax in scripts described as POSIX shell scripts.

---

## Tailwind

The project uses the standalone Tailwind CLI rather than npm.

Development behavior may depend on:

`ssldeployMode=development`

Do not add npm, Node, or a JavaScript build chain solely to compile Tailwind unless explicitly requested.

Keep generated CSS/build artifacts consistent with the repository's existing workflow.

---

## API Design

API endpoints must:

- validate all input
- authenticate requests
- authorize operations
- return appropriate HTTP status codes
- avoid leaking internal exceptions
- avoid returning secrets
- use structured responses consistently with existing project conventions

Never expose:

- OpenBao tokens
- DNS credentials
- deployment passwords
- private keys
- internal stack traces

in normal API responses.

For errors, return a safe external message and log detailed diagnostic information only when it contains no secrets.

---

## Web Forms

Forms use Flask-WTF where appropriate.

For every state-changing browser request:

- use CSRF protection
- validate fields server-side
- do not trust browser-side validation
- normalize input where appropriate
- avoid reflecting secrets into templates

Password and token fields should use appropriate password/input types and must never be repopulated after submission.

---

## Security Rules

### Never do this

```python
print(api_token)
logger.debug("credentials=%s", credentials)
return jsonify({"password": password})
```

Do not:

- commit secrets
- hard-code API tokens
- disable TLS verification to fix connection problems
- execute user-provided strings through `shell=True`
- construct shell commands by string concatenation
- trust filenames supplied by users
- expose exception tracebacks in production
- use weak random-number generation for secrets
- store passwords in plaintext unless the external system explicitly requires a recoverable credential

### Command execution

When invoking `lego`, system utilities, or deployment commands:

- prefer `subprocess.run([...], shell=False)`
- pass arguments as an array
- use explicit executable paths when appropriate
- set controlled environment variables
- avoid inheriting unnecessary secrets
- capture output carefully
- sanitize output before logging

---

## Logging

Logs are useful for diagnosing:

- certificate requests
- DNS validation failures
- deployment failures
- authentication failures
- OpenBao connectivity problems

Logs must never contain:

- passwords
- API tokens
- OpenBao tokens
- private keys
- complete credential files
- secret values
- authorization headers

If an external command prints credentials, redact them before logging.

Use stable identifiers instead of secret values.

---

## Testing

Every security-sensitive feature should include tests.

Prioritize tests for:

- authentication
- authorization
- CSRF
- secret creation
- secret deletion
- secret retrieval
- OpenBao failures
- invalid secret identifiers
- provider credential handling
- command construction
- certificate request failures
- deployment failures
- access control boundaries

Tests must not use real production credentials.

Use deterministic test fixtures and mocks for external services where appropriate.

Never add a real API token to a test fixture.

---

## Development Workflow

Before changing code:

1. Inspect the relevant existing implementation.
2. Inspect related tests.
3. Follow established naming and architecture.
4. Make the smallest change that solves the problem.
5. Add or update tests.
6. Run the relevant test suite.
7. Run formatting/linting checks used by the repository.
8. Check the Git diff for accidentally added secrets.

Do not perform broad refactors while implementing an unrelated feature or bugfix.

---

## Git

Keep commits focused.

Do not commit:

- `.env`
- generated credentials
- certificate private keys
- temporary files
- local databases containing secrets
- build output unless explicitly tracked by the project

Before committing a security-sensitive change, inspect:

```sh
git diff
git status
```

Look specifically for accidental secret exposure.

---

## Environment Compatibility

SSLDeploy is expected to run on Linux systems and may be deployed on distributions including Debian/Ubuntu and other enterprise Linux environments.

Avoid assumptions about:

- `/bin/bash` when writing POSIX scripts
- systemd being present
- package manager availability
- filesystem layout
- root privileges
- OpenBao installation paths

When platform-specific behavior is required, isolate it and document it.

---

## Dependency Policy

Prefer existing dependencies.

Before adding a dependency:

1. Determine whether the standard library or an existing dependency can solve the problem.
2. Check whether the dependency is actively maintained.
3. Consider its security implications.
4. Keep the dependency narrowly scoped.
5. Update the appropriate dependency metadata and tests.

Do not add a JavaScript package solely because a standalone CLI already solves the problem.

---

## Error Handling

Errors should be actionable without revealing sensitive information.

Good:

> DNS validation failed for the requested domain. Check the configured DNS provider credentials and DNS propagation.

Bad:

> AWS_ACCESS_KEY_ID=AKIA... AWS_SECRET_ACCESS_KEY=... failed while executing...

Preserve the original exception for internal debugging where appropriate, but sanitize anything exposed to users or logs.

---

## When Working on Credentials

Always distinguish between:

- a credential identifier
- a credential reference
- a credential value

Application code should normally operate on identifiers/references and retrieve the actual value only at the last responsible moment.

Avoid passing credential values through unnecessary layers.

---

## When Working on Certificate Private Keys

Private keys are highly sensitive.

Do not:

- log them
- include them in exceptions
- return them from unrelated API endpoints
- store them in Git
- leave temporary copies behind

Use restrictive filesystem permissions for temporary files and clean them up reliably.

---

## Pull Requests / Changes

A good change should explain:

- what changed
- why it changed
- security implications
- compatibility implications
- tests performed

For security-related changes, explicitly describe the threat or failure mode being addressed.

---

## Claude Code Guidance

When working in this repository:

- Read this file first.
- Inspect the actual repository before assuming file names or architecture.
- Do not invent APIs, configuration options, or directories when an existing implementation can be inspected.
- Prefer small, reviewable changes.
- Preserve existing behavior unless the task explicitly asks for a breaking change.
- Run targeted tests after changes.
- Do not modify unrelated files.
- Never expose secrets in your response.
- If a task would weaken authentication, authorization, TLS verification, or secret isolation, flag the security impact before implementing it.
- If requirements are ambiguous, prefer the safer behavior and ask only when the ambiguity materially affects correctness.

## Definition of Done

A change is generally complete when:

- the requested behavior works
- existing behavior remains intact
- relevant tests pass
- new security-sensitive behavior has tests
- no credentials or private keys were introduced
- error handling does not leak secrets
- configuration is documented where necessary
- the Git diff contains only intentional changes
