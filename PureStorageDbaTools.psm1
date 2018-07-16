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

    $StartMs = Get-Date

    Write-Host "Connecting to array endpoint" -ForegroundColor Yellow

    try {
        $FlashArray = New-PfaArray –EndPoint $PfaEndpoint -Credentials $PfaCredentials –IgnoreCertificateError
    }
    catch {
        $ExceptionMessage = $_.Exception.Message
        Write-Error "Failed to connect to FlashArray endpoint $PfaEndpoint with: $ExceptionMessage"
        Return
    }

    Write-Host "Connecting to snapshot target SQL Server instance" -ForegroundColor Yellow

    try {
        $DestDb           = Get-DbaDatabase -sqlinstance $SqlInstance -Database $Database
    }
    catch {
        $ExceptionMessage = $_.Exception.Message
        Write-Error "Failed to connect to destination database $SqlInstance.$Database with: $ExceptionMessage"
        Return
    }

    $GetDbDisk = { param ( $Db ) 
        $DbDisk = Get-partition -DriveLetter $Db.PrimaryFilePath.Split(':')[0]| Get-Disk
        return $DbDisk
    }

    Write-Host "Creating snapshot from windows drive < " $DestDb.PrimaryFilePath.Split(':')[0] ">"
    
    try {
        $TargetDisk = Invoke-Command -ScriptBlock $GetDbDisk -ArgumentList $DestDb
    }
    catch {
        $ExceptionMessage  = $_.Exception.Message
        Write-Error "Failed to determine the windows disk snapshot target with: $ExceptionMessage"
        Return
    }

    Write-Host "Determining snapshot target FlashArray volume" -ForegroundColor Yellow

    try {
        $TargetVolume = Get-PfaVolumes -Array $FlashArray | Where-Object { $_.serial -eq $TargetDisk.SerialNumber } | Select name
    }
    catch {
        $ExceptionMessage = $_.Exception.Message
        Write-Error "Failed to determine snapshot FlashArray volume with: $ExceptionMessage"
        Return
    }

    Write-Host "Target volume for snapshot is < " $TargetVolume.name ">"

    try {
        New-PfaVolumeSnapshots -Array $FlashArray -Sources $TargetVolume.name
    }
    catch {
        $ExceptionMessage = $_.Exception.Message
        Write-Error "Failed to create snapshot for target database FlashArray volume with: $ExceptionMessage"
        Return
    }
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
apply data masking, based on the dynamic data masking functionality available in SQL Server
version 2016 onwards.

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

Refresh multiple databases from the database specified by the SourceDatabase parameter residing on the instance specified by RefreshSource and apply SQL Server dynamic data masking to each database.
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
New-PfaDbSnapshot
Enable-DataMasks
#>
    param(
          [parameter(mandatory=$true)]  [string]                                    $RefreshDatabase          
         ,[parameter(mandatory=$true)]  [string]                                    $RefreshSource 
         ,[parameter(mandatory=$true)]  [string[]]                                  $DestSqlInstances   
         ,[parameter(mandatory=$true)]  [string]                                    $PfaEndpoint       
         ,[parameter(mandatory=$true)]  [System.Management.Automation.PSCredential] $PfaCredentials
         ,[parameter(mandatory=$false)] [switch]                                    $PromptForSnapshot
         ,[parameter(mandatory=$false)] [switch]                                    $RefreshFromSnapshot
         ,[parameter(mandatory=$false)] [switch]                                    $NoPsRemoting
         ,[parameter(mandatory=$false)] [switch]                                    $ApplyDataMasks
    )

    $StartMs = Get-Date

    if ( $PromptForSnapshot.IsPresent.Equals($false) -And $RefreshFromSnapshot.IsPresent.Equals($false) ) { 
        Write-Host "Connecting to source SQL Server instance" -ForegroundColor Yellow

        try {
            $SourceDb          = Get-DbaDatabase -sqlinstance $RefreshSource -Database $RefreshDatabase
        }
        catch {
            $ExceptionMessage = $_.Exception.Message
            Write-Error "Failed to connect to source database $RefreshSource.$Database with: $ExceptionMessage"
            Return
        }

        try {
            $SourceServer  = (Connect-DbaInstance -SqlInstance $RefreshSource).ComputerNamePhysicalNetBIOS
        }
        catch {
            Write-Error "Failed to determine target server name with: $ExceptionMessage"        
        }
    }

    Write-Host "Connecting to array endpoint" -ForegroundColor Yellow

    try {
        $FlashArray = New-PfaArray –EndPoint $PfaEndpoint -Credentials $PfaCredentials –IgnoreCertificateError
    }
    catch {
        $ExceptionMessage = $_.Exception.Message
        Write-Error "Failed to connect to FlashArray endpoint $PfaEndpoint with: $ExceptionMessage"
        Return
    }

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
                $SourceDisk        = Invoke-Command -ScriptBlock $GetDbDisk -ArgumentList $SourceDb
            }
            else {
                $SourceDisk        = Invoke-Command -ComputerName $SourceServer -ScriptBlock $GetDbDisk -ArgumentList $SourceDb
            }
        }
        catch {
            $ExceptionMessage = $_.Exception.Message
            Write-Error "Failed to determine source disk with: $ExceptionMessage"
            Return
        }

        try {
            $SourceVolume      = Get-PfaVolumes -Array $FlashArray | Where-Object { $_.serial -eq $SourceDisk.SerialNumber } | Select name
        }
        catch {
            $ExceptionMessage = $_.Exception.Message
            Write-Error "Failed to determine source volume with: $ExceptionMessage"
            Return
        }
    } 

    Foreach($DestSqlInstance in $DestSqlInstances) {
        Write-Host "Connecting to destination SQL Server instance" -ForegroundColor Yellow

        try {
            $DestDb            = Get-DbaDatabase -sqlinstance $DestSqlInstance -Database $RefreshDatabase
        }
        catch {
            $ExceptionMessage = $_.Exception.Message
            Write-Error "Failed to connect to destination database $DestSqlInstance.$Database with: $ExceptionMessage"
            Return
        }

        try {
            $TargetServer  = (Connect-DbaInstance -SqlInstance $DestSqlInstance).ComputerNamePhysicalNetBIOS
        }
        catch {
            Write-Error "Failed to determine target server name with: $ExceptionMessage"        
        }

        $OfflineDestDisk = { param ( $DiskNumber, $Status ) 
            Set-Disk -Number $DiskNumber -IsOffline $Status
        }

        try {
            if ( $NoPsRemoting.IsPresent ) {
                $DestDisk = Invoke-Command -ScriptBlock $GetDbDisk -ArgumentList $DestDb
            }
            else {
                $DestDisk = Invoke-Command -ComputerName $TargetServer -ScriptBlock $GetDbDisk -ArgumentList $DestDb
            }
        }
        catch {
            $ExceptionMessage  = $_.Exception.Message
            Write-Error "Failed to determine destination database disk with: $ExceptionMessage"
            Return
        }

        try {
            $DestVolume        = Get-PfaVolumes -Array $FlashArray | Where-Object { $_.serial -eq $DestDisk.SerialNumber } | Select name
        }
        catch {
            $ExceptionMessage = $_.Exception.Message
            Write-Error "Failed to determine destination FlashArray volume with: $ExceptionMessage"
            Return
        }

        $OfflineDestDisk = { param ( $DiskNumber, $Status ) 
            Set-Disk -Number $DiskNumber -IsOffline $Status
        }

        Write-Host "Offlining destination database" -ForegroundColor Yellow

        try {
            $DestDb.SetOffline()
        }
        catch {
            $ExceptionMessage = $_.Exception.Message
            Write-Error "Failed to offline database $Database with: $ExceptionMessage"
            Return
        }

        Write-Host "Offlining destination Windows volume" -ForegroundColor Yellow

        try {
            if ( $NoPsRemoting.IsPresent ) {
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

        $StartCopyVolMs = Get-Date
        Write-Host ' '

        try {
           if ( $PromptForSnapshot.IsPresent ) {
               Write-Host "Snap -> DB refresh: Overwriting destination FlashArray volume <" $DestVolume.name "> with snapshot <" $FilteredSnapshots[$SnapshotId].name ">" -ForegroundColor Yellow
               New-PfaVolume -Array $FlashArray -VolumeName $DestVolume.name -Source $FilteredSnapshots[$SnapshotId].name -Overwrite
           }
           elseif ( $RefreshFromSnapshot.IsPresent ) {
               Write-Host "DB -> DB refresh  : Overwriting destination FlashArray volume <" $DestVolume.name "> with snapshot <" $RefreshSource ">" -ForegroundColor Yellow
               New-PfaVolume -Array $FlashArray -VolumeName $DestVolume.name -Source $RefreshSource -Overwrite
           }
           else {
               Write-Host "DB -> DB refresh  : Overwriting destination FlashArray volume <" $DestVolume.name "> with a copy of the source volume <" $SourceVolume.name ">" -ForegroundColor Yellow
               New-PfaVolume -Array $FlashArray -VolumeName $DestVolume.name -Source $SourceVolume.name -Overwrite
           }
        }
        catch {
            $ExceptionMessage = $_.Exception.Message
            Write-Error "Failed to refresh test database volume with : $ExceptionMessage" 
            Set-Disk -Number $DestDisk.Number -IsOffline $False
            $DestDb.SetOnline()
            Return
        }

        $EndCopyVolMs = Get-Date

        Write-Host "Volume overwrite duration (ms) = " ($EndCopyVolMs - $StartCopyVolMs).TotalMilliseconds -ForegroundColor Yellow
        Write-Host " "
        Write-Host "Onlining destination Windows volume" -ForegroundColor Yellow

        try {
            if ( $NoPsRemoting.IsPresent.Equals( $true ) ) {
                Invoke-Command -ScriptBlock $OfflineDestDisk -ArgumentList $DestDisk.Number, $False
            }
            else {
                Invoke-Command -ComputerName $TargetServer -ScriptBlock $OfflineDestDisk -ArgumentList $DestDisk.Number, $False
            }
        }
        catch {
            $ExceptionMessage = $_.Exception.Message
            Write-Error "Failed to online disk with : $ExceptionMessage" 
            Return
        }

        Write-Host "Onlining destination database" -ForegroundColor Yellow

        try {
            $DestDb.SetOnline()
        }
        catch {
            $ExceptionMessage = $_.Exception.Message
            Write-Error "Failed to online database $Database with: $ExceptionMessage"
            Return
        }

        if ($ApplyDataMasks.IsPresent) {
            Write-Host "Applying data masks to $RefreshDatabase on SQL Server instance $DestSqlInstance" -ForegroundColor Yellow
            Enable-DataMasks -SqlInstance $DestSqlInstance -Database $RefreshDatabase
            Write-Host "Data masking has been applied" -ForegroundColor Yellow
        }

        Write-Host "Repairing orphaned users" -ForegroundColor Yellow      
        Repair-DbaOrphanUser -SqlInstance $DestSqlInstance -Database $RefreshDatabase
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
<#
.SYNOPSIS
A PowerShell function to apply data masks to database columns using the SQL Server dynamic data masking feature.

.DESCRIPTION
This PowerShell function uses the information stored in the extended properties of a database,
sys.extended_properties.name = 'DATAMASK' to obtain the function used to apply the data mask to the properties
associated column. This function currerntly works for columns using the following data types:

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
Enable-DataMasks -SqlInstance Z-STN-WIN2016-A\DEVOPSDEV `
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

Export-ModuleMember -Function @('Invoke-PfaDbRefresh', 'New-PfaDbSnapshot', 'Enable-DataMasks')
