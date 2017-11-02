<# Author: Raja Pamuluri
Author Email: raja.converged@gmail.com
description: This script will be used for datastore reclaim at VMWare level and Datastore names will be the input file
Version: 3.0.1
#>

################# User Agreement ###########
$ChangeID
$ESXiClusterName
###$outputof_script =
Write-Host "This script will provide the current status of datastores which are given in the input file and then unmount, detach one by one followed-by rescan " -ForegroundColor Yellow
Write-Host "Kindly understand the implications of datastore unmount & detach at ESXi layer before proceeding" -ForegroundColor Yellow 
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

function unmout_datastore (){
Foreach ($ds in $DSPath) {
#
#Things you can change as input variable for every object execution.
###Write-Host "This script will unmount the Datastore $ds as mentioned in input file"  -ForegroundColor Green
#Get-Datastore -Name $ds |get-vm | Get-HardDisk |select Name,CapacityGB,Filename,Parent|Select-String "$ds"
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
#Get-Datastore -Name $ds |get-vm | Get-HardDisk |select Name,CapacityGB,Filename,Parent|Select-String "$ds"
#Write-Host "Now we are going to unmount the $DSList from all the hosts as shown above"
get-datastore -name $ds|Detach-SCSILun -Confirm:$false -Verbose
Start-Sleep -Seconds 10
Write-Host "Here is the  status of $ds Datastore after detach"  -ForegroundColor Green
get-datastore -name $ds |Get-DatastoreMountInfo |sort Datastore,VMHost| FT -AutoSize
}
Write-Host "Now running vmfs & HBAs rescan on all hosts of cluster $ESXiClusterName"  -ForegroundColor Green
get-cluster -Name $ESXiClusterName |Get-VMHost |Get-VMHostStorage -RescanAllHba -RescanVmfs
}

function precheck_datastore (){
Foreach ($ds in $DSPath) {
#
#Things you can change as input variable for every object execution.
Write-Host "This function will perform all pre-checks on datastore $ds and all values should be True before we proceed with unmount & detach..it takes couple of minutes"  -ForegroundColor Green
Get-Datastore -Name $ds |Get-DatastoreUnmountStatus |Out-Host
Get-Datastore -Name $ds |Get-VM |FT |Out-Host
}
}

####  Connect to vcenter ########
Write-host "Checking loading VMWare PS Snapin ( It might take a minute or two) " -ForegroundColor Yellow
if ( (Get-PSSnapin -Name VMware.VimAutomation.Core -ErrorAction SilentlyContinue) -eq $null ) { Add-PsSnapin VMware.VimAutomation.Core }

$VCStatus = Connect-VIServer $vCenter -username $vcuserName  -password $vcPassword
if ( $VCStatus ) {
     
        Write-Host "Please enter the file path as input which has list of datastore names for reclaim <--- " -ForegroundColor Yellow -NoNewline
        $DSList = [String](read-host)
        $DSPath = Get-Content $DSList
        ###Write-Host "Here is the list of active VMDKs targetted datastores and mount info"
        ###Foreach ($ds in $DSPath2) {
        ###Get-Datastore -Name $ds |get-vm | Get-HardDisk |select Name,CapacityGB,Filename,Parent|Select-String "$ds"
        ###           }
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
         Write-Host "Disconnecting the vCenter"  -ForegroundColor Yellow
        Disconnect-VIServer $vCenter -Confirm:$false
        ### send-mailmessage -from "powercli_reclaim_script@AAAAAAAAAAAA.com" -to "rajasekhar.reddy@AAAAAAAAAA.com" -subject "This is output of datastore reclaim script executed on vCenter Server $vCenter by user $vcuserName  " -body $output -priority High -DNO onSuccess, onFailure -smtpServer --------
        }
        else {
        }
