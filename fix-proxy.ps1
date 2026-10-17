<#
  fix-proxy.ps1 —— 代理残留修复工具（Windows）

  场景：Clash / Clash for Windows / Clash Verge / mihomo / v2rayN / sing-box 等代理软件
        在断电、强制关机、崩溃、蓝屏之后没能正常退出，系统里留下了收不回去的代理设置，
        于是出现下面这些情况，而且「关掉代理软件」也无效：
          · 所有网页都打不开
          · 网页能开，但某些程序（游戏客户端、下载器、桌面应用）连不上服务器
          · 明明是直连状态，程序却报「网络错误 / 无法连接服务器 / 检测到代理」

  为什么会这样：Windows 里有两套互不相干的代理设置。
        · WinINET —— 浏览器、「Internet 选项」里看到的那一套
        · WinHTTP —— 浏览器以外大部分程序走的那一套
        代理软件崩溃时常常只清掉了其中一套，甚至一套都没清掉，所以会出现
        「网页正常但别的程序连不上」。只关开关是不够的：代理地址、「局域网设置」里
        的勾选（存在注册表二进制值里）都可能残留。

  做什么： 1) 清理 WinINET 代理开关、代理地址、PAC 脚本、自动检测设置
          2) 取消「Internet 选项 - 连接 - 局域网设置」里残留的勾选
          3) 重置 WinHTTP 代理（需要管理员权限）
          4) 刷新 DNS，检查网卡上残留的代理 DNS、虚拟网卡、异常路由、hosts
          5) 可选：重置网络堆栈（winsock / TCP-IP，需要重启）
  不做什么：不修改、不删除任何个人文件，不安装不下载任何东西。

  用法： 双击同目录的 fix-proxy.bat（需要时会自动请求管理员权限）
        或 powershell -ExecutionPolicy Bypass -File fix-proxy.ps1
        加 -DryRun 只查看诊断结果、不实际修改任何设置。
        结束后会在桌面生成「网络诊断报告.txt」。
#>

param(
    [switch]$AdminPhase,
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'
$RegPath  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$ConnPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\Connections'
$IsAdmin  = $false
$script:Report = @()

function Write-Line  { param([string]$Text = '', [string]$Color = 'Gray') Write-Host $Text -ForegroundColor $Color }
function Write-Head  { param([string]$Text) Write-Host ''; Write-Host ('=== ' + $Text + ' ===') -ForegroundColor Cyan }
function Write-Ok    { param([string]$Text) Write-Host ('  [OK] ' + $Text) -ForegroundColor Green }
function Write-Alert { param([string]$Text) Write-Host ('  [!]  ' + $Text) -ForegroundColor Yellow }
function Write-Bad   { param([string]$Text) Write-Host ('  [X]  ' + $Text) -ForegroundColor Red }
function Add-Report  { param([string]$Line) $script:Report += $Line }

function Save-Report {
    if ($DryRun -or $script:Report.Count -eq 0) { return }
    try {
        $desktop = [Environment]::GetFolderPath('Desktop')
        $path = Join-Path $desktop '网络诊断报告.txt'
        $stamp = '===== ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ====='
        $text = (($stamp, ($script:Report -join "`r`n")) -join "`r`n") + "`r`n"
        if (Test-Path -LiteralPath $path) {
            Add-Content -LiteralPath $path -Value $text -Encoding UTF8
        } else {
            [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($true)))
        }
        Write-Line ''
        Write-Line ('  诊断报告已存到桌面：' + $path) 'Green'
    } catch {
        Write-Alert '诊断报告保存失败（不影响修复）。'
    }
}

function Stop-Here {
    param([int]$Code = 0, [switch]$Wait)
    Save-Report
    if ($Wait -and -not $DryRun) {
        Write-Host ''
        [void](Read-Host '按回车键关闭本窗口')
    }
    exit $Code
}

try {
    $wid = [Security.Principal.WindowsIdentity]::GetCurrent()
    $IsAdmin = (New-Object Security.Principal.WindowsPrincipal($wid)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { $IsAdmin = $false }

# 让改动立即生效：通知 WinINET 重新读取代理设置
function Invoke-ProxyRefresh {
    try {
        if (-not ('DshWinInet.Api' -as [type])) {
            Add-Type -Namespace DshWinInet -Name Api -MemberDefinition @'
[DllImport("wininet.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);
'@
        }
        [void][DshWinInet.Api]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)   # SETTINGS_CHANGED
        [void][DshWinInet.Api]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)   # REFRESH
        return $true
    } catch { return $false }
}

# netsh 在中文系统上的输出编码不固定（有的机器 UTF-8、有的 GBK），原文写进报告会乱码。
# 这里只用与编码无关的「数字.数字.数字.数字:端口 / http(s)://」特征判断有没有代理地址。
function Get-WinHttpSummary {
    param($Lines)
    $text = (($Lines | ForEach-Object { [string]$_ }) -join ' ')
    $m = [regex]::Match($text, '\d{1,3}(\.\d{1,3}){3}:\d{1,5}')
    if ($m.Success) { return ('检测到代理 ' + $m.Value) }
    $m2 = [regex]::Match($text, 'https?://[^\s]+')
    if ($m2.Success) { return ('检测到代理 ' + $m2.Value) }
    return '没有代理服务器（直接访问）'
}

function Test-TcpPort {
    param([string]$TargetHost, [int]$Port, [int]$TimeoutMs = 4000)
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $ar = $c.BeginConnect($TargetHost, $Port, $null, $null)
        $ok = $ar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        $result = ($ok -and $c.Connected)
        $c.Close()
        return $result
    } catch { return $false }
}

Write-Host ''
Write-Host '==================================================' -ForegroundColor White
Write-Host '          代理残留修复工具（Windows）' -ForegroundColor White
Write-Host '==================================================' -ForegroundColor White
Write-Line '  适用：Clash / Clash for Windows / Clash Verge / mihomo /'
Write-Line '        v2rayN / sing-box 等代理软件被强制关机或崩溃后：'
Write-Line '          · 所有网页都打不开，关掉代理软件也没用'
Write-Line '          · 网页能开，但某个程序一直连不上服务器'
Write-Line ''
Write-Line '  本工具只清理代理设置和网络缓存，不碰任何个人文件，'
Write-Line '  也不安装、不下载任何东西。'
if ($DryRun) { Write-Line '  ** 演练模式：只检查、不修改 **' 'Yellow' }
if ($IsAdmin) { Write-Line '  当前权限：管理员' } else { Write-Line '  当前权限：普通用户' }
Add-Report ('时间：' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Add-Report ('管理员：' + $IsAdmin)

# ---------------- 1 ----------------
Write-Head '第 1 步  检查是否还有代理软件在运行'
$pattern = 'clash|mihomo|v2ray|xray|sing-box|nekoray|qv2ray|shadowsocks|proxifier|netch|verge'
$running = @()
try {
    $running = @(Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -match $pattern } |
        Select-Object -ExpandProperty ProcessName -Unique)
} catch { }
if ($running.Count -gt 0) {
    Write-Alert ('检测到代理程序还在运行：' + ($running -join ', '))
    Write-Line '        它可能又把代理打开。建议先在托盘图标上右键退出它，再运行本工具。' 'Yellow'
} else {
    Write-Ok '没有检测到代理软件在运行。'
}
Add-Report ('代理进程：' + $(if ($running.Count -gt 0) { $running -join ', ' } else { '无' }))

# ---------------- 2 ----------------
Write-Head '第 2 步  检查系统代理（浏览器用的那套：WinINET）'
$before = $null
try { $before = Get-ItemProperty -Path $RegPath -ErrorAction Stop } catch { }
if ($null -eq $before) {
    Write-Bad '读不到注册表的 Internet Settings 项，脚本没法继续。'
    Stop-Here -Code 1 -Wait
}

$curEnable = 0
try { $curEnable = [int]$before.ProxyEnable } catch { $curEnable = 0 }
$names = @($before.PSObject.Properties.Name)
$curServer = ''
$curPac = ''
$curAutoDetect = $null
if ($names -contains 'ProxyServer')   { $curServer = [string]$before.ProxyServer }
if ($names -contains 'AutoConfigURL') { $curPac    = [string]$before.AutoConfigURL }
if ($names -contains 'AutoDetect')    { $curAutoDetect = [int]$before.AutoDetect }

Write-Line ('  ProxyEnable    = ' + $curEnable + '      （1 = 开着系统代理）')
if ($curServer) { Write-Line ('  ProxyServer    = ' + $curServer) } else { Write-Line '  ProxyServer    = (空)' }
if ($curPac)    { Write-Line ('  AutoConfigURL  = ' + $curPac) }    else { Write-Line '  AutoConfigURL  = (空)' }
if ($null -ne $curAutoDetect) { Write-Line ('  AutoDetect     = ' + $curAutoDetect) }
Add-Report ('WinINET ProxyEnable=' + $curEnable + ' ProxyServer=' + $(if ($curServer) { $curServer } else { '(空)' }) + ' AutoConfigURL=' + $(if ($curPac) { $curPac } else { '(空)' }))

# 「局域网设置」里的勾选状态藏在 Connections 的二进制值里（bit1=自动检测、bit2=自动配置脚本、bit3=代理服务器）
$connFlags = @()
try {
    if (Test-Path -LiteralPath $ConnPath) {
        $ck = Get-ItemProperty -Path $ConnPath -ErrorAction Stop
        foreach ($n in @($ck.PSObject.Properties.Name)) {
            if ($n -like 'PS*') { continue }
            $v = $ck.$n
            if ($v -is [byte[]] -and $v.Length -gt 8) { $connFlags += [pscustomobject]@{ Name = $n; Bytes = $v } }
        }
    }
} catch { }
foreach ($cf in $connFlags) {
    $f = $cf.Bytes[8]
    Write-Line ('  ' + $cf.Name + ' 勾选位 = 0x' + ('{0:X2}' -f $f) + '   （0x02=自动检测设置, 0x04=使用自动配置脚本, 0x08=使用代理服务器）')
    Add-Report ('Connections\' + $cf.Name + ' flags=0x' + ('{0:X2}' -f $f))
}

# ---------------- 3 ----------------
Write-Head '第 3 步  清除残留的代理设置'
if ($curEnable -ne 0) {
    if ($DryRun) {
        Write-Line '  （演练模式，未修改）会把 ProxyEnable 改成 0' 'DarkYellow'
    } else {
        Set-ItemProperty -Path $RegPath -Name 'ProxyEnable' -Value 0 -Type DWord
        Write-Ok '已关掉「使用代理服务器」开关。'
    }
} else {
    Write-Ok '「使用代理服务器」本来就是关闭的。'
}

if ($curServer) {
    if ($curServer -match '127\.0\.0\.1|localhost|\[::1\]|0\.0\.0\.0') {
        if ($DryRun) {
            Write-Line ('  （演练模式，未修改）会清除 ProxyServer = ' + $curServer) 'DarkYellow'
        } else {
            Remove-ItemProperty -Path $RegPath -Name 'ProxyServer' -ErrorAction SilentlyContinue
            Write-Ok ('已清除残留的代理地址（' + $curServer + '）。')
        }
    } else {
        Write-Alert ('ProxyServer 指向 ' + $curServer + '，不像本机代理软件，可能是单位或校园网代理，已保留不动。')
    }
}

if ($curPac) {
    if ($curPac -match '127\.0\.0\.1|localhost|\[::1\]') {
        if ($DryRun) {
            Write-Line ('  （演练模式，未修改）会清除 AutoConfigURL = ' + $curPac) 'DarkYellow'
        } else {
            Remove-ItemProperty -Path $RegPath -Name 'AutoConfigURL' -ErrorAction SilentlyContinue
            Write-Ok ('已清除残留的自动配置脚本（' + $curPac + '）。')
        }
    } else {
        Write-Alert ('AutoConfigURL 指向 ' + $curPac + '，已保留不动。')
    }
}

# 取消「自动检测设置」
if ($null -ne $curAutoDetect -and $curAutoDetect -ne 0) {
    if ($DryRun) {
        Write-Line '  （演练模式，未修改）会把 AutoDetect 改成 0' 'DarkYellow'
    } else {
        Set-ItemProperty -Path $RegPath -Name 'AutoDetect' -Value 0 -Type DWord
        Write-Ok '已取消「自动检测设置」。'
    }
}

# 取消「局域网设置」里残留的勾选
$flagFixed = 0
foreach ($cf in $connFlags) {
    $f = $cf.Bytes[8]
    $new = $f -band 0xF1          # 清掉 bit1(自动检测)、bit2(自动配置脚本)、bit3(使用代理服务器)
    if ($new -ne $f) {
        if ($DryRun) {
            Write-Line ('  （演练模式，未修改）' + $cf.Name + '：0x' + ('{0:X2}' -f $f) + ' -> 0x' + ('{0:X2}' -f $new)) 'DarkYellow'
        } else {
            $cf.Bytes[8] = [byte]$new
            Set-ItemProperty -Path $ConnPath -Name $cf.Name -Value $cf.Bytes -Type Binary
            $flagFixed++
        }
    }
}
if ($flagFixed -gt 0) {
    Write-Ok ('已取消「局域网设置」里残留的 ' + $flagFixed + ' 处勾选（自动检测 / 自动配置脚本 / 使用代理服务器）。')
    Add-Report ('已清理 Connections 勾选位：' + $flagFixed + ' 处')
}

# ---------------- 4 ----------------
Write-Head '第 4 步  通知系统立即刷新代理设置'
if ($DryRun) {
    Write-Line '  （演练模式，跳过）' 'DarkYellow'
} elseif (Invoke-ProxyRefresh) {
    Write-Ok '已通知系统刷新，不用重启也能生效。'
} else {
    Write-Alert '刷新调用失败，重启电脑后同样会生效。'
}

# ---------------- 5：WinHTTP 只有管理员能改 ----------------
if (-not $IsAdmin -and -not $DryRun) {
    Write-Host ''
    Write-Alert '下一步要重置 WinHTTP 代理（浏览器以外大部分程序走的就是这一套），需要管理员权限。'
    Write-Line '        马上会弹出系统授权窗口，请点「是」。' 'Yellow'
    [void](Read-Host '        按回车键继续，关闭本窗口则放弃')

    $self = $PSCommandPath
    if (-not $self) { $self = $MyInvocation.MyCommand.Path }
    if (-not $self) { $self = $MyInvocation.InvocationName }

    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass',
            '-File', ('"' + $self + '"'),
            '-AdminPhase'
        ) | Out-Null
        Write-Line '        已用管理员身份打开新窗口，本窗口可以直接关闭。' 'Green'
        Stop-Here -Code 0
    } catch {
        Write-Bad '没有拿到管理员权限（可能点了「否」）。'
        Write-Line '        也可以右键 fix-proxy.bat，选「以管理员身份运行」再试一次。' 'Yellow'
        Add-Report '提权失败：用户拒绝或系统拒绝'
        Stop-Here -Code 1 -Wait
    }
}

# ================ 以下是管理员环节 ================

Write-Head '第 5 步  显示并重置 WinHTTP 代理（浏览器以外大部分程序走这一套）'
$showBefore = @()
try { $showBefore = @(& netsh winhttp show proxy 2>&1) } catch { }
foreach ($l in $showBefore) {
    $s = ([string]$l).Trim()
    if ($s) { Write-Line ('    ' + $s) }
}
Add-Report ('WinHTTP（重置前）：' + (Get-WinHttpSummary $showBefore))

if ($DryRun) {
    Write-Line '  （演练模式，跳过）netsh winhttp reset proxy' 'DarkYellow'
} else {
    # 注意：netsh 失败时不会抛异常，只会设置 $LASTEXITCODE，所以不能用 try/catch 判断
    # （2026-10-17 修：原来无条件打印「已重置」，没管理员权限时是假成功）。
    $winhttpExit = 0
    try { & netsh winhttp reset proxy 2>&1 | Out-Null; $winhttpExit = $LASTEXITCODE } catch { $winhttpExit = 1 }
    if ($winhttpExit -eq 0) {
        Write-Ok 'WinHTTP 代理已重置为「直接访问」。'
    } else {
        Write-Alert ("netsh winhttp reset proxy 失败（退出码 $winhttpExit），多半是没用管理员权限运行。这一步没做成，其他步骤不受影响。")
    }
    $showAfter = @()
    try { $showAfter = @(& netsh winhttp show proxy 2>&1) } catch { }
    Add-Report ('WinHTTP（重置后）：' + (Get-WinHttpSummary $showAfter))
}

Write-Head '第 6 步  刷新 DNS 缓存'
if ($DryRun) {
    Write-Line '  （演练模式，跳过）ipconfig /flushdns' 'DarkYellow'
} else {
    try { & ipconfig /flushdns 2>&1 | Out-Null; Write-Ok 'DNS 缓存已刷新。' } catch { Write-Alert '刷新 DNS 失败，可忽略。' }
}

# ---------------- 网卡上残留的代理 DNS ----------------
Write-Head '第 7 步  检查网卡上有没有残留的代理 DNS'
$dnsFixed = 0
try {
    $adapters = @(Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' })
    foreach ($a in $adapters) {
        $dnsList = @()
        try {
            $dnsList = @(Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction Stop |
                Select-Object -ExpandProperty ServerAddresses)
        } catch { }
        $dnsText = if ($dnsList.Count -gt 0) { $dnsList -join ', ' } else { '(自动获取)' }
        if ($dnsList.Count -gt 0 -and ($dnsList -join ',') -match '198\.18\.|127\.0\.0\.1|0\.0\.0\.0') {
            Write-Alert ('网卡「' + $a.Name + '」的 DNS 是 ' + $dnsText + ' —— 这是代理软件留下的，代理一关就没人应答。')
            Add-Report ('残留DNS：' + $a.Name + ' = ' + $dnsText)
            if ($DryRun) {
                Write-Line '  （演练模式，未修改）会把它改回「自动获取」。' 'DarkYellow'
            } else {
                try {
                    Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ResetServerAddresses -ErrorAction Stop
                    Write-Ok ('已把网卡「' + $a.Name + '」的 DNS 改回自动获取。')
                    $dnsFixed++
                } catch {
                    Write-Bad ('改 DNS 失败：' + $_.Exception.Message)
                }
            }
        } else {
            Write-Line ('  ' + $a.Name + '  DNS = ' + $dnsText)
            Add-Report ('DNS：' + $a.Name + ' = ' + $dnsText)
        }
    }
} catch {
    Write-Line '  （本机不允许读取网卡信息，跳过这一步，不影响修复）'
}

# ---------------- 虚拟网卡 ----------------
Write-Head '第 8 步  检查代理软件留下的虚拟网卡'
$virt = @()
try {
    $virt = @(Get-NetAdapter -ErrorAction Stop | Where-Object {
        $_.InterfaceDescription -match 'wintun|clash|mihomo|wireguard|tap-windows|tun2socks'
    })
} catch { }
if ($virt.Count -gt 0) {
    foreach ($a in $virt) {
        Write-Line ('  - ' + $a.Name + '   [' + $a.Status + ']   ' + $a.InterfaceDescription)
        Add-Report ('虚拟网卡：' + $a.Name + ' [' + $a.Status + '] ' + $a.InterfaceDescription)
    }
    Write-Alert '上面是代理软件创建的虚拟网卡（TUN 模式异常关闭时留下的），可能抢走流量。'
    Write-Line '        处理办法：设备管理器 → 网络适配器，找到上面这个名字，右键「卸载设备」，然后重启。' 'Yellow'
} else {
    Write-Ok '没有发现代理软件残留的虚拟网卡。'
}

Write-Head '第 9 步  查看默认路由（谁在接管上网流量）'
try {
    $routes = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Sort-Object RouteMetric)
    if ($routes.Count -eq 0) {
        Write-Bad '没有找到默认路由 —— 这本身就是上不了网的原因（网关或网卡有问题）。'
        Add-Report '默认路由：无'
    } else {
        foreach ($r in $routes) {
            Write-Line ('  - 网卡：' + $r.InterfaceAlias + '    下一跳：' + $r.NextHop + '    跳数：' + $r.RouteMetric)
            Add-Report ('默认路由：' + $r.InterfaceAlias + ' -> ' + $r.NextHop + ' (metric ' + $r.RouteMetric + ')')
        }
    }
    $fake = @(Get-NetRoute -ErrorAction SilentlyContinue | Where-Object { $_.DestinationPrefix -match '^198\.18\.' })
    if ($fake.Count -gt 0) {
        Write-Alert ('发现 ' + $fake.Count + ' 条 198.18.x.x 的路由（代理软件的 fake-ip 段残留），可能把连接带进死路。')
        foreach ($r in $fake) { Add-Report ('198.18 路由：' + $r.DestinationPrefix + ' -> ' + $r.InterfaceAlias) }
    }
} catch {
    Write-Line '  （本机不允许读取路由表，跳过这一步，不影响修复）'
}

# ---------------- hosts ----------------
Write-Head '第 10 步  检查 hosts 文件有没有被改'
try {
    $hostsPath = Join-Path $env:WINDIR 'System32\drivers\etc\hosts'
    $hl = @(Get-Content -LiteralPath $hostsPath -ErrorAction Stop | Where-Object {
        $_.Trim() -ne '' -and -not $_.Trim().StartsWith('#')
    })
    $susp = @($hl | Where-Object {
        $_ -match '^\s*(127\.0\.0\.1|0\.0\.0\.0)\s' -and $_ -notmatch '\slocalhost(\s|$)'
    })
    if ($susp.Count -gt 0) {
        Write-Alert ('hosts 里有 ' + $susp.Count + ' 条把域名指向本机 / 黑洞的记录（自定义记录共 ' + $hl.Count + ' 条）：')
        $susp | Select-Object -First 10 | ForEach-Object { Write-Line ('    ' + $_) }
        Write-Line '        如果里面有打不开的那个网站或服务的域名，需要把那几行删掉。' 'Yellow'
        Add-Report 'hosts 可疑记录：'
        foreach ($l in $susp) { Add-Report ('  ' + $l) }
    } else {
        Write-Ok ('hosts 没有把域名指向本机 / 黑洞的记录（自定义记录共 ' + $hl.Count + ' 条）。')
        Add-Report ('hosts 自定义记录条数：' + $hl.Count + '（无可疑项）')
    }
} catch {
    Write-Line '  （读不到 hosts 文件，跳过）'
}

# ---------------- 连通性 ----------------
Write-Head '第 11 步  测试网页能不能打开'
$webOK = $false
foreach ($u in @('http://www.baidu.com', 'http://www.msftconnecttest.com/connecttest.txt')) {
    try {
        $resp = Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
        if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 400) { $webOK = $true; break }
    } catch { }
}
if ($webOK) { Write-Ok '网页可以正常打开。' } else { Write-Bad '网页打不开。' }
Add-Report ('网页测试：' + $(if ($webOK) { '通' } else { '不通' }))

foreach ($t in @(
        @('www.baidu.com', 443, '国内网站'),
        @('www.msftconnecttest.com', 443, '国外网站（Microsoft 连通性测试）')
    )) {
    $reachable = Test-TcpPort -TargetHost $t[0] -Port $t[1]
    if ($reachable) { Write-Ok ($t[2] + '（' + $t[0] + '）可以连上') }
    else { Write-Bad ($t[2] + '（' + $t[0] + '）连不上') }
    Add-Report ('连通性 ' + $t[0] + ' = ' + $(if ($reachable) { 'OK' } else { 'FAIL' }))
}

# ---------------- 深度修复 ----------------
if (-not $webOK -and -not $DryRun) {
    Write-Head '第 12 步  深度修复（最后手段，必须重启）'
    Write-Line '  网页本身就不通，说明网络底层还有问题，可以重置 Windows 网络堆栈。' 'Yellow'
    Write-Line '  注意：这一步会重置网卡配置（设过固定 IP 的要重新设），并且必须重启电脑。' 'Yellow'
    $ans = Read-Host '  输入 Y 再回车执行，直接回车则跳过'
    if ($ans -eq 'Y' -or $ans -eq 'y') {
        # 同理必须查退出码：这三条失败时也只设置 $LASTEXITCODE、不抛异常。
        # 逐条报告结果，而不是"有一条成功就整体成功" —— 三条互相独立，
        # 只重置成功一条时整个堆栈并没有复位完（2026-10-17 独立评审指出）。
        # 注意 `netsh int ip reset` 即使成功也常返回 1，所以"全非零"才判整体失败。
        $stackSteps = @('winsock', 'int ip', 'int ipv6')
        $stackCodes = @()
        foreach ($step in $stackSteps) {
            $code = 1
            $out = ''
            try {
                if ($step -eq 'winsock') { $out = (& netsh winsock reset 2>&1 | Out-String) }
                elseif ($step -eq 'int ip') { $out = (& netsh int ip reset 2>&1 | Out-String) }
                else { $out = (& netsh int ipv6 reset 2>&1 | Out-String) }
                $code = $LASTEXITCODE
            } catch { $code = 1; $out = '' }
            # ❗不能只看退出码：netsh int ip reset 明明做成了也常返回 1，
            # 只按退出码判会把成功报成失败，用户被误导去反复重跑（2026-10-17 复审第二次指出）。
            # 所以「退出码 0」或「自己打印了 OK」都算成功。
            $ok = ($code -eq 0) -or ($out -match 'OK!?|成功')
            $stackCodes += [pscustomobject]@{ Name = $step; Code = $code; Ok = $ok }
            if ($ok) {
                if ($code -eq 0) { Write-Ok ("  netsh " + $step + " reset 完成") }
                else { Write-Ok ("  netsh " + $step + " reset 完成（退出码 " + $code + "，但输出里是 OK，按成功算）") }
            } else {
                Write-Alert ("  netsh " + $step + " reset 返回 " + $code + "（这一步没做成）")
            }
        }
        $stackSummary = (($stackCodes | ForEach-Object { $_.Name + '=' + $_.Code + $(if ($_.Ok) { '/ok' } else { '/fail' }) }) -join ', ')
        # ❗三态报告：不能把"部分成功"说成"已重置"，那样用户会以为已经复位完。
        $stackOkCount = @($stackCodes | Where-Object { $_.Ok }).Count
        $stackTotal = $stackCodes.Count
        if ($stackOkCount -eq $stackTotal) {
            Write-Ok '网络堆栈已全部重置，请重启电脑。'
        } elseif ($stackOkCount -gt 0) {
            Write-Alert ("网络堆栈只重置成功 $stackOkCount/$stackTotal 条（" + $stackSummary + "）。完整复位没做到，重启后若仍不通，请用管理员身份重跑本脚本。")
        } else {
            Write-Alert ("三条 reset 全部返回非 0（" + $stackSummary + "），多半没有管理员权限，网络堆栈实际没重置。")
        }
        Add-Report ('网络堆栈重置结果：' + $stackSummary)
    } else {
        Write-Line '  已跳过深度修复。'
    }
}

# ---------------- 结论 ----------------
Write-Host ''
Write-Host '================ 处理结果 ================' -ForegroundColor White
if ($webOK) {
    Write-Ok '代理设置已经清理干净（WinINET + WinHTTP + 局域网设置勾选）。'
} else {
    Write-Alert '网页仍然不通，请按第 12 步的提示重启后再看。'
}
Write-Line ''
Write-Line '  接下来建议：'
Write-Line '    1. 重启一次电脑（让网络栈和虚拟网卡状态彻底复位）'
Write-Line '    2. 完全退出代理软件，并关掉它的「开机自启」'
Write-Line '    3. 再打开之前连不上的程序试一次'
Write-Line ''
Write-Line '  如果还是不行，把桌面上的「网络诊断报告.txt」发回来。' 'Yellow'
Stop-Here -Code 0 -Wait
