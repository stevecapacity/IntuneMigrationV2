# Start and append post-migration log file
# If we are running as a 32-bit process on an x64 system, re-launch as a 64-bit process
if ("$env:PROCESSOR_ARCHITEW6432" -ne "ARM64")
{
    if (Test-Path "$($env:WINDIR)\SysNative\WindowsPowerShell\v1.0\powershell.exe")
    {
        & "$($env:WINDIR)\SysNative\WindowsPowerShell\v1.0\powershell.exe" -ExecutionPolicy bypass -NoProfile -File "$PSCommandPath"
        Exit $lastexitcode
    }
}

$programData = $env:ALLUSERSPROFILE
$localPath = "$($programData)\IntuneMigration"

Start-Transcript -Append "$($localPath)\post-migration.log" -Verbose
Write-Host "BEGIN LOGGING FOR GROUPTAG..."

# Add Group Tag from Autopilot device in Tenant A to Azure AD object in Tenant B
<#PERMISSIONS NEEDED FOR APP REG:
Device.ReadWrite.All
DeviceManagementApps.ReadWrite.All
DeviceManagementConfiguration.ReadWrite.All
DeviceManagementManagedDevices.PrivilegedOperations.All
DeviceManagementManagedDevices.ReadWrite.All
DeviceManagementServiceConfig.ReadWrite.All
#>

# App reg info for tenant B
$clientId = "<CLIENT ID>"
$clientSecret = "<CLIENT SECRET>"
$tenant = "TenantB.com"

# Authenticate to graph
$headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
$headers.Add("Content-Type", "application/x-www-form-urlencoded")

$body = "grant_type=client_credentials&scope=https://graph.microsoft.com/.default"
$body += -join("&client_id=" , $clientId, "&client_secret=", $clientSecret)

$response = Invoke-RestMethod "https://login.microsoftonline.com/$tenant/oauth2/v2.0/token" -Method 'POST' -Headers $headers -Body $body

#Get Token form OAuth.
$token = -join("Bearer ", $response.access_token)

#Reinstantiate headers.
$headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
$headers.Add("Authorization", $token)
$headers.Add("Content-Type", "application/json")
Write-Host "MS Graph Authenticated"

#==============================================================================#

# Get tag and device info
Write-Host "Retrieving info from local XML..."

[xml]$memSettings = Get-Content "$($localPath)\config.xml"
$memConfig = $memSettings.Config

$oldTag = $memConfig.GroupTag
Write-Host "Group Tag is $($oldTag)"

$serialNumber = $memConfig.SerialNumber
Write-Host "Serial number is $($serialNumber)"

# Get graph info
Write-Host "Getting information from Microsoft Graph.  Looking for Intune object ID..."

$intuneObject = Invoke-RestMethod -Method GET -Uri "https://graph.microsoft.com/beta/deviceManagement/managedDevices?`$filter=contains(serialNumber,'$($serialNumber)')" -Headers $headers
Write-Host "Intune object ID is $($intuneObject)"

$aadDeviceId = $intuneObject.value.azureADDeviceId
Write-Host "Getting Azure AD object..."


$aadObject = Invoke-RestMethod -Method GET -Uri "https://graph.microsoft.com/beta/devices?`$filter=deviceId eq '$($aadDeviceId)'" -Headers $headers
$aadObjectId = $aadObject.value.id
Write-Host "Azure AD object ID is $($aadObjectId)"

# Place group tag in correct format and add to existing physical IDs

$physicalIds = $aadObject.value.physicalIds
$groupTag = "[OrderID]:$($oldTag)"
$physicalIds += $groupTag

# Construct JSON body for graph post

$body = @{
	physicalIds = $physicalIds
} | ConvertTo-Json

# PATCH to graph

Invoke-RestMethod -Uri "https://graph.microsoft.com/beta/devices/$($aadObjectId)" -Method Patch -Headers $headers -Body $body

Start-Sleep -Seconds 3

# Disable Task
Disable-ScheduledTask -TaskName "GroupTag"
Write-Host "Disabled GroupTag scheduled task"

Write-Host "END LOGGING FOR GROUPTAG..."
Stop-Transcript