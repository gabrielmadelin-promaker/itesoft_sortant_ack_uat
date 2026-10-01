<#
.SYNOPSIS
    Déplace les fichiers ITESOFT sortants (ACK) des systèmes TALENTIA vers un
    répertoire de sortie unique, sur le même serveur SFTP.

.DESCRIPTION
    Runbook Azure Automation exécuté sur un Hybrid Runbook Worker Windows
    disposant de WinSCP (WinSCPnet.dll).

    Pour chaque système :
        /root/outbound/<SYSTEME>/output/invoices/<SOUS-DOSSIER>/<FICHIER>
    est déplacé vers :
        /root/outbound/azure_automation/output/<FICHIER>

    Le déplacement se fait par renommage SFTP (instantané, côté serveur).
    En cas de refus du serveur : téléchargement, envoi puis suppression de la
    source.

    Chaque déplacement est ajouté (mode append) au journal CSV
    itesoft_sortant_ack_copies.csv sur le SFTP. Le CSV n'est jamais relu :
    la source disparaissant après déplacement, aucun fichier n'est traité
    deux fois.

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

# $false = déplacement réel
# $true  = simulation, aucun déplacement
$Simulation = $false

# Si le fichier cible existe déjà dans $RemoteTarget :
# $false = ne pas l'écraser (source laissée en place, erreur, retenté au prochain passage)
# $true  = l'écraser
$OverwriteExistingTarget = $false

# Journal de session WinSCP (très utile pour diagnostiquer).
# Mettre $null pour le désactiver.
$WinScpSessionLog = Join-Path -Path $env:TEMP -ChildPath "itesoft_sortant_ack_winscp.log"

# Colonnes du CSV (identiques à l'ancienne version, pour l'append).
$CsvColumns = @("DateHeure", "Systeme", "Dossier", "NomFichier", "Source", "Destination", "TailleOctets", "Statut")

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

function Save-PendingRows
{
    # Ajoute les lignes en attente à la fin du CSV distant (append) :
    # seules les nouvelles lignes transitent, quelle que soit la taille du CSV.
    param(
        [Parameter(Mandatory = $true)] $Session,
        [Parameter(Mandatory = $true)] [string]$LocalCsv,
        [Parameter(Mandatory = $true)] [string]$RemoteCsv
    )

    if ($script:PendingRows.Count -eq 0)
    {
        return
    }

    $Lines = @($script:PendingRows | Select-Object $CsvColumns | ConvertTo-Csv -Delimiter ";" -NoTypeInformation)

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

# ============================================================
# INITIALISATION
# ============================================================

$Session       = $null
$WorkDirectory = Join-Path -Path $env:TEMP -ChildPath ("itesoft_sortant_ack_" + [guid]::NewGuid().ToString("N"))
$LocalCsv      = Join-Path -Path $WorkDirectory -ChildPath "itesoft_sortant_ack_copies.csv"

$MovedCount   = 0
$ErrorCount   = 0

$script:PendingRows     = New-Object System.Collections.Generic.List[object]
$script:RemoteCsvExists = $false
$script:LastMoveMethod  = $null

try
{
    Write-Log "Début du Runbook sur la machine $env:COMPUTERNAME."
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

    $Required = [ordered]@{
        SFTP_HOST     = $SftpHost
        SFTP_PORT     = $SftpPort
        SFTP_USER     = $SftpUser
        SFTP_PASSWORD = $SftpPassword
    }

    foreach ($Name in $Required.Keys)
    {
        if ([string]::IsNullOrWhiteSpace($Required[$Name]))
        {
            throw "La variable $Name est vide."
        }
    }

    $PortNumber = 0
    if (-not [int]::TryParse($SftpPort.Trim(), [ref]$PortNumber))
    {
        throw "La variable SFTP_PORT n'est pas un nombre : '$SftpPort'."
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
        Write-Log "SFTP_HOSTKEY non définie : toutes les clés d'hôte SSH sont acceptées." "ATTENTION"
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
    # Dossier cible et CSV
    # --------------------------------------------------------

    if (-not $Session.FileExists($RemoteTarget))
    {
        throw "Le répertoire cible n'existe pas : $RemoteTarget"
    }

    # Noms déjà présents dans la cible (un seul listing pour tout le passage).
    $TargetNames = @{}
    foreach ($TargetFile in $Session.ListDirectory($RemoteTarget).Files)
    {
        if (-not $TargetFile.IsDirectory)
        {
            $TargetNames[$TargetFile.Name.ToLowerInvariant()] = $true
        }
    }

    $script:RemoteCsvExists = $TargetNames.ContainsKey([System.IO.Path]::GetFileName($RemoteCsv).ToLowerInvariant())

    # --------------------------------------------------------
    # Parcours des systèmes
    # --------------------------------------------------------

    foreach ($System in $Systems)
    {
        $InvoicesPath = "$RemoteBase/$System/output/invoices"

        Write-Log "Traitement du système : $System ($InvoicesPath)"

        try
        {
            if (-not $Session.FileExists($InvoicesPath))
            {
                Write-Log "Répertoire invoices absent pour $System. Système ignoré." "ATTENTION"
                continue
            }

            # Uniquement les sous-dossiers directs de invoices.
            # Les fichiers directement présents sous invoices sont ignorés.
            $Folders = @(
                $Session.ListDirectory($InvoicesPath).Files |
                Where-Object { $_.IsDirectory -and -not $_.IsThisDirectory -and -not $_.IsParentDirectory } |
                Sort-Object Name
            )

            if ($Folders.Count -eq 0)
            {
                Write-Log "Aucun sous-dossier trouvé pour $System." "ATTENTION"
                continue
            }
        }
        catch
        {
            $ErrorCount++
            Write-Log "Erreur pendant le traitement du système $System : $($_.Exception.Message)" "ERREUR"
            continue
        }

        foreach ($Folder in $Folders)
        {
            $FolderName = $Folder.Name
            $FolderPath = "$InvoicesPath/$FolderName"

            try
            {
                $Files = @(
                    $Session.ListDirectory($FolderPath).Files |
                    Where-Object { -not $_.IsDirectory } |
                    Sort-Object Name
                )
            }
            catch
            {
                $ErrorCount++
                Write-Log "Lecture impossible du dossier $FolderPath : $($_.Exception.Message)" "ERREUR"
                continue
            }

            # Dossiers vides : pas de log pour ne pas noyer le journal.
            if ($Files.Count -eq 0)
            {
                continue
            }

            Write-Log "$($Files.Count) fichier(s) dans $System / $FolderName."

            foreach ($File in $Files)
            {
                $FileName   = $File.Name
                $SourcePath = "$FolderPath/$FileName"
                $TargetPath = "$RemoteTarget/$FileName"
                $TargetKey  = $FileName.ToLowerInvariant()

                # La cible est à plat : deux fichiers de même nom s'écraseraient.
                if ($TargetNames.ContainsKey($TargetKey) -and -not $OverwriteExistingTarget)
                {
                    $ErrorCount++
                    Write-Log "Fichier cible déjà existant, source laissée en place : $SourcePath -> $TargetPath" "ERREUR"
                    continue
                }

                if ($Simulation)
                {
                    Write-Log "SIMULATION : $SourcePath -> $TargetPath"
                    continue
                }

                try
                {
                    if ($TargetNames.ContainsKey($TargetKey))
                    {
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
                    continue
                }

                $TargetNames[$TargetKey] = $true
                $MovedCount++

                Write-Log "Déplacé ($script:LastMoveMethod) : $SourcePath -> $TargetPath" "OK"

                $script:PendingRows.Add([PSCustomObject]@{
                    DateHeure    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    Systeme      = $System
                    Dossier      = $FolderName
                    NomFichier   = $FileName
                    Source       = $SourcePath
                    Destination  = $TargetPath
                    TailleOctets = $File.Length
                    Statut       = "DEPLACEMENT_OK"
                })
            }

            # Journal CSV mis à jour une fois par sous-dossier.
            try
            {
                Save-PendingRows -Session $Session -LocalCsv $LocalCsv -RemoteCsv $RemoteCsv
            }
            catch
            {
                $ErrorCount++
                Write-Log "Mise à jour du CSV distant impossible (nouvel essai plus tard) : $($_.Exception.Message)" "ERREUR"
            }
        }
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
    # Dernier envoi des lignes non encore enregistrées.
    if ($script:PendingRows.Count -gt 0)
    {
        try
        {
            if ($null -eq $Session -or -not $Session.Opened)
            {
                throw "session SFTP fermée"
            }

            Save-PendingRows -Session $Session -LocalCsv $LocalCsv -RemoteCsv $RemoteCsv
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

    if ($ErrorCount -gt 0)
    {
        Write-Log "Le traitement s'est terminé avec une ou plusieurs erreurs." "ATTENTION"
    }
    else
    {
        Write-Log "Fin du traitement sans erreur." "OK"
    }
}
