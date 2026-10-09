#requires -Version 7.0
<#
.SYNOPSIS
    Read-only: find the processes whose current working directory (CWD) is inside a folder.

.DESCRIPTION
    Windows refuses to delete or rename a directory while any process keeps it as its
    current working directory. Leftover background watchers are the usual reason a project
    folder reports "The process cannot access the file ... because it is being used by
    another process" - for example the git-management autosnapshot.ps1 -Watch process
    started by a CodeBuddy SessionStart hook, which inherits the workspace CWD through
    Start-Process and may outlive the session (up to 8 hours).

    This script reads every accessible process PEB
    (NtQueryInformationProcess -> RTL_USER_PROCESS_PARAMETERS.CurrentDirectory)
    and prints the processes whose CWD equals the target folder or lives inside it.
    It only reports - it never stops or kills anything.

.PARAMETER Path
    Folder that cannot be deleted / renamed (or any file inside it).

.PARAMETER IncludeParent
    Also list processes whose CWD is exactly the parent folder of -Path.

.EXAMPLE
    pwsh -NoProfile -File find_lockers.ps1 -Path "E:\work\old_project"
    pwsh -NoProfile -File find_lockers.ps1 -Path "E:\work\old_project" -IncludeParent

.NOTES
    Exit codes: 0 = no locker found, 2 = locker(s) found, 1 = bad path / unsupported host.
    Requires: Windows + 64-bit PowerShell 7+. Same-user processes are readable without
    admin rights; processes of other users are skipped silently.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [switch]$IncludeParent
)

$ErrorActionPreference = 'Continue'

if (-not (Test-Path -LiteralPath $Path)) {
    Write-Output ("NOT FOUND: " + $Path)
    exit 1
}
$target = ([System.IO.Path]::GetFullPath($Path)).TrimEnd('\', '/')
$parent = Split-Path -Parent $target

if ([IntPtr]::Size -ne 8) {
    Write-Output "This script only supports 64-bit PowerShell (process walk uses x64 PEB offsets)."
    exit 1
}

$src = @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class ProcCwdReader {
  [DllImport("kernel32.dll", SetLastError=true)]
  static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
  [DllImport("ntdll.dll")]
  static extern int NtQueryInformationProcess(IntPtr h, int cls, byte[] buf, int len, out int ret);
  [DllImport("kernel32.dll")]
  static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, int size, out IntPtr read);
  [DllImport("kernel32.dll")]
  static extern bool CloseHandle(IntPtr h);
  public static string GetCwd(int pid) {
    IntPtr h = OpenProcess(0x0410, false, pid);
    if (h == IntPtr.Zero) { h = OpenProcess(0x1000, false, pid); }
    if (h == IntPtr.Zero) { return null; }
    try {
      byte[] pbi = new byte[48];
      int rl;
      if (NtQueryInformationProcess(h, 0, pbi, 48, out rl) != 0) { return null; }
      long peb = BitConverter.ToInt64(pbi, 8);
      byte[] p8 = new byte[8];
      IntPtr read;
      if (!ReadProcessMemory(h, (IntPtr)(peb + 0x20), p8, 8, out read)) { return null; }
      long pp = BitConverter.ToInt64(p8, 0);
      byte[] p16 = new byte[16];
      if (!ReadProcessMemory(h, (IntPtr)(pp + 0x38), p16, 16, out read)) { return null; }
      ushort len = BitConverter.ToUInt16(p16, 0);
      long bufPtr = BitConverter.ToInt64(p16, 8);
      if (bufPtr == 0 || len == 0) { return null; }
      if (len > 8192) { len = 8192; }
      byte[] sb = new byte[len];
      if (!ReadProcessMemory(h, (IntPtr)bufPtr, sb, len, out read)) { return null; }
      return Encoding.Unicode.GetString(sb).TrimEnd('\0');
    } finally { CloseHandle(h); }
  }
}
'@
Add-Type -TypeDefinition $src -Language CSharp | Out-Null

Write-Output ("TARGET : " + $target)
Write-Output ("PARENT : " + $parent)
Write-Output "SCAN   : all processes (read-only, nothing is stopped)"

$hits = @()
foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
    $cwd = $null
    try { $cwd = [ProcCwdReader]::GetCwd($p.Id) } catch { $cwd = $null }
    if ([string]::IsNullOrWhiteSpace($cwd)) { continue }
    $c = $cwd.TrimEnd('\', '/')
    $isTarget = $c.Equals($target, [System.StringComparison]::OrdinalIgnoreCase)
    $isInside = $c.StartsWith($target + '\', [System.StringComparison]::OrdinalIgnoreCase)
    $isParent = $IncludeParent -and $c.Equals($parent, [System.StringComparison]::OrdinalIgnoreCase)
    if ($isTarget -or $isInside -or $isParent) {
        $lvl = if ($isParent) { 'parent' } else { 'inside' }
        $hits += [pscustomobject]@{ PID = $p.Id; Name = $p.ProcessName; CWD = $cwd; Level = $lvl }
    }
}

if ($hits.Count -eq 0) {
    Write-Output "NO LOCKER FOUND: no process has this folder (or a subfolder) as its current directory."
    exit 0
}

Write-Output ("LOCKERS: " + $hits.Count)
foreach ($h in ($hits | Sort-Object Level, PID)) {
    Write-Output ("  PID={0,-7} {1,-18} {2,-9} CWD={3}" -f $h.PID, $h.Name, $h.Level, $h.CWD)
    $cmd = ''
    try { $cmd = (Get-CimInstance Win32_Process -Filter ("ProcessId=" + $h.PID) -ErrorAction SilentlyContinue).CommandLine } catch { $cmd = '' }
    if ($cmd) { Write-Output ("      cmd: " + $cmd) }
}
Write-Output ""
Write-Output "These processes block delete/rename of the folder. Options:"
Write-Output "  Stop-Process -Id <PID> -Force      # only after you know what the process is"
Write-Output "For a git-management watcher prefer the graceful stop:"
Write-Output "  pwsh -File <skill>\scripts\autosnapshot.ps1 -Stop -Path `"<repo>`""
exit 2
