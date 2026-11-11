<#
.SYNOPSIS
    Inventory of Azure Cosmos DB across all engine types, with per-database size and backup settings.

.DESCRIPTION
    Scans one or all enabled subscriptions and writes ONE CSV (AzureCosmos_Inventory_<ts>.csv)
    with a row per database (or per cluster for the vCore/PostgreSQL offerings).

    Engine types detected (ApiType column):
      - NoSQL                         Cosmos DB account, Kind GlobalDocumentDB
      - MongoDB (RU)                  Cosmos DB account, Kind MongoDB
      - Cassandra / Gremlin / Table   Cosmos DB account with the EnableCassandra / EnableGremlin / EnableTable capability
      - PostgreSQL                    Cosmos DB for PostgreSQL cluster (Microsoft.DBforPostgreSQL/serverGroupsv2)
      - MongoDB vCore                 Cosmos DB for MongoDB vCore / Azure DocumentDB (Microsoft.DocumentDB/mongoClusters)

    Size (RU-based accounts): Azure Monitor metrics DataUsage / IndexUsage / DocumentCount split by
    database and container (max value, last 3 hours). Backup: account-level policy (Periodic: interval,
    retention, redundancy; Continuous: 7-day / 30-day tier). Cosmos DB has no separate long-term
    retention feature, so there are no LTR fields.

.PARAMETER SubscriptionId
    One or more subscription IDs. Default: all enabled subscriptions.

.PARAMETER OutputPath
    Folder for the CSV. Default: current directory.

.PARAMETER SkipMetrics
    Skip Azure Monitor metric queries (faster, no size data).

.NOTES
    Requires: Az.Accounts, Az.CosmosDB, Az.Monitor, Az.Resources. Reader on the subscriptions is enough.
    Run: Connect-AzAccount ; .\Get-AzureCosmosInventory.ps1 -OutputPath C:\Temp
#>
[CmdletBinding()]
param(
    [string[]]$SubscriptionId,
    [string]$OutputPath = (Get-Location).Path,
    [switch]$SkipMetrics
)

$ErrorActionPreference = 'Continue'
$WarningPreference     = 'SilentlyContinue'

foreach ($m in 'Az.Accounts', 'Az.CosmosDB', 'Az.Monitor', 'Az.Resources') {
    if (-not (Get-Module -ListAvailable -Name $m)) { throw "Missing module $m. Install-Module Az -Scope CurrentUser" }
    Import-Module $m -ErrorAction Stop
}
if (-not (Get-AzContext)) { Connect-AzAccount | Out-Null }
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath | Out-Null }
$ts = Get-Date -Format 'yyyyMMdd_HHmmss'

# ---------- helpers ----------
function ToGB($bytes) { if ($null -eq $bytes) { $null } else { [math]::Round($bytes / 1GB, 4) } }

function First-NonNull {
    foreach ($a in $args) { if ($null -ne $a -and "$a" -ne '') { return $a } }
    return $null
}

function Get-LastMetric {
    param([string]$ResourceId, [string]$MetricName)
    if ($SkipMetrics) { return $null }
    try {
        $r = Get-AzMetric -ResourceId $ResourceId -MetricName $MetricName -AggregationType Maximum `
                -StartTime (Get-Date).AddHours(-1) -EndTime (Get-Date) -TimeGrain 00:05:00 `
                -WarningAction SilentlyContinue -ErrorAction Stop
        $pt = $r.Data | Where-Object { $null -ne $_.Maximum } | Select-Object -Last 1
        if ($pt) { return [double]$pt.Maximum }
    } catch { Write-Verbose "Metric $MetricName failed for $ResourceId : $($_.Exception.Message)" }
    return $null
}

# Per database + container usage for a Cosmos account. Returns @{ dbName = @{Data;Index;Docs;Containers=@{}} }
function Get-CosmosUsage {
    param([string]$AccountId)
    $out = @{}
    if ($SkipMetrics) { return $out }
    try {
        $metrics = Get-AzMetric -ResourceId $AccountId -MetricName 'DataUsage', 'IndexUsage', 'DocumentCount' `
            -AggregationType Maximum -TimeGrain 00:05:00 `
            -StartTime (Get-Date).AddHours(-3) -EndTime (Get-Date) `
            -MetricFilter "DatabaseName eq '*' and CollectionName eq '*'" `
            -WarningAction SilentlyContinue -ErrorAction Stop
        foreach ($m in $metrics) {
            foreach ($series in $m.Timeseries) {
                $dims = @{}
                foreach ($mv in $series.Metadatavalues) { $dims[$mv.Name.Value.ToLower()] = $mv.Value }
                $db   = First-NonNull $dims['databasename'] '(n/a)'
                $coll = First-NonNull $dims['collectionname'] '(n/a)'
                $pt   = $series.Data | Where-Object { $null -ne $_.Maximum } | Select-Object -Last 1
                if (-not $pt) { continue }
                if (-not $out.ContainsKey($db)) { $out[$db] = @{ Data = 0.0; Index = 0.0; Docs = 0.0; Containers = @{} } }
                $out[$db].Containers[$coll] = $true
                switch ($m.Name.Value) {
                    'DataUsage'     { $out[$db].Data  += [double]$pt.Maximum }
                    'IndexUsage'    { $out[$db].Index += [double]$pt.Maximum }
                    'DocumentCount' { $out[$db].Docs  += [double]$pt.Maximum }
                }
            }
        }
    } catch { Write-Warning "Usage metrics failed for $AccountId : $($_.Exception.Message)" }
    return $out
}

function Get-CosmosApi($acct) {
    $caps = @($acct.Capabilities | ForEach-Object { $_.Name })
    if ($acct.Kind -eq 'MongoDB' -or $caps -contains 'EnableMongo' -or $caps -contains 'EnableMongo16MBDocumentSupport') { return 'MongoDB (RU)' }
    if ($caps -contains 'EnableCassandra') { return 'Cassandra' }
    if ($caps -contains 'EnableGremlin')   { return 'Gremlin' }
    if ($caps -contains 'EnableTable')     { return 'Table' }
    return 'NoSQL'
}

# Database names per API
function Get-CosmosDbNames($api, $rg, $name) {
    try {
        switch ($api) {
            'NoSQL'        { return @(Get-AzCosmosDBSqlDatabase      -ResourceGroupName $rg -AccountName $name -ErrorAction Stop | ForEach-Object Name) }
            'MongoDB (RU)' { return @(Get-AzCosmosDBMongoDBDatabase  -ResourceGroupName $rg -AccountName $name -ErrorAction Stop | ForEach-Object Name) }
            'Cassandra'    { return @(Get-AzCosmosDBCassandraKeyspace -ResourceGroupName $rg -AccountName $name -ErrorAction Stop | ForEach-Object Name) }
            'Gremlin'      { return @(Get-AzCosmosDBGremlinDatabase  -ResourceGroupName $rg -AccountName $name -ErrorAction Stop | ForEach-Object Name) }
            default        { return @() }   # Table API has no database level
        }
    } catch { Write-Warning "Cannot list databases for $name ($api): $($_.Exception.Message)"; return @() }
}

# ---------- results ----------
$rows = [System.Collections.Generic.List[object]]::new()

function New-Row {
    [ordered]@{
        ServiceType = $null; ApiType = $null; ApiVersion = $null
        Subscription = $null; ResourceGroup = $null; Location = $null
        AccountOrClusterName = $null; Endpoint = $null
        DatabaseName = $null; ContainerCount = $null
        DataUsedGB = $null; IndexUsedGB = $null; TotalUsedGB = $null; DocumentCount = $null
        AccountTotalUsedGB = $null; ProvisionedStorageGB = $null
        CapacityMode = $null; Regions = $null; MultiRegionWrites = $null; AutoFailover = $null
        Consistency = $null; PublicNetworkAccess = $null; ZoneOrHA = $null
        BackupType = $null; BackupIntervalMinutes = $null; BackupRetentionHours = $null
        ContinuousTier = $null; BackupRedundancy = $null; EarliestRestore = $null
        Notes = $null
    }
}

# ---------- subscriptions ----------
$subs = if ($SubscriptionId) {
    $SubscriptionId | ForEach-Object { Get-AzSubscription -SubscriptionId $_ }
} else {
    Get-AzSubscription | Where-Object State -eq 'Enabled'
}

foreach ($sub in $subs) {
    Write-Host "Subscription: $($sub.Name) ($($sub.Id))" -ForegroundColor Cyan
    try { Set-AzContext -SubscriptionId $sub.Id -TenantId $sub.TenantId | Out-Null }
    catch { Write-Warning "Cannot set context for $($sub.Name): $($_.Exception.Message)"; continue }

    # ===== Cosmos DB accounts (NoSQL, MongoDB RU, Cassandra, Gremlin, Table) =====
    $accounts = @()
    foreach ($rg in (Get-AzResourceGroup -ErrorAction SilentlyContinue)) {
        $accounts += @(Get-AzCosmosDBAccount -ResourceGroupName $rg.ResourceGroupName -ErrorAction SilentlyContinue)
    }

    foreach ($a in $accounts) {
        $api = Get-CosmosApi $a
        $rg  = ($a.Id -split '/')[4]
        Write-Host "  Cosmos account: $($a.Name) [$api]"

        $caps = @($a.Capabilities | ForEach-Object { $_.Name })
        $mode = if ($caps -contains 'EnableServerless') { 'Serverless' } else { 'Provisioned throughput' }
        $bp   = $a.BackupPolicy
        $usage = Get-CosmosUsage -AccountId $a.Id

        $common = {
            param($r)
            $r.ServiceType = 'Cosmos DB account'
            $r.ApiType = $api
            $r.ApiVersion = $a.ApiProperties.ServerVersion
            $r.Subscription = $sub.Name; $r.ResourceGroup = $rg; $r.Location = $a.Location
            $r.AccountOrClusterName = $a.Name; $r.Endpoint = $a.DocumentEndpoint
            $r.CapacityMode = $mode
            $r.Regions = (@($a.Locations | ForEach-Object { $_.LocationName }) -join '; ')
            $r.MultiRegionWrites = $a.EnableMultipleWriteLocations
            $r.AutoFailover = $a.EnableAutomaticFailover
            $r.Consistency = $a.ConsistencyPolicy.DefaultConsistencyLevel
            $r.PublicNetworkAccess = $a.PublicNetworkAccess
            $r.ZoneOrHA = if (@($a.Locations | Where-Object { $_.IsZoneRedundant }).Count -gt 0) { 'Zone redundant' } else { 'No AZ' }
            $r.BackupType = $bp.BackupType
            $r.BackupIntervalMinutes = $bp.PeriodicModeProperties.BackupIntervalInMinutes
            $r.BackupRetentionHours = $bp.PeriodicModeProperties.BackupRetentionIntervalInHours
            $r.ContinuousTier = $bp.ContinuousModeProperties.Tier
            $r.BackupRedundancy = $bp.PeriodicModeProperties.BackupStorageRedundancy
            if ($bp.BackupType -eq 'Continuous') { $r.Notes = 'Continuous backup: point-in-time restore within the tier window' }
        }

        $acctTotal = 0.0
        foreach ($u in $usage.Values) { $acctTotal += $u.Data + $u.Index }

        # Databases: from the API list, plus any only seen in metrics (and Table API)
        $dbNames = @(Get-CosmosDbNames $api $rg $a.Name)
        foreach ($k in $usage.Keys) { if ($dbNames -notcontains $k) { $dbNames += $k } }
        if ($dbNames.Count -eq 0) { $dbNames = @($null) }   # empty account: still emit one row

        foreach ($dbn in $dbNames) {
            $u = if ($dbn) { $usage[$dbn] } else { $null }
            $r = New-Row
            & $common $r
            $r.DatabaseName = if ($dbn) { $dbn } elseif ($api -eq 'Table') { '(Table API - account level)' } else { '(no databases)' }
            if ($u) {
                $r.ContainerCount     = $u.Containers.Count
                $r.DataUsedGB         = ToGB $u.Data
                $r.IndexUsedGB        = ToGB $u.Index
                $r.TotalUsedGB        = ToGB ($u.Data + $u.Index)
                $r.DocumentCount      = $u.Docs
            }
            $r.AccountTotalUsedGB = ToGB $acctTotal
            $rows.Add([pscustomobject]$r)
        }
    }

    # ===== Cosmos DB for PostgreSQL clusters =====
    foreach ($pg in (Get-AzResource -ResourceType 'Microsoft.DBforPostgreSQL/serverGroupsv2' -ExpandProperties -ErrorAction SilentlyContinue)) {
        Write-Host "  Cosmos DB for PostgreSQL: $($pg.Name)"
        $p = $pg.Properties
        $nodes = [int](First-NonNull $p.nodeCount 0)
        $provMb = [double](First-NonNull $p.coordinatorStorageQuotaInMb 0) + $nodes * [double](First-NonNull $p.nodeStorageQuotaInMb 0)
        $usedBytes = Get-LastMetric $pg.ResourceId 'storage_used'

        $r = New-Row
        $r.ServiceType = 'Cosmos DB for PostgreSQL cluster'; $r.ApiType = 'PostgreSQL'
        $r.ApiVersion = "PG $($p.postgresqlVersion) / Citus $($p.citusVersion)"
        $r.Subscription = $sub.Name; $r.ResourceGroup = $pg.ResourceGroupName; $r.Location = $pg.Location
        $r.AccountOrClusterName = $pg.Name
        $r.Endpoint = (@($p.serverNames | ForEach-Object { $_.fullyQualifiedDomainName }) -join '; ')
        $r.DatabaseName = First-NonNull $p.databaseName 'citus'
        $r.ContainerCount = $null
        $r.TotalUsedGB = ToGB $usedBytes
        $r.ProvisionedStorageGB = [math]::Round($provMb / 1024, 2)
        $r.CapacityMode = "Coordinator $($p.coordinatorVCores) vCores; $nodes worker node(s) x $($p.nodeVCores) vCores"
        $r.ZoneOrHA = if ($p.enableHa) { 'HA enabled' } else { 'HA disabled' }
        $r.PublicNetworkAccess = $p.enablePublicIpAccess
        $r.BackupType = 'Automatic (service managed)'
        $r.EarliestRestore = $p.earliestRestoreTime
        $r.Notes = 'Used = storage_used metric (max, best effort). Retention is service-managed; verify in portal.'
        $rows.Add([pscustomobject]$r)
    }

    # ===== Cosmos DB for MongoDB vCore / Azure DocumentDB clusters =====
    foreach ($mc in (Get-AzResource -ResourceType 'Microsoft.DocumentDB/mongoClusters' -ExpandProperties -ErrorAction SilentlyContinue)) {
        Write-Host "  Cosmos DB for MongoDB vCore: $($mc.Name)"
        $p  = $mc.Properties
        $ng = $p.nodeGroupSpecs | Select-Object -First 1
        $diskGb = First-NonNull $ng.diskSizeGB $p.storage.sizeGb
        $sku    = First-NonNull $ng.sku $p.compute.tier
        $ha     = First-NonNull $p.highAvailability.targetMode $(if ($ng.enableHa) { 'ZoneRedundantPreferred' })

        $r = New-Row
        $r.ServiceType = 'Cosmos DB for MongoDB vCore cluster'; $r.ApiType = 'MongoDB vCore'
        $r.ApiVersion = $p.serverVersion
        $r.Subscription = $sub.Name; $r.ResourceGroup = $mc.ResourceGroupName; $r.Location = $mc.Location
        $r.AccountOrClusterName = $mc.Name
        $r.Endpoint = First-NonNull $p.connectionString $p.connectionInfo.connectionString
        $r.DatabaseName = '(cluster level)'
        $r.ProvisionedStorageGB = $diskGb
        $r.CapacityMode = "vCore: $sku x $(First-NonNull $ng.nodeCount 1) node(s)"
        $r.PublicNetworkAccess = $p.publicNetworkAccess
        $r.ZoneOrHA = $ha
        $r.BackupType = 'Automatic (service managed)'
        $r.Notes = 'No per-database size via ARM; only provisioned storage reported. Verify backup retention in portal.'
        $rows.Add([pscustomobject]$r)
    }
}

# ---------- export ----------
$outFile = Join-Path $OutputPath "AzureCosmos_Inventory_$ts.csv"
if ($rows.Count -gt 0) { $rows | Export-Csv -Path $outFile -NoTypeInformation -Encoding UTF8 }

Write-Host "`nDone. Rows: $($rows.Count)" -ForegroundColor Green
$rows | Group-Object ApiType | ForEach-Object { Write-Host ("  {0}: {1}" -f $_.Name, $_.Count) }
if ($rows.Count -gt 0) { Write-Host "Output: $outFile" } else { Write-Host "No Cosmos DB resources found." }
