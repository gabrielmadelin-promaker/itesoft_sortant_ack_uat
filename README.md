# itesoft_sortant_ack_uat

Runbook Azure Automation (Hybrid Runbook Worker Windows + WinSCP) qui copie les
fichiers ITESOFT sortants des systèmes TALENTIA vers un répertoire de sortie
unique sur le serveur SFTP, avec un historique CSV qui empêche les recopies.

```
/root/outbound/<SYSTEME>/output/invoices/<SOUS-DOSSIER>/<FICHIER>
        └──► /root/outbound/azure_automation/output/<FICHIER>
```

Script : [`runbooks/Copy-ItesoftSortantAck.ps1`](runbooks/Copy-ItesoftSortantAck.ps1)

## Prérequis

- Hybrid Worker Windows avec WinSCP installé
  (`C:\Program Files (x86)\WinSCP\WinSCPnet.dll` et `WinSCP.exe` dans le même dossier).
  WinSCP 5.19 ou plus récent recommandé pour `DuplicateFile`.
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
| `$Simulation`              | `$false` | `$true` : liste ce qui serait copié sans rien copier        |
| `$OverwriteExistingTarget` | `$false` | Écraser un fichier du même nom déjà présent dans la cible   |
| `$WinScpSessionLog`        | `%TEMP%\itesoft_sortant_ack_winscp.log` | Journal WinSCP détaillé (`$null` pour désactiver) |

## Corrections apportées à la version initiale

1. **Erreurs de syntaxe** : `:NewGuid()` et `:IsNullOrWhiteSpace(...)` →
   `[guid]::NewGuid()` et `[string]::IsNullOrWhiteSpace(...)`. Le script
   initial ne pouvait pas être analysé par PowerShell.
2. **`DuplicateFile` non supporté** : sur SFTP, WinSCP a besoin de l'extension
   serveur `copy-data` (OpenSSH ≥ 9.0) ou d'un accès shell ; sinon chaque copie
   échoue. Le script essaie `DuplicateFile` une fois puis, en cas d'échec,
   bascule automatiquement sur téléchargement temporaire + renvoi.
3. **Échec des transferts à cause des horodatages** : `PreserveTimestamp`
   désactivé. Beaucoup de serveurs refusent le `setstat` et WinSCP signale alors
   une erreur alors que le fichier a bien été transféré (ce qui cassait la mise
   à jour du CSV).
4. **Noms de fichiers interprétés comme masques** : `GetFiles`/`PutFiles`
   traitent `[ ] * ?` comme des jokers → chemins échappés avec `EscapeFileMask`.
5. **Collisions de noms** : la cible est à plat, deux fichiers de même nom
   provenant de systèmes/dossiers différents s'écrasaient silencieusement tout en
   étant marqués `COPIE_OK`. Désormais la copie est refusée (erreur explicite,
   retentée au passage suivant) sauf si `$OverwriteExistingTarget = $true`.
6. **Échec de mise à jour du CSV** : n'est plus confondu avec un échec de copie.
7. Divers : `SFTP_PORT` validé, empreinte SSH optionnelle, `List<>` au lieu de
   `+=` sur tableau, exclusion de `.`/`..` via `IsThisDirectory`/`IsParentDirectory`,
   journal WinSCP affiché en cas d'erreur générale, fichiers « déjà copiés » plus
   journalisés un par un (seulement comptés dans le bilan).

## Point d'attention

Le CSV d'historique est écrit **dans le répertoire de sortie**
(`/root/outbound/azure_automation/output`). Si un traitement aval ramasse tous
les fichiers de ce dossier, il ramassera aussi le CSV : dans ce cas, déplacer
`$RemoteCsv` vers un autre dossier.
