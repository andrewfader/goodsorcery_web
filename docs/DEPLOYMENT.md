# Deploying to production

Every push to `main` (a direct push or a merged pull request) runs CI. Once
every check passes, the `deploy` job in `.github/workflows/ci.yml` builds the
image, pushes it to GHCR and runs `bin/kamal deploy` over SSH. The deploy job
only runs in the upstream repository; to deploy your own fork, see
[Deploying from a fork](#deploying-from-a-fork). You can also run
`bin/kamal deploy` from your own machine with the same variables exported.

Cloudflare terminates TLS here. If you deploy differently, the app must still
be served over HTTPS (`force_ssl` is on); see "Plain Docker" in the README for
Thruster's built-in TLS.

Everything runs on one server:

```
visitor ──HTTPS──▶ Cloudflare (DNS proxy, TLS)
                        │
                        ▼  outbound-only tunnel
  server ┌──────────────────────── Docker network "kamal" ───────────────────────┐
         │ goodsorcery_web-tunnel (cloudflared) ──HTTP──▶ kamal-proxy ──▶ web     │
         │                                                               job (Sidekiq + sidekiq-cron)
         │ goodsorcery_web-db (Postgres 18)                                       │
         │ goodsorcery_web-valkey-jobs  (Valkey 9.1: Sidekiq, persisted)          │
         │ goodsorcery_web-valkey-cache (Valkey 9.1: Rails cache, LRU)            │
         │ goodsorcery_web-valkey-cable (Valkey 9.1: Action Cable pub/sub)        │
         └────────────────────────────────────────────────────────────────────────┘
  open inbound ports: SSH only (key only, on KAMAL_SSH_PORT). No HTTP ports are published.
```

Sidekiq, the Rails cache and Action Cable each have their own Valkey (a
Redis-compatible server), so each gets the settings its data needs:

| Accessory | Used by | Memory | When full | Persistence |
|---|---|---|---|---|
| `valkey-jobs` | Sidekiq (`REDIS_URL`) | 256 MB (container 384 MB) | refuses writes (`noeviction`, which Sidekiq requires) | append-only file only (no RDB snapshots) in `goodsorcery_web-valkey-jobs/data` under the deploy user's home |
| `valkey-cache` | Rails cache store (`REDIS_CACHE_URL`) | 128 MB (container 160 MB) | evicts the least recently used keys | none |
| `valkey-cable` | Action Cable (`REDIS_CABLE_URL`) | 32 MB (container 64 MB) | refuses writes | none |

Keeping the cache apart also means a cache flush can't touch the job queues:
the cache store has no namespace, so `Rails.cache.clear` empties its whole
database. These are the defaults; every setting can be changed, and any role
can use an external server instead, through the optional variables in
[Valkey settings](#valkey-settings).

## Keeping the server private in a public repo

- `config/deploy.yml` holds no hosts or secrets. Kamal reads the host, SSH
  port and domain from `KAMAL_WEB_HOST`, `KAMAL_SSH_PORT` (default 22) and
  `GOODSORCERY_HOST`, and every secret from
  the environment through `.kamal/secrets`.
- In GitHub, all of them live in the `production` environment, which only
  `main` may deploy from. `KAMAL_WEB_HOST` is stored as a **secret** (not a
  variable), so GitHub masks the IP wherever Kamal prints it in the public
  Actions log.
- Cloudflare Tunnel means no DNS record points at the server. Don't add `A` or
  `AAAA` records for it, and don't send mail directly from the server (use an
  SMTP provider), or its IP will show up in DNS or email headers.
- Fork pull requests run the tests without secrets and never reach the deploy
  job. The workflow uses `pull_request`, never `pull_request_target`.

## One-time setup

### 1. Server

Use Ubuntu LTS on amd64 (the image is built for `amd64`; change `builder.arch`
in `config/deploy.yml` for an arm64 server). As root:

```sh
curl -fsSL https://get.docker.com | sh
adduser --disabled-password --gecos "" deploy
usermod -aG docker deploy
install -d -m 700 -o deploy -g deploy /home/deploy/.ssh
# Add your own public key and the CI deploy key (step 4) to:
#   /home/deploy/.ssh/authorized_keys   (owner deploy, mode 600)

# SSH: keys only, no root login. If you move SSH off port 22, also set
# KAMAL_SSH_PORT (below) and open that port instead of OpenSSH.
printf 'PasswordAuthentication no\nPermitRootLogin no\n' > /etc/ssh/sshd_config.d/00-hardening.conf
systemctl reload ssh
# sshd keeps the first value it reads, and cloud images often ship
# 50-cloud-init.conf with PasswordAuthentication yes, so the 00- prefix matters.
# Check: sshd -T | grep -i passwordauthentication   (should say no)

# Firewall: SSH only. Nothing else needs to be reachable; the tunnel connects out.
ufw default deny incoming && ufw allow OpenSSH && ufw --force enable   # or: ufw allow SSH_PORT/tcp
```

Docker-published ports bypass `ufw`, which is why `deploy.yml` publishes none:
kamal-proxy runs with `publish: false`, and Postgres, Valkey and cloudflared
only listen on the private `kamal` network.

Valkey also needs two host settings, which Kamal doesn't manage. The jobs
instance forks to rewrite its append-only file, and without memory overcommit
that fork can fail; a small swap file keeps a memory spike on a 4 GB server
from waking the OOM killer:

```sh
# Let Valkey fork for background saves (it warns at startup without this).
echo 'vm.overcommit_memory = 1' > /etc/sysctl.d/90-valkey.conf
sysctl --system

# A 2 GB swap file (1 GB is enough if disk is tight). Skip if `swapon --show`
# already lists one.
fallocate -l 2G /swapfile && chmod 600 /swapfile
mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
```

### 2. Cloudflare

1. Add your domain to Cloudflare.
2. **Zero Trust → Networks → Tunnels → Create a tunnel** (type *Cloudflared*).
   Name it, then copy the token from the install command. This is
   `CLOUDFLARE_TUNNEL_TOKEN`; you don't need to install anything on the server
   yourself, because Kamal runs cloudflared as an accessory.
3. Add a **public hostname** to the tunnel: your subdomain (for example
   `errors.example.com`) with service type **HTTP** and URL **`kamal-proxy:80`**.
   Cloudflare creates the proxied DNS record for you.
4. The ingest API is called by servers, not browsers. Make sure Bot Fight Mode,
   browser integrity checks and challenges don't apply to `/api/`: turn Bot
   Fight Mode off, or add a WAF custom rule that skips them for
   `starts_with(http.request.uri.path, "/api/")`.

### 3. Postmark (optional)

Mail (password resets, sign-up confirmations, alerts) goes through Postmark's
API when `POSTMARK_API_TOKEN` is set, which also keeps the server's IP out of
email headers. To use another provider over SMTP instead, skip this step and
follow "Email" in the README; `SMTP_USERNAME` and `SMTP_PASSWORD` then need
passing through as described in [Other variables](#other-variables).

1. Create a server in Postmark and copy its **Server API token**
   (`POSTMARK_API_TOKEN`). Use the default transactional stream.
2. **Sender Signatures → Add Domain** for the domain you send from (by default
   `GOODSORCERY_HOST`, or the domain in `GOODSORCERY_MAIL_FROM`), then add the
   DKIM and Return-Path DNS records it shows in Cloudflare.
3. Leave link tracking off for the server, so reset links go straight to
   your app instead of through Postmark's redirector.

### 4. Secrets

Generate the app secrets once and keep them in a password manager. Back up the
encryption keys separately from the database; losing them makes stored data
unreadable (see "Secrets" in `README.md`).

```sh
bin/rails secret                     # SECRET_KEY_BASE
bin/rails db:encryption:init         # the three ACTIVE_RECORD_ENCRYPTION_* values
openssl rand -hex 32                 # GOODSORCERY_WEB_DATABASE_PASSWORD

ssh-keygen -t ed25519 -N "" -C "goodsorcery_web deploy" -f goodsorcery_deploy
# goodsorcery_deploy.pub goes into the server's authorized_keys (step 1);
# goodsorcery_deploy (private) becomes SSH_PRIVATE_KEY.

ssh-keyscan -p SSH_PORT -t ed25519 SERVER_IP   # becomes SSH_KNOWN_HOSTS
```

Compare the `ssh-keyscan` output with `/etc/ssh/ssh_host_ed25519_key.pub` on
the server before you trust it. On a port other than 22 the line starts with
`[SERVER_IP]:SSH_PORT`; keep it that way, since that's how SSH matches it.

In GitHub: **Settings → Environments → New environment** named `production`.
Under *Deployment branches and tags*, choose *Selected branches* and allow
only `main`. Then add:

| Kind | Name | Value |
|---|---|---|
| secret | `KAMAL_WEB_HOST` | the server's IP address |
| secret | `KAMAL_SSH_PORT` | the server's SSH port (`22` if unchanged) |
| secret | `SSH_PRIVATE_KEY` | the private deploy key |
| secret | `SSH_KNOWN_HOSTS` | the `ssh-keyscan` line |
| secret | `SECRET_KEY_BASE` | from `bin/rails secret` |
| secret | `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY` | from `db:encryption:init` |
| secret | `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY` | from `db:encryption:init` |
| secret | `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT` | from `db:encryption:init` |
| secret | `GOODSORCERY_WEB_DATABASE_PASSWORD` | the database password |
| secret | `POSTMARK_API_TOKEN` | optional: the Postmark **server** API token (Servers → your server → API Tokens); without it, configure SMTP |
| secret | `KAMAL_VALKEY_JOBS_URL`, `KAMAL_VALKEY_CACHE_URL`, `KAMAL_VALKEY_CABLE_URL` | optional: an external Redis-compatible server's URL for that role, used only with the matching `_EXTERNAL` variable below (see [Valkey settings](#valkey-settings)); `.kamal/secrets` already reads them |
| secret | `GOODSORCERY_API_KEY` | optional: an ingest key for an app that tracks this instance's own errors (create the app on this instance or another one); unset, the gem sends nothing. See "Self-reporting" in the README |
| variable | `GOODSORCERY_HOST` | the public hostname, e.g. `errors.example.com` |
| variable | `GOODSORCERY_MAIL_FROM` | optional: the sender, e.g. `Good Sorcery <no-reply@example.com>`; defaults to `no-reply@GOODSORCERY_HOST` |
| variable | `GOODSORCERY_DISABLE_SIGNUPS` | recommended: `1` closes sign-up even before the first account exists; create the owner with `goodsorcery:create_owner` (step 6) |
| variable | `GOODSORCERY_ENABLE_SIGNUPS` | optional: `1` keeps public sign-up open after the first account; unset or anything else closes it |
| variable | `KAMAL_IMAGE` | optional: the GHCR image name without `ghcr.io/`, e.g. `your-user/goodsorcery_web` (lowercase). CI defaults it to the repository's own name; Kamal's own default is `creativesorcery/goodsorcery_web`, which only the upstream repository can push to |
| variable | `KAMAL_SSH_USER` | optional: the server user Kamal logs in as, if not `deploy` |
| variable | `KAMAL_VALKEY_JOBS_EXTERNAL`, `KAMAL_VALKEY_CACHE_EXTERNAL`, `KAMAL_VALKEY_CABLE_EXTERNAL` | optional: `1` runs that role on the external server in its URL secret above instead of its Valkey accessory; unset keeps the accessory |
| variable | `GOODSORCERY_HOSTED` | optional: `1` turns on hosted mode (entitlements and "Upgrade to unlock"); unset is self-hosted. After switching, run `goodsorcery:fit_entitlements` (see below) |
| variable | `GOODSORCERY_APM_RETENTION_DAYS` | optional, self-hosted only: days of performance data to keep, 1–30 (default 30) |
| variable | `GOODSORCERY_UPGRADE_URL` | optional, hosted only: where "Upgrade to unlock" links to. Unset, locked options say "Coming soon" and no upgrade text shows |
| variable | `GOODSORCERY_TERMS_URL` | optional: an http(s) link to your Terms of Service. Set, the sign-up page says "By signing up you agree to the Terms of Service." with it linked |
| variable | `GOODSORCERY_PRIVACY_URL` | optional: an http(s) link to your Privacy Policy, linked the same way. With neither set, the sign-up page shows no agreement sentence |
| variable | `GOODSORCERY_ENDPOINT` | optional: where this instance's gem reports its own errors and performance data; self-hosted it defaults to this instance's own public URL (`https://GOODSORCERY_HOST`), hosted (`GOODSORCERY_HOSTED`) to `https://app.goodsorcery.com` |
| variable | `GOODSORCERY_PERFORMANCE_MONITORING` | optional: `0` turns off performance monitoring of this instance (on by default, with `GOODSORCERY_API_KEY` set and a gem version that supports it) |

The registry login uses the workflow's own `GITHUB_TOKEN`, so there's no
registry secret. The image goes to `ghcr.io/KAMAL_IMAGE` (by default the
repository's own package), and GHCR packages are private by default, which is
fine: the server pulls with the same login. `CLOUDFLARE_TUNNEL_TOKEN` stays out of GitHub: only the
one-time accessory boot below needs it.

### 5. Repository settings

- **Branch protection (or a ruleset) on `main`:** require pull requests and
  the CI checks, and block force pushes. Allow direct pushes only for yourself.
- **Settings → Actions → General:** require approval for workflows from
  outside contributors' forks.
- **Settings → Environments → production:** add yourself as a required
  reviewer, so no push to `main` reaches the production secrets unreviewed.
- **Settings → Advanced Security:** turn on private vulnerability reporting
  (the reporting link in `SECURITY.md` needs it), secret scanning with push
  protection, and Dependabot security updates. GitHub offers some of these
  only once the repository is public.

### 6. First boot

From your laptop, with the values from step 4 exported in your shell
(including `KAMAL_WEB_HOST`, `KAMAL_SSH_PORT`, `GOODSORCERY_HOST`,
`KAMAL_IMAGE` (the same image name CI uses, e.g. `your-user/goodsorcery_web`;
unset, Kamal uses `creativesorcery/goodsorcery_web`) and, if
your server user isn't `deploy`, `KAMAL_SSH_USER`). Kamal passes its own user
and port to SSH, overriding `User` and `Port` from an `~/.ssh/config` alias (plus a
GitHub personal access token with `read:packages` as `KAMAL_REGISTRY_PASSWORD`
and your GitHub username as `KAMAL_REGISTRY_USERNAME`):

```sh
bin/kamal accessory boot all     # Postgres, the three Valkey instances and the tunnel
```

To run a Valkey role on an external server, boot the accessories by name and
leave that one out (see [Valkey settings](#valkey-settings)).

Then push to `main` (or re-run the latest CI run). The CI deploy job first
runs `bin/boot_valkey_accessories`, which boots any Valkey accessory not yet on
the server. Every deploy then runs
`.kamal/hooks/pre-deploy`, which stops it, before any container changes, if a
Valkey accessory the app needs isn't running (see
[The pre-deploy check](#the-pre-deploy-check)). The deploy job starts
kamal-proxy, boots the web and job containers and runs migrations
(`bin/docker-entrypoint` runs `db:prepare`; it never loads the development
demo data in `db/seeds.rb`).

**Create the first owner straight away.** Until the first account exists,
anyone who finds `https://GOODSORCERY_HOST` can sign up and become the
instance's owner. Either set `GOODSORCERY_DISABLE_SIGNUPS=1` (step 4) before
this first deploy and create the owner from your laptop:

```sh
bin/kamal app exec -i --reuse 'bin/rails goodsorcery:create_owner EMAIL=you@example.com NAME="Your Name" ACCOUNT="Acme"'
```

It prompts for the password without echoing it; add `STAFF=1` inside the
quotes to also grant the staff area. Or, without that variable, open
`https://GOODSORCERY_HOST` and sign up the moment the deploy finishes; sign-up
closes after the first account. Grant staff later with
`bin/kamal app exec -r web --reuse 'bin/rails goodsorcery:make_staff EMAIL=you@example.com'`.
(`-r web` runs a command once. Without it, a non-interactive `app exec` runs
once per role, so in both the web and the job container, even with `--reuse`.)

Request bodies over 4 MiB get a 413 before they are read: Puma enforces
`http_content_length_limit` (`config/puma.rb`) and Thruster `MAX_REQUEST_BODY`
(set in the `Dockerfile`). The largest ingest body is 2 MiB, so a server
without Cloudflare in front still refuses oversized uploads.

## Day to day

- **Deploy:** merge to `main`. Deploys queue rather than overlap.
- **Roll back:** `bin/kamal rollback VERSION` (a git SHA from `bin/kamal app images`), or revert the commit on `main`.
  Neither runs migrations backwards, so the previous release runs against the new schema. Migrations keep that working: a column the code stops using stays (ignored with `ignored_columns`) and is dropped one release later. The full rules are in [MIGRATIONS.md](MIGRATIONS.md).
- **Console, logs:** `bin/kamal console`, `bin/kamal logs`, `bin/kamal logs -r job`, `bin/kamal dbc`.
- **Scheduled jobs:** sidekiq-cron runs `config/schedule.yml` inside the job
  container (the full list is under "Scheduled tasks" in the README), so the
  server needs no cron. If the job container is down, retention, alerts,
  digests and uptime checks all stop. The rake tasks still work by hand:
  `bin/kamal app exec -r web "bin/rails goodsorcery:prune"`.
- **Performance data:** batches from the gem (`config.performance_monitoring`)
  are processed on the `apm` Sidekiq queue (weight 2, after `ingest`). Each job
  is short and database-bound; a gem process sends at most two batches a
  minute. `GOODSORCERY_APM_RETENTION_DAYS` (self-hosted, 1–30, default 30)
  sets how long hourly figures and traces are kept.
- **Uptime checks:** they run on the `uptime` Sidekiq queue. A check waits on
  the network for up to about 20 seconds (two 10-second attempts), so one
  Sidekiq thread manages roughly 60 / (average check seconds) checks a minute,
  and the total is that times `SIDEKIQ_CONCURRENCY`. With many monitors, add a
  job role that runs only that queue (`bundle exec sidekiq -q uptime`, with its
  own `SIDEKIQ_CONCURRENCY`) so slow checks never hold up ingest or alerts.
  Keep the existing `job` role on `config/sidekiq.yml`, which runs every queue:
  a process started with a hand-picked `-q` list silently skips the queues it
  leaves out. Each due monitor is claimed once, so several processes can share
  the queue.
  After switching `GOODSORCERY_HOSTED` on or off, or editing
  `config/entitlements.yml`, run
  `bin/kamal app exec -r web "bin/rails goodsorcery:fit_entitlements"` (formerly
  `goodsorcery:fit_uptime_monitors`, still an alias). It fits uptime monitors
  and each app's error retention. Switching it off without the task leaves
  monitors paused under hosted limits unchecked.
- **Accessories:** `bin/kamal accessory logs tunnel`. Upgrading Postgres to a
  new major version needs a dump and restore.
- **Valkey memory:** `bin/kamal accessory exec valkey-jobs --reuse "valkey-cli info memory"`
  (likewise `valkey-cache` and `valkey-cable`) shows `used_memory_human`
  against `maxmemory_human`. A full `valkey-jobs` refuses new jobs, so if it
  creeps towards its limit, look for a growing queue or dead set in the
  Sidekiq logs, and raise `KAMAL_VALKEY_JOBS_MAXMEMORY` and
  `KAMAL_VALKEY_JOBS_MEMORY_LIMIT` together ([Sizing](#sizing)). A full
  `valkey-cache` is normal: it evicts old keys.

## Other variables

`config/deploy.yml` passes only some of the README's environment variables to
the containers: the required ones and the optional variables listed in the
table above. To use another one (for example `GOODSORCERY_EXTRA_HOSTS`,
`GOODSORCERY_DOCS_URL`, `SIDEKIQ_CONCURRENCY`,
`WEB_CONCURRENCY`, or `SMTP_USERNAME` / `SMTP_PASSWORD`), add it to `env.clear`
(or `env.secret` and `.kamal/secrets` for secrets) in `config/deploy.yml`, and
to the deploy step's `env` in `.github/workflows/ci.yml` (from `vars.` or
`secrets.`) if CI deploys. A variable set only in GitHub has no effect on its
own.

## Valkey settings

### Deploy-time variables

Kamal reads these on the machine that runs it, when it renders
`config/deploy.yml`. **All of them are optional**: unset or blank, each takes
the default below, which is what a deploy that sets none of them gets. The app
itself never reads them; it reads the runtime variables `REDIS_URL`,
`REDIS_CACHE_URL` and `REDIS_CABLE_URL` (README, ["Valkey or Redis"](../README.md#valkey-or-redis)),
which `deploy.yml` sets for it.

| Variable | Required | Default | What it does | Notes |
|---|---|---|---|---|
| `KAMAL_VALKEY_IMAGE` | optional | `valkey/valkey:9.1.3` | Image for all three accessories. | Pin an exact tag. Valkey 7.2+ or Redis 7.0+ works with Sidekiq. The command starts with flags, so a Redis image (`redis:8.2.1`) runs `redis-server` instead; use `redis-cli` wherever these docs say `valkey-cli`. |
| `KAMAL_VALKEY_JOBS_MAXMEMORY` | optional | `256mb` | `--maxmemory` for `valkey-jobs` (Sidekiq). | About two thirds of the memory limit (see [Sizing](#sizing)). |
| `KAMAL_VALKEY_JOBS_POLICY` | optional | `noeviction` | `--maxmemory-policy` for `valkey-jobs`. | **Keep `noeviction`.** Any other policy lets a full server silently drop queued jobs, retries and the cron schedule. |
| `KAMAL_VALKEY_JOBS_MEMORY_LIMIT` | optional | `384m` | Docker `--memory` for `valkey-jobs`. | About 1.5 × maxmemory: room for fragmentation and the AOF rewrite fork. |
| `KAMAL_VALKEY_JOBS_ARGS` | optional | none | Extra server arguments for `valkey-jobs`, appended last. | See "Extra arguments" below. Persistence is the append-only file only (`--appendonly yes --save ""`); keep the AOF on. |
| `KAMAL_VALKEY_CACHE_MAXMEMORY` | optional | `128mb` | `--maxmemory` for `valkey-cache` (Rails cache). | The cache fills up to it, then evicts. |
| `KAMAL_VALKEY_CACHE_POLICY` | optional | `allkeys-lru` | `--maxmemory-policy` for `valkey-cache`. | Keep an evicting policy (`allkeys-lru`, or `allkeys-lfu`). With `noeviction` a full cache refuses writes; the errors are swallowed, so caching quietly stops and the ingest rate limits fail open. |
| `KAMAL_VALKEY_CACHE_MEMORY_LIMIT` | optional | `160m` | Docker `--memory` for `valkey-cache`. | About 1.25 × maxmemory (no fork). |
| `KAMAL_VALKEY_CACHE_ARGS` | optional | none | Extra arguments for `valkey-cache`. | Persistence is off (`--save "" --appendonly no`) and should stay off: the cache is disposable. |
| `KAMAL_VALKEY_CABLE_MAXMEMORY` | optional | `32mb` | `--maxmemory` for `valkey-cable` (Action Cable). | Pub/sub stores no keys, so it stays small. |
| `KAMAL_VALKEY_CABLE_POLICY` | optional | `noeviction` | `--maxmemory-policy` for `valkey-cable`. | Nothing to evict either way. |
| `KAMAL_VALKEY_CABLE_MEMORY_LIMIT` | optional | `64m` | Docker `--memory` for `valkey-cable`. | A floor for the process itself and subscriber buffers. |
| `KAMAL_VALKEY_CABLE_ARGS` | optional | none | Extra arguments for `valkey-cable`. | Persistence is off and should stay off. |
| `KAMAL_VALKEY_JOBS_EXTERNAL` | optional | unset | `1` sends the app's `REDIS_URL` to the server in `KAMAL_VALKEY_JOBS_URL` instead of `valkey-jobs`. | Not a secret. Any value other than `1` or blank stops the deploy. |
| `KAMAL_VALKEY_CACHE_EXTERNAL` | optional | unset | The same for `REDIS_CACHE_URL` and `valkey-cache`. | |
| `KAMAL_VALKEY_CABLE_EXTERNAL` | optional | unset | The same for `REDIS_CABLE_URL` and `valkey-cable`. | |
| `KAMAL_VALKEY_JOBS_URL` | with `KAMAL_VALKEY_JOBS_EXTERNAL=1`, **secret** | none (the app gets `redis://goodsorcery_web-valkey-jobs:6379/0`) | The external server's URL, read through `.kamal/secrets`. | Passed to the app as a secret, never in `env.clear`. That server must be `noeviction` with persistence on. |
| `KAMAL_VALKEY_CACHE_URL` | with `KAMAL_VALKEY_CACHE_EXTERNAL=1`, **secret** | none (`redis://goodsorcery_web-valkey-cache:6379/0`) | The same for the cache. | Never point it at the jobs server's database (see the README). |
| `KAMAL_VALKEY_CABLE_URL` | with `KAMAL_VALKEY_CABLE_EXTERNAL=1`, **secret** | none (`redis://goodsorcery_web-valkey-cable:6379/0`) | The same for Action Cable. | |

The names follow `deploy.yml`'s existing `KAMAL_*` variables (read by Kamal,
not the app). The URL variables deliberately aren't called `REDIS_URL` and so
on: a `REDIS_URL` left in your shell for local work would otherwise silently
repoint production.

**Keep your overrides in one file and load it before every Kamal command.**
`deploy.yml` reads these variables each time Kamal runs, and an unset one
silently means the default. Put every `KAMAL_VALKEY_*` value you change, the
`_EXTERNAL` flags included, in a git-ignored file (`.env.kamal` in the
checkout: `.gitignore` already ignores `.env*`), with `export` on each line,
and `source .env.kamal` in the shell before any `bin/kamal` command. Mirror
the flags in CI (below). The risk is real: a later
`bin/kamal accessory reboot valkey-jobs` from a shell without the file
recreates the instance with the defaults. If you had raised its sizes, the
data in its append-only file may no longer fit: above the default memory
limit, the container is OOM-killed while loading the file and restarts over
and over; above the default maxmemory alone, Valkey starts but refuses every
write. Either way Sidekiq can't enqueue anything. `bin/kamal config` shows
what the current shell would deploy.

**Sizing settings only apply when an accessory boots.** CI boots a Valkey
accessory only when it is missing (with any `KAMAL_VALKEY_*` sizing variables
set in the GitHub `production` environment), so after changing one, source
your file on your laptop and run
`bin/kamal accessory reboot valkey-cache` (or the instance you changed).
Rebooting `valkey-jobs` keeps its data; rebooting the others empties them,
which is harmless. The `_EXTERNAL` flags and the URLs are the exception: they
change the app's environment, so CI needs them on every deploy (below).

**Extra arguments** (`KAMAL_VALKEY_<ROLE>_ARGS`) go through the server's shell
as written, after the default flags, so a later flag wins (for example
`--io-threads 2`, or `--maxmemory-clients 16mb`). Quote values the shell would
split or expand; an unquoted `#` starts a shell comment and drops the rest.
Don't put a password here (`--requirepass ...`): it shows in Kamal's own
output (`bin/kamal accessory boot` and `reboot`, `bin/kamal config`) and in the `docker run` command line, which anyone with Docker
access on the server can read. To protect an in-cluster instance with a
password, keep `requirepass` in a config file mounted with the accessory's
`files:` option (a local change to `deploy.yml`; the file must be readable by
the container's `valkey` user), load it with `--include /path/in/container`
in the ARGS, and give the app the matching URL as the role's secret
(`redis://:PASSWORD@goodsorcery_web-valkey-jobs:6379/0`, with
`KAMAL_VALKEY_JOBS_EXTERNAL=1`, since the default URLs carry no password). Or
use an external server, below. On the private `kamal` network, unreachable
from outside the server, the defaults run without a password.

### Using an external or managed server

To run a role on a managed Valkey or Redis (or any server outside Kamal):

1. Set `KAMAL_VALKEY_<ROLE>_EXTERNAL=1` (for example
   `KAMAL_VALKEY_CACHE_EXTERNAL=1`) in your overrides file, and for CI deploys
   as a variable in the GitHub `production` environment.
2. Provide the URL as the `KAMAL_VALKEY_<ROLE>_URL` secret. `.kamal/secrets`
   reads all three from the environment, like the other secrets, or change
   that line to fetch it through a secrets adapter (1Password and so on; see
   the file's header). For CI deploys, add it as a secret in the GitHub
   `production` environment; `.github/workflows/ci.yml` already passes the
   flags and URLs to Kamal.
3. With the flag set, `deploy.yml` drops that role's in-cluster URL from
   `env.clear` and hands the app the secret instead (for example
   `REDIS_CACHE_URL` from `KAMAL_VALKEY_CACHE_URL`), and the pre-deploy check
   stops a deploy whose URL is empty. A URL set in the shell without the flag
   stops Kamal with an error instead of being ignored, since ignoring it would
   point the app at the in-cluster accessory without a word.
4. **Don't boot that role's accessory.** Boot the others by name instead of
   `bin/kamal accessory boot all` (which boots every accessory in the file), for
   example `bin/kamal accessory boot valkey-jobs` and
   `bin/kamal accessory boot valkey-cable`. If one was already booted, remove
   it with `bin/kamal accessory remove valkey-cache`. An unused accessory left
   running does no harm beyond its memory. (`bin/kamal setup` boots every
   accessory; remove the unused one afterwards.)

### The pre-deploy check

`.kamal/hooks/pre-deploy` runs on the machine that deploys (your laptop, or
CI) after the image is built and before any container changes. For each role
without `KAMAL_VALKEY_<ROLE>_EXTERNAL=1`, it checks over SSH (as
`KAMAL_SSH_USER` on `KAMAL_SSH_PORT`, like Kamal) that
`goodsorcery_web-valkey-<role>` is running on every host in the deploy; for an
external role, that its URL secret isn't empty. If anything is missing it
stops the deploy, so the old containers keep serving. Without it, a web
container would pass its health check (`/up` doesn't touch Valkey) and take
traffic while ingest failed to enqueue and Sidekiq crash-looped. It skips the
container check under `bin/kamal setup`, which boots the accessories after the
hook runs. The SSH call needs the server's host key in `~/.ssh/known_hosts`
(CI already has it); `--skip-hooks` bypasses the check if you must.

### Sizing

The defaults fit a 4 GB server that also runs Postgres, Puma, Sidekiq,
kamal-proxy and cloudflared: about 608 MB of container limits for Valkey in
total (384 + 160 + 64), most of it for jobs. `maxmemory` caps the data;
the container limit must also hold what maxmemory doesn't count, and a
container over its limit is OOM-killed and restarted:

- **Jobs (limit about 1.5 × maxmemory):** allocator fragmentation (often
  10–30%) plus the AOF rewrite. The rewrite forks a child in the same
  container, and every page the parent changes while the child runs is copied,
  so under heavy writes the copy can approach the dataset's size. RDB
  snapshots are off (`--save ""`), so the rewrite is the only fork (it runs
  when the file doubles, from 64 MB). The extra half is headroom for an
  instance running well below maxmemory, not a guarantee for a full one being
  rewritten under load: watch `used_memory_rss` and the logs for OOM restarts.
  A healthy queue is small; memory grows with backlog (an outage of Sidekiq,
  or a flood of ingest) and with the retry and dead sets. On 8 GB or more,
  512mb–1gb (limit 1.5 × that) buys more headroom for backlogs. Below 256mb,
  watch `used_memory` during bursts: a full `noeviction` server refuses new
  jobs.
- **Cache (limit about 1.25 × maxmemory):** nothing is persisted, so nothing
  forks; the margin covers fragmentation from eviction churn. If it is ever
  exceeded, the restart only costs a cold cache. More memory means fewer
  evictions of fragments, counts and key lookups. 256mb–512mb suits 8 GB; on a
  2 GB server, 64mb is a reasonable floor.
- **Cable (limit 64m):** no data and no fork, so the limit is a floor for the
  process (about 10 MB) and its subscribers' output buffers rather than a
  multiple. Action Cable keeps one subscriber connection per web process, not
  per browser, and messages are tiny pointers, so 32mb rarely needs changing.
  On a 2 GB server, give the memory you save to Postgres instead.

Raise `MAXMEMORY` and `MEMORY_LIMIT` together, keeping these ratios, put both
in your overrides file, then reboot the accessory. `valkey-cli info memory`
(see "Day to day") shows how close each instance runs to its limit
(`used_memory_rss_human` is what counts against the container limit).

## Deploying from a fork

The `deploy` job is guarded by `github.repository == 'creativesorcery/goodsorcery_web'`,
so forks run the checks but never try to deploy. To deploy your fork from CI:

1. Change that repository name in `.github/workflows/ci.yml` to your fork's
   (`your-user/goodsorcery_web`).
2. Do the one-time setup above in your fork's settings. `KAMAL_IMAGE` defaults
   to your repository's name in lowercase, which is where the workflow's
   `GITHUB_TOKEN` can push; set the `KAMAL_IMAGE` variable only to use another
   name, and export the same value when you run Kamal locally.
3. Keep your fork's `main` in sync with upstream to get fixes; each deploy runs
   the new migrations at boot (see [MIGRATIONS.md](MIGRATIONS.md)).

## Accessories are managed by hand

CI only deploys the app. Postgres, Valkey and cloudflared keep running across
deploys, and **merging a change to an accessory in `deploy.yml` (such as a new
image version, or a new accessory) does not apply it**. Run the change from
your laptop; for a new accessory the app depends on, boot it before the merge.
The one exception is a *missing or stopped* Valkey accessory: CI's deploy job
runs `bin/boot_valkey_accessories` first, which boots or starts it (it never
reboots a running one, so a new image or size still needs the commands below):

| Situation | Command | Needs |
|---|---|---|
| Restart (stuck, or after a server reboot) | `bin/kamal accessory restart tunnel` | `KAMAL_WEB_HOST`, `KAMAL_SSH_PORT`, `GOODSORCERY_HOST` |
| New image version or rotated secret | `bin/kamal accessory reboot tunnel` | the above, every secret in `.kamal/secrets` the accessory uses, and the registry login from "First boot" |
| New accessory | `bin/kamal accessory boot valkey-cache` | the above |

Rebooting `valkey-cache` or `valkey-cable` loses nothing that matters (a cold
cache, a moment of missed live updates). Rebooting `valkey-jobs` stops Sidekiq
from reaching it for a few seconds; its data survives in the data directory.
Source your `KAMAL_VALKEY_*` overrides file first, or the reboot uses the
default sizes ([Valkey settings](#valkey-settings)). A deploy while a Valkey
accessory is missing or stopped is refused by
[the pre-deploy check](#the-pre-deploy-check).

`reboot` recreates the container and re-uploads its env file from your shell.
For the tunnel, export `CLOUDFLARE_TUNNEL_TOKEN` first: an empty value takes
the tunnel, and the site, down. The token deliberately isn't stored in GitHub,
since anyone holding it can run a connector for your hostname.

## Moving from one Redis to three Valkey instances

Deployments set up before the switch run one `redis` accessory
(`goodsorcery_web-redis`) shared by Sidekiq, the cache and Action Cable. The
move starts Sidekiq on an empty Valkey; nothing is copied over, because data
files from Redis 7.4 and later may not load in Valkey. Ingest loses nothing:
every accepted event is in Postgres (`inbound_events`) and
`goodsorcery:requeue_stale` (every 10 minutes) re-enqueues any that never got
processed. **Retries, scheduled jobs and dead jobs in the old Redis are
dropped**, along with any other job still queued there at the switch (an alert
email or Slack post, a performance batch, an uptime check). The sidekiq-cron
schedule is reloaded from `config/schedule.yml` when Sidekiq boots.

Do it in this order:

1. **Prepare the host.** As root, set `vm.overcommit_memory = 1` and add a
   1–2 GB swap file, as in [1. Server](#1-server). Neither is managed by
   Kamal. Check with `sysctl vm.overcommit_memory` and `swapon --show`.

2. **Boot the new accessories.** **If you deploy through the GitHub
   workflow, skip this step:** its deploy job runs `bin/boot_valkey_accessories`
   before `bin/kamal deploy`, which boots each Valkey accessory that isn't on
   the server yet (with the default sizes, or the `KAMAL_VALKEY_*` variables
   set in the `production` environment) and leaves running ones alone.
   Deploying from your laptop, boot them yourself first. Without the
   accessories, the new web containers would pass their health
   check and take traffic while ingest failed to enqueue and Sidekiq
   crash-looped, so [the pre-deploy check](#the-pre-deploy-check) stops such a
   deploy before any container changes. From a
   checkout that has the change (an up-to-date `main`), with the variables from
   [6. First boot](#6-first-boot) exported and your `KAMAL_VALKEY_*` overrides
   file sourced, if you have one ([Valkey settings](#valkey-settings); leave
   out an accessory whose role you point at an external server):

   ```sh
   bin/kamal accessory boot valkey-jobs
   bin/kamal accessory boot valkey-cache
   bin/kamal accessory boot valkey-cable
   bin/kamal accessory exec valkey-jobs --reuse "valkey-cli ping"   # PONG (likewise the other two)
   ```

   The old app keeps using Redis meanwhile; the new instances sit idle. If a
   role goes to an external server instead, set its
   `KAMAL_VALKEY_<ROLE>_EXTERNAL=1` flag and `KAMAL_VALKEY_<ROLE>_URL` secret
   now (in the GitHub `production` environment, and in your overrides file and
   `.kamal/secrets` locally), so the deploy picks them up.

3. **Deploy** (in the upstream repository, merging deploys through CI; on your
   own install, push or re-run your CI deploy, or run `bin/kamal deploy`).
   Expect:
   - A cold cache. Rate-limit windows start again, and each API key is looked
     up in Postgres once before it is cached again.
   - A few seconds of missed live-update broadcasts while old containers
     (publishing to Redis) and new ones (publishing to Valkey) run side by
     side. Open pages catch up on their next update or reload.
   - Don't rotate API keys during the deploy. A rotation on an old container
     clears the old cache only, so the new cache can keep accepting the old
     key for up to 5 minutes.

4. **Verify.** `bin/kamal logs -r job` should show Sidekiq starting without
   connection errors, and new events should appear in the dashboard. Events
   stranded in the old Redis count as stale once they are 10 minutes old, so
   let the 10-minute cron re-enqueue them, or run
   `bin/kamal app exec -r web "bin/rails goodsorcery:requeue_stale"` 10 or more
   minutes after the deploy (earlier, it finds nothing). Then check each
   instance's memory:
   `bin/kamal accessory exec valkey-jobs --reuse "valkey-cli info memory"`
   (and `valkey-cache`, `valkey-cable`).

5. **Remove the old Redis.** It is no longer in `deploy.yml`, so
   `bin/kamal accessory remove redis` from an up-to-date checkout can't find
   it. Over SSH as the deploy user:

   ```sh
   docker stop goodsorcery_web-redis
   docker rm goodsorcery_web-redis
   docker image rm redis:8
   # Kamal kept its data in ~/goodsorcery_web-redis (the SSH user's home). The
   # container chowned it to its own user, so delete it from a container:
   docker run --rm -v "$HOME:/deploy-home" valkey/valkey:9.1.3 rm -rf /deploy-home/goodsorcery_web-redis
   ```

   Alternatively, run `bin/kamal accessory remove redis` from a checkout of
   the commit before the switch (for example `git worktree add ../before-valkey MERGE_COMMIT^1`),
   which removes the container and the image; if it then stops at the data
   directory with "Permission denied", delete that with the last command
   above. Either way the retries and dead jobs left in it are gone for good.

## Backups

Nothing backs up Postgres yet. At minimum, schedule a nightly
`docker exec goodsorcery_web-db pg_dump -U goodsorcery_web -Fc goodsorcery_web_production`
on the server and copy the dump off it. Dumps hold encrypted error data, which
is useless without the `ACTIVE_RECORD_ENCRYPTION_*` keys, so store the keys
somewhere else.
