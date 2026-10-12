# Architecture cible du suivi et de l'alerting ITESOFT

## Périmètre

Deux runbooks, chacun utilisé pour UAT **et** PROD : l'environnement est le
**paramètre** `ENVIRONMENT` (`UAT` / `PROD`) renseigné dans chaque planification.

| Runbook               | Script                       | Flux    | Environnements |
|-----------------------|------------------------------|---------|----------------|
| `itesoft_sortant_ack` | `Move-ItesoftSortantAck.ps1` | ACK     | UAT, PROD      |
| `itesoft_sortant`     | `Move-ItesoftSortant.ps1`    | SORTANT | UAT, PROD      |

Soit **4 combinaisons à surveiller** : ACK-UAT, ACK-PROD, SORTANT-UAT,
SORTANT-PROD. Comme le nom du runbook ne dit plus l'environnement, chaque
ligne de log porte le flux et l'environnement, et l'alerting s'appuie dessus.

```
 Runbooks (worker hybride)               Azure                         Équipe
 ┌───────────────────────────────┐
 │ itesoft_sortant_ack (UAT/PROD)│──┐  sortie des jobs
 │ itesoft_sortant     (UAT/PROD)│──┼─► Paramètre de diagnostic ──► Log Analytics « ITESOFT »
 └───────────────────────────────┘  │   (JobLogs + JobStreams)        │        │
                                                                     │        ├─► Tableau de bord
                                                                     ▼        │
                                                    2 règles d'alerte ──► ag-itesoft (e-mail)
```

## Contrat de journalisation (respecté par les deux scripts)

| Ligne écrite dans la sortie du job | Rôle |
|---|---|
| `AAAA-MM-JJ HH:MM:SS [ERREUR] [<FLUX> <ENV>] <message>` | déclenche l'alerte « Erreurs » |
| `ITESOFT_BILAN {"Flux":"ACK","Env":"PROD","Deplacements":n,"Erreurs":n,...}` | une fois par exécution : sert à détecter une exécution manquante |
| `ITESOFT_MOVE {...}` / `ITESOFT_ERROR {...}` | détail par fichier (tableau de bord) |

Exemple : `2026-10-12 13:51:34 [ERREUR] [SORTANT PROD] Code système inconnu 'XXX' ...`

## Socle Azure

| Élément | Valeur |
|---|---|
| Espace Log Analytics | `ITESOFT` (unique, UAT + PROD) |
| Paramètre de diagnostic | JobLogs + JobStreams → `ITESOFT`, sur le compte `bse-fabric-prod-fr-automation` (déjà en place) |
| Groupe d'actions | `ag-itesoft` (unique, e-mail de l'équipe) |

## Règles d'alerte

Deux règles couvrent les 4 combinaisons. Chacune est **fractionnée par les
dimensions `Flux` et `Env`** : une alerte (et un e-mail) distincte par
combinaison concernée, dont l'objet indique par exemple `Flux = SORTANT, Env = PROD`.

### 1. `ITESOFT - Erreurs` — gravité 2

```kusto
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.AUTOMATION" and Category == "JobStreams"
| where RunbookName_s startswith "itesoft_sortant"
| where ResultDescription has "[ERREUR]"
| extend Flux = extract(@"\[ERREUR\] \[(\w+) (\w+)\]", 1, ResultDescription),
         Env  = extract(@"\[ERREUR\] \[(\w+) (\w+)\]", 2, ResultDescription)
| project TimeGenerated, Flux, Env, Runbook = RunbookName_s, Erreur = ResultDescription
```

| Réglage | Valeur |
|---|---|
| Mesure | Lignes de table — Nombre — **> 0** |
| Fractionner par dimensions | **Flux**, **Env** |
| Granularité / Fréquence | 15 min / 15 min |
| Actions | `ag-itesoft` |

### 2. `ITESOFT - Exécution manquante` — gravité 1

Une combinaison qui ne tourne plus (planification désactivée, worker arrêté,
paramètre `ENVIRONMENT` absent, plantage) ne produit **aucune** ligne : on
compare donc à la liste des combinaisons **attendues**.

```kusto
let attendus = datatable(Flux:string, Env:string)
[
    "ACK",     "UAT",
    "ACK",     "PROD",
    "SORTANT", "UAT",
    "SORTANT", "PROD"
];
let vus = AzureDiagnostics
    | where TimeGenerated > ago(1h)
    | where ResourceProvider == "MICROSOFT.AUTOMATION" and Category == "JobStreams"
    | where ResultDescription startswith "ITESOFT_BILAN "
    | extend d = parse_json(substring(ResultDescription, strlen("ITESOFT_BILAN ")))
    | summarize Executions = count() by Flux = tostring(d.Flux), Env = tostring(d.Env);
attendus
| join kind=leftouter vus on Flux, Env
| where isempty(Executions) or Executions == 0
| project Flux, Env
```

| Réglage | Valeur |
|---|---|
| Mesure | Lignes de table — Nombre — **> 0** |
| Fractionner par dimensions | **Flux**, **Env** |
| Granularité / Fréquence | **1 h** / 15 min |
| Actions | `ag-itesoft` |

- `ago(1h)` doit rester ≥ à l'intervalle de planification le plus long.
- Pour suspendre volontairement une combinaison (ex. UAT arrêtée), la retirer
  de `attendus`, sinon l'alerte se déclenche.

> Si la PROD doit un jour être traitée différemment (gravité, destinataires),
> dupliquer chaque règle en ajoutant `| where Env == "PROD"` / `"UAT"`.

## Tableau de bord

Les lignes `ITESOFT_MOVE` / `ITESOFT_ERROR` / `ITESOFT_BILAN` contiennent
`Flux` et `Env` : il suffit de les extraire du JSON, par exemple

```kusto
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.AUTOMATION" and Category == "JobStreams"
| where ResultDescription startswith "ITESOFT_MOVE "
| extend d = parse_json(substring(ResultDescription, strlen("ITESOFT_MOVE ")))
| where tobool(d.Simulation) == false
| summarize Fichiers = count() by Jour = bin(TimeGenerated, 1d), Flux = tostring(d.Flux), Env = tostring(d.Env)
| render columnchart
```

## Ajouter un environnement ou un flux (checklist)

1. Planification du runbook avec le bon `ENVIRONMENT`, sur le **worker hybride**.
2. Variables SFTP de l'environnement (`SFTP_HOST_<ENV>`, `SFTP_PASSWORD_<ENV>`).
3. Ajouter la combinaison à `attendus` dans la règle « Exécution manquante ».
4. Nouveau script : respecter le contrat de journalisation ci-dessus.
