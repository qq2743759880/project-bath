[CmdletBinding()]
param(
    [ValidateSet('Help','Prepare','Status','Apply','Restore','Finalize','Cancel','Check','Close')][string]$Action = 'Help',
    [string]$Root, [string]$Plan, [string]$Batch, [string]$CheckScript, [string]$Receipt, [string]$Scope, [switch]$Group
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ArchiveRoot = 'D:\project-bath'
$script:ToolPath = $PSCommandPath

# Only the public PowerShell entry is exposed. Native helpers keep a locked handle
# from comparison through IO; no path-based delete after a hash check.
function Initialize-Native {
    if ('BathNative' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Win32.SafeHandles;
public sealed class BathSnapshot {
    public byte[] Bytes; public string Hash; public string Id; public long WriteTime;
}
public static class BathNative {
    [StructLayout(LayoutKind.Sequential, Pack=4)] struct Info {
        public uint Attributes; public long Creation, Access, Write;
        public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern SafeFileHandle CreateFileW(string p,uint access,uint share,IntPtr sa,uint mode,uint flags,IntPtr t);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool GetFileInformationByHandle(SafeFileHandle h,out Info i);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool GetFileInformationByHandleEx(SafeFileHandle h,int c,IntPtr b,uint n);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool SetFileInformationByHandle(SafeFileHandle h,int c,IntPtr b,uint n);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern uint GetFinalPathNameByHandleW(SafeFileHandle h,StringBuilder b,uint n,uint flags);
    static void Error(string code) { throw new IOException(code+": "+new Win32Exception(Marshal.GetLastWin32Error()).Message); }
    static Info Get(SafeFileHandle h) { Info i; if(!GetFileInformationByHandle(h,out i)) Error("FILE_INFO_FAILED"); return i; }
    public static string Id(SafeFileHandle h) { var i=Get(h); return i.Volume.ToString("x8")+":"+i.IndexHigh.ToString("x8")+i.IndexLow.ToString("x8"); }
    static void FinalPath(SafeFileHandle h,string expected) {
        var b=new StringBuilder(520); var count=GetFinalPathNameByHandleW(h,b,520,0);
        if(count==0 || count>=520) Error("FINAL_PATH_FAILED");
        var actual=b.ToString();
        if(!actual.StartsWith(@"\\?\") || !String.Equals(actual.Substring(4).TrimEnd('\\'),Path.GetFullPath(expected).TrimEnd('\\'),StringComparison.OrdinalIgnoreCase))
            throw new IOException("UNSUPPORTED_PATH: alias or backing volume differs");
    }
    public static SafeFileHandle Directory(string path) {
        var h=CreateFileW(path,128,1,IntPtr.Zero,3,0x02200000,IntPtr.Zero);
        if(h.IsInvalid) { h.Dispose(); Error("DIRECTORY_LOCK_FAILED"); }
        try {
            var i=Get(h);
            if((i.Attributes&0x400)!=0 || (i.Attributes&16)==0) throw new IOException("UNSUPPORTED_DIRECTORY: reparse or non-directory");
            FinalPath(h,path);
            var b=Marshal.AllocHGlobal(4);
            try { if(!GetFileInformationByHandleEx(h,23,b,4)) Error("CASE_INFO_UNAVAILABLE");
                if(Marshal.ReadInt32(b)!=0) throw new IOException("UNSUPPORTED_DIRECTORY: case-sensitive directory"); }
            finally { Marshal.FreeHGlobal(b); }
            return h;
        } catch { h.Dispose(); throw; }
    }
    public static void Regular(SafeFileHandle h) {
        var i=Get(h);
        if((i.Attributes & ~(uint)(32|128))!=0 || i.Links!=1)
            throw new IOException("UNSUPPORTED_FILE: attributes, hardlink or special file");
        var b=Marshal.AllocHGlobal(65536);
        try {
            if(!GetFileInformationByHandleEx(h,7,b,65536)) Error("STREAM_INFO_FAILED");
            int next=Marshal.ReadInt32(b), length=Marshal.ReadInt32(b,4);
            if(next!=0 || length!=14 || Marshal.PtrToStringUni(IntPtr.Add(b,24),length/2)!="::$DATA")
                throw new IOException("UNSUPPORTED_FILE: alternate data streams");
        } finally { Marshal.FreeHGlobal(b); }
    }
    public static FileStream Open(string path,bool mutation) {
        uint access=mutation ? 0xc0010000u : 0x80000000u;
        var h=CreateFileW(path,access,1,IntPtr.Zero,3,0x00200000,IntPtr.Zero);
        if(h.IsInvalid) { h.Dispose(); Error("FILE_LOCK_FAILED"); }
        try { Regular(h); FinalPath(h,path); return new FileStream(h,mutation?FileAccess.ReadWrite:FileAccess.Read); }
        catch { h.Dispose(); throw; }
    }
    public static string Hash(byte[] bytes) { return Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant(); }
    public static BathSnapshot Capture(FileStream f) {
        if(f.Length>16777216) throw new IOException("UNSUPPORTED_SIZE: limit 16 MiB");
        var i=Get(f.SafeFileHandle); var bytes=new byte[(int)f.Length]; f.Position=0;
        f.ReadExactly(bytes,0,bytes.Length);
        return new BathSnapshot { Bytes=bytes,Hash=Hash(bytes),Id=Id(f.SafeFileHandle),WriteTime=i.Write };
    }
    public static BathSnapshot Read(string p) { using(var f=Open(p,false)) return Capture(f); }
    public static void WriteNew(string p,byte[] bytes) {
        using(var f=new FileStream(p,FileMode.CreateNew,FileAccess.ReadWrite,FileShare.None)) {
            Regular(f.SafeFileHandle); f.Write(bytes,0,bytes.Length); f.Flush(true);
        }
    }
    public static void ReplaceBytes(FileStream f,byte[] bytes) {
        f.Position=0; f.Write(bytes,0,bytes.Length); f.SetLength(bytes.Length); f.Flush(true);
    }
    public static void Retire(FileStream f) {
        var b=Marshal.AllocHGlobal(4);
        try { Marshal.WriteInt32(b,1); if(!SetFileInformationByHandle(f.SafeFileHandle,4,b,4)) Error("RETIRE_FAILED"); }
        finally { Marshal.FreeHGlobal(b); }
    }
    // Same-parent handle rename, validated by retained disposable Native seam proofs.
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    struct RenameInfo { public uint ReplaceIfExists; public IntPtr RootDirectory; public uint FileNameLength; public ushort FirstCharacter; }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    struct StreamData { public long Size; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=296)] public string Name; }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern IntPtr FindFirstStreamW(string path,int level,out StreamData data,uint flags);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool FindClose(IntPtr handle);

    public static void OrdinaryDirectory(SafeFileHandle h,string path) {
        var i=Get(h);
        if((i.Attributes&16)==0 || (i.Attributes&~(uint)(16|32|128))!=0)
            throw new IOException("UNSUPPORTED_DIRECTORY: attributes or non-directory");
        FinalPath(h,path);
        var b=Marshal.AllocHGlobal(4);
        try { if(!GetFileInformationByHandleEx(h,23,b,4)) Error("CASE_INFO_UNAVAILABLE");
            if(Marshal.ReadInt32(b)!=0) throw new IOException("UNSUPPORTED_DIRECTORY: case-sensitive directory"); }
        finally { Marshal.FreeHGlobal(b); }
        StreamData streams;
        var search=FindFirstStreamW(path,0,out streams,0);
        if(search==new IntPtr(-1)) {
            int code=Marshal.GetLastWin32Error();
            if(code!=38) throw new IOException("DIRECTORY_STREAM_INFO_FAILED: win32="+code+" "+new Win32Exception(code).Message);
        } else {
            FindClose(search);
            throw new IOException("UNSUPPORTED_DIRECTORY: alternate data streams");
        }
    }
    public static SafeFileHandle DirectoryMutation(string path) {
        var h=CreateFileW(path,0x10080,1,IntPtr.Zero,3,0x02200000,IntPtr.Zero);
        if(h.IsInvalid) { h.Dispose(); Error("DIRECTORY_MUTATION_LOCK_FAILED"); }
        try { OrdinaryDirectory(h,path); return h; } catch { h.Dispose(); throw; }
    }
    public static void RenameDirectoryNoReplace(SafeFileHandle h,string destination) {
        if(!Path.IsPathFullyQualified(destination)) throw new IOException("BAD_RENAME_PATH: absolute destination required");
        var current=new StringBuilder(520);
        uint count=GetFinalPathNameByHandleW(h,current,520,0);
        if(count==0 || count>=520 || !current.ToString().StartsWith(@"\\?\")) Error("FINAL_PATH_FAILED");
        string source=current.ToString().Substring(4), target=Path.GetFullPath(destination);
        if(!String.Equals(Path.GetDirectoryName(source),Path.GetDirectoryName(target),StringComparison.OrdinalIgnoreCase) || String.Equals(source,target,StringComparison.OrdinalIgnoreCase) || Path.GetFileName(target).IndexOf(':')>=0)
            throw new IOException("BAD_RENAME_PATH: distinct same-parent basename required");
        OrdinaryDirectory(h,source);
        byte[] name=Encoding.Unicode.GetBytes(target);
        int offset=Marshal.OffsetOf<RenameInfo>("FirstCharacter").ToInt32();
        var buffer=Marshal.AllocHGlobal(offset+name.Length+2);
        try {
            Marshal.Copy(new byte[offset+name.Length+2],0,buffer,offset+name.Length+2);
            Marshal.WriteInt32(buffer,Marshal.OffsetOf<RenameInfo>("FileNameLength").ToInt32(),name.Length);
            Marshal.Copy(name,0,IntPtr.Add(buffer,offset),name.Length);
            if(!SetFileInformationByHandle(h,3,buffer,(uint)(offset+name.Length+2))) {
                int code=Marshal.GetLastWin32Error();
                throw new IOException("RENAME_FAILED: win32="+code+" "+new Win32Exception(code).Message);
            }
            FinalPath(h,target);
        } finally { Marshal.FreeHGlobal(buffer); }
    }

}
'@
}

function Get-LocalPath([string]$Value) {
    if (!$Value -or $Value -notmatch '^[A-Za-z]:[\\/]' -or $Value -match '(^\\\\|[?*])') { throw 'BAD_PATH: absolute local drive path required' }
    $p = [IO.Path]::GetFullPath($Value)
    if ($p.Length -gt [IO.Path]::GetPathRoot($p).Length) { $p=$p.TrimEnd('\') }
    if ($p.Length -gt 220) { throw 'UNSUPPORTED_PATH: length exceeds slice-one limit' }
    $drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($p))
    if (!$drive.IsReady -or $drive.DriveType -ne 'Fixed' -or $drive.DriveFormat -ne 'NTFS') { throw 'UNSUPPORTED_VOLUME: fixed local NTFS required' }
    return $p
}

function Pin-Directory([string]$PathValue, $Pins) {
    $p = Get-LocalPath $PathValue
    $drive = [IO.Path]::GetPathRoot($p)
    $current = $drive
    $handle = [BathNative]::Directory($current); $Pins.Add($handle)
    foreach ($part in $p.Substring($drive.Length).Split('\', [StringSplitOptions]::RemoveEmptyEntries)) {
        $current = [IO.Path]::Combine($current,$part)
        $handle = [BathNative]::Directory($current); $Pins.Add($handle)
    }
    return [BathNative]::Id($handle)
}

function New-PinnedDirectory([string]$PathValue, $Pins) {
    if (![IO.Directory]::Exists($PathValue)) { [void][IO.Directory]::CreateDirectory($PathValue) }
    [void](Pin-Directory $PathValue $Pins)
}

function Get-Json([string]$PathValue) {
    $s = [BathNative]::Read($PathValue)
    return ([Text.UTF8Encoding]::new($false,$true).GetString($s.Bytes) | ConvertFrom-Json -AsHashtable -Depth 20)
}

function Read-PinnedFile([string]$PathValue,$Pins) {
    $f = [BathNative]::Open($PathValue,$false)
    $Pins.Add($f)
    return [BathNative]::Capture($f)
}

function New-Json([string]$PathValue, $Data) {
    $bytes = [Text.Encoding]::UTF8.GetBytes(($Data | ConvertTo-Json -Depth 20 -Compress))
    [BathNative]::WriteNew($PathValue,$bytes)
}

function Write-Lease([string]$PathValue,[string]$Owner,[string]$IntentHash='') {
    $bytes = [Text.Encoding]::UTF8.GetBytes((@{owner=$Owner; intent_sha256=$IntentHash} | ConvertTo-Json -Compress))
    # Same-volume rename of a fully flushed control file prevents a killed process
    # leaving a half-written lease. Unique temporary files remain as evidence.
    if ([IO.File]::Exists($PathValue)) { $check=[BathNative]::Read($PathValue) }
    $temporary=$PathValue+'.'+[Guid]::NewGuid().ToString('N')+'.pending'
    [BathNative]::WriteNew($temporary,$bytes)
    [IO.File]::Move($temporary,$PathValue,$true)
}

function Check-Keys($Data,[string[]]$Required,[string[]]$Optional=@()) {
    if ($Data -isnot [Collections.IDictionary]) { throw 'BAD_SCHEMA: expected object' }
    foreach ($key in $Required) { if (!$Data.Contains($key)) { throw "BAD_SCHEMA: missing $key" } }
    foreach ($key in $Data.Keys) { if ($key -cnotin ($Required+$Optional)) { throw "BAD_SCHEMA: unknown $key" } }
}

function Read-Plan([byte[]]$Bytes) {
    $p = [Text.UTF8Encoding]::new($false,$true).GetString($Bytes) | ConvertFrom-Json -AsHashtable -Depth 10
    Check-Keys $p @('schema_version','entries')
    if ($p.schema_version -ne 1 -or $p.entries -isnot [array] -or $p.entries.Count -ne 1) { throw 'BAD_SCHEMA: slice one accepts one file only' }
    $e = $p.entries[0]
    Check-Keys $e @('path','action','before_sha256','after_sha256','evidence') @('replacement_path')
    if ($e.path -isnot [string] -or $e.path -notmatch '^[^\\/:*?"<>|]+([\\/][^\\/:*?"<>|]+)*$') { throw 'BAD_PATH: relative regular path required' }
    foreach($part in ($e.path -split '[\\/]')) {
        if ($part -in @('.','..') -or $part.EndsWith('.') -or $part.EndsWith(' ') -or $part -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)') { throw 'BAD_PATH: ambiguous or device path' }
    }
    if ($e.action -cnotin @('archive','edit') -or $e.before_sha256 -cnotmatch '^[a-f0-9]{64}$' -or $e.evidence -isnot [string] -or !$e.evidence.Trim()) { throw 'BAD_SCHEMA: invalid entry' }
    if ($e.action -eq 'archive') {
        if ($e.after_sha256 -cne 'absent' -or $e.Contains('replacement_path')) { throw 'BAD_SCHEMA: archive expects absent without replacement' }
    } elseif (!$e.Contains('replacement_path') -or $e.after_sha256 -cnotmatch '^[a-f0-9]{64}$') { throw 'BAD_SCHEMA: edit requires replacement and expected hash' }
    return $e
}

function Write-Event([string]$BatchPath,[string]$State,[string]$ManifestHash,[string]$TargetId='',[long]$WriteTime=0,[string]$EvidenceHash='',[string]$ReceiptName='',[string]$CheckAttemptId='') {
    $path = Join-Path $BatchPath 'journal.jsonl'
    $record = @{state=$State; manifest_sha256=$ManifestHash; target_id=$TargetId; write_time=$WriteTime; utc=[DateTime]::UtcNow.ToString('o'); event_id=[Guid]::NewGuid().ToString('N')}
    if ($CheckAttemptId) { $record.check_attempt_event_id=$CheckAttemptId; if($State -ceq 'CheckStarted'){$record.event_id=$CheckAttemptId} }
    if ($EvidenceHash) { $record.receipt_sha256=$EvidenceHash; $record.receipt_name=$ReceiptName }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($record | ConvertTo-Json -Compress)+"`n")
    $f = [IO.FileStream]::new($path,[IO.FileMode]::Append,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try { [BathNative]::Regular($f.SafeFileHandle); $f.Write($bytes,0,$bytes.Length); $f.Flush($true) } finally { $f.Dispose() }
}

function Read-Events([string]$BatchPath,[string]$ManifestHash) {
    $path = Join-Path $BatchPath 'journal.jsonl'
    $raw = [Text.UTF8Encoding]::new($false,$true).GetString(([BathNative]::Read($path)).Bytes)
    if (!$raw.EndsWith("`n")) { throw 'INCOMPLETE_JOURNAL: preserve files and inspect last operation' }
    $events = @($raw.TrimEnd("`n").Split("`n") | ForEach-Object { $_ | ConvertFrom-Json -AsHashtable })
    foreach ($event in $events) {
        Check-Keys $event @('state','manifest_sha256','target_id','write_time','utc','event_id') @('receipt_sha256','receipt_name','check_attempt_event_id')
        if ($event.manifest_sha256 -cne $ManifestHash -or $event.state -cnotin @('BackedUp','Applying','Applied','Restoring','Restored','CheckStarted','Checked','Completed')) { throw 'BAD_JOURNAL: binding or state mismatch' }
    }
    return ,$events
}

function Assert-Same($Snapshot,$Manifest) {
    if ($Snapshot.Hash -cne $Manifest.before_sha256 -or $Snapshot.Id -cne $Manifest.before_id -or $Snapshot.WriteTime -ne $Manifest.before_write_time) { throw 'TARGET_CHANGED: original bytes or identity changed; preserve current file' }
}

function Get-PostState([string]$Target,$Manifest,$ApplyEvent,$Pins) {
    if ($Manifest.action -eq 'archive') {
        if ([IO.File]::Exists($Target) -or [IO.Directory]::Exists($Target)) { throw 'POST_CHANGED: archive path is occupied; retain current object' }
        return @{exists=$false; sha256='absent'; id=''; write_time=0}
    }
    $s=Read-PinnedFile $Target $Pins
    if ($s.Hash -cne $Manifest.after_sha256 -or $s.Id -cne $ApplyEvent.target_id -or $s.WriteTime -ne $ApplyEvent.write_time) { throw 'POST_CHANGED: target no longer matches confirmed Apply event' }
    return @{exists=$true; sha256=$s.Hash; id=$s.Id; write_time=$s.WriteTime}
}

function Same-PostState($A,$B) {
    return $A.exists -eq $B.exists -and $A.sha256 -ceq $B.sha256 -and $A.id -ceq $B.id -and $A.write_time -eq $B.write_time
}

function Read-CheckTree([string]$Tree,$Pins,[string]$CopyTo='') {
    # Bounded ordinary-file view, not a sandbox. Refuse unsupported trees before
    # running user code; hold originals against writes/deletes until receipt.
    $queue=[Collections.Generic.Queue[string]]::new(); $queue.Enqueue($Tree)
    $items=[Collections.Generic.List[object]]::new(); [long]$total=0; $count=0; $dirs=0
    while ($queue.Count) {
        $dir=$queue.Dequeue(); [void](Pin-Directory $dir $Pins)
        if (++$dirs -gt 512) { throw 'CHECK_SCOPE: more than 512 directories' }
        foreach ($path in [IO.Directory]::GetFileSystemEntries($dir) | Sort-Object -CaseSensitive) {
            $full=Get-LocalPath $path
            $relative=[IO.Path]::GetRelativePath($Tree,$full)
            $attributes=[IO.File]::GetAttributes($full)
            if ($attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'CHECK_SCOPE: reparse object in check view' }
            if ($attributes -band [IO.FileAttributes]::Directory) {
                $items.Add([ordered]@{path=$relative;kind='directory'})
                if ($CopyTo) { [void][IO.Directory]::CreateDirectory((Get-LocalPath (Join-Path $CopyTo $relative))) }
                $queue.Enqueue($full)
            } else {
                if (([IO.FileInfo]::new($full)).Length -gt 16777216) { throw 'CHECK_SCOPE: file size exceeds bounded check view' }
                $snapshot=Read-PinnedFile $full $Pins
                $total+=$snapshot.Bytes.Length
                if ($total -gt 67108864) { throw 'CHECK_SCOPE: check view exceeds 64 MiB' }
                $items.Add([ordered]@{path=$relative;kind='file';sha256=$snapshot.Hash;id=$snapshot.Id;write_time=$snapshot.WriteTime})
                if ($CopyTo) { [BathNative]::WriteNew((Get-LocalPath (Join-Path $CopyTo $relative)),$snapshot.Bytes) }
            }
        }
    }
    return ,$items.ToArray()
}

function Tree-Hash($Items) {
    $json=ConvertTo-Json -InputObject $Items -Depth 8 -Compress
    return [BathNative]::Hash([Text.Encoding]::UTF8.GetBytes($json))
}

function Run-Check([string]$ScriptFile,[string]$ProjectRoot) {
    $start=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $start.WorkingDirectory=$ProjectRoot
    $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    $start.StandardOutputEncoding=[Text.Encoding]::UTF8; $start.StandardErrorEncoding=[Text.Encoding]::UTF8
    foreach ($arg in @('-NoProfile','-File',$ScriptFile,'-ProjectRoot',$ProjectRoot)) { $start.ArgumentList.Add($arg) }
    $p=[Diagnostics.Process]::new(); $p.StartInfo=$start
    try {
        [void]$p.Start(); $out=$p.StandardOutput.ReadToEndAsync(); $err=$p.StandardError.ReadToEndAsync()
        if (!$p.WaitForExit(30000)) { $p.Kill($true); $p.WaitForExit(); throw 'CHECK_TIMEOUT: check exceeded 30 seconds; no PASS receipt' }
        return @{exit_code=$p.ExitCode; stdout=$out.GetAwaiter().GetResult(); stderr=$err.GetAwaiter().GetResult()}
    } finally { $p.Dispose() }
}

function Get-ScopedRuntime($Pins) {
    $hashes=[ordered]@{}
    foreach($name in @('bath.ps1','bath-scope.ps1','bath-view.ps1')) {
        $hashes[$name]=(Read-PinnedFile (Join-Path $PSScriptRoot $name) $Pins).Hash
    }
    return $hashes
}

function Assert-ScopedRuntime($Expected,$Pins) {
    Check-Keys $Expected @('bath.ps1','bath-scope.ps1','bath-view.ps1')
    $current=Get-ScopedRuntime $Pins
    foreach($name in $current.Keys) {
        if($current[$name] -cne $Expected[$name]) { throw 'TOOL_CHANGED: scoped runtime changed; Restore remains available' }
    }
}

function Get-ScopedHash($Snapshot) {
    $data=ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $Snapshot -Depth 20 -Compress) -AsHashtable
    [void]$data.Remove('snapshot_sha256')
    return [BathNative]::Hash([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $data -Depth 20 -Compress)))
}

function Read-ScopedState($M,[string]$BatchPath,[string]$RootPath,$Pins,$ApplyEvent=$null,$After=$null) {
    $binding=$M.check_scope
    Check-Keys $binding @('schema_version','scope_sha256','scope_id','scope_write_time','before_snapshot_sha256','runtime_sha256')
    if($binding.schema_version -ne 1) { throw 'BAD_SCOPE_BINDING: unsupported binding' }
    Assert-ScopedRuntime $binding.runtime_sha256 $Pins
    . (Join-Path $PSScriptRoot 'bath-scope.ps1')
    $scopePath=Join-Path $BatchPath 'scope.json'
    $scopeBytes=Read-PinnedFile $scopePath $Pins
    if($scopeBytes.Hash -cne $binding.scope_sha256 -or $scopeBytes.Id -cne $binding.scope_id -or $scopeBytes.WriteTime.ToString() -cne $binding.scope_write_time) { throw 'SCOPE_CHANGED: saved scope bytes or identity changed' }
    $before=Read-PinnedFile (Join-Path $BatchPath 'scope-before.json') $Pins
    if($before.Hash -cne $binding.before_snapshot_sha256) { throw 'SCOPE_CHANGED: Prepare input snapshot changed' }
    $expected=ConvertFrom-Json -InputObject ([Text.Encoding]::UTF8.GetString($before.Bytes)) -AsHashtable -Depth 20
    if((Get-ScopedHash $expected) -cne $expected.snapshot_sha256) { throw 'BAD_SCOPE_BINDING: invalid Prepare snapshot' }
    $relative=$M.path.Replace('\','/')
    if($ApplyEvent) {
        $old=@($expected.files | Where-Object {$_.path.Equals($relative,[StringComparison]::OrdinalIgnoreCase)})
        if($old.Count -ne 1) { throw 'BAD_SCOPE_BINDING: target missing from prepared inputs' }
        $expected.stats.total_bytes-=$old[0].bytes
        if($M.action -eq 'archive') {
            $expected.files=@($expected.files | Where-Object {!$_.path.Equals($relative,[StringComparison]::OrdinalIgnoreCase)})
            $expected.stats.files=$expected.files.Count
        } else {
            $old[0].sha256=$M.after_sha256; $old[0].id=$ApplyEvent.target_id
            $old[0].write_time=$ApplyEvent.write_time.ToString(); $old[0].bytes=$After.Bytes.Length
            $expected.stats.total_bytes+=$old[0].bytes
        }
    }
    $current=Read-BathScope -Root $RootPath -Scope $scopePath -ProtectedPaths $relative
    if($current.snapshot_sha256 -cne (Get-ScopedHash $expected)) { throw 'SCOPE_CHANGED: selected project state differs from the bound batch transition' }
    return $current
}

function Invoke-ScopedView([string]$RootPath,[string]$ScopePath,[string]$ScriptPath,[string]$Relative,[int]$Timeout) {
    # ponytail: reuse the proven CLI; this parent only bounds its control output.
    $start=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    $start.StandardOutputEncoding=[Text.Encoding]::UTF8; $start.StandardErrorEncoding=[Text.Encoding]::UTF8
    foreach($arg in @('-NoProfile','-File',(Join-Path $PSScriptRoot 'bath-view.ps1'),'-Root',$RootPath,'-Scope',$ScopePath,'-CheckScript',$ScriptPath,'-ProtectedPaths',$Relative)) { $start.ArgumentList.Add($arg) }
    $process=[Diagnostics.Process]::new();$process.StartInfo=$start
    try {
        [void]$process.Start();$stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
        if(!$process.WaitForExit(($Timeout*4+20)*1000)) {
            $process.Kill($true)
            if(!$process.WaitForExit(10000)) { throw 'CHECK_TIMEOUT: scoped worker did not stop' }
            throw 'CHECK_TIMEOUT: scoped worker exceeded bounded preparation/check/guard time'
        }
        $json=$stdout.GetAwaiter().GetResult();$diagnostic=$stderr.GetAwaiter().GetResult()
        $result=ConvertFrom-Json -InputObject $json -AsHashtable -Depth 20
        if(!$result.ok) { throw ($result.error_code+': '+$result.message) }
        if($process.ExitCode -ne 0 -or $result.status -cne 'LabPassed' -or $result.eligible_for_finalize -ne $false) { throw 'CHECK_FAILED: invalid lab outcome' }
        return $result
    } finally { $process.Dispose() }
}

function Read-RetainedEvidence([string]$Run,[string]$Inspection,$Pins) {
    . (Join-Path $PSScriptRoot 'bath-scope.ps1')
    $full=Get-LocalPath $Run
    if(!$full.StartsWith('D:\project-bath\',[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -cnotmatch '^view-[a-f0-9-]{36}$') { throw 'BAD_RECEIPT: invalid retained run path' }
    [void](Pin-Directory $full $Pins)
    $snapshot=Read-BathScope -Root $full -Scope $Inspection
    foreach($file in $snapshot.files) {
        $bound=Read-PinnedFile (Join-Path $full $file.path) $Pins
        if($bound.Hash -cne $file.sha256 -or $bound.Id -cne $file.id -or $bound.WriteTime.ToString() -cne $file.write_time) { throw 'EVIDENCE_CHANGED: retained file changed during inspection' }
    }
    foreach($directory in $snapshot.directories) {
        $path=if($directory.path -eq '.') {$full} else {Join-Path $full $directory.path}
        if((Pin-Directory $path $Pins) -cne $directory.id) { throw 'EVIDENCE_CHANGED: retained directory identity changed' }
    }
    return $snapshot
}

function Copy-PinnedCheck([string]$Path,$Snapshot,$Pins) {
    [BathNative]::WriteNew($Path,$Snapshot.Bytes)
    $copy=Read-PinnedFile $Path $Pins
    if($copy.Hash -cne $Snapshot.Hash) { throw 'CHECK_SCRIPT_CHANGED: copied check differs from selected script' }
    return $copy
}

function Assert-LabEvidence($Lab,$Retained,[string]$Run,[string]$ScriptHash,$scopeSnapshot,$Pins) {
    # Validate original lab evidence before sealing it; a new hash cannot bless tampering.
    $hashes=@{'stdout.log'=$Lab.stdout_sha256;'stderr.log'=$Lab.stderr_sha256;'check.ps1'=$ScriptHash;'scope.json'=$scopeSnapshot.scope_sha256;'launch.ps1'=$Lab.runtime_sha256['launch.ps1'];'process-evidence.json'=$Lab.process_evidence_sha256;'input-bindings.json'=$Lab.input_bindings_sha256;'view-source-before.json'=$Lab.view_source_before_sha256;'view-source-after.json'=$Lab.view_source_after_sha256}
    foreach($name in $hashes.Keys) {
        $file=@($Retained.files | Where-Object {$_.path -ceq $name})
        if($file.Count -ne 1 -or $file[0].sha256 -cne $hashes[$name]) { throw 'EVIDENCE_CHANGED: original lab evidence changed before seal' }
    }
    $expectedInspection=[ordered]@{schema_version=1;inputs=@('.');excluded=@();outputs=@();limits=$scopeSnapshot.limits}
    $inspectHash=[BathNative]::Hash([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $expectedInspection -Depth 25 -Compress)))
    $internal=@($Retained.files | Where-Object {$_.path -ceq 'inspect-scope.json'})
    if($internal.Count -ne 1 -or $internal[0].sha256 -cne $inspectHash) { throw 'EVIDENCE_CHANGED: lab inspection control changed' }
    $inputSnapshot=Get-Json (Join-Path $Run 'input-snapshot.json')
    if((Get-ScopedHash $inputSnapshot) -cne $Lab.input_snapshot_sha256 -or $Lab.input_snapshot_sha256 -cne $scopeSnapshot.snapshot_sha256) { throw 'EVIDENCE_CHANGED: original lab input snapshot changed' }
    $ledger=Get-Json (Join-Path $Run 'view-source-after.json')
    $allowedFiles=@()
    foreach($entry in @($ledger.files)+@($Lab.outputs.files)) {
        $path='view/'+$entry.path; $allowedFiles+=,$path
        $actual=@($Retained.files | Where-Object {$_.path -ceq $path})
        if($actual.Count -ne 1 -or $actual[0].sha256 -cne $entry.sha256 -or $actual[0].bytes -ne $entry.bytes) { throw 'EVIDENCE_CHANGED: lab source/output bytes changed before seal' }
        if($entry.Contains('id') -and ($actual[0].id -cne $entry.id -or $actual[0].write_time -cne $entry.write_time)) { throw 'EVIDENCE_CHANGED: lab source identity changed before seal' }
    }
    foreach($entry in $ledger.directories) {
        $path=if($entry.path -eq '.') {'view'} else {'view/'+$entry.path}
        $actual=@($Retained.directories | Where-Object {$_.path -ceq $path})
        if($actual.Count -ne 1 -or $actual[0].id -cne $entry.id) { throw 'EVIDENCE_CHANGED: lab source parent identity changed before seal' }
    }
    $allowedDirs=@($ledger.directories | ForEach-Object {if($_.path -eq '.'){'view'}else{'view/'+$_.path}})+@($Lab.outputs.directories | ForEach-Object {'view/'+$_})
    foreach($entry in $Retained.files) { if($entry.path.StartsWith('view/') -and $entry.path -cnotin $allowedFiles) { throw 'EVIDENCE_CHANGED: unrecorded lab view file' } }
    foreach($entry in $Retained.directories) { if(($entry.path -eq 'view' -or $entry.path.StartsWith('view/')) -and $entry.path -cnotin $allowedDirs) { throw 'EVIDENCE_CHANGED: unrecorded lab view directory' } }
}

function Invoke-Bath {
    $pins = [Collections.Generic.List[IDisposable]]::new()
    $projectLock = $null; $source = $null; $createdBatch = $null
    try {
        if ($Action -eq 'Help') {
            return @{ok=$true; operations=@('Prepare','Status','Apply','Restore','Cancel','Check','Finalize','Close'); requires='Windows, PowerShell 7.4+, local fixed NTFS; ordinary files <=16 MiB each; default one file, -Group for related files'; plan='schema_version=1; entries=[{path,action:archive|edit,before_sha256,after_sha256:absent|hash,evidence,replacement_path(for edit)}]'; archive='D:/project-bath'; group='Use -Group: schema2 related file edit/archive; schema4 one same-parent directory rename plus associated original-path file entries. Prepare,Status,Apply,Restore,Check,Finalize,Close. All edited/archive originals saved before rename; other moved children have namespace evidence only. Latest CheckStarted attempt required; no ACID, tree-byte backup or merge'; scoped='Prepare optionally takes -Scope JSON; one file archive/edit; scoped Check scripts take -ViewRoot and may create declared outputs; schema4 maps scope paths after rename'; checks='Check runs trusted read-only PowerShell on retained D view; original read locks and tree change detection; no fixed file-count limit; 512 directories/64 MiB/30s; Finalize -Receipt <returned receipt>'; limits='Close only stops ambiguous/conflicted batches without restoring; Agent selects meaningful checks; no semantic correctness proof, merge or host-wide enforcement'}
        }
        if (!$IsWindows -or $PSVersionTable.PSVersion -lt [version]'7.4') { throw 'UNSUPPORTED_HOST: PowerShell 7.4+ on Windows required' }
        Initialize-Native
        $rootPath = Get-LocalPath $Root
        if ($rootPath -like 'D:\project-bath*') { throw 'BAD_ROOT: cold archive cannot be the project' }
        $rootId = Pin-Directory $rootPath $pins
        $canonical = $rootPath.Replace('\','/').ToLowerInvariant()
        $rootHash = [BathNative]::Hash([Text.Encoding]::UTF8.GetBytes($canonical))
        $projectName = [IO.Path]::GetFileName($rootPath)
        $projectPath = Join-Path $script:ArchiveRoot ($projectName+'-'+$rootHash.Substring(0,8))
        $scopePre=$null; $scopeInput=$null; $scopeRuntime=$null
        if($Scope -and $Action -ne 'Prepare') { throw 'BAD_SCOPE: Scope is frozen by Prepare; do not override it later' }
        if($Action -eq 'Prepare' -and $Scope) {
            . (Join-Path $PSScriptRoot 'bath-scope.ps1')
            $scopeRuntime=Get-ScopedRuntime $pins
            $prePlan=Read-Plan ([BathNative]::Read((Get-LocalPath $Plan))).Bytes
            $scopePath=Get-LocalPath $Scope
            [void](Pin-Directory ([IO.Path]::GetDirectoryName($scopePath)) $pins)
            $scopeInput=Read-PinnedFile $scopePath $pins
            $scopePre=Read-BathScope -Root $rootPath -Scope $scopePath -ProtectedPaths $prePlan.path.Replace('\','/')
            foreach($file in $scopePre.files) {
                foreach($prefix in $scopePre.outputs) {
                    if(Test-ScopeUnder $file.path $prefix) { throw 'VIEW_SCOPE_CONFLICT: selected source intersects writable output; explicitly exclude generated content' }
                }
            }
            $scopeData=ConvertFrom-Json -InputObject ([Text.Encoding]::UTF8.GetString($scopeInput.Bytes)) -AsHashtable
            if($scopePre.scope_sha256 -cne $scopeInput.Hash) { throw 'SCOPE_CHANGED: scope changed during preflight' }
            if($prePlan.action -eq 'archive' -and @($scopeData.inputs | Where-Object {$_.Equals($prePlan.path.Replace('\','/'),[StringComparison]::OrdinalIgnoreCase)}).Count) { throw 'SCOPE_ARCHIVE_SELECTOR: archive requires an existing parent/root input selector' }
        }

        [void](Pin-Directory 'D:\' $pins)
        if ($Action -eq 'Prepare') { New-PinnedDirectory $script:ArchiveRoot $pins; New-PinnedDirectory $projectPath $pins }
        else { [void](Pin-Directory $projectPath $pins) }
        $identityPath = Join-Path $projectPath 'project.json'
        $leasePath = Join-Path $projectPath 'lease.json'
        if ($Action -ne 'Status') {
            $lockPath = Join-Path $projectPath 'operation.lock'
            if ([IO.File]::Exists($lockPath)) { $check = [BathNative]::Read($lockPath) }
            $projectLock = [IO.FileStream]::new($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
            [BathNative]::Regular($projectLock.SafeFileHandle)
        }
        if (![IO.File]::Exists($identityPath)) {
            if ($Action -ne 'Prepare') { throw 'BAD_PROJECT: missing identity' }
            New-Json $identityPath @{canonical_root=$canonical; root_sha256=$rootHash; root_id=$rootId}
        }
        $identity = Get-Json $identityPath
        Check-Keys $identity @('canonical_root','root_sha256','root_id')
        if ($identity.canonical_root -cne $canonical -or $identity.root_sha256 -cne $rootHash -or $identity.root_id -cne $rootId) { throw 'BAD_PROJECT: root identity mismatch or short hash collision' }
        if ($Action -eq 'Prepare') {
            if ([IO.File]::Exists($leasePath)) { $lease = Get-Json $leasePath; Check-Keys $lease @('owner') @('intent_sha256'); if ($lease.owner) { throw 'PROJECT_BUSY: another batch owns this project; restore or resolve it first' } }
            $planPath = Get-LocalPath $Plan
            [void](Pin-Directory ([IO.Path]::GetDirectoryName($planPath)) $pins)
            $planSnapshot = [BathNative]::Read($planPath)
            $entry = Read-Plan $planSnapshot.Bytes
            $target = Get-LocalPath (Join-Path $rootPath $entry.path)
            if (!$target.StartsWith($rootPath+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'BAD_PATH: target outside root' }
            $parentId = Pin-Directory ([IO.Path]::GetDirectoryName($target)) $pins
            $source = [BathNative]::Open($target,$false)
            $before = [BathNative]::Capture($source)
            $acl = Get-Acl -LiteralPath $target
            if ($acl.AreAccessRulesProtected -or $acl.GetAccessRules($true,$false,[Security.Principal.SecurityIdentifier]).Count -ne 0) { throw 'UNSUPPORTED_SECURITY: explicit/protected file ACL; slice one does not restore custom security' }
            if ($before.Hash -cne $entry.before_sha256) { throw 'TARGET_CHANGED: plan before hash does not match current file' }
            $after = $null
            if ($entry.action -eq 'edit') {
                $payloadPath = Get-LocalPath $entry.replacement_path
                [void](Pin-Directory ([IO.Path]::GetDirectoryName($payloadPath)) $pins)
                $after = [BathNative]::Read($payloadPath)
                if ($after.Hash -cne $entry.after_sha256) { throw 'PAYLOAD_CHANGED: replacement does not match approved hash' }
            }
            if($scopePre) {
                $again=Read-BathScope -Root $rootPath -Scope $scopePath -ProtectedPaths $entry.path.Replace('\','/')
                if($again.snapshot_sha256 -cne $scopePre.snapshot_sha256) { throw 'SCOPE_CHANGED: project changed during Prepare preflight' }
                if($after -and ($after.Bytes.Length -gt $scopePre.limits.max_file_bytes -or $scopePre.stats.total_bytes-$before.Bytes.Length+$after.Bytes.Length -gt $scopePre.limits.max_total_bytes)) { throw 'SCOPE_LIMIT: replacement exceeds scoped file/total byte budget' }
                Assert-ScopedRuntime $scopeRuntime $pins
            }
            $batchName = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfff')+'-'+[Guid]::NewGuid().ToString('N')
            $createdBatch = Join-Path $projectPath $batchName
            New-PinnedDirectory $createdBatch $pins
            $intentPath=Join-Path $createdBatch 'prepare-intent.json'
            New-Json $intentPath @{schema_version=1; batch=$batchName; canonical_root=$canonical; root_id=$rootId; plan_sha256=$planSnapshot.Hash; plan_id=$planSnapshot.Id; path=$entry.path; before_id=$before.Id; before_sha256=$before.Hash; before_write_time=$before.WriteTime; reason='Prepare owns project while copying and verifying original bytes'; utc=[DateTime]::UtcNow.ToString('o')}
            $intentHash=([BathNative]::Read($intentPath)).Hash
            # Intent is durable before lease acquisition; owner and intent hash
            # become visible together. No project mutation occurs in Prepare.
            Write-Lease $leasePath $batchName $intentHash
            try { [BathNative]::WriteNew((Join-Path $createdBatch 'before.bin'),$before.Bytes) }
            catch { throw ('BACKUP_FAILED: '+$_.Exception.Message) }
            [BathNative]::WriteNew((Join-Path $createdBatch 'plan.json'),$planSnapshot.Bytes)
            $copy = [BathNative]::Read((Join-Path $createdBatch 'before.bin'))
            if ($copy.Hash -cne $before.Hash) { throw 'BACKUP_FAILED: copied bytes mismatch' }
            if ($null -ne $after) { [BathNative]::WriteNew((Join-Path $createdBatch 'after.bin'),$after.Bytes) }
            $manifest = @{schema_version=1; slice='v0.2.0-slice1'; tool_sha256=(Get-FileHash -LiteralPath $script:ToolPath -Algorithm SHA256).Hash.ToLowerInvariant(); canonical_root=$canonical; root_id=$rootId; parent_id=$parentId; batch=$batchName; path=$entry.path; action=$entry.action; plan_sha256=$planSnapshot.Hash; before_sha256=$before.Hash; before_id=$before.Id; before_write_time=$before.WriteTime; after_sha256=$entry.after_sha256; backup_id=$copy.Id}
            if($scopePre) {
                $savedScope=Join-Path $createdBatch 'scope.json'
                [BathNative]::WriteNew($savedScope,$scopeInput.Bytes)
                $saved=Read-PinnedFile $savedScope $pins
                New-Json (Join-Path $createdBatch 'scope-before.json') $scopePre
                $manifest.check_scope=@{schema_version=1;scope_sha256=$saved.Hash;scope_id=$saved.Id;scope_write_time=$saved.WriteTime.ToString();before_snapshot_sha256=([BathNative]::Read((Join-Path $createdBatch 'scope-before.json'))).Hash;runtime_sha256=$scopeRuntime}
            }
            $manifestPath = Join-Path $createdBatch 'manifest.json'
            New-Json $manifestPath $manifest
            $manifestHash = ([BathNative]::Read($manifestPath)).Hash
            Write-Event $createdBatch 'BackedUp' $manifestHash
            return @{ok=$true; state='BackedUp'; batch=$createdBatch; before_sha256=$before.Hash; backup_sha256=$copy.Hash; target_volume=$before.Id.Split(':')[0]; backup_volume=$copy.Id.Split(':')[0]}
        }
        $batchPath = Get-LocalPath $Batch
        if ([IO.Path]::GetDirectoryName($batchPath) -cne $projectPath) { throw 'BAD_BATCH: expected direct child of this project archive' }
        [void](Pin-Directory $batchPath $pins)
        $cancelPath=Join-Path $batchPath 'cancelled.json'
        $intentPath=Join-Path $batchPath 'prepare-intent.json'
        $stopPath=Join-Path $batchPath 'stopped.json'
        if ($Action -eq 'Close' -or [IO.File]::Exists($stopPath)) {
            $intentSnapshot=Read-PinnedFile $intentPath $pins
            $intent=[Text.Encoding]::UTF8.GetString($intentSnapshot.Bytes) | ConvertFrom-Json -AsHashtable
            if ($intent.batch -cne [IO.Path]::GetFileName($batchPath) -or $intent.canonical_root -cne $canonical -or $intent.root_id -cne $rootId) { throw 'BAD_INTENT: project/batch mismatch' }
            $lease=Get-Json $leasePath; Check-Keys $lease @('owner') @('intent_sha256')
            $repeated=[IO.File]::Exists($stopPath)
            if ($repeated) {
                $terminal=Get-Json $stopPath
                if ($terminal.state -cne 'Stopped' -or $terminal.batch -cne $intent.batch -or $terminal.intent_sha256 -cne $intentSnapshot.Hash) { throw 'BAD_TERMINAL: stopped binding changed' }
            } else {
                if ($lease.owner -cne $intent.batch -or !$lease.Contains('intent_sha256') -or $lease.intent_sha256 -cne $intentSnapshot.Hash) { throw 'CLOSE_FORBIDDEN: only intact current owner may stop' }
                if ([IO.File]::Exists($cancelPath) -or ![IO.File]::Exists((Join-Path $batchPath 'journal.jsonl'))) { throw 'CLOSE_FORBIDDEN: incomplete Prepare uses Cancel' }
                $journalSnapshot=Read-PinnedFile (Join-Path $batchPath 'journal.jsonl') $pins
                $reason=''; $targetSnapshot=@{kind='unreadable'}
                try {
                    $cmSnapshot=Read-PinnedFile (Join-Path $batchPath 'manifest.json') $pins
                    $cm=[Text.Encoding]::UTF8.GetString($cmSnapshot.Bytes) | ConvertFrom-Json -AsHashtable
                    $ce=Read-Events $batchPath $cmSnapshot.Hash; $cl=$ce[-1]
                    if ($cl.state -eq 'Completed') {
                        if (![IO.File]::Exists((Join-Path $batchPath 'historical-restore.json'))) { throw 'CLOSE_FORBIDDEN: completed batch has no historical Restore attempt; retry Finalize' }
                        $hr=Read-PinnedFile (Join-Path $batchPath 'historical-restore.json') $pins
                        $hi=[Text.Encoding]::UTF8.GetString($hr.Bytes) | ConvertFrom-Json -AsHashtable
                        if ($hi.batch -cne $intent.batch -or $hi.manifest_sha256 -cne $cmSnapshot.Hash -or $hi.completed_event_id -cne $cl.event_id) { throw 'CLOSE_FORBIDDEN: no bound historical Restore intent; retry Finalize' }
                        $reason='Historical Restore intent with no confirmed Restoring event; stop without project writes'
                    }
                    elseif ($cl.state -in @('Applying','Restoring')) { $reason='Unconfirmed operation: '+$cl.state }
                    else {
                        $ct=Get-LocalPath (Join-Path $rootPath $intent.path)
                        $cpid=Pin-Directory ([IO.Path]::GetDirectoryName($ct)) $pins
                        if ($cpid -cne $cm.parent_id) { throw 'CONFLICT: target parent identity changed' }
                        $cb=Read-PinnedFile (Join-Path $batchPath 'before.bin') $pins
                        if ($cb.Hash -cne $cm.before_sha256 -or $cb.Id -cne $cm.backup_id) { throw 'CONFLICT: original backup changed' }
                        if ($cl.state -eq 'BackedUp') { $current=Read-PinnedFile $ct $pins; Assert-Same $current $cm }
                        elseif ($cl.state -eq 'Restored') {
                            $current=Read-PinnedFile $ct $pins
                            if ($current.Hash -cne $cm.before_sha256 -or $current.Id -cne $cl.target_id -or $current.WriteTime -ne $cl.write_time) { throw 'CONFLICT: restored target changed' }
                        } else {
                            $ca=@($ce | Where-Object state -eq 'Applied')
                            if (!$ca.Count) { throw 'CONFLICT: no confirmed Apply' }
                            $post=Get-PostState $ct $cm $ca[-1] $pins
                        }
                        throw 'CLOSE_FORBIDDEN: current state has a normal Restore/Finalize path'
                    }
                } catch {
                    if ($_.Exception.Message -match '^CLOSE_FORBIDDEN:') { throw }
                    $reason='Ambiguous/conflicted evidence: '+$_.Exception.Message
                }
                # Observe without writing. Unsupported/unreadable objects are
                # retained as-is, with a diagnostic instead of guessed content.
                try {
                    $ct=Get-LocalPath (Join-Path $rootPath $intent.path)
                    [void](Pin-Directory ([IO.Path]::GetDirectoryName($ct)) $pins)
                    if ([IO.File]::Exists($ct)) { $current=Read-PinnedFile $ct $pins; $targetSnapshot=@{kind='file'; sha256=$current.Hash; id=$current.Id; write_time=$current.WriteTime} }
                    elseif ([IO.Directory]::Exists($ct)) { $targetSnapshot=@{kind='directory'} }
                    else { $targetSnapshot=@{kind='absent'} }
                } catch { $targetSnapshot=@{kind='unreadable'; error=$_.Exception.Message} }
                New-Json $stopPath @{state='Stopped'; batch=$intent.batch; intent_sha256=$intentSnapshot.Hash; journal_sha256=$journalSnapshot.Hash; observed_target=$targetSnapshot; reason=$reason; utc=[DateTime]::UtcNow.ToString('o'); restored=$false; project_untouched=$true}
            }
            if ($Action -eq 'Status') { return @{ok=$true; state='Stopped'; observed='Stopped'; batch=$batchPath; terminal=$terminal; restored=$false} }
            if ($Action -ne 'Close') { throw 'BAD_STATE: stopped batch cannot mutate or declare verified' }
            if ($lease.owner -ceq $intent.batch) { Write-Lease $leasePath '' }
            return @{ok=$true; state='Stopped'; batch=$batchPath; repeated=$repeated; restored=$false; project_untouched=$true}
        }
        if ($Action -eq 'Cancel' -or [IO.File]::Exists($cancelPath)) {
            $intentSnapshot=Read-PinnedFile $intentPath $pins
            $intent=[Text.Encoding]::UTF8.GetString($intentSnapshot.Bytes) | ConvertFrom-Json -AsHashtable
            if ($intent.batch -cne [IO.Path]::GetFileName($batchPath) -or $intent.canonical_root -cne $canonical -or $intent.root_id -cne $rootId) { throw 'BAD_INTENT: project/batch binding mismatch' }
            $lease=Get-Json $leasePath; Check-Keys $lease @('owner') @('intent_sha256')
            if ([IO.File]::Exists((Join-Path $batchPath 'journal.jsonl'))) { throw 'CANCEL_FORBIDDEN: journal exists; use Restore/Finalize or safe Close' }
            $repeated=[IO.File]::Exists($cancelPath)
            if ($repeated) {
                $terminal=Get-Json $cancelPath
                if ($terminal.state -cne 'Cancelled' -or $terminal.intent_sha256 -cne $intentSnapshot.Hash) { throw 'BAD_TERMINAL: cancellation binding changed' }
            } else {
                if ($lease.owner -cne $intent.batch -or !$lease.Contains('intent_sha256') -or $lease.intent_sha256 -cne $intentSnapshot.Hash) { throw 'CANCEL_FORBIDDEN: only current owner with intact prepare intent may cancel' }
                New-Json $cancelPath @{state='Cancelled'; intent_sha256=$intentSnapshot.Hash; batch=$intent.batch; utc=[DateTime]::UtcNow.ToString('o'); reason='Incomplete Prepare stopped without project writes; all artifacts retained'}
            }
            if ($Action -eq 'Status') { return @{ok=$true; state='Cancelled'; observed='Cancelled'; batch=$batchPath; intent=$intent} }
            if ($Action -ne 'Cancel') { throw 'BAD_STATE: cancelled batch cannot mutate project' }
            if ($lease.owner -ceq $intent.batch) { Write-Lease $leasePath '' }
            return @{ok=$true; state='Cancelled'; batch=$batchPath; repeated=$repeated; project_untouched=$true}
        }
        $manifestPath = Join-Path $batchPath 'manifest.json'
        if (![IO.File]::Exists($manifestPath)) {
            if ($Action -ne 'Status') { throw 'INCOMPLETE_PREPARE: no verified manifest; project mutation blocked' }
            $lease = Get-Json $leasePath; Check-Keys $lease @('owner') @('intent_sha256')
            if ($lease.owner -cne [IO.Path]::GetFileName($batchPath)) { throw 'BAD_BATCH: incomplete batch is not active owner' }
            $intent=Get-Json $intentPath
            return @{ok=$true; state='Preparing'; observed='IncompletePrepare'; batch=$batchPath; backup_valid=$false; intent=$intent; next='Prepare made no project writes; Cancel can release this owner while retaining all evidence.'}
        }
        $manifestSnapshot = Read-PinnedFile $manifestPath $pins
        $m = [Text.UTF8Encoding]::new($false,$true).GetString($manifestSnapshot.Bytes) | ConvertFrom-Json -AsHashtable -Depth 20
        Check-Keys $m @('schema_version','slice','tool_sha256','canonical_root','root_id','parent_id','batch','path','action','plan_sha256','before_sha256','before_id','before_write_time','after_sha256','backup_id') @('check_scope')
        if ($m.schema_version -ne 1 -or $m.canonical_root -cne $canonical -or $m.root_id -cne $rootId -or $m.batch -cne [IO.Path]::GetFileName($batchPath)) { throw 'BAD_MANIFEST: project or batch mismatch' }
        $storedPlan = Read-PinnedFile (Join-Path $batchPath 'plan.json') $pins
        $entry = Read-Plan $storedPlan.Bytes
        if ($storedPlan.Hash -cne $m.plan_sha256 -or $entry.path -cne $m.path -or $entry.action -cne $m.action -or $entry.before_sha256 -cne $m.before_sha256 -or $entry.after_sha256 -cne $m.after_sha256) { throw 'BAD_BINDING: plan/manifest mismatch' }
        $backup = Read-PinnedFile (Join-Path $batchPath 'before.bin') $pins
        if ($backup.Hash -cne $m.before_sha256 -or $backup.Id -cne $m.backup_id) { throw 'BACKUP_FAILED: saved original hash or identity changed' }
        $after = $null
        if ($m.action -eq 'edit') { $after = Read-PinnedFile (Join-Path $batchPath 'after.bin') $pins; if ($after.Hash -cne $m.after_sha256) { throw 'PAYLOAD_CHANGED: bound replacement changed' } }
        $events = Read-Events $batchPath $manifestSnapshot.Hash
        $last = $events[-1]
        $applied=@($events | Where-Object state -eq 'Applied')
        $applyEvent=if($applied.Count){$applied[-1]}else{$null}
        $target = Get-LocalPath (Join-Path $rootPath $m.path)
        if (!$target.StartsWith($rootPath+'\',[StringComparison]::OrdinalIgnoreCase)) { throw 'BAD_PATH: outside root' }
        $parentId = Pin-Directory ([IO.Path]::GetDirectoryName($target)) $pins
        if ($parentId -cne $m.parent_id) { throw 'PARENT_CHANGED: target parent directory identity changed; preserve current directory' }
        if ($Action -eq 'Status') {
            $observed = 'Conflict'
            $current = $null
            if ([IO.File]::Exists($target)) { $current = [BathNative]::Read($target) }
            if ($last.state -eq 'Completed') {
                try { $post=Get-PostState $target $m $applyEvent $pins; $observed='Completed' } catch { $observed='ChangedAfterCompletion' }
            }
            elseif ($last.state -eq 'Restored' -and $current -and $current.Hash -ceq $m.before_sha256 -and $current.Id -ceq $last.target_id -and $current.WriteTime -eq $last.write_time) { $observed='Restored' }
            elseif ($last.state -eq 'Restoring') { $observed='InterruptedRestore' }
            elseif ($m.action -eq 'archive' -and !$current -and ![IO.Directory]::Exists($target) -and $last.state -in @('Applied','Applying','Checked','CheckStarted')) { $observed= if($last.state -eq 'Applying'){'AppliedUnconfirmed'}else{$last.state} }
            elseif ($current -and $current.Hash -ceq $m.before_sha256 -and $current.Id -ceq $m.before_id -and $current.WriteTime -eq $m.before_write_time -and $last.state -in @('BackedUp','Applying')) { $observed=if($last.state -eq 'BackedUp'){'BackedUp'}else{'BackedUpInterrupted'} }
            elseif ($m.action -eq 'edit' -and $current -and $current.Hash -ceq $m.after_sha256 -and $current.Id -ceq $m.before_id -and $last.state -in @('Applied','Applying','Checked','CheckStarted')) { $observed=if($applyEvent -and $current.WriteTime -eq $applyEvent.write_time){$last.state}elseif($last.state -eq 'Applying'){'AppliedUnconfirmed'}else{'Conflict'} }
            return @{ok=$true; state=$last.state; observed=$observed; batch=$batchPath; backup_valid=$true; last_event_id=$last.event_id; manifest_sha256=$manifestSnapshot.Hash}
        }
        $lease = Get-Json $leasePath; Check-Keys $lease @('owner') @('intent_sha256')
        if ($lease.owner -cne $m.batch -and $last.state -notin @('Restored','Completed')) { throw 'PROJECT_BUSY: batch is not active project owner' }
        if ($Action -eq 'Check') {
            if ($last.state -notin @('Applied','Checked','CheckStarted') -or !$applyEvent) { throw 'BAD_STATE: Check requires a confirmed Apply' }
            $checkAttemptId=[Guid]::NewGuid().ToString('N')
            Write-Event $batchPath 'CheckStarted' $manifestSnapshot.Hash $applyEvent.target_id $applyEvent.write_time '' '' $checkAttemptId
            if($m.Contains('check_scope')) {
                $scopeSnapshot=Read-ScopedState $m $batchPath $rootPath $pins $applyEvent $after
                $pre=Get-PostState $target $m $applyEvent $pins
                $scriptPath=Get-LocalPath $CheckScript
                [void](Pin-Directory ([IO.Path]::GetDirectoryName($scriptPath)) $pins)
                $scriptSnapshot=Read-PinnedFile $scriptPath $pins
                $receiptId=[Guid]::NewGuid().ToString('N')
                $checkCopy=Join-Path $batchPath ('check-'+$receiptId+'.ps1')
                $checkSnapshot=Copy-PinnedCheck $checkCopy $scriptSnapshot $pins
                $started=[DateTime]::UtcNow
                $lab=Invoke-ScopedView $rootPath (Join-Path $batchPath 'scope.json') $checkCopy $m.path.Replace('\','/') $scopeSnapshot.limits.timeout_seconds
                $finished=[DateTime]::UtcNow
                $labPath=Get-LocalPath $lab.receipt_path
                if([IO.Path]::GetDirectoryName($labPath) -cne $lab.run_directory -or [IO.Path]::GetFileName($labPath) -cne 'receipt.json') { throw 'BAD_RECEIPT: lab path mismatch' }
                $labBytes=Read-PinnedFile $labPath $pins
                $lr=ConvertFrom-Json -InputObject ([Text.Encoding]::UTF8.GetString($labBytes.Bytes)) -AsHashtable
                if($lr.status -cne 'LabPassed' -or $lr.eligible_for_finalize -ne $false -or $lr.scope_sha256 -cne $m.check_scope.scope_sha256 -or $lr.original_source_after_sha256 -cne $scopeSnapshot.snapshot_sha256) { throw 'CHECK_FAILED: lab source binding failed' }
                $current=Read-ScopedState $m $batchPath $rootPath $pins $applyEvent $after
                $post=Get-PostState $target $m $applyEvent $pins
                if(!(Same-PostState $pre $post)) { throw 'POST_CHANGED: target changed during scoped Check' }
                $inspectionName='scoped-inspect-'+$receiptId+'.json';$inspection=Join-Path $batchPath $inspectionName
                $evidenceFileLimit=if($scopeSnapshot.limits.max_files -eq 0){0}else{$scopeSnapshot.limits.max_files+64}
                $limits=[ordered]@{max_files=$evidenceFileLimit;max_directories=[Math]::Min(100000,$scopeSnapshot.limits.max_directories+16);max_file_bytes=16777216;max_total_bytes=[Math]::Min(1073741824,$scopeSnapshot.limits.max_total_bytes+67108864);timeout_seconds=$scopeSnapshot.limits.timeout_seconds}
                New-Json $inspection ([ordered]@{schema_version=1;inputs=@('.');limits=$limits})
                $inspectionBytes=Read-PinnedFile $inspection $pins
                $retained=Read-RetainedEvidence $lab.run_directory $inspection $pins
                Assert-LabEvidence $lr $retained $lab.run_directory $scriptSnapshot.Hash $scopeSnapshot $pins
                $receiptName='receipt-'+$receiptId+'.json';$receiptPath=Join-Path $batchPath $receiptName
                New-Json $receiptPath @{check_attempt_event_id=$checkAttemptId;schema_version=2;batch=$m.batch;canonical_root=$canonical;manifest_sha256=$manifestSnapshot.Hash;apply_event_id=$applyEvent.event_id;apply_utc=$applyEvent.utc;post_state=$post;started_utc=$started.ToString('o');finished_utc=$finished.ToString('o');passed=$true;exit_code=$lr.exit_code;scope_sha256=$m.check_scope.scope_sha256;input_snapshot_sha256=$current.snapshot_sha256;runtime_sha256=$m.check_scope.runtime_sha256;lab_receipt_path=$labPath;lab_receipt_sha256=$labBytes.Hash;retained_root=$lab.run_directory;retained_scope_name=$inspectionName;retained_scope_sha256=$inspectionBytes.Hash;retained_snapshot_sha256=$retained.snapshot_sha256}
                $receiptHash=([BathNative]::Read($receiptPath)).Hash
                Write-Event $batchPath 'Checked' $manifestSnapshot.Hash $applyEvent.target_id $applyEvent.write_time $receiptHash $receiptName $checkAttemptId
                return @{ok=$true;state='Checked';passed=$true;receipt=$receiptPath;batch=$batchPath;side_effect_guard=$true;semantic_correctness='Agent-selected scoped check; not semantic proof or host sandbox'}
            }
            $pre=Get-PostState $target $m $applyEvent $pins
            $scriptPath=Get-LocalPath $CheckScript
            [void](Pin-Directory ([IO.Path]::GetDirectoryName($scriptPath)) $pins)
            $scriptSnapshot=Read-PinnedFile $scriptPath $pins
            $receiptId=[Guid]::NewGuid().ToString('N')
            $checkCopy=Join-Path $batchPath ('check-'+$receiptId+'.ps1')
            $checkSnapshot=Copy-PinnedCheck $checkCopy $scriptSnapshot $pins
            $view=Join-Path $batchPath ('view-'+$receiptId)
            New-PinnedDirectory $view $pins
            $original=Read-CheckTree $rootPath $pins $view
            $viewPins=[Collections.Generic.List[IDisposable]]::new()
            try { $viewBefore=Tree-Hash (Read-CheckTree $view $viewPins) }
            finally { for($i=$viewPins.Count-1;$i -ge 0;$i--){$viewPins[$i].Dispose()} }
            $started=[DateTime]::UtcNow
            $check=Run-Check $checkCopy $view
            $finished=[DateTime]::UtcNow
            $guard=$true; $guardReason=''
            try {
                $viewAfter=Tree-Hash (Read-CheckTree $view $pins)
                $originalAfter=Tree-Hash (Read-CheckTree $rootPath $pins)
                if ($viewAfter -cne $viewBefore -or $originalAfter -cne (Tree-Hash $original)) { throw 'CHECK_SIDE_EFFECT: check view or original project changed' }
            } catch { $guard=$false; $guardReason=$_.Exception.Message }
            $post=Get-PostState $target $m $applyEvent $pins
            if (!(Same-PostState $pre $post)) { throw 'POST_CHANGED: target changed during check' }
            $passed=$check.exit_code -eq 0 -and $guard
            $receiptName='receipt-'+$receiptId+'.json'; $receiptPath=Join-Path $batchPath $receiptName
            New-Json $receiptPath @{check_attempt_event_id=$checkAttemptId;schema_version=1; batch=$m.batch; canonical_root=$canonical; manifest_sha256=$manifestSnapshot.Hash; apply_event_id=$applyEvent.event_id; apply_utc=$applyEvent.utc; post_state=$post; started_utc=$started.ToString('o'); finished_utc=$finished.ToString('o'); script_name=[IO.Path]::GetFileName($checkCopy); script_sha256=$checkSnapshot.Hash; command=@((Get-Process -Id $PID).Path,'-NoProfile','-File',$checkCopy,'-ProjectRoot',$view); exit_code=$check.exit_code; stdout=$check.stdout; stderr=$check.stderr; passed=$passed; check_guard=@{passed=$guard;reason=$guardReason;original_sha256=(Tree-Hash $original);view_sha256=$viewBefore;view_name=[IO.Path]::GetFileName($view)}}
            $receiptHash=([BathNative]::Read($receiptPath)).Hash
            Write-Event $batchPath 'Checked' $manifestSnapshot.Hash $applyEvent.target_id $applyEvent.write_time $receiptHash $receiptName $checkAttemptId
            return @{ok=$true; state='Checked'; passed=$passed; receipt=$receiptPath; batch=$batchPath; side_effect_guard=$guard; semantic_correctness='Agent-selected check on a bounded copy, not a semantic proof or host sandbox'}
        }
        if ($Action -eq 'Finalize') {
            if ($last.state -notin @('Checked','Completed') -or !$applyEvent -or !$last.Contains('receipt_sha256')) { throw 'EVIDENCE_REQUIRED: run Check after Apply; shallow PASS is not evidence' }
            $receiptPath=Get-LocalPath $Receipt
            if ([IO.Path]::GetDirectoryName($receiptPath) -cne $batchPath -or [IO.Path]::GetFileName($receiptPath) -cne $last.receipt_name) { throw 'BAD_RECEIPT: only latest receipt of this batch is accepted' }
            $rs=Read-PinnedFile $receiptPath $pins
            if ($rs.Hash -cne $last.receipt_sha256) { throw 'EVIDENCE_CHANGED: recorded receipt bytes changed' }
            $r=[Text.Encoding]::UTF8.GetString($rs.Bytes) | ConvertFrom-Json -AsHashtable
            $attempts=@($events | Where-Object state -CEQ 'CheckStarted')
            if(!$attempts.Count -or !$last.Contains('check_attempt_event_id') -or $r.check_attempt_event_id -isnot [string] -or $r.check_attempt_event_id -cne $attempts[-1].event_id -or $last.check_attempt_event_id -cne $r.check_attempt_event_id) { throw 'STALE_EVIDENCE: receipt does not bind latest check attempt' }
            if($m.Contains('check_scope')) {
                Check-Keys $r @('check_attempt_event_id','schema_version','batch','canonical_root','manifest_sha256','apply_event_id','apply_utc','post_state','started_utc','finished_utc','passed','exit_code','scope_sha256','input_snapshot_sha256','runtime_sha256','lab_receipt_path','lab_receipt_sha256','retained_root','retained_scope_name','retained_scope_sha256','retained_snapshot_sha256')
                if($r.schema_version -ne 2 -or $r.batch -cne $m.batch -or $r.canonical_root -cne $canonical -or $r.manifest_sha256 -cne $manifestSnapshot.Hash -or $r.apply_event_id -cne $applyEvent.event_id -or $r.apply_utc -cne $applyEvent.utc) { throw 'BAD_RECEIPT: scoped batch/Apply binding mismatch' }
                if([DateTimeOffset]::Parse($r.started_utc) -lt [DateTimeOffset]::Parse($applyEvent.utc) -or [DateTimeOffset]::Parse($r.finished_utc) -lt [DateTimeOffset]::Parse($r.started_utc) -or [DateTimeOffset]::Parse($r.finished_utc) -gt [DateTimeOffset]::Parse($last.utc)) { throw 'STALE_EVIDENCE: scoped Check time is outside Apply/event window' }
                if($r.passed -ne $true -or $r.exit_code -ne 0 -or $r.scope_sha256 -cne $m.check_scope.scope_sha256) { throw 'CHECK_FAILED: scoped receipt did not pass' }
                Assert-ScopedRuntime $r.runtime_sha256 $pins
                $current=Read-ScopedState $m $batchPath $rootPath $pins $applyEvent $after
                if($current.snapshot_sha256 -cne $r.input_snapshot_sha256) { throw 'EVIDENCE_CHANGED: current selected inputs changed' }
                $post=Get-PostState $target $m $applyEvent $pins
                if(!(Same-PostState $post $r.post_state)) { throw 'POST_CHANGED: target changed after scoped Check' }
                $labPath=Get-LocalPath $r.lab_receipt_path
                if([IO.Path]::GetDirectoryName($labPath) -cne $r.retained_root -or [IO.Path]::GetFileName($labPath) -cne 'receipt.json') { throw 'BAD_RECEIPT: invalid retained lab receipt path' }
                $labBytes=Read-PinnedFile $labPath $pins
                if($labBytes.Hash -cne $r.lab_receipt_sha256) { throw 'EVIDENCE_CHANGED: lab receipt changed' }
                if($r.retained_scope_name -cnotmatch '^scoped-inspect-[a-f0-9]{32}\.json$') { throw 'BAD_RECEIPT: invalid inspection name' }
                $inspection=Join-Path $batchPath $r.retained_scope_name
                $inspectionBytes=Read-PinnedFile $inspection $pins
                if($inspectionBytes.Hash -cne $r.retained_scope_sha256) { throw 'EVIDENCE_CHANGED: retained inspection changed' }
                $retained=Read-RetainedEvidence $r.retained_root $inspection $pins
                if($retained.snapshot_sha256 -cne $r.retained_snapshot_sha256) { throw 'EVIDENCE_CHANGED: retained source/output/log/control evidence changed' }
            } else {
            Check-Keys $r @('check_attempt_event_id','schema_version','batch','canonical_root','manifest_sha256','apply_event_id','apply_utc','post_state','started_utc','finished_utc','script_name','script_sha256','command','exit_code','stdout','stderr','passed','check_guard')
            if ($r.schema_version -ne 1 -or $r.batch -cne $m.batch -or $r.canonical_root -cne $canonical -or $r.manifest_sha256 -cne $manifestSnapshot.Hash -or $r.apply_event_id -cne $applyEvent.event_id -or $r.apply_utc -cne $applyEvent.utc) { throw 'BAD_RECEIPT: Apply/manifest/batch binding mismatch' }
            if ([DateTimeOffset]::Parse($r.started_utc) -lt [DateTimeOffset]::Parse($applyEvent.utc) -or [DateTimeOffset]::Parse($r.finished_utc) -lt [DateTimeOffset]::Parse($r.started_utc) -or [DateTimeOffset]::Parse($r.finished_utc) -gt [DateTimeOffset]::Parse($last.utc)) { throw 'STALE_EVIDENCE: check time is outside its Apply/receipt event window' }
            if (!$r.passed -or $r.exit_code -ne 0) { throw 'CHECK_FAILED: actual check did not pass; Restore or safe Close' }
            if ($r.script_name -cnotmatch '^check-[a-f0-9]{32}\.ps1$') { throw 'BAD_RECEIPT: invalid script identity' }
            $cs=Read-PinnedFile (Join-Path $batchPath $r.script_name) $pins
            if ($cs.Hash -cne $r.script_sha256) { throw 'EVIDENCE_CHANGED: executed check snapshot changed' }
            $post=Get-PostState $target $m $applyEvent $pins
            if (!(Same-PostState $post $r.post_state)) { throw 'POST_CHANGED: current state differs from check' }
            Check-Keys $r.check_guard @('passed','reason','original_sha256','view_sha256','view_name')
            if (!$r.check_guard.passed -or $r.check_guard.view_name -cnotmatch '^view-[a-f0-9]{32}$') { throw 'CHECK_FAILED: invalid/failed side-effect guard' }
            if ((Tree-Hash (Read-CheckTree $rootPath $pins)) -cne $r.check_guard.original_sha256 -or (Tree-Hash (Read-CheckTree (Join-Path $batchPath $r.check_guard.view_name) $pins)) -cne $r.check_guard.view_sha256) { throw 'EVIDENCE_CHANGED: check inputs/view changed since receipt' }
            }
            $repeated=$last.state -eq 'Completed'
            if (!$repeated) { Write-Event $batchPath 'Completed' $manifestSnapshot.Hash $applyEvent.target_id $applyEvent.write_time $rs.Hash $last.receipt_name $r.check_attempt_event_id }
            if ($lease.owner -ceq $m.batch) { Write-Lease $leasePath '' }
            return @{ok=$true; state='Completed'; batch=$batchPath; receipt=$receiptPath; repeated=$repeated; verified_at=[DateTime]::UtcNow.ToString('o'); scope='Recorded check and current single-file post-state; Agent owns semantic judgment'}
        }
        if ($Action -eq 'Apply') {
            if ($m.tool_sha256 -cne (Get-FileHash -LiteralPath $script:ToolPath -Algorithm SHA256).Hash.ToLowerInvariant()) { throw 'TOOL_CHANGED: re-prepare with current tool; Restore remains available' }
            if ($last.state -cne 'BackedUp') { throw 'BAD_STATE: Apply requires BackedUp' }
            if($m.Contains('check_scope')) { [void](Read-ScopedState $m $batchPath $rootPath $pins) }
            $source = [BathNative]::Open($target,$true)
            $current = [BathNative]::Capture($source)
            Assert-Same $current $m
            # Persist intent and verified binding before any target mutation.
            Write-Event $batchPath 'Applying' $manifestSnapshot.Hash $current.Id $current.WriteTime
            if ($m.action -eq 'archive') { [BathNative]::Retire($source) }
            else { [BathNative]::ReplaceBytes($source,$after.Bytes) }
            $source.Dispose(); $source=$null
            if ($m.action -eq 'edit') {
                $post = [BathNative]::Read($target)
                if ($post.Hash -cne $m.after_sha256 -or $post.Id -cne $m.before_id) { throw 'POST_CONFLICT: target changed before receipt; preserve current file' }
                Write-Event $batchPath 'Applied' $manifestSnapshot.Hash $post.Id $post.WriteTime
            } else { Write-Event $batchPath 'Applied' $manifestSnapshot.Hash }
            return @{ok=$true; state='Applied'; batch=$batchPath; verified=$false}
        }
        if ($Action -eq 'Restore') {
            if ($last.state -eq 'Completed') {
                if ($lease.owner -and $lease.owner -cne $m.batch) { throw 'PROJECT_BUSY: historical restore cannot take another batch lease' }
                if (!$applyEvent) { throw 'UNCONFIRMED_EDIT: completed batch has no confirmed Apply' }
                # Validate before acquiring; pin edit post-state until this
                # operation ends. Archive still uses race-safe CreateNew.
                $restorePins=[Collections.Generic.List[IDisposable]]::new()
                try { [void](Get-PostState $target $m $applyEvent $restorePins) }
                finally { for($i=$restorePins.Count-1;$i -ge 0;$i--){$restorePins[$i].Dispose()} }
                $intentSnapshot=Read-PinnedFile $intentPath $pins
                $hiPath=Join-Path $batchPath 'historical-restore.json'
                if (![IO.File]::Exists($hiPath)) { New-Json $hiPath @{batch=$m.batch;manifest_sha256=$manifestSnapshot.Hash;completed_event_id=$last.event_id;utc=[DateTime]::UtcNow.ToString('o')} }
                $hiSnapshot=Read-PinnedFile $hiPath $pins
                $hi=[Text.Encoding]::UTF8.GetString($hiSnapshot.Bytes) | ConvertFrom-Json -AsHashtable
                if ($hi.batch -cne $m.batch -or $hi.manifest_sha256 -cne $manifestSnapshot.Hash -or $hi.completed_event_id -cne $last.event_id) { throw 'BAD_INTENT: historical Restore intent mismatch' }
                if ($lease.owner -ceq $m.batch -and $lease.intent_sha256 -cne $intentSnapshot.Hash) { throw 'BAD_INTENT: historical restore lease binding changed' }
                if (!$lease.owner) { Write-Lease $leasePath $m.batch $intentSnapshot.Hash }
            }
            if ($last.state -eq 'Restored') {
                $current = [BathNative]::Read($target)
                if ($current.Hash -cne $m.before_sha256 -or $current.Id -cne $last.target_id -or $current.WriteTime -ne $last.write_time) { throw 'RESTORE_CONFLICT: already-restored target changed' }
                if ($lease.owner -ceq $m.batch) { Write-Lease $leasePath '' }
                return @{ok=$true; state='Restored'; batch=$batchPath; repeated=$true}
            }
            if ($last.state -eq 'Restoring') { throw 'INTERRUPTED_RESTORE: no safe automatic overwrite; inspect status and retain both copies' }
            if ($last.state -in @('BackedUp','Applying') -and [IO.File]::Exists($target)) {
                $source=[BathNative]::Open($target,$false); $current=[BathNative]::Capture($source)
                try { Assert-Same $current $m; Write-Event $batchPath 'Restored' $manifestSnapshot.Hash $current.Id $current.WriteTime }
                finally { $source.Dispose(); $source=$null }
                Write-Lease $leasePath ''
                return @{ok=$true; state='Restored'; batch=$batchPath; target_untouched=$true}
            }
            if ($last.state -notin @('Applied','Applying','Checked','CheckStarted','Completed')) { throw 'BAD_STATE: Restore requires saved, applied or completed batch' }
            if ($m.action -eq 'archive') {
                if ([IO.File]::Exists($target) -or [IO.Directory]::Exists($target)) { throw 'RESTORE_CONFLICT: same-path object exists; preserve it' }
                Write-Event $batchPath 'Restoring' $manifestSnapshot.Hash
                # CreateNew is the race-safe no-overwrite gate; D bytes copied to
                # the target volume, never renamed across volumes.
                [BathNative]::WriteNew($target,$backup.Bytes)
            } else {
                if ($last.state -notin @('Applied','Checked','CheckStarted','Completed') -or !$applyEvent) { throw 'UNCONFIRMED_EDIT: missing post receipt; automatic restore blocked' }
                $source = [BathNative]::Open($target,$true); $current=[BathNative]::Capture($source)
                if ($current.Hash -cne $m.after_sha256 -or $current.Id -cne $applyEvent.target_id -or $current.WriteTime -ne $applyEvent.write_time) { throw 'RESTORE_CONFLICT: later edit or new identity; preserve current file' }
                Write-Event $batchPath 'Restoring' $manifestSnapshot.Hash $current.Id $current.WriteTime
                [BathNative]::ReplaceBytes($source,$backup.Bytes)
                $source.Dispose(); $source=$null
            }
            $restored = [BathNative]::Read($target)
            if ($restored.Hash -cne $m.before_sha256) { throw 'RESTORE_CONFLICT: post-restore bytes differ; preserve copies' }
            Write-Event $batchPath 'Restored' $manifestSnapshot.Hash $restored.Id $restored.WriteTime
            Write-Lease $leasePath ''
            return @{ok=$true; state='Restored'; batch=$batchPath; before_sha256=$restored.Hash}
        }
        throw 'CAPABILITY_BLOCKED: unsupported action'
    } catch {
        $err = $_.Exception
        while ($err.InnerException) { $err=$err.InnerException }
        $message = $err.Message
        $code = if($message -match '^([A-Z_]+):'){ $Matches[1] } else { 'IO_OR_VALIDATION_FAILED' }
        return @{ok=$false; code=$code; message=$message; batch=$createdBatch; at=$_.ScriptStackTrace; next='Keep current files and D copies. Status is read-only. Do not bypass this refusal.'}
    } finally {
        if ($source) { $source.Dispose() }
        if ($projectLock) { $projectLock.Dispose() }
        for ($n=$pins.Count-1;$n -ge 0;$n--) { $pins[$n].Dispose() }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if ($Group -and $Action -ne 'Help') {
        if ($Action -eq 'Cancel') {
            @{ok=$false;code='CAPABILITY_BLOCKED';message='Group incomplete batches use Close; Cancel is single-file only'} | ConvertTo-Json -Compress
            exit 2
        }
        # Keep the existing entry; delegate group coordination without invoking single-file IO.
        $groupArgs=@('-NoProfile','-File',(Join-Path $PSScriptRoot 'bath-group.ps1'),'-Action',$Action)
        foreach ($forwardName in @('Root','Plan','Batch','CheckScript','Receipt','Scope')) {
            $forwardValue=Get-Variable -Name $forwardName -ValueOnly
            if ($forwardValue) { $groupArgs+=@(('-'+$forwardName),$forwardValue) }
        }
        & (Join-Path $PSHOME 'pwsh.exe') @groupArgs
        exit $LASTEXITCODE
    }
    $result=Invoke-Bath
    $result | ConvertTo-Json -Depth 12 -Compress -EscapeHandling EscapeNonAscii
    if (!$result.ok) { exit 2 }
}
