<#
.SYNOPSIS
    ローカルのフォルダ階層を Salesforce のコンテンツライブラリへ移行する。

.DESCRIPTION
    指定したルートフォルダを Salesforce のコンテンツライブラリ (ContentWorkspace) として作成し、
    配下のフォルダ階層を ContentFolder として再現、ファイルを ContentVersion としてアップロードして
    対応するフォルダへ配置する。結果は CSV に出力する。

    Salesforce 側の構造操作は匿名 Apex で行い、ローカルファイルの読み取りとバイナリの
    アップロードは本スクリプト (REST API) が担当する。匿名 Apex はローカルファイルシステムを
    読めないため、この役割分担が必須。

    処理は 5 フェーズ。ライブラリ作成とフォルダ作成は MIXED_DML_OPERATION により
    同一トランザクションで実行できないため、必ず別の Apex 実行に分ける。

      Phase 1  ライブラリ作成          匿名 Apex (単独トランザクション)
      Phase 2  フォルダ階層作成        匿名 Apex (深さごとに一括 insert)
      Phase 3  ファイルアップロード    REST API (ContentVersion)
      Phase 4  フォルダへ配置          匿名 Apex (ContentFolderMember 一括 update)
      Phase 5  CSV 出力

    再実行は安全。既存のライブラリ / フォルダは作り直さず再利用する。

.PARAMETER RootPath
    移行元のルートフォルダ。このフォルダ名がライブラリ名の既定値になる。

.PARAMETER LibraryName
    作成するライブラリの表示名。既定はルートフォルダ名。

.PARAMETER TargetOrg
    接続先組織のエイリアス。省略時は sf の既定接続先。

.PARAMETER OutDir
    CSV と生成した匿名 Apex の出力先。既定は ./migration-output。

.PARAMETER MaxFileSizeMB
    アップロードするファイルの上限。REST API の base64 JSON 方式の制約により既定 37MB。
    これを超えるファイルはスキップし、CSV に Skipped として記録する。

.PARAMETER ExcludePattern
    除外するファイル名のワイルドカード。複数指定可。

.PARAMETER IgnoreScanErrors
    走査できないフォルダがあっても中断せず、読めた分だけ移行する。
    既定では移行漏れを防ぐため中断する。

.PARAMETER Force
    ライブラリ内の既存ファイル確認を省略し、同名ファイルがあっても再アップロードする。
    ContentVersion は insert のたびに別の ContentDocument になるため、指定するとファイルが重複する。

.PARAMETER DryRun
    Salesforce へ一切書き込まず、走査結果と実行計画のみ表示する。

.EXAMPLE
    ./Import-FolderToLibrary.ps1 -RootPath 'D:\Docs\ProjectA' -DryRun

.EXAMPLE
    ./Import-FolderToLibrary.ps1 -RootPath 'D:\Docs\ProjectA' -LibraryName 'Project A 資料'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RootPath,
    [string]   $LibraryName,
    [string]   $TargetOrg,
    [string]   $OutDir = './migration-output',
    [int]      $MaxFileSizeMB = 37,
    [string[]] $ExcludePattern = @('Thumbs.db', '.DS_Store', 'desktop.ini'),
    [switch]   $Force,
    [switch]   $IgnoreScanErrors,
    [switch]   $DryRun
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Windows PowerShell 5.1 は既定で TLS 1.0/1.1 を使うことがあり、Salesforce に接続できない。
if ($PSVersionTable.PSVersion.Major -lt 6) {
    [System.Net.ServicePointManager]::SecurityProtocol =
        [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
}

# 匿名 Apex 1 実行あたりに詰め込む件数。スクリプト長と SOQL/DML 行数の両方に余裕を持たせている。
$MoveChunkSize  = 400
$QueryChunkSize = 300

#region ヘルパー

function Write-Phase {
    param([string]$Message)
    Write-Host ''
    Write-Host "== $Message" -ForegroundColor Cyan
}

function ConvertTo-DeveloperName {
    # ライブラリの DeveloperName は英数字と _ のみ。先頭は英字、連続 _ 不可、末尾 _ 不可。
    # 日本語名は素朴に置換すると情報が全て落ちて別ライブラリと衝突するため、
    # ASCII 以外を含む場合は元の名前のハッシュを付与して一意性を担保する。
    # DeveloperName は再実行時の突合キーなので、同じ入力から必ず同じ値が出る必要がある。
    param([string]$Text)
    $n = $Text -replace '[^A-Za-z0-9]', '_'
    $n = $n -replace '_+', '_'
    $n = $n.Trim('_')

    if ($Text -match '[^\x20-\x7E]') {
        $md5   = [System.Security.Cryptography.MD5]::Create()
        $bytes = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))
        $md5.Dispose()
        $suffix = -join ($bytes[0..3] | ForEach-Object { $_.ToString('x2') })
        $n = if ($n -eq '') { "Lib_$suffix" } else { "${n}_$suffix" }
    }

    if ($n -eq '' -or $n -notmatch '^[A-Za-z]') { $n = 'Lib_' + $n }
    if ($n.Length -gt 80) { $n = $n.Substring(0, 80).TrimEnd('_') }
    return $n
}

function Format-Size {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return "$([math]::Round($Bytes / 1GB, 2)) GB" }
    if ($Bytes -ge 1MB) { return "$([math]::Round($Bytes / 1MB, 1)) MB" }
    if ($Bytes -ge 1KB) { return "$([math]::Round($Bytes / 1KB, 1)) KB" }
    return "$Bytes B"
}

function ConvertTo-ApexString {
    # Apex 文字列リテラルへの埋め込み。生成コードなので必ずエスケープする。
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return $Text.Replace('\', '\\').Replace("'", "\'").Replace("`r", '').Replace("`n", '\n')
}

function Hide-Secret {
    # sf の応答にはアクセストークンが含まれる。エラーメッセージにそのまま載せると
    # コンソールやログに漏れるため、必ずマスクしてから表示する。
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    $masked = $Text -replace '(?<="accessToken"\s*:\s*")[^"]+', '<redacted>'
    return $masked -replace '00D[A-Za-z0-9]{12,15}![^"\s,]+', '<redacted>'
}

function Invoke-SfRaw {
    # sf を呼び出して標準出力だけを文字列で返す。
    #
    # Windows PowerShell 5.1 特有の落とし穴が 2 つある。
    #   1. ErrorActionPreference='Stop' だと、ネイティブコマンドが標準エラーに何か
    #      出しただけで NativeCommandError になる。sf は更新通知を標準エラーに出す。
    #   2. 2>&1 で標準エラーを混ぜて Out-String に通すと、コンソール幅で折り返されて
    #      JSON が改行と空白で分断され、解析できなくなる。
    # そのため標準エラーはファイルへ逃がし、標準出力は Out-String を使わず素直に連結する。
    param([string[]]$Arguments)
    $errFile  = [System.IO.Path]::GetTempFileName()
    $prevPref = $ErrorActionPreference
    $prevEnc  = $null
    $ErrorActionPreference = 'Continue'
    try {
        # sf は UTF-8 で出力するが、PowerShell はネイティブコマンドの出力を
        # [Console]::OutputEncoding で復号する。日本語 Windows のコンソールは既定が
        # CP932 なので、そのままだと日本語が化けたうえ JSON 自体が壊れて解析に失敗する。
        # 呼び出しの間だけ UTF-8 に切り替え、元の設定へ必ず戻す。
        try {
            $prevEnc = [Console]::OutputEncoding
            [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
        } catch {
            # コンソールが割り当てられていない場合は設定できない。
            # その状況では既定で UTF-8 として扱われるため実害はない。
            $prevEnc = $null
        }
        $lines = & sf @Arguments 2>$errFile
        return ($lines -join "`n")
    } finally {
        if ($null -ne $prevEnc) { try { [Console]::OutputEncoding = $prevEnc } catch {} }
        $ErrorActionPreference = $prevPref
        Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
    }
}

function ConvertFrom-SfJson {
    # sf は JSON の前に更新通知などの警告行を出すことがあるため、最初の { 以降だけを取り出す。
    param([string]$Raw, [string]$Context)
    $i = $Raw.IndexOf('{')
    if ($i -lt 0) { throw "$Context の応答に JSON が含まれていませんでした。`n$(Hide-Secret $Raw)" }
    try { return $Raw.Substring($i) | ConvertFrom-Json }
    catch { throw "$Context の応答を解析できませんでした。`n$(Hide-Secret $Raw)" }
}

function Get-OrgConnection {
    param([string]$Org)
    $sfArgs = @('org', 'display', '--json')
    if ($Org) { $sfArgs += @('--target-org', $Org) }
    $raw = Invoke-SfRaw -Arguments $sfArgs
    $j = ConvertFrom-SfJson -Raw $raw -Context 'sf org display'
    if ($j.status -ne 0) { throw "組織情報の取得に失敗しました (status=$($j.status))。" }

    # StrictMode 下では存在しないプロパティへのアクセスが例外になるため、必ず有無を確認する。
    $props = $j.result.PSObject.Properties.Name
    if ($props -notcontains 'accessToken' -or -not $j.result.accessToken) {
        throw 'アクセストークンを取得できませんでした。sf org login web で再認証してください。'
    }
    $apiVersion = if ($props -contains 'apiVersion' -and $j.result.apiVersion) { $j.result.apiVersion } else { '67.0' }

    [pscustomobject]@{
        InstanceUrl = $j.result.instanceUrl.TrimEnd('/')
        AccessToken = $j.result.accessToken
        ApiVersion  = $apiVersion
        Username    = $j.result.username
    }
}

function Invoke-AnonymousApex {
    # 生成した匿名 Apex を実行し、デバッグログを返す。失敗時は例外。
    param(
        [Parameter(Mandatory)][string] $Code,
        [Parameter(Mandatory)][string] $Label,
        [string] $Org,
        [Parameter(Mandatory)][string] $ApexDir
    )
    $file = Join-Path $ApexDir "$Label.apex"
    # Set-Content -Encoding UTF8 は 5.1 では BOM 付き、7 では BOM なしと挙動が割れる。
    # BOM が付くと Apex ソースの先頭が非 ASCII 文字になりコンパイルが通らないため、
    # バージョンに依存しない .NET の API で BOM なし UTF-8 を明示的に書く。
    [System.IO.File]::WriteAllText($file, $Code, (New-Object System.Text.UTF8Encoding $false))

    $sfArgs = @('apex', 'run', '--file', $file, '--json')
    if ($Org) { $sfArgs += @('--target-org', $Org) }
    $raw = Invoke-SfRaw -Arguments $sfArgs
    $j = ConvertFrom-SfJson -Raw $raw -Context "sf apex run ($Label / 生成物: $file)"

    # sf がコマンド自体で失敗した場合、応答に result は含まれず message だけが返る。
    if ($j.PSObject.Properties.Name -notcontains 'result') {
        $msg = if ($j.PSObject.Properties.Name -contains 'message') { $j.message } else { Hide-Secret $raw }
        throw "sf apex run が失敗しました ($Label): $msg`n生成物: $file"
    }
    $r = $j.result
    if (-not $r.compiled) { throw "Apex のコンパイルに失敗しました ($Label): $($r.compileProblem)`n生成物: $file" }
    if (-not $r.success) { throw "Apex の実行に失敗しました ($Label): $($r.exceptionMessage)`n$($r.exceptionStackTrace)`n生成物: $file" }
    return $r.logs
}

function Get-ApexMarker {
    # デバッグログから SFMIG|<種別>|... 形式のマーカーを拾う。
    # Salesforce のデバッグログは行の区切り文字である | を &#124; に、その他の記号も
    # HTML 実体参照にエスケープするため、突合前に必ずデコードする。
    # フォルダ名に & が含まれる場合もここで元に戻る。
    param([string]$Logs, [string]$Kind)
    # デバッグログには実行したソースコードも "Execute Anonymous:" 行として含まれる。
    # System.debug の呼び出し自体がマーカー文字列に一致してしまうため、
    # 実際の出力である USER_DEBUG 行だけを対象にする。
    $decoded = [System.Net.WebUtility]::HtmlDecode($Logs)
    $out = @()
    foreach ($line in ($decoded -split "`n")) {
        if ($line -match "\|USER_DEBUG\|.*?\|DEBUG\|SFMIG\|$Kind\|(.+?)\s*$") { $out += $Matches[1].Trim() }
    }
    return $out
}

function Split-Chunk {
    # SOQL の IN 句が長くなりすぎないよう、ID の配列を一定数ずつに切る。
    param([string[]]$Items, [int]$Size)
    $chunks = @()
    for ($i = 0; $i -lt $Items.Count; $i += $Size) {
        $last = [math]::Min($i + $Size - 1, $Items.Count - 1)
        $chunks += , @($Items[$i..$last])
    }
    return $chunks
}

function Get-FolderPathMap {
    # ライブラリ配下のフォルダを浅い階層から順にたどり、「パス -> ContentFolder Id」を作る。
    #
    # 以前はこの対応を匿名 Apex の System.debug から拾っていたが、デバッグログは
    # サイズ上限で切り詰められうえ記号がエスケープされる、壊れやすい経路だった。
    # SOQL なら件数にも文字種にも左右されないため、そちらへ寄せている。
    param(
        [Parameter(Mandatory)][string] $RootId,
        [Parameter(Mandatory)][int]    $MaxDepth,
        [string] $Org,
        [int]    $ChunkSize = 200
    )
    $map = @{ '' = $RootId }
    $frontier = @{ $RootId = '' }

    for ($d = 0; $d -lt $MaxDepth -and $frontier.Count -gt 0; $d++) {
        $next = @{}
        foreach ($chunk in (Split-Chunk -Items @($frontier.Keys) -Size $ChunkSize)) {
            $inList = ($chunk | ForEach-Object { "'$_'" }) -join ','
            $soql = "SELECT Id, Name, ParentContentFolderId FROM ContentFolder WHERE ParentContentFolderId IN ($inList)"
            foreach ($r in (Invoke-SfQuery -Soql $soql -Org $Org)) {
                $base = $frontier[$r.ParentContentFolderId]
                $path = if ($base -eq '') { $r.Name } else { "$base/$($r.Name)" }
                $map[$path] = $r.Id
                $next[$r.Id] = $path
            }
        }
        $frontier = $next
    }
    return $map
}

function Invoke-SfQuery {
    param([string]$Soql, [string]$Org)
    $sfArgs = @('data', 'query', '--query', $Soql, '--json')
    if ($Org) { $sfArgs += @('--target-org', $Org) }
    $raw = Invoke-SfRaw -Arguments $sfArgs
    $j = ConvertFrom-SfJson -Raw $raw -Context 'sf data query'
    if ($j.status -ne 0) { throw "SOQL の実行に失敗しました: $Soql" }
    if ($j.result.totalSize -eq 0) { return @() }
    return @($j.result.records)
}

#endregion

#region Phase 0 : 走査

Write-Phase 'Phase 0: ローカルフォルダを走査'

if (-not (Test-Path -LiteralPath $RootPath -PathType Container)) {
    throw "ルートフォルダが見つかりません: $RootPath"
}
$rootItem = Get-Item -LiteralPath $RootPath
$rootFull = $rootItem.FullName.TrimEnd('\')
if (-not $LibraryName) { $LibraryName = $rootItem.Name }
$developerName = ConvertTo-DeveloperName $LibraryName

# 走査は途中で失敗しうる。よくあるのは名前の末尾にスペースやドットが付いたフォルダで、
# Win32 API がそれを落とすため Get-ChildItem -Recurse が中へ入れない（5.1 で顕著）。
# 黙って読み飛ばすと移行漏れになるので、拾えなかったパスは必ず表に出す。
$scanErrors = @()
$rawFolders = @(Get-ChildItem -LiteralPath $rootFull -Directory -Recurse -ErrorAction SilentlyContinue -ErrorVariable +scanErrors)
$rawFiles   = @(Get-ChildItem -LiteralPath $rootFull -File -Recurse -ErrorAction SilentlyContinue -ErrorVariable +scanErrors)

if ($scanErrors.Count -gt 0 -and -not $IgnoreScanErrors) {
    Write-Host ''
    Write-Host '  走査できなかったパスがあります:' -ForegroundColor Red
    foreach ($e in ($scanErrors | Select-Object -First 20)) {
        Write-Host "    - $($e.TargetObject)" -ForegroundColor Red
    }
    throw ("走査に失敗したパスが $($scanErrors.Count) 件あります。フォルダ名の末尾にスペースやドットが付いていないか確認してください。" +
           '移行漏れを承知で続行する場合は -IgnoreScanErrors を指定します。')
}

# フォルダ: ルートからの相対パスを / 区切りで保持
$folders = @(
    $rawFolders |
        ForEach-Object { $_.FullName.Substring($rootFull.Length + 1).Replace('\', '/') } |
        Sort-Object
)

# ファイル: 相対フォルダパスと物理パスを保持
$files = @()
foreach ($f in $rawFiles) {
    $skip = $false
    foreach ($p in $ExcludePattern) { if ($f.Name -like $p) { $skip = $true; break } }
    if ($skip) { continue }
    $rel = $f.FullName.Substring($rootFull.Length + 1).Replace('\', '/')
    $dir = if ($rel.Contains('/')) { $rel.Substring(0, $rel.LastIndexOf('/')) } else { '' }
    $files += [pscustomobject]@{
        FullPath   = $f.FullName
        RelPath    = $rel
        FolderPath = $dir
        Name       = $f.Name
        SizeBytes  = $f.Length
    }
}

$maxBytes   = $MaxFileSizeMB * 1MB
$oversize   = @($files | Where-Object { $_.SizeBytes -gt $maxBytes })
$uploadable = @($files | Where-Object { $_.SizeBytes -le $maxBytes })
$totalBytes = if ($files.Count -gt 0) { ($files | Measure-Object SizeBytes -Sum).Sum } else { 0 }

Write-Host "  ルート        : $rootFull"
Write-Host "  ライブラリ名  : $LibraryName  (DeveloperName: $developerName)"
Write-Host "  フォルダ数    : $($folders.Count)"
Write-Host "  ファイル数    : $($files.Count)  (アップロード対象 $($uploadable.Count) / 上限超過 $($oversize.Count))"
Write-Host "  合計サイズ    : $(Format-Size $totalBytes)"

if ($oversize.Count -gt 0) {
    Write-Host "  上限 $MaxFileSizeMB MB を超えるためスキップ:" -ForegroundColor Yellow
    foreach ($o in $oversize) {
        Write-Host "    - $($o.RelPath) ($(Format-Size $o.SizeBytes))" -ForegroundColor Yellow
    }
}

if ($DryRun) {
    Write-Host ''
    Write-Host 'DryRun のため Salesforce へは書き込みませんでした。' -ForegroundColor Green
    return
}

if ($uploadable.Count -eq 0 -and $folders.Count -eq 0) {
    Write-Host '移行対象がありません。' -ForegroundColor Yellow
    return
}

$OutDir  = (New-Item -ItemType Directory -Force -Path $OutDir).FullName
$apexDir = (New-Item -ItemType Directory -Force -Path (Join-Path $OutDir 'apex')).FullName

$conn = Get-OrgConnection -Org $TargetOrg
Write-Host "  接続先        : $($conn.Username) @ $($conn.InstanceUrl)"

#endregion

#region Phase 1 : ライブラリ作成

Write-Phase 'Phase 1: ライブラリを作成'

# ContentWorkspace の DML はここだけで完結させる。
# 後続の ContentFolder と同一トランザクションにすると MIXED_DML_OPERATION で失敗する。
$libDev  = ConvertTo-ApexString $developerName
$libName = ConvertTo-ApexString $LibraryName
$apex = @"
List<ContentWorkspace> existing = [
    SELECT Id, RootContentFolderId FROM ContentWorkspace
    WHERE DeveloperName = '$libDev' LIMIT 1
];
ContentWorkspace ws;
if (existing.isEmpty()) {
    ws = new ContentWorkspace(
        Name = '$libName',
        DeveloperName = '$libDev',
        ShouldAddCreatorMembership = true
    );
    insert ws;
    ws = [SELECT Id, RootContentFolderId FROM ContentWorkspace WHERE Id = :ws.Id];
    System.debug('SFMIG|LIB|' + ws.Id + '|' + ws.RootContentFolderId + '|created');
} else {
    ws = existing[0];
    System.debug('SFMIG|LIB|' + ws.Id + '|' + ws.RootContentFolderId + '|reused');
}
"@

$logs = Invoke-AnonymousApex -Code $apex -Label '01-create-library' -Org $TargetOrg -ApexDir $apexDir
$libMarker = @(Get-ApexMarker -Logs $logs -Kind 'LIB')
if ($libMarker.Count -eq 0) { throw 'ライブラリ ID を取得できませんでした。migration-output/apex/01-create-library.apex を直接実行して確認してください。' }
$parts = $libMarker[0] -split '\|'
if ($parts.Count -lt 3) {
    throw "ライブラリ作成の結果を解釈できませんでした。デバッグログの該当行: $($libMarker[0])"
}
$workspaceId  = $parts[0]
$rootFolderId = $parts[1]
Write-Host "  ライブラリ    : $workspaceId ($($parts[2]))"
Write-Host "  ルートフォルダ: $rootFolderId"

#endregion

#region Phase 2 : フォルダ階層作成

Write-Phase 'Phase 2: フォルダ階層を作成'

$folderPathToId = @{ '' = $rootFolderId }

# 最も深い階層。フォルダを SOQL でたどり直すときの打ち切り深さに使う。
$maxDepth = 0
foreach ($f in $folders) { $maxDepth = [math]::Max($maxDepth, ($f -split '/').Count) }

if ($folders.Count -gt 0) {
    # 深さごとにまとめて insert する。DML ステートメント数は階層の深さ分で済む。
    $byDepth = $folders | Group-Object { ($_ -split '/').Count } | Sort-Object { [int]$_.Name }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('Map<String, Id> m = new Map<String, Id>();')
    [void]$sb.AppendLine("m.put('', '$rootFolderId');")

    foreach ($grp in $byDepth) {
        $fullList = ($grp.Group | ForEach-Object { "'" + (ConvertTo-ApexString $_) + "'" }) -join ','
        $parList = ($grp.Group | ForEach-Object {
                $p = if ($_.Contains('/')) { $_.Substring(0, $_.LastIndexOf('/')) } else { '' }
                "'" + (ConvertTo-ApexString $p) + "'"
            }) -join ','
        $nameList = ($grp.Group | ForEach-Object {
                $n = if ($_.Contains('/')) { $_.Substring($_.LastIndexOf('/') + 1) } else { $_ }
                "'" + (ConvertTo-ApexString $n) + "'"
            }) -join ','

        [void]$sb.AppendLine(@"
{
    List<String> full = new List<String>{$fullList};
    List<String> par  = new List<String>{$parList};
    List<String> nm   = new List<String>{$nameList};
    Set<Id> pids = new Set<Id>();
    for (String p : par) { pids.add(m.get(p)); }
    Map<String, Id> ex = new Map<String, Id>();
    for (ContentFolder cf : [SELECT Id, Name, ParentContentFolderId FROM ContentFolder WHERE ParentContentFolderId IN :pids]) {
        ex.put(String.valueOf(cf.ParentContentFolderId) + ':' + cf.Name, cf.Id);
    }
    List<ContentFolder> ins = new List<ContentFolder>();
    List<Integer> idx = new List<Integer>();
    for (Integer i = 0; i < full.size(); i++) {
        Id pid = m.get(par[i]);
        Id hit = ex.get(String.valueOf(pid) + ':' + nm[i]);
        if (hit != null) {
            m.put(full[i], hit);
        } else {
            ins.add(new ContentFolder(Name = nm[i], ParentContentFolderId = pid));
            idx.add(i);
        }
    }
    if (!ins.isEmpty()) {
        insert ins;
        for (Integer j = 0; j < ins.size(); j++) { m.put(full[idx[j]], ins[j].Id); }
    }
}
"@)
    }

    [void]$sb.AppendLine("System.debug('SFMIG|FOLDERS_DONE|' + m.size());")

    [void](Invoke-AnonymousApex -Code $sb.ToString() -Label '02-create-folders' -Org $TargetOrg -ApexDir $apexDir)

    # 作成したフォルダの ID は SOQL で取り直す。デバッグログから拾わない理由は
    # Get-FolderPathMap のコメントを参照。
    # SOQL はライブラリ全体を見るため、今回の対象外のフォルダも含まれうる。両方を出す。
    $folderPathToId = Get-FolderPathMap -RootId $rootFolderId -MaxDepth $maxDepth -Org $TargetOrg
    $resolved = @($folders | Where-Object { $folderPathToId.ContainsKey($_) }).Count
    Write-Host "  今回の対象フォルダ: $resolved / $($folders.Count) を解決 (ライブラリ全体では $($folderPathToId.Count - 1) 件)"

    $missing = @($folders | Where-Object { -not $folderPathToId.ContainsKey($_) })
    if ($missing.Count -gt 0) {
        $sample = ($missing | Select-Object -First 10) -join ', '
        throw "フォルダ ID を解決できませんでした ($($missing.Count) 件)。Salesforce 側でフォルダ名が変換された可能性があります。例: $sample"
    }
} else {
    Write-Host '  サブフォルダなし'
}

#endregion

#region Phase 2.5 : 既存ファイルの棚卸し

Write-Phase 'Phase 2.5: ライブラリ内の既存ファイルを確認'

# ContentVersion は insert するたびに新しい ContentDocument を作るため、
# 何もしなければ再実行のたびにファイルが重複する。
# アップロード前にライブラリ内を走査し、同じフォルダに同名のファイルがあれば飛ばす。
# キー "フォルダパス/ファイル名" -> 既存の ContentDocumentId。
# 再実行時も CSV に ID が載るよう、スキップするファイルの ID も拾っておく。
$existingDocs = @{}

if (-not $Force) {
    # フォルダ ID からパスを逆引きし、各フォルダ直下のファイルを SOQL で拾う。
    # ここも以前はデバッグログ経由だったが、件数と文字種に左右されない SOQL に変更した。
    $idToPath = @{}
    foreach ($k in $folderPathToId.Keys) { $idToPath[$folderPathToId[$k]] = $k }

    foreach ($chunk in (Split-Chunk -Items @($idToPath.Keys) -Size 200)) {
        $inList = ($chunk | ForEach-Object { "'$_'" }) -join ','
        $soql = "SELECT Id, Title, FileExtension, ParentContentFolderId FROM ContentFolderItem " +
                "WHERE ParentContentFolderId IN ($inList) AND IsFolder = false"
        foreach ($r in (Invoke-SfQuery -Soql $soql -Org $TargetOrg)) {
            $path = $idToPath[$r.ParentContentFolderId]
            $ext  = if ($r.FileExtension) { '.' + $r.FileExtension } else { '' }
            $existingDocs["$path/$($r.Title)$ext"] = $r.Id
        }
    }
    Write-Host "  既存ファイル: $($existingDocs.Count) 件"
} else {
    Write-Host '  -Force 指定のため既存チェックを省略（同名ファイルが重複します）' -ForegroundColor Yellow
}

$skipExisting = @($uploadable | Where-Object { $existingDocs.ContainsKey("$($_.FolderPath)/$($_.Name)") })
$uploadable   = @($uploadable | Where-Object { -not $existingDocs.ContainsKey("$($_.FolderPath)/$($_.Name)") })
if ($skipExisting.Count -gt 0) {
    Write-Host "  既にライブラリにあるためスキップ: $($skipExisting.Count) 件"
}

#endregion

#region Phase 3 : ファイルアップロード

Write-Phase 'Phase 3: ファイルをアップロード'

# 匿名 Apex はローカルファイルを読めないため、ここだけ REST API を直接使う。
# FirstPublishLocationId にライブラリ ID を渡すとライブラリ直下へ配置される。
$uploadUrl = "$($conn.InstanceUrl)/services/data/v$($conn.ApiVersion)/sobjects/ContentVersion"
$headers   = @{ Authorization = "Bearer $($conn.AccessToken)" }

$results = @()
$n = 0
foreach ($f in $uploadable) {
    $n++
    Write-Progress -Activity 'アップロード中' -Status "$n / $($uploadable.Count)  $($f.RelPath)" -PercentComplete ([int](100 * $n / [math]::Max($uploadable.Count, 1)))
    $status = 'Uploaded'
    $versionId = ''
    $errMsg = ''
    try {
        $bytes = [System.IO.File]::ReadAllBytes($f.FullPath)
        $body = @{
            Title                  = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
            PathOnClient           = $f.Name
            VersionData            = [Convert]::ToBase64String($bytes)
            FirstPublishLocationId = $workspaceId
        } | ConvertTo-Json -Compress
        # 5.1 の Invoke-RestMethod は文字列 Body を UTF-8 として送らないため、
        # 日本語のファイル名が化ける。バイト列に変換して渡す。
        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        $resp = Invoke-RestMethod -Method Post -Uri $uploadUrl -Headers $headers -ContentType 'application/json; charset=UTF-8' -Body $bodyBytes
        $versionId = $resp.id
    } catch {
        $status = 'Failed'
        $errMsg = $_.Exception.Message
        Write-Host "  失敗: $($f.RelPath) - $errMsg" -ForegroundColor Red
    }
    $results += [pscustomobject]@{
        FolderPath        = $f.FolderPath
        FileName          = $f.Name
        RelPath           = $f.RelPath
        SizeBytes         = $f.SizeBytes
        ContentVersionId  = $versionId
        ContentDocumentId = ''
        FolderId          = $(if ($folderPathToId.ContainsKey($f.FolderPath)) { $folderPathToId[$f.FolderPath] } else { '' })
        Status            = $status
        Error             = $errMsg
    }
}
Write-Progress -Activity 'アップロード中' -Completed

# アップロードしなかったファイルも CSV には残す。移行元との突合ができなくなるため。
foreach ($item in @(
        @{ Files = $oversize;     Status = 'Skipped';        Reason = "サイズが上限 $MaxFileSizeMB MB を超過" },
        @{ Files = $skipExisting; Status = 'AlreadyExists';  Reason = 'ライブラリに同名ファイルが既に存在' }
    )) {
    foreach ($f in $item.Files) {
        $key = "$($f.FolderPath)/$($f.Name)"
        $results += [pscustomobject]@{
            FolderPath        = $f.FolderPath
            FileName          = $f.Name
            RelPath           = $f.RelPath
            SizeBytes         = $f.SizeBytes
            ContentVersionId  = ''
            ContentDocumentId = $(if ($existingDocs.ContainsKey($key)) { $existingDocs[$key] } else { '' })
            FolderId          = $(if ($folderPathToId.ContainsKey($f.FolderPath)) { $folderPathToId[$f.FolderPath] } else { '' })
            Status            = $item.Status
            Error             = $item.Reason
        }
    }
}

$ok     = @($results | Where-Object { $_.Status -eq 'Uploaded' })
$failed = @($results | Where-Object { $_.Status -eq 'Failed' })
Write-Host "  成功 $($ok.Count) / 失敗 $($failed.Count) / サイズ超過 $($oversize.Count) / 既存 $($skipExisting.Count)"

# ContentVersionId -> ContentDocumentId を解決
if ($ok.Count -gt 0) {
    for ($i = 0; $i -lt $ok.Count; $i += $QueryChunkSize) {
        $last  = [math]::Min($i + $QueryChunkSize - 1, $ok.Count - 1)
        $chunk = $ok[$i..$last]
        $ids   = ($chunk | ForEach-Object { "'$($_.ContentVersionId)'" }) -join ','
        foreach ($rec in (Invoke-SfQuery -Soql "SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id IN ($ids)" -Org $TargetOrg)) {
            foreach ($row in ($results | Where-Object { $_.ContentVersionId -eq $rec.Id })) {
                $row.ContentDocumentId = $rec.ContentDocumentId
            }
        }
    }
}

#endregion

#region Phase 4 : フォルダへ配置

Write-Phase 'Phase 4: ファイルを対応フォルダへ配置'

# ライブラリ直下に入ったファイルを、ContentFolderMember の親を差し替えて移動する。
$toMove = @($results | Where-Object {
        $_.Status -eq 'Uploaded' -and $_.ContentDocumentId -and $_.FolderId -and $_.FolderId -ne $rootFolderId
    })

if ($toMove.Count -gt 0) {
    $moved = 0
    for ($i = 0; $i -lt $toMove.Count; $i += $MoveChunkSize) {
        $last  = [math]::Min($i + $MoveChunkSize - 1, $toMove.Count - 1)
        $chunk = $toMove[$i..$last]
        $pairs = ($chunk | ForEach-Object { "'$($_.ContentDocumentId)' => '$($_.FolderId)'" }) -join ', '
        $apex = @"
Map<Id, Id> target = new Map<Id, Id>{ $pairs };
List<ContentFolderMember> upd = new List<ContentFolderMember>();
for (ContentFolderMember cm : [
        SELECT Id, ChildRecordId, ParentContentFolderId
        FROM ContentFolderMember WHERE ChildRecordId IN :target.keySet()]) {
    Id tgt = target.get(cm.ChildRecordId);
    if (tgt != null && cm.ParentContentFolderId != tgt) {
        cm.ParentContentFolderId = tgt;
        upd.add(cm);
    }
}
if (!upd.isEmpty()) { update upd; }
System.debug('SFMIG|MOVED|' + upd.size());
"@
        $logs = Invoke-AnonymousApex -Code $apex -Label ('04-move-{0:d4}' -f $i) -Org $TargetOrg -ApexDir $apexDir
        $m = @(Get-ApexMarker -Logs $logs -Kind 'MOVED')
        if ($m.Count -gt 0) { $moved += [int]$m[0] }
    }
    Write-Host "  移動したファイル: $moved / $($toMove.Count)"
} else {
    Write-Host '  移動対象なし (すべてルート直下)'
}

#endregion

#region Phase 5 : CSV 出力

Write-Phase 'Phase 5: 結果を CSV に出力'

$stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$csvPath = Join-Path $OutDir "$developerName-$stamp.csv"
# Export-Csv -Encoding UTF8 も 5.1 と 7 で BOM の有無が割れる。
# CSV は Excel で開かれる前提なので、日本語が化けないよう BOM 付きで統一する。
$csvText = $results |
    Select-Object @{ n = 'LibraryName'; e = { $LibraryName } },
                  FolderPath, FileName, RelPath, SizeBytes,
                  ContentDocumentId, ContentVersionId, FolderId, Status, Error |
    Sort-Object FolderPath, FileName |
    ConvertTo-Csv -NoTypeInformation
[System.IO.File]::WriteAllLines($csvPath, [string[]]$csvText, (New-Object System.Text.UTF8Encoding $true))

Write-Host "  出力: $csvPath"
Write-Host ''
Write-Host "完了。ライブラリ: $($conn.InstanceUrl)/lightning/r/ContentWorkspace/$workspaceId/view" -ForegroundColor Green

#endregion
