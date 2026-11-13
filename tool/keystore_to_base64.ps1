<#
.SYNOPSIS
  把正式签名 keystore 转成 base64，粘进 GitHub Actions 的 secret 里。

.DESCRIPTION
  CD（.github/workflows/release.yml）需要三个 secret：
    ANDROID_KEYSTORE_BASE64    ← 本脚本输出
    ANDROID_KEYSTORE_PASSWORD  ← 本地 android/key.properties 的 storePassword
    ANDROID_KEY_PASSWORD       ← 同一个文件里的 keyPassword
    ANDROID_KEY_ALIAS          ← 同一个文件里的 keyAlias（本仓库是 upload）

  ⚠️ 输出的是**私钥的 base64**：等于签名凭据本身。
     - 只粘到 GitHub 的 secret 输入框里，别写进任何文件、别贴聊天；
     - 命令行里也别用 `> out.txt` 落到磁盘（本脚本默认只打印到终端，且提示剪贴板）。

.PARAMETER Path
  keystore 路径（.jks / .keystore），默认读 android/key.properties 里的 storeFile。

.PARAMETER Copy
  转完直接放进剪贴板（Windows），省得手动选中。

.EXAMPLE
  .\tool\keystore_to_base64.ps1 -Copy
#>
param(
  [string]$Path,
  [switch]$Copy
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent

if (-not $Path) {
  $props = Join-Path $repo 'android\key.properties'
  if (-not (Test-Path $props)) { throw "找不到 $props —— 先确认本机有正式签名配置" }
  $line = (Get-Content $props | Where-Object { $_ -match '^\s*storeFile\s*=' } | Select-Object -First 1)
  if (-not $line) { throw 'android/key.properties 里没有 storeFile' }
  $Path = ($line -split '=', 2)[1].Trim().Replace('\\', '\')
}

if (-not (Test-Path $Path)) { throw "keystore 不存在：$Path" }

$bytes = [IO.File]::ReadAllBytes($Path)
$b64 = [Convert]::ToBase64String($bytes)

Write-Host "keystore : $Path"
Write-Host ("大小     : {0:N0} B（base64 后 {1:N0} B）" -f $bytes.Length, $b64.Length)
Write-Host ''
Write-Host '把下面整段（单行、无换行）粘进 Settings → Secrets → ANDROID_KEYSTORE_BASE64：' -ForegroundColor Yellow
Write-Host ''

if ($Copy) {
  Set-Clipboard -Value $b64
  Write-Host '（已复制到剪贴板，为避免终端历史泄露这里不打印内容）' -ForegroundColor Green
} else {
  Write-Host $b64
}
