FROM node:20-alpine
# tini en PID 1 : recolte les process zombies (chaque requete MCP lance puis tue un
# process bank-mcp) et relaie SIGTERM proprement a nginx et supergateway.
RUN apk add --no-cache nginx gettext tini curl

# Versions figees et installees au build : plus aucun telechargement npm au
# demarrage du conteneur ni a chaque requete (avant : `npx -y` relancait une
# resolution npm a chaque session, lente et dependante du registre npm).
# supergateway >= 4.1 : gestion correcte du mode sans etat et des process enfants.
RUN npm install -g --omit=dev supergateway@4.1.0 @bank-mcp/server@0.2.1 \
 && npm cache clean --force

WORKDIR /app
COPY nginx.conf.template entrypoint.sh ./
RUN chmod +x entrypoint.sh

EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD curl -fsS http://127.0.0.1:8080/healthz || exit 1

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["./entrypoint.sh"]
