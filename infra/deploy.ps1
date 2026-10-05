# Deploys the mock lab portal to Azure.
# Run from the repo root in PowerShell after `az login`:
#   .\infra\deploy.ps1
# Creates: resource group, Log Analytics, Application Insights, Container
# Registry, Azure SQL (serverless), App Service plan + Linux container web app,
# and diagnostic settings that send App Service and SQL logs to Log Analytics.

param(
    [string]$Prefix   = "avlabs",
    [string]$Location = "southcentralus"
)

$ErrorActionPreference = "Stop"

# az is a native exe, so PowerShell won't stop on its errors by itself
function Invoke-Az {
    $out = & az @args
    if ($LASTEXITCODE -ne 0) { throw "az $($args[0]) $($args[1]) failed (see error above)" }
    return $out
}

function Write-JsonFile($obj, $path) {
    # UTF-8 without BOM so the az CLI can read it
    [IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $obj -Depth 5))
}

$suffix   = -join ((97..122) | Get-Random -Count 5 | ForEach-Object { [char]$_ })
$rg       = "rg-$Prefix-portal"
$law      = "law-$Prefix"
$appi     = "appi-$Prefix"
$acr      = "acr$Prefix$suffix"
$sqlSrv   = "sql-$Prefix-$suffix"
$sqlDb    = "labportal"
$plan     = "plan-$Prefix"
$web      = "app-$Prefix-$suffix"
$sqlUser  = "labadmin"
$image    = "$acr.azurecr.io/labportal:v1"
$tmp      = Join-Path $env:TEMP "labportal-deploy"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

$secure  = Read-Host "Choose a SQL admin password (12+ chars, upper, lower, number; avoid & ^ %)" -AsSecureString
$sqlPass = [System.Net.NetworkCredential]::new("", $secure).Password

Write-Host "`n[1/8] Resource group $rg" -ForegroundColor Cyan
Invoke-Az group create -n $rg -l $Location -o none

Write-Host "[2/8] Log Analytics + Application Insights" -ForegroundColor Cyan
Invoke-Az monitor log-analytics workspace create -g $rg -n $law -l $Location -o none
$lawId = Invoke-Az monitor log-analytics workspace show -g $rg -n $law --query id -o tsv
Invoke-Az extension add --name application-insights --upgrade -o none
Invoke-Az monitor app-insights component create --app $appi -g $rg -l $Location --workspace $lawId --kind web --application-type web -o none
$aiConn = Invoke-Az monitor app-insights component show --app $appi -g $rg --query connectionString -o tsv

Write-Host "[3/8] Container registry + cloud build (no Docker Desktop needed)" -ForegroundColor Cyan
Invoke-Az acr create -g $rg -n $acr --sku Basic --admin-enabled true -o none
Invoke-Az acr build -r $acr -t labportal:v1 . -o none
$acrUser = Invoke-Az acr credential show -n $acr --query username -o tsv
$acrPass = Invoke-Az acr credential show -n $acr --query "passwords[0].value" -o tsv

Write-Host "[4/8] Azure SQL server + serverless database" -ForegroundColor Cyan
Invoke-Az sql server create -g $rg -n $sqlSrv -l $Location -u $sqlUser -p $sqlPass -o none
Invoke-Az sql server firewall-rule create -g $rg -s $sqlSrv -n AllowAzureServices --start-ip-address 0.0.0.0 --end-ip-address 0.0.0.0 -o none
$myIp = (Invoke-RestMethod https://api.ipify.org)
Invoke-Az sql server firewall-rule create -g $rg -s $sqlSrv -n MyLaptop --start-ip-address $myIp --end-ip-address $myIp -o none
Invoke-Az sql db create -g $rg -s $sqlSrv -n $sqlDb --edition GeneralPurpose --compute-model Serverless `
    --family Gen5 --capacity 1 --auto-pause-delay 60 --backup-storage-redundancy Local -o none

$sqlConn = "Driver={ODBC Driver 18 for SQL Server};Server=tcp:$sqlSrv.database.windows.net,1433;" +
           "Database=$sqlDb;Uid=$sqlUser;Pwd=$sqlPass;Encrypt=yes;TrustServerCertificate=no;Connection Timeout=30;"

Write-Host "[5/8] App Service plan + web app" -ForegroundColor Cyan
Invoke-Az appservice plan create -g $rg -n $plan --is-linux --sku B1 -o none
Invoke-Az webapp create -g $rg -p $plan -n $web --container-image-name $image `
    --container-registry-url "https://$acr.azurecr.io" `
    --container-registry-user $acrUser --container-registry-password $acrPass -o none

Write-Host "[6/8] App settings" -ForegroundColor Cyan
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

Write-Host "[7/8] Send App Service + SQL logs to Log Analytics" -ForegroundColor Cyan
Invoke-Az webapp log config -g $rg -n $web --docker-container-logging filesystem -o none
$webId = Invoke-Az webapp show -g $rg -n $web --query id -o tsv
$webLogs = Join-Path $tmp "web-logs.json"
Write-JsonFile @(
    @{ category = "AppServiceHTTPLogs";     enabled = $true },
    @{ category = "AppServiceConsoleLogs";  enabled = $true },
    @{ category = "AppServiceAppLogs";      enabled = $true },
    @{ category = "AppServicePlatformLogs"; enabled = $true }
) $webLogs
Invoke-Az monitor diagnostic-settings create -n to-law --resource $webId --workspace $lawId --logs "@$webLogs" -o none

$dbId = Invoke-Az sql db show -g $rg -s $sqlSrv -n $sqlDb --query id -o tsv
$dbLogs = Join-Path $tmp "db-logs.json"
$dbMetrics = Join-Path $tmp "db-metrics.json"
Write-JsonFile @(
    @{ category = "Errors";   enabled = $true },
    @{ category = "Timeouts"; enabled = $true }
) $dbLogs
Write-JsonFile @( @{ category = "Basic"; enabled = $true } ) $dbMetrics
Invoke-Az monitor diagnostic-settings create -n to-law --resource $dbId --workspace $lawId --logs "@$dbLogs" --metrics "@$dbMetrics" -o none

Write-Host "[8/8] Restart to pick up settings" -ForegroundColor Cyan
Invoke-Az webapp restart -g $rg -n $web -o none

Write-Host "`nDone." -ForegroundColor Green
Write-Host "Portal:        https://$web.azurewebsites.net"
Write-Host "Health check:  https://$web.azurewebsites.net/health"
Write-Host "Live logs:     az webapp log tail -g $rg -n $web"
Write-Host "Redeploy code: az acr build -r $acr -t labportal:v1 . ; az webapp restart -g $rg -n $web"
Write-Host "Tear down:     az group delete -n $rg --yes --no-wait"
Write-Host "`nFirst load can take 1-2 minutes while the container pulls and the database wakes up."
