<#
.SYNOPSIS
    Import-FolderToLibrary.ps1 の Phase 3 と同等の REST 呼び出しを、curl と PowerShell の
    両方で試して比較する診断スクリプト。

.DESCRIPTION
    Phase 3 だけが失敗する場合に、原因が「トークン」「ホスト」「HTTP クライアント」の
    どれにあるのかを切り分ける。

    既定ではデータを一切作らない。ContentVersion への POST は必須項目を欠いた本文
    （`{}`）を送るため、認証が通っていれば REQUIRED_FIELD_MISSING で弾かれるだけで
    レコードは作成されない。実アップロードを試す場合のみ -UploadFile を指定する。

    curl と PowerShell で結果が食い違えば、原因は HTTP クライアント側にある。
    たとえば PowerShell だけ INVALID_AUTH_HEADER になるなら、送っている
    Authorization ヘッダーが壊れているということ。

    アクセストークンは画面に出さない。curl へはコマンドラインではなく設定ファイル経由で
    渡すため、プロセス一覧にも残らない。

.PARAMETER TargetOrg
    接続先組織のエイリアス。省略時は sf の既定接続先。

.PARAMETER LibraryId
    ContentWorkspace の ID。-UploadFile と併用する場合のみ必要。

.PARAMETER UploadFile
    実際にアップロードを試すファイル。**指定するとレコードが作成される。**
    切り分けの最後の手段として使う。

.EXAMPLE
    ./Test-RestUpload.ps1 -TargetOrg mysandbox

.EXAMPLE
    ./Test-RestUpload.ps1 -TargetOrg mysandbox -LibraryId 058xxxxxxxxxxxxxxx -UploadFile .\test.txt
#>
[CmdletBinding()]
param(
    [string] $TargetOrg,
    [string] $LibraryId,
    [string] $UploadFile
)

$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 6) {
    [System.Net.ServicePointManager]::SecurityProtocol =
        [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
}

function Write-Section { param([string]$T) Write-Host ''; Write-Host "== $T" -ForegroundColor Cyan }

function Get-RestErrorDetail {
    # 応答本文には errorCode が入っている。取得経路が 5.1 と 7 で異なるため両方試す。
    param($ErrorRecord)
    $status = $null
    try { $status = $ErrorRecord.Exception.Response.StatusCode.value__ } catch { }
    $body = ''
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        $body = $ErrorRecord.ErrorDetails.Message
    } else {
        try {
            $reader = New-Object System.IO.StreamReader($ErrorRecord.Exception.Response.GetResponseStream())
            $body = $reader.ReadToEnd()
            $reader.Dispose()
        } catch { $body = '' }
    }
    $body = ($body -replace '\s+', ' ').Trim()
    if ($status -and $body) { return "HTTP $status $body" }
    if ($status) { return "HTTP $status $($ErrorRecord.Exception.Message)" }
    return $ErrorRecord.Exception.Message
}

#region トークン取得

Write-Section 'トークンを取得'

$sfArgs = @('org', 'display', '--json')
if ($TargetOrg) { $sfArgs += @('--target-org', $TargetOrg) }

# sf 呼び出しには 5.1 特有の落とし穴が 2 つある。
#   - ErrorActionPreference='Stop' だと、標準エラーに何か出ただけで NativeCommandError になる。
#     sf は更新通知を標準エラーに出すため、正常終了でも落ちる。
#   - 出力は UTF-8 だが、PowerShell はコンソールのコードページ（日本語版は CP932）で復号する。
$prevEnc  = $null
$prevPref = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    try { $prevEnc = [Console]::OutputEncoding; [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { $prevEnc = $null }
    $raw = (& sf @sfArgs 2>$null) -join ([string][char]10)
} finally {
    if ($null -ne $prevEnc) { try { [Console]::OutputEncoding = $prevEnc } catch { } }
    $ErrorActionPreference = $prevPref
}

$i = $raw.IndexOf('{')
if ($i -lt 0) { throw "sf org display の応答に JSON が含まれていません。" }
$j = $raw.Substring($i) | ConvertFrom-Json
if ($j.status -ne 0) { throw "sf org display が失敗しました (status=$($j.status))。" }

$tok  = $j.result.accessToken
$inst = $j.result.instanceUrl.TrimEnd('/')
$ver  = $j.result.apiVersion
Write-Host "  username    : $($j.result.username)"
Write-Host "  instanceUrl : $inst"
Write-Host "  apiVersion  : $ver"

#endregion

#region トークンの健全性

Write-Section 'アクセストークンの健全性を確認'

# INVALID_AUTH_HEADER は「ヘッダーが壊れている」という意味なので、まずここを疑う。
# HTTP ヘッダーに載せられるのは可視 ASCII (0x21-0x7E) のみ。
$masked = if ($tok.Length -gt 12) { $tok.Substring(0, 8) + '…' + $tok.Substring($tok.Length - 4) } else { '(短すぎ)' }
Write-Host "  マスク表示  : $masked"
Write-Host "  長さ        : $($tok.Length)"

$bad = @()
for ($k = 0; $k -lt $tok.Length; $k++) {
    $c = [int][char]$tok[$k]
    if ($c -lt 0x21 -or $c -gt 0x7E) {
        $bad += ('位置{0}: U+{1:X4}' -f $k, $c)
    }
}
if ($bad.Count -gt 0) {
    Write-Host "  不正な文字  : $($bad.Count) 個 → $($bad -join ', ')" -ForegroundColor Red
    Write-Host '  ★ これが INVALID_AUTH_HEADER の原因です。トークンに空白や制御文字が混入しています。' -ForegroundColor Red
} else {
    Write-Host '  不正な文字  : なし（可視 ASCII のみ）' -ForegroundColor Green
}
Write-Host "  先頭が 00D  : $($tok.StartsWith('00D'))"
Write-Host "  ! を含む    : $($tok.Contains('!'))"

$headerValue = "Bearer $tok"
Write-Host "  ヘッダー長  : $($headerValue.Length)"

#endregion

#region curl の有無

$curl = (Get-Command curl.exe -ErrorAction SilentlyContinue)
if (-not $curl) {
    Write-Host ''
    Write-Host 'curl.exe が見つかりません。PowerShell 側の結果のみ表示します。' -ForegroundColor Yellow
}

function Invoke-CurlProbe {
    # curl にトークンを渡す。コマンドラインに載せるとプロセス一覧から見えるため設定ファイル経由。
    param([string]$Url, [string]$Method = 'GET', [string]$Data, [string]$ContentType)
    if (-not $curl) { return $null }
    $cfg  = [System.IO.Path]::GetTempFileName()
    $out  = [System.IO.Path]::GetTempFileName()
    try {
        # 各要素は必ず括弧で囲う。PowerShell はカンマ演算子を + より優先して解釈するため、
        # 括弧がないと 2 要素の配列ではなく 1 本の文字列に連結されてしまい、
        # curl が Authorization ヘッダーを受け取れなくなる。
        $lines = @(
            ('url = "' + $Url + '"'),
            ('header = "Authorization: ' + $headerValue + '"')
        )
        if ($Method -ne 'GET') { $lines += 'request = "' + $Method + '"' }
        if ($ContentType)      { $lines += 'header = "Content-Type: ' + $ContentType + '"' }
        if ($PSBoundParameters.ContainsKey('Data')) { $lines += 'data = "' + $Data.Replace('"', '\"') + '"' }

        # 改行は必ず LF にする。CRLF だと curl が行末の CR をヘッダー値に含めてしまい、
        # Authorization が壊れて 401 になる（実測済み）。
        # WriteAllLines は Windows では CRLF を書くため使わない。
        $lf = [string][char]10
        [System.IO.File]::WriteAllText($cfg, ([string]::Join($lf, $lines) + $lf), (New-Object System.Text.UTF8Encoding $false))

        $code = & curl.exe --silent --show-error --config $cfg --output $out --write-out '%{http_code}'
        $body = ''
        if (Test-Path -LiteralPath $out) { $body = (Get-Content -LiteralPath $out -Raw -ErrorAction SilentlyContinue) }
        return [pscustomobject]@{ Status = $code; Body = (($body -replace '\s+', ' ').Trim()) }
    } finally {
        foreach ($f in @($cfg, $out)) {
            if ($f -and (Test-Path -LiteralPath $f)) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
        }
    }
}

function Show-Result {
    param([string]$Label, [string]$Status, [string]$Body)
    $color = if ($Status -match '^2') { 'Green' } else { 'Yellow' }
    Write-Host "  $Label : $Status" -ForegroundColor $color
    if ($Body) {
        $short = if ($Body.Length -gt 300) { $Body.Substring(0, 300) + '…' } else { $Body }
        Write-Host "    $short"
    }
}

#endregion

#region 1. ホスト到達性（認証なし）

Write-Section '1. ホストへの到達性（認証不要のエンドポイント）'
try {
    $vs = Invoke-RestMethod -Uri "$inst/services/data/" -Method Get
    $avail = ($vs | Select-Object -Last 3 | ForEach-Object { $_.version }) -join ', '
    Write-Host "  OK  この org が提供する API バージョン(末尾3件): $avail" -ForegroundColor Green
    $latest = ($vs | Select-Object -Last 1).version
    if ($latest -and $latest -ne $ver) {
        Write-Host "  注意: sf は $ver と報告していますが、org の最新は $latest です" -ForegroundColor Yellow
    }
} catch {
    Write-Host "  NG  $(Get-RestErrorDetail $_)" -ForegroundColor Red
    Write-Host '  → instanceUrl が誤っているか、ネットワークで到達できません。' -ForegroundColor Red
}

#endregion

#region 2. GET /limits（認証あり）

Write-Section '2. GET /limits — トークンが有効かどうか'
$url = "$inst/services/data/v$ver/limits"

try {
    $null = Invoke-RestMethod -Uri $url -Headers @{ Authorization = $headerValue } -Method Get
    Show-Result 'PowerShell' '200' ''
} catch {
    Show-Result 'PowerShell' 'ERROR' (Get-RestErrorDetail $_)
}
$r = Invoke-CurlProbe -Url $url
if ($r) { Show-Result 'curl      ' $r.Status $r.Body }

# Salesforce は Bearer と OAuth のどちらの接頭辞も受け付ける。
# INVALID_AUTH_HEADER が出る場合の比較材料として両方試す。
try {
    $null = Invoke-RestMethod -Uri $url -Headers @{ Authorization = "OAuth $tok" } -Method Get
    Show-Result 'PS (OAuth)' '200' ''
} catch {
    Show-Result 'PS (OAuth)' 'ERROR' (Get-RestErrorDetail $_)
}

#endregion

#region 3. POST /sobjects/ContentVersion（空ボディ・レコードは作られない）

Write-Section '3. POST /sobjects/ContentVersion — 空ボディ（レコードは作成されません）'
$postUrl = "$inst/services/data/v$ver/sobjects/ContentVersion"

try {
    $null = Invoke-RestMethod -Uri $postUrl -Headers @{ Authorization = $headerValue } -Method Post `
                              -ContentType 'application/json' -Body ([System.Text.Encoding]::UTF8.GetBytes('{}'))
    Show-Result 'PowerShell' '200(想定外)' ''
} catch {
    Show-Result 'PowerShell' 'ERROR' (Get-RestErrorDetail $_)
}
$r = Invoke-CurlProbe -Url $postUrl -Method 'POST' -Data '{}' -ContentType 'application/json'
if ($r) { Show-Result 'curl      ' $r.Status $r.Body }

#endregion

#region 4. 実アップロード（任意）

if ($UploadFile) {
    Write-Section '4. 実ファイルのアップロード（レコードが作成されます）'
    if (-not (Test-Path -LiteralPath $UploadFile -PathType Leaf)) { throw "ファイルが見つかりません: $UploadFile" }
    if (-not $LibraryId) { throw '-UploadFile を使う場合は -LibraryId も指定してください。' }

    $name  = [System.IO.Path]::GetFileName($UploadFile)
    $bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $UploadFile))
    $body  = @{
        Title                  = [System.IO.Path]::GetFileNameWithoutExtension($name)
        PathOnClient           = $name
        VersionData            = [Convert]::ToBase64String($bytes)
        FirstPublishLocationId = $LibraryId
    } | ConvertTo-Json -Compress

    Write-Host "  ファイル: $name  ($($bytes.Length) バイト / base64 $([int]($bytes.Length * 1.34)) バイト)"
    try {
        $resp = Invoke-RestMethod -Uri $postUrl -Headers @{ Authorization = $headerValue } -Method Post `
                                  -ContentType 'application/json; charset=UTF-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($body))
        Show-Result 'PowerShell' '201' "ContentVersionId=$($resp.id)"
    } catch {
        Show-Result 'PowerShell' 'ERROR' (Get-RestErrorDetail $_)
    }
}

#endregion

#region 判定の目安

Write-Section '判定の目安'
@'
  ・3 で REQUIRED_FIELD_MISSING (400) が返る
      → 認証は正常。原因はアップロード時のリクエスト内容側。

  ・curl は通るのに PowerShell だけ失敗する
      → HTTP クライアント側の問題。Authorization ヘッダーの送られ方が違う。

  ・INVALID_AUTH_HEADER が出た
      → セッション切れではなく、Authorization ヘッダーの形式が不正という意味。
        - 上の「不正な文字」に指摘があれば、それが原因。トークンに空白や制御文字が
          混入している。
        - curl だけ通るなら、PowerShell 側のヘッダーの送られ方の問題。
        - Bearer は駄目で OAuth は通る（またはその逆）なら、接頭辞の扱いの問題。
        - どれも該当せず両方失敗するなら、通信経路上でヘッダーを書き換えている
          機器（セキュリティ製品や TLS 検査プロキシ）を疑う。

  ・どちらも INVALID_SESSION_ID
      → セッションが無効。sf org login web で再認証する。
        それでも直らなければ、組織のセッション設定（発信元 IP への固定など）を確認する。
'@ | Write-Host

#endregion
