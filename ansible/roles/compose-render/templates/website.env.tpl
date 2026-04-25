{# Mirrors infra/services/website/deployment.yml. Both NUXT_PUBLIC_* and the
   non-prefixed copies are emitted because the existing K8s deployment does the
   same — leaving them aligned reduces surprise during cutover. #}
NUXT_PUBLIC_BASE_URL=https://cash-track.app
NUXT_PUBLIC_WEB_APP_URL=https://my.cash-track.app
NUXT_PUBLIC_GATEWAY_URL=https://gateway.cash-track.app
NUXT_PUBLIC_GOOGLE_ANALYTICS_ID=UA-28063621-2
BASE_URL=https://cash-track.app
WEB_APP_URL=https://my.cash-track.app
GATEWAY_URL=https://gateway.cash-track.app
GOOGLE_ANALYTICS_ID=UA-28063621-2

# common vault — captcha + Google client id (public-key class but rotated like a secret).
NUXT_PUBLIC_CAPTCHA_CLIENT_KEY={{ op_prefix }}/common/CAPTCHA_CLIENT_KEY
NUXT_PUBLIC_GOOGLE_CLIENT_ID={{ op_prefix }}/common/GOOGLE_API_CLIENT_ID
CAPTCHA_CLIENT_KEY={{ op_prefix }}/common/CAPTCHA_CLIENT_KEY
GOOGLE_CLIENT_ID={{ op_prefix }}/common/GOOGLE_API_CLIENT_ID
