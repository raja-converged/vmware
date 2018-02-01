
################# User Agreement ###########
<# 
Author and customized by: Raja

<#	
	===========================================================================
	Created by: 	Raja Pamuluri
	Created on:		1/2018
    Version: v2.0
    Github Link: https://github.com/raja-converged/vmware
		===========================================================================
	.DESCRIPTION
		PowerShell Module to help to automate the end to end storage reclaim activity if you have VMware as hypervisor and XIO storage as SAN system.
This script in first part, will perform the datastore reclaim at vCenter level that includes pre-check,unmount,detach, validate and clear dead paths at ESXi level.
In the second part, it will perform the XIO volume unmap & removal steps at XIO array level that includes pre-check, unmap from all IGs,wait for 10 minutes, remove the volume
permanently and then validate.
	.NOTES
		Make sure you understand the impact of Datastore reclaim and XIO level volume removal. At the same time make sure you follow the process as per your organization and you can modify or customize the script as you need.
		* Tested against PowerShell 5.0 
		* Tested against VMware PowerCLI 6.5.1 build 5377412
		* Tested against vCenter 6.0 / 5.5
		* Tested against ESXi 5.5/6.0
        * Tested against XIOS v4.0.25 and XMS v4.2.2-20 with REST APT v2.0
        * Tested against XIO Powershell Module XtremIO.Utils v1.4.0 and you can download this from below GitHub link
            https://github.com/mtboren/XtremIO.Utils/tree/master/XtremIO.Utils

#

You import or this script will has built in with the below two modules  since these two won't come by default with VMware Powershell plugin.
DatastoreFunctions.ps1 is the script which we have taken from VMware and customized to perform the unmount , detach opertations.
get-datastoreunmountstatus.ps1 is the script which we have taken from Vmware community and it will perform the pre-check tasks.

For any modifications or suggestions please do contact Raja Pamuluri at raja.converged@gmail.com.

#>
$ChangeID
$ESXiClusterName
###$outputof_script =
Write-Host "Before running executing this script make sure you have imported the required modules like datastore functions,get-datastoreunmount status:" -ForegroundColor Yellow
Write-Host "This script will provide the current status of datastores which are given in the input file and then unmount, detach one by one followed-by rescan " -ForegroundColor Yellow
Write-Host "Kindly understand the implications of datastore unmount and detach at ESXi layer before proceeding" -ForegroundColor Yellow 
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

$vCenter = Read-host "Enter vCenter Host FQDN on which we need to performt the reclaim: "
$vcuserName =Read-host "Enter Username: " 
$SecurePassword = Read-Host -assecurestring "Please enter your password: " 
$BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
$vcPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
Write-Host "Please enter the ESXi Cluster Name for this activity: " -ForegroundColor Yellow -NoNewline
$ESXiClusterName = [string] (read-host)


############## Functions ###################


function Get-DatastoreUnmountStatus{
  <#
.SYNOPSIS  Check if a datastore can be unmounted.
.DESCRIPTION The function checks a number of prerequisites
  that need to be met to be able to unmount a datastore.
.PARAMETER Datastore
  The datastore for which you want to check the conditions.
  You can pass the name of the datastore or the Datastore
  object returned by Get-Datastore
.EXAMPLE
  PS> Get-DatastoreUnmountStatus -Datastore DS1
.EXAMPLE
  PS> Get-Datastore | Get-DatastoreUnmountStatus
#>
  param(
    [CmdletBinding()]
    [Parameter(Mandatory=$true,ValueFromPipeline=$true)]
    [PSObject[]]$Datastore
  )
 
  process{
    foreach($ds in $Datastore){
      if($ds.GetType().Name -eq "string"){
        $ds = Get-Datastore -Name $ds
      }
      $parent = Get-View $ds.ExtensionData.Parent
      New-Object PSObject -Property @{
        Datastore = $ds.Name
        # No Virtual machines
        NoVM = $ds.ExtensionData.VM.Count -eq 0
        # Not in a Datastore Cluster
        NoDastoreClusterMember = $parent -isnot [VMware.Vim.StoragePod]
        # Not managed by sDRS
        NosDRS = &{
          if($parent -is [VMware.Vim.StoragePod]){
            !$parent.PodStorageDrsEntry.StorageDrsConfig.PodConfig.Enabled
          }
          else {$true}
        }
        # SIOC disabled
        NoSIOC = !$ds.StorageIOControlEnabled
        # No HA heartbeat
        NoHAheartbeat = &{
          $hbDatastores = @()
          $cls = Get-View -ViewType ClusterComputeResource -Property Host |
          where{$_.Host -contains $ds.ExtensionData.Host[0].Key}
          if($cls){
            $cls | %{
              (                $_.RetrieveDasAdvancedRuntimeInfo()).HeartbeatDatastoreInfo | %{
                $hbDatastores += $_.Datastore
              }
            }
            $hbDatastores -notcontains $ds.ExtensionData.MoRef
          }
          else{$true}
        }
        # No vdSW file
        NovdSwFile = &{
          New-PSDrive -Location $ds -Name ds -PSProvider VimDatastore -Root '\' | Out-Null
          $result = Get-ChildItem -Path ds:\ -Recurse |
          where {$_.Name -match '.dvsData'}
          Remove-PSDrive -Name ds -Confirm:$false
          if($result){$false}else{$true}
        }
        # No scratch partition
        NoScratchPartition = &{
          $result = $true
          $ds.ExtensionData.Host | %{Get-View $_.Key} | %{
            $diagSys = Get-View $_.ConfigManager.DiagnosticSystem
            $dsDisks = $ds.ExtensionData.Info.Vmfs.Extent | %{$_.DiskName}
            if($dsDisks -contains $diagSys.ActivePartition.Id.DiskName){
              $result = $false
            }
          }
          $result
        }
      }
    }
  }
}


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


Function Unmount-Datastore {
	<#	.Description
		Unmount VMFS volume(s) from VMHost(s)
		.Example
		Get-Datastore myOldDatastore0 | Unmount-Datastore -VMHost (Get-VMHost myhost0.dom.com, myhost1.dom.com)
		Unmounts the VMFS volume myOldDatastore0 from specified VMHosts
		Get-Datastore myOldDatastore1 | Unmount-Datastore
		Unmounts the VMFS volume myOldDatastore1 from all VMHosts associated with the datastore
		.Outputs
		None
	#>
	[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact="High")]
	Param (
		## One or more datastore objects to whose VMFS volumes to unmount
		[Parameter(Mandatory=$true,ValueFromPipeline=$true)][VMware.VimAutomation.ViCore.Impl.V1.DatastoreManagement.VmfsDatastoreImpl[]]$Datastore,
		## VMHost(s) on which to unmount a VMFS volume; if non specified, will unmount the volume on all VMHosts that have it mounted
		[Parameter(ParameterSetName="SelectedVMHosts")][VMware.VimAutomation.ViCore.Impl.V1.Inventory.VMHostImpl[]]$VMHost
	)
	Begin {$arrHostsystemViewPropertiesToGet = "Name","ConfigManager.StorageSystem"; $arrStorageSystemViewPropertiesToGet = "SystemFile"}
	Process {
		## for each of the datastores
		foreach ($dstThisOne in $Datastore) {
			## if the datastore is actually mounted on any host
			if ($dstThisOne.ExtensionData.Host) {
				## the MoRefs of the HostSystems upon which to act
				$arrMoRefsOfHostSystemsForUnmount = if ($PSCmdlet.ParameterSetName -eq "SelectedVMHosts") {$VMHost | Foreach-Object {$_.Id}} else {$dstThisOne.ExtensionData.Host | Foreach-Object {$_.Key}}
				## get array of HostSystem Views from which to unmount datastore
				$arrViewsOfHostSystemsForUnmount = Get-View -Property $arrHostsystemViewPropertiesToGet -Id $arrMoRefsOfHostSystemsForUnmount

				foreach ($viewThisHost in $arrViewsOfHostSystemsForUnmount) {
					## actually do the unmount (if not WhatIf)
					if ($PSCmdlet.ShouldProcess("VMHost '$($viewThisHost.Name)'", "Unmounting VMFS datastore '$($dstThisOne.Name)'")) {
						$viewStorageSysThisHost = Get-View $viewThisHost.ConfigManager.StorageSystem -Property $arrStorageSystemViewPropertiesToGet
						## add try/catch here?  and, return something here?
						$viewStorageSysThisHost.UnmountVmfsVolume($dstThisOne.ExtensionData.Info.vmfs.uuid)
					} ## end if
				} ## end foreach
			} ## end if
		} ## end foreach
	} ## end process
} ## end fn


Function Mount-Datastore {
	<#	.Description
		Mount VMFS volume(s) on VMHost(s)
		.Example
		Get-Datastore myOldDatastore1 | Mount-Datastore
		Mounts the VMFS volume myOldDatastore1 on all VMHosts associated with the datastore (where it is not already mounted)
		.Outputs
		None
	#>
	[CmdletBinding(SupportsShouldProcess=$true)]
	Param (
		[Parameter(Mandatory=$true,ValueFromPipeline=$true)][VMware.VimAutomation.ViCore.Impl.V1.DatastoreManagement.VmfsDatastoreImpl[]]$Datastore
	)
	Begin {$arrHostsystemViewPropertiesToGet = "Name","ConfigManager.StorageSystem"; $arrStorageSystemViewPropertiesToGet = "SystemFile"}
	Process {
		foreach ($dstThisOne in $Datastore) {
			## if there are any hosts associated with this datastore (though, there always should be)
			if ($dstThisOne.ExtensionData.Host) {
				foreach ($oDatastoreHostMount in $dstThisOne.ExtensionData.Host) {
					$viewThisHost = Get-View $oDatastoreHostMount.Key -Property $arrHostsystemViewPropertiesToGet
					if (-not $oDatastoreHostMount.MountInfo.Mounted) {
						if ($PSCmdlet.ShouldProcess("VMHost '$($viewThisHost.Name)'", "Mounting VMFS Datastore '$($dstThisOne.Name)'")) {
							$viewStorageSysThisHost = Get-View $viewThisHost.ConfigManager.StorageSystem -Property $arrStorageSystemViewPropertiesToGet
							$viewStorageSysThisHost.MountVmfsVolume($dstThisOne.ExtensionData.Info.vmfs.uuid);
						} ## end if
					} ## end if
					else {Write-Verbose -Verbose "Datastore '$($dstThisOne.Name)' already mounted on VMHost '$($viewThisHost.Name)'"}
				} ## end foreach
			} ## end if
		} ## end foreach
	} ## end process
} ## end fn


Function Detach-SCSILun {
	<#	.Description
		Detach SCSI LUN(s) from VMHost(s).  If specifying host, needs to be a VMHost object (as returned from Get-VMHost).  This was done to avoid any "matched host with similar name pattern" problems that may occur if accepting host-by-name.
		.Example
		Get-Datastore myOldDatastore0 | Detach-SCSILun -VMHost (Get-VMHost myhost0.dom.com, myhost1.dom.com)
		Detaches the SCSI LUN associated with datastore myOldDatastore0 from specified VMHosts
		Get-Datastore myOldDatastore1 | Detach-SCSILun
		Detaches the SCSI LUN associated with datastore myOldDatastore1 from all VMHosts associated with the datastore
		.Outputs
		None
	#>
	[CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact="High")]
	Param (
		## One or more datastore objects to whose SCSI LUN to detach
		[Parameter(Mandatory=$true,ValueFromPipeline=$true)][VMware.VimAutomation.ViCore.Impl.V1.DatastoreManagement.VmfsDatastoreImpl[]]$Datastore,
		## VMHost(s) on which to detach the SCSI LUN; if non specified, will detach the SCSI LUN on all VMHosts that have it attached
		[Parameter(ParameterSetName="SelectedVMHosts")][VMware.VimAutomation.ViCore.Impl.V1.Inventory.VMHostImpl[]]$VMHost
	)
	Begin {$arrHostsystemViewPropertiesToGet = "Name","ConfigManager.StorageSystem"; $arrStorageSystemViewPropertiesToGet = "SystemFile","StorageDeviceInfo.ScsiLun"}
	Process {
		foreach ($dstThisOne in $Datastore) {
			## get the canonical names for all of the extents that comprise this datastore
			$arrDStoreExtentCanonicalNames = $dstThisOne.ExtensionData.Info.Vmfs.Extent | Foreach-Object {$_.DiskName}
			## if there are any hosts associated with this datastore (though, there always should be)
			if ($dstThisOne.ExtensionData.Host) {
				## the MoRefs of the HostSystems upon which to act
				$arrMoRefsOfHostSystemsForUnmount = if ($PSCmdlet.ParameterSetName -eq "SelectedVMHosts") {$VMHost | Foreach-Object {$_.Id}} else {$dstThisOne.ExtensionData.Host | Foreach-Object {$_.Key}}
				## get array of HostSystem Views from which to unmount datastore
				$arrViewsOfHostSystemsForUnmount = Get-View -Property $arrHostsystemViewPropertiesToGet -Id $arrMoRefsOfHostSystemsForUnmount

				foreach ($viewThisHost in $arrViewsOfHostSystemsForUnmount) {
					## get the StorageSystem View
					$viewStorageSysThisHost = Get-View $viewThisHost.ConfigManager.StorageSystem -Property $arrStorageSystemViewPropertiesToGet
					foreach ($oScsiLun in $viewStorageSysThisHost.StorageDeviceInfo.ScsiLun) {
						## if this SCSI LUN is part of the storage that makes up this datastore (if its canonical name is in the array of extent canonical names)
						if ($arrDStoreExtentCanonicalNames -contains $oScsiLun.canonicalName) {
							if ($PSCmdlet.ShouldProcess("VMHost '$($viewThisHost.Name)'", "Detach LUN '$($oScsiLun.CanonicalName)'")) {
								$viewStorageSysThisHost.DetachScsiLun($oScsiLun.Uuid)
							} ## end if
						} ## end if
					} ## end foreach
				} ## end foreach
			} ## end if
		} ## end foreach
	} ## end process
} ## end fn


Function Attach-SCSILun {
	<#	.Description
		Attach SCSI LUN(s) to VMHost(s)
		.Example
		Get-Datastore myOldDatastore1 | Attach-SCSILun
		Attaches the SCSI LUN associated with datastore myOldDatastore1 to all VMHosts associated with the datastore
		.Outputs
		None
	#>
	[CmdletBinding(SupportsShouldProcess=$true)]
	Param (
		## One or more datastore objects to whose SCSI LUN to attach
		[Parameter(Mandatory=$true,ValueFromPipeline=$true)][VMware.VimAutomation.ViCore.Impl.V1.DatastoreManagement.VmfsDatastoreImpl[]]$Datastore
	)
	Begin {$arrHostsystemViewPropertiesToGet = "Name","ConfigManager.StorageSystem"; $arrStorageSystemViewPropertiesToGet = "SystemFile","StorageDeviceInfo.ScsiLun"}
	Process {
		foreach ($dstThisOne in $Datastore) {
			$arrDStoreExtentCanonicalNames = $dstThisOne.ExtensionData.Info.Vmfs.Extent | Foreach-Object {$_.DiskName}
			## if there are any hosts associated with this datastore (though, there always should be)
			if ($dstThisOne.ExtensionData.Host) {
				foreach ($oDatastoreHostMount in $dstThisOne.ExtensionData.Host) {
					## get the HostSystem and StorageSystem Views
					$viewThisHost = Get-View $oDatastoreHostMount.Key -Property $arrHostsystemViewPropertiesToGet
					$viewStorageSysThisHost = Get-View $viewThisHost.ConfigManager.StorageSystem -Property $arrStorageSystemViewPropertiesToGet
					foreach ($oScsiLun in $viewStorageSysThisHost.StorageDeviceInfo.ScsiLun) {
						## if this SCSI LUN is part of the storage that makes up this datastore (if its canonical name is in the array of extent canonical names)
						if ($arrDStoreExtentCanonicalNames -contains $oScsiLun.canonicalName) {
							## if this SCSI LUN is not already attached
							if (-not ($oScsiLun.operationalState[0] -eq "ok")) {
								if ($PSCmdlet.ShouldProcess("VMHost '$($viewThisHost.Name)'", "Attach LUN '$($oScsiLun.CanonicalName)'")) {
									$viewStorageSysThisHost.AttachScsiLun($oScsiLun.Uuid)
								} ## end if
							} ## end if
							else {Write-Verbose -Verbose "SCSI LUN '$($oScsiLun.canonicalName)' already attached on VMHost '$($viewThisHost.Name)'"}
						} ## end if
					} ## end foreach
				} ## end foreach
			} ## end if
		} ## end foreach
	} ## end process
} ## end fn

function unmout_datastore (){
Foreach ($ds in $DSPath) {
#
#Write-Host "Now we are going to unmount the $DSList from all the hosts as shown above"
get-datastore -name $ds|Unmount-Datastore -Confirm:$false -Verbose
}
Write-Host "wait for 30 sec before moving to detaching of datastore" -ForegroundColor Green
Start-Sleep -Seconds 30
}

function detach_datastore (){
Foreach ($ds in $DSPath) {
#
#Things you can change as input variable for every object execution.
Write-Host "This script will detach the Datastore $ds as mentioned in input file"  -ForegroundColor Green
#Write-Host "Now we are going to unmount the $DSList from all the hosts as shown above"
get-datastore -name $ds|Detach-SCSILun -Confirm:$false -Verbose
Start-Sleep -Seconds 10
Write-Host "Here is the  status of $ds Datastore after detach"  -ForegroundColor Green
get-datastore -name $ds |Get-DatastoreMountInfo |sort Datastore,VMHost| FT -AutoSize
}
Write-Host "Now running vmfs & HBAs rescan on all hosts of cluster $ESXiClusterName"  -ForegroundColor Green
get-cluster -Name $ESXiClusterName |Get-VMHost |Get-VMHostStorage -RescanAllHba -RescanVmfs |Out-Host
}

function precheck_datastore (){
Foreach ($ds in $DSPath) {
Write-Host "This function will perform all pre-checks on datastore $ds and all values should be True before we proceed with unmount & detach..it takes couple of minutes"  -ForegroundColor Green
Get-Datastore -Name $ds |Get-DatastoreUnmountStatus |Out-Host
Get-Datastore -Name $ds |Get-VM |FT |Out-Host
}
}

function XIO_unmap_remove () {


################# User Agreement ###########
<# You need to have both XIO & VMware PowerCLI modules are already installed on the host from where you are running this script.
\\mdcnasshares\s_convergedteam\Automation\Powershell\Production\XtremIO.Utils-master
For any modifications or suggestions please do contact Raja Pamuluri (rajasekhar.reddy@vistraenergy) or get the approval from Chris Cantu.
#>

Write-Host "Please enter the file path as input which has list of XIO Volume names and their NAA IDs in CSV file format <--- " -ForegroundColor Black -BackgroundColor Yellow -NoNewline
$path = [String](read-host)
$VolList= Import-CSV $path
Write-Host "Please enter the XIO management server name on which XIO clusters are configured for management: ==> " -ForegroundColor Yellow -NoNewline
$XIOmgmtHost = [string] (Read-Host)
Write-Host "Please enter the XIO cluster name on which XIO clusters are configured: ==> " -ForegroundColor Yellow -NoNewline
$XIOcluster = [string] (Read-Host)

<################## vCenter Details ###########

$vCenter = Read-host "Enter vCenter Host FQDN on which we need to performt the reclaim: " 
$vcuserName =Read-host "Enter Username: " 
$SecurePassword = Read-Host -assecurestring "Please enter your password: " 
$BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
$vcPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
Write-Host "Please enter the ESXI cluster name to which these volumes are mapped to: " -ForegroundColor Black -BackgroundColor Yellow -NoNewline
$ESXicluster = [string] (Read-Host)
################# vCenter Details ###########
#>


write-host "Connecting to XMS server through PowerCLI: " -foregroundcolor Yellow
Connect-XIOServer $XIOmgmtHost
write-host "Here is cluster capacity before reclaim: " -foregroundcolor Yellow
Get-XIOCluster |FT -autosize
function precheck_xiovol () {
Foreach ($volname in $VolList) {
write-host "Here is the volume $volname.Name details and current mappings:" -foregroundcolor Yellow
Get-XIOVolume $volname.Name|FT -AutoSize
Get-XIOLunMap -Volume $volname.Name |Out-Host
}
}
function removemapping_xiovol () {
Foreach ($volname in $VolList) {
#Get-XIOLunMap -Volume $volname.Name |Remove-XIOLunMap -WhatIf
#Get-XIOLunMap -Volume $volname.Name |Remove-XIOLunMap -WhatIf
Get-XIOLunMap -Volume $volname.Name |Remove-XIOLunMap -Confirm:$false -Verbose
}
}

function delete_xiovol () {
Foreach ($volname in $VolList) {
#Remove-XIOVolume -Volume "$volname.Name" -WhatIf
Get-XIOVolume $volname.Name | Remove-XIOVolume -Confirm:$false -Verbose
}
}

do {
                 precheck_xiovol
                 Write-Host "Are you sure you want to proceed with removal of all above volumes mappings at XIO level (Yes/No): " -ForegroundColor Yellow -NoNewline
                 $UserConfirmation = Read-Host
         } Until ( ($UserConfirmation -eq "Yes") -or ($UserConfirmation -eq "No"))

        if ( $UserConfirmation -eq "No" ){
                Write-host "Exiting" -ForegroundColor Red
                exit
        }

write-host "Now we are calling the remove mappings function and it will take some time to remove mappings at XIO level:"
removemapping_xiovol
$VCStatus = Connect-VIServer $vCenter -username $vcuserName  -password $vcPassword
if ( $VCStatus ) {
Write-Host "Now we will be connecting to the vCenter and then perform rescan on all given ESXi cluster post removing LUN mappings at storage level:" -ForegroundColor Yellow
get-cluster -Name $ESXiClusterName |Get-VMHost |Get-VMHostStorage -RescanAllHba -RescanVmfs -Verbose |Out-Host
}
else {
}

write-host "Now the script will go to sleep for 10 minutes before you decide to go to deletion of unmapped volumes:"
do {
                 Write-Host "Are you sure you want to wait for 10 minutes before deleting the volumes at XIO level (Yes/No): " -ForegroundColor Yellow -NoNewline
                 $UserConfirmation = Read-Host
         } Until ( ($UserConfirmation -eq "Yes") -or ($UserConfirmation -eq "No"))

        if ( $UserConfirmation -eq "No" ){
                Write-host "Exiting" -ForegroundColor Red
                exit
        }

        sleep 600
        do {
                 Write-Host "Are you sure you want to go with deleting the volumes at XIO level, but note that we can't roll back the data once deleted (Yes/No): " -ForegroundColor Yellow -NoNewline
                 $UserConfirmation = Read-Host
         } Until ( ($UserConfirmation -eq "Yes") -or ($UserConfirmation -eq "No"))

        if ( $UserConfirmation -eq "No" ){
                Write-host "Exiting" -ForegroundColor Red
                exit
        }
        delete_xiovol
        Write-Host "Here is the capacity after volume unmap & delete"
        Get-XIOCluster |FT -AutoSize
        Write-Host "Now we are disconnecting the XIO cluster from this Powershell host"
        Disconnect-XIOServer $XIOmgmtHost
      }

####  Connect to vcenter ########
Write-host "Checking loading VMWare PS Snapin ( It might take a minute or two) " -ForegroundColor Yellow
if ( (Get-PSSnapin -Name VMware.VimAutomation.Core -ErrorAction SilentlyContinue) -eq $null ) { Add-PsSnapin VMware.VimAutomation.Core }

$VCStatus = Connect-VIServer $vCenter -username $vcuserName  -password $vcPassword
if ( $VCStatus ) {
     
        Write-Host "Please enter the file path as input which has list of datastore names for reclaim <--- " -ForegroundColor Yellow -NoNewline
        $DSList = [String](read-host)
        $DSPath = Get-Content $DSList
        Write-Host "Here is the curretn status of targetted datastores mount info"  -ForegroundColor Green
        Foreach ($ds in $DSPath) {
          get-datastore -name $ds |Get-DatastoreMountInfo |sort Datastore, VMHost |FT -AutoSize
          }

          #### Checking if any active VMDK and VMs using on each datastore ####

        do {
                 precheck_datastore
                 Write-Host "Are you sure you want to proceed with next step i.e unmount & detach (Yes/No): " -ForegroundColor Yellow -NoNewline
                 $UserConfirmation = Read-Host
         } Until ( ($UserConfirmation -eq "Yes") -or ($UserConfirmation -eq "No"))

        if ( $UserConfirmation -eq "No" ){
                Write-host "Exiting" -ForegroundColor Red
                exit
        }
        
      
          #### User Confirmation before unmounting datastores ####
                   
        do {
                 Write-Host "Are you sure you want to unmount the above mentioned datastores (Yes/No): " -ForegroundColor Yellow -NoNewline
                 $UserConfirmation = Read-Host
         } Until ( ($UserConfirmation -eq "Yes") -or ($UserConfirmation -eq "No"))

        if ( $UserConfirmation -eq "No" ){
                Write-host "Exiting" -ForegroundColor Red
                exit
        }
        
        Write-Host "Now Datastores will be unmounted from all hosts"  -ForegroundColor Green
        unmout_datastore

         #### User Confirmation before detaching datastores ####

        do {
                 Write-Host "Are you sure you want to detach the above mentioned datastores Now (Yes/No): " -ForegroundColor Yellow -NoNewline
                 $UserConfirmation = Read-Host
         } Until ( ($UserConfirmation -eq "Yes") -or ($UserConfirmation -eq "No"))

        if ( $UserConfirmation -eq "No" ){
                Write-host "Exiting" -ForegroundColor Red
                exit
        }
        
        Write-Host "Now Datastores will be detached from all hosts"  -ForegroundColor Yellow
        detach_datastore
        Write-Host "Now we will be connecting to XIO cluster and then unmap, remove the respective volumes at XIO storage array level:"  -ForegroundColor Yellow
         do {
                 Write-Host "Are you sure you want to proceed with XIO storage array level unmap & remove volume function (Yes/No): " -ForegroundColor Yellow -NoNewline
                 $UserConfirmation = Read-Host
         } Until ( ($UserConfirmation -eq "Yes") -or ($UserConfirmation -eq "No"))

        if ( $UserConfirmation -eq "No" ){
                Write-host "Exiting" -ForegroundColor Red
                exit
        }
        Write-Host "Now we are calling the xio_unmap_remove function which will unmap & remove the volumes at XIO storage array level:"  -ForegroundColor Yellow
        XIO_unmap_remove
        Write-Host "Disconnecting the vCenter also from here"  -ForegroundColor Yellow
        Disconnect-VIServer $vCenter -Confirm:$false
               }
        else {
        }
