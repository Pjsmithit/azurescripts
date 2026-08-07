    
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
            
            
            #Collect Total Storage Account Capacity
            $metric = Get-AzMetric -ResourceId $saId -MetricName "UsedCapacity" -WarningAction SilentlyContinue
            if ($metric -and $metric.Data.Count -gt 0) {
                $saaverageBytes = ($metric.Data | Where-Object { $_.Average -ne $null } | Select-Object -Last 1).Average
                $sacapacityInGB = [math]::Round($saaverageBytes / 1GB, 2)
            } else {
                $sacapacityInGB = 0
            }
            #End SA Capacity Collection
            
            
            #Collect Blob Capacity and Detail Active and Archive Tiers
            $saidblob = $sa.id += "/blobServices/default"
            $filter = [string](New-AzMetricFilter -Dimension "Tier" -Operator ne -Value "Archive")
            $blobmetric = Get-AzMetric -ResourceId $saidblob -MetricName "BlobCapacity" -TimeGrain 01:00:00 -AggregationType Average -MetricFilter $filter
            

            if ($blobmetric -and $blobmetric.Data.Count -gt 0) {
                $blobaverageBytes = ($blobmetric.Data | Where-Object { $_.Average -ne $null } | Select-Object -Last 1).Average
                $blobcapacityInGB = [math]::Round($blobaverageBytes / 1GB, 2)
            } else {
                $blobcapacityInGB = 0
            }

            $filtera = [string](New-AzMetricFilter -Dimension "Tier" -Operator eq -Value "Archive")
            $blobarchivemetric = Get-AzMetric -ResourceId $saidblob -MetricName "BlobCapacity" -TimeGrain 01:00:00 -AggregationType Average -MetricFilter $filtera
            

            if ($blobarchivemetric -and $blobarchivemetric.Data.Count -gt 0) {
                $blobarchiveaverageBytes = ($blobarchivemetric.Data | Where-Object { $_.Average -ne $null } | Select-Object -Last 1).Average
                $blobarchivecapacityInGB = [math]::Round($blobarchiveaverageBytes / 1GB, 2)
            } else {
                $blobarchivecapacityInGB = 0
            }
            #End Blob Capacity Collection

            #Collect File Sizing
            $saidfile = $said += "/fileServices/default"
            $filemetric = Get-AzMetric -ResourceId $saidfile -MetricName "FileCapacity"
            
            if ($filemetric -and $filemetric.Data.Count -gt 0) {
                $fileaverageBytes = ($filemetric.Data | Where-Object { $_.Average -ne $null } | Select-Object -Last 1).Average
                $filecapacityInGB = [math]::Round($fileaverageBytes / 1GB, 2)
            } else {
                $filecapacityInGB = 0
            }
            #End File Capacity Collection

                        
            #Create Row for export
            $results += [PSCustomObject]@{
                StorageAccountName  = $storageName
                UsedCapacityInGB    = $sacapacityInGB
                BlobActiveCapacity  = $blobcapacityInGB
                BlobArchiveCapacity = $blobarchivecapacityInGB
                FileCapacity        = $filecapacityInGB
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