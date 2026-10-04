# syntax=docker/dockerfile:1

# Access-key gate in front of surfpool. The only Public service; surfpool's own
# ports flip to Private, reachable only as surfpool:<port> on the NF network.
FROM caddy:2-alpine

COPY Caddyfile /etc/caddy/Caddyfile
RUN caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile

EXPOSE 8899 8900

CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
