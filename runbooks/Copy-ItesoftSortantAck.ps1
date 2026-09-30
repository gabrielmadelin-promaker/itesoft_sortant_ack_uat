<#
.SYNOPSIS
    Copie les fichiers ITESOFT sortants (ACK) des systèmes TALENTIA vers un
    répertoire de sortie unique, sur le même serveur SFTP.

.DESCRIPTION
    Runbook Azure Automation exécuté sur un Hybrid Runbook Worker Windows
    disposant de WinSCP (WinSCPnet.dll).

    Pour chaque système :
        /root/outbound/<SYSTEME>/output/invoices/<SOUS-DOSSIER>/<FICHIER>
    est copié vers :
        /root/outbound/azure_automation/output/<FICHIER>

    Un CSV d'historique (itesoft_sortant_ack_copies.csv) est tenu à jour sur
    le SFTP : un fichier déjà présent avec le statut COPIE_OK n'est jamais
    recopié.

    Variables Azure Automation attendues :
        SFTP_HOST, SFTP_PORT, SFTP_USER, SFTP_PASSWORD (chiffrée)
    Variable optionnelle :
        SFTP_HOSTKEY  (empreinte SSH, ex. "ssh-ed25519 255 xxxxxxxx...")
#>

$ErrorActionPreference = "Stop"

# ============================================================
# CONFIGURATION
# ============================================================

$Systems = @(
    "TALENTIA_BLUECARSHARING",
    "TALENTIA_BLUEUS",
    "TALENTIA_BSE",
    "TALENTIA_ODET",
    "TALENTIA_POLYCEA",
    "TALENTIA_VIGNES",
    "TALENTIA_MEDIA"
)

$RemoteBase   = "/root/outbound"
$RemoteTarget = "/root/outbound/azure_automation/output"
$RemoteCsv    = "$RemoteTarget/itesoft_sortant_ack_copies.csv"

$WinScpDll = "C:\Program Files (x86)\WinSCP\WinSCPnet.dll"

# $false = copie réelle
# $true  = simulation, aucune copie
$Simulation = $false

# Si le fichier cible existe déjà dans $RemoteTarget :
# $false = ne pas l'écraser (fichier en erreur, retenté au prochain passage)
# $true  = l'écraser
$OverwriteExistingTarget = $false

# Journal de session WinSCP (très utile pour diagnostiquer).
# Mettre $null pour le désactiver.
$WinScpSessionLog = Join-Path -Path $env:TEMP -ChildPath "itesoft_sortant_ack_winscp.log"

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

    $Line = "{0} [{1}] {2}" -f `
        (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), `
        $Level, `
        $Message

    Write-Output $Line
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

    # PutFiles interprète la source comme un masque : on l'échappe.
    $Result = $Session.PutFiles(
        $Session.EscapeFileMask($LocalPath),
        $RemotePath,
        $false,
        (New-TransferOptions)
    )

    $Result.Check()
}

function Receive-RemoteFile
{
    # Télécharge un fichier distant vers un chemin local (nom de fichier inclus).
    param(
        [Parameter(Mandatory = $true)] $Session,
        [Parameter(Mandatory = $true)] [string]$RemotePath,
        [Parameter(Mandatory = $true)] [string]$LocalPath
    )

    # GetFiles interprète la source comme un masque : on l'échappe
    # (noms de fichiers contenant [ ] * ?).
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

function Copy-RemoteFile
{
    # Copie un fichier sur le même serveur SFTP.
    # 1. Session.DuplicateFile (copie côté serveur, nécessite l'extension
    #    SFTP "copy-data" ou un accès shell, et WinSCP >= 5.19).
    # 2. Repli : téléchargement dans un fichier temporaire local puis envoi.
    # Retourne la méthode utilisée.
    param(
        [Parameter(Mandatory = $true)] $Session,
        [Parameter(Mandatory = $true)] [string]$SourcePath,
        [Parameter(Mandatory = $true)] [string]$TargetPath,
        [Parameter(Mandatory = $true)] [string]$TempDirectory
    )

    if ($script:UseDuplicateFile)
    {
        try
        {
            $Session.DuplicateFile($SourcePath, $TargetPath)
            return "DUPLICATE"
        }
        catch
        {
            # Inutile de retenter DuplicateFile pour les fichiers suivants.
            $script:UseDuplicateFile = $false

            $script:PendingWarnings.Add(
                "DuplicateFile indisponible ($($_.Exception.Message)). " +
                "Repli sur téléchargement/envoi pour la suite du traitement."
            )
        }
    }

    $TempFile = Join-Path `
        -Path $TempDirectory `
        -ChildPath ([guid]::NewGuid().ToString("N") + ".tmp")

    try
    {
        Receive-RemoteFile -Session $Session -RemotePath $SourcePath -LocalPath $TempFile
        Send-LocalFile     -Session $Session -LocalPath $TempFile   -RemotePath $TargetPath
    }
    finally
    {
        if (Test-Path -LiteralPath $TempFile)
        {
            Remove-Item -LiteralPath $TempFile -Force -ErrorAction SilentlyContinue
        }
    }

    return "GET_PUT"
}

function Save-History
{
    # Écrit le CSV local puis l'envoie sur le SFTP.
    param(
        [Parameter(Mandatory = $true)] $Session,
        [Parameter(Mandatory = $true)] $Rows,
        [Parameter(Mandatory = $true)] [string]$LocalCsv,
        [Parameter(Mandatory = $true)] [string]$RemoteCsv
    )

    $Rows |
        Select-Object DateHeure, Systeme, Dossier, NomFichier, Source, Destination, TailleOctets, Statut |
        Export-Csv `
            -LiteralPath $LocalCsv `
            -Delimiter ";" `
            -NoTypeInformation `
            -Encoding UTF8

    Send-LocalFile -Session $Session -LocalPath $LocalCsv -RemotePath $RemoteCsv
}

function Get-HistoryKey
{
    param(
        [string]$System,
        [string]$Folder,
        [string]$FileName
    )

    return ("{0}|{1}|{2}" -f $System, $Folder, $FileName).ToLowerInvariant()
}

# ============================================================
# INITIALISATION
# ============================================================

$Session = $null

$Guid = [guid]::NewGuid().ToString("N")

$WorkDirectory = Join-Path -Path $env:TEMP -ChildPath "itesoft_sortant_ack_$Guid"
$LocalCsv      = Join-Path -Path $WorkDirectory -ChildPath "itesoft_sortant_ack_copies.csv"

$CopiedCount  = 0
$SkippedCount = 0
$ErrorCount   = 0

$script:UseDuplicateFile = $true
$script:PendingWarnings  = New-Object System.Collections.Generic.List[string]

try
{
    Write-Log "Début du Runbook sur la machine $env:COMPUTERNAME."
    Write-Log "PowerShell $($PSVersionTable.PSVersion) - Mode simulation : $Simulation."

    New-Item -ItemType Directory -Path $WorkDirectory -Force | Out-Null

    # --------------------------------------------------------
    # Vérification de WinSCP
    # --------------------------------------------------------

    if (-not (Test-Path -LiteralPath $WinScpDll))
    {
        throw "Bibliothèque WinSCP introuvable : $WinScpDll"
    }

    Add-Type -Path $WinScpDll

    $WinScpVersion = (Get-Item -LiteralPath $WinScpDll).VersionInfo.FileVersion
    Write-Log "WinSCP .NET assembly version $WinScpVersion."

    if (-not ([WinSCP.Session].GetMethods().Name -contains "DuplicateFile"))
    {
        Write-Log `
            "Cette version de WinSCP ne propose pas DuplicateFile : copie par téléchargement/envoi." `
            "ATTENTION"

        $script:UseDuplicateFile = $false
    }

    # --------------------------------------------------------
    # Lecture des variables Azure Automation
    # --------------------------------------------------------

    $SftpHost     = [string](Get-AutomationVariable -Name "SFTP_HOST")
    $SftpPort     = [string](Get-AutomationVariable -Name "SFTP_PORT")
    $SftpUser     = [string](Get-AutomationVariable -Name "SFTP_USER")
    $SftpPassword = [string](Get-AutomationVariable -Name "SFTP_PASSWORD")

    $SftpHostKey = $null
    try
    {
        $SftpHostKey = [string](Get-AutomationVariable -Name "SFTP_HOSTKEY")
    }
    catch
    {
        # Variable optionnelle.
    }

    foreach ($Variable in @(
        @{ Name = "SFTP_HOST";     Value = $SftpHost },
        @{ Name = "SFTP_PORT";     Value = $SftpPort },
        @{ Name = "SFTP_USER";     Value = $SftpUser },
        @{ Name = "SFTP_PASSWORD"; Value = $SftpPassword }
    ))
    {
        if ([string]::IsNullOrWhiteSpace($Variable.Value))
        {
            throw "La variable $($Variable.Name) est vide."
        }
    }

    $PortNumber = 0
    if (-not [int]::TryParse($SftpPort.Trim(), [ref]$PortNumber))
    {
        throw "La variable SFTP_PORT n'est pas un nombre : '$SftpPort'."
    }

    # --------------------------------------------------------
    # Paramètres de connexion SFTP
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
        # À remplacer en production par la variable SFTP_HOSTKEY.
        $SessionOptions.GiveUpSecurityAndAcceptAnySshHostKey = $true

        Write-Log `
            "SFTP_HOSTKEY non définie : toutes les clés d'hôte SSH sont acceptées." `
            "ATTENTION"
    }

    # --------------------------------------------------------
    # Ouverture de la session
    # --------------------------------------------------------

    $Session = New-Object WinSCP.Session

    if ($WinScpSessionLog)
    {
        $Session.SessionLogPath = $WinScpSessionLog
        Write-Log "Journal de session WinSCP : $WinScpSessionLog"
    }

    $Session.Open($SessionOptions)

    Write-Log `
        "Connexion SFTP réussie vers $SftpHost sur le port $PortNumber." `
        "OK"

    # --------------------------------------------------------
    # Vérification du dossier cible
    # --------------------------------------------------------

    if (-not $Session.FileExists($RemoteTarget))
    {
        throw "Le répertoire cible n'existe pas : $RemoteTarget"
    }

    # Noms des fichiers déjà présents dans la cible
    # (pour détecter les collisions de noms entre systèmes/dossiers).
    $TargetNames = @{}
    foreach ($TargetFile in $Session.ListDirectory($RemoteTarget).Files)
    {
        if (-not $TargetFile.IsDirectory)
        {
            $TargetNames[$TargetFile.Name.ToLowerInvariant()] = $true
        }
    }

    # --------------------------------------------------------
    # Récupération du CSV existant
    # --------------------------------------------------------

    $History = New-Object System.Collections.Generic.List[object]

    if ($Session.FileExists($RemoteCsv))
    {
        Write-Log "Téléchargement du CSV existant : $RemoteCsv"

        Receive-RemoteFile -Session $Session -RemotePath $RemoteCsv -LocalPath $LocalCsv

        if ((Get-Item -LiteralPath $LocalCsv).Length -gt 0)
        {
            foreach ($Row in @(Import-Csv -LiteralPath $LocalCsv -Delimiter ";" -Encoding UTF8))
            {
                $History.Add($Row)
            }
        }

        Write-Log "$($History.Count) ligne(s) déjà présente(s) dans le CSV."
    }
    else
    {
        Write-Log "Aucun CSV existant. Un nouveau CSV sera créé."
    }

    # --------------------------------------------------------
    # Index des fichiers déjà copiés
    # --------------------------------------------------------

    $AlreadyCopied = @{}

    foreach ($Row in $History)
    {
        if ($Row.Statut -eq "COPIE_OK")
        {
            $AlreadyCopied[(Get-HistoryKey $Row.Systeme $Row.Dossier $Row.NomFichier)] = $true
        }
    }

    Write-Log "$($AlreadyCopied.Count) fichier(s) déjà copié(s) d'après l'historique."

    # --------------------------------------------------------
    # Parcours des systèmes
    # --------------------------------------------------------

    foreach ($System in $Systems)
    {
        $InvoicesPath = "$RemoteBase/$System/output/invoices"

        Write-Log "Traitement du système : $System"
        Write-Log "Répertoire source : $InvoicesPath"

        try
        {
            if (-not $Session.FileExists($InvoicesPath))
            {
                Write-Log `
                    "Répertoire invoices absent pour $System. Système ignoré." `
                    "ATTENTION"

                continue
            }

            # Uniquement les sous-dossiers directs de invoices.
            # Les fichiers directement présents sous invoices sont ignorés.
            $Folders = @(
                $Session.ListDirectory($InvoicesPath).Files |
                Where-Object {
                    $_.IsDirectory -and
                    -not $_.IsThisDirectory -and
                    -not $_.IsParentDirectory
                } |
                Sort-Object Name
            )

            if ($Folders.Count -eq 0)
            {
                Write-Log `
                    "Aucun sous-dossier trouvé. Les fichiers directement sous invoices sont ignorés." `
                    "ATTENTION"

                continue
            }

            Write-Log "$($Folders.Count) sous-dossier(s) trouvé(s) pour $System."

            # ------------------------------------------------
            # Parcours des dossiers
            # ------------------------------------------------

            foreach ($Folder in $Folders)
            {
                $FolderName = $Folder.Name
                $FolderPath = "$InvoicesPath/$FolderName"

                Write-Log "Analyse du dossier : $System / $FolderName"

                try
                {
                    # Uniquement les fichiers directement présents
                    # dans le sous-dossier.
                    $Files = @(
                        $Session.ListDirectory($FolderPath).Files |
                        Where-Object { -not $_.IsDirectory } |
                        Sort-Object Name
                    )

                    if ($Files.Count -eq 0)
                    {
                        Write-Log "Aucun fichier dans $FolderPath."
                        continue
                    }

                    Write-Log "$($Files.Count) fichier(s) trouvé(s) dans $FolderName."

                    # ----------------------------------------
                    # Copie des fichiers
                    # ----------------------------------------

                    foreach ($File in $Files)
                    {
                        $FileName   = $File.Name
                        $SourcePath = "$FolderPath/$FileName"
                        $TargetPath = "$RemoteTarget/$FileName"
                        $FileKey    = Get-HistoryKey $System $FolderName $FileName

                        # Ne pas recopier un fichier déjà enregistré
                        # dans le CSV avec le statut COPIE_OK.
                        if ($AlreadyCopied.ContainsKey($FileKey))
                        {
                            $SkippedCount++
                            continue
                        }

                        # La cible est un répertoire à plat : deux fichiers de
                        # même nom (systèmes ou dossiers différents) s'écraseraient.
                        if (
                            -not $OverwriteExistingTarget -and
                            $TargetNames.ContainsKey($FileName.ToLowerInvariant())
                        )
                        {
                            $ErrorCount++

                            Write-Log `
                                "Fichier cible déjà existant, copie non effectuée : $TargetPath (source : $SourcePath)" `
                                "ERREUR"

                            continue
                        }

                        if ($Simulation)
                        {
                            Write-Log "SIMULATION : $SourcePath -> $TargetPath"
                            continue
                        }

                        try
                        {
                            # Copie distante sur le même serveur SFTP.
                            # Le fichier source reste présent.
                            $Method = Copy-RemoteFile `
                                -Session $Session `
                                -SourcePath $SourcePath `
                                -TargetPath $TargetPath `
                                -TempDirectory $WorkDirectory

                            foreach ($Warning in $script:PendingWarnings)
                            {
                                Write-Log $Warning "ATTENTION"
                            }
                            $script:PendingWarnings.Clear()

                            $TargetNames[$FileName.ToLowerInvariant()] = $true

                            Write-Log `
                                "Copie réussie ($Method) : $SourcePath -> $TargetPath" `
                                "OK"
                        }
                        catch
                        {
                            $ErrorCount++

                            foreach ($Warning in $script:PendingWarnings)
                            {
                                Write-Log $Warning "ATTENTION"
                            }
                            $script:PendingWarnings.Clear()

                            Write-Log `
                                "Échec de la copie de $SourcePath : $($_.Exception.Message)" `
                                "ERREUR"

                            # Aucune ligne n'est ajoutée au CSV
                            # lorsque la copie échoue.
                            continue
                        }

                        # Création de la ligne uniquement
                        # après la réussite de la copie.
                        $History.Add([PSCustomObject]@{
                            DateHeure    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                            Systeme      = $System
                            Dossier      = $FolderName
                            NomFichier   = $FileName
                            Source       = $SourcePath
                            Destination  = $TargetPath
                            TailleOctets = $File.Length
                            Statut       = "COPIE_OK"
                        })

                        $AlreadyCopied[$FileKey] = $true
                        $CopiedCount++

                        # Envoi du CSV sur le SFTP après chaque copie réussie :
                        # en cas d'arrêt brutal, l'historique reste cohérent.
                        try
                        {
                            Save-History `
                                -Session $Session `
                                -Rows $History `
                                -LocalCsv $LocalCsv `
                                -RemoteCsv $RemoteCsv
                        }
                        catch
                        {
                            $ErrorCount++

                            Write-Log `
                                "Copie réussie mais échec de la mise à jour du CSV distant : $($_.Exception.Message)" `
                                "ERREUR"
                        }
                    }
                }
                catch
                {
                    $ErrorCount++

                    Write-Log `
                        "Erreur pendant le traitement du dossier $FolderPath : $($_.Exception.Message)" `
                        "ERREUR"
                }
            }
        }
        catch
        {
            $ErrorCount++

            Write-Log `
                "Erreur pendant le traitement du système $System : $($_.Exception.Message)" `
                "ERREUR"
        }
    }
}
catch
{
    $ErrorCount++

    Write-Log `
        "Erreur générale : $($_.Exception.Message)" `
        "ERREUR"

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
            Write-Log `
                "Erreur lors de la fermeture de la session : $($_.Exception.Message)" `
                "ATTENTION"
        }
    }

    if (Test-Path -LiteralPath $WorkDirectory)
    {
        Remove-Item `
            -LiteralPath $WorkDirectory `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
    }

    Write-Log `
        "Bilan : $CopiedCount copie(s), $SkippedCount fichier(s) déjà traité(s), $ErrorCount erreur(s)."

    if ($ErrorCount -gt 0)
    {
        Write-Log `
            "Le traitement s'est terminé avec une ou plusieurs erreurs." `
            "ATTENTION"
    }
    else
    {
        Write-Log "Fin du traitement sans erreur." "OK"
    }
}
