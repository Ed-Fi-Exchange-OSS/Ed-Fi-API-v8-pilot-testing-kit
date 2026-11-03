# Troubleshooting

Companion to the [main README](../README.md). Covers port conflicts, certificate trust failures,
startup timeouts and failures, volume reset, switching templates, and bootstrapping failures.

## Port conflicts

The kit binds `HTTP_PORT` (default `80`), `HTTPS_PORT` (default `443`), and `POSTGRES_PORT`
(default `5435`) on `BIND_ADDRESS` (default `127.0.0.1`). If one of those is already in use on your
host, Compose will fail to bring up `nginx` or `db`. Change the conflicting value(s) in `.env` before
starting -- or before re-running `start` if you already have a `.env` -- and start again. No other
host port is published by this kit.

Changing `HTTPS_PORT` also requires changing `PUBLIC_ORIGIN`, because the printed URLs, the saved
credential files (token URL, `apiBaseUrl`, and `dataApiBaseUrl`), and the CORS origins are all built from
`PUBLIC_ORIGIN`. For example, with `HTTPS_PORT=8443` set `PUBLIC_ORIGIN=https://localhost:8443`; with
the default `443`, leave the port off (or write `:443`). `start` stops with an error that names the
exact value to set if the two disagree.

## Certificate trust failures

- **A client rejects the certificate as untrusted:** see [Trusting the certificate from your own
  client code](../README.md#trusting-the-certificate-from-your-own-client-code) in the main README
  for the `curl`/.NET/Python/Node approaches.
- **You changed the hostname you use to reach the kit** (something other than `localhost`): the
  shipped certificate generators (`ssl/generate-certificate.sh` and `.ps1`) hard-code the names the
  certificate is valid for -- its Subject Alternative Names are only `localhost`, `nginx`, and
  `127.0.0.1` -- so regenerating it does not add your hostname. To use another hostname, supply your
  own `ssl/server.crt` and `ssl/server.key` whose SANs include it, then restart NGINX:

  ```shell
  docker compose restart nginx
  ```

- **`ssl/generate-certificate.(sh | ps1)` refuses to run:** when both `server.crt` and
  `server.key` already exist, it won't overwrite them without `--force`/`-Force`. That's deliberate -- confirm you actually want to replace
  the certificate (every client that trusted the old one will need to trust the new one too) before
  passing it.
- **NGINX fails to start citing a missing certificate:** `start` generates one automatically if
  `ssl/server.crt` or `ssl/server.key` is missing, so this should only happen if certificate
  generation itself failed. Re-run `./ssl/generate-certificate.sh` directly and read its error
  output; it requires `openssl` on `PATH` (or PowerShell 7 for the `.ps1` version).

## Startup timeouts and failures

`start` runs `docker compose up -d --build --wait` and waits on service health rather than just
container creation (FR-LIFE-7). If any service doesn't become healthy, or a one-shot
initialization step exits non-zero, `start` prints something like:

```text
Startup did not complete.
Compose reported:
  container edfi-pilot-init-bootstrap-1 has no healthcheck configured

Checking service status...
FAILED: <service> (<reason>)

----- last 20 lines of '<service>' -----
  ...
Full logs: (cd "<path>" && docker compose logs <service>)

Inspect further with:
  (cd "<path>" && docker compose ps -a)
  (cd "<path>" && docker compose logs)
```

and exits non-zero. "Compose reported" repeats Compose's own `--wait` error (if it doesn't print a
recognizable one, `start` shows Compose's last few output lines instead). Each `FAILED` service is
one that error names, or one that `docker compose ps -a` shows as:

- `unhealthy`, or `exited with code <n>` for a non-zero exit code.
- `never started`: the container was created but never started, usually because a service it
  depends on failed first.
- A one-shot `init-` service that `exited with code 0` (or is `still running`), with a note that
  Compose `--wait` may have checked it as a long-running service. Compose does that for any service
  that no other service depends on with `condition: service_completed_successfully`, and then fails
  because a finished one-shot container can never become healthy.

Run the printed `docker compose logs <service>` command for the full history. If no failing service
can be identified, use the two inspect commands at the end of the report.

`start.sh` and `start.ps1` copy Compose's output as it streams in order to report this, so Compose
shows its plain, line-by-line progress output rather than its interactive progress display.

**Expected startup order**, if you're trying to figure out where a failure sits in the chain: `db`
and `config` (CS) become healthy first, then identity seeding, then the schema and data store
init steps, then the template load, then `dms`, then bootstrapping. A failure early in that chain
(for example, `init-identity`) usually means a problem with a secret in `.env` -- `init-identity`
validates each CS client secret (32-128 characters, with a lowercase letter, an uppercase letter, a
digit, and a special character) before touching the database, and fails naming the `.env` variable
if one is invalid.

The first `up` on a clean host also builds the `tools` image (a locally built image used by every
one-shot init step) and, on `DATABASE_TEMPLATE=populated`, loads the sample data set -- budget
several minutes for a clean first start before concluding something has hung.

## Volume reset

Use `./reset.sh` / `.ps1` to return to a clean state -- for a corrupted environment, or because you
want to switch templates (see below). It requires `--force`/`-Force` or an interactive "yes"
confirmation; without either, it changes nothing and exits non-zero:

```bash
./reset.sh            # prompts for confirmation, shows exactly what will be removed
./reset.sh --force     # skips the prompt (for scripts and CI)
./reset.sh --force --start   # reset, then start again immediately
```

It removes the database volume, the ApiSchema volume, the Data Standard download cache, PGAdmin's
data volume, and every file under `.runtime/` except `.gitkeep` (so the bootstrap credential and any
credentials you provisioned with `new-credential` stop working). It keeps `.env` and the TLS
certificate -- only data, not configuration, is destroyed.

## Switching templates

`DATABASE_TEMPLATE` (`minimal` or `populated`) only takes effect the **first** time a database is
initialized. If you change it in `.env` -- or run `./start.sh --template populated` -- against a
database that was already initialized with the other template, nothing reloads. The template
loader detects the mismatch and logs:

```text
WARNING: this database was initialized with DATABASE_TEMPLATE='<old>', but .env now sets
DATABASE_TEMPLATE='<new>'. Changing the template on an existing database requires a reset: run
'docker compose down -v' and start again. Leaving the database as it is.
```

To actually switch, reset first:

```bash
./reset.sh --force --start
```

(`start` will pick up whatever `DATABASE_TEMPLATE` is currently set to in `.env`, or pass
`--template` again to be explicit.)

## Bootstrapping failures

Bootstrapping (the bootstrap credential and the baseline education organization hierarchy) runs as
part of `start`, and fails startup with a message naming the specific step that failed rather than
reporting success with a partially prepared environment. The step names you'll see in
`docker compose logs init-bootstrap` (each wrapped in `[brackets]`) are, in order:
`validate-env`, `validate-baseline-file`, `cms-token`, `bootstrap-credential`, `credentials-file`,
`dms-token`, `baseline-records`, and `summary`. A failure naming:

- `validate-env` or `cms-token` usually points at a CS secret problem in `.env`, or CS not yet
  being reachable.
- `validate-baseline-file` means `bootstrap/baseline-edorgs.json` is missing or malformed -- this
  should only happen if the repository checkout itself is damaged.
- `baseline-records` names the specific education organization resource and natural key that failed,
  with the HTTP status and response body CS or Ed-Fi API v8 returned.

To retry bootstrapping on its own, without a destructive reset, once the underlying problem is
fixed:

```shell
# Bash
./bootstrap.sh

# PowerShell
.\bootstrap.ps1
```

This requires the stack to already be running (`./start.sh` first) -- otherwise it fails fast with
a message telling you to start the stack first, rather than letting `docker compose run` silently
bring up every dependency on its own.

## Upgrading from 8.1.0-beta1

The 8.1.0-beta2 kit changes the `.env` variable names and moves to PostgreSQL 18, so an existing
beta1 checkout needs a few steps before `./start.sh` will work. `start`, `stop`, and `reset` do the
safe part for you and refuse to continue on the rest; none of them deletes data on their own.

1. **Renamed keys.** Every `CMS_*` variable is now `CONFIGURATION_SERVICE_*` (for example
   `CMS_ADMIN_CLIENT_SECRET` is now `CONFIGURATION_SERVICE_ADMIN_CLIENT_SECRET`). `start`, `stop`, and
   `reset` rename them in your `.env` automatically, keeping your existing values -- the secrets and
   encryption keys must stay the same, or the existing database can no longer be read. The previous
   file is saved as `.env.pre-beta2.bak`. `CMS_IMAGE` is replaced by the kit's pinned
   `CONFIGURATION_SERVICE_IMAGE`, not carried over. If you keep your own copy of `.env`, rename the keys
   there the same way.
2. **Image pins.** Compare the `*_IMAGE` lines in your `.env` with `.env.example` and update
   `DMS_IMAGE` (beta1 images do not work with this kit) and `POSTGRES_IMAGE` (`postgres:16.x` must
   become the `postgres:18.x` pin). The kit stops with a message if `POSTGRES_IMAGE` still pins a
   version before 18.
3. **Reset the database.** PostgreSQL 18 stores its data in a different place in the volume, and
   changing the image does not migrate it; the kit stops if the `db-data` volume still has a
   PostgreSQL 16 database. For a pilot kit, the simplest path is to discard it and start clean, which
   deletes all Ed-Fi API v8 and CS data in the kit:

   ```shell
   # Bash
   ./reset.sh --force --start

   # PowerShell
   .\reset.ps1 -Force -Start
   ```

   To keep the data, dump it first, from the old database, before you reset. This starts a temporary
   PostgreSQL 16 container on the existing volume (use the project name from `KIT_PROJECT_NAME` in place
   of `edfi-pilot`, and your old `POSTGRES_IMAGE` value); restoring the dump into the new database is
   up to you and is not covered or tested by this kit:

   ```shell
   docker run -d --name pg16-dump -v edfi-pilot_db-data:/var/lib/postgresql/data postgres:16.8-alpine
   docker exec pg16-dump pg_dumpall -U postgres > backup.sql
   docker rm -f pg16-dump
   ```

4. **Fix `http/.env`.** If you created `http/.env` for the REST Client files, rename its `CMS_*` keys to
   `CONFIGURATION_SERVICE_*` too (`http/claimset-test.http` reads
   `CONFIGURATION_SERVICE_ADMIN_CLIENT_SECRET`), then re-run any request that failed on a missing
   variable. Reset also replaces the credentials under `.runtime/`, so re-copy any you saved from there.
