<#
.SYNOPSIS
    Distribue les factures ITESOFT sortantes déposées dans le répertoire
    d'entrée vers le répertoire invoices du système TALENTIA concerné, sur le
    même serveur SFTP.

.DESCRIPTION
    Runbook Azure Automation exécuté sur un Hybrid Runbook Worker Windows
    disposant de WinSCP (WinSCPnet.dll).

    Chaque fichier :
        /root/outbound/azure_automation/input/<Numero>-<SYS>-<CompanyCode>-<LegalTaxContext>-<Format>.xml
    est déplacé et renommé en :
        /root/outbound/<SYSTEME>/output/invoices/<CompanyCode>_<LegalTaxContext>_<Format>/<Numero>.xml

    Exemple : 400_PTX_0000076993_1790793900222-BSE-T400-FR_B2B-FR_UBL.xml
           -> TALENTIA_BSE/output/invoices/T400_FR_B2B_FR_UBL/400_PTX_0000076993_1790793900222.xml

    <SYS> est un code à 3 lettres converti en nom de système par la table
    $SystemCodes (BSE -> TALENTIA_BSE...).

    Les champs sont séparés par "-". SYS, CompanyCode, LegalTaxContext et
    Format ne contiennent pas de "-" (mais peuvent contenir des "_"). Le nom est
    lu depuis la droite : tout ce qui précède SYS est le numéro de facture.

    Les répertoires cibles manquants (y compris .../output/invoices) sont créés.
    À la création du sous-dossier, un fichier config.json y est déposé :
        {"companyCode":"<CompanyCode>","legalTaxContext":"<LegalTaxContext>","format":"<Format>"}

    Chaque déplacement est ajouté (mode append) au journal CSV
    itesoft_sortant_copies.csv dans le répertoire d'entrée.

    Un fichier en anomalie (nom non conforme, code système inconnu, fichier
    cible déjà présent) reste dans input, est signalé en erreur et sera retenté
    au passage suivant.

    Runbook itesoft_sortant, utilisé pour UAT et PROD : seul le paramètre
    Environment (renseigné dans chaque planification) change.

    Variables Azure Automation attendues (<ENV> = UAT ou PROD) :
        Propres à l'environnement : SFTP_HOST_<ENV>, SFTP_PASSWORD_<ENV> (chiffrée)
        Communes UAT/PROD         : SFTP_USER, SFTP_PORT
    Variable optionnelle :
        SFTP_HOSTKEY_<ENV>  (empreinte SSH, ex. "ssh-ed25519 255 xxxxxxxx...")

.PARAMETER Environment
    UAT ou PROD. Détermine les variables SFTP utilisées.
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("UAT", "PROD")]
    [string]$Environment
)

$ErrorActionPreference = "Stop"

$Environment = $Environment.ToUpperInvariant()
$Flux        = "SORTANT"

# ============================================================
# CONFIGURATION
# ============================================================

# Table de transcodification : code présent dans le nom du fichier -> système.
$SystemCodes = @{
    "BLS" = "TALENTIA_BLUECARSHARING"
    "BLU" = "TALENTIA_BLUEUS"
    "BSE" = "TALENTIA_BSE"
    "ODE" = "TALENTIA_ODET"
    "VIG" = "TALENTIA_VIGNES"
    "MED" = "TALENTIA_MEDIA"
}

$RemoteBase  = "/root/outbound"
$RemoteInput = "/root/outbound/azure_automation/input"

# <Numero>-<SYS>-<CompanyCode>-<LegalTaxContext>-<Format>.xml
# Les 4 derniers champs ne contiennent pas de "-" ; le numéro (.+) prend le reste.
$FileNamePattern = '^(?<Numero>.+)-(?<Code>[^-]+)-(?<CompanyCode>[^-]+)-(?<LegalTaxContext>[^-]+)-(?<Format>[^-]+)\.xml$'

# Fichier déposé dans chaque sous-dossier créé.
$ConfigFileName = "config.json"

# Journal CSV des déplacements (append).
$RemoteCsv  = "$RemoteInput/itesoft_sortant_copies.csv"
$CsvColumns = @("DateHeure", "Systeme", "Dossier", "NomFichier", "Source", "Destination", "TailleOctets", "Statut")

# Seuls les fichiers correspondant à ce masque sont traités
# (insensible à la casse). Les autres restent en place, sans erreur.
$FileMask = "*.xml"

$WinScpDll = "C:\Program Files (x86)\WinSCP\WinSCPnet.dll"

# $false = déplacement réel
# $true  = simulation, aucun déplacement
$Simulation = $false

# Si le fichier cible existe déjà :
# $false = ne pas l'écraser (source laissée en place, erreur, retenté au prochain passage)
# $true  = l'écraser
$OverwriteExistingTarget = $false

# Journal de session WinSCP (très utile pour diagnostiquer).
# Mettre $null pour le désactiver.
$WinScpSessionLog = Join-Path -Path $env:TEMP -ChildPath "itesoft_sortant_$($Environment.ToLowerInvariant())_winscp.log"

# ============================================================
# FONCTIONS
# ============================================================

function Write-Log
{
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet("INFO", "OK", "ATTENTION", "ERREUR")]
        [string]$Level = "INFO"
    )

    # [<Flux> <Env>] permet à l'alerting de savoir d'où vient chaque ligne,
    # le même runbook servant à UAT et à PROD.
    Write-Output ("{0} [{1}] [{2} {3}] {4}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Flux, $Environment, $Message)
}

function Write-Event
{
    # Ligne structurée (préfixe + JSON sur une ligne) destinée à Log Analytics :
    # la sortie du job est envoyée dans AzureDiagnostics (catégorie JobStreams)
    # et analysée par les requêtes de docs/log-analytics.md.
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("ITESOFT_MOVE", "ITESOFT_ERROR", "ITESOFT_BILAN")]
        [string]$Type,

        [Parameter(Mandatory = $true)]
        [hashtable]$Data
    )

    $Data["Env"]        = $Environment
    $Data["Flux"]       = $Flux
    $Data["Simulation"] = $Simulation
    Write-Output ("{0} {1}" -f $Type, ([PSCustomObject]$Data | ConvertTo-Json -Compress))
}

function New-TransferOptions
{
    param([switch]$Append)

    $Options = New-Object WinSCP.TransferOptions
    $Options.TransferMode = [WinSCP.TransferMode]::Binary

    # Beaucoup de serveurs SFTP refusent la modification de la date ou des
    # droits : WinSCP lève alors une erreur alors que le transfert a réussi.
    $Options.PreserveTimestamp = $false
    $Options.FilePermissions   = $null

    if ($Append)
    {
        $Options.OverwriteMode = [WinSCP.OverwriteMode]::Append
    }

    return $Options
}

function Send-LocalFile
{
    # Envoie un fichier local vers un chemin distant (nom de fichier inclus).
    param(
        [Parameter(Mandatory = $true)] $Session,
        [Parameter(Mandatory = $true)] [string]$LocalPath,
        [Parameter(Mandatory = $true)] [string]$RemotePath,
        [switch]$Append
    )

    # PutFiles/GetFiles interprètent la source comme un masque : on l'échappe.
    $Session.PutFiles(
        $Session.EscapeFileMask($LocalPath),
        $RemotePath,
        $false,
        (New-TransferOptions -Append:$Append)
    ).Check()
}

function Receive-RemoteFile
{
    # Télécharge un fichier distant vers un chemin local (nom de fichier inclus).
    param(
        [Parameter(Mandatory = $true)] $Session,
        [Parameter(Mandatory = $true)] [string]$RemotePath,
        [Parameter(Mandatory = $true)] [string]$LocalPath
    )

    $Result = $Session.GetFiles(
        $Session.EscapeFileMask($RemotePath),
        $LocalPath,
        $false,
        (New-TransferOptions)
    )

    $Result.Check()

    if ($Result.Transfers.Count -eq 0)
    {
        throw "Aucun fichier téléchargé depuis $RemotePath."
    }
}

function Remove-RemoteFile
{
    param(
        [Parameter(Mandatory = $true)] $Session,
        [Parameter(Mandatory = $true)] [string]$RemotePath
    )

    $Session.RemoveFiles($Session.EscapeFileMask($RemotePath)).Check()
}

function New-RemoteDirectory
{
    # Crée un répertoire distant et ses parents manquants (comme mkdir -p),
    # sans jamais remonter au-dessus de $Root.
    param(
        [Parameter(Mandatory = $true)] $Session,
        [Parameter(Mandatory = $true)] [string]$Root,
        [Parameter(Mandatory = $true)] [string]$Path
    )

    $Current = $Root.TrimEnd("/")

    foreach ($Segment in $Path.Substring($Current.Length).Trim("/").Split("/"))
    {
        $Current = "$Current/$Segment"

        if (-not $Session.FileExists($Current))
        {
            $Session.CreateDirectory($Current)
            Write-Log "Répertoire créé : $Current" "OK"
        }
    }
}

function Write-RemoteTextFile
{
    # Crée un fichier texte distant (UTF-8 sans BOM, sans saut de ligne final).
    param(
        [Parameter(Mandatory = $true)] $Session,
        [Parameter(Mandatory = $true)] [string]$RemotePath,
        [Parameter(Mandatory = $true)] [string]$Text,
        [Parameter(Mandatory = $true)] [string]$TempDirectory
    )

    $TempFile = Join-Path -Path $TempDirectory -ChildPath ([guid]::NewGuid().ToString("N") + ".tmp")

    try
    {
        [System.IO.File]::WriteAllText($TempFile, $Text, (New-Object System.Text.UTF8Encoding($false)))
        Send-LocalFile -Session $Session -LocalPath $TempFile -RemotePath $RemotePath
    }
    finally
    {
        if (Test-Path -LiteralPath $TempFile)
        {
            Remove-Item -LiteralPath $TempFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function Save-PendingRows
{
    # Ajoute les lignes en attente à la fin du CSV distant (append) :
    # seules les nouvelles lignes transitent, quelle que soit la taille du CSV.
    param(
        [Parameter(Mandatory = $true)] $Session,
        [Parameter(Mandatory = $true)] [string]$RemoteCsv,
        [Parameter(Mandatory = $true)] [string]$TempDirectory
    )

    if ($script:PendingRows.Count -eq 0)
    {
        return
    }

    $LocalCsv = Join-Path -Path $TempDirectory -ChildPath "itesoft_sortant_copies.csv"
    $Lines    = @($script:PendingRows | Select-Object $CsvColumns | ConvertTo-Csv -Delimiter ";" -NoTypeInformation)

    if ($script:RemoteCsvExists)
    {
        # Sans en-tête ni BOM : le contenu est collé à la fin du fichier.
        [System.IO.File]::WriteAllLines($LocalCsv, [string[]]@($Lines | Select-Object -Skip 1), (New-Object System.Text.UTF8Encoding($false)))
        Send-LocalFile -Session $Session -LocalPath $LocalCsv -RemotePath $RemoteCsv -Append
    }
    else
    {
        # Nouveau fichier : en-tête + BOM (lecture correcte des accents dans Excel).
        [System.IO.File]::WriteAllLines($LocalCsv, [string[]]$Lines, (New-Object System.Text.UTF8Encoding($true)))
        Send-LocalFile -Session $Session -LocalPath $LocalCsv -RemotePath $RemoteCsv
        $script:RemoteCsvExists = $true
    }

    $script:PendingRows.Clear()
}

function Move-RemoteFile
{
    # Déplace un fichier sur le même serveur SFTP.
    # 1. Renommage SFTP (instantané, atomique).
    # 2. Repli : téléchargement + envoi + suppression de la source.
    #    Si la suppression échoue, la copie cible est retirée pour ne pas
    #    laisser de doublon.
    # La méthode utilisée est placée dans $script:LastMoveMethod.
    param(
        [Parameter(Mandatory = $true)] $Session,
        [Parameter(Mandatory = $true)] [string]$SourcePath,
        [Parameter(Mandatory = $true)] [string]$TargetPath,
        [Parameter(Mandatory = $true)] [string]$TempDirectory
    )

    try
    {
        $Session.MoveFile($SourcePath, $TargetPath)
        $script:LastMoveMethod = "RENAME"
        return
    }
    catch
    {
        $RenameError = $_.Exception.Message
    }

    # Certains serveurs SFTP renvoient une erreur alors que le renommage a eu
    # lieu, ou la source a été prise par un autre traitement : on vérifie l'état
    # réel avant de tenter le repli.
    $SourceExists = $Session.FileExists($SourcePath)
    $TargetExists = $Session.FileExists($TargetPath)

    if (-not $SourceExists -and $TargetExists)
    {
        $script:LastMoveMethod = "RENAME_CONFIRMED"
        return
    }

    if (-not $SourceExists)
    {
        throw "Renommage refusé ($RenameError) et fichier source disparu sans arriver à destination : vérifier qu'aucun autre traitement ne consomme ce répertoire."
    }

    $TempFile = Join-Path -Path $TempDirectory -ChildPath ([guid]::NewGuid().ToString("N") + ".tmp")

    try
    {
        Receive-RemoteFile -Session $Session -RemotePath $SourcePath -LocalPath $TempFile
        Send-LocalFile     -Session $Session -LocalPath $TempFile   -RemotePath $TargetPath

        try
        {
            Remove-RemoteFile -Session $Session -RemotePath $SourcePath
        }
        catch
        {
            $DeleteError = $_.Exception.Message
            Remove-RemoteFile -Session $Session -RemotePath $TargetPath
            throw "Suppression de la source impossible ($DeleteError), copie cible retirée."
        }
    }
    catch
    {
        throw "Renommage refusé ($RenameError) puis repli en échec : $($_.Exception.Message)"
    }
    finally
    {
        if (Test-Path -LiteralPath $TempFile)
        {
            Remove-Item -LiteralPath $TempFile -Force -ErrorAction SilentlyContinue
        }
    }

    $script:LastMoveMethod = "GET_PUT_DELETE"
}

# ============================================================
# INITIALISATION
# ============================================================

$Session       = $null
$WorkDirectory = Join-Path -Path $env:TEMP -ChildPath ("itesoft_sortant_" + [guid]::NewGuid().ToString("N"))

$MovedCount = 0
$ErrorCount = 0

$script:LastMoveMethod  = $null
$script:PendingRows     = New-Object System.Collections.Generic.List[object]
$script:RemoteCsvExists = $false

try
{
    Write-Log "Début du Runbook $Flux $Environment sur la machine $env:COMPUTERNAME."
    Write-Log "PowerShell $($PSVersionTable.PSVersion) - Mode simulation : $Simulation."

    New-Item -ItemType Directory -Path $WorkDirectory -Force | Out-Null

    # --------------------------------------------------------
    # WinSCP
    # --------------------------------------------------------

    if (-not (Test-Path -LiteralPath $WinScpDll))
    {
        throw "Bibliothèque WinSCP introuvable : $WinScpDll"
    }

    Add-Type -Path $WinScpDll
    Write-Log "WinSCP .NET assembly version $((Get-Item -LiteralPath $WinScpDll).VersionInfo.FileVersion)."

    # --------------------------------------------------------
    # Variables Azure Automation
    # --------------------------------------------------------

    # Hôte, mot de passe et empreinte : propres à l'environnement
    # (SFTP_HOST_UAT, SFTP_HOST_PROD...). Utilisateur et port : communs.
    $VarHost     = "SFTP_HOST_$Environment"
    $VarPort     = "SFTP_PORT"
    $VarUser     = "SFTP_USER"
    $VarPassword = "SFTP_PASSWORD_$Environment"
    $VarHostKey  = "SFTP_HOSTKEY_$Environment"

    $Required = [ordered]@{}

    foreach ($Name in @($VarHost, $VarPort, $VarUser, $VarPassword))
    {
        try
        {
            $Required[$Name] = [string](Get-AutomationVariable -Name $Name)
        }
        catch
        {
            throw "La variable Azure Automation $Name est introuvable : $($_.Exception.Message)"
        }

        if ([string]::IsNullOrWhiteSpace($Required[$Name]))
        {
            throw "La variable $Name est vide."
        }
    }

    $SftpHost     = $Required[$VarHost]
    $SftpPort     = $Required[$VarPort]
    $SftpUser     = $Required[$VarUser]
    $SftpPassword = $Required[$VarPassword]

    $SftpHostKey = $null
    try
    {
        $SftpHostKey = [string](Get-AutomationVariable -Name $VarHostKey)
    }
    catch
    {
        # Variable optionnelle.
    }

    $PortNumber = 0
    if (-not [int]::TryParse($SftpPort.Trim(), [ref]$PortNumber))
    {
        throw "La variable $VarPort n'est pas un nombre : '$SftpPort'."
    }

    # --------------------------------------------------------
    # Connexion SFTP
    # --------------------------------------------------------

    $SessionOptions = New-Object WinSCP.SessionOptions

    $SessionOptions.Protocol   = [WinSCP.Protocol]::Sftp
    $SessionOptions.HostName   = $SftpHost.Trim()
    $SessionOptions.PortNumber = $PortNumber
    $SessionOptions.UserName   = $SftpUser.Trim()
    $SessionOptions.Password   = $SftpPassword

    if (-not [string]::IsNullOrWhiteSpace($SftpHostKey))
    {
        $SessionOptions.SshHostKeyFingerprint = $SftpHostKey.Trim()
    }
    else
    {
        # Même comportement que -hostkey=*
        $SessionOptions.GiveUpSecurityAndAcceptAnySshHostKey = $true
        Write-Log "$VarHostKey non définie : toutes les clés d'hôte SSH sont acceptées." "ATTENTION"
    }

    $Session = New-Object WinSCP.Session

    if ($WinScpSessionLog)
    {
        $Session.SessionLogPath = $WinScpSessionLog
        Write-Log "Journal de session WinSCP : $WinScpSessionLog"
    }

    $Session.Open($SessionOptions)
    Write-Log "Connexion SFTP réussie vers $SftpHost sur le port $PortNumber." "OK"

    # --------------------------------------------------------
    # Lecture du répertoire d'entrée
    # --------------------------------------------------------

    if (-not $Session.FileExists($RemoteInput))
    {
        throw "Le répertoire d'entrée n'existe pas : $RemoteInput"
    }

    $Files = @(
        $Session.ListDirectory($RemoteInput).Files |
        Where-Object { -not $_.IsDirectory -and $_.Name -like $FileMask } |
        Sort-Object Name
    )

    Write-Log "$($Files.Count) fichier(s) $FileMask dans $RemoteInput."

    $script:RemoteCsvExists = $Session.FileExists($RemoteCsv)

    # Répertoires cibles déjà vérifiés ou créés pendant ce passage.
    $KnownFolders = @{}

    foreach ($File in $Files)
    {
        $FileName   = $File.Name
        $SourcePath = "$RemoteInput/$FileName"

        # ----------------------------------------------------
        # Analyse du nom de fichier
        # ----------------------------------------------------

        $Match = [regex]::Match($FileName, $FileNamePattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

        if (-not $Match.Success)
        {
            $ErrorCount++
            $Message = "Nom non conforme (attendu <Numero>-<SYS>-<CompanyCode>-<LegalTaxContext>-<Format>.xml)"
            Write-Log "$Message, fichier laissé en place : $SourcePath" "ERREUR"
            Write-Event "ITESOFT_ERROR" @{ NomFichier = $FileName; Source = $SourcePath; Message = $Message }
            continue
        }

        $Code   = $Match.Groups["Code"].Value.ToUpperInvariant()
        $CompanyCode     = $Match.Groups["CompanyCode"].Value
        $LegalTaxContext = $Match.Groups["LegalTaxContext"].Value
        $Format          = $Match.Groups["Format"].Value
        $Folder          = "{0}_{1}_{2}" -f $CompanyCode, $LegalTaxContext, $Format

        if (-not $SystemCodes.ContainsKey($Code))
        {
            $ErrorCount++
            $Message = "Code système inconnu '$Code' (codes connus : $(($SystemCodes.Keys | Sort-Object) -join ', '))"
            Write-Log "$Message, fichier laissé en place : $SourcePath" "ERREUR"
            Write-Event "ITESOFT_ERROR" @{ CodeSysteme = $Code; NomFichier = $FileName; Source = $SourcePath; Message = $Message }
            continue
        }

        $System       = $SystemCodes[$Code]
        $InvoicesPath = "$RemoteBase/$System/output/invoices"
        $TargetFolder = "$InvoicesPath/$Folder"
        $TargetPath   = "$TargetFolder/$($Match.Groups["Numero"].Value).xml"

        if ($Simulation)
        {
            Write-Log "SIMULATION : $SourcePath -> $TargetPath"
            continue
        }

        try
        {
            # ------------------------------------------------
            # Répertoire cible
            # ------------------------------------------------

            if (-not $KnownFolders.ContainsKey($TargetFolder))
            {
                if (-not $Session.FileExists($TargetFolder))
                {
                    # Crée .../<SYSTEME>/output/invoices/<sous-dossier>.
                    New-RemoteDirectory -Session $Session -Root $RemoteBase -Path $TargetFolder

                    # config.json du nouveau sous-dossier. En cas d'échec, le
                    # sous-dossier est retiré pour être recréé complet au
                    # passage suivant.
                    $ConfigPath = "$TargetFolder/$ConfigFileName"
                    $ConfigJson = [ordered]@{
                        companyCode     = $CompanyCode
                        legalTaxContext = $LegalTaxContext
                        format          = $Format
                    } | ConvertTo-Json -Compress

                    try
                    {
                        Write-RemoteTextFile -Session $Session -RemotePath $ConfigPath -Text $ConfigJson -TempDirectory $WorkDirectory
                        Write-Log "Fichier créé : $ConfigPath $ConfigJson" "OK"
                    }
                    catch
                    {
                        $ConfigError = $_.Exception.Message
                        Remove-RemoteFile -Session $Session -RemotePath $TargetFolder
                        throw "Création de $ConfigPath impossible ($ConfigError), sous-dossier retiré."
                    }
                }

                $KnownFolders[$TargetFolder] = $true
            }

            # ------------------------------------------------
            # Fichier cible déjà présent
            # ------------------------------------------------

            if ($Session.FileExists($TargetPath))
            {
                if (-not $OverwriteExistingTarget)
                {
                    throw "Fichier cible déjà existant : $TargetPath"
                }

                Remove-RemoteFile -Session $Session -RemotePath $TargetPath
            }

            Move-RemoteFile `
                -Session $Session `
                -SourcePath $SourcePath `
                -TargetPath $TargetPath `
                -TempDirectory $WorkDirectory
        }
        catch
        {
            $ErrorCount++
            Write-Log "Échec du déplacement de $SourcePath : $($_.Exception.Message)" "ERREUR"
            Write-Event "ITESOFT_ERROR" @{ Systeme = $System; CodeSysteme = $Code; Dossier = $Folder; NomFichier = $FileName; Source = $SourcePath; Destination = $TargetPath; Message = $_.Exception.Message }
            continue
        }

        $MovedCount++

        Write-Log "Déplacé ($script:LastMoveMethod) : $SourcePath -> $TargetPath" "OK"
        Write-Event "ITESOFT_MOVE" @{ Systeme = $System; CodeSysteme = $Code; Dossier = $Folder; NomFichier = $FileName; Source = $SourcePath; Destination = $TargetPath; TailleOctets = $File.Length; Methode = $script:LastMoveMethod }

        $script:PendingRows.Add([PSCustomObject]@{
            DateHeure    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            Systeme      = $System
            Dossier      = $Folder
            NomFichier   = $FileName
            Source       = $SourcePath
            Destination  = $TargetPath
            TailleOctets = $File.Length
            Statut       = "DEPLACEMENT_OK"
        })
    }
}
catch
{
    $ErrorCount++
    Write-Log "Erreur générale : $($_.Exception.Message)" "ERREUR"

    if ($WinScpSessionLog -and (Test-Path -LiteralPath $WinScpSessionLog))
    {
        Write-Log "Dernières lignes du journal WinSCP :"
        Get-Content -LiteralPath $WinScpSessionLog -Tail 30 | ForEach-Object { Write-Output "    $_" }
    }

    throw
}
finally
{
    # Journal CSV : envoi des lignes en fin de traitement (même après une erreur).
    if ($script:PendingRows.Count -gt 0)
    {
        try
        {
            if ($null -eq $Session -or -not $Session.Opened)
            {
                throw "session SFTP fermée"
            }

            Save-PendingRows -Session $Session -RemoteCsv $RemoteCsv -TempDirectory $WorkDirectory
        }
        catch
        {
            $ErrorCount++
            Write-Log "Lignes non enregistrées dans le CSV ($($_.Exception.Message)) :" "ERREUR"
            $script:PendingRows | Select-Object $CsvColumns | ConvertTo-Csv -Delimiter ";" -NoTypeInformation | ForEach-Object { Write-Output "    $_" }
        }
    }

    if ($null -ne $Session)
    {
        try
        {
            $Session.Dispose()
            Write-Log "Session SFTP fermée."
        }
        catch
        {
            Write-Log "Erreur lors de la fermeture de la session : $($_.Exception.Message)" "ATTENTION"
        }
    }

    if (Test-Path -LiteralPath $WorkDirectory)
    {
        Remove-Item -LiteralPath $WorkDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Log "Bilan : $MovedCount déplacement(s), $ErrorCount erreur(s)."
    Write-Event "ITESOFT_BILAN" @{ Machine = $env:COMPUTERNAME; Deplacements = $MovedCount; Erreurs = $ErrorCount }

    if ($ErrorCount -gt 0)
    {
        Write-Log "Le traitement s'est terminé avec une ou plusieurs erreurs." "ATTENTION"
    }
    else
    {
        Write-Log "Fin du traitement sans erreur." "OK"
    }
}
