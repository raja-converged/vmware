Write-Host "Enter the cluster name on which all hosts you wnat start SSH:" -ForegroundColor Yellow
$esxiclustername = [string](Read-Host)
Write-Host "Here is the current status of SSH service on all hosts"
Get-cluster -Name $esxiclustername |Get-VMHost |Get-VMHostService | where Label -Match SSH |select VMHost,Key,Label,Policy,Running,Required |FT -AutoSize
do { Write-Host "Are you sure you want start SSH service on all ESXi hosts of $esxiclustername (Yes / No) "
$userconfirmation = Read-Host
} until (($userconfirmation -eq "Yes") -or ($userconfirmation -eq "No"))
if ($userconfirmation -eq "Yes") {
Write-Host "Now starting SSH service on all hosts of cluster $esxiclustername"
Get-cluster -Name $esxiclustername |Get-VMHost |foreach { Start-VMHostService -HostService ($_ | Get-VMHostService | Where { $_.Key -eq "TSM-SSH"})|select VMHost,Key,Label,Policy,Running,Required |FT -AutoSize}
}
else 
{ 
exit
}
