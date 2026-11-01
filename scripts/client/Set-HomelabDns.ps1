[CmdletBinding()]
param([switch]$Remove)
$ErrorActionPreference = 'Stop'
$owner = 'Homelab home.arpa local DNS'
$namespace = '.home.arpa'
$servers = @('192.168.1.210','192.168.1.150')
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script in an elevated PowerShell window to configure the home.arpa-only DNS rule.'
}
$rules = @(Get-DnsClientNrptRule)
$owned = @($rules | Where-Object {$_.Comment -eq $owner})
function ServerList($values) { return ((@($values) -split '[,; ]+' | Where-Object {$_} | Sort-Object) -join ',') }
foreach ($rule in $owned) {
    if (@($rule.Namespace).Count -ne 1 -or $rule.Namespace[0] -ne $namespace -or (ServerList $rule.NameServers) -ne (ServerList $servers)) {
        throw 'The existing owned rule differs; review it before continuing.'
    }
}
$conflicts = @($rules | Where-Object {
    if ($_.Comment -eq $owner) { return $false }
    foreach ($item in @($_.Namespace)) {
        $name = $item.Trim('.').ToLowerInvariant()
        if (-not $name -or $name -eq 'home.arpa' -or 'home.arpa'.EndsWith('.'+$name) -or $name.EndsWith('.home.arpa')) { return $true }
    }
    return $false
})
if ($conflicts.Count) { throw 'An existing DNS policy covers home.arpa; refusing to overwrite it.' }
if ($Remove) {
    foreach ($rule in $owned) { Remove-DnsClientNrptRule -Name $rule.Name -Force }
} else {
    if ($owned.Count -gt 1) { throw 'Multiple owned rules exist; review them before continuing.' }
    if ($owned.Count -eq 0) {
        Add-DnsClientNrptRule -Namespace $namespace -NameServers $servers -Comment $owner -DisplayName $owner
    }
}
Clear-DnsClientCache
$after = @(Get-DnsClientNrptRule)
foreach ($rule in @($rules | Where-Object {$_.Comment -ne $owner})) {
    if (-not ($after | Where-Object {$_.Name -eq $rule.Name})) { throw 'An unrelated rule is missing after the update.' }
}
$effective = @(Get-DnsClientNrptPolicy -Effective | Where-Object {@($_.Namespace) -contains $namespace})
if (-not $Remove -and ($effective.Count -ne 1 -or (ServerList $effective[0].NameServers) -ne (ServerList $servers))) {
    throw 'The expected home.arpa policy is not effective; review Windows DNS policy before continuing.'
}
if ($Remove -and @($after | Where-Object {$_.Comment -eq $owner}).Count) { throw 'The owned rule was not removed.' }
$effective | Select-Object Namespace,NameServers
Write-Output 'Only the owned home.arpa rule was changed; interface DNS and other policies were preserved.'
