[CmdletBinding()]
param([string]$Action='Status',[string]$Root,[string]$Plan,[string]$Batch)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$script:RenameScripts=$PSScriptRoot

function Import-RenameHelpers {
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'bath.ps1'),[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'TOOL_INVALID: main helper parse failed'}
    foreach($name in @('Initialize-Native','Get-LocalPath','Pin-Directory','New-PinnedDirectory','Read-PinnedFile','New-Json','Write-Lease','Check-Keys')){
        $defs=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)|Where-Object Name -CEQ $name)
        if($defs.Count-ne 1){throw 'TOOL_INVALID: helper definition ambiguous'}
        . ([scriptblock]::Create($defs[0].Extent.Text))
        Set-Item "function:script:$name" (Get-Item "function:$name").ScriptBlock
    }
    Initialize-Native
    . (Join-Path $PSScriptRoot 'bath-scope.ps1')
    foreach($name in @('Assert-ScopeJson','Assert-ScopeRelative','Test-ScopeUnder','Assert-ScopeAcl','Read-BathScope','Initialize-ScopeNative','Add-ScopeDirectoryAncestors')){
        Set-Item "function:script:$name" (Get-Item "function:$name").ScriptBlock
    }
}

function Assert-RenameString($Value,[string]$Name,[string]$Pattern='') {
    if($Value-isnot[string]-or!$Value.Trim()-or($Pattern-and$Value-cnotmatch$Pattern)){throw "BAD_SCHEMA: invalid string $Name"}
}
function Assert-RenameVersion($Value) {
    if(($Value-isnot[int]-and$Value-isnot[long])-or$Value-ne 3){throw 'BAD_SCHEMA: integer schema3 required'}
}
function Convert-RenameJson([string]$Json) {
    $arguments=@{InputObject=$Json;AsHashtable=$true;Depth=30}
    if((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')){$arguments.DateKind='String'}
    return (ConvertFrom-Json @arguments)
}
function Read-RenameJson([string]$Path,$Pins) {
    $data=Read-PinnedFile $Path $Pins
    $json=[Text.UTF8Encoding]::new($false,$true).GetString($data.Bytes)
    $doc=[Text.Json.JsonDocument]::Parse($json)
    try{
        Assert-ScopeJson $doc.RootElement;$value=Convert-RenameJson $json
        # Before7.5 ConvertFrom-Json auto-converts ISO strings; preserve actual JSON scalar types.
        if($doc.RootElement.ValueKind-eq'Object'){
            foreach($p in $doc.RootElement.EnumerateObject()){if($p.Value.ValueKind-eq'String'){$value[$p.Name]=$p.Value.GetString()}}
        }
        return @{snapshot=$data;value=$value}
    }finally{$doc.Dispose()}
}
function Read-RenamePlan([byte[]]$Bytes) {
    $json=[Text.UTF8Encoding]::new($false,$true).GetString($Bytes)
    $doc=[Text.Json.JsonDocument]::Parse($json)
    try{
        Assert-ScopeJson $doc.RootElement;$p=Convert-RenameJson $json
        if($doc.RootElement.ValueKind-eq'Object'){
            foreach($property in $doc.RootElement.EnumerateObject()){
                if($property.Value.ValueKind-eq'String'){$p[$property.Name]=$property.Value.GetString()}
                if($property.Name-ceq'entries'-and$property.Value.ValueKind-eq'Array'){
                    $index=0
                    foreach($row in $property.Value.EnumerateArray()){
                        if($row.ValueKind-eq'Object'){foreach($field in $row.EnumerateObject()){if($field.Value.ValueKind-eq'String'){$p.entries[$index][$field.Name]=$field.Value.GetString()}}}
                        $index++
                    }
                }
            }
        }
    }finally{$doc.Dispose()}
    Check-Keys $p @('schema_version','mode','entries');Assert-RenameVersion $p.schema_version
    Assert-RenameString $p.mode 'mode';if($p.mode-cne'rename'-or$p.entries-isnot[array]-or$p.entries.Count-ne 1){throw 'BAD_SCHEMA: exactly one rename entry required'}
    $e=$p.entries[0]
    Check-Keys $e @('entry_id','action','path','destination','evidence')
    Assert-RenameString $e.entry_id 'entry_id' '^[a-z][a-z0-9_-]{0,63}$'
    Assert-RenameString $e.action 'action';if($e.action-cne'rename_directory'){throw 'BAD_SCHEMA: rename_directory action required'}
    Assert-ScopeRelative $e.path;Assert-ScopeRelative $e.destination;Assert-RenameString $e.evidence 'evidence'
    if($e.path.Equals($e.destination,[StringComparison]::OrdinalIgnoreCase)-or[IO.Path]::GetDirectoryName($e.path).Replace('\','/').ToLowerInvariant()-cne[IO.Path]::GetDirectoryName($e.destination).Replace('\','/').ToLowerInvariant()){throw 'BAD_PLAN: different-parent or case-only rename refused'}
    return $e
}
function Get-RenameRuntime($Pins) {
    $r=[ordered]@{}
    foreach($n in @('bath.ps1','bath-scope.ps1','bath-rename.ps1')){$r[$n]=(Read-PinnedFile (Join-Path $script:RenameScripts $n) $Pins).Hash}
    return $r
}
function Assert-RenameDirectoryStreams([string]$Path) {
    # PowerShell7 supports directory streams; no returned stream is normal for a directory.
    # Provider errors fail closed. Every named stream is unsupported, even zero bytes.
    $streams=@(Get-Item -LiteralPath $Path -Stream '*' -ErrorAction Stop)
    foreach($s in $streams){if($s.Stream -isnot[string]-or$s.Stream-cnotin@(':$DATA','::$DATA')){throw 'UNSUPPORTED_DIRECTORY: alternate data stream'}}
    $attributes=[IO.File]::GetAttributes($Path)
    if(([int]$attributes-band(-bnot([int][IO.FileAttributes]::Directory)))-ne 0){throw 'UNSUPPORTED_DIRECTORY: special directory attributes'}
}
function Get-RenameLedger([string]$Project,[string]$ScopePath,$Entry) {
    $s=Read-BathScope -Root $Project -Scope $ScopePath -ProtectedPaths @($Entry.path)
    $directories=@();$files=@()
    foreach($d in $s.directories){
        if(Test-ScopeUnder $d.path $Entry.path){
            $relative=if($d.path-ceq$Entry.path){'.'}else{$d.path.Substring($Entry.path.Length+1)}
            Assert-RenameDirectoryStreams (Join-Path $Project $d.path)
            $directories+=,[ordered]@{path=$relative;id=$d.id}
        }
    }
    foreach($f in $s.files){$files+=,[ordered]@{path=$f.path.Substring($Entry.path.Length+1);id=$f.id;sha256=$f.sha256;write_time=$f.write_time;bytes=$f.bytes}}
    $rootDirectory=@($directories|Where-Object path -CEQ '.');if($rootDirectory.Count-ne 1){throw 'BAD_LEDGER: missing source directory'}
    $ledger=[ordered]@{schema_version=3;directory_id=$rootDirectory[0].id;directories=@($directories|Sort-Object path -CaseSensitive);files=@($files|Sort-Object path -CaseSensitive);limits=$s.limits;stats=[ordered]@{files=$files.Count;directories=$directories.Count;total_bytes=$s.stats.total_bytes}}
    $ledger.namespace_sha256=[BathNative]::Hash([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $ledger -Compress -Depth 30)))
    return $ledger
}
function Assert-RenameIntent($Intent,[string]$Canonical,[string]$RootId,[string]$BatchName) {
    Check-Keys $Intent @('schema_version','kind','batch','canonical_root','root_id','plan_sha256','plan_id','entry_id','path','destination','parent_id','before_directory_id','reason')
    Assert-RenameVersion $Intent.schema_version
    foreach($n in @('root_id','plan_id','parent_id','before_directory_id')){Assert-RenameString $Intent[$n] $n '^[a-f0-9]{8}:[a-f0-9]{16}$'}
    Assert-RenameString $Intent.plan_sha256 'plan_sha256' '^[a-f0-9]{64}$';Assert-RenameString $Intent.reason 'reason'
    if($Intent.kind-isnot[string]-or$Intent.kind-cne'rename'-or$Intent.batch-isnot[string]-or$Intent.batch-cne$BatchName-or$Intent.canonical_root-isnot[string]-or$Intent.canonical_root-cne$Canonical-or$Intent.root_id-cne$RootId){throw 'BAD_INTENT: root/batch mismatch'}
    [void](Read-RenamePlan ([Text.Encoding]::UTF8.GetBytes((@{schema_version=3;mode='rename';entries=@(@{entry_id=$Intent.entry_id;action='rename_directory';path=$Intent.path;destination=$Intent.destination;evidence=$Intent.reason})}|ConvertTo-Json -Compress -Depth 10))))
}
function Assert-RenameManifest($M,$IntentData) {
    Check-Keys $M @('schema_version','kind','batch','canonical_root','root_id','plan_sha256','prepare_intent_sha256','runtime_sha256','entry','backup_kind','full_byte_backup','namespace_sha256','ledger_file_sha256','phase','execution_ready','eligible_for_finalize')
    Assert-RenameVersion $M.schema_version;$i=$IntentData.value
    foreach($n in @('kind','batch','canonical_root','root_id','plan_sha256')){if($M[$n]-isnot[string]-or$M[$n]-cne$i[$n]){throw "BAD_MANIFEST: $n differs from original intent"}}
    foreach($n in @('prepare_intent_sha256','namespace_sha256','ledger_file_sha256')){Assert-RenameString $M[$n] $n '^[a-f0-9]{64}$'}
    if($M.prepare_intent_sha256-cne$IntentData.snapshot.Hash){throw 'BAD_INTENT: original prepare intent changed'}
    foreach($n in @('full_byte_backup','execution_ready','eligible_for_finalize')){if($M[$n]-isnot[bool]){throw 'BAD_MANIFEST: boolean capabilities required'}}
    if($M.full_byte_backup-or$M.eligible_for_finalize-or($M.execution_ready-ne($M.phase-ceq'NAMESPACE_RENAME_COMPONENT_STAGING'))){throw 'BAD_MANIFEST: capability boundary'}
    if($M.backup_kind-isnot[string]-or$M.backup_kind-cne'namespace_evidence'-or$M.phase-isnot[string]-or$M.phase-cnotin@('READ_ONLY_PROJECT_PREPARATION_STAGING','NAMESPACE_RENAME_COMPONENT_STAGING')){throw 'BAD_MANIFEST: phase/backup boundary'}
    Check-Keys $M.runtime_sha256 @('bath.ps1','bath-scope.ps1','bath-rename.ps1')
    foreach($v in $M.runtime_sha256.Values){Assert-RenameString $v 'runtime_sha256' '^[a-f0-9]{64}$'}
    Check-Keys $M.entry @('entry_id','path','destination','parent_id','before_directory_id')
    foreach($n in $M.entry.Keys){if($M.entry[$n]-isnot[string]-or$M.entry[$n]-cne$i[$n]){throw 'BAD_MANIFEST: entry differs from intent'}}
}
function Read-RenameEvidence([string]$Path,$M,$Pins,[bool]$RuntimeRequired=$true) {
    $plan=Read-PinnedFile (Join-Path $Path 'plan.json') $Pins
    if($plan.Hash-cne$M.plan_sha256){throw 'BAD_PLAN: saved plan bytes changed'}
    $entry=Read-RenamePlan $plan.Bytes
    foreach($n in @('entry_id','path','destination')){if($entry[$n]-cne$M.entry[$n]){throw 'BAD_PLAN: saved intent differs'}}
    $raw=Read-RenameJson (Join-Path $Path 'namespace-before.json') $Pins;$l=$raw.value
    if($raw.snapshot.Hash-cne$M.ledger_file_sha256){throw 'BAD_LEDGER: retained byte hash differs'}
    Check-Keys $l @('schema_version','directory_id','directories','files','limits','stats','namespace_sha256');Assert-RenameVersion $l.schema_version
    if($l.namespace_sha256-isnot[string]-or$l.namespace_sha256-cne$M.namespace_sha256-or$l.directory_id-isnot[string]-or$l.directory_id-cne$M.entry.before_directory_id){throw 'BAD_LEDGER: identity/hash binding'}
    $data=[ordered]@{};foreach($key in $l.Keys){if($key-cne'namespace_sha256'){$data[$key]=$l[$key]}}
    if([BathNative]::Hash([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $data -Compress -Depth 30)))-cne$l.namespace_sha256){throw 'BAD_LEDGER: invalid self hash'}
    if($RuntimeRequired){$runtime=Get-RenameRuntime $Pins
    foreach($n in $runtime.Keys){if($runtime[$n]-cne$M.runtime_sha256[$n]){throw 'TOOL_CHANGED: preparation runtime changed'}}}
    return $l
}
function Get-RenameObserved([string]$Project,$Intent) {
    $source=Join-Path $Project $Intent.path;$destination=Join-Path $Project $Intent.destination
    return [ordered]@{source_exists=(Test-Path -LiteralPath $source);destination_exists=(Test-Path -LiteralPath $destination);source_path=$Intent.path;destination_path=$Intent.destination}
}
function Assert-RenameScope([string]$Path,$Intent,$Before,$Pins) {
    $scope=(Read-RenameJson (Join-Path $Path 'scope.json') $Pins).value
    Check-Keys $scope @('schema_version','inputs')
    if(($scope.schema_version-isnot[int]-and$scope.schema_version-isnot[long])-or$scope.schema_version-ne 1-or$scope.inputs-isnot[array]-or$scope.inputs.Count-ne 1-or$scope.inputs[0]-isnot[string]-or$scope.inputs[0]-cne$Intent.path){throw 'BAD_SCOPE: frozen original selection changed'}
}
function Save-RenameAfterScope([string]$Path,$Intent,$Before,$Pins,[bool]$Create=$false) {
    $target=Join-Path $Path 'scope-after.json'
    if($Create-and![IO.File]::Exists($target)){New-Json $target @{schema_version=1;inputs=@($Intent.destination);limits=$Before.limits}}
    $scope=(Read-RenameJson $target $Pins).value
    Check-Keys $scope @('schema_version','inputs','limits')
    if(($scope.schema_version-isnot[int]-and$scope.schema_version-isnot[long])-or$scope.schema_version-ne 1-or$scope.inputs-isnot[array]-or$scope.inputs.Count-ne 1-or$scope.inputs[0]-isnot[string]-or$scope.inputs[0]-cne$Intent.destination-or(ConvertTo-Json $scope.limits -Compress)-cne(ConvertTo-Json $Before.limits -Compress)){throw 'BAD_SCOPE: destination selection/limits changed'}
}
function Add-RenameEvent([string]$Path,[string]$Manifest,[string]$State,[string]$Namespace='',[string]$Ledger='') {
    $event=[ordered]@{event_id=[Guid]::NewGuid().ToString();utc=[DateTime]::UtcNow.ToString('o');manifest_sha256=$Manifest;state=$State}
    if($Namespace){$event.namespace_sha256=$Namespace};if($Ledger){$event.ledger_file_sha256=$Ledger}
    $file=Join-Path $Path 'journal.jsonl'
    if([IO.File]::Exists($file)){[void][BathNative]::Read($file)}
    $stream=[IO.FileStream]::new($file,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try{[BathNative]::Regular($stream.SafeFileHandle);[void]$stream.Seek(0,[IO.SeekOrigin]::End);$bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $event -Compress)+"`n");$stream.Write($bytes);$stream.Flush($true)}finally{$stream.Dispose()}
}
function Read-RenameJournal([string]$Path,$Manifest) {
    $file=Join-Path $Path 'journal.jsonl';$hash=$null;$state='';$last=$null
    if(![IO.File]::Exists($file)){return @{hash=$null;state='Ambiguous';last=$null}}
    $raw=[BathNative]::Read($file);$hash=$raw.Hash
    try{
        $json=[Text.UTF8Encoding]::new($false,$true).GetString($raw.Bytes)
        if(!$json){return @{hash=$hash;state='';last=$null}}
        if(!$json.EndsWith("`n")){throw 'BAD_JOURNAL: partial journal'}
        $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach($line in $json.TrimEnd("`n").Split("`n")){
            $doc=[Text.Json.JsonDocument]::Parse($line)
            try{Assert-ScopeJson $doc.RootElement;$e=Convert-RenameJson $line;foreach($property in $doc.RootElement.EnumerateObject()){if($property.Value.ValueKind-eq'String'){$e[$property.Name]=$property.Value.GetString()}}}finally{$doc.Dispose()}
            Check-Keys $e @('event_id','utc','manifest_sha256','state') @('namespace_sha256','ledger_file_sha256')
            Assert-RenameString $e.event_id 'event_id' '^[a-f0-9-]{36}$';Assert-RenameString $e.utc 'utc';Assert-RenameString $e.manifest_sha256 'manifest_sha256' '^[a-f0-9]{64}$';Assert-RenameString $e.state 'state'
            if(!$seen.Add($e.event_id)-or$e.manifest_sha256-cne$Manifest){throw 'BAD_JOURNAL: binding/duplicate event'}
            foreach($name in @('namespace_sha256','ledger_file_sha256')){if($e.Contains($name)){Assert-RenameString $e[$name] $name '^[a-f0-9]{64}$'}}
            $allowed=switch($state){'' {@('Applying','Conflict')};'Applying' {@('Applied')};'Applied' {@('Restoring','Conflict')};'Restoring' {@('Restored')};'Restored' {@('Conflict')};default {@()}}
            if($e.state-cnotin$allowed){throw 'BAD_JOURNAL: invalid transition'}
            if($e.state-cin@('Applied','Restored')-and(!$e.Contains('namespace_sha256')-or!$e.Contains('ledger_file_sha256'))){throw 'BAD_JOURNAL: confirmation evidence missing'}
            $state=$e.state;$last=$e
        }
        if($state-cin@('Applying','Restoring')){$state='Ambiguous'}
        return @{hash=$hash;state=$state;last=$last}
    }catch{return @{hash=$hash;state='Ambiguous';last=$null}}
}
function Read-RenameAfter([string]$Path,$Event,$Before,$Pins) {
    $after=Read-RenameJson (Join-Path $Path 'namespace-after.json') $Pins
    if($after.snapshot.Hash-cne$Event.ledger_file_sha256-or$Event.namespace_sha256-cne$Before.namespace_sha256-or$after.value.namespace_sha256-cne$Before.namespace_sha256){throw 'BAD_LEDGER: applied after binding changed'}
    # The complete relative ledger must match the frozen original census, including scalar types.
    $a=ConvertTo-Json $after.value -Compress -Depth 30;$b=ConvertTo-Json $Before -Compress -Depth 30
    if($a-cne$b){throw 'BAD_LEDGER: after ledger differs from frozen census'}
    return $after.value
}
function Invoke-RenamePrepare {
    $pins=[Collections.Generic.List[IDisposable]]::new();$lock=$null;$batchPath=$null
    try{
        if($Action-cnotin@('Prepare','Status','Close','Apply','Restore')){throw 'CAPABILITY_BLOCKED: Check/Finalize are gated'}
        if(!$IsWindows-or$PSVersionTable.PSVersion-lt[version]'7.4'){throw 'UNSUPPORTED_HOST: Windows PowerShell7.4+ required'}
        Import-RenameHelpers
        if(($Action-ceq'Prepare'-and(!$Plan-or$Batch))-or($Action-cne'Prepare'-and(!$Batch-or$Plan))){throw 'BAD_ARGUMENT: Prepare requires only Plan; Status/Close require only Batch'}
        $project=Get-LocalPath $Root;$rootId=Pin-Directory $project $pins
        $canonical=$project.Replace('\','/').ToLowerInvariant()
        if($canonical-ceq'd:/project-bath'-or$canonical.StartsWith('d:/project-bath/')){throw 'BAD_ROOT: archive cannot be project'}
        $hash=[BathNative]::Hash([Text.Encoding]::UTF8.GetBytes($canonical))
        $archive=Get-LocalPath (Join-Path 'D:/project-bath' ([IO.Path]::GetFileName($project)+'-'+$hash.Substring(0,8)))
        if($Action-ceq'Prepare'){
            $planPath=Get-LocalPath $Plan;[void](Pin-Directory ([IO.Path]::GetDirectoryName($planPath)) $pins)
            $planData=Read-PinnedFile $planPath $pins;$entry=Read-RenamePlan $planData.Bytes;$runtime=Get-RenameRuntime $pins
            $source=Get-LocalPath (Join-Path $project $entry.path);$destination=Get-LocalPath (Join-Path $project $entry.destination)
            $parentId=Pin-Directory ([IO.Path]::GetDirectoryName($source)) $pins;Assert-ScopeAcl $source
            $sourceId=Pin-Directory $source $pins;Assert-RenameDirectoryStreams $source
            if(Test-Path -LiteralPath $destination){throw 'DESTINATION_EXISTS: any existing destination refused'}
            New-PinnedDirectory 'D:/project-bath' $pins;New-PinnedDirectory $archive $pins
        }else{[void](Pin-Directory $archive $pins)}
        $lockPath=Join-Path $archive 'operation.lock'
        if([IO.File]::Exists($lockPath)){[void][BathNative]::Read($lockPath)}
        $lock=[IO.FileStream]::new($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);[BathNative]::Regular($lock.SafeFileHandle)
        $identityPath=Join-Path $archive 'project.json';$leasePath=Join-Path $archive 'lease.json'
        if(![IO.File]::Exists($identityPath)){if($Action-cne'Prepare'){throw 'BAD_PROJECT: identity missing'};New-Json $identityPath @{canonical_root=$canonical;root_sha256=$hash;root_id=$rootId}}
        $identity=(Read-RenameJson $identityPath $pins).value;Check-Keys $identity @('canonical_root','root_sha256','root_id')
        if($identity.canonical_root-isnot[string]-or$identity.canonical_root-cne$canonical-or$identity.root_sha256-isnot[string]-or$identity.root_sha256-cne$hash-or$identity.root_id-isnot[string]-or$identity.root_id-cne$rootId){throw 'BAD_PROJECT: identity differs'}
        $lease=@{owner='';intent_sha256=''}
        if([IO.File]::Exists($leasePath)){
            # Lease must not remain pinned: Write-Lease atomically renames the control file.
            $lp=[Collections.Generic.List[IDisposable]]::new()
            try{$lease=(Read-RenameJson $leasePath $lp).value}finally{foreach($p in $lp){$p.Dispose()}}
            Check-Keys $lease @('owner') @('intent_sha256')
            if($lease.owner-isnot[string]-or($lease.Contains('intent_sha256')-and$lease.intent_sha256-isnot[string])){throw 'BAD_LEASE: scalar owner/hash required'}
        }
        if($Action-ceq'Prepare'){
            if($lease.owner){throw 'PROJECT_BUSY: another batch owns project'}
            $batchPath=Join-Path $archive ('rename-'+[Guid]::NewGuid().ToString());New-PinnedDirectory $batchPath $pins
            $intent=[ordered]@{schema_version=3;kind='rename';batch=[IO.Path]::GetFileName($batchPath);canonical_root=$canonical;root_id=$rootId;plan_sha256=$planData.Hash;plan_id=$planData.Id;entry_id=$entry.entry_id;path=$entry.path;destination=$entry.destination;parent_id=$parentId;before_directory_id=$sourceId;reason='Namespace-only preparation; no project mutation or full child-byte backup'}
            New-Json (Join-Path $batchPath 'prepare-intent.json') $intent
            $intentHash=([BathNative]::Read((Join-Path $batchPath 'prepare-intent.json'))).Hash
            Write-Lease $leasePath $intent.batch $intentHash
            [BathNative]::WriteNew((Join-Path $batchPath 'plan.json'),$planData.Bytes)
            New-Json (Join-Path $batchPath 'scope.json') @{schema_version=1;inputs=@($entry.path)}
            $ledger=Get-RenameLedger $project (Join-Path $batchPath 'scope.json') $entry
            if($ledger.directory_id-cne$sourceId){throw 'SOURCE_CHANGED: source identity differs'}
            New-Json (Join-Path $batchPath 'namespace-before.json') $ledger
            $m=[ordered]@{schema_version=3;kind='rename';batch=$intent.batch;canonical_root=$canonical;root_id=$rootId;plan_sha256=$planData.Hash;prepare_intent_sha256=$intentHash;runtime_sha256=$runtime;entry=[ordered]@{entry_id=$entry.entry_id;path=$entry.path;destination=$entry.destination;parent_id=$parentId;before_directory_id=$sourceId};backup_kind='namespace_evidence';full_byte_backup=$false;namespace_sha256=$ledger.namespace_sha256;ledger_file_sha256=([BathNative]::Read((Join-Path $batchPath 'namespace-before.json'))).Hash;phase='NAMESPACE_RENAME_COMPONENT_STAGING';execution_ready=$true;eligible_for_finalize=$false}
            New-Json (Join-Path $batchPath 'manifest.json') $m
            $md=Read-RenameJson (Join-Path $batchPath 'manifest.json') $pins;$id=Read-RenameJson (Join-Path $batchPath 'prepare-intent.json') $pins
            Assert-RenameManifest $md.value $id;[void](Read-RenameEvidence $batchPath $md.value $pins)
            [BathNative]::WriteNew((Join-Path $batchPath 'journal.jsonl'),[byte[]]@())
            New-Json (Join-Path $batchPath 'prepared.json') @{state='NamespaceSavedPreview';manifest_sha256=$md.snapshot.Hash;intent_sha256=$intentHash}
            return @{ok=$true;state='NamespaceSavedPreview';batch=$batchPath;execution_ready=$true;phase=$m.phase;namespace_sha256=$ledger.namespace_sha256;observed=(Get-RenameObserved $project $intent)}
        }
        $batchPath=Get-LocalPath $Batch
        if([IO.Path]::GetDirectoryName($batchPath)-cne$archive-or[IO.Path]::GetFileName($batchPath)-cnotmatch'^rename-[a-f0-9-]{36}$'){throw 'BAD_BATCH: rename batch must belong to project'}
        [void](Pin-Directory $batchPath $pins)
        $id=Read-RenameJson (Join-Path $batchPath 'prepare-intent.json') $pins;$intent=$id.value
        Assert-RenameIntent $intent $canonical $rootId ([IO.Path]::GetFileName($batchPath))
        $manifestPath=Join-Path $batchPath 'manifest.json';$preparedPath=Join-Path $batchPath 'prepared.json';$stopPath=Join-Path $batchPath 'stopped.json'
        $manifestHash=$null;$preparedHash=$null;$m=$null
        if([IO.File]::Exists($manifestPath)){$md=Read-RenameJson $manifestPath $pins;$manifestHash=$md.snapshot.Hash;$m=$md.value;Assert-RenameManifest $m $id}
        if([IO.File]::Exists($preparedPath)){$pd=Read-RenameJson $preparedPath $pins;$preparedHash=$pd.snapshot.Hash;Check-Keys $pd.value @('state','manifest_sha256','intent_sha256');if(!$m-or$pd.value.state-isnot[string]-or$pd.value.state-cne'NamespaceSavedPreview'-or$pd.value.manifest_sha256-isnot[string]-or$pd.value.manifest_sha256-cne$manifestHash-or$pd.value.intent_sha256-isnot[string]-or$pd.value.intent_sha256-cne$id.snapshot.Hash){throw 'BAD_PREPARED: persistent preparation binding differs'}}
        $newPhase=$m-and$m.phase-ceq'NAMESPACE_RENAME_COMPONENT_STAGING'
        $journal=if($newPhase){Read-RenameJournal $batchPath $manifestHash}else{@{hash=$null;state='';last=$null}}
        if($newPhase-and$journal.state-cin@('Applied','Restored')){
            try{
                $confirmedBefore=Read-RenameEvidence $batchPath $m $pins $false
                if($journal.state-ceq'Applied'){
                    Save-RenameAfterScope $batchPath $intent $confirmedBefore $pins
                    [void](Read-RenameAfter $batchPath $journal.last $confirmedBefore $pins)
                }elseif($journal.last.namespace_sha256-cne$m.namespace_sha256-or$journal.last.ledger_file_sha256-cne$m.ledger_file_sha256){throw 'BAD_JOURNAL: restored evidence binding differs'}
            }catch{$journal.state='Ambiguous'}
        }
        $stopped=[IO.File]::Exists($stopPath)
        if($stopped){
            $stop=(Read-RenameJson $stopPath $pins).value
            if($newPhase){Check-Keys $stop @('state','batch','intent_sha256','manifest_sha256','prepared_sha256','restored','reason','utc','journal_sha256');if($null-ne$stop.journal_sha256){Assert-RenameString $stop.journal_sha256 'journal_sha256' '^[a-f0-9]{64}$'};if($stop.journal_sha256-cne$journal.hash){throw 'BAD_STOP: retained journal changed'}}else{Check-Keys $stop @('state','batch','intent_sha256','manifest_sha256','prepared_sha256','restored','reason','utc')}
            foreach($n in @('manifest_sha256','prepared_sha256')){
                if($null-ne$stop[$n]){Assert-RenameString $stop[$n] $n '^[a-f0-9]{64}$'}
            }
            if($stop.state-isnot[string]-or$stop.state-cne'Stopped'-or$stop.batch-isnot[string]-or$stop.batch-cne$intent.batch-or$stop.intent_sha256-isnot[string]-or$stop.intent_sha256-cne$id.snapshot.Hash-or$stop.manifest_sha256-cne$manifestHash-or$stop.prepared_sha256-cne$preparedHash-or$stop.restored-isnot[bool]-or$stop.restored){throw 'BAD_STOP: terminal binding differs'}
            Assert-RenameString $stop.reason 'stop reason';Assert-RenameString $stop.utc 'stop utc'
        }elseif($journal.state-cne'Restored'-and($lease.owner-cne$intent.batch-or!$lease.Contains('intent_sha256')-or$lease.intent_sha256-cne$id.snapshot.Hash)){throw 'BAD_INTENT: only intact current owner may inspect or close'}
        if($Action-ceq'Close'){
            if($newPhase-and$journal.state-ceq'Applied'){throw 'CAPABILITY_BLOCKED: Applied batch requires Restore'}
            if(!$stopped){
                $marker=@{state='Stopped';batch=$intent.batch;intent_sha256=$id.snapshot.Hash;manifest_sha256=$manifestHash;prepared_sha256=$preparedHash;restored=$false;reason='Namespace batch stopped preserving current tree and retained evidence';utc=[DateTime]::UtcNow.ToString('o')}
                if($newPhase){$marker.journal_sha256=$journal.hash}
                New-Json $stopPath $marker
                [void][BathNative]::Read($stopPath)
            }
            if($lease.owner-ceq$intent.batch){if(!$lease.Contains('intent_sha256')-or$lease.intent_sha256-cne$id.snapshot.Hash){throw 'BAD_LEASE: owner intent changed'};Write-Lease $leasePath ''}
            return @{ok=$true;state='Stopped';batch=$batchPath;restored=$false;observed=(Get-RenameObserved $project $intent)}
        }
        $state=if($stopped){'Stopped'}elseif(!$m-or!$preparedHash){'IncompletePrepare'}elseif($journal.state){$journal.state}else{'NamespaceSavedPreview'}
        if($Action-cin@('Apply','Restore')){
            if(!$newPhase-or!$m.execution_ready){throw 'CAPABILITY_BLOCKED: preparation-only batch cannot mutate'}
            if($state-cnotin@('NamespaceSavedPreview','Applied','Restored')){throw 'AMBIGUOUS_STATE: no confirmed state for mutation'}
            $before=Read-RenameEvidence $batchPath $m $pins
            Assert-RenameScope $batchPath $intent $before $pins
            if($Action-ceq'Apply'-and$state-cne'NamespaceSavedPreview'){throw 'CAPABILITY_BLOCKED: Apply requires original prepared state'}
            if($Action-ceq'Restore'-and$state-cnotin@('Applied','Restored')){throw 'CAPABILITY_BLOCKED: Restore requires confirmed Applied'}
            $reverse=$Action-ceq'Restore'
            $from=if($reverse-and$state-cne'Restored'){$intent.destination}else{$intent.path}
            $to=if($reverse){$intent.path}else{$intent.destination}
            $expected=$before
            $parent=Get-LocalPath ([IO.Path]::GetDirectoryName((Join-Path $project $intent.path)))
            if((Pin-Directory $parent $pins)-cne$intent.parent_id){throw 'SOURCE_CHANGED: parent identity changed'}
            $handle=$null
            try{
                if($reverse-and$state-cne'Restored'){Save-RenameAfterScope $batchPath $intent $before $pins;$expected=Read-RenameAfter $batchPath $journal.last $before $pins}
                $handle=[BathNative]::DirectoryMutation((Get-LocalPath (Join-Path $project $from)))
                if([BathNative]::Id($handle)-cne$intent.before_directory_id){throw 'SOURCE_CHANGED: directory identity changed'}
                $captureEntry=@{path=$from}
                $scopeFile=if($from-ceq$intent.path){'scope.json'}else{'scope-after.json'}
                $live=Get-RenameLedger $project (Join-Path $batchPath $scopeFile) $captureEntry
                if($live.namespace_sha256-cne$expected.namespace_sha256){throw 'SOURCE_CHANGED: live child census differs'}
                if($state-ceq'Restored'){
                    return @{ok=$true;state='Restored';batch=$batchPath;execution_ready=$true;phase=$m.phase;observed=(Get-RenameObserved $project $intent)}
                }
                if(Test-Path -LiteralPath (Join-Path $project $to)){throw 'DESTINATION_EXISTS: reverse/forward destination occupied'}
                if(!$reverse){Save-RenameAfterScope $batchPath $intent $before $pins $true}
                $pending=if($reverse){'Restoring'}else{'Applying'}
                Add-RenameEvent $batchPath $manifestHash $pending
                # durable intent precedes the native no-replace rename
                [BathNative]::RenameDirectoryNoReplace($handle,(Get-LocalPath (Join-Path $project $to)))
                $postScope=if($reverse){'scope.json'}else{'scope-after.json'}
                $post=Get-RenameLedger $project (Join-Path $batchPath $postScope) @{path=$to}
                if($post.namespace_sha256-cne$before.namespace_sha256){throw 'SOURCE_CHANGED: post-rename census differs'}
                if($reverse){
                    Add-RenameEvent $batchPath $manifestHash 'Restored' $post.namespace_sha256 $m.ledger_file_sha256
                    Write-Lease $leasePath ''
                    $state='Restored'
                }else{
                    New-Json (Join-Path $batchPath 'namespace-after.json') $post
                    $afterHash=([BathNative]::Read((Join-Path $batchPath 'namespace-after.json'))).Hash
                    [void](Read-RenameAfter $batchPath @{namespace_sha256=$post.namespace_sha256;ledger_file_sha256=$afterHash} $before $pins)
                    Add-RenameEvent $batchPath $manifestHash 'Applied' $post.namespace_sha256 $afterHash
                    $state='Applied'
                }
            }catch{
                # A durable unconfirmed intent stays ambiguous: never infer which IO completed.
                $current=Read-RenameJournal $batchPath $manifestHash
                if($current.state-cin@('NamespaceSavedPreview','Applied','Restored')-or!$current.state){Add-RenameEvent $batchPath $manifestHash 'Conflict'}
                throw
            }finally{if($handle){$handle.Dispose()}}
        }elseif($state-ceq'NamespaceSavedPreview'){[void](Read-RenameEvidence $batchPath $m $pins $false)}
        return @{ok=$true;state=$state;batch=$batchPath;execution_ready=[bool]$newPhase;phase=$(if($m){$m.phase}else{'NAMESPACE_RENAME_COMPONENT_STAGING'});observed=(Get-RenameObserved $project $intent)}
    }catch{
        $message=$_.Exception.Message;$code=if($message-match'^([A-Z_]+):'){$Matches[1]}else{'PREPARATION_REFUSED'}
        return @{ok=$false;state='Refused';batch=$batchPath;error_code=$code;message=$message}
    }finally{if($lock){$lock.Dispose()};foreach($pin in $pins){$pin.Dispose()}}
}
@{ok=$false;error_code='USE_MAIN_ENTRY';message='Use bath.ps1 -Group for directory rename with associated files; standalone mutation is not supported'}|ConvertTo-Json -Compress
exit 2
