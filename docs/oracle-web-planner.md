# Oracle web-planner deployment

The Tide and Seek passage planner runs as an isolated static container. It does
not join, restart or depend on the Tail End Charlie Compose projects, database,
relay or Caddy network.

## Exposure boundary

The host port defaults to `127.0.0.1:4180`. This keeps the preview off the
public internet and avoids changing TEC's production TLS proxy or DNS before a
Tide and Seek domain is selected.

Reach it through an SSH tunnel:

```sh
ssh -N -L 4180:127.0.0.1:4180 oracle-relay
```

Then open `http://127.0.0.1:4180/planner.html` locally. The container serves no
API, so GPX import/export and browser-local drafts work, while short plan-code
publishing correctly remains unavailable.

## Deploy

On the host, keep the release under `/opt/tide-and-seek` and run:

```sh
cd /opt/tide-and-seek
TIDE_AND_SEEK_WEB_IMAGE_TAG=<commit-or-release> \
  docker compose -f deploy/compose.website.yaml up -d --build
docker compose -f deploy/compose.website.yaml ps
curl --fail --silent --show-error http://127.0.0.1:4180/planner.html >/dev/null
```

## Rollback

For the first isolated preview, rollback means stopping only this Compose
project:

```sh
cd /opt/tide-and-seek
docker compose -f deploy/compose.website.yaml stop planner
```

Once more than one image tag exists on the host, set
`TIDE_AND_SEEK_WEB_IMAGE_TAG` to the previous retained tag and run `up -d`
without `--build`. Never restart TEC services as part of this rollback.
