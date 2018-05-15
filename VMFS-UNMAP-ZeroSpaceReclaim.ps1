<#
Author and customized by: Raja
	===========================================================================
	Created by: 	Raja Pamuluri
	Created on:		03/2018
    Version: v2.0
    Github Link: https://github.com/raja-converged/vmware
	===========================================================================

.DESCRIPTION
	This script connects to an ESXi host and runs an UNMAP against each datastore to reclaim space from thin file operations except the datastores of boot, snapshot
 and NFS type since those migth not support the UNMAP operations.
       Requires ESXi version >= 5.5 & PowerCLI 6.5 R1
Make sure you run this script in powershell ISE administrator mode only since we are going to change some PowerCLIconfig settings.
Also, it is highly recommended to execute this script during less IO load on datastires.
#>

cls
Write-Host "disconnecting all hosts / vCenters from this PowerCLI host:" -ForegroundColor Cyan
Disconnect-VIServer -Server * -Force -Confirm:$false

################# ESXi Host Details ###########

$HostName = Read-host "Enter the ESXi host FQDN on which we need to run the datastore UNMAP or Zero Space Reclaim: "
$Username =Read-host "Enter Username: " 
$SecurePassword = Read-Host -assecurestring "Please enter your password: " 
$BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
$vcPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)

################# vCenter Details ###########

Write-Host "Enter the .CSV File path where you want to export all datastores list ...For ex:C:\Raja\dslist.csv:" -ForegroundColor Green 
$DatastoresExportPath = [string] (Read-Host)

<#Param
(
   [Parameter(Mandatory=$true)]
   $HostName
)#>

#Set the PowerCLI configuration settings by ignoring Invalid certificate errors and also set the infinite TimeOut value for connectivity through Web for this session.
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -confirm:$false
Set-PowerCLIConfiguration -WebOperationTimeoutSeconds -1 -Scope Session -Confirm:$false

$HostConnectStatus = Connect-VIServer -Server $HostName -user $Username -password $vcPassword  
if ( $HostConnectStatus ) {
$HostEsxCli = Get-EsxCli -VMHost $HostName
$DataStoresList = Get-Datastore | Where-Object {$_.ExtensionData.Summary.Type -eq 'VMFS' -And $_.ExtensionData.Capability.PerFileThinProvisioningSupported} |where Name -NotMatch "boot|snap-|NFS"|Sort-Object Name
$DataStoresList |Export-Csv -Path $DatastoresExportPath
Write-Host "Please check the exported file and validate the list of datastores on which we are going to execute UNMAP:" -ForegroundColor Green
Write-Host "In the exported datastores list we have excluded the boot, snapshot & NFS datastores from UNMAP operation:" -ForegroundColor Green
do {
      Write-Host "Are you sure you want to continue with UNMAP on all datastores listed in exported datastores (Yes/No): " -ForegroundColor Yellow -NoNewline
        $UserConfirmation = Read-Host
         } Until ( ($UserConfirmation -eq "Yes") -or ($UserConfirmation -eq "No"))

        if ( $UserConfirmation -eq "No" ){
                Write-host "Exiting" -ForegroundColor Red
                exit
        }
ForEach ($DStore in $DataStoresList) { 
    Write-Host " ------------------------------------------------------------ " -ForegroundColor 'yellow'
    Write-Host " -- Starting Unmap on DataStore $DStore -- " -ForegroundColor 'yellow' 
    Write-Host " ------------------------------------------------------------ " -ForegroundColor 'yellow'
    $HostEsxCli.storage.vmfs.unmap(300,"$DStore", $null)
    Write-Host " ------------------------------------------------------------ " -ForegroundColor 'green'
    Write-Host " -- Unmap has completed on DataStore $DStore -- " -ForegroundColor 'green'
    Write-Host " ------------------------------------------------------------ " -ForegroundColor 'green'
    Start-Sleep -s 60
}
Write-Host "Now disconnecting all VIServers from this powershell host:" -ForegroundColor Cyan
Disconnect-VIServer -Server * -Force -Confirm:$false
}
else {
Write-Host "The credentials you have entered to connect host ESXCLI are invalid, please try again:" -ForegroundColor Yellow
}

