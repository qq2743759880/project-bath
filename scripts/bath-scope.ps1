Set-StrictMode -Version Latest

# Import only the reviewed read-only/path primitives. Never execute bath.ps1's CLI.
function Initialize-ScopeNative {
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'bath.ps1'),[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw 'SCOPE_INVALID: legacy helper parse failed' }
    foreach ($name in @('Initialize-Native','Get-LocalPath','Pin-Directory','Read-PinnedFile','Check-Keys')) {
        $defs=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$false) | Where-Object Name -CEQ $name)
        if ($defs.Count -ne 1) { throw 'SCOPE_INVALID: helper identity unavailable' }
        . ([scriptblock]::Create($defs[0].Extent.Text))
        Set-Item -Path "function:script:$name" -Value (Get-Item "function:$name").ScriptBlock
    }
    Initialize-Native
}

function Assert-ScopeJson($Element) {
    if ($Element.ValueKind -eq 'Object') {
        $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach($p in $Element.EnumerateObject()) {
            if (!$seen.Add($p.Name)) { throw 'SCOPE_INVALID: duplicate JSON field' }
            Assert-ScopeJson $p.Value
        }
    } elseif($Element.ValueKind -eq 'Array') { foreach($v in $Element.EnumerateArray()) { Assert-ScopeJson $v } }
}

function Assert-ScopeRelative($Value,[bool]$AllowRoot=$false) {
    if ($Value -isnot [string] -or !$Value -or $Value -match '[\\:*?"<>|]' -or $Value.StartsWith('/') -or $Value.EndsWith('/')) { throw 'SCOPE_PATH_ESCAPE: canonical relative path required' }
    if ($Value -eq '.' -and $AllowRoot) { return }
    foreach($part in $Value.Split('/')) {
        if (!$part -or $part -in @('.','..') -or $part.EndsWith('.') -or $part.EndsWith(' ') -or $part -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)') { throw 'SCOPE_PATH_ESCAPE: ambiguous relative path' }
    }
}

function Test-ScopeUnder([string]$Path,[string]$Prefix) {
    return $Prefix -eq '.' -or $Path.Equals($Prefix,[StringComparison]::OrdinalIgnoreCase) -or $Path.StartsWith($Prefix+'/',[StringComparison]::OrdinalIgnoreCase)
}

function Assert-ScopeAcl([string]$Path) {
    $acl=Get-Acl -LiteralPath $Path
    if ($acl.AreAccessRulesProtected -or $acl.GetAccessRules($true,$false,[Security.Principal.SecurityIdentifier]).Count -ne 0) { throw 'SCOPE_UNSUPPORTED_OBJECT: explicit/protected ACL' }
}

function Add-ScopeDirectoryAncestors([string]$Root,[string]$Relative,$Pins,$Directories,$Known,$Limits) {
    $current=''
    if ($Relative -eq '.') { return }
    foreach($part in $Relative.Split('/')) {
        $current=if($current) {$current+'/'+$part} else {$part}
        if($Known.Add($current)) {
            if($Directories.Count -ge $Limits.max_directories) { throw 'SCOPE_LIMIT: directory count' }
            $full=Get-LocalPath (Join-Path $Root $current)
            $id=Pin-Directory $full $Pins
            Assert-ScopeAcl $full
            $Directories.Add([ordered]@{path=$current;id=$id})
        }
    }
}

function Read-BathScope([string]$Root,[string]$Scope,[string[]]$ProtectedPaths=@()) {
    Initialize-ScopeNative
    $pins=[Collections.Generic.List[IDisposable]]::new()
    try {
        $rootPath=Get-LocalPath $Root
        $rootId=Pin-Directory $rootPath $pins
        Assert-ScopeAcl $rootPath
        $scopePath=Get-LocalPath $Scope
        [void](Pin-Directory ([IO.Path]::GetDirectoryName($scopePath)) $pins)
        $raw=Read-PinnedFile $scopePath $pins
        $json=[Text.UTF8Encoding]::new($false,$true).GetString($raw.Bytes)
        $doc=[Text.Json.JsonDocument]::Parse($json)
        try { Assert-ScopeJson $doc.RootElement } finally { $doc.Dispose() }
        $s=ConvertFrom-Json -InputObject $json -AsHashtable -Depth 20
        Check-Keys $s @('schema_version','inputs') @('excluded','outputs','limits')
        if ($s.schema_version -isnot [long] -and $s.schema_version -isnot [int]) { throw 'SCOPE_INVALID: schema integer required' }
        if ($s.schema_version -ne 1 -or $s.inputs -isnot [array] -or !$s.inputs.Count) { throw 'SCOPE_INVALID: inputs array required' }
        $excluded=@(); $outputs=@()
        if ($s.Contains('excluded')) {
            if ($s.excluded -isnot [array]) { throw 'SCOPE_INVALID: excluded array required' }
            $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach($e in $s.excluded) {
                Check-Keys $e @('path','reason'); Assert-ScopeRelative $e.path
                if ($e.reason -isnot [string] -or !$e.reason.Trim() -or !$seen.Add($e.path)) { throw 'SCOPE_INVALID: exclusion reason/uniqueness' }
                $excluded+=,[ordered]@{path=$e.path;reason=$e.reason}
            }
        }
        if ($s.Contains('outputs')) {
            if ($s.outputs -isnot [array]) { throw 'SCOPE_INVALID: outputs array required' }
            $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach($o in $s.outputs) { Assert-ScopeRelative $o; if(!$seen.Add($o)) { throw 'SCOPE_INVALID: duplicate output' }; $outputs+=,$o }
        }
        $limits=[ordered]@{max_files=0;max_directories=512;max_file_bytes=16777216;max_total_bytes=67108864;timeout_seconds=30}
        $ceilings=@{max_directories=100000;max_file_bytes=16777216;max_total_bytes=1073741824;timeout_seconds=300}
        if ($s.Contains('limits')) {
            Check-Keys $s.limits @() @($limits.Keys)
            foreach($k in $s.limits.Keys) {
                $v=$s.limits[$k]
                if (($v -isnot [long] -and $v -isnot [int]) -or $v -lt 0 -or ($k -ne 'max_files' -and ($v -eq 0 -or $v -gt $ceilings[$k]))) { throw 'SCOPE_INVALID: integer limit required; max_files=0 disables file count only' }
                $limits[$k]=$v
            }
        }
        $selectors=@()
        foreach($i in $s.inputs) {
            Assert-ScopeRelative $i $true
            foreach($prior in $selectors) { if ((Test-ScopeUnder $i $prior) -or (Test-ScopeUnder $prior $i)) { throw 'SCOPE_INVALID: overlapping input selectors' } }
            $selectors+=,$i
        }
        $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach($p in $ProtectedPaths) {
            Assert-ScopeRelative $p
            if(!$seen.Add($p)) { throw 'SCOPE_INVALID: duplicate protected path' }
            if (!@($selectors | Where-Object { Test-ScopeUnder $p $_ }).Count) { throw 'SCOPE_TARGET_UNCOVERED: target not covered by inputs' }
            foreach($e in @($excluded | ForEach-Object { $_.path })+$outputs) {
                if ((Test-ScopeUnder $p $e) -or (Test-ScopeUnder $e $p)) { throw 'SCOPE_TARGET_EXCLUDED: protected target intersects exclusion/output' }
            }
        }
        foreach($o in $outputs) {
            if([IO.File]::Exists((Join-Path $rootPath $o))) { throw 'SCOPE_INVALID: output directory prefix names an existing file' }
        }
        $clock=[Diagnostics.Stopwatch]::StartNew()
        $queue=[Collections.Generic.Queue[string]]::new()
        foreach($i in $selectors) { $queue.Enqueue($i) }
        $files=[Collections.Generic.List[object]]::new()
        $directories=[Collections.Generic.List[object]]::new()
        $directories.Add([ordered]@{path='.';id=$rootId})
        $knownDirectories=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        [void]$knownDirectories.Add('.')
        [long]$total=0; $excludedCount=$excluded.Count
        while($queue.Count) {
            if ($clock.Elapsed.TotalSeconds -gt $limits.timeout_seconds) { throw 'SCOPE_LIMIT: enumeration timeout' }
            $rel=$queue.Dequeue()
            if (@($excluded | Where-Object { Test-ScopeUnder $rel $_.path }).Count) { continue }
            $full=if($rel -eq '.') {$rootPath} else {Get-LocalPath (Join-Path $rootPath $rel)}
            if (![IO.File]::Exists($full) -and ![IO.Directory]::Exists($full)) { throw 'SCOPE_INVALID: selected input does not exist' }
            $attr=[IO.File]::GetAttributes($full)
            if($attr -band [IO.FileAttributes]::ReparsePoint) { throw 'SCOPE_UNSUPPORTED_OBJECT: reparse selected' }
            Assert-ScopeAcl $full
            if($attr -band [IO.FileAttributes]::Directory) {
                Add-ScopeDirectoryAncestors $rootPath $rel $pins $directories $knownDirectories $limits
                if($directories.Count -gt $limits.max_directories) { throw 'SCOPE_LIMIT: directory count' }
                foreach($child in [IO.Directory]::GetFileSystemEntries($full) | Sort-Object -CaseSensitive) {
                    $r=[IO.Path]::GetRelativePath($rootPath,$child).Replace('\','/')
                    Assert-ScopeRelative $r; $queue.Enqueue($r)
                }
            } else {
                if(($limits.max_files -gt 0 -and $files.Count -ge $limits.max_files) -or ([IO.FileInfo]::new($full)).Length -gt $limits.max_file_bytes) { throw 'SCOPE_LIMIT: file count/size' }
                $parent=[IO.Path]::GetRelativePath($rootPath,[IO.Path]::GetDirectoryName($full)).Replace('\','/')
                Add-ScopeDirectoryAncestors $rootPath $parent $pins $directories $knownDirectories $limits
                $f=Read-PinnedFile $full $pins
                $total+=$f.Bytes.Length
                if($total -gt $limits.max_total_bytes) { throw 'SCOPE_LIMIT: total bytes' }
                $files.Add([ordered]@{path=$rel;sha256=$f.Hash;id=$f.Id;write_time=$f.WriteTime.ToString([Globalization.CultureInfo]::InvariantCulture);bytes=$f.Bytes.Length})
            }
        }
        $snapshot=[ordered]@{schema_version=1;project_root=$rootPath;root_id=$rootId;scope_sha256=$raw.Hash;
            files=@($files.ToArray() | Sort-Object path -CaseSensitive);directories=@($directories.ToArray() | Sort-Object path -CaseSensitive);
            excluded=$excluded;outputs=$outputs;limits=$limits;stats=[ordered]@{files=$files.Count;directories=$directories.Count;total_bytes=$total;excluded_roots=$excludedCount}}
        $snapshot.snapshot_sha256=[BathNative]::Hash([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $snapshot -Compress -Depth 20)))
        return $snapshot
    } catch {
        $msg=$_.Exception.Message
        if ($msg -match '^SCOPE_(INVALID|PATH_ESCAPE|TARGET_UNCOVERED|TARGET_EXCLUDED|LIMIT|UNSUPPORTED_OBJECT):') { throw }
        if ($msg -match 'UNSUPPORTED_|LOCK_FAILED|FINAL_PATH|CASE_INFO|STREAM_INFO|FILE_INFO|BAD_PATH') { throw "SCOPE_UNSUPPORTED_OBJECT: $msg" }
        throw "SCOPE_INVALID: $msg"
    } finally { foreach($pin in $pins) { $pin.Dispose() } }
}
