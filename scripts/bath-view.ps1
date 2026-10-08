param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$Scope,[Parameter(Mandatory)][string]$CheckScript,[string[]]$ProtectedPaths=@())
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'bath-scope.ps1')

function Get-ViewHash($Data) {
    return [BathNative]::Hash([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Data -Depth 25 -Compress)))
}

function Write-ViewJson([string]$Path,$Data) {
    [BathNative]::WriteNew($Path,[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Data -Depth 25 -Compress)))
}

function New-ExclusiveViewDirectory([string]$Path) {
    if (!('BathViewDirectory' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class BathViewDirectory {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool CreateDirectoryW(string path, IntPtr security);
    public static void Create(string path) {
        if(!CreateDirectoryW(path,IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error());
    }
}
public sealed class BathViewJob : IDisposable {
    [StructLayout(LayoutKind.Sequential)] struct BasicLimit { public long ProcessTime,JobTime; public uint Flags; public UIntPtr MinWorking,MaxWorking; public uint ActiveLimit; public UIntPtr Affinity; public uint Priority,Scheduling; }
    [StructLayout(LayoutKind.Sequential)] struct Io { public ulong ReadOps,WriteOps,OtherOps,ReadBytes,WriteBytes,OtherBytes; }
    [StructLayout(LayoutKind.Sequential)] struct Extended { public BasicLimit Basic; public Io Counters; public UIntPtr ProcessMemory,JobMemory,PeakProcess,PeakJob; }
    [StructLayout(LayoutKind.Sequential)] struct Accounting { public long User,Kernel,PeriodUser,PeriodKernel; public uint PageFaults,Total,Active,Terminated; }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr CreateJobObjectW(IntPtr attributes,string name);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job,int kind,ref Extended info,uint size);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool QueryInformationJobObject(IntPtr job,int kind,out Accounting info,uint size,IntPtr returned);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job,IntPtr process);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateJobObject(IntPtr job,uint exitCode);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    IntPtr handle;
    static void Check(bool ok) { if(!ok) throw new Win32Exception(Marshal.GetLastWin32Error()); }
    public BathViewJob() {
        handle=CreateJobObjectW(IntPtr.Zero,null); if(handle==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        try { var info=new Extended(); info.Basic.Flags=0x2000; Check(SetInformationJobObject(handle,9,ref info,(uint)Marshal.SizeOf<Extended>())); }
        catch { Dispose(); throw; }
    }
    public void Assign(IntPtr process) { Check(AssignProcessToJobObject(handle,process)); }
    public uint Active { get { Accounting info; Check(QueryInformationJobObject(handle,1,out info,(uint)Marshal.SizeOf<Accounting>(),IntPtr.Zero)); return info.Active; } }
    public bool WaitEmpty(int milliseconds) {
        var clock=System.Diagnostics.Stopwatch.StartNew();
        while(Active!=0) { if(clock.ElapsedMilliseconds>=milliseconds) return false; System.Threading.Thread.Sleep(Math.Min(20,Math.Max(1,milliseconds-(int)clock.ElapsedMilliseconds))); }
        return true;
    }
    public void Terminate() { Check(TerminateJobObject(handle,1)); }
    public void Dispose() { if(handle!=IntPtr.Zero) { CloseHandle(handle); handle=IntPtr.Zero; } }
}
'@
    }
    [BathViewDirectory]::Create($Path)
}

function Get-SourceLedger($Snapshot,$Expected) {
    $files=@()
    foreach($e in $Expected.files) {
        $match=@($Snapshot.files | Where-Object { $_.path -ceq $e.path })
        if($match.Count -ne 1) { throw 'VIEW_SOURCE_CHANGED: selected file missing or renamed' }
        $files+=,$match[0]
    }
    $directories=@()
    foreach($e in $Expected.directories) {
        if (@($Expected.outputs | Where-Object { Test-ScopeUnder $e.path $_ }).Count) { continue }
        $match=@($Snapshot.directories | Where-Object { $_.path -ceq $e.path })
        if($match.Count -ne 1) { throw 'VIEW_SOURCE_CHANGED: selected directory missing or renamed' }
        $directories+=,$match[0]
    }
    return [ordered]@{files=$files;directories=$directories}
}

function Get-RunLogHash([string]$Path) {
    $f=[BathNative]::Open($Path,$false)
    try { return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($f)).ToLowerInvariant() }
    finally { $f.Dispose() }
}

function Assert-ViewInputBinding([string]$Path,$Before,[string]$Code) {
    try {
        $after=[BathNative]::Read($Path)
        if($after.Hash -cne $Before.Hash -or $after.Id -cne $Before.Id -or $after.WriteTime -ne $Before.WriteTime) { throw 'bytes, identity or write time changed' }
    } catch { throw "${Code}: $($_.Exception.Message)" }
}

function Invoke-ViewLab {
    $run=$null; $receiptPath=$null; $pins=[Collections.Generic.List[IDisposable]]::new()
    $receipt=[ordered]@{schema_version=1;run_id=[Guid]::NewGuid().ToString();status='LabFailed';eligible_for_finalize=$false;project_root=$null;scope_sha256=$null;input_snapshot_sha256=$null;runtime_sha256=[ordered]@{};check_script_sha256=$null;started_at_utc=[DateTime]::UtcNow.ToString('o');finished_at_utc=$null;exit_code=$null;stdout_sha256=$null;stderr_sha256=$null;view_source_before_sha256=$null;view_source_after_sha256=$null;original_source_after_sha256=$null;process_evidence_sha256=$null;input_bindings_sha256=$null;outputs=[ordered]@{files=@();directories=@()};error_code=$null}
    $failure=$null; $process=$null; $job=$null; $processStarted=$false; $processEvidence=$null; $cleanup=$null
    try {
        if(!$IsWindows -or $PSVersionTable.PSVersion -lt [version]'7.4') { throw 'SCOPE_UNSUPPORTED_OBJECT: Windows PowerShell 7.4+ required' }
        $source=Read-BathScope -Root $Root -Scope $Scope -ProtectedPaths $ProtectedPaths
        $receipt.project_root=$source.project_root; $receipt.scope_sha256=$source.scope_sha256; $receipt.input_snapshot_sha256=$source.snapshot_sha256
        $canonical=$source.project_root.Replace('\','/').ToLowerInvariant()
        if($canonical -eq 'd:/project-bath' -or $canonical.StartsWith('d:/project-bath/')) { throw 'SCOPE_INVALID: archive cannot be project root' }
        foreach($name in @('bath.ps1','bath-scope.ps1','bath-view.ps1')) { $receipt.runtime_sha256[$name]=([BathNative]::Read((Join-Path $PSScriptRoot $name))).Hash }
        foreach($file in $source.files) {
            if (@($source.outputs | Where-Object { Test-ScopeUnder $file.path $_ }).Count) { throw 'VIEW_SCOPE_CONFLICT: selected source bytes intersect writable output prefix' }
        }
        $scriptPath=Get-LocalPath $CheckScript
        if([IO.Path]::GetExtension($scriptPath) -ine '.ps1') { throw 'SCOPE_INVALID: trusted PowerShell script required' }
        $scriptBefore=[BathNative]::Read($scriptPath)
        Assert-ScopeAcl $scriptPath
        $scriptPins=[Collections.Generic.List[IDisposable]]::new()
        try { [void](Pin-Directory ([IO.Path]::GetDirectoryName($scriptPath)) $scriptPins) }
        finally { foreach($p in $scriptPins) {$p.Dispose()} }
        $receipt.check_script_sha256=$scriptBefore.Hash
        try {
            [void](Get-LocalPath 'D:/project-bath')
            [void](Pin-Directory 'D:/' $pins)
            $archive='D:/project-bath'
            if(![IO.Directory]::Exists($archive)) { [void][IO.Directory]::CreateDirectory($archive) }
            [void](Pin-Directory $archive $pins)
            Assert-ScopeAcl $archive
            $key=[IO.Path]::GetFileName($source.project_root)+'-'+[BathNative]::Hash([Text.Encoding]::UTF8.GetBytes($canonical)).Substring(0,8)
            $project=Get-LocalPath (Join-Path $archive $key)
            if(![IO.Directory]::Exists($project)) { [void][IO.Directory]::CreateDirectory($project) }
            [void](Pin-Directory $project $pins)
            Assert-ScopeAcl $project
            $newRun=Get-LocalPath (Join-Path $project ('view-'+$receipt.run_id))
            New-ExclusiveViewDirectory $newRun
            $run=$newRun
            [void](Pin-Directory $run $pins)
        } catch { throw "D_ARCHIVE_UNAVAILABLE: $($_.Exception.Message)" }
        $receiptPath=Join-Path $run 'receipt.json'
        Write-ViewJson (Join-Path $run 'input-snapshot.json') $source
        $scopeCopy=Join-Path $run 'scope.json'
        $scopePath=Get-LocalPath $Scope
        $scopeRaw=[BathNative]::Read($scopePath)
        if($scopeRaw.Hash -cne $source.scope_sha256) { throw 'SOURCE_CHANGED: scope changed during preparation' }
        $inputBindings=[ordered]@{schema_version=1;scope=[ordered]@{path=$scopePath;id=$scopeRaw.Id;write_time=$scopeRaw.WriteTime.ToString([Globalization.CultureInfo]::InvariantCulture);sha256=$scopeRaw.Hash};check_script=[ordered]@{path=$scriptPath;id=$scriptBefore.Id;write_time=$scriptBefore.WriteTime.ToString([Globalization.CultureInfo]::InvariantCulture);sha256=$scriptBefore.Hash}}
        $bindingsPath=Join-Path $run 'input-bindings.json'; Write-ViewJson $bindingsPath $inputBindings
        $receipt.input_bindings_sha256=([BathNative]::Read($bindingsPath)).Hash
        [BathNative]::WriteNew($scopeCopy,$scopeRaw.Bytes)
        $scriptCopy=Join-Path $run 'check.ps1'; [BathNative]::WriteNew($scriptCopy,$scriptBefore.Bytes)
        $copiedScriptBefore=[BathNative]::Read($scriptCopy)
        $launch=Join-Path $run 'launch.ps1'; $gate=Join-Path $run 'launch.go'
        $bootstrap=@'
param([string]$Script,[string]$ViewRoot,[string]$Gate)
$ErrorActionPreference='Stop'
# Fixed bootstrap executes no user code until parent owns this process tree.
while(![IO.File]::Exists($Gate)) { Start-Sleep -Milliseconds 10 }
$global:LASTEXITCODE=0
& $Script -ViewRoot $ViewRoot
$succeeded=$?
if($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
if(!$succeeded) { exit 1 }
'@
        [BathNative]::WriteNew($launch,[Text.Encoding]::UTF8.GetBytes($bootstrap))
        $receipt.runtime_sha256['launch.ps1']=([BathNative]::Read($launch)).Hash
        $view=Get-LocalPath (Join-Path $run 'view'); New-ExclusiveViewDirectory $view
        foreach($dir in $source.directories) {
            if($dir.path -ne '.') { [void][IO.Directory]::CreateDirectory((Get-LocalPath (Join-Path $view $dir.path))) }
        }
        foreach($file in $source.files) {
            $actual=[BathNative]::Read((Get-LocalPath (Join-Path $source.project_root $file.path)))
            if($actual.Hash -cne $file.sha256 -or $actual.Id -cne $file.id -or $actual.WriteTime.ToString() -cne $file.write_time) { throw 'SOURCE_CHANGED: source changed while copying' }
            $dest=Get-LocalPath (Join-Path $view $file.path)
            [BathNative]::WriteNew($dest,$actual.Bytes)
            if(([BathNative]::Read($dest)).Hash -cne $file.sha256) { throw 'VIEW_SOURCE_CHANGED: copy hash differs' }
        }
        $viewBefore=Read-BathScope -Root $view -Scope $scopeCopy
        $sourceLedger=Get-SourceLedger $viewBefore $source
        $receipt.view_source_before_sha256=Get-ViewHash $sourceLedger
        Write-ViewJson (Join-Path $run 'view-source-before.json') $sourceLedger
        $sourcePre=Read-BathScope -Root $Root -Scope $Scope -ProtectedPaths $ProtectedPaths
        if($sourcePre.snapshot_sha256 -cne $source.snapshot_sha256) { throw 'SOURCE_CHANGED: original snapshot changed before launch' }
        Assert-ViewInputBinding $scopePath $scopeRaw 'SOURCE_CHANGED'
        Assert-ViewInputBinding $scriptPath $scriptBefore 'CHECK_SCRIPT_CHANGED'
        $inspectScope=Join-Path $run 'inspect-scope.json'
        Write-ViewJson $inspectScope ([ordered]@{schema_version=1;inputs=@('.');excluded=@();outputs=@();limits=$source.limits})
        # User checks are trusted, but their side effects cannot redefine guard inputs.
        $controlBindings=[ordered]@{}
        foreach($name in @('input-snapshot.json','scope.json','check.ps1','launch.ps1','input-bindings.json','inspect-scope.json','view-source-before.json')) {
            $controlBindings[$name]=[BathNative]::Read((Join-Path $run $name))
        }
        $stdout=Join-Path $run 'stdout.log'; $stderr=Join-Path $run 'stderr.log'
        $outStream=[IO.FileStream]::new($stdout,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
        $errStream=[IO.FileStream]::new($stderr,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
        $start=[Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh.exe'))
        $start.UseShellExecute=$false; $start.CreateNoWindow=$true; $start.WorkingDirectory=$view
        $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
        foreach($a in @('-NoProfile','-File',$launch,'-Script',$scriptCopy,'-ViewRoot',$view,'-Gate',$gate)) { $start.ArgumentList.Add($a) }
        $processEvidence=[ordered]@{schema_version=1;bootstrap_sha256=$receipt.runtime_sha256['launch.ps1'];job_assigned=$false;gate_released=$false;termination_requested=$false;owned_processes_after_stop=$null;root_pid=$null;timeout_milliseconds=[int]($source.limits.timeout_seconds*1000);actual_elapsed_milliseconds=$null}
        try {
            $job=[BathViewJob]::new()
            $process=[Diagnostics.Process]::new(); $process.StartInfo=$start
            $deadline=[Diagnostics.Stopwatch]::StartNew()
            $processStarted=$process.Start(); $processEvidence.root_pid=$process.Id
            $outTask=$process.StandardOutput.BaseStream.CopyToAsync($outStream)
            $errTask=$process.StandardError.BaseStream.CopyToAsync($errStream)
            try { $job.Assign($process.SafeHandle.DangerousGetHandle()) }
            catch { throw "CHECK_FAILED: Job assignment refused; user gate remains closed: $($_.Exception.Message)" }
            $processEvidence.job_assigned=$true
            [BathNative]::WriteNew($gate,[Text.Encoding]::UTF8.GetBytes($receipt.run_id))
            $processEvidence.gate_released=$true
            $remaining=[Math]::Max(0,$processEvidence.timeout_milliseconds-[int]$deadline.ElapsedMilliseconds)
            $timedOut=!$process.WaitForExit($remaining)
            if(!$timedOut) {
                $remaining=[Math]::Max(0,$processEvidence.timeout_milliseconds-[int]$deadline.ElapsedMilliseconds)
                $timedOut=!$job.WaitEmpty($remaining)
            }
            $drain=[Threading.Tasks.Task]::WhenAll([Threading.Tasks.Task[]]@($outTask,$errTask))
            if(!$timedOut) {
                $remaining=[Math]::Max(0,$processEvidence.timeout_milliseconds-[int]$deadline.ElapsedMilliseconds)
                $timedOut=!$drain.Wait($remaining)
            }
            if($timedOut) {
                $cleanup=[Diagnostics.Stopwatch]::StartNew()
                $processEvidence.termination_requested=$true; $job.Terminate()
                if(!$job.WaitEmpty([Math]::Max(0,10000-[int]$cleanup.ElapsedMilliseconds))) { throw 'CHECK_TIMEOUT: owned Job processes did not stop in cleanup grace' }
                $remaining=[Math]::Max(0,10000-[int]$cleanup.ElapsedMilliseconds)
                if(!$process.WaitForExit($remaining)) { throw 'CHECK_TIMEOUT: root process did not stop' }
                $remaining=[Math]::Max(0,10000-[int]$cleanup.ElapsedMilliseconds)
                if(!$drain.Wait($remaining)) { throw 'CHECK_TIMEOUT: redirected pipes did not close' }
            }
            [void]$outTask.GetAwaiter().GetResult(); [void]$errTask.GetAwaiter().GetResult()
            $processEvidence.owned_processes_after_stop=$job.Active
            $processEvidence.actual_elapsed_milliseconds=$deadline.ElapsedMilliseconds
            $receipt.exit_code=$process.ExitCode
        } finally { $outStream.Dispose(); $errStream.Dispose() }
        $receipt.stdout_sha256=Get-RunLogHash $stdout; $receipt.stderr_sha256=Get-RunLogHash $stderr
        # Always inspect original selected state, even when the trusted child failed.
        try {
            $sourceAfter=Read-BathScope -Root $Root -Scope $Scope -ProtectedPaths $ProtectedPaths
            $receipt.original_source_after_sha256=$sourceAfter.snapshot_sha256
            if($sourceAfter.snapshot_sha256 -cne $source.snapshot_sha256) { $failure='SOURCE_CHANGED: original selected snapshot or scope changed' }
            Assert-ViewInputBinding $scopePath $scopeRaw 'SOURCE_CHANGED'
        } catch { $failure="SOURCE_CHANGED: $($_.Exception.Message)" }
        try {
            $scriptAfter=[BathNative]::Read($scriptPath); $copyAfter=[BathNative]::Read($scriptCopy)
            if($scriptAfter.Hash -cne $scriptBefore.Hash -or $scriptAfter.Id -cne $scriptBefore.Id -or $scriptAfter.WriteTime -ne $scriptBefore.WriteTime -or $copyAfter.Hash -cne $copiedScriptBefore.Hash -or $copyAfter.Id -cne $copiedScriptBefore.Id -or $copyAfter.WriteTime -ne $copiedScriptBefore.WriteTime) { throw 'CHECK_SCRIPT_CHANGED: check script bytes or identity changed' }
        } catch { if(!$failure) {$failure="CHECK_SCRIPT_CHANGED: $($_.Exception.Message)"} }
        foreach($name in $receipt.runtime_sha256.Keys) {
            $runtimePath=if($name -eq 'launch.ps1') {$launch} else {Join-Path $PSScriptRoot $name}
            if(([BathNative]::Read($runtimePath)).Hash -cne $receipt.runtime_sha256[$name] -and !$failure) { $failure='SOURCE_CHANGED: participating runtime changed' }
        }
        try {
            foreach($name in $controlBindings.Keys) {
                $bound=Read-PinnedFile (Join-Path $run $name) $pins
                $expected=$controlBindings[$name]
                if($bound.Hash -cne $expected.Hash -or $bound.Id -cne $expected.Id -or $bound.WriteTime -ne $expected.WriteTime) { throw 'SOURCE_CHANGED: internal guard/evidence bytes or identity changed' }
            }
            # Whole created view is inspected: excluded input names do not hide new writes.
            $viewAfter=Read-BathScope -Root $view -Scope $inspectScope
            if($viewAfter.scope_sha256 -cne $controlBindings['inspect-scope.json'].Hash) { throw 'SOURCE_CHANGED: internal inspection scope binding changed' }
            $afterLedger=Get-SourceLedger $viewAfter $source
            $receipt.view_source_after_sha256=Get-ViewHash $afterLedger
            Write-ViewJson (Join-Path $run 'view-source-after.json') $afterLedger
            if($receipt.view_source_after_sha256 -cne $receipt.view_source_before_sha256) { throw 'VIEW_SOURCE_CHANGED: copied source bytes, identity or write time changed' }
            $outputFiles=@(); $outputDirs=@()
            foreach($f in $viewAfter.files) {
                if(@($source.files | Where-Object {$_.path -ceq $f.path}).Count) {continue}
                if(!@($source.outputs | Where-Object {Test-ScopeUnder $f.path $_}).Count) { throw 'VIEW_UNDECLARED_WRITE: new file outside output prefixes' }
                $outputFiles+=,[ordered]@{path=$f.path;sha256=$f.sha256;bytes=$f.bytes}
            }
            foreach($d in $viewAfter.directories) {
                if(@($source.outputs | Where-Object {(Test-ScopeUnder $d.path $_) -or ($d.path -ne '.' -and (Test-ScopeUnder $_ $d.path))}).Count) { $outputDirs+=,$d.path; continue }
                if(!@($source.directories | Where-Object {$_.path -ceq $d.path}).Count) { throw 'VIEW_UNDECLARED_WRITE: new directory outside output prefixes/parents' }
            }
            $receipt.outputs=[ordered]@{files=$outputFiles;directories=$outputDirs}
        } catch { if(!$failure) {$failure=$_.Exception.Message} }
        if($failure) { throw $failure }
        if($timedOut) { throw 'CHECK_TIMEOUT: owned check process tree terminated at scope timeout' }
        if($receipt.exit_code -ne 0) { throw 'CHECK_FAILED: trusted check exited nonzero' }
        $receipt.status='LabPassed'
    } catch {
        $failure=$_.Exception.Message
        $receipt.error_code=if($failure -match '^([A-Z_]+):') {$Matches[1]} else {'SCOPE_INVALID'}
    } finally {
        if($job -and $processEvidence -and $processEvidence.job_assigned) {
            if($job.Active -ne 0) {
                if(!$cleanup) {$cleanup=[Diagnostics.Stopwatch]::StartNew()}
                $processEvidence.termination_requested=$true; $job.Terminate()
                if(!$job.WaitEmpty([Math]::Max(0,10000-[int]$cleanup.ElapsedMilliseconds))) { $failure='CHECK_TIMEOUT: owned process stop was not confirmed'; $receipt.status='LabFailed'; $receipt.error_code='CHECK_TIMEOUT' }
            }
            $processEvidence.owned_processes_after_stop=$job.Active
        }
        if($processStarted -and !$process.HasExited) {
            if(!$cleanup) {$cleanup=[Diagnostics.Stopwatch]::StartNew()}
            $process.Kill($true)
            if(!$process.WaitForExit([Math]::Max(0,10000-[int]$cleanup.ElapsedMilliseconds))) { $failure='CHECK_TIMEOUT: root stop was not confirmed'; $receipt.status='LabFailed'; $receipt.error_code='CHECK_TIMEOUT' }
        }
        if($processStarted -and $process.HasExited -and $null -eq $receipt.exit_code) { $receipt.exit_code=$process.ExitCode }
        if($process) {$process.Dispose()}; if($job) {$job.Dispose()}
        if($run -and $processEvidence) {
            $evidencePath=Join-Path $run 'process-evidence.json'
            Write-ViewJson $evidencePath $processEvidence
            $receipt.process_evidence_sha256=([BathNative]::Read($evidencePath)).Hash
        }
        $receipt.finished_at_utc=[DateTime]::UtcNow.ToString('o')
        if($receiptPath) { Write-ViewJson $receiptPath $receipt }
        foreach($p in $pins) {$p.Dispose()}
    }
    if($receipt.status -eq 'LabPassed') {
        return [ordered]@{ok=$true;schema_version=1;status='LabPassed';eligible_for_finalize=$false;run_directory=$run;receipt_path=$receiptPath}
    }
    return [ordered]@{ok=$false;schema_version=1;status='LabFailed';eligible_for_finalize=$false;error_code=$receipt.error_code;message=$failure;run_directory=$run;receipt_path=$receiptPath}
}

try { $result=Invoke-ViewLab; ConvertTo-Json -InputObject $result -Depth 20 -Compress; if(!$result.ok) {exit 1} }
catch { ConvertTo-Json -InputObject ([ordered]@{ok=$false;schema_version=1;status='LabFailed';eligible_for_finalize=$false;error_code='SCOPE_INVALID';message=$_.Exception.Message;run_directory=$null;receipt_path=$null}) -Compress; exit 1 }
