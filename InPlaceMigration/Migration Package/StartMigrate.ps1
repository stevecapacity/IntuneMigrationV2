<# PRIMARY MIGRATION SCRIPT FOR INTUNE TENANT TO TENANT MIGRATION #>
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

$ErrorActionPreference = 'SilentlyContinue'

<# =================================================================================================#>
#### LOCAL FILES AND LOGGING ####
<# =================================================================================================#>

#Copy necessary files from intunewin package to local PC

$localPath = "C:\ProgramData\IntuneMigration"

if (!(Test-Path $localPath)) {
	mkdir $localPath
}

$packageFiles = @(
	"migrate.ppkg",
	"AutopilotRegistration.xml",
	"AutopilotRegistration.ps1",
	"MigrateBitlockerKey.xml",
	"MigrateBitlockerKey.ps1",
	"SetPrimaryUser.xml",
	"SetPrimaryUser.ps1",
	"GroupTag.ps1",
	"GroupTag.xml",
	"MiddleBoot.ps1",
	"MiddleBoot.xml",
	"RestoreProfile.ps1",
	"RestoreProfile.xml"
)

foreach ($file in $packageFiles) {
	Copy-Item -Path "$($PSScriptRoot)\$($file)" -Destination "$($localPath)" -Force -Verbose
}

#Set detection flag for Intune install
$installFlag = "$($localPath)\Installed.txt"
New-Item $installFlag -Force
Set-Content -Path $($installFlag) -Value "Package Installed"

#Start logging of script
Start-Transcript -Path "$($localPath)\migration.log" -Verbose

# Verify context is 
Write-Host "Running as..."
whoami
Write-Host ""


<# =================================================================================================#>
#### AUTHENTICATE TO MS GRAPH AND BLOB STORAGE####
<# =================================================================================================#>

#SOURCE TENANT Application Registration Auth 
Write-Host "Authenticating to MS Graph..."
$clientId = "<CLIENT ID>"
$clientSecret = "<CLIENT SECRET>"
$tenant = "<TENANT.COM>"

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
#### IMPORT XML ####
<# =================================================================================================#>
# Check if premigrate was run or if migration is starting from StartMigrate
$preMigrate = "$($localPath)\config.xml"
if(Test-Path $preMigrate)
{
	Write-Host "Premigration process has run.  Importing device properties..."
	[xml]$xmlFile = Get-Content -Path "$($localPath)\config.xml"
	$config = $xmlFile.Config
	$intuneID = $config.IntuneID
	Write-Host "Intune ID is $($intuneID)"
	$autopilotID = $config.AutopilotID
	Write-Host "Autopilot ID is $($autopilotID)"
	$migrateMethod = $config.MigrateMethod
	$locations = $config.Locations.Location
}
else
{
	Write-Host "Premigration not run.  Gathering device info now..."
	$serialNumber = Get-WmiObject -Class Win32_Bios | Select-Object -ExpandProperty serialNumber
	$autopilotObject = Invoke-RestMethod -Method Get -Uri "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeviceIdentities?`$filter=contains(serialNumber,'$($serialNumber)')" -Headers $headers
	$intuneObject = Invoke-RestMethod -Method Get -Uri "https://graph.microsoft.com/beta/deviceManagement/managedDevices?`$filter=contains(serialNumber,'$($serialNumber)')" -Headers $headers
	$autopilotID = $autopilotObject.value.id
	Write-Host "Autopilot ID is $($autopilotID)"
	$intuneID = $intuneObject.value.id
	Write-Host "Intune ID is $($intuneID)"
	$groupTag = $autopilotObject.value.groupTag
	Write-Host "Current Autopilot group tag is $($groupTag)"
	$migrateMethod = "none"
	$activeUserName = (Get-WmiObject -Class Win32_ComputerSystem | Select-Object username).username
	$user = $activeUsername -replace '.*\\'
	Write-Host "Current user is $($user)"

	Write-Host "Creating local XML config file"
	$xmlString = @"
	<Config>
	<GroupTag>$groupTag</GroupTag>
	<User>$user</User>
	<MigrateMethod>$migrateMethod</MigrateMethod>
	<SerialNumber>$serialNumber</SerialNumber>
"@
	$xmlPath = "$($localPath)\config.xml"
	New-Item $xmlPath -Force
	Set-Content -Path $xmlPath -Value $xmlString
	Write-Host "Set local content to $($xmlPath)"
}
<# =================================================================================================#>
#### SET REQUIRED POLICY ####
<# =================================================================================================#>
# Ensure Microsoft Account creation policy is enabled

$regPath = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Accounts"
$regName = "AllowMicrosoftAccountConnection"
$value = 1

$currentRegValue = Get-ItemPropertyValue -Path $regPath -name $regName -ErrorAction SilentlyContinue

if ($currentRegValue -eq $value) {
	Write-Host "Registry value for AllowMicrosoftAccountConnection is correctly set to $value."
}
else {
	Write-Host "Setting MDM registry value for AllowMicrosoftAccountConnection..."
	reg.exe add "HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Accounts" /v "AllowMicrosoftAccountConnection" /t REG_DWORD /d 1 /f | Out-Host
}

<#===============================================================================================#>
# Only show OTHER USER option after reboot
Write-Host "Turning off Last Signed-In User Display...."
try {
	Set-ItemProperty -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System" -Name dontdisplaylastusername -Value 1 -Type DWORD -Force
	Write-Host "Enabled Interactive Logon policy"
} 
catch {
	Write-Host "Failed to enable policy"
}
<# =================================================================================================#>
#### USER DATA MIGRATION ####
<# =================================================================================================#>
Write-Host "Checking migration method..."

if($migrateMethod -eq "local")
{
	Write-Host "Migration method is local.  Verifying staged content in Public folder..."
	foreach($location in $locations)
	{
		$publicPath = "C:\Users\Public\Temp\$($location)"
		if(Test-Path $publicPath)
		{
			Write-Host "$($publicPath) is staged and ready for migration"
		}
		else
		{
			Write-Host "$($publicPath) is not found"
		}
	}
}
elseif ($migrateMethod -eq "blob") 
{
	Import-Module Az.Storage
	$storageAccountName = "<STORAGE ACCOUNT NAME>"
	$storageAccountKey = "<STORAGE ACCOUNT KEY>"
	$context = New-AzStorageContext -StorageAccountName $storageAccountName -StorageAccountKey $storageAccountKey
	$blobContainer = $config.GUID
	$blobExists = Get-AzStorageContainer -Context $context | Where-Object {$_.Name -eq "$($blobContainer)"}
	if($blobExists -ne $null)
	{
		Write-Host "Blob storage is ready for migration"
	}
	else
	{
		Write-Host "Blob storage is not ready."
	} 
}
else
{
	Write-Host "User data will not be migrated"
}
<# =================================================================================================#>
#### REMOVE PREVIOUS ENROLLMENT ARTIFICATS ####
<# =================================================================================================#>
#Remove previous MDM enrollment settings from registry

Get-ChildItem 'Cert:\LocalMachine\My' | Where-Object { $_.Issuer -match "Microsoft Intune MDM Device CA" } | Remove-Item -Force

$EnrollmentsPath = "HKLM:\Software\Microsoft\Enrollments\"
$ERPath = "HKLM:\Software\Microsoft\Enrollments\"
$Enrollments = Get-ChildItem -Path $EnrollmentsPath
foreach ($enrollment in $Enrollments) {
	$object = Get-ItemProperty Registry::$enrollment
	$discovery = $object."DiscoveryServiceFullURL"
	if ($discovery -eq "https://enrollment.manage.microsoft.com/enrollmentserver/discovery.svc") {
		$enrollPath = $ERPath + $object.PSChildName
		Remove-Item -Path $enrollPath -Recurse
	}
}

<#===============================================================================================#>
#Remove previous MDM enrollment tasks in task scheduler
$enrollID = $enrollPath.Split('\')[-1]

$taskPath = "\Microsoft\Windows\EnterpriseMgmt\$($enrollID)\"

$tasks = Get-ScheduledTask -TaskPath $taskPath

if ($tasks.Count -gt 0) {
	Write-Host "Deleting tasks in folder: $taskPath"
	foreach ($task in $tasks) {
		$taskName = $task.TaskName
		Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
		Write-Host "Deleted task: $taskName"
	}
}
else {
	Write-Host "No tasks found in folder: $taskPath"
}

Write-Host "Removed previous Intune enrollment"

<# =================================================================================================#>
#### LEAVE AZURE AD AND INTUNE ####
<# =================================================================================================#>

# Remove device from Current Azure AD and Intune environment

Write-Host "Leaving the $($tenant) Azure AD and Intune environment"
Start-Process "C:\Windows\sysnative\dsregcmd.exe" -ArgumentList "/leave"

# Check if device is domain joined
$dsregStatus = (dsregcmd /status | Select-String "DomainJoined")
$dsregString = $dsregStatus.ToString()
$domainJoin = $dsregString.Split(":")[1].Trim()

# If machine is domain joined, remove from domain
if($domainJoin -eq "YES"){
	$password = ConvertTo-SecureString "MyPlainTextPassword" -AsPlainText -Force
	$cred = New-Object System.Management.Automation.PSCredential ("domain\username", $password)

	Write-Host "Computer $($env:COMPUTERNAME) is Domain Joined.  Attempting to remove..."
	try {
		Remove-Computer -UnjoinDomainCredential $cred -Force
		Write-Host "Removed computer $($env:COMPUTERNAME) from $($tenant)"
	}
	catch {
		Write-Host "Could not remove computer $($env:COMPUTERNAME) from $($tenant)"
	}
} else {
	Write-Host "Computer $($env:COMPUTERNAME) is not Domain Joined"
}

Start-Sleep -Seconds 5

<# =================================================================================================#>
#### SET POST-MIGRATION TASKS ####
<# =================================================================================================#>

#Create post-migration tasks

foreach($file in $packageFiles)
{
    if($file -match '.xml')
    {
        $name = $file.Split('.')[0]
        schtasks /create /TN $($name) /xml "$($localPath)\$($file)" /f
		Write-Host "Created $($name) task"
    }
}

<# =================================================================================================#>
#### JOIN TENANT B ####
<# =================================================================================================#>

#Run ppkg to enroll into new tenant
Write-Host "Installing provisioning package for new Azure AD tenant"
Install-ProvisioningPackage -PackagePath "$($localPath)\migrate.ppkg" -QuietInstall -Force

<# =================================================================================================#>
#### DELETE OBJECTS FROM TENANT A AND REBOOT ####
<# =================================================================================================#>

#Delete Intune and Autopilot objects from old tenant
if ($intuneID -eq $null) {
	Write-Host "Intune ID is null.  Skipping Intune object deletion..."
}
else {
	Write-Host "Attempting to Delete the Intune object..."
	try {
		Invoke-RestMethod -Method Delete -Uri "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$($intuneID)" -Headers $headers
		Start-Sleep -Seconds 2
		Write-Host "Intune object deleted."
	}
 catch {
		Write-Host "Intune object deletion failed.  Trying again..."
		Write-Host "StatusCode:" $_.Exception.Response.StatusCode.value__ 
		Write-Host "StatusDescription:" $_.Exception.Response.StatusDescription
	}

}

if ($autopilotID -eq $null) {
	Write-Host "Autopilot ID is null.  Skipping Autopilot object deletion..."
}
else {
	Write-Host "Attempting to Delete the Autopilot object..."
	try {
		Invoke-RestMethod -Method Delete -Uri "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeviceIdentities/$($autopilotID)" -Headers $headers
		Start-Sleep -Seconds 2
		Write-Host "Autopilot object deleted."
	}
 catch {
		Write-Host "Autopilot object deletion failed.  Trying again..."
		Write-Host "StatusCode:" $_.Exception.Response.StatusCode.value__ 
		Write-Host "StatusDescription:" $_.Exception.Response.StatusDescription
	}
}

<#===============================================================================================#>
# Reboot
Shutdown -r -t 30

Stop-Transcript
