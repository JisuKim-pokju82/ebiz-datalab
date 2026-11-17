$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$gh = "C:\Program Files\GitHub CLI\gh.exe"
if (-not (Test-Path $gh)) {
    $ghCmd = Get-Command gh -ErrorAction SilentlyContinue
    if ($ghCmd) { $gh = $ghCmd.Source } else { throw "GitHub CLI (gh) not found." }
}

$token = (& $gh auth token).Trim()
$headers = @{
    "Authorization"        = "Bearer $token"
    "Accept"               = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
    "User-Agent"           = "Antigravity-eBiz-DataLab"
}

$Owner = "JisuKim-pokju82"
$Repo  = "ebiz-datalab"
$WorkDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $WorkDir) { $WorkDir = (Get-Location).Path }
$TodayDate = ([DateTimeOffset]::UtcNow.ToOffset([TimeSpan]::FromHours(9))).ToString("yyyy-MM-dd")

function Invoke-GhJsonPost {
    param([string]$Uri, [string]$Method = "Post", [object]$BodyObj)
    $json = $BodyObj | ConvertTo-Json -Depth 10 -Compress
    $utf8Bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    return Invoke-RestMethod -Uri $Uri -Headers $headers -Method $Method -ContentType "application/json; charset=utf-8" -Body $utf8Bytes
}

# 0. Update 기타/manifest.json automatically from local SUMMARY\기타 files
$etcDir = Join-Path $WorkDir "기타"
if (-not (Test-Path $etcDir)) {
    New-Item -ItemType Directory -Force -Path $etcDir | Out-Null
}
$hiddenEtc = @("index.html", "manifest.json", ".gitkeep")
$etcFiles = @()
Get-ChildItem -LiteralPath $etcDir -File -Force | Sort-Object Name | ForEach-Object {
    if ($hiddenEtc -notcontains $_.Name) {
        $etcFiles += [ordered]@{
            name      = $_.Name
            size      = $_.Length
            updatedAt = $_.LastWriteTime.ToString("yyyy-MM-dd")
        }
    }
}
$manifestObj = [ordered]@{
    updatedAt = $TodayDate
    files     = $etcFiles
}
$manifestJson = $manifestObj | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText((Join-Path $etcDir "manifest.json"), $manifestJson, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "[1/4] Updated 기타/manifest.json ($($etcFiles.Count) archive files detected)." -ForegroundColor Cyan

# 1. Ensure repository exists on GitHub (auto-init if brand new)
$repoExists = $false
try {
    $null = Invoke-RestMethod -Uri "https://api.github.com/repos/$Owner/$Repo" -Headers $headers -Method Get
    $repoExists = $true
} catch {
    $repoExists = $false
}

if (-not $repoExists) {
    Write-Host "[2/4] Creating GitHub repository $Owner/$Repo ..." -ForegroundColor Yellow
    $createBody = [ordered]@{
        name        = $Repo
        description = "K Car e-biz실 데이터랩 (Mobility Intelligence & Strategy Main Portal)"
        homepage    = "https://jisukim-pokju82.github.io/$Repo/"
        private     = $false
        auto_init   = $true
    }
    $null = Invoke-GhJsonPost -Uri "https://api.github.com/user/repos" -Method "Post" -BodyObj $createBody
    Start-Sleep -Seconds 2
} else {
    Write-Host "[2/4] Repository $Owner/$Repo verified." -ForegroundColor Cyan
}

# 2. Collect all files in SUMMARY (excluding .github/workflows which is uploaded via Contents API to register Actions)
$refInfo = Invoke-RestMethod -Uri "https://api.github.com/repos/$Owner/$Repo/git/ref/heads/main" -Headers $headers -Method Get
$baseCommitSha = $refInfo.object.sha
$commitInfo = Invoke-RestMethod -Uri "https://api.github.com/repos/$Owner/$Repo/git/commits/$baseCommitSha" -Headers $headers -Method Get
$baseTreeSha = $commitInfo.tree.sha

$allFiles = Get-ChildItem -LiteralPath $WorkDir -Recurse -File -Force | Where-Object {
    $rel = $_.FullName.Substring($WorkDir.Length).TrimStart('\', '/') -replace '\\', '/'
    ($rel -notlike ".git/*") -and ($rel -notlike ".github/workflows/*")
}

Write-Host "[3/4] Uploading $($allFiles.Count) portal files to GitHub ($Owner/$Repo) ..." -ForegroundColor Cyan
$treeItems = New-Object System.Collections.Generic.List[object]
foreach ($file in $allFiles) {
    $relPath = $file.FullName.Substring($WorkDir.Length).TrimStart('\', '/') -replace '\\', '/'
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    $b64 = [Convert]::ToBase64String($bytes)
    $blobRes = Invoke-GhJsonPost -Uri "https://api.github.com/repos/$Owner/$Repo/git/blobs" -Method "Post" -BodyObj @{
        content  = $b64
        encoding = "base64"
    }
    $treeItems.Add([ordered]@{
        path = $relPath
        mode = "100644"
        type = "blob"
        sha  = $blobRes.sha
    })
}

$newTree = Invoke-GhJsonPost -Uri "https://api.github.com/repos/$Owner/$Repo/git/trees" -Method "Post" -BodyObj @{
    base_tree = $baseTreeSha
    tree      = $treeItems
}

if ($newTree.sha -ne $baseTreeSha) {
    $newCommit = Invoke-GhJsonPost -Uri "https://api.github.com/repos/$Owner/$Repo/git/commits" -Method "Post" -BodyObj @{
        message = "feat(portal): sync e-biz실 데이터랩 main portal & category reports ($TodayDate)"
        tree    = $newTree.sha
        parents = @($baseCommitSha)
    }
    $null = Invoke-GhJsonPost -Uri "https://api.github.com/repos/$Owner/$Repo/git/refs/heads/main" -Method "Patch" -BodyObj @{
        sha   = $newCommit.sha
        force = $false
    }
    Write-Host "  -> Committed portal files ($($newCommit.sha.Substring(0,7)))." -ForegroundColor Green
} else {
    Write-Host "  -> Portal tree is already up to date ($($baseCommitSha.Substring(0,7)))." -ForegroundColor Green
}

# 3. Sync .github/workflows/sync_etc_manifest.yml via Contents API
$wfRel = ".github/workflows/sync_etc_manifest.yml"
$wfFull = Join-Path $WorkDir ($wfRel -replace '/', '\')
if (Test-Path $wfFull) {
    $wfBytes = [System.IO.File]::ReadAllBytes($wfFull)
    $wfB64   = [Convert]::ToBase64String($wfBytes)
    $remoteWf = $null
    try {
        $remoteWf = Invoke-RestMethod -Uri "https://api.github.com/repos/$Owner/$Repo/contents/$wfRel" -Headers $headers -Method Get
    } catch {}
    $remoteCleanB64 = if ($remoteWf -and $remoteWf.content) { ($remoteWf.content -replace '\s+', '') } else { "" }
    if ($remoteCleanB64 -ne $wfB64) {
        $putBody = [ordered]@{
            message = "ci(archive): register cloud auto-manifest workflow for 기타 folder"
            content = $wfB64
            branch  = "main"
        }
        if ($remoteWf -and $remoteWf.sha) { $putBody["sha"] = $remoteWf.sha }
        $null = Invoke-GhJsonPost -Uri "https://api.github.com/repos/$Owner/$Repo/contents/$wfRel" -Method "Put" -BodyObj $putBody
        Write-Host "  -> Registered GitHub Actions workflow ($wfRel)." -ForegroundColor Cyan
    }
}

# 4. Enable GitHub Pages (main branch, / root) if not already enabled
Write-Host "[4/4] Verifying GitHub Pages deployment (24/7 Cloud Hosting, PC OFF ready) ..." -ForegroundColor Cyan
$pagesEnabled = $false
try {
    $pagesInfo = Invoke-RestMethod -Uri "https://api.github.com/repos/$Owner/$Repo/pages" -Headers $headers -Method Get
    $pagesEnabled = $true
} catch {
    $pagesEnabled = $false
}

if (-not $pagesEnabled) {
    $pagesInfo = Invoke-GhJsonPost -Uri "https://api.github.com/repos/$Owner/$Repo/pages" -Method "Post" -BodyObj @{
        source = @{
            branch = "main"
            path   = "/"
        }
    }
    Write-Host "  -> Enabled GitHub Pages!" -ForegroundColor Green
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host " e-biz실 데이터랩 GitHub 클라우드 배포 완료! (PC 전원 OFF 가능)" -ForegroundColor Green
Write-Host " 메인 포털 URL : https://jisukim-pokju82.github.io/$Repo/" -ForegroundColor Yellow
Write-Host " 보증 개선 URL : https://jisukim-pokju82.github.io/$Repo/warranty/" -ForegroundColor Yellow
Write-Host " 기타 폴더 URL : https://jisukim-pokju82.github.io/$Repo/%EA%B8%B0%ED%83%80/" -ForegroundColor Yellow
Write-Host "================================================================" -ForegroundColor Green
