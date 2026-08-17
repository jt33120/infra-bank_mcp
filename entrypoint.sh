#!/bin/sh
set -e

if [ -z "$BANK_MCP_HOME_B64" ]; then
  echo "ERROR: BANK_MCP_HOME_B64 manquant (tar base64 de ~/.bank-mcp)" >&2
  exit 1
fi
echo "$BANK_MCP_HOME_B64" | base64 -d | tar xzf - -C /root
chmod 700 /root/.bank-mcp 2>/dev/null || true
chmod 600 /root/.bank-mcp/config.json 2>/dev/null || true

if [ -z "$MCP_AUTH_TOKEN" ]; then
  echo "ERROR: MCP_AUTH_TOKEN manquant" >&2
  exit 1
fi

envsubst '${MCP_AUTH_TOKEN}' < /app/nginx.conf.template > /etc/nginx/nginx.conf

# stdio->SSE mode in supergateway shares one Server/child process across every
# SSE connection: a second concurrent connection makes it throw "Already
# connected to a transport", an uncaught exception that kills the whole
# process (nginx then proxies to a dead upstream forever). Stateful
# Streamable HTTP gives each session its own Server + child process, so one
# session dying can't take the others down. Restart-loop below is defense in
# depth in case supergateway exits for any other reason.
while true; do
  npx -y supergateway \
    --stdio "npx -y @bank-mcp/server" \
    --outputTransport streamableHttp \
    --stateful \
    --streamableHttpPath /mcp \
    --port 8100 \
    --healthEndpoint /healthz
  echo "supergateway exited (code $?), restarting in 2s..." >&2
  sleep 2
done &

nginx -g 'daemon off;'
