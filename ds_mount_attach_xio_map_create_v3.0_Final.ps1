
################# User Agreement ###########
<# 
Author and customized by: Raja

<#	
	===========================================================================
	Created by: 	Raja Pamuluri
	Created on:		1/2018
    Version: v3.0
    Github Link: https://github.com/raja-converged/vmware
		===========================================================================
	.DESCRIPTION
		PowerShell Module to help to automate the end to eganization and you can modify or customize the script as you need.
		* Tested against PowerShell 5.0 nd storage allocation activity if you have VMware as hypervisor and XIO storage as SAN system.
This script in first part, will perform the XIO volume creation at XIO storage array level that includes capacity pre-check, volume creation, mapping to given initiator grups and then validate.
In the second part, it will perform the datastore creation & validation steps at vSphere cluster level and the datastore name will be same as volume name at XIO level.
	.NOTES
		Make sure you understand the impact of creating new volume with higher capacity at XIO level volume and creating the same as datastore at vSphere level. At the same time make sure you follow the process as per your or
		* Tested against VMware PowerCLI 6.5.1 build 5377412
		* Tested against vCenter 6.0 / 5.5
		* Tested against ESXi 5.5/6.0
        * Tested against XIOS v4.0.25 and XMS v4.2.2-20 with REST APT v2.0
        * Tested against XIO Powershell Module XtremIO.Utils v1.4.0 and you can download this from below GitHub link
          https://github.com/mtboren/XtremIO.Utils/tree/master/XtremIO.Utils

For any modifications or suggestions please do contact Raja Pamuluri at raja.converged@gmail.com

#>
Write-Host "This script will allow you to create new XIO volume,map to initiator groups, validate, create datastore of the same volume at ESXi level and then rescan at cluster level " -ForegroundColor Yellow
Write-Host "Kindly understand the implications of creating new volume at  XIO storage level and datastore at vSphere level before proceeding" -ForegroundColor Yellow 
do {
        Write-Host "Enter Yes to proceed No to quit. Are you ready to proceed (Yes/No): " -NoNewline -ForegroundColor Yellow
        $userAcceptance = read-host 
} Until (($userAcceptance -eq "Yes") -or ($userAcceptance -eq "No") )

if ( $userAcceptance  -eq "No" ){ 
        Write-host "Exiting" -ForegroundColor Red
        exit
}else{

        Write-Host "Please enter the ServiceNow change ID submitted for this activity: " -ForegroundColor Yellow -NoNewline
        $ChangeID = read-host
}

################# vCenter Details ###########

$vCenter = Read-host "Enter vCenter Host FQDN where we have ESXi cluster and need to create datastore: "
$vcuserName =Read-host "Enter Username to connect vCenter server : " 
$SecurePassword = Read-Host -assecurestring "Please enter your password: " 
$BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
$vcPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
Write-Host "Please enter the ESXi Cluster Name for this activity: " -ForegroundColor Yellow -NoNewline
$ESXiClusterName = [string] (read-host)

Write-Host "Please enter the XIO management server name on which XIO clusters are configured: ==> " -ForegroundColor Yellow -NoNewline
$XIOmgmtHost = [string] (Read-Host)
Write-Host "Please enter the XIO cluster name on which we need to create new XIO volume: ==> " -ForegroundColor Yellow -NoNewline
$XIOcluster = [string] (Read-Host)
Write-Host "Please enter the user name to accese the XIO system i.e admin or DOMAIN\YOURID which has admin permissions : ==> " -ForegroundColor Yellow -NoNewline
$XIOUsername = [string] (Read-Host)
Write-Host "Please enter the Name for new XIO volume which we will be creating and then map to ESXi cluster. Note that the same Name we will use as datastore Name at ESXi level <--- " -ForegroundColor Yellow -NoNewline
$XIOVolumeName = [string] (Read-Host)
Write-Host "Please enter new XIO volume capacity in GBs only<--- " -ForegroundColor Yellow -NoNewline
$XIOVolCapacityGB = [int] (Read-Host)

#Write-Host "Please enter the existing Initiator group Names seperated by comma to which we need to map the new XIO volume <--- " -ForegroundColor Yellow -NoNewline
 #$IGList = [string[]](read-host)
 #$IGArray = $IGList.split(",")

############## Functions ###################
Function Get-DatastoreMountInfo {
	<#	.Description
		Get Datastore mount info (like, is datastore mounted on given host, is SCSI LUN attached, so on)
	#>
	[CmdletBinding()]
	Param (
		## one or more datastore objects for which to get Mount info
		[Parameter(Mandatory=$true,ValueFromPipeline=$true)][VMware.VimAutomation.ViCore.Impl.V1.DatastoreManagement.VmfsDatastoreImpl[]]$Datastore
	)
	Begin {$arrHostsystemViewPropertiesToGet = "Name","ConfigManager.StorageSystem"; $arrStorageSystemViewPropertiesToGet = "SystemFile","StorageDeviceInfo.ScsiLun"}
	Process {
		foreach ($dstThisOne in $Datastore) {
			## if this is a VMFS datastore
			if ($dstThisOne.ExtensionData.info.Vmfs) {
				## get the canonical names for all of the extents that comprise this datastore
				$arrDStoreExtentCanonicalNames = $dstThisOne.ExtensionData.Info.Vmfs.Extent | Foreach-Object {$_.DiskName}
				## if there are any hosts associated with this datastore (though, there always should be)
				if ($dstThisOne.ExtensionData.Host) {
					foreach ($oDatastoreHostMount in $dstThisOne.ExtensionData.Host) {
						## get the HostSystem and StorageSystem Views
						$viewThisHost = Get-View $oDatastoreHostMount.Key -Property $arrHostsystemViewPropertiesToGet
						$viewStorageSys = Get-View $viewThisHost.ConfigManager.StorageSystem -Property $arrStorageSystemViewPropertiesToGet
						foreach ($oScsiLun in $viewStorageSys.StorageDeviceInfo.ScsiLun) {
							## if this SCSI LUN is part of the storage that makes up this datastore (if its canonical name is in the array of extent canonical names)
							if ($arrDStoreExtentCanonicalNames -contains $oScsiLun.canonicalName) {
								New-Object -Type PSObject -Property @{
									Datastore = $dstThisOne.Name
									ExtentCanonicalName = $oScsiLun.canonicalName
									VMHost = $viewThisHost.Name
									Mounted = $oDatastoreHostMount.MountInfo.Mounted
									ScsiLunState = Switch ($oScsiLun.operationalState[0]) {
												"ok" {"Attached"; break}
												"off" {"Detached"; break}
												default {$oScsiLun.operationalstate[0]}
											} ## end switch
								} ## end new-object
							} ## end if
						} ## end foreach
					} ## end foreach
				} ## end if
			} ## end if
		} ## end foreach
	} ## end proces
} ## end fn


function XIOVol_create_map () {
 
write-host "Connecting to XMS server through PowerCLI and it will ask you to enter the password for the username you given above " -foregroundcolor Yellow
Connect-XIOServer $XIOmgmtHost -TrustAllCert -Credential $XIOUsername
write-host "Here is cluster capacity before we create new XIO volume and make sure the used capacity is below 90% : " -foregroundcolor Yellow
Get-XIOCluster |FT -autosize
write-host "Here is the list of existing initiator groups on cluster $XIOcluster : " -foregroundcolor Yellow
Get-XIOInitiatorGroup -Cluster $XIOcluster |FT -AutoSize
Write-Host "Please enter the existing Initiator group Names seperated by comma to which we need to map the new XIO volume <--- " -ForegroundColor Yellow -NoNewline
 $IGList = [string[]](read-host)
 $IGArray = $IGList.split(",")

do {
 Write-Host "Are you sure you want to proceed with creating new XIO volume (Yes/No): " -ForegroundColor Yellow -NoNewline
                 $UserConfirmation = Read-Host
         } Until ( ($UserConfirmation -eq "Yes") -or ($UserConfirmation -eq "No"))

        if ( $UserConfirmation -eq "No" ){
                Write-host "Exiting" -ForegroundColor Red
                exit
        }

Write-Host "Now creating new XIO volume with name $XIOVolumeName and capacity $XIOVolCapacityGB GB:" -ForegroundColor Yellow
New-XIOVolume -ComputerName $XIOmgmtHost -Cluster $XIOcluster -Name $XIOVolumeName -SizeGB $XIOVolCapacityGB -Verbose
Write-Host "Here is the Newly created XIO volume $XIOVolumeName details:, please validate before proceeding with mapping function" -ForegroundColor Yellow
Get-XIOVolume -Cluster $XIOcluster -Name $XIOVolumeName |FT -AutoSize
do {
 Write-Host "Are you sure you want to proceed with mapping the new XIO volume to IGs (Yes/No): " -ForegroundColor Yellow -NoNewline
                 $UserConfirmation = Read-Host
         } Until ( ($UserConfirmation -eq "Yes") -or ($UserConfirmation -eq "No"))

        if ( $UserConfirmation -eq "No" ){
                Write-host "Exiting" -ForegroundColor Red
                exit
        }


Foreach ($IGName in $IGArray) {
Write-Host "Here is the current LUN mappings to the IG $IGName : " -ForegroundColor Yellow
Get-XIOLunMap -InitiatorGroup $IGName -ComputerName $XIOmgmtHost -Cluster $XIOcluster |sort -Property LunID |FT -AutoSize
}
Write-Host "Please enter the Host LUN ID, it is recommended to use the LUN ID which is available across all IGs as shown above : " -ForegroundColor Yellow -NoNewline
$XIOVolLUNID = [int] (Read-Host)
Write-Host "Now we will be mapping the $XIOVolumeName with $XIOVolLUNID to these $IGList IGs : " -ForegroundColor Yellow
New-XIOLunMap -Cluster $XIOcluster -Volume $XIOVolumeName -InitiatorGroup $IGArray -HostLunId $XIOVolLUNID -Verbose
Get-XIOLunMap -Volume $XIOVolumeName -ComputerName $XIOmgmtHost -Cluster $XIOcluster
$XIOVolNAAID = Get-XIOVolume -Name $XIOVolumeName| select $_.NaaName
}

function datastore_create () {

$DatastoreName = $XIOVolumeName
$XIOVolNAAID = "naa."+(Get-XIOVolume -Name $XIOVolumeName| select -ExpandProperty NaaName)
  Write-Host "Now running VMFS rescan on all hosts of this cluster and once it is done, we will look for newly created XIO Volume which has NAA ID $XIOVolNAAID, please wait:" -ForegroundColor Yellow
        Get-Cluster $ESXiClusterName |Get-VMHost |Get-VMHostStorage -RescanAllHba -RescanVmfs | Out-Host
        Get-Cluster $ESXiClusterName |Get-VMHost |Get-ScsiLun |select CanonicalName,ConsoleDeviceName,LunType,CapacityGB,VMHost | where CanonicalName -Match $XIOVolNAAID |FT -AutoSize
        $vmhostlist = Get-Cluster $ESXiClusterName |Get-VMHost
        Get-VMHost $vmhostlist[0]|New-Datastore -Name $DatastoreName -Path $XIOVolNAAID -Vmfs -FileSystemVersion 5 -Verbose
        Get-Cluster $ESXiClusterName |Get-VMHost |Get-VMHostStorage -RescanAllHba -RescanVmfs | Out-Host
        Write-Host "Here is the newly created datastore $DatastoreName mount information: " -ForegroundColor Yellow
        Get-Cluster $ESXiClusterName |Get-VMHost |Get-Datastore -Name $DatastoreName |Get-DatastoreMountInfo |FT -AutoSize
}

####  Connect to vcenter ########
Write-host "Checking loading VMWare PS Snapin ( It might take a minute or two) " -ForegroundColor Yellow
if ( (Get-PSSnapin -Name VMware.VimAutomation.Core -ErrorAction SilentlyContinue) -eq $null ) { Add-PsSnapin VMware.VimAutomation.Core }

$VCStatus = Connect-VIServer $vCenter -username $vcuserName  -password $vcPassword
if ( $VCStatus ) {
     
     Write-Host "Now calling the XIO_vol_create_map function" -ForegroundColor Yellow
     
     XIOVol_create_map

         #### User Confirmation before creating datastores ####

        do {
                 Write-Host "Are you sure you want to create new datastore on cluster $ESXiClusterName  (Yes/No): " -ForegroundColor Yellow -NoNewline
                 $UserConfirmation = Read-Host
         } Until ( ($UserConfirmation -eq "Yes") -or ($UserConfirmation -eq "No"))

        if ( $UserConfirmation -eq "No" ){
                Write-host "Exiting" -ForegroundColor Red
                exit
        }
        
        Write-Host "Now we are calling datastore_create function:" -ForegroundColor Yellow
       datastore_create
       Write-Host "with this we have completed the task and now Disconnecting the vCenter & XIO mgmt host from here"  -ForegroundColor Yellow
        Disconnect-VIServer $vCenter -Confirm:$false
        Disconnect-XIOServer -ComputerName $XIOmgmtHost
               }
        else {
        }
