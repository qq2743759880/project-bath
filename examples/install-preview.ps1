[CmdletBinding()]
param([string]$Archive='', [string]$Destination='')
$ErrorActionPreference='Stop'
if(!$Archive){$Archive=Join-Path (Split-Path -Parent $PSScriptRoot) 'dist\project-bath-v0.2.0-rc3.zip'}
$Archive=[IO.Path]::GetFullPath($Archive)
if(!$Destination){$Destination=Join-Path ([IO.Path]::GetDirectoryName($Archive)) ('project-bath-preview-'+[Guid]::NewGuid().ToString('N').Substring(0,8))}
$Destination=[IO.Path]::GetFullPath($Destination)
if(Test-Path -LiteralPath $Destination){throw 'Destination exists. Choose a NEW isolated directory; no existing Skill will be overwritten.'}
if((Get-FileHash -LiteralPath $Archive).Hash.ToLowerInvariant() -cne '80ac1055823f01fbb5ed4d8d54e85f8b4b780442e140f9c6676fd6d1c9e40c2d'){throw 'Runtime archive differs from this RC3 release'}
Expand-Archive -LiteralPath $Archive -DestinationPath $Destination
$root=Join-Path $Destination 'project-bath'
$expected=@('SKILL.md','references/LICENSE','references/protocol.md','scripts/bath.ps1','scripts/bath-group.ps1','scripts/bath-scope.ps1','scripts/bath-view.ps1','scripts/bath-preview.ps1','scripts/bath-rename.ps1')
$files=@(Get-ChildItem -LiteralPath $root -Recurse -File)
if($files.Count-ne$expected.Count){throw 'Unexpected Runtime file inventory'}
foreach($file in $files){
    $relative=[IO.Path]::GetRelativePath($root,$file.FullName).Replace('\','/')
    if($relative-cnotin$expected -or ($file.Attributes-band[IO.FileAttributes]::ReparsePoint)){throw 'Unexpected Runtime path'}
    # Only this newly extracted installer-owned code; never normalize a target project's data.
    [IO.File]::SetAttributes($file.FullName,[IO.FileAttributes]::Archive)
}
& (Join-Path $PSHOME 'pwsh.exe') -NoProfile -File (Join-Path $root 'scripts\bath.ps1') -Action Help
if($LASTEXITCODE-ne0){throw 'Extracted tool Help failed'}
'Skill entry: '+(Join-Path $root 'SKILL.md')
'Preview extracted; ask your file-capable Agent to read that exact entry. Existing global installation unchanged.'
