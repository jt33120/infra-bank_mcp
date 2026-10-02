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
nginx -t

# Mode Streamable HTTP SANS ETAT : chaque requete POST lance son propre process
# bank-mcp, qui est tue des que la reponse est envoyee. Aucun process ne survit
# entre deux requetes.
#
# Pourquoi pas le mode stateful (version precedente) : chaque session ouverte par
# un client (Notion, Claude...) gardait un process bank-mcp vivant indefiniment,
# car les clients ne ferment jamais leur session (pas de DELETE). Les process
# s'accumulaient jusqu'a epuiser la limite de threads du conteneur, puis chaque
# nouveau process mourait au demarrage ("pthread_create: Resource temporarily
# unavailable", SIGABRT) => "MCP tool discovery failed" cote client, jusqu'au
# prochain redemarrage du conteneur. Sans etat, il n'y a plus rien a accumuler,
# et un redemarrage du conteneur n'invalide aucune session cote client.
#
# La boucle relance supergateway s'il s'arrete pour une raison quelconque.
while true; do
  supergateway \
    --stdio "bank-mcp" \
    --outputTransport streamableHttp \
    --streamableHttpPath /mcp \
    --port 8100 \
    --healthEndpoint /healthz || true
  echo "supergateway arrete, redemarrage dans 2s..." >&2
  sleep 2
done &

# Attend que supergateway reponde avant d'ouvrir le port public, pour ne pas
# renvoyer de 502 pendant le demarrage.
i=0
until curl -fsS http://127.0.0.1:8100/healthz >/dev/null 2>&1 || [ $i -ge 30 ]; do
  i=$((i + 1))
  sleep 1
done

# nginx est le process principal : s'il s'arrete, le conteneur s'arrete et
# Railway le redemarre (restartPolicyType ALWAYS dans railway.json).
exec nginx -g 'daemon off;'
