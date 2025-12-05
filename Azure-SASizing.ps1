    
    $folderlocation = "C:\VeeamAzureSizingReports"
    New-Item -ErrorAction Ignore -Path $folderlocation -ItemType "Directory"
    
    Connect-AzAccount
    $subscription = Get-AzSubscription
    
    foreach ($sub in $subscription) {
        Set-AzContext -SubscriptionId $sub.Id
         
    
    $resourceGroups = Get-AzResourceGroup
    $results = @()

    foreach ($rg in $resourceGroups) {
        $rgName = $rg.ResourceGroupName
        

        $storageAccounts = Get-AzStorageAccount -ResourceGroupName $rgName

        foreach ($sa in $storageAccounts) {
            $storageName = $sa.StorageAccountName
            $saId = $sa.Id

            $metric = Get-AzMetric -ResourceId $saId -MetricName "UsedCapacity" -WarningAction SilentlyContinue

            if ($metric -and $metric.Data.Count -gt 0) {
                $averageBytes = ($metric.Data | Where-Object { $_.Average -ne $null } | Select-Object -Last 1).Average
                $capacityInGB = [math]::Round($averageBytes / 1GB, 2)
            } else {
                $capacityInGB = 0
            }

            $results += [PSCustomObject]@{
                StorageAccountName  = $storageName
                UsedCapacityInGB    = $capacityInGB
                ResourceGroupName   = $rgName
                SubscriptionId      = $Sub.Id
            }
        }
    }


     #Export Results
    $filenmae = $folderlocation + "\Veeam Sizing Output - Azure Storage Accounts - " + $Sub.Name + ".csv"
    $results | export-csv $filenmae
    }
    Disconnect-AzAccount
    cls
    write-host 'Please send the files located within C:\VeeamAzureSizingReports to Veeam for review'
    pause

    
