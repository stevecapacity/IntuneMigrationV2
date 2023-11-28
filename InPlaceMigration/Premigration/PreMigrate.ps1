<# PRE MIGRATION BACKUP - SCRIPT FOR INTUNE TENANT TO TENANT MIGRATION #>
<# RUN AT T-10 DAYS BEFORE MIGRATION #>
<# WARNING: THIS MUST BE RUN AS SYSTEM CONTEXT #>
<#APP REG PERMISSIONS NEEDED:
Device.ReadWrite.All
DeviceManagementApps.ReadWrite.All
DeviceManagementConfiguration.ReadWrite.All
DeviceManagementManagedDevices.PrivilegedOperations.All
DeviceManagementManagedDevices.ReadWrite.All
DeviceManagementServiceConfig.ReadWrite.All
#>
# If we are running as a 32-bit process on an x64 system, re-launch as a 64-bit process
if ("$env:PROCESSOR_ARCHITEW6432" -ne "ARM64")
{
    if (Test-Path "$($env:WINDIR)\SysNative\WindowsPowerShell\v1.0\powershell.exe")
    {
        & "$($env:WINDIR)\SysNative\WindowsPowerShell\v1.0\powershell.exe" -ExecutionPolicy bypass -NoProfile -File "$PSCommandPath"
        Exit $lastexitcode
    }
}

#// PRE-MIGRATE BACKUP SCRIPT SHOULD RUN AT A MINIMUM OF 10 DAYS PRIOR TO TENANT MIGRATION
$ErrorActionPreference = 'SilentlyContinue'

<# =================================================================================================#>
#### LOCAL FILES AND LOGGING ####
<# =================================================================================================#>

# Create local path for files and logging

$programData = $env:ALLUSERSPROFILE
$localPath = "$($programData)\IntuneMigration"

if(!(Test-Path $localPath))
{
    mkdir $localPath
}

# Set detection flag for Intune install
$installFlag = "$($localPath)\Installed.txt"
New-Item $installFlag -Force
Set-Content -Path $installFlag -Value "Installed"

# Start logging
Start-Transcript -Path "$($localPath)\preMigrationBackup.log" -Verbose

Write-Host "Starting Intune tenant to tenant migration pre-migrate backup process..."

<# =================================================================================================#>
#### AUTHENTICATE TO MS GRAPH ####
<# =================================================================================================#>

# SOURCE TENANT Application Registration Auth
Write-Host "Authenticating to MS Graph..."
$clientId = "<APPLICATION CLIENT ID>"
$clientSecret = "<APPLICATION CLIENT SECRET>"
$tenant = "<name@tenant.com>"

$headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
$headers.Add("Content-Type", "application/x-www-form-urlencoded")

$body = "grant_type=client_credentials&scope=https://graph.microsoft.com/.default"
$body += -join ("&client_id=" , $clientId, "&client_secret=", $clientSecret)

$response = Invoke-RestMethod "https://login.microsoftonline.com/$tenant/oauth2/v2.0/token" -Method 'POST' -Headers $headers -Body $body

#Get Token form OAuth.
$token = -join ("Bearer ", $response.access_token)

#Reinstantiate headers.
$headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
$headers.Add("Authorization", $token)
$headers.Add("Content-Type", "application/json")
Write-Host "MS Graph Authenticated"

<# =================================================================================================#>
#### CONNECT TO BLOB STORAGE ####
<# =================================================================================================#>

# Install Az Storage module for blob
Write-Host "Checking for NuGet Package Provider..."
$nuget = Get-PackageProvider -Name NuGet -ErrorAction Ignore

if(-not($nuget))
{
    try
    {
        Write-Host "Package Provider NuGet not found. Installing now..."
        Install-PackageProvider -Name NuGet -Confirm:$false -Force
        Write-Host "NuGet installed."
    }
    catch
    {
        $message = $_
        Write-Host "Error installing NuGet: $message"
    }
}
else 
{
    Write-Host "Package Provider NuGet already installed"
}

$azStorage = Get-InstalledModule -Name Az.Storage -ErrorAction Ignore

if(-not($azStorage))
{
    try 
    {
        Write-Host "Az.Storage module not found. Installing now..."
        Install-Module -Name Az.Storage -Force
        Import-Module Az.Storage
        Write-Host "Az.Storage module installed"    
    }
    catch 
    {
        $message = $_
        Write-Host "Error installing Az.Storage module: $message"
    }
}
else
{
    Write-Host "Az.Storage module already installed"
    Import-Module Az.Storage
}

# Connect to blob storage
$storageAccountName = "<STORAGE ACCOUNT NAME>"
$storageAccountKey = "<STORAGE ACCOUNT KEY>"
$context = New-AzStorageContext -StorageAccountName $storageAccountName -StorageAccountKey $storageAccountKey
$container = 'migration'

Write-Host "Connecting to Azure blob storage account $($storageAccountName)"

<# =================================================================================================#>
#### GET CURRENT STATE INFO ####
<# =================================================================================================#>
$guid = (New-Guid).Guid

# Get active username
$activeUsername = (Get-WMIObject Win32_ComputerSystem | Select-Object username).username
$user = $activeUsername -replace '.*\\'
Write-Host "Current active user is $($user)"
$currentDomain = (Get-WmiObject Win32_ComputerSystem | Select-Object Domain).Domain

# Get hostname
$hostname = $env:COMPUTERNAME
Write-Host "Device hostname is $($hostname)"

# Gather Autopilot and Intune Object details
Write-Host "Gathering device info from tenant $($tenant)"
$serialNumber = Get-WmiObject -Class Win32_Bios | Select-Object -ExpandProperty serialNumber
Write-Host "Serial number is $($serialNumber)"

$autopilotObject = Invoke-RestMethod -Method Get -Uri "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeviceIdentities?`$filter=contains(serialNumber,'$($serialNumber)')" -Headers $headers
$intuneObject = Invoke-RestMethod -Method Get -Uri "https://graph.microsoft.com/beta/deviceManagement/managedDevices?`$filter=contains(serialNumber,'$($serialNumber)')" -Headers $headers

$autopilotID = $autopilotObject.value.id
Write-Host "Autopilot ID is $($autopilotID)"
$intuneID = $intuneObject.value.id
Write-Host "Intune ID is $($intuneID)"
$groupTag = $autopilotObject.value.groupTag
Write-Host "Current Autopilot GroupTag is $($groupTag)"

<#===============================================================================================#>
# User paths to be migrated
# Paths can be added or removed from this array as needed without affecting the migration.  Note that more paths will mean more files will mean larger data sizes...
Write-Host "Determining paths to be migrated..."

$locations = @(
    "AppData\Local"
    "AppData\Roaming"
    "Documents"
    "Desktop"
    "Pictures"
    "Downloads"
)

$xmlLocations = @()

foreach($location in $locations)
{
    $xmlLocations += "<Location>$location</Location>`n"
    Write-Host "$($location) will be migrated"
}

<# =================================================================================================#>
#### GET INSTALLED APPLICATIONS
<# =================================================================================================#>

Write-Host "Getting installed applications..."

$apps = (Get-Package | Where-Object {$_.ProviderName -eq "Programs" -or $_.ProviderName -eq "msi"}).Name
$allApps = @()

foreach($app in $apps)
{
    $allApps += "<Application>$app</Application>"
    Write-Host "$($app) is installed on $($hostname)."    
}

<# =================================================================================================#>
#### DATA MIGRATION + BACKUP METHOD ####
<# =================================================================================================#>

# Check user data size
$totalProfileSize

foreach($location in $locations)
{
    $userLocation = "C:\Users\$($user)\$($location)"
    $size = (Get-ChildItem $userLocation -Recurse | Measure-Object Length -Sum).Sum
    $sizeGB = "{0:N2} GB" -f ($size / 1Gb)
    Write-Host "$userLocation is $($sizeGB)"
    $totalProfileSize += $size
}

$totalProfileSizeGB = "{0:N2} GB" -f ($totalProfileSize/ 1Gb)
Write-Host "The size of $($user) user data is $($totalProfileSizeGB)"

# Check disk space
$diskSize = Get-Volume -DriveLetter C | Select-Object -ExpandProperty size
$diskSizeGB = "{0:N2} GB" -f ($diskSize/ 1Gb)
$freeSpace = Get-Volume -DriveLetter C | Select-Object -ExpandProperty SizeRemaining
$freeSpaceGB = "{0:N2} GB" -f ($freeSpace/ 1Gb)
Write-Host "Disk has $($freeSpaceGB) free space available out of the total $($diskSizeGB)"

# Space needed for local migration vs blob storage
$localRequiredSpace = $totalProfileSize * 3
$localRequiredSpaceGB = "{0:N2} GB" -f ($localRequiredSpace/ 1Gb)
Write-Host "$($localRequiredSpaceGB) of free disk space is required to migrate data locally"

$blobRequiredSpace = $totalProfileSize * 2
$blobRequiredSpaceGB = "{0:N2} GB" -f ($blobRequiredSpace/ 1Gb)
Write-Host "$($blobRequiredSpaceGB) of free disk space is required to migrate data via blob storage"

# Attempt to backup data for migration
$migrateMethod = ""
# Try local backup 
# Exclude AAD.BrokerPlugin folder

$aadBrokerFolder = Get-ChildItem -Path "$($userLocation)\Packages" | Where-Object {$_.Name -match "Microsoft.AAD.BrokerPlugin_*"} | Select-Object -ExpandProperty Name
$aadBrokerPath = "$($userLocation)\Packages\$($aadBrokerFolder)"

if($freeSpace -gt $localRequiredSpace)
{
    $migrateMethod = "local"
    Write-Host "$($freeSpaceGB) of free space is sufficient to transfer $($totalProfileSizeGB) of $($user) data locally."
    foreach($location in $locations)
    {   
        $userLocation = "C:\Users\$($user)\$($location)"
        $backupLocation = "C:\Users\Public\Temp\$($location)"
        if(!(Test-Path $backupLocation))
        {
            mkdir $backupLocation
        }
        Write-Host "Initiating backup of $($userLocation)"
        robocopy $userLocation $backupLocation /E /ZB /R:0 /W:0 /V /XJ /FFT /XD $aadBrokerPath
        Write-Host "$($userLocation) backed up to $($backupLocation)"    
    }
}
# Try blob backup
elseif($freeSpace -gt $blobRequiredSpace) 
{
    $migrateMethod = "blob"
    # Create user container
    $containerName = $guid
    New-AzStorageContainer -Name $containerName -Context $context
    Write-Host "$($freeSpaceGB) of free space is sufficient to transfer $($totalProfileSizeGB) of $($user) data via blob storage."
    foreach($location in $locations)
    {
        $userLocation = "C:\Users\$($user)\$($location)"
        $blobLocation = $location
        if($blobLocation -match '[^a-zA-Z0-9]')
        {
            Write-Host "$($blobLocation) contains special character.  Removing..."
            $blobName = $blobLocation -replace '\\'
            Write-Host "Removed special character from $($blobName)"
            $backupLocation = "$($localPath)\$($blobName)"
            if(!(Test-Path $backupLocation))
            {
                mkdir $backupLocation
            }
            robocopy $userLocation $backupLocation /E /ZB /R:0 /W:0 /V /XJ /FFT /XD $aadBrokerPath
            Write-Host "Coppied data from $($userLocation) to $($backupLocation)"
            Compress-Archive -path "$($backupLocation)" -DestinationPath "$($localPath)\$($blobName)" -Force
            Write-Host "Compressed $($backupLocation) to $($localPath)\$($blobName).zip"
            Set-AzStorageBlobContent -File "$($localPath)\$($blobName).zip" -Container $containerName -Blob "$($blobName).zip" -Context $context -Force | Out-Null
            Write-Host "$($blobName).zip uploaded to $($storageAccountName) blob storage"
            Remove-Item -Path "$($backupLocation)" -Recurse -Force
            Remove-Item -Path "$($localPath)\$($blobName).zip" -Recurse -Force
        }
        else 
        {
            Write-Host "$($blobLocation) does not contain special chearacters."
            $blobName = $blobLocation
            Compress-Archive -Path $userLocation -DestinationPath "$($localPath)\$($blobName)" -Force
            Write-Host "Compressed $($userLocation) to $($localPath)\$($blobName).zip"
            Set-AzStorageBlobContent -File "$($localPath)\$($blobName).zip" -Container $containerName -Blob "$($blobName).zip" -Context $context -Force | Out-Null
            Write-Host "$($blobName).zip uploaded to $($storageAccountName) blob storage"
            Remove-Item -Path "$($localPath)\$($blobName).zip" -Recurse -Force
        }
    }
}
else
{
    # cannot migrate data
    $migrateMethod = "none"
    Write-Host "No enough local space to migrate user data."
}

<# =================================================================================================#>
#### STEP 7: CONSTRUCT XML and upload to blob
<# =================================================================================================#>

# create xml
$xmlString = @"
<Config>
<GUID>$guid</GUID>
<MigrateMethod>$migrateMethod</MigrateMethod>
<Hostname>$hostname</Hostname>
<SerialNumber>$serialNumber</SerialNumber>
<Username>$user</Username>
<CurrentDomain>$currentDomain</CurrentDomain>
<FreeDiskSpace>$freeSpaceGB</FreeDiskSpace>
<TotalProfileSize>$totalProfileSizeGB</TotalProfileSize>
<AutopilotID>$autopilotID</AutopilotID>
<IntuneID>$intuneID</IntuneID>
<GroupTag>$groupTag</GroupTag>
<Locations>
$xmlLocations</Locations>
<Applications>
$allApps</Applications>
</Config>
"@

$xmlFile = "config.xml"
$xmlPath = "$($localPath)\$($xmlFile)"
New-Item $xmlPath -Force
Set-Content -Path $xmlPath -Value $xmlString
Write-Host "XML file saved to $xmlPath"

$blobGUID = "$($guid).xml"

# upload to blob
Set-AzStorageBlobContent -File $xmlPath -Container $container -Blob $blobGUID -Context $context -Force
Write-Host "$($xmlPath) uploaded to $($storageAccountName) blob storage"

Stop-Transcript
