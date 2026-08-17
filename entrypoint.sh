#!/bin/sh
set -e
: "${PORT:=8000}"

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

envsubst '${PORT} ${MCP_AUTH_TOKEN}' < /app/nginx.conf.template > /etc/nginx/nginx.conf

npx -y supergateway \
  --stdio "npx -y @bank-mcp/server" \
  --port 8000 \
  --ssePath /sse \
  --messagePath /message \
  --healthEndpoint /healthz &

nginx -g 'daemon off;'
