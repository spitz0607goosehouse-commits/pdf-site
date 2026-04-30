# pdf-auto-deploy.ps1
$PdfSourceDir = "$env:USERPROFILE\Dropbox\ナビオ\共有フォルダー（高3東大理系数学）"
$SiteRepoDir  = "$env:USERPROFILE\pdf-site"
$GsPath       = "C:\Program Files\gs\gs10.07.0\bin\gswin64c.exe"
$CompressThreshold = 5MB

$PdfsDir = "$SiteRepoDir\pdfs"
$LogFile = "$SiteRepoDir\deploy.log"

function Log($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "[$ts] $msg" | Tee-Object -Append $LogFile
}

function Get-HumanSize($bytes) {
    if ($bytes -ge 1MB) { return ("{0:N1} MB" -f ($bytes / 1MB)) }
    if ($bytes -ge 1KB) { return ("{0:N0} KB" -f ($bytes / 1KB)) }
    return "$bytes B"
}

function Compress-Pdf($src, $dst) {
    $origSize = (Get-Item $src).Length
    if ($origSize -lt $CompressThreshold) {
        Copy-Item $src $dst -Force
        Log "  コピー（圧縮スキップ）: $(Split-Path $src -Leaf)"
        return
    }
    & $GsPath -sDEVICE=pdfwrite -dCompatibilityLevel=1.4 -dPDFSETTINGS=/printer -dAutoRotatePages=/None -dEmbedAllFonts=true -dSubsetFonts=true -dNOPAUSE -dBATCH -dQUIET "-sOutputFile=$dst" $src 2>$null
    if ($LASTEXITCODE -eq 0 -and (Test-Path $dst)) {
        $newSize = (Get-Item $dst).Length
        if ($newSize -ge $origSize) {
            Copy-Item $src $dst -Force
            Log "  コピー（圧縮効果なし）: $(Split-Path $src -Leaf)"
        } else {
            $pct = [math]::Round($newSize * 100 / $origSize)
            Log "  圧縮: $(Split-Path $src -Leaf) $origSize -> $newSize bytes ($pct%)"
        }
    } else {
        Copy-Item $src $dst -Force
        Log "  圧縮失敗: $(Split-Path $src -Leaf)"
    }
}

function Generate-FileList {
    $now = Get-Date -Format "yyyy/MM/dd HH:mm"
    $files = @()
    Get-ChildItem $PdfsDir -Filter "*.pdf" -ErrorAction SilentlyContinue | ForEach-Object {
        $files += @{ name = $_.Name; size = (Get-HumanSize $_.Length); date = $_.LastWriteTime.ToString("yyyy/MM/dd HH:mm") }
    }
    @{ updated = $now; files = $files } | ConvertTo-Json -Depth 3 | Out-File -Encoding utf8 "$SiteRepoDir\filelist.json"
}

function Sync-And-Deploy {
    Log "変更を検出。同期を開始..."
    if (-not (Test-Path $PdfsDir)) { New-Item -ItemType Directory -Path $PdfsDir -Force | Out-Null }

    Get-ChildItem $PdfSourceDir -Filter "*.pdf" -ErrorAction SilentlyContinue | ForEach-Object {
        $dst = "$PdfsDir\$($_.Name)"
        if (Test-Path $dst) {
            if ($_.LastWriteTime -le (Get-Item $dst).LastWriteTime) { return }
        }
        Log "処理中: $($_.Name)"
        Compress-Pdf $_.FullName $dst
    }

    Get-ChildItem $PdfsDir -Filter "*.pdf" -ErrorAction SilentlyContinue | ForEach-Object {
        $src = "$PdfSourceDir\$($_.Name)"
        if (-not (Test-Path $src)) {
            Log "削除: $($_.Name)"
            Remove-Item $_.FullName -Force
        }
    }

    Generate-FileList
    Log "filelist.json を更新"

    Set-Location $SiteRepoDir
    git add -A
    $null = git diff --cached --quiet 2>&1
    if ($LASTEXITCODE -eq 0) { Log "変更なし（スキップ）"; return }
    git commit -m "auto-update: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    git push origin main
    if ($LASTEXITCODE -eq 0) { Log "デプロイ成功" } else { Log "デプロイ失敗" }
}

Log "=== pdf-auto-deploy 起動 ==="
Log "監視対象: $PdfSourceDir"
Sync-And-Deploy

Log "ファイル監視を開始..."
$watcher = New-Object System.IO.FileSystemWatcher
$watcher.Path = $PdfSourceDir
$watcher.Filter = "*.pdf"
$watcher.EnableRaisingEvents = $true

$lastRun = [datetime]::MinValue
$action = {
    $now = Get-Date
    if (($now - $script:lastRun).TotalSeconds -lt 10) { return }
    $script:lastRun = $now
    Start-Sleep -Seconds 5
    Sync-And-Deploy
}

Register-ObjectEvent $watcher Changed -Action $action | Out-Null
Register-ObjectEvent $watcher Created -Action $action | Out-Null
Register-ObjectEvent $watcher Deleted -Action $action | Out-Null
Register-ObjectEvent $watcher Renamed -Action $action | Out-Null

while ($true) { Start-Sleep -Seconds 60 }
