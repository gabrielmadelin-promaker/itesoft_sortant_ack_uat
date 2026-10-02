# Suivi des déplacements dans Log Analytics

Le runbook écrit, en plus de ses logs lisibles, une ligne structurée par
événement dans la sortie du job :

```
ITESOFT_MOVE  {"Systeme":"TALENTIA_BSE","Dossier":"F1","NomFichier":"a.xml","Source":"...","Destination":"...","TailleOctets":1234,"Methode":"RENAME","Simulation":false}
ITESOFT_ERROR {"Systeme":"...","Dossier":"...","NomFichier":"...","Source":"...","Destination":"...","Message":"...","Simulation":false}
ITESOFT_BILAN {"Machine":"SRV-HW01","Deplacements":12,"Erreurs":0,"Simulation":false}
```

Il suffit d'envoyer la sortie des jobs vers un espace Log Analytics pour pouvoir
interroger, partager et alerter dessus. **Aucune permission Entra ID, aucun
secret, aucune ouverture réseau supplémentaire** : c'est Azure Automation qui
transmet les flux des jobs, y compris ceux exécutés sur le worker hybride.

## 1. Mise en place (une seule fois)

1. **Espace Log Analytics** : en utiliser un existant ou en créer un
   (portail Azure → *Log Analytics workspaces* → *Créer*).
2. **Paramètre de diagnostic** sur le compte Automation :
   portail → compte Automation → *Surveillance* → *Paramètres de diagnostic* →
   *Ajouter un paramètre de diagnostic* :
   - cocher **JobLogs** et **JobStreams** ;
   - cocher *Envoyer à l'espace de travail Log Analytics* et choisir l'espace ;
   - enregistrer.
3. Lancer le runbook une fois. Les données arrivent en général sous 5 à 15
   minutes dans la table `AzureDiagnostics`.

> Rétention : 30 jours par défaut, réglable sur l'espace (jusqu'à 2 ans en
> interactif, plus en archive). Le CSV sur le SFTP reste l'historique complet.

## 2. Requêtes

À coller dans *Log Analytics workspaces* → l'espace → *Journaux*.

### Fichiers déplacés

```kusto
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.AUTOMATION" and Category == "JobStreams"
| where ResultDescription startswith "ITESOFT_MOVE "
| extend d = parse_json(substring(ResultDescription, strlen("ITESOFT_MOVE ")))
| where tobool(d.Simulation) == false
| project
    TimeGenerated,
    Systeme      = tostring(d.Systeme),
    Dossier      = tostring(d.Dossier),
    Fichier      = tostring(d.NomFichier),
    TailleOctets = tolong(d.TailleOctets),
    Methode      = tostring(d.Methode),
    Source       = tostring(d.Source),
    Destination  = tostring(d.Destination),
    JobId        = JobId_g
| order by TimeGenerated desc
```

### Erreurs

```kusto
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.AUTOMATION" and Category == "JobStreams"
| where ResultDescription startswith "ITESOFT_ERROR "
| extend d = parse_json(substring(ResultDescription, strlen("ITESOFT_ERROR ")))
| project
    TimeGenerated,
    Systeme = tostring(d.Systeme),
    Dossier = tostring(d.Dossier),
    Fichier = tostring(d.NomFichier),
    Message = tostring(d.Message),
    Source  = tostring(d.Source),
    JobId   = JobId_g
| order by TimeGenerated desc
```

### Volume par jour et par système

```kusto
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.AUTOMATION" and Category == "JobStreams"
| where ResultDescription startswith "ITESOFT_MOVE "
| extend d = parse_json(substring(ResultDescription, strlen("ITESOFT_MOVE ")))
| where tobool(d.Simulation) == false
| summarize Fichiers = count() by Jour = bin(TimeGenerated, 1d), Systeme = tostring(d.Systeme)
| order by Jour desc, Systeme asc
```

### Bilan de chaque exécution

```kusto
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.AUTOMATION" and Category == "JobStreams"
| where ResultDescription startswith "ITESOFT_BILAN "
| extend d = parse_json(substring(ResultDescription, strlen("ITESOFT_BILAN ")))
| project
    TimeGenerated,
    Machine      = tostring(d.Machine),
    Deplacements = toint(d.Deplacements),
    Erreurs      = toint(d.Erreurs),
    Simulation   = tobool(d.Simulation),
    JobId        = JobId_g
| order by TimeGenerated desc
```

### Jobs en échec (plantage complet du runbook)

```kusto
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.AUTOMATION" and Category == "JobLogs"
// Remplacer par le nom du runbook tel qu'il apparaît dans Azure Automation
| where RunbookName_s == "NOM_DU_RUNBOOK"
| where ResultType in ("Failed", "Suspended", "Stopped")
| project TimeGenerated, ResultType, JobId = JobId_g
| order by TimeGenerated desc
```

## 3. Partager

- **Tableau de bord** : depuis le résultat d'une requête, *Épingler au tableau
  de bord* (ou créer un *Workbook* avec les requêtes ci-dessus), puis
  *Partager*.
- **Droits** : donner aux personnes le rôle **Log Analytics Reader** sur l'espace
  (ou seulement sur le tableau de bord / workbook et l'espace).
- **Excel** : dans *Journaux*, *Exporter* → *Exporter vers Excel* ; le fichier
  peut être actualisé depuis Excel (requête Power Query).

## 4. Alerte (optionnel)

Portail → l'espace → *Alertes* → *Créer une règle d'alerte* →
*Recherche personnalisée dans les journaux* avec la requête **Erreurs**
ci-dessus, condition « nombre de résultats > 0 », fréquence 1 h, et un groupe
d'actions qui envoie un e-mail (ou un message Teams).
