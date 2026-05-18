# Stealthier multithreaded SMB share enumeration
# No Get-ADComputer / RSAT required
# PowerShell 5 compatible

$OutFile = ".\domain_smb_shares.csv"
$ThrottleLimit = 10        # Lower = stealthier. Try 3-10
$MinDelayMs = 300          # Jitter before each host
$MaxDelayMs = 1500
$PortTimeoutMs = 800

# LDAP computer enumeration
$Searcher = New-Object DirectoryServices.DirectorySearcher
$Searcher.Filter = "(&(objectCategory=computer)(!(userAccountControl:1.2.840.113556.1.4.803:=2)))"
$Searcher.PageSize = 1000
$Searcher.PropertiesToLoad.Add("dnshostname") | Out-Null

$Computers = $Searcher.FindAll() | ForEach-Object {
    $_.Properties["dnshostname"]
} | Where-Object { $_ } | ForEach-Object { $_[0] } | Sort-Object -Unique

Write-Host "[+] Found $($Computers.Count) domain computers"

$RunspacePool = [runspacefactory]::CreateRunspacePool(1, $ThrottleLimit)
$RunspacePool.Open()

$Jobs = @()

foreach ($Computer in $Computers) {

    $PowerShell = [powershell]::Create()
    $PowerShell.RunspacePool = $RunspacePool

    [void]$PowerShell.AddScript({
        param($Computer, $MinDelayMs, $MaxDelayMs, $PortTimeoutMs)

        Start-Sleep -Milliseconds (Get-Random -Minimum $MinDelayMs -Maximum $MaxDelayMs)

        function Test-Port445 {
            param($HostName, $TimeoutMs)

            try {
                $Client = New-Object System.Net.Sockets.TcpClient
                $Async = $Client.BeginConnect($HostName, 445, $null, $null)
                $Success = $Async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)

                if ($Success -and $Client.Connected) {
                    $Client.EndConnect($Async)
                    $Client.Close()
                    return $true
                }

                $Client.Close()
                return $false
            }
            catch {
                return $false
            }
        }

        if (-not (Test-Port445 -HostName $Computer -TimeoutMs $PortTimeoutMs)) {
            return
        }

        try {
            $Shares = Get-WmiObject Win32_Share -ComputerName $Computer -ErrorAction Stop

            foreach ($Share in $Shares) {
                [PSCustomObject]@{
                    Computer    = $Computer
                    ShareName   = $Share.Name
                    Path        = $Share.Path
                    Description = $Share.Description
                    Type        = $Share.Type
                }
            }
        }
        catch {
            try {
                $Output = cmd /c "net view \\$Computer" 2>$null

                foreach ($Line in $Output) {
                    if ($Line -match "^\s*(\S+)\s+Disk") {
                        [PSCustomObject]@{
                            Computer    = $Computer
                            ShareName   = $Matches[1]
                            Path        = ""
                            Description = "Enumerated via net view"
                            Type        = "Disk"
                        }
                    }
                }
            }
            catch {}
        }

    }).AddArgument($Computer).AddArgument($MinDelayMs).AddArgument($MaxDelayMs).AddArgument($PortTimeoutMs)

    $Jobs += [PSCustomObject]@{
        Computer = $Computer
        PS       = $PowerShell
        Handle   = $PowerShell.BeginInvoke()
    }
}

$Results = foreach ($Job in $Jobs) {
    try {
        $Job.PS.EndInvoke($Job.Handle)
    }
    catch {}
    finally {
        $Job.PS.Dispose()
    }
}

$RunspacePool.Close()
$RunspacePool.Dispose()

$Results |
    Sort-Object Computer, ShareName |
    Export-Csv $OutFile -NoTypeInformation

$Results | Format-Table -AutoSize

Write-Host "`n[+] Saved results to $OutFile"
