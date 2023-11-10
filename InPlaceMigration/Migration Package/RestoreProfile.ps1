# Start and append post-migration log file
$localPath = "C:\ProgramData\IntuneMigration"

$postMigrationLog = "$($localPath)\post-migration.log"
Start-Transcript -Append $postMigrationLog -Verbose
Write-Host "BEGIN LOGGING FOR RESTOREPROFILE..."

$ErrorActionPreference = 'SilentlyContinue'
# Check if migrating data
Write-Host "Checking migration method..."

# Get XML values from local xml content
[xml]$xmlFile = Get-Content -Path "$($localPath)\config.xml"
$config = $xmlFile.Config
$migrateMethod = $config.MigrateMethod
$locations = $config.Locations.Location

# Get current username
$activeUsername = (Get-WMIObject Win32_ComputerSystem | Select-Object username).username
$currentUser = $activeUsername -replace '.*\\'

# Check for temp data path
$tempDataPath = "$($localPath)\TempData"
Write-Host "Checking for $tempDataPath..."
if(!(Test-Path $tempDataPath))
{
	Write-Host "Creating $($tempDataPath)"
	mkdir $tempDataPath
}
else
{
	Write-Host "$($tempDataPath) exists"
}

# Migrate data based on MigrateMethod data point
if($migrateMethod -eq "local")
{
	Write-Host "Migration method is local.  Migrating from Public directory..."
	foreach($location in $locations)
	{
		$userPath = "C:\Users\$($currentUser)\$($location)"
		$publicPath = "C:\Users\Public\Temp\$($location)"
		Write-Host "Initiating data restore of $($location)"
		robocopy $publicPath $userPath /E /ZB /R:0 /W:0 /V /XJ /FFT
  		Remove-Item -Path $publicPath -Recurse -Force
	}
	Write-Host "$($currentUser) data is restored"
}
elseif ($migrateMethod -eq "blob") 
{
	Write-Host "Migration method is blob storage.  Connecting to AzBlob storage account..."
	$storageAccountName = "<STORAGE ACCOUNT NAME>"
	$storageAccountKey = "<STORAGE ACCOUNT KEY>"
	$context = New-AzStorageContext -StorageAccountName $storageAccountName -StorageAccountKey $storageAccountKey
	$containerName = $config.GUID
	foreach($location in $locations)
	{
		if($location -match '[^a-zA-Z0-9]')
		{
			$blobName = $location
			$blobName = $blobName -replace '\\'
			$blob = "$($blobName).zip"	
			$userPath = "C:\Users\$($currentUser)\$($location)"
			$blobDownload = @{
				Blob = $blob
				Container = $containerName
				Destination = $tempDataPath
				Context = $context
			}
			Get-AzStorageBlobContent @blobDownload | Out-Null
			$publicPath = "C:\Users\Public\Temp"
			if(!(Test-Path $publicPath))
			{
				mkdir $publicPath
			}
			Expand-Archive -Path "$($tempDataPath)\$($blob)" -DestinationPath $publicPath -Force | Out-Null
			Write-Host "Expanded $($tempDataPath)\$($blob) to $($publicPath) folder"
			$fullPublicPath = "$($publicPath)\$($blobName)"
			robocopy $fullPublicPath $userPath /E /ZB /R:0 /W:0 /V /XJ /FFT
			Write-Host "Coppied contents of $($fullPublicPath) to $($userPath)"
   			Remove-Item -Path "$($tempDataPath)\$($blob) -Recurse -Force
      			Remove-Item -Path $fullPublicPath -Recures -Force
		}
		else 
		{
			$blobName = "$($location).zip"
			$userPath = "C:\Users\$($currentUser)"
			$blobDownload = @{
				Blob = $blobName
				Container = $containerName
				Destination = $tempDataPath
				Context = $context
			}
			Get-AzStorageBlobContent @blobDownload | Out-Null
			Expand-Archive -Path "$($tempDataPath)\$($blobName)" -DestinationPath $userPath -Force | Out-Null
			Write-Host "Expanded $($tempDataPath)\$($blobName) to $($userPath) folder"
   			Remove-Item -Path "$($tempDataPath)\$($blob) -Recurse -Force
		}
	}
	Write-Host "User data restored from blob storage"
}
else
{
	Write-Host "User data will not be migrated"
}

Start-Sleep -Seconds 3

# Renable the GPO so the user can see the last signed-in user on logon screen
try {
	Set-ItemProperty -Path "HKLM:Software\Microsoft\Windows\CurrentVersion\Policies\System" -Name dontdisplaylastusername -Value 0 -Type DWORD
	Write-Host "$(Get-TimeStamp) - Disable Interactive Logon GPO"
} 
catch {
	Write-Host "$(Get-TimeStamp) - Failed to disable GPO"
}

# Disable RestoreProfile Task
Disable-ScheduledTask -TaskName "RestoreProfile"
Write-Host "Disabled RestoreProfile scheduled task"

Write-Host "Rebooting machine in 30 seconds"
Shutdown -r -t 30

Write-Host "END LOGGING FOR RESTOREPROFILE..."
Stop-Transcript
