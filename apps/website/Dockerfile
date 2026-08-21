FROM caddy:2.11.4-alpine

COPY Caddyfile /etc/caddy/Caddyfile
COPY . /srv
RUN setcap -r /usr/bin/caddy && rm /srv/Caddyfile

EXPOSE 8080
