{# Mirrors infra/services/frontend/deployment.yml. The frontend image's
   entrypoint substitutes these into the served bundle / nginx config at
   container start (Vue 2 build still consumes VUE_APP_*; the Vue 3 + Vite
   migration tracked in /frontend/MIGRATION.md will eventually swap to VITE_*).
   No op:// references — pure URL config — but rendered through the same
   compose-render flow as the rest for uniformity. #}
VUE_APP_BASE_URL=https://my.cash-track.app
VUE_APP_API_URL=https://api.cash-track.app
VUE_APP_WEBSITE_URL=https://cash-track.app
VUE_APP_GATEWAY_URL=https://gateway.cash-track.app
