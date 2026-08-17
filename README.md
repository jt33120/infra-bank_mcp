# bank-mcp-railway

Serveur MCP bancaire perso (lecture seule) : Boursobank + BNP Paribas via Enable Banking (PSD2, gratuit),
expose en HTTPS avec authentification bearer, pret pour Railway + connexion MCP custom dans Notion.

## Contenu
- `bank-mcp` (@bank-mcp/server) : serveur MCP open source read-only (comptes, transactions, soldes)
- `supergateway` : pont stdio -> Streamable HTTP (stateful, une session/process enfant par client)
- `nginx` : verification du header `Authorization: Bearer $MCP_AUTH_TOKEN` (401 sinon)

## Connexion client MCP (Notion, etc.)
- URL : `https://<domaine>/mcp`
- Transport : **Streamable HTTP** (pas SSE — l'ancien pont stdio->SSE de supergateway
  partage un seul process enfant entre toutes les connexions et plante des qu'un client
  ouvre une 2e connexion SSE en parallele ; le mode Streamable HTTP stateful isole
  chaque session dans son propre process enfant)
- Auth : `Authorization: Bearer <MCP_AUTH_TOKEN>`

## Variables d'environnement (Railway)
| Variable | Contenu |
|---|---|
| `BANK_MCP_HOME_B64` | `tar czf - -C ~ .bank-mcp \| base64` (apres `npx -y @bank-mcp/server init`) |
| `MCP_AUTH_TOKEN` | `openssl rand -hex 32` |

nginx ecoute en dur sur le port `8080` (pas de variable `$PORT`) : c'est le seul point d'entree
public. `supergateway` ecoute en interne sur `127.0.0.1:8100`, jamais expose directement.

## Deploiement
1. Pousser ce dossier sur un repo GitHub PRIVE : `gh repo create bank-mcp-railway --private --push --source=.`
2. Railway : New Project -> Deploy from GitHub -> choisir le repo
3. Renseigner les variables ci-dessus
4. Settings -> Networking -> Generate Domain, puis s'assurer que le domaine cible le port `8080`
5. Tester : `curl -H "Authorization: Bearer <token>" https://<url>/healthz` -> `ok`

## Securite
- JAMAIS de cle privee, config ou token dans le repo, Notion ou un chat : uniquement dans les variables Railway.
- Le serveur ne lit que des donnees : aucune ecriture bancaire possible (read-only au niveau du code bank-mcp).
- Consentement PSD2 a renouveler tous les ~90 jours : relancer `npx -y @bank-mcp/server init` puis maj `BANK_MCP_HOME_B64`.
