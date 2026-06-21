{# Rendered into secrets/frontend.env and consumed by the frontend image's
   entrypoint at container start.

   The current Vue 3 + Vite app reads VITE_WEBSITE_URL / VITE_GATEWAY_URL — the
   entrypoint injects them into window.__APP_CONFIG__ in the served index.html and
   fails fast if either is unset (see /frontend/entrypoint.sh). Without them the SPA
   resolves config to `undefined` and redirect-loops to /undefined/undefined/….

   The legacy Vue 2 VUE_APP_* vars are retained for backward compatibility so an
   older frontend image can be rolled back without re-rendering this file; the Vite
   entrypoint ignores them. Remove them once rollback is no longer a concern.

   No op:// references — pure URL config — but rendered through the same
   compose-render flow as the rest for uniformity. #}
VITE_WEBSITE_URL=https://cash-track.app
VITE_GATEWAY_URL=https://gateway.cash-track.app
VUE_APP_BASE_URL=https://my.cash-track.app
VUE_APP_API_URL=https://api.cash-track.app
VUE_APP_WEBSITE_URL=https://cash-track.app
VUE_APP_GATEWAY_URL=https://gateway.cash-track.app
