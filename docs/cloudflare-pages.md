# Cloudflare Pages website deployment

The static Tide and Seek website is hosted in the Cloudflare Pages project
`tide-and-seek`. Direct Upload was selected for the first private development
cycle; it does not require a paid Pages plan or a runtime Function.

## Build and deploy

```sh
tools/build_website.sh
npx --yes wrangler@4.125.0 pages deploy build/website \
  --project-name tide-and-seek \
  --branch main
```

The production Pages address is `https://tide-and-seek.pages.dev/`. The custom
hostname is `https://tide-and-seek.tailendcharlie.app/` and must be associated
with the Pages project before its Cloudflare DNS CNAME is considered complete.

The build step deliberately excludes the container configuration, repository
README and tests from the public upload. `_headers` remains in the output so
the chart-provider allow-list and security policy are applied by Pages.

## Rollback

Cloudflare keeps immutable Pages deployments. In the dashboard, open Workers &
Pages, select `tide-and-seek`, open Deployments, choose the last known-good
production deployment and select Rollback. Do not change the custom-domain DNS
record merely to roll back site content.
