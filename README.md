# itesoft_sortant_ack_uat

Runbooks Azure Automation (Hybrid Runbook Worker Windows + WinSCP) qui
déplacent les fichiers ITESOFT sur le serveur SFTP. Deux scripts, chacun
utilisé par un runbook UAT et un runbook PROD (paramètre `Environment`) :

| Script | Runbooks | Flux |
|---|---|---|
| [`runbooks/Move-ItesoftSortantAck.ps1`](runbooks/Move-ItesoftSortantAck.ps1) | `itesoft_sortant_ack_uat`, `itesoft_sortant_ack_prod` | ACK : invoices des systèmes → sortie commune |
| [`runbooks/Move-ItesoftSortant.ps1`](runbooks/Move-ItesoftSortant.ps1) | `itesoft_sortant_uat`, `itesoft_sortant_prod` | SORTANT : entrée commune → invoices du système |

Prérequis, variables et paramètre `Environment` : communs aux deux scripts
(voir ci-dessous).

## Flux ACK (`Move-ItesoftSortantAck.ps1`)

```
/root/outbound/<SYSTEME>/output/invoices/<SOUS-DOSSIER>/<FICHIER>.json
        └──► /root/outbound/azure_automation/output/<FICHIER>.json
```

Chaque déplacement est aussi journalisé dans un CSV sur le SFTP.

## Flux SORTANT (`Move-ItesoftSortant.ps1`)

```
/root/outbound/azure_automation/input/<Numero>_<SYS>_<CompanyCode>_<LegalTaxContext>_<Format>.xml
        └──► /root/outbound/<SYSTEME>/output/invoices/<CompanyCode>_<LegalTaxContext>_<Format>/<même nom>
```

Transcodification `<SYS>` → `<SYSTEME>` (table `$SystemCodes` en tête du script) :

| Code | Système |
|---|---|
| BLS | TALENTIA_BLUECARSHARING |
| BLU | TALENTIA_BLUEUS |
| BSE | TALENTIA_BSE |
| ODE | TALENTIA_ODET |
| VIG | TALENTIA_VIGNES |
| MED | TALENTIA_MEDIA |

- Le nom est lu depuis la droite : le numéro de facture peut contenir des `_`,
  pas les trois derniers segments. Extension et code insensibles à la casse.
- Le sous-dossier `<CompanyCode>_<LegalTaxContext>_<Format>` est créé s'il
  n'existe pas ; le répertoire `.../output/invoices` du système doit exister.
- Restent dans `input`, signalés en `[ERREUR]` et retentés au passage suivant :
  nom non conforme, code système inconnu, répertoire invoices absent, fichier
  cible déjà présent.
- Les fichiers qui ne sont pas des `.xml` sont ignorés sans erreur.

## Prérequis

- Hybrid Worker Windows avec WinSCP installé
  (`C:\Program Files (x86)\WinSCP\WinSCPnet.dll` et `WinSCP.exe` dans le même dossier).
- Paramètre du runbook **`Environment`** : `UAT` ou `PROD` (obligatoire, à
  renseigner dans chaque planification). Le même script sert aux runbooks
  `itesoft_sortant_ack_uat` et `itesoft_sortant_ack_prod`.
- Variables Azure Automation (`<ENV>` = `UAT` ou `PROD`) :

| Variable               | Portée       | Obligatoire | Description                                        |
|------------------------|--------------|-------------|----------------------------------------------------|
| `SFTP_HOST_<ENV>`      | par env      | oui         | Nom ou IP du serveur SFTP                          |
| `SFTP_PASSWORD_<ENV>`  | par env      | oui         | Mot de passe (variable **chiffrée**)               |
| `SFTP_HOSTKEY_<ENV>`   | par env      | non         | Empreinte SSH, ex. `ssh-ed25519 255 xxxx...`. Sans elle, toutes les clés sont acceptées. |
| `SFTP_USER`            | commune      | oui         | Utilisateur (identique UAT / PROD)                 |
| `SFTP_PORT`            | commune      | oui         | Port (identique UAT / PROD)                        |

## Paramètres (en tête du script)

| Paramètre                  | Défaut   | Rôle                                                        |
|----------------------------|----------|-------------------------------------------------------------|
| `$Simulation`              | `$false` | `$true` : liste ce qui serait déplacé sans rien toucher     |
| `$FileMask`                | `*.json` | Seuls les fichiers correspondant à ce masque sont déplacés (insensible à la casse) |
| `$OverwriteExistingTarget` | `$false` | Écraser un fichier du même nom déjà présent dans la cible   |
| `$WinScpSessionLog`        | `%TEMP%\itesoft_sortant_ack_<env>_winscp.log` | Journal WinSCP détaillé (`$null` pour désactiver) |

## Fonctionnement

- **Déplacement** par renommage SFTP : instantané, côté serveur, sans transfert
  de données. Si le serveur refuse le renommage (par exemple systèmes de fichiers
  différents), repli automatique : téléchargement → envoi → suppression de la
  source. Si la suppression de la source échoue, la copie cible est retirée pour
  ne pas créer de doublon.
- **Fichier de même nom déjà présent dans la cible** : la source est laissée en
  place et une erreur est signalée ; le fichier est retenté au passage suivant.
- **Journal CSV** (`itesoft_sortant_ack_copies.csv`, mêmes colonnes qu'avant,
  statut `DEPLACEMENT_OK`) : les nouvelles lignes sont **ajoutées en fin de
  fichier** (append), une fois par sous-dossier puis en fin de traitement. Le CSV
  n'est plus téléchargé ni réécrit en entier. Si l'envoi échoue en fin de
  traitement, les lignes sont affichées dans la sortie du job.

## Suivi dans Log Analytics

Chaque déplacement, chaque erreur et le bilan de chaque exécution sont aussi
écrits sous forme de lignes structurées (`ITESOFT_MOVE`, `ITESOFT_ERROR`,
`ITESOFT_BILAN` suivies d'un JSON) dans la sortie du job. Mise en place,
requêtes KQL, partage et alerte : [`docs/log-analytics.md`](docs/log-analytics.md).

Les requêtes reconnaissent les lignes grâce au préfixe `ITESOFT_` : le nom du
runbook dans Azure Automation n'a pas d'importance.

Architecture cible (4 runbooks UAT/PROD, contrat de journalisation, règles
d'alerte) : [`docs/alerting-architecture.md`](docs/alerting-architecture.md).

## Historique des corrections

Version déplacement :
- copie remplacée par un déplacement (renommage SFTP, repli get/put/delete) ;
- CSV en append une fois par sous-dossier au lieu d'un renvoi complet après
  chaque fichier ;
- plus de déduplication par CSV : la source disparaît après déplacement, le
  CSV n'est jamais relu ;
- dossiers vides non journalisés ; code simplifié (~110 lignes de moins).

Première révision du script d'origine :
1. Erreurs de syntaxe `:NewGuid()` / `:IsNullOrWhiteSpace(...)`.
2. `PreserveTimestamp` désactivé (erreurs `setstat` sur beaucoup de serveurs).
3. Chemins échappés avec `EscapeFileMask` (noms contenant `[ ] * ?`).
4. Collisions de noms dans la cible détectées au lieu d'écrasements silencieux.
5. `SFTP_PORT` validé, empreinte SSH optionnelle, journal WinSCP.

## Point d'attention

Le CSV est écrit **dans le répertoire de sortie**. Si un traitement aval ramasse
tous les fichiers de ce dossier, il ramassera aussi le CSV : dans ce cas,
déplacer `$RemoteCsv` vers un autre dossier.
