function New-PfaDbSnapshot
{
<#
.SYNOPSIS
A PowerShell function to create a FlashArray snapshot of the volume that a database resides on.

.DESCRIPTION
A PowerShell function to create a FlashArray snapshot of the volume that a database resides on, based in the
values of the following parameters:

.PARAMETER Database
The name of the database to refresh, note that it is assumed that source and target database(s) are named the same.
This parameter is MANDATORY.

.PARAMETER SqlInstance
This can be one or multiple SQL Server instance(s) that host the database(s) to be refreshed, in the case that the
function is invoked  to refresh databases  across more than one  instance, the list  of target instances should be
spedcified as an array of strings, otherwise a single string representing the target  instance will suffice.  This 
parameter is MANDATORY.

.PARAMETER PfaEndpoint
The ip address representing the FlashArray that the volumes for the source and refresh target databases reside on.
This parameter is MANDATORY.

.PARAMETER PfaCredentials
A PSCredential object containing the username and password of the FlashArray to connect to. For instruction on how
to store and retrieve these from an encrypted file, refer to this article https://www.purepowershellguy.com/?p=8431

.EXAMPLE
New-PfaDbSnapshot -Database       tpch-no-compression         
                  -SqlInstance    z-sql2016-devops-prd  
                  -PfaEndpoint    10.225.112.10      
                  -PfaCredentials $Cred

Create a snapshot of FlashArray volume that stores the tpch-no-compression database on the z-sql2016-devops-prd instance  
-RefreshSource parameter.
.NOTES
                               Known Restrictions
                               ------------------

1. This function does not currently work for databases associated with
   failover cluster instances.

2. This function cannot be used to seed secondary replicas in availability
   groups using databases in the primary replica.

3. The function assumes that all database files and the transaction log
   reside on a single FlashArray volume.

                    Obtaining The PureStorageDbaTools Module
                    ----------------------------------------

This function is part of the PureStorageDbaTools module, it is recommend
that the module is always obtained from the PowerShell gallery:

https://www.powershellgallery.com/packages/PureStorageDbaTools

Note that it has dependencies on the dbatools and PureStoragePowerShellSDK
modules which are installed as part of the installation of this module.

                                    Licence
                                    -------

This function is available under the Apache 2.0 license, stipulated as follows:

Copyright 2017 Pure Storage, Inc.
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at
    http://www.apache.org/licenses/LICENSE-2.0
Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on  an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
.LINK
https://www.powershellgallery.com/packages/PureStorageDbaTools
https://www.purepowershellguy.com/?p=8431
Invoke-PfaDbaRefresh
Enable-DataMasks
#>
    param(
         [parameter(mandatory=$true)] [string]                                    $Database          
        ,[parameter(mandatory=$true)] [string]                                    $SqlInstance   
        ,[parameter(mandatory=$true)] [string]                                    $PfaEndpoint       
        ,[parameter(mandatory=$true)] [System.Management.Automation.PSCredential] $PfaCredentials
    )

    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())

    if ( ! $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) ) {
        Write-Error "This function needs to be invoked within a PowerShell session with elevated admin rights"
        Return
    }

    try {
        $FlashArray = New-PfaArray -EndPoint $PfaEndpoint -Credentials $PfaCredentials -IgnoreCertificateError
    }
    catch {
        $ExceptionMessage = $_.Exception.Message
        Write-Error "Failed to connect to FlashArray endpoint $PfaEndpoint with: $ExceptionMessage"
        Return
    }

    Write-Colour -Text "FlashArray endpoint       : ", "CONNECTED" -Color Yellow, Green

    try {
        $DestDb = Get-DbaDatabase -sqlinstance $SqlInstance -Database $Database
    }
    catch {
        $ExceptionMessage = $_.Exception.Message
        Write-Error "Failed to connect to destination database $SqlInstance.$Database with: $ExceptionMessage"
        Return
    }

    Write-Colour -Text "Target SQL Server instance: ", $SqlInstance, " - ", "CONNECTED" -Color Yellow, Green, Green, Green
    Write-Colour -Text "Target windows drive      : ", $DestDb.PrimaryFilePath.Split(':')[0] -Color Yellow, Green

    try {
        $TargetServer  = (Connect-DbaInstance -SqlInstance $SqlInstance).ComputerNamePhysicalNetBIOS
    }
    catch {
        Write-Error "Failed to determine target server name with: $ExceptionMessage"        
    }

    Write-Colour -Text "Target SQL Server host    : ", $TargetServer -ForegroundColor Yellow, Green

    $GetDbDisk = { param ( $Db ) 
        $DbDisk = Get-Partition -DriveLetter $Db.PrimaryFilePath.Split(':')[0]| Get-Disk
        return $DbDisk
    }
    
    try {
        $TargetDisk = Invoke-Command -ComputerName $TargetServer -ScriptBlock $GetDbDisk -ArgumentList $DestDb
    }
    catch {
        $ExceptionMessage  = $_.Exception.Message
        Write-Error "Failed to determine the windows disk snapshot target with: $ExceptionMessage"
        Return
    }

    Write-Colour -Text "Target disk serial number : ", $TargetDisk.SerialNumber -Color Yellow, Green

    try {
        $TargetVolume = Get-PfaVolumes -Array $FlashArray | Where-Object { $_.serial -eq $TargetDisk.SerialNumber } | Select-Object name
    }
    catch {
        $ExceptionMessage = $_.Exception.Message
        Write-Error "Failed to determine snapshot FlashArray volume with: $ExceptionMessage"
        Return
    }

    $SnapshotSuffix = $SqlInstance.Replace('\', '-') + '-' + $Database + '-' +  $(Get-Date).Hour +  $(Get-Date).Minute +  $(Get-Date).Second
    Write-Colour -Text "Snapshot target Pfa volume: ", $TargetVolume.name -Color Yellow, Green
    Write-Colour -Text "Snapshot suffix           : ", $SnapshotSuffix -Color Yellow, Green

    try {
        New-PfaVolumeSnapshots -Array $FlashArray -Sources $TargetVolume.name -Suffix $SnapshotSuffix
    }
    catch {
        $ExceptionMessage = $_.Exception.Message
        Write-Error "Failed to create snapshot for target database FlashArray volume with: $ExceptionMessage"
        Return
    }
} 
function DbRefresh
{
    param(
        [parameter(mandatory=$true)]  [string] $DestSqlInstance   
       ,[parameter(mandatory=$true)]  [string] $RefreshDatabase       
       ,[parameter(mandatory=$true)]  [string] $PfaEndpoint       
       ,[parameter(mandatory=$true)]  [System.Management.Automation.PSCredential] $PfaCredentials
       ,[parameter(mandatory=$true)]  [string] $SourceVolume
       ,[parameter(mandatory=$false)] [string] $StaticDataMaskFile
       ,[parameter(mandatory=$false)] [bool]   $ForceDestDbOffline       
       ,[parameter(mandatory=$false)] [bool]   $NoPsRemoting
       ,[parameter(mandatory=$false)] [bool]   $PromptForSnapshot              
       ,[parameter(mandatory=$false)] [bool]   $ApplyDataMasks
    )

    try {
        $FlashArray = New-PfaArray -EndPoint $PfaEndpoint -Credentials $PfaCredentials -IgnoreCertificateError
    }
    catch {
        $ExceptionMessage = $_.Exception.Message
        Write-Error "Failed to connect to FlashArray endpoint $PfaEndpoint with: $ExceptionMessage"
        Return
    }

    try {
        $DestDb = Get-DbaDatabase -sqlinstance $DestSqlInstance -Database $RefreshDatabase
    }
    catch {
        $ExceptionMessage = $_.Exception.Message
        Write-Error "Failed to connect to destination database $DestSqlInstance.$Database with: $ExceptionMessage"
        Return
    }

    Write-Host " "
    Write-Colour -Text "Target SQL Server instance: ", $DestSqlInstance, "- CONNECTED" -ForegroundColor Yellow, Green, Green

    try {
        $TargetServer  = (Connect-DbaInstance -SqlInstance $DestSqlInstance).ComputerNamePhysicalNetBIOS
    }
    catch {
        Write-Error "Failed to determine target server name with: $ExceptionMessage"        
    }

    Write-Colour -Text "Target SQL Server host    : ", $TargetServer -ForegroundColor Yellow, Green
 
    $GetDbDisk = { param ( $Db ) 
        $DbDisk = Get-Partition -DriveLetter $Db.PrimaryFilePath.Split(':')[0]| Get-Disk
        return $DbDisk
    }

    $GetVolumeLabel = {  param ( $Db )
        Write-Verbose "Target database drive letter = $Db.PrimaryFilePath.Split(':')[0]"
        $VolumeLabel = $(Get-Volume -DriveLetter $Db.PrimaryFilePath.Split(':')[0]).FileSystemLabel
        Write-Verbose "Target database windows volume label = <$VolumeLabel>"
        return $VolumeLabel
    }

    try {
        if ( $NoPsRemoting ) {
            $DestDisk = Invoke-Command -ScriptBlock $GetDbDisk -ArgumentList $DestDb
            $DestVolumeLabel = Invoke-Command -ScriptBlock $GetVolumeLabel -ArgumentList $DestDb
        }
        else {
            $DestDisk = Invoke-Command -ComputerName $TargetServer -ScriptBlock $GetDbDisk -ArgumentList $DestDb
            $DestVolumeLabel = Invoke-Command -ComputerName $TargetServer -ScriptBlock $GetVolumeLabel -ArgumentList $DestDb
        }
    }
    catch {
        $ExceptionMessage = $_.Exception.Message
        Write-Error "Failed to determine destination database disk with: $ExceptionMessage"
        Return
    }

    Write-Colour -Text "Target drive letter       : ", $DestDb.PrimaryFilePath.Split(':')[0] -ForegroundColor Yellow, Green

    try {
        $DestVolume = Get-PfaVolumes -Array $FlashArray | Where-Object { $_.serial -eq $DestDisk.SerialNumber } | Select-Object name
        
        if (!$DestVolume) {
            throw "Failed to determine destination FlashArray volume, check that source and destination volumes are on the SAME array"
        } 
    }
    catch {
        $ExceptionMessage = $_.Exception.Message
        Write-Error "Failed to determine destination FlashArray volume with: $ExceptionMessage"
        Return
    }

    Write-Colour -Text "Target Pfa volume         : ", $DestVolume.name -ForegroundColor Yellow, Green

    $OfflineDestDisk = { param ( $DiskNumber, $Status ) 
        Set-Disk -Number $DiskNumber -IsOffline $Status
    }

    try {
        if ( $ForceDestDbOffline ) {
            $ForceDatabaseOffline = "ALTER DATABASE [$RefreshDatabase] SET OFFLINE WITH ROLLBACK IMMEDIATE"
            Invoke-DbaQuery -ServerInstance $DestSqlInstance -Database $RefreshDatabase -Query $ForceDatabaseOffline
        }
        else {
            $DestDb.SetOffline()
        }
    }
    catch {
        $ExceptionMessage = $_.Exception.Message
        Write-Error "Failed to offline database $Database with: $ExceptionMessage"
        Return
    }

    Write-Colour -Text "Target database           : ", "OFFLINE" -ForegroundColor Yellow, Green

    try {
        if ( $NoPsRemoting ) {
            Invoke-Command -ScriptBlock $OfflineDestDisk -ArgumentList $DestDisk.Number, $True
        }
        else {
            Invoke-Command -ComputerName $TargetServer -ScriptBlock $OfflineDestDisk -ArgumentList $DestDisk.Number, $True
        }
    }
    catch {
        $ExceptionMessage = $_.Exception.Message
        Write-Error "Failed to offline disk with : $ExceptionMessage" 
        Return
    }

    Write-Colour -Text "Target windows disk       : ", "OFFLINE" -ForegroundColor Yellow, Green

    $StartCopyVolMs = Get-Date

    try {
        Write-Colour -Text "Source Pfa volume         : ", $SourceVolume -ForegroundColor Yellow, Green
        New-PfaVolume -Array $FlashArray -VolumeName $DestVolume.name -Source $SourceVolume -Overwrite
    }
    catch {
        $ExceptionMessage = $_.Exception.Message
        Write-Error "Failed to refresh test database volume with : $ExceptionMessage" 
        Set-Disk -Number $DestDisk.Number -IsOffline $False
        $DestDb.SetOnline()
        Return
    }

    Write-Colour -Text "Volume overwrite          : ", "SUCCESSFUL" -ForegroundColor Yellow, Green
    $EndCopyVolMs = Get-Date
    Write-Colour -Text "Overwrite duration (ms)   : ", ($EndCopyVolMs - $StartCopyVolMs).TotalMilliseconds -Color Yellow, Green

    $SetVolumeLabel = { param ( $Db, $DestVolumeLabel )
        Set-Volume -DriveLetter $Db.PrimaryFilePath.Split(':')[0] -NewFileSystemLabel $DestVolumeLabel
    }

    try {
        if ( $NoPsRemoting ) {
            Invoke-Command -ScriptBlock $OfflineDestDisk -ArgumentList $DestDisk.Number, $False
            Invoke-Command -ScriptBlock $SetVolumeLabel -ArgumentList $DestDb, $DestVolumeLabel
        }
        else {
            Invoke-Command -ComputerName $TargetServer -ScriptBlock $OfflineDestDisk -ArgumentList $DestDisk.Number, $False
            Invoke-Command -ComputerName $TargetServer -ScriptBlock $SetVolumeLabel -ArgumentList $DestDb, $DestVolumeLabel
        }
    }
    catch {
        $ExceptionMessage = $_.Exception.Message
        Write-Error "Failed to online disk with : $ExceptionMessage" 
        Return
    }

    Write-Colour -Text "Target windows disk       : ", "ONLINE" -ForegroundColor Yellow, Green

    try {
        $DestDb.SetOnline()
    }
    catch {
        $ExceptionMessage = $_.Exception.Message
        Write-Error "Failed to online database $Database with: $ExceptionMessage"
        Return
    }

    Write-Colour -Text "Target database           : ", "ONLINE" -ForegroundColor Yellow, Green

    if ( $ApplyDataMasks ) {
        Write-Host "Applying SQL Server dynamic data masks to $RefreshDatabase on SQL Server instance $DestSqlInstance" -ForegroundColor Yellow

        try {
            Invoke-DynamicDataMasking -SqlInstance $DestSqlInstance -Database $RefreshDatabase
            Write-Host "SQL Server dynamic data masking has been applied" -ForegroundColor Yellow
        }
        catch {
            $ExceptionMessage = $_.Exception.Message
            Write-Error "Failed to apply SQL Server dynamic data masks to $Database on $DestSqlInstance with: $ExceptionMessage"
            Return    
        }
    }
    elseif ([System.IO.File]::Exists($StaticDataMaskFile)) {
        Write-Color -Text "Static data mask target   : ", $DestSqlInstance, " - ", $RefreshDatabase -Color Yellow, Green, Green, Green

        try {
            Invoke-StaticDataMasking -SqlInstance $DestSqlInstance -Database $RefreshDatabase -DataMaskFile $StaticDataMaskFile
            Write-Color -Text "Static data masking       : ", "APPLIED" -ForegroundColor Yellow, Green

        }
        catch {
            $ExceptionMessage = $_.Exception.Message
            Write-Error "Failed to apply static data masking to $Database on $DestSqlInstance with: $ExceptionMessage"
            Return    
        }
    }

    Repair-DbaDbOrphanUser -SqlInstance $DestSqlInstance -Database $RefreshDatabase | Out-Null
    Write-Color -Text "Orphaned users            : ", "REPAIRED" -ForegroundColor Yellow, Green
}

function Invoke-PfaDbRefresh
{
<#
.SYNOPSIS
A PowerShell function to refresh one or more SQL Server databases (the destination) from either a snapshot or 
database.

.DESCRIPTION
A PowerShell function to refresh one or more SQL Server databases either from:

- a snapshot specified by its name
- a snapshot picked from a list associated with the volume the source database resides on 
- a source database directly

This  function will detect and repair  orpaned users in refreshed databases and  optionally 
apply data masking, based on either:

- the dynamic data masking functionality available in SQL Server version 2016 onwards,
- static data masking built into dbatooils from version 0.9.725, refer to https://dbatools.io/mask/

.PARAMETER RefreshDatabase
The name of the database to refresh, note that it is assumed that source and target database(s) are named the same.
This parameter is MANDATORY.

.PARAMETER RefreshSource
If the RefreshFromSnapshot flag is specified, this parameter takes the name of a snapshot, otherwise this takes the
name of the source SQL Server instance. This parameter is MANDATORY.

.PARAMETER DestSqlInstance
This can be one or multiple SQL Server instance(s) that host the database(s) to be refreshed, in the case that the
function is invoked  to refresh databases  across more than one  instance, the list  of target instances should be
spedcified as an array of strings, otherwise a single string representing the target  instance will suffice.  This 
parameter is MANDATORY.

.PARAMETER PfaEndpoint
The ip address representing the FlashArray that the volumes for the source and refresh target databases reside on.
This parameter is MANDATORY.

.PARAMETER PfaCredentials
A PSCredential object containing the username and password of the FlashArray to connect to. For instruction on how
to store and retrieve these from an encrypted file, refer to this article https://www.purepowershellguy.com/?p=8431

.PARAMETER PollJobInterval
Interval at which background job status is poll, if this is ommited polling will not take place. Note that this parameter
is not applicable is the PromptForSnapshot switch is specified.

.PARAMETER PromptForSnapshot
This is an optional flag that if specified will result in a list of snapshots  being displayed for the database volume on
the FlashArray that the user can select one from. Despite the source of the refresh  operation being an existing snapshot 
, the source instance still has to be specified  by the RefreshSource parameter in  order that the function can determine
which FlashArray volume to list existing snapshots for.

.PARAMETER RefreshFromSnapshot
This is an optional flag that if specified causes the function to expect the RefreshSource  parameter to be supplied with
the name of an existing snapshot.

.PARAMETER NoPsRemoting
The commands that off and online the windows volumes associated with the refresh target databases will use Invoke-Command
with powershell remoting unless this flag is specified. Certain tools that can invoke PowerShell, Ansible for example  do
not permit double-hop authentication unless CredSSP authentication is  used. For security purposes  Kerberos is recommend
over CredSSP, however this does not support double-hop authentication, in which case this flag should be specified.

.PARAMETER ApplyDataMasks
Specifying  this optional  masks will  cause data  masks to  be applied , as  per the  dynamic data  masking feature first 
introduced with SQL Server 2016, this results in this function invoking the Enable-DataMasks  function to be invoked.  For
documentation on Enable-DataMasks, use the command Get-Help Enable-DataMasks [-Detailed].

.PARAMETER ForceDestDbOffline
Specifying this switch will cause refresh target databases for be forced offline via WITH ROLLBACK IMMEDIATE.

.PARAMETER StaticDataMaskFile
If this parameter is present and has a file path associated with it,  the data masking available in version 0.9.725 of the
dbatools module  onwards will be applied  to the refreshed database.  The use of this is  contigent on the data  mask file
being created and populated in the first place as per this blog post: https://dbatools.io/mask/ .

.EXAMPLE
Invoke-PfaDbRefresh -RefreshDatabase   tpch-no-compression  `
                    -RefreshSource     z-sql2016-devops-prd `
                    -DestSqlInstance   z-sql2016-devops-tst `
                    -PfaEndpoint       10.225.112.10        `
                    -PfaCredentials    $Creds               `
                    -PromptForSnapshot

Refresh a single database from a snapshot selected from a list of snapshots associated with the volume specified by the RefreshSource parameter.
.EXAMPLE
$Targets = @("z-sql2016-devops-tst", "z-sql2016-devops-dev")
Invoke-PfaDbRefresh -RefreshDatabase   tpch-no-compression  `
                    -RefreshSource     z-sql2016-devops-prd `
                    -DestSqlInstance   $Targets             `
                    -PfaEndpoint       10.225.112.10        `
                    -PfaCredentials    $Creds               `
                    -PromptForSnapshot

Refresh multiple databases from a snapshot selected from a list of snapshots associated with the volume specified by the RefreshSource parameter.
.EXAMPLE
Invoke-PfaDbRefresh -RefreshDatabase    tpch-no-compression  `
                    -RefreshSource      source-snap          `
                    -DestSqlInstance    z-sql2016-devops-tst `
                    -PfaEndpoint        10.225.112.10        `
                    -PfaCredentials     $Creds               `
                    -RefreshFromSnapshot

Refresh a single database using the snapshot specified by the RefreshSource parameter.
.EXAMPLE
$Targets = @("z-sql2016-devops-tst", "z-sql2016-devops-dev")
Invoke-PfaDbRefresh -RefreshDatabase    tpch-no-compression `
                    -RefreshSource      source-snap         `
                    -DestSqlInstance    $Targets            `
                    -PfaEndpoint        10.225.112.10       `
                    -PfaCredentials     $Creds              `
                    -RefreshFromSnapshot

Refresh multiple databases using the snapshot specified by the RefreshSource parameter.
.EXAMPLE
Invoke-PfaDbRefresh -$RefreshDatabase   tpch-no-compression  `
                    -RefreshSource      z-sql-prd            `
                    -DestSqlInstance    z-sql2016-devops-tst `
                    -PfaEndpoint        10.225.112.10        `
                    -PfaCredentials     $Creds               

Refresh a single database from the database specified by the SourceDatabase parameter residing on the instance specified by RefreshSource.
.EXAMPLE
$Targets = @("z-sql2016-devops-tst", "z-sql2016-devops-dev")
Invoke-PfaDbRefresh -$RefreshDatabase   tpch-no-compression `
                    -RefreshSource      z-sql-prd           `
                    -DestSqlInstance    $Targets            `
                    -PfaEndpoint        10.225.112.10       `
                    -PfaCredentials     $Creds              

Refresh multiple databases from the database specified by the SourceDatabase parameter residing on the instance specified by RefreshSource. 
.EXAMPLE
$Targets = @("z-sql2016-devops-tst", "z-sql2016-devops-dev")
Invoke-PfaDbRefresh -$RefreshDatabase   tpch-no-compression `
                    -RefreshSource      z-sql-prd           `
                    -DestSqlInstance    $Targets            `
                    -PfaEndpoint        10.225.112.10       `
                    -PfaCredentials     $Creds              `
                    -ApplyDataMasks

Refresh multiple databases from the database specified by the SourceDatabase parameter residing on the instance specified by RefreshSource. 
.EXAMPLE
$StaticDataMaskFile = "D:\apps\datamasks\z-sql-prd.tpch-no-compression.tables.json"
$Targets              = @("z-sql2016-devops-tst", "z-sql2016-devops-dev")
Invoke-PfaDbRefresh -$RefreshDatabase   tpch-no-compression `
                    -RefreshSource      z-sql-prd           `
                    -DestSqlInstance    $Targets            `
                    -PfaEndpoint        10.225.112.10       `
                    -PfaCredentials     $Creds              `
                    -StaticDataMaskFile $StaticDataMaskFile

Refresh multiple databases from the database specified by the SourceDatabase parameter residing on the instance specified by RefreshSource and apply SQL Server dynamic data masking to each database.
.EXAMPLE
$StaticDataMaskFile = "D:\apps\datamasks\z-sql-prd.tpch-no-compression.tables.json"
$Targets              = @("z-sql2016-devops-tst", "z-sql2016-devops-dev")
Invoke-PfaDbRefresh -$RefreshDatabase   tpch-no-compression `
                    -RefreshSource      z-sql-prd           `
                    -DestSqlInstance    $Targets            `
                    -PfaEndpoint        10.225.112.10       `
                    -PfaCredentials     $Creds              `
                    -ForceDestDbOffline                     `
                    -StaticDataMaskFile $StaticDataMaskFile

Refresh multiple databases from the database specified by the SourceDatabase parameter residing on the instance specified by RefreshSource and apply SQL Server dynamic data masking to each database.
All databases to be refreshed are forced offline prior to their underlying FlashArray volumes being overwritten.
.EXAMPLE
$StaticDataMaskFile = "D:\apps\datamasks\z-sql-prd.tpch-no-compression.tables.json"
$Targets              = @("z-sql2016-devops-tst", "z-sql2016-devops-dev")
Invoke-PfaDbRefresh -$RefreshDatabase   tpch-no-compression `
                    -RefreshSource      z-sql-prd           `
                    -DestSqlInstance    $Targets            `
                    -PfaEndpoint        10.225.112.10       `
                    -PfaCredentials     $Creds
                    -PollJobInterval    10              `
                    -ForceDestDbOffline                     `
                    -StaticDataMaskFile $StaticDataMaskFile

Refresh multiple databases from the database specified by the SourceDatabase parameter residing on the instance specified by RefreshSource and apply SQL Server dynamic data masking to each database.
All databases to be refreshed are forced offline prior to their underlying FlashArray volumes being overwritten. Poll the status of the refresh jobs once every 10 seconds.
.NOTES
                               Known Restrictions
                               ------------------

1. This function does not currently work for databases associated with
   failover cluster instances.

2. This function cannot be used to seed secondary replicas in availability
   groups using databases in the primary replica.

3. The function assumes that all database files and the transaction log
   reside on a single FlashArray volume.

                    Obtaining The PureStorageDbaTools Module
                    ----------------------------------------

This function is part of the PureStorageDbaTools module, it is recommend
that the module is always obtained from the PowerShell gallery:

https://www.powershellgallery.com/packages/PureStorageDbaTools

Note that it has dependencies on the dbatools and PureStoragePowerShellSDK
modules which are installed as part of the installation of this module.

                                    Licence
                                    -------

This function is available under the Apache 2.0 license, stipulated as follows:

Copyright 2017 Pure Storage, Inc.
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at
    http://www.apache.org/licenses/LICENSE-2.0
Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on  an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
.LINK
https://www.powershellgallery.com/packages/PureStorageDbaTools
https://www.purepowershellguy.com/?p=8431
https://dbatools.io/mask/
New-PfaDbSnapshot
Enable-DataMasks
#>
    param(
          [parameter(mandatory=$true)]  [string]                                    $RefreshDatabase          
         ,[parameter(mandatory=$true)]  [string]                                    $RefreshSource 
         ,[parameter(mandatory=$true)]  [string[]]                                  $DestSqlInstances   
         ,[parameter(mandatory=$true)]  [string]                                    $PfaEndpoint       
         ,[parameter(mandatory=$true)]  [System.Management.Automation.PSCredential] $PfaCredentials
         ,[parameter(mandatory=$false)] [int]                                       $PollJobInterval
         ,[parameter(mandatory=$false)] [switch]                                    $PromptForSnapshot
         ,[parameter(mandatory=$false)] [switch]                                    $RefreshFromSnapshot
         ,[parameter(mandatory=$false)] [switch]                                    $NoPsRemoting
         ,[parameter(mandatory=$false)] [switch]                                    $ApplyDataMasks
         ,[parameter(mandatory=$false)] [switch]                                    $ForceDestDbOffline 
         ,[parameter(mandatory=$false)] [string]                                    $StaticDataMaskFile
    )

    $StartMs = Get-Date

    if ( $PromptForSnapshot.IsPresent.Equals($false) -And $RefreshFromSnapshot.IsPresent.Equals($false) ) { 
        try {
            $SourceDb = Get-DbaDatabase -sqlinstance $RefreshSource -Database $RefreshDatabase
        }
        catch {
            $ExceptionMessage = $_.Exception.Message
            Write-Error "Failed to connect to source database $RefreshSource.$Database with: $ExceptionMessage"
            Return
        }

        Write-Color -Text "Source SQL Server instance: ", $RefreshSource, " - CONNECTED" -Color Yellow, Green, Green

        try {
            $SourceServer = (Connect-DbaInstance -SqlInstance $RefreshSource).ComputerNamePhysicalNetBIOS
        }
        catch {
            Write-Error "Failed to determine target server name with: $ExceptionMessage"        
        }
    }

    try {
        $FlashArray = New-PfaArray -EndPoint $PfaEndpoint -Credentials $PfaCredentials -IgnoreCertificateError
    }
    catch {
        $ExceptionMessage = $_.Exception.Message
        Write-Error "Failed to connect to FlashArray endpoint $PfaEndpoint with: $ExceptionMessage"
        Return
    }

    Write-Color -Text "FlashArray endpoint       : ", "CONNECTED" -ForegroundColor Yellow, Green

    $GetDbDisk = { param ( $Db ) 
        $DbDisk = Get-partition -DriveLetter $Db.PrimaryFilePath.Split(':')[0]| Get-Disk
        return $DbDisk
    }

    $Snapshots = $(Get-PfaAllVolumeSnapshots $FlashArray)
    $FilteredSnapshots = $Snapshots.where({ ([string]$_.Source) -eq $RefreshSource })

    if ( $PromptForSnapshot.IsPresent ) { 
        Write-Host ' '
        for ($i=0; $i -lt $FilteredSnapshots.Count; $i++) {
            Write-Host 'Snapshot ' $i.ToString()
            $FilteredSnapshots[$i]
        }
                   
        $SnapshotId = Read-Host -Prompt 'Enter the number of the snapshot to be used for the database refresh'
    }
    elseif ( $RefreshFromSnapshot.IsPresent.Equals( $false ) ) {
        try {
            if ( $NoPsRemoting.IsPresent ) {
                $SourceDisk = Invoke-Command -ScriptBlock $GetDbDisk -ArgumentList $SourceDb
            }
            else {
                $SourceDisk = Invoke-Command -ComputerName $SourceServer -ScriptBlock $GetDbDisk -ArgumentList $SourceDb
            }
        }
        catch {
            $ExceptionMessage = $_.Exception.Message
            Write-Error "Failed to determine source disk with: $ExceptionMessage"
            Return
        }

        try {
            $SourceVolume = Get-PfaVolumes -Array $FlashArray | Where-Object { $_.serial -eq $SourceDisk.SerialNumber } | Select-Object name
        }
        catch {
            $ExceptionMessage = $_.Exception.Message
            Write-Error "Failed to determine source volume with: $ExceptionMessage"
            Return
        }
    } 

    if ( $PromptForSnapshot.IsPresent ) {
        Foreach($DestSqlInstance in $DestSqlInstances) {
            Invoke-DbRefresh -DestSqlInstance $DestSqlInstance `
                             -RefreshDatabase $RefreshDatabase `
                             -PfaEndpoint     $PfaEndpoint     `
                             -PfaCredentials  $PfaCredentials  `
                             -SourceVolume    $FilteredSnapshots[$SnapshotId]
        }
    }
    else {
        $JobNumber = 1
        Foreach($DestSqlInstance in $DestSqlInstances) {
            $JobName = "DbRefresh" + $JobNumber
            Write-Colour -Text "Refresh background job    : ", $JobName, " - ", "PROCESSING" -Color Yellow, Green, Green, Green
            If ( $RefreshFromSnapshot.IsPresent ) {
                Start-Job -Name $JobName -ScriptBlock $Function:DbRefresh -argumentlist $DestSqlInstance   , `
                                                                                        $RefreshDatabase   , `
                                                                                        $PfaEndpoint       , `
                                                                                        $PfaCredentials    , `
                                                                                        $RefreshSource     , `
                                                                                        $StaticDataMaskFile, `
                                                                                        $ForceDestDbOffline.IsPresent, `
                                                                                        $NoPsRemoting.IsPresent      , `
                                                                                        $PromptForSnapshot.IsPresent , `
                                                                                        $ApplyDataMasks.IsPresent | Out-Null            
            } 
            else {
                Start-Job -Name $JobName -ScriptBlock $Function:DbRefresh -argumentlist $DestSqlInstance   , `
                                                                                        $RefreshDatabase   , `
                                                                                        $PfaEndpoint       , `
                                                                                        $PfaCredentials    , `
                                                                                        $SourceVolume.Name , `
                                                                                        $StaticDataMaskFile, `
                                                                                        $ForceDestDbOffline.IsPresent, `
                                                                                        $NoPsRemoting.IsPresent      , `
                                                                                        $PromptForSnapshot.IsPresent , `
                                                                                        $ApplyDataMasks.IsPresent | Out-Null            
            }
            $JobNumber += 1;
        }

        While (Get-Job -State Running | Where-Object {$_.Name.Contains("DbRefresh")}) {
            if ($PSBoundParameters.ContainsKey('PollJobInterval')) {
                Get-Job -State Running | Where-Object {$_.Name.Contains("DbRefresh")} | Receive-Job
                Start-Sleep -Seconds $PollJobInterval        
            }
            else {
                Start-Sleep -Seconds 1
            }
        }   

        Write-Colour -Text "Refresh background jobs   : ", "COMPLETED" -Color Yellow, Green

        foreach($job in (Get-Job | Where-Object {$_.Name.Contains("DbRefresh")})) {
            $result = Receive-Job $job
            Write-Host $result
        }

        Remove-Job -State Completed
    }

    $EndMs = Get-Date
    Write-Host " "
    Write-Host "-------------------------------------------------------"         -ForegroundColor Green
    Write-Host " "
    Write-Host "D A T A B A S E      R E F R E S H      C O M P L E T E"         -ForegroundColor Green
    Write-Host " "
    Write-Host "              Duration (s) = " ($EndMs - $StartMs).TotalSeconds  -ForegroundColor White
    Write-Host " "
    Write-Host "-------------------------------------------------------"         -ForegroundColor Green
} 

function Enable-DataMasks
{
    param(
        [parameter(mandatory=$true)]  [string] $SqlInstance   
       ,[parameter(mandatory=$true)]  [string] $Database       
    )
    
    Write-Warning "Enable-DataMasks has been deprecated, use Invoke-DynamicDataMasking instead"
}
function Invoke-DynamicDataMasking
{
<#
.SYNOPSIS
A PowerShell function to apply data masks to database columns using the SQL Server dynamic data masking feature.

.DESCRIPTION
This function uses the information stored in the extended properties of a database:
sys.extended_properties.name = 'DATAMASK' to obtain the dynamic data masking function to apply 
at column level. Columns of the following data type are currently supported:

- int
- bigint
- char
- nchar
- varchar
- nvarchar

Using the c_address column in the tpch customer table as an example, the DATAMASK extended property can be applied
to the column as follows:

exec sp_addextendedproperty  
     @name = N'DATAMASK' 
    ,@value = N'(FUNCTION = 'partial(0, "XX", 20)'' 
    ,@level0type = N'Schema', @level0name = 'dbo' 
    ,@level1type = N'Table',  @level1name = 'customer' 
    ,@level2type = N'Column', @level2name = 'c_address'
GO

.PARAMETER SqlInstance
The SQL Server instance of the database that data masking is to be applied to

.PARAMETER Database
The database that data masking is to be applied to

.EXAMPLE
Invoke-DynamicDataMasking -SqlInstance Z-STN-WIN2016-A\DEVOPSDEV `
                          -Database    tpch-no-compression

.NOTES
                    Obtaining The PureStorageDbaTools Module
                    ----------------------------------------

This function is part of the PureStorageDbaTools module, it is recommend
that the module is always obtained from the PowerShell gallery:

https://www.powershellgallery.com/packages/PureStorageDbaTools

Note that it has dependencies on the dbatools and PureStoragePowerShellSDK
modules which are installed as part of the installation of this module.

                                    Licence
                                    -------

This function is available under the Apache 2.0 license, stipulated as follows:

Copyright 2017 Pure Storage, Inc.
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at
    http://www.apache.org/licenses/LICENSE-2.0
Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on  an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
.LINK
https://www.powershellgallery.com/packages/PureStorageDbaTools
https://docs.microsoft.com/en-us/sql/relational-databases/security/dynamic-data-masking?view=sql-server-2017
New-PfaDbSnapshot
Invoke-PfaDbRefresh
#>
    param(
          [parameter(mandatory=$true)]  [string] $SqlInstance   
         ,[parameter(mandatory=$true)]  [string] $Database       
    )

    $sql = @"
BEGIN
	DECLARE  @sql_statement nvarchar(1024)
	        ,@error_message varchar(1024)

	DECLARE apply_data_masks CURSOR FOR
	SELECT       'ALTER TABLE ' + tb.name + ' ALTER COLUMN ' + c.name +
			   + ' ADD MASKED WITH '
			   + CAST(p.value AS char) + ''')'
	FROM       sys.columns c
	JOIN       sys.types t 
	ON         c.user_type_id = t.user_type_id
	LEFT JOIN  sys.index_columns ic 
	ON         ic.object_id = c.object_id
	AND        ic.column_id = c.column_id
	LEFT JOIN  sys.indexes i 
	ON         ic.object_id = i.object_id 
	AND        ic.index_id  = i.index_id
	JOIN       sys.tables tb 
	ON         tb.object_id = c.object_id
	JOIN       sys.extended_properties AS p 
	ON         p.major_id   = tb.object_id 
	AND        p.minor_id   = c.column_id
	AND        p.class      = 1
	WHERE      t.name IN ('int', 'bigint', 'char', 'nchar', 'varchar', 'nvarchar');

	OPEN apply_data_masks  
	FETCH NEXT FROM apply_data_masks INTO @sql_statement;
  
	WHILE @@FETCH_STATUS = 0  
	BEGIN
	    PRINT 'Applying data mask: ' + @sql_statement; 

		BEGIN TRY
		    EXEC sp_executesql @stmt = @sql_statement  
		END TRY
		BEGIN CATCH
		    SELECT @error_message = ERROR_MESSAGE();
			PRINT 'Application of data mask failed with: ' + @error_message; 
		END CATCH;

		FETCH NEXT FROM apply_data_masks INTO @sql_statement
	END;

	CLOSE apply_data_masks
	DEALLOCATE apply_data_masks; 
END;
"@

    Invoke-DbaSqlQuery -SqlInstance $SqlInstance -Database $Database -Query $sql
}
function Invoke-StaticDataMasking
{
<#
.SYNOPSIS
A PowerShell function to statically mask data in char, varchar and/or nvarchar columns using a MD5 hashing function.

.DESCRIPTION
This PowerShell function uses as input a JSON file created by calling the New-DbaDbMaskingConfig PowerShell function.
Data in the columns specified in this file which are of the type char, varchar or nvarchar are envrypted using a MD5
hash.

.PARAMETER SqlInstance
The SQL Server instance of the database that static data masking is to be applied to

.PARAMETER Database
The database that static data masking is to be applied to

.PARAMETER DataMaskFile
Absolute path to the JSON file generated by invoking New-DbaDbMaskingConfig. The file can be subsequently editted by
hand  to  suit the  data masking  requirements of  this  function's  user. Currently, static data  masking  is  only
supported for columns with char, varchar, nvarchar, int and bigint data types.

.EXAMPLE
Invoke-StaticDataMasking -SqlInstance  Z-STN-WIN2016-A\DEVOPSDEV `
                         -Database     tpch-no-compression `
                         -DataMaskFile 'C:\Users\devops\Documents\tpch-no-compression.tables.json'
.NOTES
                    Obtaining The PureStorageDbaTools Module
                    ----------------------------------------

This function is part of the PureStorageDbaTools module, it is recommend
that the module is always obtained from the PowerShell gallery:

https://www.powershellgallery.com/packages/PureStorageDbaTools

Note that it has dependencies on the dbatools and PureStoragePowerShellSDK
modules which are installed as part of the installation of this module.

                                    Licence
                                    -------

This function is available under the Apache 2.0 license, stipulated as follows:

Copyright 2017 Pure Storage, Inc.
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at
    http://www.apache.org/licenses/LICENSE-2.0
Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on  an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
.LINK
https://www.powershellgallery.com/packages/PureStorageDbaTools
https://docs.microsoft.com/en-us/sql/relational-databases/security/dynamic-data-masking?view=sql-server-2017
New-PfaDbSnapshot
Invoke-PfaDbRefresh
#>
param(
         [parameter(mandatory=$true)]  [string] $SqlInstance   
        ,[parameter(mandatory=$true)]  [string] $Database       
        ,[parameter(mandatory=$true)]  [string] $DataMaskFile       
    )

    if ($DataMaskFile.ToString().StartsWith('http')) {
        $tables = Invoke-RestMethod -Uri $DataMaskFile
    } else {
        # Check if the destination is accessible
        if (-not (Test-Path -Path $DataMaskFile)) {
            Write-Error "Could not find data mask config file $DataMaskFile"
            Return
        }
    }

    # Get all the items that should be processed
    try {
        $tables = Get-Content -Path $DataMaskFile -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-Error "Could not parse masking config file: $DataMaskFile" -ErrorRecord $_
    }

    foreach ($tabletest in $tables.Tables) {
        if ($Table -and $tabletest.Name -notin $Table) {
            continue
        }
    
        $ColumnIndex = 0
        $UpdateStatement = ""
    
        foreach ($columntest in $tabletest.Columns) {
            if ($columntest.ColumnType -in 'varchar', 'char', 'nvarchar') {
                if ($ColumnIndex -eq 0) {
                    $UpdateStatement =  'UPDATE ' + $tabletest.Name + ' SET ' + $columntest.Name + ' = SUBSTRING(CONVERT(VARCHAR, HASHBYTES(' + '''' + 'MD5' + '''' + ', ' + $columntest.Name + '), 1), 1, ' + $columntest.MaxValue + ')' 
                }
                else {
                    $UpdateStatement += ', ' + $columntest.Name + ' = SUBSTRING(CONVERT(VARCHAR, HASHBYTES(' + '''' + 'MD5' + '''' + ', ' + $columntest.Name + '), 1), 1, ' + $columntest.MaxValue + ')'
                }
            }
            elseif ($columntest.ColumnType -eq 'int') {
                if ($ColumnIndex -eq 0) {
                    $UpdateStatement =  'UPDATE ' + $tabletest.Name + ' SET ' + $columntest.Name + ' = ABS(CHECKSUM(NEWID())) % 2147483647' 
                }
                else {
                    $UpdateStatement += ', ' + $columntest.Name + ' = ABS(CHECKSUM(NEWID())) % 2147483647'
                }
            }   
            elseif ($columntest.ColumnType -eq 'bigint') {
                if ($ColumnIndex -eq 0) {
                    $UpdateStatement =  'UPDATE ' + $tabletest.Name + ' SET ' + $columntest.Name + ' = ABS(CHECKSUM(NEWID()))' 
                }
                else {
                    $UpdateStatement += ', ' + $columntest.Name + ' = ABS(CHECKSUM(NEWID()))'
                }
            }   
            else {
                Write-Error "$columntest.ColumnType is not supported, please remove the column $columntest.Name from the $tabletest.Name table"
                Return
            }
            $ColumnIndex += 1
        }

        Write-Verbose "Statically masking table $tabletest.Name using $UpdateStatement"
        Invoke-DbaQuery -ServerInstance $SqlInstance -Database $Database -Query $UpdateStatement -QueryTimeout 999999 
    }            
}

Export-ModuleMember -Function @('Invoke-PfaDbRefresh', 'New-PfaDbSnapshot', 'Enable-DataMasks', 'Invoke-DynamicDataMasking', 'Invoke-StaticDataMasking')
