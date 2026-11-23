# Azure Scripts

A collection of PowerShell scripts that gather **sizing information** and **backup configuration** from an Azure environment. The output is intended to help with backup design, configuration and capacity sizing.

All scripts are **read-only**. They query Azure Resource Manager and Azure Monitor and write results to CSV files. Nothing in your environment is changed.

## Scripts

| Script | What it collects | Output |
|---|---|---|
| `Azure-VMSizing.ps1` | Azure VMs per subscription: OS disk and total data disk capacity (GB) | `Veeam Sizing Output - Azure VMs - <subscription>.csv` |
| `Azure-SASizing-Detailed.ps1` | Storage accounts per subscription: total used capacity, Blob capacity (active and archive tiers) and File capacity (GB) | `Veeam Sizing Output - Azure Storage Accounts - <subscription>.csv` |
| `Azure-SQLSizing.ps1` | Azure SQL Database and SQL Managed Instance: servers, elastic pools, databases, used capacity, short-term (PITR) and long-term (LTR) retention | `AzureSql_Inventory_<timestamp>.csv` |
| `Azure-CosmosSizing.ps1` | Cosmos DB across all engines (NoSQL, MongoDB RU, Cassandra, Gremlin, Table, PostgreSQL, MongoDB vCore): per-database size and backup settings | `AzureCosmos_Inventory_<timestamp>.csv` |
| `Azure-BackupPolicyReport.ps1` | Recovery Services vault backup policies (Standard and Enhanced), protected items, schedules and retention | `AzureBackupPolicyReport-<timestamp>.csv` |

### Azure-VMSizing.ps1
Loops through every subscription visible to the signed-in account and reports each VM's OS disk size and the combined size of its data disks. Files are saved to `C:\VeeamAzureSizingReports`.

### Azure-SASizing-Detailed.ps1
Loops through every subscription and storage account and reads Azure Monitor capacity metrics: `UsedCapacity` for the account, `BlobCapacity` split into non-archive and archive tiers, and `FileCapacity`. Files are saved to `C:\VeeamAzureSizingReports`.

### Azure-SQLSizing.ps1
Produces one CSV with a row per database across both platforms (Azure SQL Database and SQL Managed Instance), including tier/SKU, elastic pool, max and used size, backup storage redundancy, earliest restore point, PITR retention and LTR weekly/monthly/yearly retention (shown as readable text such as "4 weeks" or "None").

Parameters:
- `-SubscriptionId` – one or more subscription IDs (default: all enabled subscriptions)
- `-OutputPath` – output folder (default: current directory)
- `-SkipMetrics` – skip Azure Monitor queries for a faster run, without used-capacity data
- `-QueryManagedInstanceSize` – connect to each Managed Instance with your Entra ID token to read per-database file sizes. This needs network access to the instance (VNet or private endpoint) and `VIEW ANY DATABASE` / `VIEW SERVER STATE` permission.

### Azure-CosmosSizing.ps1
Produces one CSV with a row per database (or per cluster for the vCore/PostgreSQL offerings). For RU-based accounts, size comes from Azure Monitor (`DataUsage`, `IndexUsage`, `DocumentCount`) per database and container. Backup settings include policy type (Periodic or Continuous), interval, retention, redundancy and continuous tier.

Parameters:
- `-SubscriptionId` – one or more subscription IDs (default: all enabled subscriptions)
- `-OutputPath` – output folder (default: current directory)
- `-SkipMetrics` – skip Azure Monitor queries (faster, no size data)

### Azure-BackupPolicyReport.ps1
Uses the Azure Backup REST API rather than the `Get-AzRecoveryServicesBackupProtectionPolicy` cmdlet, because the cmdlet does not reliably return Enhanced (V2) policies. The CSV has one row per protected item (VM, SQL DB, SAP HANA DB, file share) with its policy settings. Policies with no assigned items appear with an empty workload, and items with stopped protection are listed too.

Parameters:
- `-SubscriptionId` – one or more subscription IDs (default: all visible subscriptions)
- `-OutputPath` – CSV file path (default: `.\AzureBackupPolicyReport-<timestamp>.csv`)

## Requirements

- PowerShell 5.1 or PowerShell 7+
- The [Az PowerShell module](https://learn.microsoft.com/powershell/azure/install-azure-powershell):
  ```powershell
  Install-Module Az -Scope CurrentUser
  ```
  Individual scripts use `Az.Accounts`, `Az.Compute`, `Az.Storage`, `Az.Sql`, `Az.CosmosDB`, `Az.Monitor` and `Az.Resources`.
- An Azure account with **Reader** access on the subscriptions to scan (this includes Monitoring Reader for metrics). The backup policy report needs **Backup Reader** (or Reader) on the vaults.

## Usage

1. Open PowerShell and sign in:
   ```powershell
   Connect-AzAccount
   ```
2. Run the script you need. For example:
   ```powershell
   # VM and storage account sizing (prompts for sign-in, saves to C:\VeeamAzureSizingReports)
   .\Azure-VMSizing.ps1
   .\Azure-SASizing-Detailed.ps1

   # SQL, Cosmos DB and backup policy reports
   .\Azure-SQLSizing.ps1 -OutputPath C:\Temp
   .\Azure-CosmosSizing.ps1 -OutputPath C:\Temp
   .\Azure-BackupPolicyReport.ps1 -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
   ```
3. Review the generated CSV files and share them as required for your sizing or backup configuration review.

If script execution is blocked, you may need to adjust your execution policy for the session, for example `Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned`.

## Notes

- Capacity figures come from Azure Monitor metrics, so they reflect recent usage as reported by Azure rather than a point-in-time scan of the data.
- The VM and storage account scripts sign out of Azure (`Disconnect-AzAccount`) when they finish.
- Review the CSV output before sharing it. It contains resource names, subscription names and resource group names from your environment.

## License

Released under the [MIT License](LICENSE).
