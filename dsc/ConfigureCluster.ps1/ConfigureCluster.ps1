#
# Copyright 2020 Microsoft Corporation. All rights reserved."
#

configuration ConfigureCluster
{
    param
    (
        [Parameter(Mandatory)]
        [String]$DomainName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$AdminCreds,

        [Parameter(Mandatory)]
        [String]$ClusterName,

        [Parameter(Mandatory)]
        [String]$NamePrefix,

        [Parameter(Mandatory)]
        [Int]$VMCount,

        [Parameter(Mandatory)]
        [String]$WitnessType,

        [Parameter(Mandatory)]
        [String]$ListenerIPAddress1,

        [String]$ListenerIPAddress2 = "0.0.0.0",

        [Int]$ListenerProbePort1 = 49100,

        [Int]$ListenerProbePort2 = 49101,

        [String]$ClusterGroup = "${ClusterName}-group",

        [String]$ClusterIPName = "IP Address ${ListenerIPAddress1}",

        [Int]$DataDiskSizeGB = 1023,

        [String]$DataDiskDriveLetter = "F",

        [String]$WitnessStorageName,

        [System.Management.Automation.PSCredential]$WitnessStorageKey
    )

    Import-DscResource -ModuleName PSDesiredStateConfiguration, ComputerManagementDsc, ActiveDirectoryDsc

    [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("$($AdminCreds.UserName)@${DomainName}", $AdminCreds.Password)

    [System.Collections.ArrayList]$Nodes = @()
    For ($count = 1; $count -lt $VMCount; $count++) {
        $Nodes.Add($NamePrefix + $Count.ToString())
    }

    If ($ListenerIPAddress2 -ne "0.0.0.0") {
        $ClusterSetupOptions = "-StaticAddress ${ListenerIPAddress2}"
    } else {
        $ClusterSetupOptions = ""
    }

    Node localhost
    {

        WindowsFeature FC {
            Name   = "Failover-Clustering"
            Ensure = "Present"
        }

        WindowsFeature FCPS {
            Name      = "RSAT-Clustering-PowerShell"
            Ensure    = "Present"
            DependsOn = "[WindowsFeature]FC"
        }

        WindowsFeature FCCmd {
            Name      = "RSAT-Clustering-CmdInterface"
            Ensure    = "Present"
            DependsOn = "[WindowsFeature]FCPS"
        }

        WindowsFeature FCMgmt {
            Name = "RSAT-Clustering-Mgmt"
            Ensure = "Present"
            DependsOn = "[WindowsFeature]FCCmd"
        }

        WindowsFeature ADPS {
            Name      = "RSAT-AD-PowerShell"
            Ensure    = "Present"
            DependsOn = "[WindowsFeature]FCMgmt"
        }

        WindowsFeature FS
        {
            Name = "FS-FileServer"
            Ensure = "Present"
            DependsOn = "[WindowsFeature]ADPS"
        }

        WaitForADDomain DscForestWait 
        { 
            DomainName              = $DomainName 
            Credential              = $DomainCreds
            WaitForValidCredentials = $True
            WaitTimeout             = 600
            RestartCount            = 3
            DependsOn               = "[WindowsFeature]FS"
        }

        Computer DomainJoin
        {
            Name       = $env:COMPUTERNAME
            DomainName = $DomainName
            Credential = $DomainCreds
            DependsOn  = "[WaitForADDomain]DscForestWait"
        }

        Script CreateCluster {
            SetScript            = "New-Cluster -Name ${ClusterName} -Node ${env:COMPUTERNAME} -NoStorage ${ClusterSetupOptions}"
            TestScript           = "(Get-Cluster -ErrorAction SilentlyContinue).Name -eq '${ClusterName}'"
            GetScript            = "@{Ensure = if ((Get-Cluster -ErrorAction SilentlyContinue).Name -eq '${ClusterName}') {'Present'} else {'Absent'}}"
            PsDscRunAsCredential = $DomainCreds
            DependsOn            = "[Computer]DomainJoin"
        }

        Script ClusterIPAddress {
            SetScript  = "Get-ClusterGroup -Name 'Cluster Group' -ErrorAction SilentlyContinue | Get-ClusterResource | Where-Object ResourceType -eq 'IP Address' -ErrorAction SilentlyContinue | Set-ClusterParameter -Name ProbePort ${ListenerProbePort2}; `$global:DSCMachineStatus = 1"
            TestScript = "if ('${ListenerIpAddress2}' -eq '0.0.0.0') { `$true } else { (Get-ClusterGroup -Name 'Cluster Group' -ErrorAction SilentlyContinue | Get-ClusterResource | Where-Object ResourceType -eq 'IP Address' -ErrorAction SilentlyContinue | Get-ClusterParameter -Name ProbePort).Value -eq ${ListenerProbePort2}}"
            GetScript  = "@{Ensure = if ('${ListenerIpAddress2}' -eq '0.0.0.0') { 'Present' } elseif ((Get-ClusterGroup -Name 'Cluster Group' -ErrorAction SilentlyContinue | Get-ClusterResource | Where-Object ResourceType -eq 'IP Address' -ErrorAction SilentlyContinue | Get-ClusterParameter -Name ProbePort).Value -eq ${ListenerProbePort2}) {'Present'} else {'Absent'}}"
            DependsOn  = "[Script]CreateCluster"
        }

        foreach ($Node in $Nodes) {
            Script "AddClusterNode_${Node}" {
                SetScript            = "Add-ClusterNode -Name ${Node} -NoStorage"
                TestScript           = "'${Node}' -in (Get-ClusterNode).Name"
                GetScript            = "@{Ensure = if ('${Node}' -in (Get-ClusterNode).Name) {'Present'} else {'Absent'}}"
                PsDscRunAsCredential = $DomainCreds
                DependsOn            = "[Script]ClusterIPAddress"
            }
        }

        Script AddClusterDisks {
            SetScript  = "Get-Disk | Where-Object PartitionStyle -eq 'RAW' | Initialize-Disk -PartitionStyle GPT -PassThru -ErrorAction SilentlyContinue | Sort-Object -Property Number | % { [char]`$NextDriveLetter = (1 + [int](([int][char]'$DataDiskDriveLetter'..[int][char]'Z') | % { `$Disk = [char]`$_ ; Get-Partition -DriveLetter `$Disk -ErrorAction SilentlyContinue} | Select-Object -Last 1).DriveLetter); If ( `$NextDriveLetter -eq [char]1 ) { `$NextDriveLetter = '$DataDiskDriveLetter' }; New-Partition -InputObject `$_ -NewDriveLetter `$NextDriveLetter -UseMaximumSize  } | % { `$ClusterDisk = Format-Volume -DriveLetter `$(`$_.DriveLetter) -NewFilesystemLabel Cluster_Disk_`$(`$_.DriveLetter) -FileSystem NTFS -AllocationUnitSize 65536 -UseLargeFRS -Confirm:`$false | Get-Partition | Get-Disk | Add-ClusterDisk ; `$ClusterDisk.Name=`"Cluster_Disk_`$(`$_.DriveLetter)`" ; Start-ClusterResource -Name Cluster_Disk_`$(`$_.DriveLetter) }"
            TestScript = "(Get-Disk | Where-Object PartitionStyle -eq 'RAW').Count -eq 0"
            GetScript  = "@{Ensure = if ((Get-Disk | Where-Object PartitionStyle -eq 'RAW').Count -eq 0) {'Present'} else {'Absent'}}"
            DependsOn  = "[Script]CreateCluster"
        }

        Script ClusterWitness {
            SetScript  = "if ('${WitnessType}' -eq 'Cloud') { Set-ClusterQuorum -CloudWitness -AccountName ${WitnessStorageName} -AccessKey $($WitnessStorageKey.GetNetworkCredential().Password) } else { Set-ClusterQuorum -DiskWitness `$((Get-ClusterGroup -Name 'Available Storage' | Get-ClusterResource | ? ResourceType -eq 'Physical Disk' | Sort-Object Name | Select-Object -Last 1).Name) }"
            TestScript = "((Get-ClusterQuorum).QuorumResource).Count -gt 0"
            GetScript  = "@{Ensure = if (((Get-ClusterQuorum).QuorumResource).Count -gt 0) {'Present'} else {'Absent'}}"
            DependsOn  = "[Script]AddClusterDisks"
        }

        Script IncreaseClusterTimeouts {
            SetScript  = "(Get-Cluster).SameSubnetDelay = 2000; (Get-Cluster).SameSubnetThreshold = 15; (Get-Cluster).CrossSubnetDelay = 3000; (Get-Cluster).CrossSubnetThreshold = 15"
            TestScript = "(Get-Cluster).SameSubnetDelay -eq 2000 -and (Get-Cluster).SameSubnetThreshold -eq 15 -and (Get-Cluster).CrossSubnetDelay -eq 3000 -and (Get-Cluster).CrossSubnetThreshold -eq 15"
            GetScript  = "@{Ensure = if ((Get-Cluster).SameSubnetDelay -eq 2000 -and (Get-Cluster).SameSubnetThreshold -eq 15 -and (Get-Cluster).CrossSubnetDelay -eq 3000 -and (Get-Cluster).CrossSubnetThreshold -eq 15) {'Present'} else {'Absent'}}"
            DependsOn  = "[Script]ClusterWitness"
        }
        
        Script AddClusterGroup {
            SetScript  = "Add-ClusterGroup -Name '$ClusterGroup'"
            TestScript = "'${ClusterGroup}' -in (Get-ClusterGroup).Name"
            GetScript  = "@{Ensure = if ('${ClusterGroup}' -in (Get-ClusterGroup).Name) {'Present'} else {'Absent'}}"
            DependsOn  = "[Script]IncreaseClusterTimeouts"
        }

        Script AddClusterIPAddress {
            SetScript  = "Add-ClusterResource -Name '${ClusterIpName}' -Group '${ClusterGroup}' -ResourceType 'IP Address' | Set-ClusterParameter -Multiple `@`{Address='${ListenerIpAddress1}';ProbePort=${ListenerProbePort1};SubnetMask='255.255.255.255';Network=(Get-ClusterNetwork)[0].Name;OverrideAddressMatch=1;EnableDhcp=0`}"
            TestScript = "'${ClusterIPName}' -in (Get-ClusterResource).Name"
            GetScript  = "@{Ensure = if ('${ClusterIPName}' -in (Get-ClusterResource).Name) {'Present'} else {'Absent'}}"
            DependsOn  = "[Script]AddClusterGroup"
        }

        Script StartClusterGroup {
            SetScript  = "Start-ClusterGroup -Name '$ClusterGroup'"
            TestScript = "(Get-ClusterGroup -Name '$ClusterGroup').State -eq 'Online'"
            GetScript  = "@{Ensure = if ((Get-ClusterGroup -Name '$ClusterGroup').State -eq 'Online') {'Present'} else {'Absent'}}"
            DependsOn  = "[Script]AddClusterIPAddress"
        }
        
        Script FirewallRuleProbePort1 {
            SetScript  = "Remove-NetFirewallRule -DisplayName 'Failover Cluster - Probe Port 1' -ErrorAction SilentlyContinue; New-NetFirewallRule -DisplayName 'Failover Cluster - Probe Port 1' -Profile Domain -Direction Inbound -Action Allow -Enabled True -Protocol 'tcp' -LocalPort ${ListenerProbePort1}"
            TestScript = "(Get-NetFirewallRule -DisplayName 'Failover Cluster - Probe Port 1' -ErrorAction SilentlyContinue | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue).LocalPort -eq ${ListenerProbePort1}"
            GetScript  = "@{Ensure = if ((Get-NetFirewallRule -DisplayName 'Failover Cluster - Probe Port 1' -ErrorAction SilentlyContinue | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue).LocalPort -eq ${ListenerProbePort1}) {'Present'} else {'Absent'}}"
            DependsOn  = "[Script]StartClusterGroup"
        }

        Script FirewallRuleProbePort2 {
            SetScript  = "Remove-NetFirewallRule -DisplayName 'Failover Cluster - Probe Port 2' -ErrorAction SilentlyContinue; New-NetFirewallRule -DisplayName 'Failover Cluster - Probe Port 2' -Profile Domain -Direction Inbound -Action Allow -Enabled True -Protocol 'tcp' -LocalPort ${ListenerProbePort2}"
            TestScript = "(Get-NetFirewallRule -DisplayName 'Failover Cluster - Probe Port 2' -ErrorAction SilentlyContinue | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue).LocalPort -eq ${ListenerProbePort2}"
            GetScript  = "@{Ensure = if ((Get-NetFirewallRule -DisplayName 'Failover Cluster - Probe Port 2' -ErrorAction SilentlyContinue | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue).LocalPort -eq ${ListenerProbePort2}) {'Present'} else {'Absent'}}"
            DependsOn  = "[Script]FirewallRuleProbePort1"
        }

        LocalConfigurationManager {
            RebootNodeIfNeeded = $True
        }

    }
}
