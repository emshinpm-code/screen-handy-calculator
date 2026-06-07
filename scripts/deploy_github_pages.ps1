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
    [string]$InstallMessage
  )

  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "$Name command was not found. $InstallMessage"
  }
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

Write-Step "Checking required tools"
Require-Command "git" "Install Git, then reopen PowerShell."
Require-Command "gh" "Install GitHub CLI, then reopen PowerShell."

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

Write-Step "Checking remote repository"
$originUrl = ""
try {
  $originUrl = (& git remote get-url origin 2>$null)
} catch {
  $originUrl = ""
}

if ([string]::IsNullOrWhiteSpace($originUrl)) {
  $visibility = if ($Public) { "--public" } else { "--private" }
  Write-Step "Creating GitHub repository: $RepoName"
  Run-Gh @("repo", "create", $RepoName, $visibility, "--source=.", "--remote=origin", "--push")
} else {
  Write-Host "origin: $originUrl"
}

Write-Step "Committing and pushing changes"
$status = (& git status --porcelain)
if (-not [string]::IsNullOrWhiteSpace($status)) {
  Run-Git @("add", ".")
  Run-Git @("commit", "-m", $CommitMessage)
} else {
  Write-Host "No changes to commit."
}

Run-Git @("push", "-u", "origin", "main")

Write-Step "Enabling GitHub Pages"
$pagesPostArgs = @(
  "api",
  "--method", "POST",
  "/repos/:owner/$RepoName/pages",
  "-f", "source.branch=main",
  "-f", "source.path=/"
)

& gh @pagesPostArgs
if ($LASTEXITCODE -ne 0) {
  Write-Host "Pages may already be enabled. Trying to update the Pages configuration." -ForegroundColor Yellow
  Run-Gh @(
    "api",
    "--method", "PUT",
    "/repos/:owner/$RepoName/pages",
    "-f", "source.branch=main",
    "-f", "source.path=/"
  )
}

Write-Step "Reading deployment information"
$repoInfoJson = (& gh repo view $RepoName --json nameWithOwner,url)
if ($LASTEXITCODE -ne 0) {
  throw "Could not read repository information."
}

$repoInfo = $repoInfoJson | ConvertFrom-Json
$owner = ($repoInfo.nameWithOwner -split "/")[0]
$pagesUrl = "https://$owner.github.io/$RepoName/"
$branch = (& git branch --show-current)
$commit = (& git rev-parse --short HEAD)

Write-Host ""
Write-Host "Repository URL: $($repoInfo.url)"
Write-Host "Pages URL: $pagesUrl"
Write-Host "Current branch: $branch"
Write-Host "Last commit hash: $commit"
Write-Host "GitHub Pages enabled."
Write-Host "Deploy completed."
