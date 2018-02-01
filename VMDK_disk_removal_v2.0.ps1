################# User Agreement ###########

<#	

    Author and customized by: Raja
	===========================================================================
	Created by: 	Raja Pamuluri
	Created on:		11/2017
    Version: v2.0
    Github Link: https://github.com/raja-converged/vmware
		===========================================================================
	.DESCRIPTION
		PowerShell Module to help with multiple Hard Disks removal from multiple VMs at vCenter level that includes pre-check,remove and validate at ESXi level.
	.NOTES
		Make sure you understand the impact of Hard disks removal and follow the process at your organization level. Also, you can modify or customize as you need.
		* Tested against PowerShell 5.0 
		* Tested against VMware PowerCLI 6.5.1 build 5377412
		* Tested against vCenter 6.0 / 5.5
		* Tested against ESXi 5.5/6.0
For any modifications or suggestions please do contact Raja Pamuluri at raja.converged@gmail.com.

#>

Write-Host "This script will show the status of each hard disk and then remove the hard disk from the VM as given in the imported input CSV file " -ForegroundColor Yellow
Write-Host "Kindly understand the implications of hard disk removeal at ESXi & VM layer before proceeding" -ForegroundColor Yellow 
Write-Host "export the hard disk entries with the command Get-VM <VMNAME> | Get-Harddisk |select Name,Parent,Filename,Id|Export-Csv C:\Temp\harddisk.csv and filter the harddisks which one you want remove and save it"
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
        Write-Host "Please enter the ESXi Cluster Name for this activity: " -ForegroundColor Yellow -NoNewline
        $ESXiClusterName = [string] (read-host)

}

################# vCenter Details ###########

$vCenter = Read-host "Enter vCenter Host FQDN on which we need to performt the reclaim: " 
$vcuserName =Read-host "Enter Username: " 
$SecurePassword = Read-Host -assecurestring "Please enter your password: " 
$BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
$vcPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)


############## Functions ###################


#Things you can change as input variable for every object execution.
#------------------------------
function remove_harddisk (){
Write-Host " This script will remvoe the hard disks from assigned VMs as mentioned in the imported CSV file"
Foreach ($hd in $HDPath) {
$vm = $hd.Parent
$vmdkPath = $hd.Filename 
$id = $hd.Id
$deviceName = $hd.naa
$datastore = $hd.datastore
$datastorePath = $hd.datastorepath
#------------------------------
Get-VM $vm | Get-Harddisk -Id $Id | Remove-Harddisk -Confirm:$false
Write-Host "Now the disk with ID $id and with VMDK path $vmdkPath is removed from $vm as mentioned in the imported CSV file"
}
}


function precheck_harddisk (){
Write-Host " This script will check the status of hard disks mentioned in the imported CSV file"
Foreach ($hd in $HDPath) {
$vm = $hd.Parent
$vmdkPath = $hd.Filename 
$id = $hd.Id
$deviceName = $hd.naa
$datastore = $hd.datastore
$datastorePath = $hd.datastorepath
#------------------------------
Get-VM $vm | Get-Harddisk -Id $Id |select Name,Parent,Filename,Id,@{name="UUID";expr={$_.extensiondata.backing.uuid}}|FT -wrap
}
}


####  Connect to vcenter ########
Write-host "Checking loading VMWare PS Snapin ( It might take a minute or two) " -ForegroundColor Yellow
if ( (Get-PSSnapin -Name VMware.VimAutomation.Core -ErrorAction SilentlyContinue) -eq $null ) {     Add-PsSnapin VMware.VimAutomation.Core }


$VCStatus = Connect-VIServer $vCenter -username $vcuserName  -password $vcPassword
if ( $VCStatus ) {
        
        Write-Host "Please enter the file path as input which has list of hard disks with virtual disk IDs and VM names in CSV file format <--- " -ForegroundColor Black -BackgroundColor Yellow -NoNewline
        $HDList = [String](read-host)
        $HDPath = Import-CSV $HDList
        Write-Host "Please enter the list of VMs seperated by Comma and asking to get the hard disks list post removal <--- " -ForegroundColor Black -BackgroundColor Yellow -NoNewline
        $VMsList = [String](read-host)
        $VMArray = $VMsList.split(",")
 

            #### Checking if any active VMDK and VMs using on each datastore ####

        do {
                 precheck_harddisk
                 Write-Host "Are you sure you want to proceed with Harddisk removal from VMs (Yes/No): " -ForegroundColor Yellow -NoNewline
                 $UserConfirmation = Read-Host
         } Until ( ($UserConfirmation -eq "Yes") -or ($UserConfirmation -eq "No"))

        if ( $UserConfirmation -eq "No" ){
                Write-host "Exiting" -ForegroundColor Red
                exit
        }
        
      
          #### User Confirmation before removing hard disks from VMs ####
        do {
                 Write-Host "Are you sure you want to remove the hard disks from VMs (Yes/No): " -ForegroundColor Yellow -NoNewline
                 $UserConfirmation = Read-Host
         } Until ( ($UserConfirmation -eq "Yes") -or ($UserConfirmation -eq "No"))

        if ( $UserConfirmation -eq "No" ){
                Write-host "Exiting" -ForegroundColor Red
                exit
        }
        
       remove_harddisk

        Write-Host "Now datastores are removed from all VMs"  -ForegroundColor Yellow
         Write-Host "Here is the current hard disks list on these VMs $VMsList after removal of disks"  -ForegroundColor Yellow
        foreach ($vmname in $VMArray) {
        Get-VM $vmname |Get-HardDisk|select Name,Parent,Filename,Id,@{name="UUID";expr={$_.extensiondata.backing.uuid}}|FT -AutoSize
        }
        Write-Host "Disconnecting the vCenter"  -ForegroundColor Yellow
        Disconnect-VIServer $vCenter -Confirm:$false
        }
        else {
        }
