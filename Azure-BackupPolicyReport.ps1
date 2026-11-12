<#
.SYNOPSIS
    Single-file report of Azure Recovery Services vault backup policies (Standard AND Enhanced),
    the workloads assigned to each, and each policy's schedule/retention settings.

.DESCRIPTION
    Uses the Azure Backup REST API (via Invoke-AzRestMethod) instead of the Get-AzRecoveryServicesBackupProtectionPolicy
    cmdlet, because the cmdlet does not reliably return Enhanced (V2) policies.

    Output: one CSV, one row per protected item (VM / SQL DB / SAP HANA DB / file share), with its policy settings.
    Policies with no assigned items are included as a row with an empty workload.

.PARAMETER SubscriptionId
    One or more subscription IDs. Default: all subscriptions visible to the account.

.PARAMETER OutputPath
    CSV file path. Default: .\AzureBackupPolicyReport-<timestamp>.csv

.EXAMPLE
    .\Get-AzBackupPolicyReport.ps1
    .\Get-AzBackupPolicyReport.ps1 -SubscriptionId "xxxxxxxx-..." -OutputPath C:\Reports\backup.csv

.NOTES
    Requires: Az.Accounts (Install-Module Az -Scope CurrentUser)
    Permissions: Backup Reader (or Reader) on the vaults.
#>
[CmdletBinding()]
param(
    [string[]]$SubscriptionId,
    [string]$OutputPath = (Join-Path (Get-Location).Path ("AzureBackupPolicyReport-{0}.csv" -f (Get-Date -Format 'yyyyMMdd-HHmm')))
)

$ErrorActionPreference = 'Stop'
$ApiVersion = '2024-10-01'

if (-not (Get-Module -ListAvailable -Name Az.Accounts)) { throw "Az.Accounts not found. Run: Install-Module Az -Scope CurrentUser" }
if (-not (Get-AzContext)) { Connect-AzAccount | Out-Null }

# ---------- helpers ----------
function Invoke-ArmList([string]$Path) {
    $all = @()
    while ($Path) {
        $r = Invoke-AzRestMethod -Method GET -Path $Path
        if ($r.StatusCode -ge 400) { throw "REST $($r.StatusCode): $($r.Content)" }
        $j = $r.Content | ConvertFrom-Json
        if ($j.value) { $all += $j.value }
        $Path = if ($j.nextLink) { $j.nextLink -replace '^https://[^/]+', '' } else { $null }
    }
    $all
}

function Format-Time($t) {
    if ($null -eq $t -or $t -eq '') { return '' }
    if ($t -is [datetime]) { return $t.ToUniversalTime().ToString('HH:mm') }
    ([datetimeoffset]::Parse([string]$t)).UtcDateTime.ToString('HH:mm')
}
function Format-Times($arr) { (@($arr) | Where-Object { $_ } | ForEach-Object { Format-Time $_ }) -join ',' }
function Format-Duration($d) { if ($d) { "$($d.count) $($d.durationType)" } else { '' } }

function Format-Schedule($sp) {
    if (-not $sp) { return '' }
    switch ($sp.schedulePolicyType) {
        'SimpleSchedulePolicyV2' {
            switch ($sp.scheduleRunFrequency) {
                'Hourly' {
                    $hs = $sp.hourlySchedule
                    return "Hourly: every $($hs.interval)h, window start $(Format-Time $hs.scheduleWindowStartTime) for $($hs.scheduleWindowDuration)h"
                }
                'Daily'  { return "Daily @ $(Format-Times $sp.dailySchedule.scheduleRunTimes)" }
                'Weekly' { return "Weekly ($($sp.weeklySchedule.scheduleRunDays -join ',')) @ $(Format-Times $sp.weeklySchedule.scheduleRunTimes)" }
                default  { return [string]$sp.scheduleRunFrequency }
            }
        }
        'SimpleSchedulePolicy' {
            $days = if ($sp.scheduleRunDays) { " ($($sp.scheduleRunDays -join ','))" } else { '' }
            return "$($sp.scheduleRunFrequency)$days @ $(Format-Times $sp.scheduleRunTimes)"
        }
        'LogSchedulePolicy' { return "Every $($sp.scheduleFrequencyInMins) min" }
        default { return [string]$sp.schedulePolicyType }
    }
}

function Format-Occurrence($s) {
    if ($s.retentionScheduleFormatType -eq 'Weekly' -and $s.retentionScheduleWeekly) {
        return "$($s.retentionScheduleWeekly.weeksOfTheMonth -join ',') $($s.retentionScheduleWeekly.daysOfTheWeek -join ',')"
    }
    if ($s.retentionScheduleDaily) {
        $d = @($s.retentionScheduleDaily.daysOfTheMonth) | ForEach-Object { if ($_.isLast) { 'Last' } else { $_.date } }
        return "day $($d -join ',')"
    }
    ''
}

function Get-RetentionParts($rp) {
    $o = [ordered]@{ Daily = ''; Weekly = ''; Monthly = ''; Yearly = '' }
    if (-not $rp) { return $o }
    if ($rp.retentionPolicyType -eq 'SimpleRetentionPolicy') {
        $o.Daily = Format-Duration $rp.retentionDuration
        return $o
    }
    if ($rp.dailySchedule)   { $o.Daily   = Format-Duration $rp.dailySchedule.retentionDuration }
    if ($rp.weeklySchedule)  { $o.Weekly  = "$(Format-Duration $rp.weeklySchedule.retentionDuration) ($($rp.weeklySchedule.daysOfTheWeek -join ','))" }
    if ($rp.monthlySchedule) { $o.Monthly = "$(Format-Duration $rp.monthlySchedule.retentionDuration) ($(Format-Occurrence $rp.monthlySchedule))" }
    if ($rp.yearlySchedule)  { $o.Yearly  = "$(Format-Duration $rp.yearlySchedule.retentionDuration) ($($rp.yearlySchedule.monthsOfYear -join ',') $(Format-Occurrence $rp.yearlySchedule))" }
    $o
}

function Get-PolicyInfo($p) {
    $pr = $p.properties
    $info = [ordered]@{
        PolicyType = 'Standard'; Schedule = ''; InstantRestoreDays = ''; TimeZone = $pr.timeZone
        DailyRetention = ''; WeeklyRetention = ''; MonthlyRetention = ''; YearlyRetention = ''
    }

    if ($pr.backupManagementType -eq 'AzureWorkload') {
        # SQL / SAP HANA: Full, Differential, Log sub-policies
        $sched = @(); $d = @(); $w = @(); $m = @(); $y = @()
        foreach ($sub in @($pr.subProtectionPolicy)) {
            $lbl = $sub.policyType
            $sched += "${lbl}: $(Format-Schedule $sub.schedulePolicy)"
            $rp = Get-RetentionParts $sub.retentionPolicy
            if ($rp.Daily)   { $d += "${lbl}: $($rp.Daily)" }
            if ($rp.Weekly)  { $w += "${lbl}: $($rp.Weekly)" }
            if ($rp.Monthly) { $m += "${lbl}: $($rp.Monthly)" }
            if ($rp.Yearly)  { $y += "${lbl}: $($rp.Yearly)" }
        }
        $info.Schedule = $sched -join ' | '
        $info.DailyRetention = $d -join ' | '; $info.WeeklyRetention = $w -join ' | '
        $info.MonthlyRetention = $m -join ' | '; $info.YearlyRetention = $y -join ' | '
        $info.TimeZone = $pr.settings.timeZone
        return [pscustomobject]$info
    }

    if ($pr.policyType -eq 'V2') { $info.PolicyType = 'Enhanced' }
    $info.Schedule = Format-Schedule $pr.schedulePolicy
    $rp = Get-RetentionParts $pr.retentionPolicy
    $info.DailyRetention = $rp.Daily; $info.WeeklyRetention = $rp.Weekly
    $info.MonthlyRetention = $rp.Monthly; $info.YearlyRetention = $rp.Yearly
    if ($null -ne $pr.instantRpRetentionRangeInDays) { $info.InstantRestoreDays = $pr.instantRpRetentionRangeInDays }
    [pscustomobject]$info
}

# ---------- main ----------
$subs = if ($SubscriptionId) { $SubscriptionId } else { (Get-AzSubscription).Id }
$rows = [System.Collections.Generic.List[object]]::new()

foreach ($sub in $subs) {
    $null = Set-AzContext -SubscriptionId $sub
    $subName = (Get-AzContext).Subscription.Name
    Write-Host "Subscription: $subName" -ForegroundColor Cyan

    $vaults = Invoke-ArmList "/subscriptions/$sub/providers/Microsoft.RecoveryServices/vaults?api-version=2023-04-01"
    foreach ($vault in $vaults) {
        $rg = ($vault.id -split '/')[4]
        Write-Host "  Vault: $($vault.name)" -ForegroundColor Yellow
        try {
            $policies = Invoke-ArmList "$($vault.id)/backupPolicies?api-version=$ApiVersion"
            $items    = Invoke-ArmList "$($vault.id)/backupProtectedItems?api-version=$ApiVersion"
        }
        catch { Write-Warning "Vault $($vault.name): $($_.Exception.Message)"; continue }

        $itemsByPolicy = $items | Group-Object { $_.properties.policyName } -AsHashTable -AsString

        foreach ($p in $policies) {
            $info = Get-PolicyInfo $p
            $mine = if ($itemsByPolicy -and $itemsByPolicy.ContainsKey($p.name)) { $itemsByPolicy[$p.name] } else { @() }

            $common = [ordered]@{
                Subscription = $subName; ResourceGroup = $rg; Vault = $vault.name; Location = $vault.location
            }
            $polCols = [ordered]@{
                PolicyName = $p.name
                PolicyType = $info.PolicyType
                Schedule = $info.Schedule
                TimeZone = $info.TimeZone
                InstantRestoreDays = $info.InstantRestoreDays
                DailyRetention = $info.DailyRetention
                WeeklyRetention = $info.WeeklyRetention
                MonthlyRetention = $info.MonthlyRetention
                YearlyRetention = $info.YearlyRetention
            }

            if (@($mine).Count -eq 0) {
                $wl = switch ($p.properties.backupManagementType) {
                    'AzureIaasVM' { 'VM' } 'AzureStorage' { 'AzureFileShare' }
                    default { $p.properties.workLoadType }
                }
                $rows.Add([pscustomobject]($common + [ordered]@{
                    WorkloadType = $wl; WorkloadName = '(no items assigned)'; Container = ''
                    ProtectionState = ''; LastBackupStatus = ''; LastBackupTime = ''; SourceResourceId = ''
                } + $polCols))
                continue
            }

            foreach ($i in $mine) {
                $ip = $i.properties
                $rows.Add([pscustomobject]($common + [ordered]@{
                    WorkloadType = $ip.workloadType
                    WorkloadName = $ip.friendlyName
                    Container = $ip.containerName
                    ProtectionState = $ip.protectionState
                    LastBackupStatus = $ip.lastBackupStatus
                    LastBackupTime = $ip.lastBackupTime
                    SourceResourceId = $ip.sourceResourceId
                } + $polCols))
            }
        }

        # Items with no policy (e.g. stopped protection, retained data)
        foreach ($i in ($items | Where-Object { -not $_.properties.policyName })) {
            $ip = $i.properties
            $rows.Add([pscustomobject][ordered]@{
                Subscription = $subName; ResourceGroup = $rg; Vault = $vault.name; Location = $vault.location
                WorkloadType = $ip.workloadType; WorkloadName = $ip.friendlyName; Container = $ip.containerName
                ProtectionState = $ip.protectionState; LastBackupStatus = $ip.lastBackupStatus
                LastBackupTime = $ip.lastBackupTime; SourceResourceId = $ip.sourceResourceId
                PolicyName = '(none - protection stopped)'; PolicyType = ''; Schedule = ''; TimeZone = ''
                InstantRestoreDays = ''; DailyRetention = ''; WeeklyRetention = ''; MonthlyRetention = ''; YearlyRetention = ''
            })
        }
    }
}

$columns = 'Subscription', 'PolicyName', 'PolicyType', 'ResourceGroup', 'Vault', 'Location',
           'WorkloadType', 'WorkloadName', 'Container', 'ProtectionState', 'LastBackupStatus', 'LastBackupTime', 'SourceResourceId',
           'Schedule', 'TimeZone', 'InstantRestoreDays', 'DailyRetention', 'WeeklyRetention', 'MonthlyRetention', 'YearlyRetention'
$rows | Select-Object $columns | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
Write-Host "`nDone. $($rows.Count) rows written to $OutputPath" -ForegroundColor Green
$rows | Group-Object PolicyType, PolicyName | Select-Object Count, Name | Format-Table -AutoSize
