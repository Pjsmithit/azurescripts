    $folderlocation = "C:\VeeamAzureSizingReports"
    New-Item -ErrorAction Ignore -Path $folderlocation -ItemType "Directory"
    
    Connect-AzAccount
    $subscription = Get-AzSubscription
    
    foreach ($sub in $subscription) {
        Set-AzContext -SubscriptionId $sub.Id

        $vmlist = get-azvm
        $results = @()
        $totaldatadisk = 0
    
        foreach ($vm in $vmlist) {
            
            $vmosdisk = ((get-azvm -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name).StorageProfile).OsDisk
            $osdiskdetails = get-azdisk -ResourceGroupName $vm.ResourceGroupName -DiskName $vmosdisk.Name
            $vmdatadisk = ((get-azvm -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name).StorageProfile).DataDisks
            foreach ($datadisk in $vmdatadisk) {
                $datadiskdetails = get-azdisk -ResourceGroupName $vm.ResourceGroupName -DiskName $datadisk.Name
                $totaldatadisk = $datadiskdetails.DiskSizeGB + $totaldatadisk        
            }
       $results += [PSCustomObject]@{
          VMName  = $vm.Name
          OSDiskCapacityGB = $osdiskdetails.DiskSizeGB 
          DataDiskCapacityGB    = $totaldatadisk
          
        }
        $totaldatadisk = 0
    }
        
    #Export Results
    $filenmae = $folderlocation + "\Veeam Sizing Output - Azure VMs - " + $Sub.Name + ".csv"
    $results | export-csv $filenmae
    }
    Disconnect-AzAccount
    cls
    write-host 'Please send the files located within C:\VeeamAzureSizingReports to Veeam for review'
    pause
