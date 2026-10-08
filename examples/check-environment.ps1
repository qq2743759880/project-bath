$ErrorActionPreference='Stop'
if(!$IsWindows){throw 'Windows required'}
if($PSVersionTable.PSVersion -lt [version]'7.4'){throw 'PowerShell 7.4+ required'}
$drive=[IO.DriveInfo]::new('D:\')
if(!$drive.IsReady -or $drive.DriveType -ne 'Fixed' -or $drive.DriveFormat -ne 'NTFS'){throw 'A ready local fixed NTFS D drive is required'}
[ordered]@{windows=$true;powershell=$PSVersionTable.PSVersion.ToString();archive_drive='D:';additional_runtime_packages='none'}|ConvertTo-Json -Compress
