param(
  [string]$RepoName = "screen-handy-calculator",
  [string]$CommitMessage = "chore: update site",
  [bool]$Public = $true
)

$ErrorActionPreference = "Stop"

function Write-Step {
  param([string]$Message)
  Write-Host ""
  Write-Host "==> $Message" -ForegroundColor Cyan
}

function Require-Command {
  param(
    [string]$Name,
    [string]$InstallMessage,
    [string[]]$CandidatePaths = @()
  )

  if (Get-Command $Name -ErrorAction SilentlyContinue) {
    return
  }

  foreach ($candidate in $CandidatePaths) {
    if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)) {
      $candidateDirectory = Split-Path -Parent $candidate
      $env:Path = "$candidateDirectory;$env:Path"
      if (Get-Command $Name -ErrorAction SilentlyContinue) {
        return
      }
    }
  }

  throw "$Name command was not found. $InstallMessage"
}

function Run-Gh {
  param([string[]]$Arguments)
  & gh @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "gh $($Arguments -join ' ') failed."
  }
}

function Run-Git {
  param([string[]]$Arguments)
  & git @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "git $($Arguments -join ' ') failed."
  }
}

function Get-PagesUrl {
  param(
    [string]$Owner,
    [string]$RepoName
  )

  $url = (& gh api "/repos/$Owner/$RepoName/pages" --jq ".html_url" 2>$null)
  if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($url)) {
    return $url.Trim()
  }

  return ""
}

function Get-RemoteUrl {
  param(
    [string]$Owner,
    [string]$RepoName
  )

  $url = (& gh repo view "$Owner/$RepoName" --json url --jq ".url" 2>$null)
  if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($url)) {
    return $url.Trim()
  }

  return ""
}

Write-Step "Checking required tools"
$gitCandidates = @(
  "$env:ProgramFiles\Git\cmd\git.exe",
  "$env:ProgramFiles\Git\bin\git.exe",
  "${env:ProgramFiles(x86)}\Git\cmd\git.exe",
  "${env:ProgramFiles(x86)}\Git\bin\git.exe",
  "$env:LocalAppData\Programs\Git\cmd\git.exe",
  "$env:LocalAppData\Programs\Git\bin\git.exe"
)

$ghCandidates = @(
  "$env:ProgramFiles\GitHub CLI\gh.exe",
  "${env:ProgramFiles(x86)}\GitHub CLI\gh.exe",
  "$env:LocalAppData\Programs\GitHub CLI\gh.exe",
  "$env:LocalAppData\GitHub CLI\gh.exe"
)

Require-Command "git" "Install Git, then reopen PowerShell." $gitCandidates
Require-Command "gh" "Install GitHub CLI, then reopen PowerShell." $ghCandidates

Write-Step "Checking GitHub CLI authentication"
& gh auth status
if ($LASTEXITCODE -ne 0) {
  Write-Host ""
  Write-Host "GitHub CLI authentication is required." -ForegroundColor Yellow
  Write-Host "Run these commands manually, complete browser authentication, then rerun this script."
  Write-Host ""
  Write-Host "  gh auth login"
  Write-Host "  gh auth setup-git"
  exit 1
}

Write-Step "Reading GitHub owner"
$Owner = (& gh api user --jq ".login")
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($Owner)) {
  throw "Could not read GitHub login."
}
$Owner = $Owner.Trim()
Write-Host "Owner: $Owner"

Write-Step "Checking project files"
$requiredFiles = @(
  "index.html",
  "README.md",
  ".gitignore",
  "docs/CHANGELOG.md"
)

foreach ($file in $requiredFiles) {
  if (-not (Test-Path -LiteralPath $file)) {
    throw "Required file is missing: $file"
  }
}

Write-Step "Checking Git repository"
if (-not (Test-Path -LiteralPath ".git")) {
  Run-Git @("init")
}

Run-Git @("branch", "-M", "main")

Write-Step "Creating local commit if needed"
$hasCommit = $true
& git rev-parse --verify HEAD *> $null
if ($LASTEXITCODE -ne 0) {
  $hasCommit = $false
}

$status = (& git status --porcelain)
if (-not $hasCommit -or -not [string]::IsNullOrWhiteSpace($status)) {
  Run-Git @("add", ".")
  Run-Git @("commit", "-m", $CommitMessage)
} else {
  Write-Host "No changes to commit."
}

Write-Step "Checking remote repository"
$originUrl = ""
try {
  $originUrl = (& git remote get-url origin 2>$null)
} catch {
  $originUrl = ""
}

if ([string]::IsNullOrWhiteSpace($originUrl)) {
  $visibility = if ($Public) { "--public" } else { "--private" }
  $existingRepoUrl = Get-RemoteUrl -Owner $Owner -RepoName $RepoName

  if ([string]::IsNullOrWhiteSpace($existingRepoUrl)) {
    Write-Step "Creating GitHub repository: $RepoName"
    Run-Gh @("repo", "create", $RepoName, $visibility, "--source=.", "--remote=origin")
  } else {
    Write-Step "Connecting existing GitHub repository: $RepoName"
    Run-Git @("remote", "add", "origin", $existingRepoUrl)
  }
} else {
  Write-Host "origin: $originUrl"
}

Write-Step "Pushing main branch"
Run-Git @("push", "-u", "origin", "main")

Write-Step "Enabling GitHub Pages"
$pagesPath = "/repos/$Owner/$RepoName/pages"
$pagesPostArgs = @(
  "api",
  "--method", "POST",
  $pagesPath,
  "-f", "source[branch]=main",
  "-f", "source[path]=/"
)

& gh @pagesPostArgs
if ($LASTEXITCODE -ne 0) {
  Write-Host "Pages may already be enabled. Trying to update the Pages configuration." -ForegroundColor Yellow
  & gh @(
    "api",
    "--method", "PUT",
    $pagesPath,
    "-f", "source[branch]=main",
    "-f", "source[path]=/"
  )

  if ($LASTEXITCODE -ne 0) {
    $existingPagesUrl = Get-PagesUrl -Owner $Owner -RepoName $RepoName
    if ([string]::IsNullOrWhiteSpace($existingPagesUrl)) {
      throw "Could not enable or read GitHub Pages."
    }

    Write-Host "Pages is already enabled."
  }
}

Write-Step "Reading deployment information"
$repoInfoJson = (& gh repo view $RepoName --json nameWithOwner,url)
if ($LASTEXITCODE -ne 0) {
  throw "Could not read repository information."
}

$repoInfo = $repoInfoJson | ConvertFrom-Json
$PagesUrl = ""
for ($attempt = 1; $attempt -le 3; $attempt++) {
  $PagesUrl = Get-PagesUrl -Owner $Owner -RepoName $RepoName
  if (-not [string]::IsNullOrWhiteSpace($PagesUrl)) {
    break
  }

  if ($attempt -lt 3) {
    Write-Host "Pages URL is not ready yet. Retrying in 3 seconds..."
    Start-Sleep -Seconds 3
  }
}

if ([string]::IsNullOrWhiteSpace($PagesUrl)) {
  $PagesUrl = "https://$Owner.github.io/$RepoName/"
  Write-Host "Could not read Pages html_url. Using expected Pages URL." -ForegroundColor Yellow
}

$branch = (& git branch --show-current)
$commit = (& git rev-parse --short HEAD)

Write-Host ""
Write-Host "Repository URL: $($repoInfo.url)"
Write-Host "Pages URL: $PagesUrl"
Write-Host "Current branch: $branch"
Write-Host "Last commit hash: $commit"
Write-Host "GitHub Pages enabled."
Write-Host "Deploy completed."
