param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$Scope,[string[]]$ProtectedPaths=@(),[switch]$Detailed)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
try {
    if ($PSVersionTable.PSVersion -lt [version]'7.4' -or !$IsWindows) { throw 'SCOPE_UNSUPPORTED_OBJECT: Windows PowerShell 7.4+ required' }
    . (Join-Path $PSScriptRoot 'bath-scope.ps1')
    $snapshot=Read-BathScope -Root $Root -Scope $Scope -ProtectedPaths $ProtectedPaths
    $result=[ordered]@{ok=$true;schema_version=1;scope_status='Ready';execution_ready=$false;blockers=@('INTEGRATION_PENDING');snapshot_sha256=$snapshot.snapshot_sha256;scope_sha256=$snapshot.scope_sha256;stats=$snapshot.stats;limits=$snapshot.limits;excluded=$snapshot.excluded}
    if($Detailed) { $result.snapshot=$snapshot }
    ConvertTo-Json -InputObject $result -Depth 20 -Compress
    exit 0
} catch {
    $message=$_.Exception.Message
    $code=if($message -match '^(SCOPE_[A-Z_]+):') {$Matches[1]} else {'SCOPE_INVALID'}
    ConvertTo-Json -InputObject ([ordered]@{ok=$false;schema_version=1;error_code=$code;message=$message;execution_ready=$false}) -Compress
    exit 1
}
