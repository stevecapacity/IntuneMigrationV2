$modules = @(
	'BurntToast'
	'RunAsUser'
)

foreach($module in $modules)
{
	$installed = Get-InstalledModule -Name $module
	if(-not($installed))
	{
		try 
		{
			Install-Module -Name $module -Confirm:$false -Force
			Import-Module $module			
		}
		catch 
		{
			$message = $_
			Write-Host "Error installing $($module): $message"
		}
	}
	else 
	{
		Import-Module $module
		Write-Host "$($module) already installed."
	}
}


$scriptblock = {
$header = New-BTHeader -Title 'Migration Solution'
$button = New-BTButton -Content 'Whatever' -Dismiss
$text = "Migrating user data, please wait..."
$img = "<PATH TO YOUR LOGO IMG>"
$hero = "<PATH TO HERO GIF OR IMAGE>"
$progress = New-BTProgressBar -Status 'Copying files' -Indeterminate
New-BurntToastNotification -Text $text -AppLogo $img -Header $header -Button $button -HeroImage $hero -ProgressBar $progress
}

Invoke-AsCurrentUser -ScriptBlock $scriptblock -UseWindowsPowerShell