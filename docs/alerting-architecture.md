# Architecture cible du suivi et de l'alerting ITESOFT

## Périmètre

| Runbook                    | Flux    | Env  | Script                         |
|----------------------------|---------|------|--------------------------------|
| `itesoft_sortant_ack_uat`  | ACK     | UAT  | `Move-ItesoftSortantAck.ps1`   |
| `itesoft_sortant_ack_prod` | ACK     | PROD | `Move-ItesoftSortantAck.ps1`   |
| `itesoft_sortant_uat`      | SORTANT | UAT  | script dédié (logique différente) |
| `itesoft_sortant_prod`     | SORTANT | PROD | script dédié (logique différente) |

Les deux scripts sont différents ; ce qui les relie, c'est un **contrat de
journalisation commun** (ci-dessous). Les alertes et le tableau de bord ne
dépendent que de ce contrat : ils couvrent les 4 runbooks sans être dupliqués.

```
 Runbooks (worker hybride)          Azure                         Équipe
 ┌────────────────────────┐
 │ itesoft_sortant_ack_*  │──┐  sortie des jobs
 │ itesoft_sortant_*      │──┼─► Paramètre de diagnostic ──► Log Analytics « ITESOFT »
 └────────────────────────┘  │   (JobLogs + JobStreams)        │        │
                             │                                 │        ├─► Tableau de bord
                (1 par compte Automation)                       │        │
                                                               ▼        │
                                              2 règles d'alerte ──► ag-itesoft (e-mail)
```

## Contrat de journalisation (obligatoire pour chaque script)

Chaque script écrit dans la sortie du job (`Write-Output`) :

| Ligne | Quand | Obligatoire |
|---|---|---|
| `AAAA-MM-JJ HH:MM:SS [ERREUR] <message>` | à chaque erreur, quelle qu'elle soit | **oui** — déclenche l'alerte « Erreurs » |
| `ITESOFT_BILAN {"Deplacements":n,"Erreurs":n,"Simulation":false,...}` | une fois, en fin d'exécution (bloc `finally`) | **oui** — sert à détecter un runbook arrêté |
| `ITESOFT_ERROR {...}` | erreur sur un fichier précis | recommandé (détail par fichier) |
| `ITESOFT_MOVE {...}` / autres `ITESOFT_<TYPE> {...}` | événement métier propre au flux | libre |

Les fonctions `Write-Log` et `Write-Event` de `Move-ItesoftSortantAck.ps1`
peuvent être reprises telles quelles dans le script du flux SORTANT.

L'environnement et le flux sont déduits du **nom du runbook** (colonne
`RunbookName_s`), d'où la convention de nommage `itesoft_sortant[_ack]_<uat|prod>`
à respecter strictement.

## Socle Azure

| Élément | Valeur | Remarque |
|---|---|---|
| Espace Log Analytics | `ITESOFT` (unique, UAT + PROD) | rétention à ajuster (30 j par défaut) |
| Paramètre de diagnostic | JobLogs + JobStreams → `ITESOFT` | **un par compte Automation** : si UAT et PROD sont dans deux comptes, le créer sur les deux |
| Groupe d'actions | `ag-itesoft` | unique, e-mail de l'équipe |

## Règles d'alerte

Deux règles, chacune couvrant les 4 runbooks, **fractionnées par la dimension
`Runbook`** : une alerte distincte (et un e-mail distinct) par runbook concerné,
avec son nom et son environnement. Ajouter un runbook ne demande pas de
nouvelle règle.

### 1. `ITESOFT - Erreurs` — gravité 2

```kusto
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.AUTOMATION" and Category == "JobStreams"
| where RunbookName_s startswith "itesoft_sortant"
| where ResultDescription has "[ERREUR]"
| extend Env  = toupper(extract(@"_(uat|prod)$", 1, RunbookName_s)),
         Flux = iff(RunbookName_s has "_ack_", "ACK", "SORTANT")
| project TimeGenerated, Runbook = RunbookName_s, Env, Flux, Erreur = ResultDescription
```

- Mesure : **Lignes de table** — Nombre — **> 0**
- Fractionner par dimensions : **Runbook** (et éventuellement Env)
- Granularité 15 min — Fréquence 15 min
- Actions : `ag-itesoft`

### 2. `ITESOFT - Runbook arrêté` — gravité 1

Un runbook qui ne tourne plus ne produit **aucune** ligne : on compare donc à la
liste des runbooks **attendus** (à tenir à jour, et à vider d'un runbook UAT
volontairement arrêté pour éviter les fausses alertes).

```kusto
let attendus = datatable(Runbook:string)
[
    "itesoft_sortant_ack_uat",
    "itesoft_sortant_ack_prod",
    "itesoft_sortant_uat",
    "itesoft_sortant_prod"
];
let vus = AzureDiagnostics
    | where TimeGenerated > ago(1h)
    | where ResourceProvider == "MICROSOFT.AUTOMATION" and Category == "JobStreams"
    | where ResultDescription startswith "ITESOFT_BILAN "
    | summarize Executions = count() by Runbook = RunbookName_s;
attendus
| join kind=leftouter vus on Runbook
| where isempty(Executions) or Executions == 0
| extend Env = toupper(extract(@"_(uat|prod)$", 1, Runbook))
| project Runbook, Env
```

- Mesure : **Lignes de table** — Nombre — **> 0**
- Fractionner par dimensions : **Runbook**
- Granularité **1 h** — Fréquence 15 min (`ago(1h)` doit rester ≥ à
  l'intervalle de planification le plus long des 4 runbooks)
- Actions : `ag-itesoft`

> Si un jour la PROD doit être traitée différemment (gravité, destinataires),
> il suffira de dupliquer chaque règle en ajoutant `| where Env == "PROD"` /
> `"UAT"`.

## Tableau de bord

Les requêtes de [`log-analytics.md`](log-analytics.md) deviennent multi-runbooks
en remplaçant le filtre de type d'événement par :

```kusto
| where RunbookName_s startswith "itesoft_sortant"
| extend Env  = toupper(extract(@"_(uat|prod)$", 1, RunbookName_s)),
         Flux = iff(RunbookName_s has "_ack_", "ACK", "SORTANT")
```

puis en ajoutant `Env` et `Flux` aux colonnes / au `summarize`. Tuiles
conseillées : erreurs (7 j) par runbook, bilan de la dernière exécution de
chaque runbook, volume par jour × flux × env.

## Mise en place d'un nouveau runbook (checklist)

1. Nommer le runbook selon la convention `itesoft_sortant[_ack]_<uat|prod>`.
2. Vérifier que le script respecte le contrat (`[ERREUR]`, `ITESOFT_BILAN`).
3. Publier, planifier sur le **worker hybride**.
4. Vérifier que son compte Automation a le paramètre de diagnostic vers `ITESOFT`.
5. L'ajouter à la liste `attendus` de la règle « Runbook arrêté ».
