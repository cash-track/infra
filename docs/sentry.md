# Sentry error tracking

## Overview

Sentry is errors-only. Tracing stays on Tempo — every SDK disables Sentry's own tracing
(`traces_sample_rate`/`EnableTracing`/`tracesSampleRate` are off in api, gateway, frontend
and website).

- **Four projects, four DSNs:**
  - `cash-track-api` — PHP API.
  - `cash-track-gateway` — Go gateway.
  - `cash-track-frontend` — its own DSN, strict rate limit, Allowed Domains.
  - `cash-track-website` — its own DSN, strict rate limit, Allowed Domains.
- **`trace_id` tag + `tempo` context:** api and gateway tag every event with the OTel
  `trace_id` and attach a `tempo` context whose `url` is a ready-to-click Grafana Tempo
  Explore link, built from the `SENTRY_TEMPO_URL` template (`{trace_id}` placeholder).
  Browser events (frontend, website) tag `trace_id` too, taken from the gateway's
  CORS-exposed `X-Ct-Trace-Id` header, but carry no Tempo link — the internal Grafana
  hostname must not ship in public bundles.
- **Loki `AppErrorLogSpike` backstop:** `compose/config/loki/rules/app-errors.yml` fires
  a warning if api or gateway log more than 20 ERROR+ records in 10 minutes, whether or
  not Sentry is reachable.
- **Non-goals (deliberate):**
  - Caught-and-logged API errors (`$this->logger->error(...)`) are not sent to Sentry —
    only unhandled exceptions are. A Monolog→Sentry bridge would duplicate every one of
    those, since `LoggerReporter` already logs them.
  - Website SSR (Nitro) errors are not captured — `@sentry/nuxt` server-side capture
    needs a Node `--import` preload the deploy doesn't set up. The website is mostly
    static.
  - Gateway panics still crash the process; Sentry reports the panic first, then it
    re-panics. Recovering into a 500 would be a behaviour change nobody asked for.

## 1. Sentry organisation setup (one-time, in the Sentry UI)

1. Create four projects:
   - `cash-track-api` (PHP).
   - `cash-track-gateway` (Go).
   - `cash-track-frontend` (Vue).
   - `cash-track-website` (Vue).
2. **Client Keys (DSN) → Configure → Rate Limit**, per project:
   - api: 2000 events/hour
   - gateway: 1000 events/hour
   - frontend: 300 events/hour
   - website: 100 events/hour

   Browser DSNs are public, so their limits cap abuse and quota burn.
3. **Browser projects → Settings → Security & Privacy → Allowed Domains:**
   - frontend: `my.cash-track.app`
   - website: `cash-track.app`, `www.cash-track.app`
4. **Inbound Filters** on the browser projects: enable browser extensions, legacy
   browsers, web crawlers, and localhost.
5. **Org → Subscription → Spike Protection:** on.
6. **Data scrubbing:** keep "Data Scrubber" and "Use default scrubbers" on in every
   project. This is defence in depth on top of the API's `BeforeSend`, which already
   strips request bodies and cookies.
7. **Alerts → Create Alert → Issues**, for each project:
   - "A new issue is created" → email.
   - "Number of events in an issue is more than 50 in 1h" → email.

   To jump from an issue to its trace: open the event → **Contexts → tempo → url**
   (tailnet only), or search `trace_id:<id>` across projects.
8. Per-service ignore lists live in code, so change them with a PR:
   - api: `app/config/sentry.php` → `ignore_exceptions`
   - gateway: `errtrack/errtrack.go` → `ignoredErrors`
   - frontend: `src/shared/sentry.ts` → `IGNORED_ERRORS`
   - website: `app/plugins/sentry.client.ts`

   For one-off noise, use Sentry's **Issue → Ignore** / **Delete & Discard** instead of
   a code change.

## 2. 1Password

Do this **before** merging this infra PR — `op inject` fails the whole deploy if the
`sentry` item doesn't exist yet. The commands below never echo a DSN.

```bash
eval "$(op signin)"
op item create --vault cash-track-prod --category "Secure Note" --title sentry \
  "API_DSN[password]=$(pbpaste)"   # copy the api DSN first
op item edit --vault cash-track-prod sentry "GATEWAY_DSN[password]=$(pbpaste)"
op item edit --vault cash-track-prod sentry "FRONTEND_DSN[password]=$(pbpaste)"
op item edit --vault cash-track-prod sentry "WEBSITE_DSN[password]=$(pbpaste)"
for f in API_DSN GATEWAY_DSN FRONTEND_DSN WEBSITE_DSN; do
  op read "op://cash-track-prod/sentry/$f" >/dev/null && echo "$f ok"   # existence check only
done
```

The item is `op://cash-track-prod/sentry` with fields `API_DSN`, `GATEWAY_DSN`,
`FRONTEND_DSN` and `WEBSITE_DSN`, matching the `SENTRY_DSN` / `VITE_SENTRY_DSN` / `NUXT_PUBLIC_SENTRY_DSN`
references in `ansible/roles/compose-render/templates/{api,gateway,frontend,website}.env.tpl`.

## 3. Deploy

1. Merge and release the api, gateway, frontend and website PRs first. They are no-ops
   without a DSN, so this is safe before the 1Password item exists.
2. Create the 1Password item (§2 above).
3. Then `make deploy`, which re-renders the env files, recreates loki with the rules
   mount, and restarts the services.

## 4. Verify (operator, after deploy)

- **Loki rule loaded:**

  ```bash
  ./infra/ssh-prod docker-obs exec loki wget -qO- http://localhost:3100/loki/api/v1/rules
  ```

  Should list `AppErrorLogSpike`.
- **Server DSNs work:**

  ```bash
  ./infra/ssh-prod 'set -a; . /opt/cashtrack/secrets/api.env; docker run --rm -e SENTRY_DSN getsentry/sentry-cli send-event -m "sentry wiring check"'
  ```

  The event should appear in `cash-track-api`. Repeat with `gateway.env` and check
  `cash-track-gateway`. The DSN is sourced into the environment and never printed.
- **Trace link end-to-end:** request a non-existent resource that makes the api throw,
  or wait for a real error. Confirm the issue has a `trace_id` tag and that
  `tempo.url` opens the trace in Grafana over the tailnet.
- **Browser DSNs:** check that the frontend has no `sentry-trace` header on gateway
  requests (DevTools → Network) — trace propagation to the gateway is disabled by
  design (CORS preflight would reject it).

## 5. Rotating a DSN

In Sentry: **Client Keys → generate a new key** → update the matching 1Password field
(§2) → `make deploy` → disable the old key.
