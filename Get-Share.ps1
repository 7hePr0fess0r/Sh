function Invoke-SmbShare {
    param(
        [int]$ThrottleLimit = 10,
        [int]$MinDelayMs = 300,
        [int]$MaxDelayMs = 1500,
        [int]$TimeoutMs = 800
    )

    $Searcher = New-Object DirectoryServices.DirectorySearcher
    $Searcher.Filter = "(&(objectCategory=computer)(!(userAccountControl:1.2.840.113556.1.4.803:=2)))"
    $Searcher.PageSize = 1000
    $Searcher.PropertiesToLoad.Add("dnshostname") | Out-Null

    $Computers = $Searcher.FindAll() |
        ForEach-Object { $_.Properties["dnshostname"] } |
        Where-Object { $_ } |
        ForEach-Object { $_[0] } |
        Sort-Object -Unique

    Write-Host "[+] Found $($Computers.Count) domain computers" -ForegroundColor Green

    $Pool = [runspacefactory]::CreateRunspacePool(1, $ThrottleLimit)
    $Pool.Open()
    $Jobs = @()

    foreach ($Computer in $Computers) {

        $PS = [powershell]::Create()
        $PS.RunspacePool = $Pool

        [void]$PS.AddScript({
            param($Computer, $MinDelayMs, $MaxDelayMs, $TimeoutMs)

            Start-Sleep -Milliseconds (Get-Random -Minimum $MinDelayMs -Maximum $MaxDelayMs)

            function Test-Port445 {
                param($HostName, $TimeoutMs)

                try {
                    $Client = New-Object System.Net.Sockets.TcpClient
                    $Async = $Client.BeginConnect($HostName, 445, $null, $null)
                    $Connected = $Async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)

                    if ($Connected -and $Client.Connected) {
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

            if (-not (Test-Port445 -HostName $Computer -TimeoutMs $TimeoutMs)) {
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
                        Method      = "WMI"
                    }
                }
            }
            catch {
                $Output = cmd /c "net view \\$Computer" 2>$null

                foreach ($Line in $Output) {
                    if ($Line -match "^\s*(\S+)\s+Disk") {
                        [PSCustomObject]@{
                            Computer    = $Computer
                            ShareName   = $Matches[1]
                            Path        = "\\$Computer\$($Matches[1])"
                            Description = "Enumerated via net view"
                            Type        = "Disk"
                            Method      = "NetView"
                        }
                    }
                }
            }

        }).AddArgument($Computer).AddArgument($MinDelayMs).AddArgument($MaxDelayMs).AddArgument($TimeoutMs)

        $Jobs += [PSCustomObject]@{
            PS     = $PS
            Handle = $PS.BeginInvoke()
        }
    }

    foreach ($Job in $Jobs) {
        try {
            $Job.PS.EndInvoke($Job.Handle)
        }
        catch {}
        finally {
            $Job.PS.Dispose()
        }
    }

    $Pool.Close()
    $Pool.Dispose()
}
