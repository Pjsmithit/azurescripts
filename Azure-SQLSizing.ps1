<#
.SYNOPSIS
    Inventory of Azure SQL PaaS (SQL Database + SQL Managed Instance): servers, databases,
    elastic pools, used capacity, and short-term / long-term backup configuration.

.DESCRIPTION
    Scans one or all enabled subscriptions and writes ONE CSV (AzureSql_Inventory_<ts>.csv)
    with a row per database: Platform (Azure SQL Database (PaaS) / SQL Managed Instance),
    server/instance name + FQDN, sizes, short-term (PITR) and long-term (LTR) retention.
    LTR values are shown as readable text ("4 weeks", "None"); Azure returns them as ISO 8601
    durations (P4W, P12M, P5Y; PT0S = zero = no long-term retention configured).

    Used capacity comes from Azure Monitor metrics (last 1 hour, max value):
      SQL DB: 'storage' (used data space), 'allocated_data_storage'
      SQL MI: 'storage_space_used_mb' (instance level)

.PARAMETER SubscriptionId
    One or more subscription IDs. Default: all enabled subscriptions.

.PARAMETER OutputPath
    Folder for CSV output. Default: current directory.

.PARAMETER SkipMetrics
    Skip Azure Monitor metric queries (faster, no used-capacity data).

.NOTES
    Requires: Az.Accounts, Az.Sql, Az.Monitor (Az.Resources optional)
    Permissions: Reader on the subscriptions is sufficient (Monitoring Reader for metrics,
    included in Reader).
    Run: Connect-AzAccount ; .\Get-AzureSqlInventory.ps1 -OutputPath C:\Temp
#>
[CmdletBinding()]
param(
    [string[]]$SubscriptionId,
    [string]$OutputPath = (Get-Location).Path,
    [switch]$SkipMetrics,
    # Connect to each Managed Instance with your Entra ID token and read per-database file sizes
    # (Azure Monitor has no per-database size metric for MI). Needs network access to the MI
    # (VNet/private endpoint) and a login with VIEW ANY DATABASE / VIEW SERVER STATE.
    [switch]$QueryManagedInstanceSize
)

$ErrorActionPreference = 'Continue'
$WarningPreference     = 'SilentlyContinue'

foreach ($m in 'Az.Accounts', 'Az.Sql', 'Az.Monitor') {
    if (-not (Get-Module -ListAvailable -Name $m)) { throw "Missing module $m. Install-Module Az -Scope CurrentUser" }
    Import-Module $m -ErrorAction Stop
}
if (-not (Get-AzContext)) { Connect-AzAccount | Out-Null }
if (-not (Test-Path $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath | Out-Null }
$ts = Get-Date -Format 'yyyyMMdd_HHmmss'

# ---------- helpers ----------
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
function ToGB($bytes) { if ($null -eq $bytes) { $null } else { [math]::Round($bytes / 1GB, 3) } }

$script:PlatSql = 'Azure SQL Database (PaaS)'
$script:PlatMi  = 'SQL Managed Instance'

# Returns @{ DbName = @{DataGB=..; LogGB=..} } via T-SQL (sys.master_files = allocated file size)
function Get-MiDbSizes {
    param([string]$Fqdn)
    $out = @{}
    try {
        $tok = (Get-AzAccessToken -ResourceUrl 'https://database.windows.net/' -ErrorAction Stop).Token
        if ($tok -is [System.Security.SecureString]) { $tok = [System.Net.NetworkCredential]::new('', $tok).Password }
        $cn = New-Object System.Data.SqlClient.SqlConnection("Server=tcp:$Fqdn,1433;Database=master;Encrypt=True;Connection Timeout=15")
        $cn.AccessToken = $tok
        $cn.Open()
        $cmd = $cn.CreateCommand()
        $cmd.CommandTimeout = 60
        $cmd.CommandText = @"
SELECT d.name,
       SUM(CASE WHEN f.type = 0 THEN CAST(f.size AS bigint) END) * 8 / 1048576.0 AS data_gb,
       SUM(CASE WHEN f.type = 1 THEN CAST(f.size AS bigint) END) * 8 / 1048576.0 AS log_gb
FROM sys.master_files f JOIN sys.databases d ON d.database_id = f.database_id
WHERE d.database_id > 4
GROUP BY d.name
"@
        $rd = $cmd.ExecuteReader()
        while ($rd.Read()) {
            $out[$rd.GetString(0)] = @{
                DataGB = if ($rd.IsDBNull(1)) { $null } else { [math]::Round([double]$rd.GetValue(1), 3) }
                LogGB  = if ($rd.IsDBNull(2)) { $null } else { [math]::Round([double]$rd.GetValue(2), 3) }
            }
        }
        $rd.Close(); $cn.Close()
    } catch { Write-Warning "MI size query failed for $Fqdn : $($_.Exception.Message)" }
    return $out
}

# ISO 8601 duration -> readable text. P4W = 4 weeks, P12M = 12 months, P5Y = 5 years, PT0S = zero (not configured)
function ConvertFrom-IsoDuration($v) {
    if ([string]::IsNullOrWhiteSpace($v) -or $v -match '^PT?0[SDWMY]$') { return 'None' }
    if ($v -match '^P(\d+)([DWMY])$') {
        $u = @{ D = 'day'; W = 'week'; M = 'month'; Y = 'year' }[$Matches[2]]
        $n = [int]$Matches[1]
        return "$n $u$(if ($n -ne 1) {'s'})"
    }
    return $v
}
function Format-Ltr($p) {
    if (-not $p) { return @{ W = 'Unknown'; M = 'Unknown'; Y = 'Unknown'; WoY = $null } }
    @{ W = ConvertFrom-IsoDuration $p.WeeklyRetention; M = ConvertFrom-IsoDuration $p.MonthlyRetention
       Y = ConvertFrom-IsoDuration $p.YearlyRetention; WoY = $p.WeekOfYear }
}

# ---------- result collections ----------
$servers = [System.Collections.Generic.List[object]]::new()
$pools   = [System.Collections.Generic.List[object]]::new()
$dbs     = [System.Collections.Generic.List[object]]::new()
$mis     = [System.Collections.Generic.List[object]]::new()
$midbs   = [System.Collections.Generic.List[object]]::new()

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

    # ===== Azure SQL Database logical servers =====
    foreach ($srv in (Get-AzSqlServer -ErrorAction SilentlyContinue)) {
        Write-Host "  SQL server: $($srv.ServerName)"
        $servers.Add([pscustomobject]@{
            Subscription      = $sub.Name
            SubscriptionId    = $sub.Id
            ResourceGroup     = $srv.ResourceGroupName
            ServerName        = $srv.ServerName
            Location          = $srv.Location
            FQDN              = $srv.FullyQualifiedDomainName
            Version           = $srv.ServerVersion
            PublicAccess      = $srv.PublicNetworkAccess
            MinTlsVersion     = $srv.MinimalTlsVersion
        })

        foreach ($pool in (Get-AzSqlElasticPool -ResourceGroupName $srv.ResourceGroupName -ServerName $srv.ServerName -ErrorAction SilentlyContinue)) {
            $pools.Add([pscustomobject]@{
                Subscription  = $sub.Name
                ResourceGroup = $srv.ResourceGroupName
                ServerName    = $srv.ServerName
                PoolName      = $pool.ElasticPoolName
                Edition       = $pool.Edition
                Sku           = $pool.SkuName
                Capacity      = $pool.Capacity
                MaxSizeGB     = [math]::Round($pool.StorageMB / 1024, 3)
                DbCount       = $null
                State         = $pool.State
                ZoneRedundant = $pool.ZoneRedundant
            })
        }

        foreach ($db in (Get-AzSqlDatabase -ResourceGroupName $srv.ResourceGroupName -ServerName $srv.ServerName -ErrorAction SilentlyContinue |
                         Where-Object DatabaseName -ne 'master')) {
            Write-Host "    DB: $($db.DatabaseName)"
            $rid  = $db.ResourceId
            $used = Get-LastMetric $rid 'storage'
            $alloc = Get-LastMetric $rid 'allocated_data_storage'

            $pitr = $null; $ltr = $null
            try { $pitr = Get-AzSqlDatabaseBackupShortTermRetentionPolicy -ResourceGroupName $srv.ResourceGroupName -ServerName $srv.ServerName -DatabaseName $db.DatabaseName -ErrorAction Stop } catch { Write-Verbose "PITR: $($_.Exception.Message)" }
            try { $ltr  = Get-AzSqlDatabaseBackupLongTermRetentionPolicy  -ResourceGroupName $srv.ResourceGroupName -ServerName $srv.ServerName -DatabaseName $db.DatabaseName -ErrorAction Stop } catch { Write-Verbose "LTR: $($_.Exception.Message)" }
            $l = Format-Ltr $ltr

            $dbs.Add([pscustomobject]@{
                Platform             = $script:PlatSql
                Subscription         = $sub.Name
                ResourceGroup        = $srv.ResourceGroupName
                ServerName           = $srv.ServerName
                DatabaseName         = $db.DatabaseName
                Location             = $db.Location
                Status               = $db.Status
                Edition              = $db.Edition
                ServiceObjective     = $db.CurrentServiceObjectiveName
                ElasticPool          = $db.ElasticPoolName
                Capacity             = $db.Capacity
                Family               = $db.Family
                MaxSizeGB            = ToGB $db.MaxSizeBytes
                UsedSizeGB           = ToGB $used
                AllocatedSizeGB      = ToGB $alloc
                UsedPct              = if ($used -and $db.MaxSizeBytes) { [math]::Round(100 * $used / $db.MaxSizeBytes, 1) } else { $null }
                ZoneRedundant        = $db.ZoneRedundant
                ReadScale            = $db.ReadScale
                LicenseType          = $db.LicenseType
                CreationDate         = $db.CreationDate
                EarliestRestoreDate  = $db.EarliestRestoreDate
                BackupStorageRedundancy = $db.CurrentBackupStorageRedundancy
                PITR_RetentionDays   = $pitr.RetentionDays
                PITR_DiffBackupHours = $pitr.DiffBackupIntervalInHours
                LTR_Weekly           = $l.W
                LTR_Monthly          = $l.M
                LTR_Yearly           = $l.Y
                LTR_WeekOfYear       = $l.WoY
            })
        }
    }

    # ===== Azure SQL Managed Instances =====
    foreach ($mi in (Get-AzSqlInstance -ErrorAction SilentlyContinue)) {
        Write-Host "  Managed Instance: $($mi.ManagedInstanceName)"
        $usedMb = Get-LastMetric $mi.Id 'storage_space_used_mb'
        $mis.Add([pscustomobject]@{
            Subscription      = $sub.Name
            ResourceGroup     = $mi.ResourceGroupName
            InstanceName      = $mi.ManagedInstanceName
            Location          = $mi.Location
            FQDN              = $mi.FullyQualifiedDomainName
            Tier              = $mi.Sku.Tier
            Sku               = $mi.Sku.Name
            vCores            = $mi.VCores
            LicenseType       = $mi.LicenseType
            ReservedStorageGB = $mi.StorageSizeInGB
            UsedStorageGB     = if ($null -ne $usedMb) { [math]::Round($usedMb / 1024, 3) } else { $null }
            UsedPct           = if ($usedMb -and $mi.StorageSizeInGB) { [math]::Round(100 * ($usedMb / 1024) / $mi.StorageSizeInGB, 1) } else { $null }
            ZoneRedundant     = $mi.ZoneRedundant
            BackupStorageRedundancy = $mi.BackupStorageRedundancy
            PublicDataEndpoint = $mi.PublicDataEndpointEnabled
            MinTlsVersion     = $mi.MinimalTlsVersion
            State             = $mi.ProvisioningState
        })

        $miSizes = @{}
        if ($QueryManagedInstanceSize) { $miSizes = Get-MiDbSizes -Fqdn $mi.FullyQualifiedDomainName }

        foreach ($mdb in (Get-AzSqlInstanceDatabase -ResourceGroupName $mi.ResourceGroupName -InstanceName $mi.ManagedInstanceName -ErrorAction SilentlyContinue)) {
            $sz = $miSizes[$mdb.Name]
            Write-Host "    MI DB: $($mdb.Name)"
            $pitr = $null; $ltr = $null
            try { $pitr = Get-AzSqlInstanceDatabaseBackupShortTermRetentionPolicy -ResourceGroupName $mi.ResourceGroupName -InstanceName $mi.ManagedInstanceName -DatabaseName $mdb.Name -ErrorAction Stop } catch { Write-Verbose "MI PITR: $($_.Exception.Message)" }
            try { $ltr  = Get-AzSqlInstanceDatabaseBackupLongTermRetentionPolicy  -ResourceGroupName $mi.ResourceGroupName -InstanceName $mi.ManagedInstanceName -DatabaseName $mdb.Name -ErrorAction Stop } catch { Write-Verbose "MI LTR: $($_.Exception.Message)" }
            $l = Format-Ltr $ltr

            $midbs.Add([pscustomobject]@{
                Platform             = $script:PlatMi
                Subscription         = $sub.Name
                ResourceGroup        = $mi.ResourceGroupName
                InstanceName         = $mi.ManagedInstanceName
                DatabaseName         = $mdb.Name
                Status               = $mdb.Status
                Tier                 = $mi.Sku.Tier
                Sku                  = $mi.Sku.Name
                InstanceStorageGB    = $mi.StorageSizeInGB
                DataFileSizeGB       = $sz.DataGB
                LogFileSizeGB        = $sz.LogGB
                BackupStorageRedundancy = $mi.BackupStorageRedundancy
                Collation            = $mdb.Collation
                CreationDate         = $mdb.CreationDate
                EarliestRestorePoint = $mdb.EarliestRestorePoint
                PITR_RetentionDays   = $pitr.RetentionDays
                PITR_DiffBackupHours = $pitr.DiffBackupIntervalInHours
                LTR_Weekly           = $l.W
                LTR_Monthly          = $l.M
                LTR_Yearly           = $l.Y
                LTR_WeekOfYear       = $l.WoY
            })
        }
    }
}

# ---------- single combined output (both platforms) ----------
$srvLookup = @{}; foreach ($s in $servers) { $srvLookup[$s.ServerName] = $s }
$miLookup  = @{}; foreach ($m in $mis)     { $miLookup[$m.InstanceName] = $m }

$all = [System.Collections.Generic.List[object]]::new()
foreach ($d in $dbs) {
    $s = $srvLookup[$d.ServerName]
    $all.Add([pscustomobject][ordered]@{
        Platform = $d.Platform; Subscription = $d.Subscription; ResourceGroup = $d.ResourceGroup
        Location = $d.Location; ServerName = $d.ServerName; ServerFQDN = $s.FQDN
        DatabaseName = $d.DatabaseName; Status = $d.Status
        Tier = $d.Edition; Sku = $d.ServiceObjective; ElasticPool = $d.ElasticPool
        DbMaxSizeGB = $d.MaxSizeGB; DbUsedSizeGB = $d.UsedSizeGB; DbAllocatedSizeGB = $d.AllocatedSizeGB
        DbUsedPct = $d.UsedPct
        InstanceReservedStorageGB = $null; InstanceUsedStorageGB = $null
        BackupStorageRedundancy = $d.BackupStorageRedundancy; EarliestRestore = $d.EarliestRestoreDate
        PITR_RetentionDays = $d.PITR_RetentionDays; PITR_DiffBackupHours = $d.PITR_DiffBackupHours
        LTR_Weekly = $d.LTR_Weekly; LTR_Monthly = $d.LTR_Monthly; LTR_Yearly = $d.LTR_Yearly; LTR_WeekOfYear = $d.LTR_WeekOfYear
    })
}
foreach ($d in $midbs) {
    $m   = $miLookup[$d.InstanceName]
    $tot = if ($null -ne $d.DataFileSizeGB) { [math]::Round($d.DataFileSizeGB + [double]$d.LogFileSizeGB, 3) } else { $null }
    $all.Add([pscustomobject][ordered]@{
        Platform = $d.Platform; Subscription = $d.Subscription; ResourceGroup = $d.ResourceGroup
        Location = $m.Location; ServerName = $d.InstanceName; ServerFQDN = $m.FQDN
        DatabaseName = $d.DatabaseName; Status = $d.Status
        Tier = $d.Tier; Sku = $d.Sku; ElasticPool = $null
        DbMaxSizeGB = $null; DbUsedSizeGB = $null; DbAllocatedSizeGB = $tot   # MI: data+log file size (needs -QueryManagedInstanceSize)
        DbUsedPct = $null
        InstanceReservedStorageGB = $d.InstanceStorageGB; InstanceUsedStorageGB = $m.UsedStorageGB
        BackupStorageRedundancy = $d.BackupStorageRedundancy; EarliestRestore = $d.EarliestRestorePoint
        PITR_RetentionDays = $d.PITR_RetentionDays; PITR_DiffBackupHours = $d.PITR_DiffBackupHours
        LTR_Weekly = $d.LTR_Weekly; LTR_Monthly = $d.LTR_Monthly; LTR_Yearly = $d.LTR_Yearly; LTR_WeekOfYear = $d.LTR_WeekOfYear
    })
}

$outFile = Join-Path $OutputPath "AzureSql_Inventory_$ts.csv"
$all | Export-Csv -Path $outFile -NoTypeInformation -Encoding UTF8

$totUsed = ($dbs | Measure-Object UsedSizeGB -Sum).Sum
$totMi   = ($mis | Measure-Object UsedStorageGB -Sum).Sum
Write-Host "`nDone. SQL DB servers: $($servers.Count) | SQL DBs: $($dbs.Count) | Managed Instances: $($mis.Count) | MI DBs: $($midbs.Count)" -ForegroundColor Green
Write-Host ("Used capacity - SQL DB: {0:N2} GB | SQL MI: {1:N2} GB" -f $totUsed, $totMi) -ForegroundColor Green
Write-Host "Output: $outFile"
