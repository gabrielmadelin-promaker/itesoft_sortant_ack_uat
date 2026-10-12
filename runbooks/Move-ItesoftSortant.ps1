<#
.SYNOPSIS
    Distribue les factures ITESOFT sortantes déposées dans le répertoire
    d'entrée vers le répertoire invoices du système TALENTIA concerné, sur le
    même serveur SFTP.

.DESCRIPTION
    Runbook Azure Automation exécuté sur un Hybrid Runbook Worker Windows
    disposant de WinSCP (WinSCPnet.dll).

    Chaque fichier :
        /root/outbound/azure_automation/input/<Numero>_<SYS>_<CompanyCode>_<LegalTaxContext>_<Format>.xml
    est déplacé vers :
        /root/outbound/<SYSTEME>/output/invoices/<CompanyCode>_<LegalTaxContext>_<Format>/<même nom>

    <SYS> est un code à 3 lettres converti en nom de système par la table
    $SystemCodes (BSE -> TALENTIA_BSE...).

    Le nom est lu en partant de la droite : le numéro de facture peut donc
    contenir des "_" ; CompanyCode, LegalTaxContext et Format ne le peuvent pas.

    Un fichier en anomalie (nom non conforme, code système inconnu, répertoire
    invoices absent, fichier cible déjà présent) reste dans input, est signalé
    en erreur et sera retenté au passage suivant.

    Le même script sert aux runbooks itesoft_sortant_uat et
    itesoft_sortant_prod : seul le paramètre Environment change.

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

# <Numero>_<SYS>_<CompanyCode>_<LegalTaxContext>_<Format>.xml
# Le numéro (.+) absorbe les "_" éventuels ; les 4 autres segments n'en contiennent pas.
$FileNamePattern = '^(?<Numero>.+)_(?<Code>[^_]+)_(?<CompanyCode>[^_]+)_(?<LegalTaxContext>[^_]+)_(?<Format>[^_]+)\.xml$'

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

    Write-Output ("{0} [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message)
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
    $Options = New-Object WinSCP.TransferOptions
    $Options.TransferMode = [WinSCP.TransferMode]::Binary

    # Beaucoup de serveurs SFTP refusent la modification de la date ou des
    # droits : WinSCP lève alors une erreur alors que le transfert a réussi.
    $Options.PreserveTimestamp = $false
    $Options.FilePermissions   = $null

    return $Options
}

function Send-LocalFile
{
    # Envoie un fichier local vers un chemin distant (nom de fichier inclus).
    param(
        [Parameter(Mandatory = $true)] $Session,
        [Parameter(Mandatory = $true)] [string]$LocalPath,
        [Parameter(Mandatory = $true)] [string]$RemotePath
    )

    # PutFiles/GetFiles interprètent la source comme un masque : on l'échappe.
    $Session.PutFiles(
        $Session.EscapeFileMask($LocalPath),
        $RemotePath,
        $false,
        (New-TransferOptions)
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

$script:LastMoveMethod = $null

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
            $Message = "Nom non conforme (attendu <Numero>_<SYS>_<CompanyCode>_<LegalTaxContext>_<Format>.xml)"
            Write-Log "$Message, fichier laissé en place : $SourcePath" "ERREUR"
            Write-Event "ITESOFT_ERROR" @{ NomFichier = $FileName; Source = $SourcePath; Message = $Message }
            continue
        }

        $Code   = $Match.Groups["Code"].Value.ToUpperInvariant()
        $Folder = "{0}_{1}_{2}" -f $Match.Groups["CompanyCode"].Value, $Match.Groups["LegalTaxContext"].Value, $Match.Groups["Format"].Value

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
        $TargetPath   = "$TargetFolder/$FileName"

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
                # Le répertoire invoices du système doit exister : on ne crée
                # que le sous-dossier <CompanyCode>_<LegalTaxContext>_<Format>.
                if (-not $Session.FileExists($InvoicesPath))
                {
                    throw "Répertoire invoices absent : $InvoicesPath"
                }

                if (-not $Session.FileExists($TargetFolder))
                {
                    $Session.CreateDirectory($TargetFolder)
                    Write-Log "Répertoire créé : $TargetFolder" "OK"
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
