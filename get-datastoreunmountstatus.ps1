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