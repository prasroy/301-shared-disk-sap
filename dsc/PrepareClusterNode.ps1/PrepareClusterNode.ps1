#
# Copyright 2020 Microsoft Corporation. All rights reserved."
#

configuration PrepareClusterNode
{
    param
    (
        [Parameter(Mandatory)]
        [String]$DomainName,

        [Parameter(Mandatory)]
        [System.Management.Automation.PSCredential]$AdminCreds,

        [Int]$ListenerProbePort1 = 49100,

        [Int]$ListenerProbePort2 = 49101,

        [Int]$ListenerPort1 = 1433,

        [Int]$ListenerPort2 = 2383
    )

    Import-DscResource -ModuleName PSDesiredStateConfiguration, ComputerManagementDsc, ActiveDirectoryDsc

    [System.Management.Automation.PSCredential]$DomainCreds = New-Object System.Management.Automation.PSCredential ("$($Admincreds.UserName)@${DomainName}", $Admincreds.Password)
   
    Node localhost
    {

        Script dscRebootFix1 {
            SetScript            = "`$taskTrigger = New-ScheduledTaskTrigger -AtStartup; `$taskAction = New-ScheduledTaskAction -Execute 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -Argument '-Command Start-Sleep 300; Restart-Computer -Force'; `$taskSettings = New-ScheduledTaskSettingsSet; `$taskCreds = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest; `$task = New-ScheduledTask -Action `$taskAction -Trigger `$taskTrigger -Settings `$taskSettings -Principal `$taskCreds; Register-ScheduledTask -TaskName 'dscRebootFix1' -InputObject `$task"
            TestScript           = "if ((Get-ScheduledTask -TaskName 'dscRebootFix1' -ErrorAction SilentlyContinue).State -ne `$null) { Stop-ScheduledTask -TaskName 'dscRebootFix1'; (Disable-ScheduledTask -TaskName 'dscRebootFix1').State -eq 'Disabled' } else { `$false }"
            GetScript            = "@{Ensure = if ((Get-ScheduledTask -TaskName 'dscRebootFix1' -ErrorAction SilentlyContinue).State -ne `$null) {'Present'} else {'Absent'}}"
        }

        WindowsFeature FC
        {
            Name = "Failover-Clustering"
            Ensure = "Present"
            DependsOn  = "[Script]dscRebootFix1"
        }

        WindowsFeature FCPS
        {
            Name = "RSAT-Clustering-PowerShell"
            Ensure = "Present"
        }

        WindowsFeature FCCmd {
            Name = "RSAT-Clustering-CmdInterface"
            Ensure = "Present"
        }

        WindowsFeature FCMgmt {
            Name = "RSAT-Clustering-Mgmt"
            Ensure = "Present"
        }

        WindowsFeature ADPS
        {
            Name = "RSAT-AD-PowerShell"
            Ensure = "Present"
        }

        WindowsFeature FS
        {
            Name = "FS-FileServer"
            Ensure = "Present"
        }

        WaitForADDomain DscForestWait 
        { 
            DomainName = $DomainName 
            Credential= $DomainCreds
            WaitForValidCredentials = $True
            WaitTimeout = 600
            RestartCount = 3
            DependsOn = "[WindowsFeature]ADPS"
        }

        Computer DomainJoin
        {
            Name = $env:COMPUTERNAME
            DomainName = $DomainName
            Credential = $DomainCreds
            DependsOn = "[WaitForADDomain]DscForestWait"
        }

        Script FirewallRuleProbePort1 {
            SetScript  = "Remove-NetFirewallRule -DisplayName 'Failover Cluster - Probe Port 1' -ErrorAction SilentlyContinue; New-NetFirewallRule -DisplayName 'Failover Cluster - Probe Port 1' -Profile Domain -Direction Inbound -Action Allow -Enabled True -Protocol 'tcp' -LocalPort ${ListenerProbePort1}"
            TestScript = "(Get-NetFirewallRule -DisplayName 'Failover Cluster - Probe Port 1' -ErrorAction SilentlyContinue | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue).LocalPort -eq ${ListenerProbePort1}"
            GetScript  = "@{Ensure = if ((Get-NetFirewallRule -DisplayName 'Failover Cluster - Probe Port 1' -ErrorAction SilentlyContinue | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue).LocalPort -eq ${ListenerProbePort1}) {'Present'} else {'Absent'}}"
            DependsOn  = "[Computer]DomainJoin"
        }

        Script FirewallRuleProbePort2 {
            SetScript  = "Remove-NetFirewallRule -DisplayName 'Failover Cluster - Probe Port 2' -ErrorAction SilentlyContinue; New-NetFirewallRule -DisplayName 'Failover Cluster - Probe Port 2' -Profile Domain -Direction Inbound -Action Allow -Enabled True -Protocol 'tcp' -LocalPort ${ListenerProbePort2}"
            TestScript = "(Get-NetFirewallRule -DisplayName 'Failover Cluster - Probe Port 2' -ErrorAction SilentlyContinue | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue).LocalPort -eq ${ListenerProbePort2}"
            GetScript  = "@{Ensure = if ((Get-NetFirewallRule -DisplayName 'Failover Cluster - Probe Port 2' -ErrorAction SilentlyContinue | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue).LocalPort -eq ${ListenerProbePort2}) {'Present'} else {'Absent'}}"
            DependsOn  = "[Script]FirewallRuleProbePort1"
        }

        LocalConfigurationManager 
        {
            ActionAfterReboot = "ContinueConfiguration"
            ConfigurationMode = "ApplyAndMonitor"
            RebootNodeIfNeeded = $True
        }

    }
}
