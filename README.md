# bank-mcp-railway

Serveur MCP bancaire perso (lecture seule) : Boursobank + BNP Paribas via Enable Banking (PSD2, gratuit),
expose en HTTPS avec authentification bearer, deploye sur Railway et utilisable depuis Notion, Claude, etc.

## Contenu
- `bank-mcp` (`@bank-mcp/server`, version figee) : serveur MCP open source read-only (comptes, transactions, soldes)
- `supergateway` (version figee) : pont stdio -> Streamable HTTP, en mode **sans etat**
- `nginx` : seul point d'entree public, verifie `Authorization: Bearer $MCP_AUTH_TOKEN` (401 sinon)
- `tini` : PID 1 du conteneur, recolte les process termines

Les deux paquets npm sont installes **au build** (Dockerfile) : rien n'est telecharge au demarrage
ni pendant une requete.

## Utilisation

### Ce que le serveur sait faire

| Outil | Role | Parametres utiles |
|---|---|---|
| `list_accounts` | Liste les comptes (UID, IBAN, nom, devise) | `connectionId` |
| `get_balance` | Solde(s) actuel(s) | `accountId`, `connectionId` |
| `list_transactions` | Transactions filtrees (90 derniers jours par defaut) | `dateFrom`, `dateTo`, `accountId`, `amountMin`, `amountMax`, `type`, `limit` |
| `search_transactions` | Recherche texte (libelle, marchand, reference) | `query`, `dateFrom`, `dateTo`, `limit` |
| `spending_summary` | Depenses regroupees par marchand ou categorie | `groupBy`, `dateFrom`, `dateTo`, `limit` |

Les dates sont au format `AAAA-MM-JJ`. Exemples de demandes a l'assistant :
- « Quel est le solde de mes comptes ? »
- « Liste mes transactions de septembre 2026 au-dessus de 100 € »
- « Cherche les paiements AMAZON depuis juillet »
- « Resume mes depenses du mois dernier par marchand »

Astuce : preferer des periodes courtes ou `search_transactions` / `spending_summary` a un
`list_transactions` sur plusieurs mois avec `limit: 500` — la reponse est enorme (plusieurs
centaines de Ko) et consomme beaucoup de contexte cote assistant.

### Parametres de connexion (communs a tous les clients)
- URL : `https://bank-mcp-railway-production.up.railway.app/mcp`
- Transport : **Streamable HTTP** (pas SSE : `/sse` n'existe plus)
- Auth : **en-tete** `Authorization: Bearer <MCP_AUTH_TOKEN>` — pas OAuth

### Notion
Ajouter une connexion MCP personnalisee avec l'URL ci-dessus et l'authentification par en-tete /
cle d'API (nom `Authorization`, valeur `Bearer <MCP_AUTH_TOKEN>`).

Notion choisit sa methode de connexion tout seul, d'apres ce que le serveur annonce. Le serveur est
donc sans ambiguite pour qu'il ne parte pas en OAuth (qui ne peut pas aboutir ici) :
- `/.well-known/*` et `/oauth/*` renvoient `404` (et non `401`)
- les `401` portent `WWW-Authenticate: Bearer`, sans parametre `resource_metadata`
- les preflights CORS (`OPTIONS`) passent sans authentification

### Claude Code
```sh
claude mcp add --transport http banques \
  https://bank-mcp-railway-production.up.railway.app/mcp \
  --header "Authorization: Bearer <MCP_AUTH_TOKEN>"
```

### API Claude (connecteur MCP)
```json
"mcp_servers": [{
  "type": "url",
  "name": "banques",
  "url": "https://bank-mcp-railway-production.up.railway.app/mcp",
  "authorization_token": "<MCP_AUTH_TOKEN>"
}]
```

### Tester a la main (curl)
```sh
URL=https://bank-mcp-railway-production.up.railway.app
TOKEN=<MCP_AUTH_TOKEN>

# 1. Le service est-il vivant ? (sans auth) -> ok
curl $URL/healthz

# 2. Le token est-il bon et les outils visibles ? -> liste des 5 outils
curl -s $URL/mcp \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'

# 3. Un vrai appel bancaire -> soldes
curl -s $URL/mcp \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_balance","arguments":{}}}'
```

### En cas d'erreur
| Symptome | Cause probable | Que faire |
|---|---|---|
| `/healthz` ne repond pas / 502 | Conteneur en (re)demarrage | Attendre ~30 s ; sinon logs Railway |
| `401` | Token absent ou faux | Verifier `Bearer <MCP_AUTH_TOKEN>` dans le client |
| `tools/list` OK mais `tools/call` en erreur banque | Consentement PSD2 expire (~90 j) | Voir « Renouveler le consentement » |
| « MCP tool discovery failed » | Serveur injoignable | Tester `/healthz` puis l'etape 2 ci-dessus |

## Stabilite : pourquoi le mode sans etat

Version precedente (supergateway en mode *stateful*) : chaque session ouverte par un client
gardait un process `bank-mcp` (plus son wrapper `npx`) vivant **indefiniment**, car Notion et
les autres clients ne ferment jamais leurs sessions. Les process s'accumulaient (memoire du
conteneur montee a 2,3 Go) jusqu'a epuiser la limite de threads du conteneur. A partir de la,
chaque nouveau process mourait au demarrage :

```
Child stderr: node[1487]: pthread_create: Resource temporarily unavailable
Child exited: code=null, signal=SIGABRT
```

=> le premier appel passait, puis toutes les decouvertes d'outils echouaient
(« MCP tool discovery failed ») jusqu'au prochain redemarrage du conteneur.

Maintenant :
- **Sans etat** : chaque requete lance son propre process `bank-mcp`, tue des la reponse
  envoyee. Rien ne s'accumule, et un redemarrage du conteneur n'invalide aucune session cote
  client (il n'y en a plus). Teste : 600 requetes dont 20 en parallele, 0 echec, nombre de
  process et memoire (~90 Mo) constants. Cout : ~0,7 s de demarrage par requete.
- **Versions figees, installees au build** : plus de `npx -y` qui interrogeait le registre npm
  a chaque session.
- **Auto-reparation** : supergateway est relance automatiquement s'il s'arrete ; si nginx
  s'arrete, le conteneur s'arrete et Railway le redemarre (`restartPolicyType: ALWAYS`).
- **Healthcheck** : `/healthz` (sans auth, ne renvoie que `ok`) traverse nginx jusqu'a
  supergateway ; Railway ne bascule le trafic sur un nouveau deploiement que lorsqu'il repond.

## Variables d'environnement (Railway)
| Variable | Contenu |
|---|---|
| `BANK_MCP_HOME_B64` | `tar czf - -C ~ .bank-mcp \| base64` (apres `npx -y @bank-mcp/server init`) |
| `MCP_AUTH_TOKEN` | `openssl rand -hex 32` |

nginx ecoute en dur sur le port `8080` (pas de variable `$PORT`) : c'est le seul point d'entree
public. `supergateway` ecoute en interne sur `127.0.0.1:8100`, jamais expose directement.

## Deploiement
1. Repo GitHub PRIVE, Railway : New Project -> Deploy from GitHub -> choisir le repo
2. Renseigner les variables ci-dessus
3. Settings -> Networking -> Generate Domain, cible le port `8080`
4. `railway.json` regle le build (Dockerfile), le healthcheck et la politique de redemarrage
5. Tester avec les commandes curl ci-dessus

Les logs nginx et supergateway partent sur stdout/stderr : visibles directement dans les logs Railway.

## Renouveler le consentement PSD2 (~tous les 90 jours)
1. En local : `npx -y @bank-mcp/server@0.2.1 init` (reconnecte les banques)
2. `tar czf - -C ~ .bank-mcp | base64` puis coller le resultat dans `BANK_MCP_HOME_B64` sur Railway
3. Railway redeploie automatiquement

## Securite
- JAMAIS de cle privee, config ou token dans le repo, Notion ou un chat : uniquement dans les variables Railway.
- Le serveur ne lit que des donnees : aucune ecriture bancaire possible (read-only au niveau du code bank-mcp).
