# Sentry error tracking

## Overview

Sentry is errors-only. Tracing stays on Tempo — every SDK disables Sentry's own tracing
(`traces_sample_rate`/`EnableTracing`/`tracesSampleRate` are off in api, gateway, frontend
and website).

- **Four projects, four DSNs** (org `cashtrack-o2`, EU region):
  - `api` — PHP API.
  - `gateway` — Go gateway.
  - `frontend` — its own DSN, strict rate limit, Allowed Domains.
  - `website` — its own DSN, strict rate limit, Allowed Domains.
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
  - Caught-and-logged API errors reach Sentry only when logged with an `'exception'`
    context (`ExceptionToSentryIssueHandler`); plain error lines stay in Loki.
    `BeforeSend` drops a repeat of the same exception instance, so a logged-then-reported
    exception is one event.
  - Website SSR (Nitro) errors are not captured — `@sentry/nuxt` server-side capture
    needs a Node `--import` preload the deploy doesn't set up. The website is mostly
    static.
  - Gateway panics still crash the process; Sentry reports the panic first, then it
    re-panics. Recovering into a 500 would be a behaviour change nobody asked for.

## 1. Sentry organisation setup (one-time, in the Sentry UI)

1. Create four projects:
   - `api` (PHP).
   - `gateway` (Go).
   - `frontend` (Vue).
   - `website` (Vue).
2. **Client Keys (DSN) → Configure → Rate Limit**, per project:
   - api: 2000 events/hour
   - gateway: 1000 events/hour
   - frontend: 300 events/hour
   - website: 100 events/hour

   Browser DSNs are public, so their limits cap abuse and quota burn.
3. **Browser projects → Settings → Security & Privacy → Allowed Domains:**
   - frontend: `my.cash-track.app`, `my.dev-cash-track.app`
   - website: `cash-track.app`, `www.cash-track.app`, `dev-cash-track.app`

   The dev domains let a local stack with a DSN set report too. Its events carry
   `environment: development` (the dev server's build mode); built images report
   `production`.
4. **Inbound Filters** on the browser projects: enable browser extensions, legacy
   browsers, web crawlers, and localhost.
5. **Org → Subscription → Spike Protection:** on.
6. **Data scrubbing:** keep "Data Scrubber" and "Use default scrubbers" on in every
   project. This is defence in depth on top of the API's `BeforeSend`, which already
   strips request bodies and cookies.
7. **Alerts:** two alerts, each connected to all four projects, both emailing the owner:
   - "New issue": a new issue is created → email.
   - "Issue over 50 events in 1h": number of events in an issue is more than 50 in 1h
     → email.

   Delete Sentry's per-project default "Send a notification for high priority issues"
   alerts; they duplicate "New issue".

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

Do this **before** merging the infra PR — the merge deploys, and `op inject` fails the
whole deploy if the `sentry` item doesn't exist yet. The commands below never echo a DSN.

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

## 3. Rollout order

Merging to infra `main` **is** the deploy: `.github/workflows/ansible.yml` runs
`site.yml` against prod on every push touching `ansible/`, `compose/` or `terraform/`.

1. Create the 1Password item (§2). Hard requirement: without it the deploy triggered
   by the infra merge fails at `op inject`.
2. Merge and release the api, gateway, frontend and website Sentry PRs. They are no-ops
   until the env files carry a DSN, so they can ship any time before step 3.
3. Merge the infra PR. CI re-renders the env files, recreates loki with the rules mount
   and restarts the services. Run `make deploy` only if that CI run failed.
4. Verify (§4).

Order between steps 2 and 3 is not a hard constraint: current images ignore the new
`SENTRY_*` variables. Apps first just means Sentry is live as soon as step 3 finishes.

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

  The event should appear in `api`. Repeat with `gateway.env` and check
  `gateway`. The DSN is sourced into the environment and never printed.
- **Trace link end-to-end:** request a non-existent resource that makes the api throw,
  or wait for a real error. Confirm the issue has a `trace_id` tag and that
  `tempo.url` opens the trace in Grafana over the tailnet.
- **Browser DSNs:** check that the frontend has no `sentry-trace` header on gateway
  requests (DevTools → Network) — trace propagation to the gateway is disabled by
  design (CORS preflight would reject it).

## 5. Rotating a DSN

In Sentry: **Client Keys → generate a new key** → update the matching 1Password field
(§2) → `make deploy` → disable the old key.
