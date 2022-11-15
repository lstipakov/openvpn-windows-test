#Requires -Version 7

param (
    [ValidateSet("Default", "OvpnDco", "Wintun", "TapWindows6", "All")]
    [string]$Driver = "Default",

    [string]$CA = "c:\Temp\openvpn2_ta\ca.crt",
    [string]$CERT = "c:\Temp\openvpn2_ta\lev-tclient.crt",
    [string]$KEY = "c:\Temp\openvpn2_ta\lev-tclient.key",

    [string[]]$Tests = "All",

    # use "Return" instead of "exit" at the end of execution, useful when called from Invoke-Command
    # (cannot use switch parameter with Invoke-Command -FilePath -ArgumentList)
    [int]$SuppressExit = 0
)

$OPENVPN_EXE = "c:\Program Files\OpenVPN\bin\openvpn.exe"
$REMOTE = "conn-test-server.openvpn.org"

$MANAGEMENT_PORT="58581"
$BASE_P2MP="--client --tls-cert-profile insecure --ca $CA --cert $CERT --key $KEY --remote-cert-tls server --verb 3 --setenv UV_NOCOMP 1 --push-peer-info --management 127.0.0.1 $MANAGEMENT_PORT"

$PING4_HOSTS_1=@("10.194.1.1", "10.194.0.1")
$PING6_HOSTS_1=@("fd00:abcd:194:1::1", "fd00:abcd:194:0::1")

$PING4_HOSTS_2=@("10.194.2.1", "10.194.0.1")
$PING6_HOSTS_2=@("fd00:abcd:194:2::1", "fd00:abcd:194:0::1")

$PING4_HOSTS_4=@("10.194.4.1", "10.194.0.1")
$PING6_HOSTS_4=@("fd00:abcd:194:4::1", "fd00:abcd:194:0::1")

$ALL_TESTS = [ordered]@{
    "1" = @{
        Title="tcp / p2pm / top net30"
        Conf="$BASE_P2MP --dev tun --proto tcp4 --remote $REMOTE --port 51194"
        Ping4Hosts=$PING4_HOSTS_1
        Ping6Hosts=$PING6_HOSTS_1
    }
    "1a" = @{
        Title="tcp*6* / p2pm / top net30"
        Conf="$BASE_P2MP --dev tun3 --proto tcp6-client --remote $REMOTE --port 51194 --server-poll-timeout 10"
        Ping4Hosts=$PING4_HOSTS_1
        Ping6Hosts=$PING6_HOSTS_1
    }
    "2" = @{
        Title="udp / p2pm / top net30"
        Conf="$BASE_P2MP --dev tun --proto udp4 --remote $REMOTE --port 51194"
        Ping4Hosts=$PING4_HOSTS_2
        Ping6Hosts=$PING6_HOSTS_2
    }
    "2b" = @{
        Title="udp *6* / p2pm / top net30"
        Conf="$BASE_P2MP --dev tun --proto udp6 --remote $REMOTE --port 51194"
        Ping4Hosts=$PING4_HOSTS_2
        Ping6Hosts=$PING6_HOSTS_2
    }
    "2f" = @{
        Title="UDP / p2pm / top net30 / pull-filter -> ipv6-only"
        Conf="$BASE_P2MP --dev tun --proto udp --remote $REMOTE --port 51194 --pull-filter accept ifconfig- --pull-filter ignore ifconfig"
        Ping4Hosts=@()
        Ping6Hosts=$PING6_HOSTS_2
    }
    "3" = @{
        Title="udp / p2pm / top subnet"
        Conf="$BASE_P2MP --dev tun --proto udp4 --remote $REMOTE --port 51195"
        Ping4Hosts=@("10.194.3.1", "10.194.0.1")
        Ping6Hosts=@("fd00:abcd:194:3::1", "fd00:abcd:194:0::1")
    }
    "4" = @{
        Title="udp(4) / p2pm / tap"
        Conf="$BASE_P2MP --dev tap --proto udp4 --remote $REMOTE --port 51196 --route-ipv6 fd00:abcd:195::/48 fd00:abcd:194:4::ffff"
        Ping4Hosts=$PING4_HOSTS_4
        Ping6Hosts=$PING6_HOSTS_4
    }
    "4a" = @{
        Title="udp(6) / p2pm / tap3 / topo subnet"
        Conf="$BASE_P2MP --dev tap3 --proto udp6 --remote $REMOTE --port 51196 --topology subnet"
        Ping4Hosts=$PING4_HOSTS_4
        Ping6Hosts=$PING6_HOSTS_4
    }
    "4b" = @{
        Title="udp / p2pm / tap / ipv6-only (pull-filter) / MAC-Addr"
        Conf="$BASE_P2MP --dev tap --proto udp --remote $REMOTE --port 51196 --pull-filter accept ifconfig- --pull-filter ignore ifconfig --lladdr 00:aa:bb:c0:ff:ee"
        Ping4Hosts=@()
        Ping6Hosts=$PING6_HOSTS_4
    }
    "5" = @{
        Title="udp / p2pm / top net30 / ipv6 112"
        Conf="$BASE_P2MP --dev tun --proto udp4 --remote $REMOTE --port 51197"
        Ping4Hosts=@("10.194.5.1", "10.194.0.1")
        Ping6Hosts=@("fd00:abcd:194:5::1", "fd00:abcd:194:0::1")
    }
}

function Test-ConnectionMs([switch]$IPv4, [switch]$IPv6, [array]$Hosts, $Count=20, $Delay=250) {
    $(64, 1440, 3000) | ForEach-Object {
        $bufferSize = $_
        Write-Host "Ping ""$Hosts"" $Count times with $bufferSize bytes..."

        # failures per host
        $failuresPerHost = [hashtable]::Synchronized(@{ })
        foreach ($h in $Hosts) {
            $failuresPerHost[$h] = 0
        }

        for ($i = 0; $i -lt $Count; ++$i) {
            # this is because we have nested scope, Invoke-Command and Parallel
            # see https://stackoverflow.com/questions/57700435/usingvar-in-start-job-within-invoke-command
            $pingPerHost = [scriptblock]::Create(
@'
            $startTime = Get-Date
            $ok = Test-Connection -TargetName $_ -IPv4:$using:IPv4 -IPv6:$using:IPv6 -Count 1 -BufferSize $using:bufferSize -Quiet
            if (!$ok) {
                $fph = $using:failuresPerHost
                ++$fph[$_]
            }
            $endTime = Get-Date
            $neededDelay = $Delay - (($endTime - $startTime).TotalMilliseconds)
            # sleep if ping took less time than passed $Delay value
            if ($neededDelay -gt 0) {
                Start-Sleep -Milliseconds $neededDelay
            }
'@
            )

            # ping hosts in parallel
            $hosts | ForEach-Object -Parallel $pingPerHost
        }

        foreach ($en in $failuresPerHost.GetEnumerator()) {
            # test failed if all pings have failed
            if ($en.Value -eq $Count) {
                throw "ping $($en.Key) failed"
            } elseif ($en.Value -gt 0) {
                # print failure rate if some pings have failed
                $rate = ($en.Value / $Count).ToString("0.00")
                Write-Host "failure rate for $($en.Key): $rate"
            }
        }
    }
}

function Test-Pings ([array]$hosts4, [array]$hosts6) {
    if ($hosts4) {
        Test-ConnectionMs -IPv4 -Hosts $hosts4
    }
    if ($hosts6) {
        Test-ConnectionMs -IPv6 -Hosts $hosts6
    }
}

Function Stop-OpenVPN {
    $socket = New-Object System.Net.Sockets.TcpClient("127.0.0.1", $MANAGEMENT_PORT)

    if ($socket) {
        $Stream = $Socket.GetStream()
        $Writer = New-Object System.IO.StreamWriter($Stream)

        Start-Sleep -Seconds 1
        $writer.WriteLine("signal SIGTERM")
        $writer.Flush()
        Start-Sleep -Seconds 3
    } else {
        $processes = (Get-Process|Where-Object { $_.ProcessName -eq "openvpn" })
        foreach ($process in $processes) {
            Stop-Process $process.Id -Force
        }
    }
}

function Start-OpenVPN ([string]$TestId, [string]$Conf, [string]$Driver) {
    $windowsDriver = ""
    switch ($Driver) {
        "OvpnDco" {
            $windowsDriver = " --windows-driver ovpn-dco"
        }
        "TapWindows6" {
            $windowsDriver = " --windows-driver tap-windows6"
        }
        "wintun" {
            $windowsDriver = " --windows-driver wintun"
        }
    }
    $Conf += $windowsDriver
    $logFile = "openvpn-$TestId-$Driver.log"
    $Conf += " --log $logFile"

    Start-Process -NoNewWindow -FilePath $OPENVPN_EXE -ArgumentList $Conf -ErrorAction Stop -RedirectStandardError error-$TestId-$Driver.log -RedirectStandardOutput output-$TestId-$Driver.log

    for ($i = 0; $i -le 30; ++$i) {
        Start-Sleep -Seconds 1
        if (!(Test-Path $logFile)) {
            Write-Host "Waiting for log $logFile to appear..."
        } elseif (Select-String -Pattern "Initialization Sequence Completed" -Path $logFile) {
            return
        } else {
            Write-Host "Waiting for connection to be established..."
        }
    }

    Write-Error "Cannot establish VPN connection" -ErrorAction Stop
}

function Start-SingleDriverTests([string]$Drv) {
    $passed = [String[]]@()
    $failed = [String[]]@()
    if ($Tests -eq "All") {
        $tests_to_run = $ALL_TESTS.Keys
    } else {
        $tests_to_run = $Tests
    }

    Write-Host "`r`nWill run tests $($tests_to_run -join ",") using driver $Drv"
    foreach ($t in $tests_to_run) {
        if (!$ALL_TESTS.Contains($t)) {
            Write-Error "Test $t is missing"
            continue
        }

        $test = $ALL_TESTS[$t]
        Write-Host "Running Test $t ($($test.Title))"

        try {
            Start-OpenVPN -TestId $t -Conf $test.Conf -Driver $Drv

            # give some time for network settings to settle
            Start-Sleep -Seconds 3

            Test-Pings $test.Ping4Hosts $test.Ping6Hosts
            Write-Host "PASS`r`n"
            $passed += ,$t
        }
        catch {
            Write-Host "FAIL: $_`r`n"
            $failed += ,$t
        }
        finally {
            Stop-OpenVPN
        }
    }

    return [System.Tuple]::Create($passed, $failed)
}

$results = @()
if ($Driver -eq "All") {
    # skip Wintun since it requires SYSTEM elevation
    foreach ($d in @("OvpnDco", "TapWindows6")) {
        $r = Start-SingleDriverTests $d
        $results += ,[System.Tuple]::Create($d, $r.Item1, $r.Item2)
    }
} else {
    $r = Start-SingleDriverTests $Driver
    $results += ,[System.Tuple]::Create($Driver, $r.Item1, $r.Item2)
}

$exitcode = 0
Write-Host "`r`nSUMMARY:"
foreach ($r in $results) {
    Write-Host "Driver $($r.Item1)`r`nPassed: $($r.Item2)`r`nFailed: $($r.Item3)`r`n"
    if ($r.Item3) {
        $exitcode = 1
    }
}

if ($SuppressExit) {
    return $exitcode
}
else {
    exit $exitcode
}