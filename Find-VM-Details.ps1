#Cleaning the Powershell screen on your system

cls

#
# Start off by asking what tasks they are interested in completing
# In order to add additional tasks, add in additional write-host
# lines and then create a function to allow the option to be run
#
Write-host "This script will help you to identify the vCenter name, ESXi cluster name & VMHost name for the given VM which is hosting in ABC domain vCenters:" -ForegroundColor Green
Write-host ""
Write-Host "##############################################################################" -ForegroundColor Cyan
$vcuserName =Read-host "Enter Username (<DOMAINNAME>\<UserName>) to connect all vCenter servers in ABC domain:"
$SecurePassword = Read-Host -assecurestring "Please enter your password: " 
$BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
$vcPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
Write-Host "Please enter the VM Name which you want to know where it is currently hosting : " -ForegroundColor Green -NoNewline
$VMName = [string] (read-host)
Write-Host "##############################################################################" -ForegroundColor Cyan
Write-Host ""
Write-Host "Now we are connecting to all ABC.COM domain vCenter servers " -ForegroundColor Green 
$VCStatus = Connect-VIServer vcenter1.abc.com,vcenter2.abc.com,vcenter3.abc.com,vcenter4.abc.com,vcenter5.abc.com,vcenter6.abc.com,vcenter7.abc.com -User $vcuserName -Password $vcPassword
if ( $VCStatus ) {
     
New-VIProperty -Name vCenterServer -ObjectType VirtualMachine -Value {$Args[0].Uid.Split(":")[0].Split("@")[1]} |FT -AutoSize
Write-Host "Please find details of $VMName and you can login to the respective vCenter if needed:" -ForegroundColor Green
get-vm $VMName |select Name,vCenterServer,@{Name = "ESXiCluster";expr={get-cluster -VM $VMName}},@{Name = "Datacenter";expr={Get-VM $VMName|Get-Datacenter }},@{Name = "ESXI Host";expr={Get-VMHost -vm  $VMName }},@{N="IP";E={@($_.Guest.IPAddress)}},@{N="Guest State";E={@($_.Guest.State)}},@{Name = "Datastores List";expr={Get-VM $VMName |Get-Datastore }} |FT -Wrap
Write-Host "Now disconnecting all vCenters from this powerCLI host:" -ForegroundColor White
Disconnect-VIServer -Server * -Force -Confirm:$false
                }
else {
}

