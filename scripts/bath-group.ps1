[CmdletBinding()]
param([ValidateSet('Prepare','Status','Apply','Restore','Check','Finalize','Close')][string]$Action='Status',[string]$Root,[string]$Plan,[string]$Batch,[string]$CheckScript,[string]$Receipt,[string]$Scope,[string]$ProjectName)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$script:ArchiveRoot='D:\project-bath'
$script:GroupTool=$PSCommandPath
$script:GroupScripts=$PSScriptRoot
$script:GroupMixed=$false
$script:GroupRename=$null
$script:GroupPhase='MIXED_CHECKED_STAGING'
$script:GroupExecutionReady=$false
$script:GroupEligible=$false

function Import-GroupHelpers {
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'bath.ps1'),[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'TOOL_INVALID: main helper parse failed'}
    foreach($name in @('Assert-BathProjectName','Get-BathProjectArchive','Initialize-Native','Get-LocalPath','Pin-Directory','New-PinnedDirectory','Read-PinnedFile','Get-Json','New-Json','Write-Lease','Check-Keys','Get-ScopedHash','Invoke-ScopedView','Read-RetainedEvidence','Copy-PinnedCheck','Assert-LabEvidence')) {
        $defs=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)|Where-Object Name -CEQ $name)
        if($defs.Count-ne 1){throw 'TOOL_INVALID: helper definition ambiguous'}
        # AST-created blocks have no file extent, so preserve the trusted helper directory explicitly.
        . ([scriptblock]::Create($defs[0].Extent.Text.Replace('$PSScriptRoot','$script:GroupScripts')))
        Set-Item "function:script:$name" (Get-Item "function:$name").ScriptBlock
    }
    Initialize-Native
}

function Import-GroupNamespaceHelpers {
    $tokens=$null;$errors=$null
    $renameAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'bath-rename.ps1'),[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'TOOL_INVALID: rename helpers parse failed'}
    foreach($name in @('Assert-RenameDirectoryStreams','Get-RenameLedger','Get-RenameObserved')){
        $defs=@($renameAst.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]},$false)|Where-Object Name -CEQ $name)
        if($defs.Count-ne 1){throw 'TOOL_INVALID: namespace helper ambiguous'}
        . ([scriptblock]::Create($defs[0].Extent.Text))
        Set-Item "function:script:$name" (Get-Item "function:$name").ScriptBlock
    }
}

function Convert-GroupReceipt([byte[]]$Bytes) {
    $json=[Text.UTF8Encoding]::new($false,$true).GetString($Bytes)
    $doc=[Text.Json.JsonDocument]::Parse($json)
    try{
        Assert-ScopeJson $doc.RootElement
        $receipt=ConvertFrom-Json $json -AsHashtable -Depth 30
        # PS7.4-compatible: preserve the producer's ISO UTC strings and fractional precision.
        foreach($p in $doc.RootElement.EnumerateObject()){if($p.Value.ValueKind-eq'String'){$receipt[$p.Name]=$p.Value.GetString()}}
        return $receipt
    }finally{$doc.Dispose()}
}

function Get-GroupRuntime($Pins) {
    $hashes=[ordered]@{}
    foreach($name in @('bath.ps1','bath-scope.ps1','bath-view.ps1','bath-group.ps1')){$hashes[$name]=(Read-PinnedFile (Join-Path $PSScriptRoot $name) $Pins).Hash}
    if($script:GroupMixed){$hashes['bath-rename.ps1']=(Read-PinnedFile (Join-Path $PSScriptRoot 'bath-rename.ps1') $Pins).Hash}
    return $hashes
}

function Assert-GroupRuntime($Expected,$Pins) {
    $keys=@('bath.ps1','bath-scope.ps1','bath-view.ps1','bath-group.ps1');if($script:GroupMixed){$keys+=,'bath-rename.ps1'}
    Check-Keys $Expected $keys
    $current=Get-GroupRuntime $Pins
    foreach($n in $current.Keys){if($Expected[$n]-cne $current[$n]){throw 'TOOL_CHANGED: group runtime changed; safe Restore remains available'}}
}

function Read-GroupPlan([byte[]]$Bytes) {
    . (Join-Path $PSScriptRoot 'bath-scope.ps1')
    $json=[Text.UTF8Encoding]::new($false,$true).GetString($Bytes)
    $doc=[Text.Json.JsonDocument]::Parse($json)
    try{Assert-ScopeJson $doc.RootElement}finally{$doc.Dispose()}
    $p=ConvertFrom-Json $json -AsHashtable -Depth 20
    if(($p.schema_version-isnot[int]-and$p.schema_version-isnot[long])-or$p.schema_version-cnotin@(2,4)-or$p.entries-isnot[array]-or!$p.entries.Count){throw 'BAD_SCHEMA: group requires integer schema2/4 and nonempty entries'}
    $script:GroupMixed=$p.schema_version-eq 4;$script:GroupRename=$null
    if($script:GroupMixed){
        Check-Keys $p @('schema_version','rename','entries');Check-Keys $p.rename @('entry_id','path','destination','evidence')
        $r=$p.rename;Assert-ScopeRelative $r.path;Assert-ScopeRelative $r.destination
        if($r.entry_id-isnot[string]-or$r.entry_id-cnotmatch'^[a-z][a-z0-9_-]{0,63}$'-or$r.evidence-isnot[string]-or!$r.evidence.Trim()-or$r.path.Equals($r.destination,[StringComparison]::OrdinalIgnoreCase)-or[IO.Path]::GetDirectoryName($r.path)-ine[IO.Path]::GetDirectoryName($r.destination)){throw 'BAD_SCHEMA: one ordinary same-parent rename required'}
        $script:GroupRename=$r
    }else{Check-Keys $p @('schema_version','entries')}
    $ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $paths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if($script:GroupMixed){[void]$ids.Add($script:GroupRename.entry_id)}
    foreach($e in $p.entries){
        Check-Keys $e @('entry_id','path','action','before_sha256','after_sha256','evidence') @('replacement_path')
        Assert-ScopeRelative $e.path
        if($e.entry_id-isnot[string]-or$e.entry_id-cnotmatch'^[a-z][a-z0-9_-]{0,63}$'-or!$ids.Add($e.entry_id)-or!$paths.Add($e.path)){throw 'BAD_SCHEMA: stable unique entry ID/path required'}
        if($e.action-isnot[string]-or$e.action-cnotin@('edit','archive')-or$e.before_sha256-isnot[string]-or$e.before_sha256-cnotmatch'^[a-f0-9]{64}$'-or$e.after_sha256-isnot[string]-or$e.evidence-isnot[string]-or!$e.evidence.Trim()){throw 'BAD_SCHEMA: invalid entry'}
        if($script:GroupMixed-and((Test-ScopeUnder $e.path $script:GroupRename.destination)-or$e.path.Equals($script:GroupRename.path,[StringComparison]::OrdinalIgnoreCase))){throw 'BAD_SCHEMA: original file path required'}
        if($e.action-eq'archive'){
            if($e.after_sha256-cne'absent'-or$e.Contains('replacement_path')){throw 'BAD_SCHEMA: archive requires absent and no replacement'}
        }elseif(!$e.Contains('replacement_path')-or$e.replacement_path-isnot[string]-or$e.after_sha256-cnotmatch'^[a-f0-9]{64}$'){throw 'BAD_SCHEMA: edit requires replacement'}
    }
    return ,$p.entries
}

function Assert-GroupBudget($Snapshot,$Sources) {
    [long]$total=$Snapshot.stats.total_bytes
    foreach($source in $Sources){
        if($source.replacement){
            if($source.replacement.Bytes.Length-gt$Snapshot.limits.max_file_bytes){throw 'SCOPE_LIMIT: replacement file limit'}
            $total+=$source.replacement.Bytes.Length-$source.original.Bytes.Length
        }else{$total-=$source.original.Bytes.Length}
    }
    if($total-gt$Snapshot.limits.max_total_bytes){throw 'SCOPE_LIMIT: replacement total limit'}
}

function Assert-GroupIntent($Data,$Manifest,$Canonical,$RootId,$Lease) {
    $intent=ConvertFrom-Json ([Text.Encoding]::UTF8.GetString($Data.Bytes)) -AsHashtable -Depth 25
    $keys=@('schema_version','kind','batch','canonical_root','root_id','plan_sha256','plan_id','targets','reason');if($script:GroupMixed){$keys+=,'rename'};Check-Keys $intent $keys
    if($Data.Hash-cne$Manifest.prepare_intent_sha256-or$intent.schema_version-ne$Manifest.schema_version-or$intent.kind-cne$Manifest.kind-or$intent.batch-cne$Manifest.batch-or$intent.canonical_root-cne$Canonical-or$intent.root_id-cne$RootId-or$intent.plan_sha256-cne$Manifest.plan_sha256-or$intent.targets.Count-ne$Manifest.entries.Count){throw 'BAD_INTENT: original group intent binding changed'}
    if($script:GroupMixed){Check-Keys $intent.rename @('entry_id','path','destination','parent_id','before_directory_id');foreach($k in $intent.rename.Keys){if($intent.rename[$k]-cne$Manifest.rename[$k]){throw 'BAD_INTENT: namespace intent differs'}}}
    for($i=0;$i-lt$Manifest.entries.Count;$i++){
        $e=$Manifest.entries[$i];$t=$intent.targets[$i]
        $tk=@('entry_id','path','before_sha256');if($script:GroupMixed){$tk+=,'path_after'};Check-Keys $t $tk
        if($t.entry_id-cne$e.entry_id-or$t.path-cne$e.path-or$t.before_sha256-cne$e.before_sha256){throw 'BAD_INTENT: target list differs'}
        if($script:GroupMixed-and$t.path_after-cne$e.path_after){throw 'BAD_INTENT: projected path differs'}
    }
    if($Lease.owner-ceq$Manifest.batch-and$Lease.intent_sha256-cne$Data.Hash){throw 'BAD_INTENT: owner lease intent differs'}
}

function Write-GroupEvent([string]$Path,[string]$State,[string]$ManifestHash,[string]$EntryId='',[string]$TargetId='',[long]$WriteTime=0,[string]$ReceiptName='',[string]$ReceiptHash='',[string]$OperationEventId='',[string]$NamespaceHash='',[string]$LedgerHash='',[string]$CheckAttempt='',[switch]$ReturnId) {
    $data=[ordered]@{event_id=[Guid]::NewGuid().ToString('N');utc=[DateTime]::UtcNow.ToString('o');manifest_sha256=$ManifestHash;state=$State}
    if($EntryId){$data.entry_id=$EntryId;$data.target_id=$TargetId;$data.write_time=$WriteTime.ToString()}
    if($ReceiptName){$data.receipt_name=$ReceiptName;$data.receipt_sha256=$ReceiptHash}
    if($OperationEventId){$data.operation_event_id=$OperationEventId};if($NamespaceHash){$data.namespace_sha256=$NamespaceHash;$data.ledger_file_sha256=$LedgerHash};if($CheckAttempt){$data.check_attempt_event_id=$CheckAttempt}
    $f=[IO.FileStream]::new((Join-Path $Path 'journal.jsonl'),[IO.FileMode]::Append,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try{[BathNative]::Regular($f.SafeFileHandle);$b=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $data -Compress)+"`n");$f.Write($b);$f.Flush($true)}finally{$f.Dispose()}
    if($ReturnId){return $data.event_id}
}

function Get-GroupMappedPath([string]$Path,$Rename) {
    if($Path.Equals($Rename.path,[StringComparison]::OrdinalIgnoreCase)){return $Rename.destination}
    if($Path.StartsWith($Rename.path+'/',[StringComparison]::OrdinalIgnoreCase)){return $Rename.destination+$Path.Substring($Rename.path.Length)}
    return $Path
}
function Get-GroupComparisonHash($Snapshot) {
    $copy=ConvertFrom-Json (ConvertTo-Json $Snapshot -Depth 30) -AsHashtable -Depth 30
    $copy.files=@($copy.files|Sort-Object @{Expression={$_['path']}} -CaseSensitive)
    $copy.directories=@($copy.directories|Sort-Object @{Expression={$_['path']}} -CaseSensitive)
    return Get-ScopedHash $copy
}
function Get-GroupAfterScope($Scope,$Rename) {
    $mapped=ConvertFrom-Json (ConvertTo-Json $Scope -Depth 30) -AsHashtable
    $mapped.inputs=@($mapped.inputs|ForEach-Object{Get-GroupMappedPath $_ $Rename})
    if($mapped.Contains('excluded')){foreach($e in $mapped.excluded){$e.path=Get-GroupMappedPath $e.path $Rename}}
    if($mapped.Contains('outputs')){$mapped.outputs=@($mapped.outputs|ForEach-Object{Get-GroupMappedPath $_ $Rename})}
    $lists=@(,@($mapped.inputs));if($mapped.Contains('outputs')){$lists+=,@($mapped.outputs)}
    foreach($list in $lists){$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);foreach($value in $list){if(!$seen.Add($value)){throw 'BAD_SCOPE: mapped selector collision'}}}
    return $mapped
}
function Get-GroupNamespace([string]$Project,[string]$Path,[string]$Relative,$Limits) {
    $scope=Join-Path $Path ('namespace-scope-'+[BathNative]::Hash([Text.Encoding]::UTF8.GetBytes($Relative))+'.json')
    $body=[ordered]@{schema_version=1;inputs=@($Relative);limits=$Limits}
    if(![IO.File]::Exists($scope)){New-Json $scope $body}
    if((ConvertTo-Json (Get-Json $scope) -Compress -Depth 20)-cne(ConvertTo-Json $body -Compress -Depth 20)){throw 'BAD_SCOPE: full namespace selection changed'}
    return Get-RenameLedger $Project $scope @{path=$Relative}
}
function Get-GroupNamespaceHash($Ledger) {
    $data=[ordered]@{};foreach($k in $Ledger.Keys){if($k-cne'namespace_sha256'){$data[$k]=$Ledger[$k]}}
    return [BathNative]::Hash([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $data -Compress -Depth 30)))
}
function Read-GroupNamespaceBefore($M,[string]$Path,$Pins) {
    $raw=Read-PinnedFile (Join-Path $Path 'namespace-before.json') $Pins
    $l=ConvertFrom-Json ([Text.Encoding]::UTF8.GetString($raw.Bytes)) -AsHashtable -Depth 30
    Check-Keys $l @('schema_version','directory_id','directories','files','limits','stats','namespace_sha256')
    if($raw.Hash-cne$M.rename.ledger_file_sha256-or$l.namespace_sha256-cne$M.rename.namespace_sha256-or(Get-GroupNamespaceHash $l)-cne$l.namespace_sha256-or$l.directory_id-cne$M.rename.before_directory_id){throw 'BAD_LEDGER: frozen namespace differs'}
    return $l
}
function Get-GroupExpectedNamespace($M,$Before,$Projection,[bool]$Restoring=$false) {
    $l=ConvertFrom-Json (ConvertTo-Json $Before -Depth 30) -AsHashtable -Depth 30
    foreach($e in $M.entries){
        if(!(Test-ScopeUnder $e.path $M.rename.path)){continue}
        $relative=$e.path.Substring($M.rename.path.Length+1);$row=@($Projection.entries|Where-Object entry_id -CEQ $e.entry_id)[0]
        $file=@($l.files|Where-Object{$_.path.Equals($relative,[StringComparison]::OrdinalIgnoreCase)})
        if($file.Count-ne 1){throw 'BAD_LEDGER: target missing from original namespace'}
        if($row.restored){$file[0].id=$row.restored.target_id;$file[0].write_time=$row.restored.write_time}
        elseif($row.applied){
            if($Restoring){throw 'RESTORE_CONFLICT: file not restored before namespace reversal'}
            if($e.action-eq'archive'){$l.files=@($l.files|Where-Object{!$_.path.Equals($relative,[StringComparison]::OrdinalIgnoreCase)})}
            else{$file[0].sha256=$e.after_sha256;$file[0].bytes=$e.after_bytes;$file[0].id=$row.applied.target_id;$file[0].write_time=$row.applied.write_time}
        }
        if($row.state-in@('UnconfirmedApply','UnconfirmedRestore','Conflict')){throw 'RESTORE_CONFLICT: ambiguous file transition'}
    }
    $l.stats.files=$l.files.Count;$l.stats.total_bytes=[long]0;foreach($f in $l.files){$l.stats.total_bytes+=$f.bytes}
    $l.namespace_sha256=Get-GroupNamespaceHash $l;return $l
}
function Assert-GroupNamespaceCurrent($M,[string]$Path,[string]$Project,$Pins,$Projection,[bool]$Restoring=$false,[bool]$AtOriginal=$false) {
    $before=Read-GroupNamespaceBefore $M $Path $Pins
    $expected=Get-GroupExpectedNamespace $M $before $Projection $Restoring
    $relative=if($AtOriginal){$M.rename.path}else{$M.rename.destination}
    $actual=Get-GroupNamespace $Project $Path $relative $before.limits
    if($actual.namespace_sha256-cne$expected.namespace_sha256){throw 'SOURCE_CHANGED: complete namespace differs from confirmed transition'}
    return $actual
}
function Invoke-GroupNamespaceRename($M,[string]$Path,[string]$Project,$Pins,[string]$ManifestHash,$Projection,[bool]$Reverse=$false) {
    $before=Read-GroupNamespaceBefore $M $Path $Pins
    $expected=if($Reverse){Get-GroupExpectedNamespace $M $before $Projection $true}else{$before}
    $from=if($Reverse){$M.rename.destination}else{$M.rename.path};$to=if($Reverse){$M.rename.path}else{$M.rename.destination}
    if((Pin-Directory ([IO.Path]::GetDirectoryName((Join-Path $Project $from))) $Pins)-cne$M.rename.parent_id){throw 'PARENT_CHANGED: namespace parent changed'}
    $h=[BathNative]::DirectoryMutation((Get-LocalPath (Join-Path $Project $from)))
    try{
        if([BathNative]::Id($h)-cne$M.rename.before_directory_id){throw 'SOURCE_CHANGED: namespace directory changed'}
        $live=Get-GroupNamespace $Project $Path $from $before.limits
        if($live.namespace_sha256-cne$expected.namespace_sha256){throw 'SOURCE_CHANGED: namespace census changed'}
        if(Test-Path -LiteralPath (Join-Path $Project $to)){throw 'DESTINATION_EXISTS: namespace destination occupied'}
        $state=if($Reverse){'Restoring'}else{'Applying'}
        $op=Write-GroupEvent $Path $state $ManifestHash $M.rename.entry_id $M.rename.before_directory_id -ReturnId
        [BathNative]::RenameDirectoryNoReplace($h,(Get-LocalPath (Join-Path $Project $to)))
        $post=Get-GroupNamespace $Project $Path $to $before.limits
        if($post.namespace_sha256-cne$expected.namespace_sha256){throw 'SOURCE_CHANGED: renamed census differs'}
        $name=if($Reverse){'namespace-restored.json'}else{'namespace-after.json'};New-Json (Join-Path $Path $name) $post
        $raw=Read-PinnedFile (Join-Path $Path $name) $Pins
        $confirmed=if($Reverse){'Restored'}else{'Applied'}
        Write-GroupEvent $Path $confirmed $ManifestHash $M.rename.entry_id $M.rename.before_directory_id -OperationEventId $op -NamespaceHash $post.namespace_sha256 -LedgerHash $raw.Hash
    }finally{$h.Dispose()}
}

function Read-GroupEvents([string]$Path,[string]$Hash,$M) {
    $raw=[Text.UTF8Encoding]::new($false,$true).GetString(([BathNative]::Read((Join-Path $Path 'journal.jsonl'))).Bytes)
    if(!$raw.EndsWith("`n")){throw 'INCOMPLETE_JOURNAL: preserve group; automatic writes refused'}
    $events=@($raw.TrimEnd("`n").Split("`n")|ForEach-Object{
        $doc=[Text.Json.JsonDocument]::Parse($_)
        try{Assert-ScopeJson $doc.RootElement;$row=ConvertFrom-Json $_ -AsHashtable;foreach($property in $doc.RootElement.EnumerateObject()){if($property.Value.ValueKind-eq'String'){$row[$property.Name]=$property.Value.GetString()}};$row}finally{$doc.Dispose()}
    })
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$pending=@{};$latestAttempt=''
    $known=@($M.entries.entry_id);if($script:GroupMixed){$known+=,$M.rename.entry_id}
    $life=@{};foreach($id in $known){$life[$id]='Untouched'};$global='';$confirmedApplied=@{};$confirmedRestored=@{}
    foreach($e in $events){
        Check-Keys $e @('event_id','utc','manifest_sha256','state') @('entry_id','target_id','write_time','receipt_name','receipt_sha256','operation_event_id','namespace_sha256','ledger_file_sha256','check_attempt_event_id')
        foreach($k in $e.Keys){if($e[$k]-isnot[string]){throw 'BAD_JOURNAL: strict scalar strings required'}}
        if($e.event_id-cnotmatch'^[a-f0-9]{32}$'-or$e.manifest_sha256-cnotmatch'^[a-f0-9]{64}$'){throw 'BAD_JOURNAL: event/hash syntax'}
        [void][DateTimeOffset]::Parse($e.utc)
        if($e.Contains('write_time')-and$e.write_time-cnotmatch'^[0-9]+$'){throw 'BAD_JOURNAL: write time syntax'}
        if($e.event_id-isnot[string]-or!$seen.Add($e.event_id)-or$e.manifest_sha256-cne$Hash-or$e.state-cnotin@('BackedUp','Applying','Applied','Restoring','Restored','Conflict','CheckStarted','Checked','Completed','Stopped')){throw 'BAD_JOURNAL: group binding/state mismatch'}
        if($e.Contains('entry_id')-and$e.entry_id-cnotin$known){throw 'BAD_JOURNAL: unknown entry'}
        if($e.state-ceq'CheckStarted'){$latestAttempt=$e.event_id}
        # Old schema2 journals remain inspectable/restorable; current-runtime Finalize still requires a new bound attempt.
        if($e.state-ceq'Checked'-and($script:GroupMixed-or$latestAttempt-or$e.Contains('check_attempt_event_id'))-and(!$latestAttempt-or!$e.Contains('check_attempt_event_id')-or$e.check_attempt_event_id-cne$latestAttempt)){throw 'BAD_JOURNAL: latest check attempt mismatch'}
        if($script:GroupMixed-and$e.Contains('entry_id')){
            if($e.state-in@('Applying','Restoring')){
                $isApply=$e.state-eq'Applying'
                if($pending.Contains($e.entry_id)-or($isApply-and($life[$e.entry_id]-cne'Untouched'-or$global-cne'Applying'))-or(!$isApply-and(!$confirmedApplied.Contains($e.entry_id)-or$confirmedRestored.Contains($e.entry_id)-or$global-cne'Restoring'))){throw 'BAD_JOURNAL: entry intent outside lifecycle'}
                if($isApply-and$e.entry_id-cne$M.rename.entry_id-and!$confirmedApplied.Contains($M.rename.entry_id)){throw 'BAD_JOURNAL: file intent before namespace confirmation'}
                if(!$isApply-and$e.entry_id-ceq$M.rename.entry_id){foreach($id in $M.entries.entry_id){if($confirmedApplied.Contains($id)-and!$confirmedRestored.Contains($id)){throw 'BAD_JOURNAL: namespace reversal before file restores'}}}
                $pending[$e.entry_id]=$e;$life[$e.entry_id]=$e.state
            }
            elseif($e.state-in@('Applied','Restored')){
                $intent=if($pending.Contains($e.entry_id)){$pending[$e.entry_id]}else{$null}
                $want=if($e.state-eq'Applied'){'Applying'}else{'Restoring'}
                if(!$intent-or$intent.state-cne$want-or!$e.Contains('operation_event_id')-or$e.operation_event_id-cne$intent.event_id){throw 'BAD_JOURNAL: confirmation has no exact intent'}
                $pending.Remove($e.entry_id)
                $life[$e.entry_id]=$e.state
                if($e.state-eq'Applied'){$confirmedApplied[$e.entry_id]=$e}else{$confirmedRestored[$e.entry_id]=$e}
                if($e.entry_id-ceq$M.rename.entry_id-and(!$e.Contains('namespace_sha256')-or!$e.Contains('ledger_file_sha256')-or$e.target_id-cne$M.rename.before_directory_id)){throw 'BAD_JOURNAL: namespace confirmation evidence missing'}
            }
            elseif($e.state-eq'Conflict'){$life[$e.entry_id]='Conflict'}
            else{throw 'BAD_JOURNAL: invalid entry event state'}
        }elseif($script:GroupMixed){
            switch($e.state){
                'BackedUp' {if($global){throw 'BAD_JOURNAL: duplicate backup terminal'}}
                'Applying' {if($global-cne'BackedUp'){throw 'BAD_JOURNAL: duplicate/out-of-order global Apply'}}
                'Applied' {if($global-cne'Applying'-or$pending.Count-or$confirmedApplied.Count-ne$known.Count){throw 'BAD_JOURNAL: global Applied without complete confirmations'}}
                'Restoring' {if($global-cnotin@('Applying','Applied','Checked','CheckStarted','Completed','Conflict','Restoring')){throw 'BAD_JOURNAL: global restore state'}}
                'Restored' {if($global-cne'Restoring'-or$pending.Count-or!$confirmedRestored.Contains($M.rename.entry_id)){throw 'BAD_JOURNAL: incomplete namespace reversal'};foreach($id in $confirmedApplied.Keys){if(!$confirmedRestored.Contains($id)){throw 'BAD_JOURNAL: incomplete file restoration'}}}
                'CheckStarted' {if($global-cnotin@('Applied','Checked','CheckStarted')-or$confirmedApplied.Count-ne$known.Count-or$confirmedRestored.Count-or$pending.Count){throw 'BAD_JOURNAL: Check before complete Apply'}}
                'Checked' {if($global-cne'CheckStarted'){throw 'BAD_JOURNAL: Check confirmation without latest attempt'}}
                'Completed' {if($global-cne'Checked'-or!$e.Contains('check_attempt_event_id')-or$e.check_attempt_event_id-cne$latestAttempt){throw 'BAD_JOURNAL: completion before latest Check'}}
                'Conflict' {if(!$global-or$global-in@('Restored','Stopped')){throw 'BAD_JOURNAL: conflict outside active lifecycle'}}
                default {throw 'BAD_JOURNAL: unsupported global lifecycle'}
            }
            $global=$e.state
        }
    }
    return ,$events
}

function Get-GroupProjection($Events,$M) {
    $items=@()
    $entries=@($M.entries);if($script:GroupMixed){$entries+=,$M.rename}
    foreach($entry in $entries){
        $rows=@($Events|Where-Object{ $_.Contains('entry_id')-and$_.entry_id-ceq$entry.entry_id })
        $last=if($rows.Count){$rows[-1]}else{$null}
        $applied=@($rows|Where-Object state -eq 'Applied')
        $restored=@($rows|Where-Object state -eq 'Restored')
        $unconfirmed=@($rows|Where-Object state -in @('Applying','Restoring'))
        $state=if(!$last){'Untouched'}elseif($last.state-eq'Applying'){'UnconfirmedApply'}elseif($last.state-eq'Restoring'){'UnconfirmedRestore'}else{$last.state}
        if($unconfirmed.Count){$pending=$unconfirmed[-1];$confirmed=if($pending.state-eq'Applying'){'Applied'}else{'Restored'};if(!@($rows|Where-Object{ $_.state-eq$confirmed-and[DateTimeOffset]::Parse($_.utc)-ge[DateTimeOffset]::Parse($pending.utc)}).Count){$state=if($pending.state-eq'Applying'){'UnconfirmedApply'}else{'UnconfirmedRestore'}}}
        $items+=,[ordered]@{entry_id=$entry.entry_id;state=$state;applied=if($applied.Count){$applied[-1]}else{$null};restored=if($restored.Count){$restored[-1]}else{$null}}
    }
    $global=@($Events|Where-Object{!$_.Contains('entry_id')})[-1]
    $state=$global.state
    if($state-eq'Applying'){$state='InterruptedApply'}
    if($state-eq'Restoring'){$state='InterruptedRestore'}
    if($state-eq'CheckStarted'){$state='CheckInterrupted'}
    if(@($items|Where-Object state -eq 'UnconfirmedApply').Count){$state='InterruptedApply'}
    if(@($items|Where-Object state -eq 'UnconfirmedRestore').Count){$state='InterruptedRestore'}
    return [ordered]@{state=$state;entries=$items;last=$Events[-1]}
}

function Read-GroupScope($M,[string]$Path,[string]$Project,$Pins,$Projection=$null) {
    Assert-GroupRuntime $M.runtime_sha256 $Pins
    . (Join-Path $PSScriptRoot 'bath-scope.ps1')
    $scopePath=Join-Path $Path 'scope.json';$s=Read-PinnedFile $scopePath $Pins
    if($s.Hash-cne$M.check_scope.scope_sha256-or$s.Id-cne$M.check_scope.scope_id-or$s.WriteTime.ToString()-cne$M.check_scope.scope_write_time){throw 'SCOPE_CHANGED: saved scope changed'}
    $b=Read-PinnedFile (Join-Path $Path 'scope-before.json') $Pins
    if($b.Hash-cne$M.check_scope.before_snapshot_sha256){throw 'SCOPE_CHANGED: before snapshot changed'}
    $expected=ConvertFrom-Json ([Text.Encoding]::UTF8.GetString($b.Bytes)) -AsHashtable -Depth 25
    if((Get-ScopedHash $expected)-cne$expected.snapshot_sha256){throw 'BAD_SCOPE: before fingerprint invalid'}
    if($script:GroupMixed){
        $after=Read-PinnedFile (Join-Path $Path 'scope-after.json') $Pins
        if($after.Hash-cne$M.check_scope.after_scope_sha256-or$after.Id-cne$M.check_scope.after_scope_id-or$after.WriteTime.ToString()-cne$M.check_scope.after_scope_write_time){throw 'SCOPE_CHANGED: mapped scope changed'}
        $derived=Get-GroupAfterScope (ConvertFrom-Json ([Text.Encoding]::UTF8.GetString($s.Bytes)) -AsHashtable -Depth 30) $M.rename
        if((ConvertTo-Json $derived -Compress -Depth 30)-cne(ConvertTo-Json (ConvertFrom-Json ([Text.Encoding]::UTF8.GetString($after.Bytes)) -AsHashtable -Depth 30) -Compress -Depth 30)){throw 'SCOPE_CHANGED: mapped scope is not original projection'}
        if($Projection){
            foreach($f in $expected.files){$f.path=Get-GroupMappedPath $f.path $M.rename};foreach($d in $expected.directories){$d.path=Get-GroupMappedPath $d.path $M.rename}
            foreach($x in $expected.excluded){$x.path=Get-GroupMappedPath $x.path $M.rename};$expected.outputs=@($expected.outputs|ForEach-Object{Get-GroupMappedPath $_ $M.rename})
            $scopePath=Join-Path $Path 'scope-after.json';$expected.scope_sha256=$after.Hash
            [void](Assert-GroupNamespaceCurrent $M $Path $Project $Pins $Projection)
        }
    }
    if($Projection){
        foreach($entry in $M.entries){
            $row=@($Projection.entries|Where-Object entry_id -CEQ $entry.entry_id)[0]
            if(!$row.applied-or$row.restored-or$row.state-cne'Applied'){throw 'BAD_STATE: all group entries need confirmed Apply'}
            $relative=if($script:GroupMixed){$entry.path_after}else{$entry.path}
            $file=@($expected.files|Where-Object{$_.path.Equals($relative,[StringComparison]::OrdinalIgnoreCase)})[0];$expected.stats.total_bytes-=$file.bytes
            if($entry.action-eq'archive'){$expected.files=@($expected.files|Where-Object{!$_.path.Equals($relative,[StringComparison]::OrdinalIgnoreCase)})}else{$file.sha256=$entry.after_sha256;$file.id=$row.applied.target_id;$file.write_time=$row.applied.write_time;$file.bytes=$entry.after_bytes;$expected.stats.total_bytes+=$file.bytes}
        }
        $expected.stats.files=$expected.files.Count
    }
    $protected=if($script:GroupMixed-and$Projection){@($M.entries.path_after)}else{@($M.entries.path)}
    $actual=Read-BathScope -Root $Project -Scope $scopePath -ProtectedPaths $protected
    $match=if($script:GroupMixed){(Get-GroupComparisonHash $actual)-ceq(Get-GroupComparisonHash $expected)}else{$actual.snapshot_sha256-ceq(Get-ScopedHash $expected)}
    if(!$match){throw 'SCOPE_CHANGED: selected state differs from group transition'}
    return $actual
}

function Invoke-GroupBath {
    $pins=[Collections.Generic.List[IDisposable]]::new();$sourcePins=[Collections.Generic.List[IDisposable]]::new();$lock=$null;$batchPath=$null;$sources=[Collections.Generic.List[object]]::new()
    try{
        Import-GroupHelpers
        . (Join-Path $PSScriptRoot 'bath-scope.ps1')
        if(!$IsWindows-or$PSVersionTable.PSVersion-lt[version]'7.4'){throw 'UNSUPPORTED_HOST: Windows PowerShell7.4+ required'}
        $project=Get-LocalPath $Root;$rootId=Pin-Directory $project $pins
        $canonical=$project.Replace('\','/').ToLowerInvariant()
        if($canonical-eq'd:/project-bath'-or$canonical.StartsWith('d:/project-bath/')){throw 'BAD_ROOT: archive cannot be project'}
        $hash=[BathNative]::Hash([Text.Encoding]::UTF8.GetBytes($canonical))
        $archive=Get-BathProjectArchive $project $hash $rootId $pins
        if($Scope-and$Action-ne'Prepare'){throw 'BAD_SCOPE: scope frozen on Prepare'}
        if($Action-eq'Prepare'){
            . (Join-Path $PSScriptRoot 'bath-scope.ps1')
            $planPath=Get-LocalPath $Plan;[void](Pin-Directory ([IO.Path]::GetDirectoryName($planPath)) $pins)
            $planData=Read-PinnedFile $planPath $pins;$entries=Read-GroupPlan $planData.Bytes
            if($script:GroupMixed){Import-GroupNamespaceHelpers}
            $runtime=Get-GroupRuntime $pins
            $rename=$script:GroupRename;$renameRecord=$null
            if($script:GroupMixed){
                $source=Get-LocalPath (Join-Path $project $rename.path);$destination=Get-LocalPath (Join-Path $project $rename.destination)
                if(Test-Path -LiteralPath $destination){throw 'DESTINATION_EXISTS: rename target occupied'}
                $parent=Pin-Directory ([IO.Path]::GetDirectoryName($source)) $pins;Assert-ScopeAcl $source
                $id=Pin-Directory $source $sourcePins;Assert-RenameDirectoryStreams $source
                $renameRecord=[ordered]@{entry_id=$rename.entry_id;path=$rename.path;destination=$rename.destination;parent_id=$parent;before_directory_id=$id}
            }
            if($Scope){$scopePath=Get-LocalPath $Scope;$scopeData=Read-PinnedFile $scopePath $pins;$scopeBytes=$scopeData.Bytes}
            else{$scopeBytes=[Text.Encoding]::UTF8.GetBytes('{"schema_version":1,"inputs":["."]}');$scopePath=$null}
            # Scope reader needs a file: default scope is written only in this new owned group after lease setup.
            if($scopePath){$beforeScope=Read-BathScope -Root $project -Scope $scopePath -ProtectedPaths @($entries.path)}
            else{$beforeScope=$null}
            if($beforeScope){foreach($f in $beforeScope.files){foreach($o in $beforeScope.outputs){if(Test-ScopeUnder $f.path $o){throw 'VIEW_SCOPE_CONFLICT: source/output intersection'}}}}
            $scopeObject=ConvertFrom-Json ([Text.Encoding]::UTF8.GetString($scopeBytes)) -AsHashtable
            foreach($entry in $entries){
                if($entry.action-eq'archive'-and@($scopeObject.inputs|Where-Object{ $_.Equals($entry.path,[StringComparison]::OrdinalIgnoreCase) }).Count){throw 'SCOPE_ARCHIVE_SELECTOR: select existing parent/root'}
                $target=Get-LocalPath (Join-Path $project $entry.path);$parent=Pin-Directory ([IO.Path]::GetDirectoryName($target)) $sourcePins;Assert-ScopeAcl $target
                $original=Read-PinnedFile $target $sourcePins
                if($original.Hash-cne$entry.before_sha256){throw 'TARGET_CHANGED: before bytes differ'}
                $replacement=$null
                if($entry.action-eq'edit'){$rp=Get-LocalPath $entry.replacement_path;[void](Pin-Directory ([IO.Path]::GetDirectoryName($rp)) $pins);$replacement=Read-PinnedFile $rp $pins;if($replacement.Hash-cne$entry.after_sha256){throw 'PAYLOAD_CHANGED: replacement differs'}}
                $sources.Add(@{entry=$entry;original=$original;replacement=$replacement;parent=$parent})
            }
            if($beforeScope){Assert-GroupBudget $beforeScope $sources}
        }
        if($Action-eq'Prepare'){New-PinnedDirectory 'D:/project-bath' $pins;New-PinnedDirectory $archive $pins}else{[void](Pin-Directory $archive $pins)}
        if($Action-ne'Status') {
            $lockPath=Join-Path $archive 'operation.lock';if([IO.File]::Exists($lockPath)){[void][BathNative]::Read($lockPath)}
            $lock=[IO.FileStream]::new($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None);[BathNative]::Regular($lock.SafeFileHandle)
        }
        $identity=Join-Path $archive 'project.json';$leasePath=Join-Path $archive 'lease.json'
        if(![IO.File]::Exists($identity)){if($Action-ne'Prepare'){throw 'BAD_PROJECT: missing identity'};New-Json $identity @{canonical_root=$canonical;root_sha256=$hash;root_id=$rootId}}
        $owner=Get-Json $identity
        if($owner.canonical_root-cne$canonical-or$owner.root_sha256-cne$hash-or$owner.root_id-cne$rootId){throw 'BAD_PROJECT: identity mismatch'}
        if($Action-eq'Prepare'){
            if([IO.File]::Exists($leasePath)-and(Get-Json $leasePath).owner){throw 'PROJECT_BUSY: another batch owns project'}
            $batchPath=Join-Path $archive ('group-'+[Guid]::NewGuid().ToString());New-PinnedDirectory $batchPath $pins
            $intent=[ordered]@{schema_version=2;kind='group';batch=[IO.Path]::GetFileName($batchPath);canonical_root=$canonical;root_id=$rootId;plan_sha256=$planData.Hash;plan_id=$planData.Id;targets=@($entries|ForEach-Object{[ordered]@{entry_id=$_.entry_id;path=$_.path;before_sha256=$_.before_sha256}});reason='All group bytes must be backed up before any project write'}
            if($script:GroupMixed){$intent.schema_version=4;$intent.kind='mixed';$intent.rename=$renameRecord;foreach($t in $intent.targets){$t.path_after=Get-GroupMappedPath $t.path $rename}}
            $intentPath=Join-Path $batchPath 'prepare-intent.json';New-Json $intentPath $intent
            Write-Lease $leasePath $intent.batch ([BathNative]::Read($intentPath)).Hash
            [BathNative]::WriteNew((Join-Path $batchPath 'scope.json'),$scopeBytes)
            $saved=Read-PinnedFile (Join-Path $batchPath 'scope.json') $pins
            if(!$beforeScope){$beforeScope=Read-BathScope -Root $project -Scope (Join-Path $batchPath 'scope.json') -ProtectedPaths @($entries.path)}
            Assert-GroupBudget $beforeScope $sources
            New-Json (Join-Path $batchPath 'scope-before.json') $beforeScope
            if($script:GroupMixed){
                New-Json (Join-Path $batchPath 'scope-after.json') (Get-GroupAfterScope $scopeObject $rename)
                $afterScope=Read-PinnedFile (Join-Path $batchPath 'scope-after.json') $pins
                $namespace=Get-GroupNamespace $project $batchPath $rename.path $beforeScope.limits
                New-Json (Join-Path $batchPath 'namespace-before.json') $namespace
                $renameRecord=[ordered]@{};foreach($k in $intent.rename.Keys){$renameRecord[$k]=$intent.rename[$k]}
                $renameRecord.namespace_sha256=$namespace.namespace_sha256;$renameRecord.ledger_file_sha256=(Read-PinnedFile (Join-Path $batchPath 'namespace-before.json') $pins).Hash
                [void](Get-GroupNamespace $project $batchPath $rename.path $namespace.limits)
            }
            [BathNative]::WriteNew((Join-Path $batchPath 'plan.json'),$planData.Bytes)
            New-PinnedDirectory (Join-Path $batchPath 'entries') $pins
            $records=@()
            foreach($s in $sources){
                $e=$s.entry;$dir=Join-Path (Join-Path $batchPath 'entries') $e.entry_id;New-PinnedDirectory $dir $pins
                [BathNative]::WriteNew((Join-Path $dir 'before.bin'),$s.original.Bytes);$backup=Read-PinnedFile (Join-Path $dir 'before.bin') $pins
                if($backup.Hash-cne$e.before_sha256){throw 'BACKUP_FAILED: group before mismatch'}
                $afterId=$null;$afterBytes=0
                if($s.replacement){[BathNative]::WriteNew((Join-Path $dir 'after.bin'),$s.replacement.Bytes);$payload=Read-PinnedFile (Join-Path $dir 'after.bin') $pins;if($payload.Hash-cne$e.after_sha256){throw 'BACKUP_FAILED: replacement copy mismatch'};$afterId=$payload.Id;$afterBytes=$payload.Bytes.Length}
                $records+=,[ordered]@{entry_id=$e.entry_id;path=$e.path;action=$e.action;before_sha256=$e.before_sha256;before_id=$s.original.Id;before_write_time=$s.original.WriteTime.ToString();parent_id=$s.parent;backup_id=$backup.Id;after_sha256=$e.after_sha256;after_bytes=$afterBytes;payload_id=$afterId}
                if($script:GroupMixed){$records[-1].path_after=Get-GroupMappedPath $e.path $rename}
            }
            $m=[ordered]@{schema_version=2;kind='group';batch=$intent.batch;canonical_root=$canonical;root_id=$rootId;plan_sha256=$planData.Hash;prepare_intent_sha256=([BathNative]::Read($intentPath)).Hash;runtime_sha256=$runtime;check_scope=[ordered]@{scope_sha256=$saved.Hash;scope_id=$saved.Id;scope_write_time=$saved.WriteTime.ToString();before_snapshot_sha256=([BathNative]::Read((Join-Path $batchPath 'scope-before.json'))).Hash};entries=$records}
            if($script:GroupMixed){$m.schema_version=4;$m.kind='mixed';$m.rename=$renameRecord;$m.phase='MIXED_CHECKED_STAGING';$m.execution_ready=$true;$m.eligible_for_finalize=$true;$m.check_scope.after_scope_sha256=$afterScope.Hash;$m.check_scope.after_scope_id=$afterScope.Id;$m.check_scope.after_scope_write_time=$afterScope.WriteTime.ToString()}
            $manifestPath=Join-Path $batchPath 'manifest.json';New-Json $manifestPath $m
            Write-GroupEvent $batchPath 'BackedUp' ([BathNative]::Read($manifestPath)).Hash
            if($script:GroupMixed){$script:GroupExecutionReady=$true;$script:GroupEligible=$true}
            return @{ok=$true;state='BackedUp';batch=$batchPath;entries=@($entries.entry_id);verified=$false}
        }
        $batchPath=Get-LocalPath $Batch
        if([IO.Path]::GetDirectoryName($batchPath)-cne$archive-or[IO.Path]::GetFileName($batchPath)-cnotmatch'^group-[a-f0-9-]{36}$'){throw 'BAD_BATCH: group must belong to project'}
        [void](Pin-Directory $batchPath $pins);$lease=Get-Json $leasePath
        $manifestPath=Join-Path $batchPath 'manifest.json'
        if(![IO.File]::Exists($manifestPath)){
            $intentData=Read-PinnedFile (Join-Path $batchPath 'prepare-intent.json') $pins;$intent=ConvertFrom-Json ([Text.Encoding]::UTF8.GetString($intentData.Bytes)) -AsHashtable
            if($intent.canonical_root-cne$canonical-or$intent.root_id-cne$rootId-or$intent.batch-cne[IO.Path]::GetFileName($batchPath)){throw 'BAD_INTENT: incomplete group mismatch'}
            $stoppedPath=Join-Path $batchPath 'stopped.json';$stopped=[IO.File]::Exists($stoppedPath)
            if($Action-eq'Status'){return @{ok=$true;state=if($stopped){'Stopped'}else{'IncompletePrepare'};batch=$batchPath;entries=$intent.targets}}
            if($Action-ne'Close'){throw 'INCOMPLETE_PREPARE: Close retains incomplete evidence without project writes'}
            if(!$stopped){if($lease.owner-cne$intent.batch-or$lease.intent_sha256-cne$intentData.Hash){throw 'PROJECT_BUSY: only intact owner can close'};New-Json $stoppedPath @{state='Stopped';intent_sha256=$intentData.Hash;restored=$false}}
            elseif((Get-Json $stoppedPath).intent_sha256-cne$intentData.Hash){throw 'BAD_INTENT: stopped marker mismatch'}
            if($lease.owner-ceq$intent.batch){if($lease.intent_sha256-cne$intentData.Hash){throw 'BAD_INTENT: stopped owner intent differs'};Write-Lease $leasePath ''}
            return @{ok=$true;state='Stopped';batch=$batchPath;restored=$false}
        }
        $ms=Read-PinnedFile $manifestPath $pins;$m=ConvertFrom-Json ([Text.Encoding]::UTF8.GetString($ms.Bytes)) -AsHashtable -Depth 25
        $script:GroupMixed=$m.schema_version-eq 4
        $mk=@('schema_version','kind','batch','canonical_root','root_id','plan_sha256','prepare_intent_sha256','runtime_sha256','check_scope','entries');if($script:GroupMixed){$mk+=@('rename','phase','execution_ready','eligible_for_finalize')};Check-Keys $m $mk
        if(($m.schema_version-ne 2-and$m.schema_version-ne 4)-or$m.kind-cne$(if($script:GroupMixed){'mixed'}else{'group'})-or$m.canonical_root-cne$canonical-or$m.root_id-cne$rootId-or$m.batch-cne[IO.Path]::GetFileName($batchPath)){throw 'BAD_MANIFEST: group/project mismatch'}
        if($script:GroupMixed){
            Import-GroupNamespaceHelpers
            if($m.phase-cnotin@('MIXED_APPLY_RESTORE_STAGING','MIXED_CHECKED_STAGING')-or$m.execution_ready-isnot[bool]-or!$m.execution_ready-or$m.eligible_for_finalize-isnot[bool]-or$m.eligible_for_finalize-ne($m.phase-ceq'MIXED_CHECKED_STAGING')){throw 'BAD_MANIFEST: mixed capability boundary'}
            $script:GroupPhase=$m.phase;$script:GroupExecutionReady=$m.execution_ready;$script:GroupEligible=$m.eligible_for_finalize
        }
        $planSaved=Read-PinnedFile (Join-Path $batchPath 'plan.json') $pins
        if($planSaved.Hash-cne$m.plan_sha256){throw 'PLAN_CHANGED: frozen plan changed'}
        $frozenEntries=Read-GroupPlan $planSaved.Bytes
        if($frozenEntries.Count-ne$m.entries.Count){throw 'PLAN_CHANGED: entry count differs'}
        for($i=0;$i-lt$m.entries.Count;$i++){
            foreach($key in @('entry_id','path','action','before_sha256','after_sha256')){if($m.entries[$i][$key]-cne$frozenEntries[$i][$key]){throw 'BAD_MANIFEST: plan record differs'}}
            if($script:GroupMixed-and$m.entries[$i].path_after-cne(Get-GroupMappedPath $m.entries[$i].path $m.rename)){throw 'BAD_MANIFEST: projected path differs'}
        }
        if($script:GroupMixed){foreach($k in @('entry_id','path','destination')){if($m.rename[$k]-cne$script:GroupRename[$k]){throw 'BAD_MANIFEST: rename differs from plan'}};[void](Read-GroupNamespaceBefore $m $batchPath $pins)}
        $intentData=Read-PinnedFile (Join-Path $batchPath 'prepare-intent.json') $pins
        Assert-GroupIntent $intentData $m $canonical $rootId $lease
        $stoppedPath=Join-Path $batchPath 'stopped.json'
        $markerExists=[IO.File]::Exists($stoppedPath)
        $journalData=if($Action-in@('Close','Status')-or$markerExists){Read-PinnedFile (Join-Path $batchPath 'journal.jsonl') $pins}else{[BathNative]::Read((Join-Path $batchPath 'journal.jsonl'))}
        if($markerExists){
            $stop=Get-Json $stoppedPath
            Check-Keys $stop @('state','manifest_sha256','intent_sha256','journal_sha256','restored','reason')
            if($stop.state-cne'Stopped'-or$stop.manifest_sha256-cne$ms.Hash-or$stop.intent_sha256-cne$intentData.Hash-or$stop.journal_sha256-cne$journalData.Hash-or$stop.restored-ne$false){throw 'BAD_STOP: persistent terminal evidence changed'}
            if($Action-eq'Status'){return @{ok=$true;state='Stopped';batch=$batchPath;restored=$false}}
            if($Action-ne'Close'){throw 'BAD_STATE: stopped group cannot resume writes'}
            if($lease.owner-ceq$m.batch){if($lease.intent_sha256-cne$intentData.Hash){throw 'BAD_INTENT: stopped owner intent differs'};Write-Lease $leasePath ''}
            return @{ok=$true;state='Stopped';batch=$batchPath;restored=$false}
        }
        $journalError=$null
        try{$events=Read-GroupEvents $batchPath $ms.Hash $m;$projection=Get-GroupProjection $events $m}catch{$journalError=$_.Exception.Message;$projection=@{state='AmbiguousJournal';entries=@()}}
        if($Action-eq'Status'){
            $result=@{ok=$true;state=$projection.state;batch=$batchPath;entries=$projection.entries;conflicts=@($projection.entries|Where-Object state -in @('Conflict','UnconfirmedApply','UnconfirmedRestore')|ForEach-Object entry_id);journal_error=$journalError}
            if($script:GroupMixed){$result.observed=Get-RenameObserved $project $m.rename;$result.namespace=@($projection.entries|Where-Object entry_id -CEQ $m.rename.entry_id)}
            return $result
        }
        if($lease.owner-cne$m.batch-and$projection.state-cnotin@('Restored','Completed','Stopped')){throw 'PROJECT_BUSY: group is not current owner'}
        if($Action-eq'Close'){
            if($projection.state-cnotin@('InterruptedApply','InterruptedRestore','CheckInterrupted','Conflict','Stopped','AmbiguousJournal')-and!($script:GroupMixed-and$projection.state-eq'BackedUp')){throw 'BAD_STATE: healthy group uses Restore/Finalize'}
            if($lease.owner-cne$m.batch){throw 'PROJECT_BUSY: only intact current owner can stop group'}
            New-Json $stoppedPath @{state='Stopped';manifest_sha256=$ms.Hash;intent_sha256=$intentData.Hash;journal_sha256=$journalData.Hash;restored=$false;reason=$projection.state}
            Write-Lease $leasePath ''
            return @{ok=$true;state='Stopped';batch=$batchPath;restored=$false}
        }
        if($journalError){throw 'AMBIGUOUS_JOURNAL: automatic writes refused; safe Close preserves journal'}
        # Validate every payload before first possible target mutation, including later entries.
        $payloads=@{};$backups=@{}
        foreach($e in $m.entries){
            $dir=Join-Path (Join-Path $batchPath 'entries') $e.entry_id
            $b=Read-PinnedFile (Join-Path $dir 'before.bin') $pins
            if($b.Hash-cne$e.before_sha256-or$b.Id-cne$e.backup_id){throw 'BACKUP_FAILED: original backup changed'};$backups[$e.entry_id]=$b
            if($e.action-eq'edit'){$a=Read-PinnedFile (Join-Path $dir 'after.bin') $pins;if($a.Hash-cne$e.after_sha256-or$a.Id-cne$e.payload_id){throw 'PAYLOAD_CHANGED: saved replacement changed'};$payloads[$e.entry_id]=$a}
        }
        if($Action-eq'Apply'){
            if($projection.state-cne'BackedUp'){throw 'BAD_STATE: group Apply requires BackedUp'}
            [void](Read-GroupScope $m $batchPath $project $pins)
            if($script:GroupMixed){
                $validationPins=[Collections.Generic.List[IDisposable]]::new()
                try{foreach($e in $m.entries){
                    $target=Get-LocalPath (Join-Path $project $e.path)
                    if((Pin-Directory ([IO.Path]::GetDirectoryName($target)) $validationPins)-cne$e.parent_id){throw 'PARENT_CHANGED: original parent differs'}
                    $b=Read-PinnedFile $target $validationPins
                    if($b.Hash-cne$e.before_sha256-or$b.Id-cne$e.before_id-or$b.WriteTime.ToString()-cne$e.before_write_time){throw 'TARGET_CHANGED: original input differs'}
                }}finally{foreach($pin in $validationPins){$pin.Dispose()}}
                Write-GroupEvent $batchPath 'Applying' $ms.Hash
                Invoke-GroupNamespaceRename $m $batchPath $project $pins $ms.Hash $projection
            }
            $handles=@{}
            try{
                foreach($e in $m.entries){
                    $relative=if($script:GroupMixed){$e.path_after}else{$e.path};$target=Get-LocalPath (Join-Path $project $relative)
                    if((Pin-Directory ([IO.Path]::GetDirectoryName($target)) $sourcePins)-cne$e.parent_id){throw 'PARENT_CHANGED: group parent changed'}
                    $f=[BathNative]::Open($target,$true);$handles[$e.entry_id]=$f;$b=[BathNative]::Capture($f)
                    if($b.Hash-cne$e.before_sha256-or$b.Id-cne$e.before_id-or$b.WriteTime.ToString()-cne$e.before_write_time){throw 'TARGET_CHANGED: group input changed'}
                }
                if(!$script:GroupMixed){Write-GroupEvent $batchPath 'Applying' $ms.Hash}
                foreach($e in $m.entries){
                    $relative=if($script:GroupMixed){$e.path_after}else{$e.path}
                    $f=$handles[$e.entry_id];$fileIntent=Write-GroupEvent $batchPath 'Applying' $ms.Hash $e.entry_id $e.before_id ([long]$e.before_write_time) -ReturnId
                    if($e.action-eq'archive'){[BathNative]::Retire($f)}else{[BathNative]::ReplaceBytes($f,$payloads[$e.entry_id].Bytes)}
                    $f.Dispose();$handles.Remove($e.entry_id)
                    $id='';$time=0
                    if($e.action-eq'edit'){$post=[BathNative]::Read((Join-Path $project $relative));if($post.Hash-cne$e.after_sha256-or$post.Id-cne$e.before_id){throw 'POST_CHANGED: group post-state differs'};$id=$post.Id;$time=$post.WriteTime}
                    elseif(Test-Path -LiteralPath (Join-Path $project $relative)){throw 'POST_CHANGED: archived path occupied'}
                    Write-GroupEvent $batchPath 'Applied' $ms.Hash $e.entry_id $id $time -OperationEventId $fileIntent
                }
                Write-GroupEvent $batchPath 'Applied' $ms.Hash
                return @{ok=$true;state='Applied';batch=$batchPath;entries=@($m.entries.entry_id);verified=$false}
            }finally{foreach($f in $handles.Values){$f.Dispose()}}
        }
        if($Action-eq'Restore'){
            if($projection.state-eq'Stopped'){throw 'BAD_STATE: stopped group cannot resume writes'}
            if($projection.state-eq'Completed'){
                if($lease.owner-and$lease.owner-cne$m.batch){throw 'PROJECT_BUSY: historical group cannot take active lease'}
                if($lease.owner-ceq$m.batch-and$lease.intent_sha256-cne$m.prepare_intent_sha256){throw 'BAD_INTENT: historical owner intent differs'}
                if(!$lease.owner){Write-Lease $leasePath $m.batch $m.prepare_intent_sha256;$lease=Get-Json $leasePath}
            }
            if($projection.state-eq'Restored'){
                if($script:GroupMixed){
                    $nsRow=@($projection.entries|Where-Object entry_id -CEQ $m.rename.entry_id)[0];$raw=Read-PinnedFile (Join-Path $batchPath 'namespace-restored.json') $pins
                    $ledger=ConvertFrom-Json ([Text.Encoding]::UTF8.GetString($raw.Bytes)) -AsHashtable -Depth 30
                    if(!$nsRow.restored-or$raw.Hash-cne$nsRow.restored.ledger_file_sha256-or$ledger.namespace_sha256-cne$nsRow.restored.namespace_sha256-or(Get-GroupNamespaceHash $ledger)-cne$ledger.namespace_sha256){throw 'BAD_LEDGER: retained restored namespace changed'}
                    $live=Assert-GroupNamespaceCurrent $m $batchPath $project $pins $projection $true $true
                    if($live.namespace_sha256-cne$nsRow.restored.namespace_sha256){throw 'BAD_LEDGER: own restored confirmation differs'}
                }
                foreach($e in $m.entries){$row=@($projection.entries|Where-Object entry_id -CEQ $e.entry_id)[0];if($row.restored){$now=[BathNative]::Read((Join-Path $project $e.path));if($now.Hash-cne$e.before_sha256-or$now.Id-cne$row.restored.target_id-or$now.WriteTime.ToString()-cne$row.restored.write_time){throw 'RESTORE_CONFLICT: historical restore no longer represents current user state'}}}
                if($lease.owner-ceq$m.batch){if($lease.intent_sha256-cne$m.prepare_intent_sha256){throw 'BAD_INTENT: restored owner intent differs'};Write-Lease $leasePath ''}
                return @{ok=$true;state='Restored';batch=$batchPath;restored=@();conflicts=@();historical=$true}
            }
            if($script:GroupMixed){
                $namespaceRow=@($projection.entries|Where-Object entry_id -CEQ $m.rename.entry_id)[0]
                if(!$namespaceRow.applied-or$namespaceRow.state-cnotin@('Applied','Conflict')){throw 'UNCONFIRMED_EDIT: namespace is not confirmed Applied'}
                $after=Read-PinnedFile (Join-Path $batchPath 'namespace-after.json') $pins
                if($after.Hash-cne$namespaceRow.applied.ledger_file_sha256){throw 'BAD_LEDGER: original namespace Applied evidence changed'}
            }
            $restoredIds=@();$conflicts=@()
            Write-GroupEvent $batchPath 'Restoring' $ms.Hash
            for($i=$m.entries.Count-1;$i-ge 0;$i--){
                $e=$m.entries[$i];$row=@($projection.entries|Where-Object entry_id -CEQ $e.entry_id)[0]
                if($row.state-in@('UnconfirmedApply','UnconfirmedRestore')){$conflicts+=,$e.entry_id;Write-GroupEvent $batchPath 'Conflict' $ms.Hash $e.entry_id;continue}
                if(!$row.applied){continue}
                $relative=if($script:GroupMixed){$e.path_after}else{$e.path};$target=Get-LocalPath (Join-Path $project $relative);$f=$null
                try{
                    if((Pin-Directory ([IO.Path]::GetDirectoryName($target)) $sourcePins)-cne$e.parent_id){throw 'RESTORE_CONFLICT: parent changed'}
                    if($row.restored){$now=[BathNative]::Read($target);if($now.Hash-cne$e.before_sha256-or$now.Id-cne$row.restored.target_id-or$now.WriteTime.ToString()-cne$row.restored.write_time){throw 'RESTORE_CONFLICT: user changed already restored entry'};continue}
                    if($e.action-eq'archive'){
                        if([IO.File]::Exists($target)-or[IO.Directory]::Exists($target)){throw 'RESTORE_CONFLICT: same-name user object exists'}
                        $fileIntent=Write-GroupEvent $batchPath 'Restoring' $ms.Hash $e.entry_id -ReturnId
                        [BathNative]::WriteNew($target,$backups[$e.entry_id].Bytes)
                    }else{
                        $f=[BathNative]::Open($target,$true);$current=[BathNative]::Capture($f)
                        if($current.Hash-cne$e.after_sha256-or$current.Id-cne$row.applied.target_id-or$current.WriteTime.ToString()-cne$row.applied.write_time){throw 'RESTORE_CONFLICT: later user edit or identity'}
                        $fileIntent=Write-GroupEvent $batchPath 'Restoring' $ms.Hash $e.entry_id $current.Id $current.WriteTime -ReturnId
                        [BathNative]::ReplaceBytes($f,$backups[$e.entry_id].Bytes);$f.Dispose();$f=$null
                    }
                    $post=[BathNative]::Read($target);if($post.Hash-cne$e.before_sha256){throw 'RESTORE_CONFLICT: restored bytes differ'}
                    Write-GroupEvent $batchPath 'Restored' $ms.Hash $e.entry_id $post.Id $post.WriteTime -OperationEventId $fileIntent;$restoredIds+=,$e.entry_id
                }catch{$conflicts+=,$e.entry_id;Write-GroupEvent $batchPath 'Conflict' $ms.Hash $e.entry_id}finally{if($f){$f.Dispose()}}
            }
            if($conflicts.Count){Write-GroupEvent $batchPath 'Conflict' $ms.Hash;return @{ok=$false;state='Conflict';batch=$batchPath;restored=$restoredIds;conflicts=$conflicts;code='RESTORE_CONFLICT'}}
            if($script:GroupMixed){
                # Child parent pins must not prevent their ancestor's reverse rename.
                foreach($pin in $sourcePins){$pin.Dispose()};$sourcePins.Clear()
                $projection=Get-GroupProjection (Read-GroupEvents $batchPath $ms.Hash $m) $m
                try{Invoke-GroupNamespaceRename $m $batchPath $project $pins $ms.Hash $projection $true}
                catch{Write-GroupEvent $batchPath 'Conflict' $ms.Hash;throw}
            }
            Write-GroupEvent $batchPath 'Restored' $ms.Hash
            if($lease.owner-ceq$m.batch){if($lease.intent_sha256-cne$m.prepare_intent_sha256){throw 'BAD_INTENT: restored owner intent differs'};Write-Lease $leasePath ''}
            return @{ok=$true;state='Restored';batch=$batchPath;restored=$restoredIds;conflicts=@()}
        }
        if($Action-eq'Check'){
            if($script:GroupMixed-and($m.phase-cne'MIXED_CHECKED_STAGING'-or!$m.eligible_for_finalize)){throw 'CAPABILITY_BLOCKED: old Apply/Restore phase cannot Check/Finalize'}
            if($projection.state-cnotin@('Applied','Checked','CheckInterrupted')){throw 'BAD_STATE: group Check requires complete confirmed Apply'}
            $checkAttempt=Write-GroupEvent $batchPath 'CheckStarted' $ms.Hash -ReturnId
            $current=Read-GroupScope $m $batchPath $project $pins $projection
            $scriptPath=Get-LocalPath $CheckScript;[void](Pin-Directory ([IO.Path]::GetDirectoryName($scriptPath)) $pins)
            $scriptData=Read-PinnedFile $scriptPath $pins
            $receiptId=[Guid]::NewGuid().ToString('N');$copy=Join-Path $batchPath ('check-'+$receiptId+'.ps1')
            $copied=Copy-PinnedCheck $copy $scriptData $pins
            $started=[DateTime]::UtcNow
            $viewScope=if($script:GroupMixed){'scope-after.json'}else{'scope.json'};$viewTarget=if($script:GroupMixed){$m.entries[0].path_after}else{$m.entries[0].path}
            $lab=Invoke-ScopedView $project (Join-Path $batchPath $viewScope) $copy $viewTarget $current.limits.timeout_seconds $archive
            $finished=[DateTime]::UtcNow
            $lrPath=Get-LocalPath $lab.receipt_path;$lrData=Read-PinnedFile $lrPath $pins
            $lr=ConvertFrom-Json ([Text.Encoding]::UTF8.GetString($lrData.Bytes)) -AsHashtable -Depth 25
            if($lr.status-cne'LabPassed'-or$lr.eligible_for_finalize-ne$false-or$lr.exit_code-ne 0-or$lr.input_snapshot_sha256-cne$current.snapshot_sha256){throw 'CHECK_FAILED: lab not bound to current group'}
            $again=Read-GroupScope $m $batchPath $project $pins $projection
            if($again.snapshot_sha256-cne$current.snapshot_sha256){throw 'SCOPE_CHANGED: originals changed during group check'}
            $limits=[ordered]@{};foreach($key in $current.limits.Keys){$limits[$key]=$current.limits[$key]}
            if($limits.max_files-ne 0){$limits.max_files=$limits.max_files+64}
            $limits.max_directories=[Math]::Min(100000,$limits.max_directories+16)
            $limits.max_total_bytes=[Math]::Min(1073741824,$limits.max_total_bytes+67108864)
            $inspectionName='scoped-inspect-'+$receiptId+'.json';$inspection=Join-Path $batchPath $inspectionName
            New-Json $inspection ([ordered]@{schema_version=1;inputs=@('.');limits=$limits})
            $inspectionData=Read-PinnedFile $inspection $pins
            $retained=Read-RetainedEvidence $lab.run_directory $inspection $pins
            Assert-LabEvidence $lr $retained $lab.run_directory $copied.Hash $current $pins
            $applyIds=@($projection.entries|ForEach-Object{[ordered]@{entry_id=$_.entry_id;event_id=$_.applied.event_id;target_id=$_.applied.target_id;write_time=$_.applied.write_time}})
            $receiptName='receipt-'+$receiptId+'.json';$receiptPath=Join-Path $batchPath $receiptName
            $r=[ordered]@{schema_version=2;kind='group';batch=$m.batch;canonical_root=$canonical;manifest_sha256=$ms.Hash;applied_events=$applyIds;started_utc=$started.ToString('o');finished_utc=$finished.ToString('o');passed=$true;exit_code=0;scope_sha256=$current.scope_sha256;input_snapshot_sha256=$current.snapshot_sha256;runtime_sha256=$m.runtime_sha256;lab_receipt_path=$lrPath;lab_receipt_sha256=$lrData.Hash;retained_root=$lab.run_directory;retained_scope_name=$inspectionName;retained_scope_sha256=$inspectionData.Hash;retained_snapshot_sha256=$retained.snapshot_sha256}
            $r.check_attempt_event_id=$checkAttempt
            if($script:GroupMixed){
                $r.schema_version=4;$r.kind='mixed';$r.scope_before_sha256=$m.check_scope.scope_sha256
                $ns=Assert-GroupNamespaceCurrent $m $batchPath $project $pins $projection
                $namespaceRow=@($projection.entries|Where-Object entry_id -CEQ $m.rename.entry_id)[0]
                $nsRaw=Read-PinnedFile (Join-Path $batchPath 'namespace-after.json') $pins
                if($nsRaw.Hash-cne$namespaceRow.applied.ledger_file_sha256-or$namespaceRow.applied.namespace_sha256-cne$m.rename.namespace_sha256){throw 'BAD_LEDGER: original namespace confirmation differs'}
                $r.namespace_after_sha256=$ns.namespace_sha256;$r.namespace_after_ledger_sha256=$nsRaw.Hash
            }
            New-Json $receiptPath $r;$receiptHash=([BathNative]::Read($receiptPath)).Hash
            Write-GroupEvent $batchPath 'Checked' $ms.Hash '' '' 0 $receiptName $receiptHash -CheckAttempt $checkAttempt
            return @{ok=$true;state='Checked';passed=$true;batch=$batchPath;receipt=$receiptPath;semantic_correctness='Agent-owned judgment; recorded checks only, not host sandbox'}
        }
        if($Action-eq'Finalize'){
            if($script:GroupMixed-and($m.phase-cne'MIXED_CHECKED_STAGING'-or!$m.eligible_for_finalize)){throw 'CAPABILITY_BLOCKED: old Apply/Restore phase cannot Check/Finalize'}
            if($projection.state-cnotin@('Checked','Completed')-or!$projection.last.Contains('receipt_sha256')){throw 'EVIDENCE_REQUIRED: latest group Check required'}
            $path=Get-LocalPath $Receipt
            if([IO.Path]::GetDirectoryName($path)-cne$batchPath-or[IO.Path]::GetFileName($path)-cne$projection.last.receipt_name){throw 'BAD_RECEIPT: latest own group receipt only'}
            $rs=Read-PinnedFile $path $pins
            if($rs.Hash-cne$projection.last.receipt_sha256){throw 'EVIDENCE_CHANGED: receipt changed'}
            $r=Convert-GroupReceipt $rs.Bytes
            $rk=@('schema_version','kind','batch','canonical_root','manifest_sha256','applied_events','started_utc','finished_utc','passed','exit_code','scope_sha256','input_snapshot_sha256','runtime_sha256','lab_receipt_path','lab_receipt_sha256','retained_root','retained_scope_name','retained_scope_sha256','retained_snapshot_sha256','check_attempt_event_id');if($script:GroupMixed){$rk+=@('namespace_after_sha256','namespace_after_ledger_sha256','scope_before_sha256')};Check-Keys $r $rk
            if($r.schema_version-ne$m.schema_version-or$r.kind-cne$m.kind-or$r.batch-cne$m.batch-or$r.canonical_root-cne$canonical-or$r.manifest_sha256-cne$ms.Hash-or$r.passed-isnot[bool]-or!$r.passed-or$r.exit_code-ne 0){throw 'BAD_RECEIPT: group/manifest/pass binding'}
            $attempts=@($events|Where-Object state -eq 'CheckStarted');if(!$attempts.Count-or$r.check_attempt_event_id-cne$attempts[-1].event_id){throw 'EVIDENCE_REQUIRED: latest successful check attempt only'}
            $expectedCount=$m.entries.Count;if($script:GroupMixed){$expectedCount++}
            if($r.applied_events-isnot[array]-or$r.applied_events.Count-ne$expectedCount){throw 'BAD_RECEIPT: Apply set mismatch'}
            $seenIds=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach($record in $r.applied_events){if(!$seenIds.Add($record.entry_id)){throw 'BAD_RECEIPT: duplicate Apply event'}}
            foreach($record in $r.applied_events){$row=@($projection.entries|Where-Object entry_id -CEQ $record.entry_id);if($row.Count-ne 1-or!$row[0].applied-or$row[0].applied.event_id-cne$record.event_id-or$row[0].applied.target_id-cne$record.target_id-or$row[0].applied.write_time-cne$record.write_time){throw 'BAD_RECEIPT: Apply event mismatch'}}
            $lastApply=@($events|Where-Object{ $_.Contains('entry_id')-and$_.state-eq'Applied' })[-1]
            if([DateTimeOffset]::Parse($r.started_utc)-lt[DateTimeOffset]::Parse($lastApply.utc)-or[DateTimeOffset]::Parse($r.finished_utc)-lt[DateTimeOffset]::Parse($r.started_utc)-or[DateTimeOffset]::Parse($r.finished_utc)-gt[DateTimeOffset]::Parse($projection.last.utc)){throw 'STALE_EVIDENCE: check outside Apply/event window'}
            Assert-GroupRuntime $r.runtime_sha256 $pins
            $current=Read-GroupScope $m $batchPath $project $pins $projection
            if($current.snapshot_sha256-cne$r.input_snapshot_sha256-or$current.scope_sha256-cne$r.scope_sha256){throw 'SCOPE_CHANGED: current input differs from receipt'}
            if($script:GroupMixed){
                $ns=Assert-GroupNamespaceCurrent $m $batchPath $project $pins $projection;$namespaceRow=@($projection.entries|Where-Object entry_id -CEQ $m.rename.entry_id)[0]
                $nsRaw=Read-PinnedFile (Join-Path $batchPath 'namespace-after.json') $pins
                if($r.scope_before_sha256-cne$m.check_scope.scope_sha256-or$r.namespace_after_sha256-cne$ns.namespace_sha256-or$r.namespace_after_ledger_sha256-cne$nsRaw.Hash-or$nsRaw.Hash-cne$namespaceRow.applied.ledger_file_sha256-or$namespaceRow.applied.namespace_sha256-cne$m.rename.namespace_sha256){throw 'BAD_RECEIPT: full namespace/before scope binding differs'}
            }
            $labPath=Get-LocalPath $r.lab_receipt_path
            if([IO.Path]::GetDirectoryName($labPath)-cne$r.retained_root-or[IO.Path]::GetFileName($labPath)-cne'receipt.json'){throw 'BAD_RECEIPT: lab path mismatch'}
            $ls=Read-PinnedFile $labPath $pins;if($ls.Hash-cne$r.lab_receipt_sha256){throw 'EVIDENCE_CHANGED: lab receipt changed'}
            $inspection=Join-Path $batchPath $r.retained_scope_name
            if($r.retained_scope_name-cnotmatch'^scoped-inspect-[a-f0-9]{32}\.json$'){throw 'BAD_RECEIPT: inspection name invalid'}
            if((Read-PinnedFile $inspection $pins).Hash-cne$r.retained_scope_sha256){throw 'EVIDENCE_CHANGED: retained scope changed'}
            $retained=Read-RetainedEvidence $r.retained_root $inspection $pins
            if($retained.snapshot_sha256-cne$r.retained_snapshot_sha256){throw 'EVIDENCE_CHANGED: retained run changed'}
            $lr=ConvertFrom-Json ([Text.Encoding]::UTF8.GetString($ls.Bytes)) -AsHashtable -Depth 25
            Assert-LabEvidence $lr $retained $r.retained_root $lr.check_script_sha256 $current $pins
            if($projection.state-ne'Completed'){Write-GroupEvent $batchPath 'Completed' $ms.Hash '' '' 0 $projection.last.receipt_name $rs.Hash -CheckAttempt $r.check_attempt_event_id}
            if($lease.owner-ceq$m.batch){Write-Lease $leasePath ''}
            return @{ok=$true;state='Completed';batch=$batchPath;receipt=$path;verified_at=[DateTime]::UtcNow.ToString('o')}
        }
        throw 'CAPABILITY_BLOCKED: unsupported group action'
    }catch{
        $err=$_.Exception;while($err.InnerException){$err=$err.InnerException};$message=$err.Message
        $code=if($message-match'^([A-Z_]+):'){$Matches[1]}else{'IO_OR_VALIDATION_FAILED'}
        return @{ok=$false;code=$code;message=$message;batch=$batchPath;at=$_.ScriptStackTrace;next='Preserve all files/evidence; Status and safe Close/Restore only'}
    }finally{if($lock){$lock.Dispose()};foreach($pin in $sourcePins){$pin.Dispose()};for($i=$pins.Count-1;$i-ge 0;$i--){$pins[$i].Dispose()}}
}

if($MyInvocation.InvocationName-ne'.'){
    $result=Invoke-GroupBath
    if($script:GroupMixed){$result.backup_kind='file_bytes_and_namespace_evidence';$result.full_byte_backup=$false;$result.phase=$script:GroupPhase;$result.execution_ready=$script:GroupExecutionReady;$result.eligible_for_finalize=$script:GroupEligible}
    ConvertTo-Json $result -Compress -Depth 25 -EscapeHandling EscapeNonAscii;if(!$result.ok){exit 2}
}
