Connect-AzAccount

#cls

$AllTagedResources = $null

$ForceInputExcel = $false
$ForceSetAzResourceInterventionMode = $false # FRENO
$SetNewLinkedLAW = $false # FRENO
$CrearNuevoLAW = $false    # FRENO

$InputExcel = "C:\Users\alexis\OneDrive\LAW-Link-To-Cluster\ListadoAppInsightsVersusLAWS_DD.xlsx"
$ExcelWhorkSheet = 'REMESA1' #'RUN-R2' #'REPESCA-R1'
$OutputFile = 'ListadoAppInsightsVersusLAWS.csv'

$KustoPagination = $true
$OnlyKustoInfo = $false

$KustoQuery = "resources | where type == 'microsoft.insights/components' | extend properties"

$TargetAppIfilteredByExcel = @(Import-Excel -Path $InputExcel -WorksheetName $ExcelWhorkSheet | where { $_.EJECUTAR -eq 'GO'})

$TargetAppIfilteredByExcel.Count

if($KustoPagination)
{
    # Pagination:
    $Result = $null
    $kqlResult = $null

    $kqlQuery = $KustoQuery

    $batchSize = 1000
    $skipResult = 0

    [System.Collections.Generic.List[string]]$kqlResult

    while ($true) {

        if ($skipResult -gt 0)
        {
            $graphResult = Search-AzGraph -Query $kqlQuery -First $batchSize -SkipToken $graphResult.SkipToken
        }
        else
        {
            $graphResult = Search-AzGraph -Query $kqlQuery -First $batchSize
        }

        $kqlResult += $graphResult.data

        if ($graphResult.data.Count -lt $batchSize)
        {
            break;
        }

        $skipResult += $skipResult + $batchSize
    }

    $Result = $kqlResult

}
else
{
    $Result = Search-AzGraph -Query $KustoQuery -First 1000  
}

$AllTagedResources = @($Result)

if($ForceInputExcel)
{
    $AllTagedResources = @( $AllTagedResources | where { $_.ResourceId -in @($TargetAppIfilteredByExcel.ResourceId) } )
}

$AllTagedResources | Select Name,id | ft -AutoSize ; echo "TOTAL:" ; $AllTagedResources.Count

pause

Write-Host -f Black -b White "#;AppI;ResourceId;SubscriptionId;ResourceGroup;Location;Retention;RetentionInDays;ContinousExport;workspaceResourceId"

echo "#;AppI;ResourceId;SubscriptionId;ResourceGroup;Location;Retention;RetentionInDays;ContinousExport;workspaceResourceId" > $OutputFile

$Counter = 0

foreach($AppI in $AllTagedResources)
{
    Get-AzSubscription -SubscriptionId $AppI.subscriptionId | Select-AzSubscription | Set-AzContext | Out-Null ; $Counter++
    
    $appInsightsDetails = $null ; $workspaceResourceId = $null

    $appInsightsDetails = Get-AzResource -ResourceId $AppI.id -ExpandProperties
    $workspaceResourceId = $appInsightsDetails.Properties.workspaceResourceId 
    
    if($appInsightsDetails)
    {

        if($workspaceResourceId)
        {
            Write-Host -f Red -b Yellow  "$($Counter);$($AppI.name);$($AppI.subscriptionId);$($AppI.properties.Retention);$($AppI.properties.RetentionInDays);$($workspaceResourceId)"
            echo "$($Counter);$($AppI.name);$($AppI.ResourceId);$($AppI.subscriptionId);$($AppI.resourceGroup);$($AppI.location);$($AppI.properties.Retention);$($AppI.properties.RetentionInDays);N/A;$($workspaceResourceId)" >> $OutputFile
        }
        else
        {
            $ContinuosExportEnabled = $null ; $ContinuosExportEnabled = (Get-AzApplicationInsightsContinuousExport -ResourceGroupName $AppI.resourceGroup -Name $AppI.name)

            if($ContinuosExportEnabled.Count -gt 0){ $ContinuosExportEnabled = $true }else{ $ContinuosExportEnabled = $false }

            $ExistingLAW = $null
            $ExistingLAW = Get-AzOperationalInsightsWorkspace -ResourceGroupName $AppI.resourceGroup #Get-AzResource -ResourceGroupName $AppI.resourceGroup -ResourceType "Microsoft.Insights/components" -Name $appInsightsName
                
            if($SetNewLinkedLAW)
            {

                if($ExistingLAW)
                {
                    if($ExistingLAW -is [Array])
                    {
                        # SE HAN ENCONTRADO VARIOS LAW EN EL RSG

                        echo " Hay varios $($ExistingLAW.Count) LAWs en el RSG $($AppI.resourceGroup)"

                        $ExistingLAW | ft

                        $ExistingLAW = ( $ExistingLAW | where { $_.Name -like $($($AppI.Name).Replace('-ais-','-law-')) } | Select -First 1 ) # Intento asociar AISName contra LAWName

                        if(!$ExistingLAW){ $ExistingLAW = ( $ExistingLAW | where { $_.resourceGroup -like $($($AppI.resourceGroup).Replace('-rsg-','-law-')) } | Select -First 1 )  } # Si no lo caza por AISName intento por RSGName

                        if($ExistingLAW)
                        {
                            $propertiesObject = @{  
                                "WorkspaceResourceId" = $ExistingLAW.ResourceId  
                            }  
                            if($ForceSetAzResourceInterventionMode){ Set-AzResource -ResourceId $AppI.ResourceId -Properties $propertiesObject -Force | Out-Null }
                        }

                    }
                    else
                    {
                        # SE HA ENCONTRADO UN UNICO LAW EN EL RSG
                        #echo " Se va a linkar el AppInsights $($AppI.Name) al LAW $($ExistingLAW.Name)"
                        $propertiesObject = @{  
                            "WorkspaceResourceId" = $ExistingLAW.ResourceId  
                        }  
   
                        if($ForceSetAzResourceInterventionMode){ Set-AzResource -ResourceId $AppI.ResourceId -Properties $propertiesObject -Force | Out-Null }
                    }
                }
                else
                {

                    echo " No existen LAWs en el RSG $($AppI.resourceGroup) hay que crear uno nuevo $($($AppI.Name).Replace('-ais-','-law-'))"

                    if($CrearNuevoLAW)
                    {
                        $logAnalyticsWorkspace = $null

                        if($ExcelWhorkSheet -like "*-R1")
                        {
                            $logAnalyticsWorkspaceName =$($($AppI.Name).Replace('-ais-','-law-').Replace('-appinsights-','-law-')) # Relación 1 - 1
                        }
                        else
                        {
                            $logAnalyticsWorkspaceName = $($($AppI.resourceGroup).Replace('-rsg-','-law-').Replace('-appinsights-','-law-')).Split('-') # Relación 1 - N
                            $logAnalyticsWorkspaceNameStr = "$($logAnalyticsWorkspaceName[1])-$($logAnalyticsWorkspaceName[2])-$($logAnalyticsWorkspaceName[3])-$($logAnalyticsWorkspaceName[4])-001"
                            $logAnalyticsWorkspaceName = $logAnalyticsWorkspaceNameStr
                        }

                        # Cree un nuevo recurso de Log Analytics en el mismo grupo de recursos y ubicación que el recurso de Application Insights  
                        $logAnalyticsWorkspace = (New-AzOperationalInsightsWorkspace -Location $AppI.location -Name $logAnalyticsWorkspaceName -ResourceGroupName $AppI.resourceGroup) # | Out-Null

                        # Obtenga el nuevo recurso de Log Analytics creado
                        if(!($logAnalyticsWorkspace))
                        {
                            $logAnalyticsWorkspace = (Get-AzOperationalInsightsWorkspace -Name $logAnalyticsWorkspaceName -ResourceGroupName $AppI.resourceGroup) # | Out-Null
                            #$logAnalyticsWorkspace | ft
                        }

                        $propertiesObject = @{  
                            "WorkspaceResourceId" = $logAnalyticsWorkspace.ResourceId  
                        }  
   
                        if($ForceSetAzResourceInterventionMode){ Set-AzResource -ResourceId $AppI.ResourceId -Properties $propertiesObject -Force | Out-Null }
                    }
                    else
                    {
                        echo " << SI NO SE CREA TAMPOCO SE LINKA >> "
                    }
                }            
            }

            if($ExistingLAW)
            {
                if($ForceSetAzResourceInterventionMode)
                {
                    Write-Host -f Yellow -b Blue "$($Counter);$($AppI.name);$($AppI.subscriptionId);$($AppI.properties.Retention);$($AppI.properties.RetentionInDays);LINKANDO:$($ExistingLAW.ResourceId)"
                    echo "$($Counter);$($AppI.name);$($AppI.ResourceId);$($AppI.subscriptionId);$($AppI.resourceGroup);$($AppI.location);$($AppI.properties.Retention);$($AppI.properties.RetentionInDays);$($ContinuosExportEnabled);LINKANDO:$($ExistingLAW.ResourceId)" >> $OutputFile
                }else{
                    Write-Host -f Yellow -b Blue "$($Counter);$($AppI.name);$($AppI.subscriptionId);$($AppI.properties.Retention);$($AppI.properties.RetentionInDays);PROPONER:$($ExistingLAW.ResourceId)"
                    echo "$($Counter);$($AppI.name);$($AppI.ResourceId);$($AppI.subscriptionId);$($AppI.resourceGroup);$($AppI.location);$($AppI.properties.Retention);$($AppI.properties.RetentionInDays);$($ContinuosExportEnabled);SIN-LINKAR:$($ExistingLAW.ResourceId)" >> $OutputFile
                }  
            }
            else
            {
                Write-Host -f Yellow -b Blue "$($Counter);$($AppI.name);$($AppI.subscriptionId);$($AppI.properties.Retention);$($AppI.properties.RetentionInDays);SIN-LINKAR"
                echo "$($Counter);$($AppI.name);$($AppI.ResourceId);$($AppI.subscriptionId);$($AppI.resourceGroup);$($AppI.location);$($AppI.properties.Retention);$($AppI.properties.RetentionInDays);$($ContinuosExportEnabled);SIN-LINKAR" >> $OutputFile
            }
        }
    }
    else
    {
        write-host -b red -f Yellow "$($Counter);$($AppI.name);$($AppI.ResourceId);$($AppI.subscriptionId);$($AppI.resourceGroup);$($AppI.location);$($AppI.properties.Retention);$($AppI.properties.RetentionInDays);N/A;APP-DELETED"
        echo "$($Counter);$($AppI.name);$($AppI.ResourceId);$($AppI.subscriptionId);$($AppI.resourceGroup);$($AppI.location);$($AppI.properties.Retention);$($AppI.properties.RetentionInDays);N/A;APP-DELETED" >> $OutputFile
    }

}
