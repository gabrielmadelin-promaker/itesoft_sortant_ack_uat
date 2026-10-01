# itesoft_sortant_ack_uat

Runbook Azure Automation (Hybrid Runbook Worker Windows + WinSCP) qui
**déplace** les fichiers ITESOFT sortants des systèmes TALENTIA vers un
répertoire de sortie unique sur le serveur SFTP, et journalise chaque
déplacement dans un CSV.

```
/root/outbound/<SYSTEME>/output/invoices/<SOUS-DOSSIER>/<FICHIER>
        └──► /root/outbound/azure_automation/output/<FICHIER>
```

Script : [`runbooks/Move-ItesoftSortantAck.ps1`](runbooks/Move-ItesoftSortantAck.ps1)

## Prérequis

- Hybrid Worker Windows avec WinSCP installé
  (`C:\Program Files (x86)\WinSCP\WinSCPnet.dll` et `WinSCP.exe` dans le même dossier).
- Variables Azure Automation :

| Variable        | Obligatoire | Description                                        |
|-----------------|-------------|----------------------------------------------------|
| `SFTP_HOST`     | oui         | Nom ou IP du serveur SFTP                          |
| `SFTP_PORT`     | oui         | Port (22 en général)                               |
| `SFTP_USER`     | oui         | Utilisateur                                        |
| `SFTP_PASSWORD` | oui         | Mot de passe (variable **chiffrée**)               |
| `SFTP_HOSTKEY`  | non         | Empreinte SSH, ex. `ssh-ed25519 255 xxxx...`. Sans elle, toutes les clés sont acceptées. |

## Paramètres (en tête du script)

| Paramètre                  | Défaut   | Rôle                                                        |
|----------------------------|----------|-------------------------------------------------------------|
| `$Simulation`              | `$false` | `$true` : liste ce qui serait déplacé sans rien toucher     |
| `$OverwriteExistingTarget` | `$false` | Écraser un fichier du même nom déjà présent dans la cible   |
| `$WinScpSessionLog`        | `%TEMP%\itesoft_sortant_ack_winscp.log` | Journal WinSCP détaillé (`$null` pour désactiver) |

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

Les requêtes filtrent sur le nom de runbook `Move-ItesoftSortantAck` : à adapter
si le runbook porte un autre nom dans Azure Automation.

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
