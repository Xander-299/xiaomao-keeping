#Requires -Version 5.1
<#
.SYNOPSIS
  一条命令：出包 → 核验 → 装到设备（模拟器 / 真机）→ 启动。

.DESCRIPTION
  把 2026-10-29 手工走查的那串命令固化下来（MuMu 实测过）。做四件事：

  1. 临时改 `android/gradle.properties`（内存 8G→3G、可选的并列包名 qaAppId），
     **无论成败都按字节还原**，并校验还原结果与备份一致；
  2. `flutter build apk --{debug|release} --no-pub`（`--no-pub` 防止隐式 pub get 改掉 pubspec.lock）；
  3. 核验：APK 是不是这次构建的、包名/版本码对不对、release 还要比签名指纹、
     `-Grep` 给了文案时在 kernel 里 grep（仅 debug，release 是 AOT 没法 grep）；
  4. `adb install -r`（debug 自动加 `-t`；撞 VERSION_DOWNGRADE 自动补 `-d` 重试），
     然后 force-stop + monkey 拉起，避开「装完手势不生效」。

.PARAMETER Serial
  `adb devices` 里的设备序列号。模拟器 `127.0.0.1:16384`；真机形如 `22041211AC`。

.PARAMETER Mode
  `debug`（默认，模拟器必须用它：release 只打 ARM）或 `release`（真机正式包）。

.PARAMETER Qa
  用并列包名 `com.teacodeman.yanxin.qa`，不动用户的正式包（**真机走查请始终带上**）。
  注意：只能写进 gradle.properties，环境变量 `ORG_GRADLE_PROJECT_qaAppId` 实测不生效。

.PARAMETER Arm64Only
  release 时只打 `arm64-v8a`（只给一台真机装，包小一半）。

.PARAMETER Grep
  本批新增的独有文案，装机前在 kernel 里核验（可给多个）。不传则跳过这一步。

.PARAMETER NoBuild
  不构建，直接装 `build/app/outputs/flutter-apk/` 里最新的 APK。

.PARAMETER SkipVerify
  跳过签名 / 文案核验（只在你自己已经核过时用）。

.PARAMETER Smoke
  装完启动后做一次冒烟：清空 logcat → 拉起 App → 抓 `logcat -s flutter` 与 crash 缓冲，
  出现 `MissingPluginException` / Dart 未捕获异常 / FATAL 直接判失败。
  2026-11-09 v0.8.3 首包就是「装得上、签名对、但插件没注册 → 全站白屏」，
  发布前请带上这个开关。

.EXAMPLE
  # 模拟器日常走查（debug + 并列包名）
  .\tool\install_device.ps1

.EXAMPLE
  # 真机走查
  .\tool\install_device.ps1 -Serial 22041211AC -Qa -Grep 图标与颜色

.EXAMPLE
  # 真机正式包（需要 android/key.properties，否则 release 会退化成 debug 签名）
  .\tool\install_device.ps1 -Serial 22041211AC -Mode release -Arm64Only

.NOTES
  - 本机只有 Windows PowerShell 5.1：本文件必须存成 **UTF-8 with BOM**（否则中文注释会被当 ANSI 解析报语法错）。
  - 不要给本脚本设 `$ErrorActionPreference='Stop'`：adb / gradle 的正常 stderr 会被 PowerShell
    当异常抛出（`NativeCommandError`），导致「构建其实成功了却报失败」。
  - 不要自动 uninstall：卸载会清掉本地账本，宁可失败让人来看。
#>
param(
  [string]$Serial = '127.0.0.1:16384',
  [ValidateSet('debug', 'release')]
  [string]$Mode = 'debug',
  [switch]$Qa,
  [switch]$Arm64Only,
  [string[]]$Grep = @(),
  [switch]$NoBuild,
  [switch]$SkipVerify,
  [switch]$NoLaunch,
  [switch]$Smoke,
  [string]$Adb = 'D:\Download\Java\Android\platform-tools\adb.exe',
  [string]$Flutter = 'D:\Download\Flutter\flutter\bin\flutter.bat',
  [string]$BuildTools = 'D:\Download\Java\Android\build-tools\36.0.0',
  [string]$ExpectedCertSha256 = 'd46b65a43bcfc6633f5460fb893b6b6e55db66ae16ac650054fb085698e86567'
)

$ErrorActionPreference = 'Continue'
$Repo = Split-Path -Parent $PSScriptRoot
$QaPackage = 'com.teacodeman.yanxin.qa'
$MainPackage = 'com.teacodeman.yanxin'
$GradleProps = Join-Path $Repo 'android\gradle.properties'
$ApkDir = Join-Path $Repo 'build\app\outputs\flutter-apk'

function Write-Step([string]$Msg) {
  Write-Host ''
  Write-Host "==> $Msg" -ForegroundColor Cyan
}
function Write-Ok([string]$Msg) {
  Write-Host "    [OK] $Msg" -ForegroundColor Green
}
function Write-Note([string]$Msg) {
  Write-Host "    [!]  $Msg" -ForegroundColor Yellow
}
function Fail([string]$Msg) {
  Write-Host ''
  Write-Host "[FAIL] $Msg" -ForegroundColor Red
  exit 1
}

# ─────────────────────────── 0. 前置检查 ───────────────────────────
Write-Step "前置检查"
foreach ($exe in @($Adb, $Flutter)) {
  if (-not (Test-Path $exe)) { Fail "找不到可执行文件：$exe" }
}
Write-Ok "adb / flutter 就位"

# 设备和 adb 的连接常常被上一次 shell 回收，先起服务再连（首条命令撞 device offline 是常态）
& $Adb start-server 2>&1 | Out-Null
if ($Serial -match '^\d+\.\d+\.\d+\.\d+:\d+$') {
  & $Adb connect $Serial 2>&1 | Out-Null
  Start-Sleep -Seconds 1
}
$devices = (& $Adb devices 2>&1 | Out-String)
if ($devices -notmatch ([regex]::Escape($Serial) + '\s+device')) {
  Fail "设备 $Serial 不在线。`n当前设备列表：`n$devices`n真机请先开「USB 调试」+「USB 调试（安全设置）」。"
}
Write-Ok "设备在线：$Serial"

$freeMb = [int]((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1024)
Write-Host ("    空闲内存：{0} MB" -f $freeMb)

# ─────────────────────────── 1. 出包 ───────────────────────────
$apk = $null
if (-not $NoBuild) {
  Write-Step "构建 $Mode 包"
  # 本机默认 JAVA_HOME 是 JDK 25；这个 Android 工程按 HANDOFF 用 JDK 17 构建。
  # 只改本次进程，构建完还原。
  $jdk = 'D:\Download\Java\jdk-17.0.20.1+1'
  $oldJavaHome = $env:JAVA_HOME
  if (Test-Path (Join-Path $jdk 'bin\java.exe')) {
    $env:JAVA_HOME = $jdk
    Write-Note "构建 JDK：$jdk（不是系统默认的 $oldJavaHome）"
  } else {
    Write-Note "没找到 JDK 17（$jdk），沿用系统 JAVA_HOME=$oldJavaHome"
  }
  $origBytes = [IO.File]::ReadAllBytes($GradleProps)
  $patched = $false
  try {
    $text = [IO.File]::ReadAllText($GradleProps)
    $new = $text

    if ($freeMb -lt 4096 -and $new -match 'Xmx8G') {
      $new = $new.Replace('-Xmx8G -XX:MaxMetaspaceSize=4G', '-Xmx3G -XX:MaxMetaspaceSize=1G')
      Write-Note "内存余量不足 4G：Gradle 堆临时降到 3G（构建后还原）"
    }
    if ($Qa -and ($new -notmatch '(?m)^qaAppId=')) {
      $new = $new.TrimEnd() + "`nqaAppId=$QaPackage`n"
      Write-Note "并列包名：$QaPackage（构建后还原）"
    }
    if ($new -ne $text) {
      $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
      [IO.File]::WriteAllText($GradleProps, $new, $utf8NoBom)
      $patched = $true
    }

    $buildArgs = @('build', 'apk', "--$Mode", '--no-pub')
    if ($Mode -eq 'release' -and $Arm64Only) { $buildArgs += @('--target-platform', 'android-arm64') }
    Write-Host ("    flutter " + ($buildArgs -join ' ')) -ForegroundColor DarkGray
    & $Flutter @buildArgs 2>&1 | ForEach-Object {
      $line = "$_"
      # 原生进程的 stderr 会被 PowerShell 包成 ErrorRecord，个别记录 ToString() 只剩类型名 → 丢掉
      if ($line -and $line -ne 'System.Management.Automation.RemoteException') {
        Write-Host "    $line"
      }
    }
    # flutter 把进度写到 stderr，PowerShell 会包成 ErrorRecord；构建成败以「APK 是否更新」为准
  }
  finally {
    if ($patched) {
      [IO.File]::WriteAllBytes($GradleProps, $origBytes)
      $nowBytes = [IO.File]::ReadAllBytes($GradleProps)
      $same = [Convert]::ToBase64String($nowBytes) -eq [Convert]::ToBase64String($origBytes)
      if ($same) {
        Write-Ok 'android/gradle.properties 已按字节还原'
      }
      else {
        Write-Note 'android/gradle.properties 还原后与备份不一致！请立刻 `git checkout -- android/gradle.properties`'
      }
    }
    $env:JAVA_HOME = $oldJavaHome
  }

  if (-not (Test-Path $ApkDir)) { Fail "构建产物目录不存在：$ApkDir" }
  $apk = Get-ChildItem $ApkDir -Filter '*.apk' |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
  if (-not $apk) { Fail '没找到 APK —— 构建八成失败了，往上翻 flutter 的输出' }
  if ((Get-Date) - $apk.LastWriteTime -gt [TimeSpan]::FromMinutes(10)) {
    Write-Note ("最新 APK 是 {0:HH:mm:ss} 的，可能不是这次的产物" -f $apk.LastWriteTime)
  }
}
else {
  Write-Step '跳过构建，沿用现有 APK'
  $apk = Get-ChildItem $ApkDir -Filter '*.apk' |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
  if (-not $apk) { Fail "目录里没有 APK：$ApkDir" }
}
Write-Ok ("APK：{0}（{1:N1} MB，{2:HH:mm:ss}）" -f $apk.Name, ($apk.Length / 1MB), $apk.LastWriteTime)

# ─────────────────────────── 2. 核验 ───────────────────────────
Write-Step '核验包内容'
$aapt = Join-Path $BuildTools 'aapt.exe'
if (Test-Path $aapt) {
  $badging = (& $aapt dump badging $apk.FullName 2>&1 | Out-String)
  if ($badging -match "package: name='([^']+)' versionCode='(\d+)' versionName='([^']*)'") {
    $pkg = $Matches[1]
    $versionCode = $Matches[2]
    $versionName = $Matches[3]
    Write-Ok "包名 $pkg · versionCode $versionCode · versionName $versionName"
  }
  else {
    Fail "读不出 APK 的包名（aapt 输出被截断？）`n$badging"
  }
}
else {
  Write-Note "找不到 aapt（$aapt），跳过包名核验"
  $pkg = if ($Qa) { $QaPackage } else { $MainPackage }
}

$wantPkg = if ($Qa) { $QaPackage } else { $MainPackage }
if ($pkg -ne $wantPkg) {
  Fail ("包名是 $pkg，但期望 $wantPkg。`n" +
    "  · 这个 APK 本来就是并列包 → 带上 -Qa 再跑；`n" +
    "  · 你想要主包名 → qaAppId 没进构建（环境变量 ORG_GRADLE_PROJECT_qaAppId 实测无效，" +
    "必须写进 android/gradle.properties，本脚本已处理）；`n" +
    "  · 装错包名会去顶正式包 —— 先别继续。")
}

if ($Mode -eq 'release' -and -not (Test-Path (Join-Path $Repo 'android\key.properties'))) {
  Write-Note '没有 android/key.properties → release 会退化成 debug 签名，装不上用户的正式包（只能并列装）'
}

if (-not $SkipVerify) {
  if ($Mode -eq 'release' -and (Test-Path $aapt)) {
    $apksigner = Join-Path $BuildTools 'apksigner.bat'
    if (Test-Path $apksigner) {
      $certs = (& $apksigner verify --print-certs $apk.FullName 2>&1 | Out-String)
      if ($certs -match 'SHA-256 digest:\s*([0-9a-fA-F]+)') {
        $sha = $Matches[1].ToLower()
        if ($sha -eq $ExpectedCertSha256.ToLower()) {
          Write-Ok "签名指纹一致（upload key）"
        }
        else {
          Fail ("签名指纹不一致！`n  实际：$sha`n  期望：$($ExpectedCertSha256.ToLower())`n" +
            "覆盖安装会失败/丢账本，别装。要么补齐 android/key.properties，要么带 -Qa 并列装。")
        }
      }
      else {
        Write-Note '读不出签名指纹，跳过比对'
      }
    }
  }

  if ($Grep.Count -gt 0) {
    if ($Mode -eq 'debug') {
      $py = Join-Path $Repo 'tool\verify_apk_kernel.py'
      if (Test-Path $py) {
        # Python 往管道写 stdout 时用系统 locale（cp936），PowerShell 又按控制台编码解 → 中文全糊。
        # 两边都对齐到 UTF-8，才看得清「哪一条没绿」。
        $oldEnc = $null
        $oldPyIo = $env:PYTHONIOENCODING
        $oldPyUtf8 = $env:PYTHONUTF8
        try {
          $oldEnc = [Console]::OutputEncoding
          [Console]::OutputEncoding = [Text.Encoding]::UTF8
          $env:PYTHONIOENCODING = 'utf-8'
          $env:PYTHONUTF8 = '1'
          $out = (& python $py @Grep 2>&1 | Out-String)
        }
        finally {
          if ($oldEnc) { try { [Console]::OutputEncoding = $oldEnc } catch { } }
          $env:PYTHONIOENCODING = $oldPyIo
          $env:PYTHONUTF8 = $oldPyUtf8
        }
        Write-Host $out
        if ($out -notmatch 'grep.*-> True|新鲜度: OK') {
          Write-Note 'kernel 核验没全绿，仔细看上面输出（尤其「装到旧包」那条）'
        }
      }
      else {
        Write-Note '找不到 tool\verify_apk_kernel.py，跳过文案核验'
      }
    }
    else {
      Write-Note 'release 是 AOT（libapp.so），grep kernel 的办法不适用；本次跳过文案核验'
    }
  }
}

# ─────────────────────────── 3. 装机 ───────────────────────────
Write-Step "安装到 $Serial"
$installArgs = @('-s', $Serial, 'install', '-r')
if ($Mode -eq 'debug') { $installArgs += '-t' }   # debug 包带 testOnly
$installArgs += $apk.FullName
$result = (& $Adb @installArgs 2>&1 | Out-String)
Write-Host "    $($result.Trim())"

if ($result -match 'VERSION_DOWNGRADE') {
  Write-Note '版本码比已装的小 → 加 -d 重试（不卸载，数据保留）'
  $installArgs = @('-s', $Serial, 'install', '-r', '-d')
  if ($Mode -eq 'debug') { $installArgs += '-t' }
  $installArgs += $apk.FullName
  $result = (& $Adb @installArgs 2>&1 | Out-String)
  Write-Host "    $($result.Trim())"
}
if ($result -notmatch 'Success') {
  if ($result -match 'signatures do not match') {
    Fail ("签名与已装包不一致。`n" +
      "  · 想并存：带 -Qa 重新出包（包名 $QaPackage，签名不同也没关系）；`n" +
      "  · 想覆盖：补齐 android/key.properties 用 upload key 重出 release；`n" +
      "  · 千万别直接 adb uninstall 正式包 —— 本地账本会一起没。")
  }
  Fail "安装失败：`n$result"
}
Write-Ok '安装成功'

# ─────────────────────────── 4. 启动 ───────────────────────────
if (-not $NoLaunch) {
  Write-Step "启动 $pkg"
  if ($Smoke) { & $Adb -s $Serial logcat -c 2>&1 | Out-Null }
  & $Adb -s $Serial shell am force-stop $pkg 2>&1 | Out-Null
  Start-Sleep -Milliseconds 500
  & $Adb -s $Serial shell monkey -p $pkg -c android.intent.category.LAUNCHER 1 2>&1 | Out-Null
  Start-Sleep -Seconds 2
  $top = (& $Adb -s $Serial shell dumpsys activity activities 2>&1 | Out-String)
  if ($top -match [regex]::Escape($pkg)) {
    Write-Ok "已在设备前台：$pkg"
  }
  else {
    Write-Note "没确认到前台 Activity，手动点一下图标看看（logcat：adb -s $Serial logcat -d -t 200）"
  }

  if ($Smoke) {
    Write-Step '启动冒烟（插件 / 崩溃）'
    Start-Sleep -Seconds 3
    $flutterLog = (& $Adb -s $Serial logcat -d -s flutter 2>&1 | Out-String)
    $crashLog = (& $Adb -s $Serial logcat -b crash -d -t 200 2>&1 | Out-String)
    $problems = @()
    if ($flutterLog -match 'MissingPluginException') {
      $problems += 'MissingPluginException —— 插件没注册（多半是构建时缺 .flutter-plugins-dependencies，先跑 flutter pub get 再出包）'
    }
    if ($flutterLog -match 'E/flutter|Unhandled Exception') {
      $problems += 'Dart 未捕获异常（见 adb logcat -s flutter）'
    }
    if ($crashLog -match 'FATAL EXCEPTION') {
      $problems += 'crash 缓冲有 FATAL EXCEPTION（见 adb logcat -b crash）'
    }
    if ($problems.Count -gt 0) {
      $tail = ($flutterLog -split "`r?`n" | Select-Object -Last 15) -join "`n"
      Fail ("启动冒烟失败：`n  - " + ($problems -join "`n  - ") + "`n最近 flutter 日志：`n$tail")
    }
    Write-Ok '启动冒烟通过：无插件缺失 / 无未捕获异常 / 无 FATAL'
  }
}

Write-Step '完成'
Write-Host "    走查取语义树： .\tool\ui_mumu.ps1 -Action dump -Serial $Serial -Out `$env:TEMP\ui.txt"
Write-Host "    截图（别用 > 重定向）： adb -s $Serial shell screencap -p /sdcard/s.png ; adb -s $Serial pull /sdcard/s.png shots\x.png"
