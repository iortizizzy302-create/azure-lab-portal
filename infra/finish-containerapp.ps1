# Finishes the lab portal deploy on Azure Container Apps (for subscriptions
# with no App Service quota). Uses the image, SQL server, Log Analytics and
# App Insights that already exist.
# Run from the project folder:
#   .\infra\finish-containerapp.ps1 -SqlName sqlavl780191

param(
    [Parameter(Mandatory = $true)][string]$SqlName,
    [string]$Prefix   = "avlabs",
    [string]$Suffix   = "xdfoc",
    [string]$Location = "centralus"
)

$ErrorActionPreference = "Stop"

function Invoke-Az {
    $out = & az @args
    if ($LASTEXITCODE -ne 0) { throw "az $($args[0]) $($args[1]) failed (see error above)" }
    return $out
}

function Exists {
    $ErrorActionPreference = "Continue"
    & az @args -o none 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

$rg      = "rg-$Prefix-portal"
$law     = "law-$Prefix"
$appi    = "appi-$Prefix"
$acr     = "acr$Prefix$Suffix"
$sqlDb   = "labportal"
$sqlUser = "labadmin"
$envName = "cae-$Prefix-$Location"
$app     = "ca-$Prefix-$Suffix"
$image   = "$acr.azurecr.io/labportal:v1"

$secure  = Read-Host "SQL admin password (the one you used for $SqlName)" -AsSecureString
$sqlPass = [System.Net.NetworkCredential]::new("", $secure).Password

Write-Host "`n[1/5] Container Apps CLI extension + provider" -ForegroundColor Cyan
Invoke-Az extension add --name containerapp --upgrade -o none
Invoke-Az provider register --namespace Microsoft.App --wait -o none

Write-Host "[2/5] Make sure the database exists" -ForegroundColor Cyan
if (-not (Exists sql db show -g $rg -s $SqlName -n $sqlDb)) {
    Invoke-Az sql db create -g $rg -s $SqlName -n $sqlDb --edition GeneralPurpose --compute-model Serverless `
        --family Gen5 --capacity 1 --auto-pause-delay 60 --backup-storage-redundancy Local -o none
}
if (-not (Exists sql server firewall-rule show -g $rg -s $SqlName -n AllowAzureServices)) {
    Invoke-Az sql server firewall-rule create -g $rg -s $SqlName -n AllowAzureServices --start-ip-address 0.0.0.0 --end-ip-address 0.0.0.0 -o none
}
$sqlConn = "Driver={ODBC Driver 18 for SQL Server};Server=tcp:$SqlName.database.windows.net,1433;" +
           "Database=$sqlDb;Uid=$sqlUser;Pwd=$sqlPass;Encrypt=yes;TrustServerCertificate=no;Connection Timeout=30;"

Write-Host "[3/5] Container Apps environment wired to Log Analytics" -ForegroundColor Cyan
$lawCustomerId = Invoke-Az monitor log-analytics workspace show -g $rg -n $law --query customerId -o tsv
$lawKey        = Invoke-Az monitor log-analytics workspace get-shared-keys -g $rg -n $law --query primarySharedKey -o tsv
if (-not (Exists containerapp env show -g $rg -n $envName)) {
    Invoke-Az containerapp env create -g $rg -n $envName -l $Location `
        --logs-workspace-id $lawCustomerId --logs-workspace-key $lawKey -o none
}

Write-Host "[4/5] Container app" -ForegroundColor Cyan
$aiConn  = Invoke-Az monitor app-insights component show --app $appi -g $rg --query connectionString -o tsv
$acrUser = Invoke-Az acr credential show -n $acr --query username -o tsv
$acrPass = Invoke-Az acr credential show -n $acr --query "passwords[0].value" -o tsv
$flask   = [guid]::NewGuid().ToString()

$secrets = @("sqlconn=$sqlConn", "aiconn=$aiConn", "flasksecret=$flask")
$envVars = @("AZURE_SQL_CONNECTION=secretref:sqlconn",
             "APPLICATIONINSIGHTS_CONNECTION_STRING=secretref:aiconn",
             "FLASK_SECRET=secretref:flasksecret",
             "DEMO_TOOLS=true")

if (-not (Exists containerapp show -g $rg -n $app)) {
    Invoke-Az containerapp create -g $rg -n $app --environment $envName --image $image `
        --registry-server "$acr.azurecr.io" --registry-username $acrUser --registry-password $acrPass `
        --target-port 8000 --ingress external --cpu 0.5 --memory 1.0Gi `
        --min-replicas 0 --max-replicas 1 `
        --secrets @secrets --env-vars @envVars -o none
} else {
    Invoke-Az containerapp secret set -g $rg -n $app --secrets @secrets -o none
    Invoke-Az containerapp update -g $rg -n $app --image $image --set-env-vars @envVars -o none
}

Write-Host "[5/5] Get the URL" -ForegroundColor Cyan
$fqdn = Invoke-Az containerapp show -g $rg -n $app --query properties.configuration.ingress.fqdn -o tsv

Write-Host "`nDone." -ForegroundColor Green
Write-Host "Portal:        https://$fqdn"
Write-Host "Health check:  https://$fqdn/health"
Write-Host "Live logs:     az containerapp logs show -g $rg -n $app --follow"
Write-Host "Redeploy code: docker build -t $image . ; docker push $image ; az containerapp update -g $rg -n $app --image $image"
Write-Host "Tear down:     az group delete -n $rg --yes --no-wait"
Write-Host "`nThe app scales to zero when idle, so the first visit can take 30-60 seconds to wake up."