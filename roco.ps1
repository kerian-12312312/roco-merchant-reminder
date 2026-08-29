# roco.ps1 - 洛克王国世界远行商人 查询 / 定时提醒
#
# 用法:
#   ./roco.ps1 query           手动查询本轮商品
#   ./roco.ps1 list            列出全部商品(按轮次分组)
#   ./roco.ps1 check           拉取并检查关注商品，命中则推送(每轮只推一次)
#   ./roco.ps1 daemon          常驻循环，每 N 分钟检查一次(默认 5)
#   ./roco.ps1 push            把本轮在售商品推送到手机(不关注是否命中)
#   ./roco.ps1 test            发送一条测试推送到手机
#
# 可选参数:
#   -Config <path>   指定配置文件(默认脚本同目录 config.json)
#   -ApiKey <key>    覆盖 API Key
#   -PushToken <tok> 覆盖虾推啥 token
#   -IntervalMinutes <n> daemon 检查间隔
#   -MockFile <path> 使用本地 JSON 代替真实接口(测试用)

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('query', 'list', 'check', 'daemon', 'push', 'test')]
    [string]$Command = 'query',

    [string]$Config = (Join-Path $PSScriptRoot 'config.json'),
    [string]$ApiKey = '',
    [string]$PushToken = '',
    [int]$IntervalMinutes = 5,
    [string]$MockFile = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$RoundLabels = @('', '08:00-12:00', '12:00-16:00', '16:00-20:00', '20:00-24:00')

function Read-Config([string]$Path) {
    if (-not (Test-Path $Path)) { throw "找不到配置文件: $Path" }
    return (Get-Content -Raw -Path $Path | ConvertFrom-Json)
}

function Get-StatePath {
    return (Join-Path $PSScriptRoot '.rocom_state.json')
}

function Get-BeijingTime {
    # Linux(GitHub Actions)与 Windows 的时区名不同，逐个尝试并兜底
    $tz = $null
    foreach ($id in @('Asia/Shanghai', 'China Standard Time')) {
        try { $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById($id); break }
        catch { }
    }
    if (-not $tz) { return [System.DateTime]::UtcNow.AddHours(8) }
    return [System.TimeZoneInfo]::ConvertTimeFromUtc([System.DateTime]::UtcNow, $tz)
}

function Get-CurrentRound([datetime]$bj) {
    $h = $bj.Hour
    if ($h -ge 8 -and $h -lt 12) { return 1 }
    if ($h -ge 12 -and $h -lt 16) { return 2 }
    if ($h -ge 16 -and $h -lt 20) { return 3 }
    if ($h -ge 20 -and $h -lt 24) { return 4 }
    return 0
}

function Get-MerchantInfo($cfg) {
    if ($MockFile) {
        if (-not (Test-Path $MockFile)) { throw "找不到 Mock 文件: $MockFile" }
        return (Get-Content -Raw -Path $MockFile | ConvertFrom-Json)
    }
    $key = if ($ApiKey) { $ApiKey } else { $cfg.api.apiKey }
    if (-not $key) { throw '缺少 API Key：请在 config.json 的 api.apiKey 填写，或用 -ApiKey 传入。' }
    $base = $cfg.api.baseUrl.TrimEnd('/')
    $url = "$base/api/v1/games/rocom/merchant/info?refresh=true"
    $resp = Invoke-RestMethod -Uri $url -Method Get -Headers @{ 'X-API-Key' = $key } -TimeoutSec 20
    # 真实接口返回 { code, message, data }，取出 data 以便后续直接读 merchantActivities 等字段
    if ($resp.PSObject.Properties.Name -contains 'data' -and $null -ne $resp.data) {
        return $resp.data
    }
    return $resp
}

function Get-ProductGroups($resp) {
    $activity = $null
    if ($resp.merchantActivities) {
        $activity = if ($resp.merchantActivities -is [System.Array]) { $resp.merchantActivities[0] } else { $resp.merchantActivities }
    }
    elseif ($resp.merchant_activities) {
        $activity = if ($resp.merchant_activities -is [System.Array]) { $resp.merchant_activities[0] } else { $resp.merchant_activities }
    }
    if (-not $activity) { return @() }

    $out = @()
    foreach ($field in 'products', 'product_list', 'get_props', 'get_extra_props', 'get_pets') {
        $value = $activity.$field
        if ($null -eq $value) { continue }
        if ($value -is [System.Array]) { foreach ($i in $value) { $out += $i } }
        else { $out += $value }
    }
    return $out
}

function To-Ms([object]$v) {
    if ($null -eq $v -or "$v" -eq '') { return $null }
    $n = [long]"$v"
    if ($n -lt 100000000000) { $n = $n * 1000 }
    return $n
}

function Ms-ToUtcDate([object]$ms) {
    if ($null -eq $ms) { return $null }
    return ([System.DateTimeOffset]::FromUnixTimeMilliseconds([long]$ms)).UtcDateTime
}

function Test-IsActive($item) {
    $now = [System.DateTime]::UtcNow
    $s = To-Ms $item.start_time
    $e = To-Ms $item.end_time
    (($null -eq $s) -or ((Ms-ToUtcDate $s) -le $now)) -and
    (($null -eq $e) -or ((Ms-ToUtcDate $e) -gt $now))
}

function Get-PriceLimitMaps($resp) {
    $random = @()
    if ($resp.random_goods) { $random = @($resp.random_goods) }
    elseif ($resp.randomGoods) { $random = @($resp.randomGoods) }
    $price = @{}
    $limit = @{}
    foreach ($item in $random) {
        $name = "$($item.goods_name)"
        if (-not $name) { $name = "$($item.name)" }
        if (-not $name) { continue }
        if ($null -ne $item.price -and "$($item.price)" -ne '') { $price[$name] = $item.price }
        if ($null -ne $item.buy_limit_num -and "$($item.buy_limit_num)" -ne '') { $limit[$name] = $item.buy_limit_num }
    }
    return @{ price = $price; limit = $limit }
}

function Get-ItemName($item) {
    $name = "$($item.name)"
    if (-not $name) { $name = "$($item.goods_name)" }
    if (-not $name) { $name = '未知' }
    return $name
}

function Ms-ToBeijing([object]$ms) {
    if ($null -eq $ms) { return $null }
    $dt = ([System.DateTimeOffset]::FromUnixTimeMilliseconds([long]$ms)).UtcDateTime
    $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById('China Standard Time')
    return [System.TimeZoneInfo]::ConvertTimeFromUtc($dt, $tz)
}

function Format-Window($item) {
    $s = To-Ms $item.start_time
    $e = To-Ms $item.end_time
    $sD = Ms-ToBeijing $s
    $eD = Ms-ToBeijing $e
    if ($null -ne $sD -and $null -ne $eD) {
        if ($sD.Date -eq $eD.Date) { return "$($sD.ToString('MM-dd HH:mm'))-$($eD.ToString('HH:mm'))" }
        return "$($sD.ToString('MM-dd HH:mm'))-$($eD.ToString('MM-dd HH:mm'))"
    }
    if ($null -ne $sD) { return "自 $($sD.ToString('MM-dd HH:mm'))" }
    if ($null -ne $eD) { return "至 $($eD.ToString('MM-dd HH:mm'))" }
    return ''
}

function Send-Xtuis($cfg, $text, $desp) {
    $tok = if ($PushToken) { $PushToken } else { $cfg.notify.token }
    if (-not $tok) { throw '缺少虾推啥 token：请在 config.json 的 notify.token 填写，或用 -PushToken 传入。' }
    $pushHost = if ($cfg.notify.provider -eq 'bark') { 'bark.xtuis.cn' } else { 'wx.xtuis.cn' }
    $url = "https://$pushHost/$tok.send"
    $body = @{ text = $text; desp = $desp }
    return (Invoke-RestMethod -Uri $url -Method Post -Body $body -ContentType 'application/x-www-form-urlencoded' -TimeoutSec 15)
}

function Get-State([string]$path) {
    if (Test-Path $path) {
        try {
            $s = Get-Content -Raw -Path $path | ConvertFrom-Json
            if ($null -eq $s.sent) { $s.sent = @() }
            return $s
        }
        catch { return [pscustomobject]@{ sent = @() } }
    }
    return [pscustomobject]@{ sent = @() }
}

function Set-State([string]$path, $state) {
    $state | ConvertTo-Json -Depth 5 | Set-Content -Path $path -Encoding UTF8
}

function Invoke-Query($cfg) {
    $resp = Get-MerchantInfo $cfg
    $groups = Get-ProductGroups $resp
    $maps = Get-PriceLimitMaps $resp
    $bj = Get-BeijingTime
    $round = Get-CurrentRound $bj

    if ($round -eq 0) {
        Write-Host "远行商人尚未营业（每日 08:00-24:00）。当前北京时间：$(Get-Date $bj -Format 'yyyy-MM-dd HH:mm')"
        return
    }

    $active = @($groups | Where-Object { Test-IsActive $_ })
    Write-Host "远行商人 · 第${round}轮 ($($RoundLabels[$round])) · 北京时间 $(Get-Date $bj -Format 'HH:mm')"
    if ($active.Count -eq 0) { Write-Host '（本轮暂无商品）'; return }

    $idx = 0
    foreach ($p in $active) {
        $idx++
        $name = Get-ItemName $p
        $rawPrice = if ($maps.price.ContainsKey($name)) { "$($maps.price[$name])" } else { '' }
        $price = if ($rawPrice -ne '' -and $rawPrice -ne '0') { $rawPrice } else { '--' }
        $limit = if ($maps.limit.ContainsKey($name)) { $maps.limit[$name] } else { '--' }
        Write-Host ("{0,2}. {1}   价格:{2}  限购:{3}" -f $idx, $name, $price, $limit)
    }
}

function Invoke-List($cfg) {
    try { $resp = Get-MerchantInfo $cfg }
    catch { Write-Warning "获取商人数据失败: $($_.Exception.Message)"; return }
    $groups = Get-ProductGroups $resp
    $maps = Get-PriceLimitMaps $resp
    $bj = Get-BeijingTime

    # 去重：避免 products/product_list/get_props 多字段重复
    $seen = @{}
    $items = @()
    foreach ($p in $groups) {
        $s = To-Ms $p.start_time
        $e = To-Ms $p.end_time
        $key = "$($p._id)|$($p.id)|$($p.name)|$s|$e"
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $items += $p
    }

    $byRound = @{}
    foreach ($p in $items) {
        $r = 0
        if ($null -ne $p.round) { $r = [int]$p.round }
        if (-not $byRound.ContainsKey($r)) { $byRound[$r] = @() }
        $byRound[$r] += $p
    }

    $groupLabel = @{ 0 = '常规/长期' }
    foreach ($r in 1..4) { $groupLabel[$r] = "第${r}轮 $($RoundLabels[$r])" }

    Write-Host "远行商人 · 全部商品($($items.Count) 件) · 北京时间 $(Get-Date $bj -Format 'yyyy-MM-dd HH:mm')"
    foreach ($r in 1, 2, 3, 4, 0) {
        if (-not $byRound.ContainsKey($r)) { continue }
        $list = $byRound[$r] | Sort-Object { [long](To-Ms $_.start_time) }
        Write-Host ""
        Write-Host "【$($groupLabel[$r])】"
        foreach ($p in $list) {
            $name = Get-ItemName $p
            $limit = if ($maps.limit.ContainsKey($name)) { $maps.limit[$name] } else { '--' }
            $rawPrice = if ($maps.price.ContainsKey($name)) { "$($maps.price[$name])" } else { '' }
            $price = if ($rawPrice -ne '' -and $rawPrice -ne '0') { $rawPrice } else { '--' }
            $win = Format-Window $p
            Write-Host ("  {0}   限购:{1}  价格:{2}  {3}" -f $name, $limit, $price, $win)
        }
    }
}

function Invoke-Check($cfg) {
    try { $resp = Get-MerchantInfo $cfg }
    catch { Write-Warning "获取商人数据失败: $($_.Exception.Message)"; return }

    $groups = Get-ProductGroups $resp
    $bj = Get-BeijingTime
    $round = Get-CurrentRound $bj
    if ($round -eq 0) {
        Write-Host "（$(Get-Date $bj -Format 'HH:mm') 商人未营业，跳过）"
        return
    }

    $active = @($groups | Where-Object { Test-IsActive $_ })
    $watch = @($cfg.watchlist)
    $hits = @()
    foreach ($p in $active) {
        $name = Get-ItemName $p
        foreach ($w in $watch) {
            if ($name -like "*$w*") { $hits += $name; break }
        }
    }
    $hits = @($hits | Select-Object -Unique)

    $dateKey = "{0:yyyy-MM-dd}-{1}" -f $bj, $round
    $statePath = Get-StatePath
    $state = Get-State $statePath
    if ($state.sent -contains $dateKey) {
        Write-Host "$dateKey 已提醒过，跳过"
        return
    }
    if ($hits.Count -eq 0) {
        Write-Host "$dateKey 无匹配商品"
        return
    }

    # 单个命中用商品名做标题；多个命中改成「有多个值得购买的东西」
    $text = if ($hits.Count -eq 1) { "$($hits[0])" } else { '有多个值得购买的东西' }
    $desp = "命中：$($hits -join '、')`n第${round}轮 $($RoundLabels[$round])`n$(Get-Date $bj -Format 'yyyy-MM-dd HH:mm')"
    try {
        Send-Xtuis $cfg $text $desp
        $state.sent = @($state.sent + $dateKey)
        Set-State $statePath $state
        Write-Host "已推送: $($hits -join '、')"
    }
    catch {
        Write-Warning "推送失败: $($_.Exception.Message)"
    }
}

function Invoke-Test($cfg) {
    $text = "远行商人提醒 · 测试"
    $desp = "收到即配置成功。`n关注商品：$($cfg.watchlist -join '、')"
    Send-Xtuis $cfg $text $desp
    Write-Host '测试推送已发送，请查看手机。'
}

function Invoke-Push($cfg) {
    try { $resp = Get-MerchantInfo $cfg }
    catch { Write-Warning "获取商人数据失败: $($_.Exception.Message)"; return }
    $groups = Get-ProductGroups $resp
    $bj = Get-BeijingTime
    $round = Get-CurrentRound $bj
    $active = @($groups | Where-Object { Test-IsActive $_ })
    $names = @($active | ForEach-Object { Get-ItemName $_ })

    $text = if ($round -eq 0) { '远行商人' } else { "远行商人 · 第${round}轮" }
    $desp = if ($names.Count -eq 0) {
        "当前暂无商品`n$(Get-Date $bj -Format 'yyyy-MM-dd HH:mm')"
    }
    else {
        "在售：`n" + ($names -join "`n") + "`n$(Get-Date $bj -Format 'yyyy-MM-dd HH:mm')"
    }
    Send-Xtuis $cfg $text $desp
    Write-Host "已推送当前货架：$($names -join '、')"
}

function Invoke-Daemon($cfg) {
    Write-Host "daemon 启动，每 $IntervalMinutes 分钟检查一次。Ctrl+C 退出。"
    while ($true) {
        Invoke-Check $cfg
        Start-Sleep -Seconds ($IntervalMinutes * 60)
    }
}

$cfg = Read-Config $Config
switch ($Command) {
    'query' { Invoke-Query $cfg }
    'list' { Invoke-List $cfg }
    'check' { Invoke-Check $cfg }
    'daemon' { Invoke-Daemon $cfg }
    'push' { Invoke-Push $cfg }
    'test' { Invoke-Test $cfg }
}
