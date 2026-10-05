# Finishes the lab portal deploy when `az acr build` isn't allowed
# (free-trial subscriptions). Builds the image locally with Docker Desktop,
# pushes it to the registry deploy.ps1 already created, then runs the rest.
# Run from the project folder (the one with Dockerfile):
#   .\infra\finish-deploy.ps1

param(
    [string]$Prefix   = "avlabs",
    [string]$Suffix   = "xdfoc",
    [string]$Location = "southcentralus",
    [string]$SqlName  = ""
)

$ErrorActionPreference = "Stop"

function Invoke-Az {
    $out = & az @args
    if ($LASTEXITCODE -ne 0) { throw "az $($args[0]) $($args[1]) failed (see error above)" }
    return $out
}

function Exists {
    # Runs an az "show" command quietly; returns $true if the resource exists
    $ErrorActionPreference = "Continue"
    & az @args -o none 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Write-JsonFile($obj, $path) {
    [IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $obj -Depth 5))
}

$rg      = "rg-$Prefix-portal"
$law     = "law-$Prefix"
$appi    = "appi-$Prefix"
$acr     = "acr$Prefix$Suffix"
$sqlSrv  = $(if ($SqlName) { $SqlName } else { "sql-$Prefix-$Suffix" })
$sqlDb   = "labportal"
$plan    = "plan-$Prefix"
$web     = "app-$Prefix-$Suffix"
$sqlUser = "labadmin"
$image   = "$acr.azurecr.io/labportal:v1"
$tmp     = Join-Path $env:TEMP "labportal-deploy"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

if (-not (Test-Path .\Dockerfile)) { throw "Run this from the project folder (the one with Dockerfile)." }

$secure  = Read-Host "Choose a SQL admin password (12+ chars, upper, lower, number; avoid & ^ %)" -AsSecureString
$sqlPass = [System.Net.NetworkCredential]::new("", $secure).Password

Write-Host "`n[1/6] Build image locally and push to $acr" -ForegroundColor Cyan
Invoke-Az acr login -n $acr
docker build -t $image .
if ($LASTEXITCODE -ne 0) { throw "docker build failed (see output above)" }
docker push $image
if ($LASTEXITCODE -ne 0) { throw "docker push failed (see output above)" }
$acrUser = Invoke-Az acr credential show -n $acr --query username -o tsv
$acrPass = Invoke-Az acr credential show -n $acr --query "passwords[0].value" -o tsv

Write-Host "[2/6] Azure SQL server + serverless database" -ForegroundColor Cyan
if (-not (Exists sql server show -g $rg -n $sqlSrv)) {
    Invoke-Az sql server create -g $rg -n $sqlSrv -l $Location -u $sqlUser -p $sqlPass -o none
} else {
    Write-Host "  SQL server exists; resetting its admin password to the one you just typed"
    Invoke-Az sql server update -g $rg -n $sqlSrv -p $sqlPass -o none
}
Invoke-Az sql server firewall-rule create -g $rg -s $sqlSrv -n AllowAzureServices --start-ip-address 0.0.0.0 --end-ip-address 0.0.0.0 -o none
$myIp = (Invoke-RestMethod https://api.ipify.org)
Invoke-Az sql server firewall-rule create -g $rg -s $sqlSrv -n MyLaptop --start-ip-address $myIp --end-ip-address $myIp -o none
if (-not (Exists sql db show -g $rg -s $sqlSrv -n $sqlDb)) {
    Invoke-Az sql db create -g $rg -s $sqlSrv -n $sqlDb --edition GeneralPurpose --compute-model Serverless `
        --family Gen5 --capacity 1 --auto-pause-delay 60 --backup-storage-redundancy Local -o none
}
$sqlConn = "Driver={ODBC Driver 18 for SQL Server};Server=tcp:$sqlSrv.database.windows.net,1433;" +
           "Database=$sqlDb;Uid=$sqlUser;Pwd=$sqlPass;Encrypt=yes;TrustServerCertificate=no;Connection Timeout=30;"

Write-Host "[3/6] App Service plan + web app" -ForegroundColor Cyan
if (-not (Exists appservice plan show -g $rg -n $plan)) {
    Invoke-Az appservice plan create -g $rg -n $plan --is-linux --sku B1 -o none
}
if (-not (Exists webapp show -g $rg -n $web)) {
    Invoke-Az webapp create -g $rg -p $plan -n $web --container-image-name $image `
        --container-registry-url "https://$acr.azurecr.io" `
        --container-registry-user $acrUser --container-registry-password $acrPass -o none
}

Write-Host "[4/6] App settings" -ForegroundColor Cyan
$aiConn = Invoke-Az monitor app-insights component show --app $appi -g $rg --query connectionString -o tsv
$settingsFile = Join-Path $tmp "settings.json"
Write-JsonFile @(
    @{ name = "WEBSITES_PORT";                         value = "8000";  slotSetting = $false },
    @{ name = "APPLICATIONINSIGHTS_CONNECTION_STRING"; value = $aiConn; slotSetting = $false },
    @{ name = "AZURE_SQL_CONNECTION";                  value = $sqlConn; slotSetting = $false },
    @{ name = "FLASK_SECRET";                          value = [guid]::NewGuid().ToString(); slotSetting = $false },
    @{ name = "DEMO_TOOLS";                            value = "true";  slotSetting = $false }
) $settingsFile
Invoke-Az webapp config appsettings set -g $rg -n $web --settings "@$settingsFile" -o none
Remove-Item $settingsFile

Write-Host "[5/6] Send App Service + SQL logs to Log Analytics" -ForegroundColor Cyan
$lawId = Invoke-Az monitor log-analytics workspace show -g $rg -n $law --query id -o tsv
Invoke-Az webapp log config -g $rg -n $web --docker-container-logging filesystem -o none
$webId = Invoke-Az webapp show -g $rg -n $web --query id -o tsv
$webLogs = Join-Path $tmp "web-logs.json"
Write-JsonFile @(
    @{ category = "AppServiceHTTPLogs";     enabled = $true },
    @{ category = "AppServiceConsoleLogs";  enabled = $true },
    @{ category = "AppServiceAppLogs";      enabled = $true },
    @{ category = "AppServicePlatformLogs"; enabled = $true }
) $webLogs
if (-not (Exists monitor diagnostic-settings show -n to-law --resource $webId)) {
    Invoke-Az monitor diagnostic-settings create -n to-law --resource $webId --workspace $lawId --logs "@$webLogs" -o none
}
$dbId = Invoke-Az sql db show -g $rg -s $sqlSrv -n $sqlDb --query id -o tsv
$dbLogs = Join-Path $tmp "db-logs.json"
$dbMetrics = Join-Path $tmp "db-metrics.json"
Write-JsonFile @(
    @{ category = "Errors";   enabled = $true },
    @{ category = "Timeouts"; enabled = $true }
) $dbLogs
Write-JsonFile @( @{ category = "Basic"; enabled = $true } ) $dbMetrics
if (-not (Exists monitor diagnostic-settings show -n to-law --resource $dbId)) {
    Invoke-Az monitor diagnostic-settings create -n to-law --resource $dbId --workspace $lawId --logs "@$dbLogs" --metrics "@$dbMetrics" -o none
}

Write-Host "[6/6] Restart to pick up settings" -ForegroundColor Cyan
Invoke-Az webapp restart -g $rg -n $web -o none

Write-Host "`nDone." -ForegroundColor Green
Write-Host "Portal:        https://$web.azurewebsites.net"
Write-Host "Health check:  https://$web.azurewebsites.net/health"
Write-Host "Live logs:     az webapp log tail -g $rg -n $web"
Write-Host "Redeploy code: docker build -t $image . ; docker push $image ; az webapp restart -g $rg -n $web"
Write-Host "Tear down:     az group delete -n $rg --yes --no-wait"
Write-Host "`nFirst load can take 1-2 minutes while the container pulls and the database wakes up."
