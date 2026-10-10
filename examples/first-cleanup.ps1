[CmdletBinding()]
param([string]$EvidenceDirectory='')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
& (Join-Path $PSScriptRoot 'check-environment.ps1')
$repo=Split-Path -Parent $PSScriptRoot
$tool=Join-Path $repo 'scripts\bath.ps1'
$id=[Guid]::NewGuid().ToString('N').Substring(0,12)
$sampleHome=Join-Path (Join-Path $repo '.project-bath-fixtures') ('showcase-'+$id)
[void][IO.Directory]::CreateDirectory($sampleHome)
$root=Join-Path $sampleHome 'project'
$work=Join-Path 'D:\project-bath\project-bath\_work' ('showcase-'+$id)
[void][IO.Directory]::CreateDirectory($root)
[void][IO.Directory]::CreateDirectory($work)
$encoding=[Text.UTF8Encoding]::new($false)
$old=Join-Path $root 'old-guide.md'
$current=Join-Path $root 'current-guide.md'
[IO.File]::WriteAllText($old,"Retired guide. Replaced by current-guide.md.`n",$encoding)
[IO.File]::WriteAllText($current,"Current startup instructions. Replaces old-guide.md.`n",$encoding)
$before=(Get-FileHash -LiteralPath $old).Hash.ToLowerInvariant()
$plan=Join-Path $work 'plan.json'
[ordered]@{schema_version=1;entries=@([ordered]@{path='old-guide.md';action='archive';before_sha256=$before;after_sha256='absent';evidence='Both disposable guides establish replacement; current-guide.md is the surviving instruction.'})}|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $plan -Encoding utf8
$scope=Join-Path $work 'scope.json'
[ordered]@{schema_version=1;inputs=@('.');excluded=@();outputs=@();limits=@{max_files=0}}|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $scope -Encoding utf8
$checker=Join-Path $work 'check.ps1'
@'
param([Parameter(Mandatory)][string]$ViewRoot)
$ErrorActionPreference='Stop'
if(Test-Path -LiteralPath (Join-Path $ViewRoot 'old-guide.md')){throw 'Old guide remains'}
if([IO.File]::ReadAllText((Join-Path $ViewRoot 'current-guide.md')) -ne "Current startup instructions. Replaces old-guide.md.`n"){throw 'Current instructions changed'}
'Current instructions preserved; retired guide absent.'
'@ | Set-Content -LiteralPath $checker -Encoding utf8
$calls=[Collections.Generic.List[object]]::new()
function Invoke-Demo([string]$Action,[string]$Batch='',[string]$Receipt='') {
    $arguments=@('-NoProfile','-File',$tool,'-Action',$Action,'-Root',$root)
    if($Action-ceq'Prepare'){$arguments+=@('-Plan',$plan,'-Scope',$scope,'-ProjectName','project-bath')}
    if($Batch){$arguments+=@('-Batch',$Batch)}
    if($Action-ceq'Check'){$arguments+=@('-CheckScript',$checker)}
    if($Receipt){$arguments+=@('-Receipt',$Receipt)}
    $start=[DateTime]::UtcNow
    $raw=& (Join-Path $PSHOME 'pwsh.exe') @arguments
    $exit=$LASTEXITCODE
    $value=($raw -join "`n")|ConvertFrom-Json -AsHashtable
    $calls.Add(@{action=$Action;command=@('pwsh')+$arguments;exit_code=$exit;raw_stdout=($raw -join "`n");result=$value;started_utc=$start.ToString('o');finished_utc=[DateTime]::UtcNow.ToString('o')})
    if($exit-ne0 -or !$value.ok){throw "Tool refused $Action. Preserve fixture and backups; do not bypass. $($value.message)"}
    return $value
}
$batch='';$completed=$false
try {
    $prepared=Invoke-Demo Prepare;$batch=$prepared.batch
    if((Get-FileHash -LiteralPath $old).Hash.ToLowerInvariant()-cne$before){throw 'Prepare altered original'}
    $saved=Join-Path $batch 'before.bin'
    if((Get-FileHash -LiteralPath $saved).Hash.ToLowerInvariant()-cne$before){throw 'Backup differs'}
    $applied=Invoke-Demo Apply $batch
    $checked=Invoke-Demo Check $batch
    if(!$checked.passed){throw 'Check did not pass'}
    $finished=Invoke-Demo Finalize $batch $checked.receipt
    $completed=$true
    $status=Invoke-Demo Status $batch
    if($status.observed-cne'Completed'){throw 'Completion state mismatch'}
    $restored=Invoke-Demo Restore $batch
    $preserved=(Get-FileHash -LiteralPath $old).Hash.ToLowerInvariant()-ceq$before
    if(!$preserved){throw 'Restored bytes differ'}
    [ordered]@{prepare=$prepared.state;apply=$applied.state;check_passed=$checked.passed;finalize=$finished.state;restore=$restored.state;original_bytes_preserved=$preserved}|ConvertTo-Json
} finally {
    $record=@{fixture=$root;work=$work;batch=$batch;completed_before_restore=$completed;calls=@($calls.ToArray());note='Disposable sample retained; no cleanup of D archives. This proves the tool roundtrip, not all business semantics.'}
    $record|ConvertTo-Json -Depth 25|Set-Content -LiteralPath (Join-Path $work 'trace.json') -Encoding utf8
    if($EvidenceDirectory){[void][IO.Directory]::CreateDirectory($EvidenceDirectory);$record|ConvertTo-Json -Depth 25|Set-Content -LiteralPath (Join-Path $EvidenceDirectory 'first-cleanup-trace.json') -Encoding utf8}
}
