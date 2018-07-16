# PureStorageDbaTools

The module contains powershell functions to refresh SQL Server databases, create snapshots of SQL Server databases and obfuscate sensitive data via 
SQL Server's dynamic data masking functionality. This functionality is currently provided by three functions: 

- Invoke-PfaDbRefresh
- New-PfaDbSnapshot
- Enable-DataMasks

## Getting Started

### Prerequisites

This module is built on top of both dbatools and the PureStoragePowerShellSDK modules, as such it has the following prerequisites:

- Windows PowerShell 3.0 or higher .
- .NET Framework 4.5 .
- Purity Operating Environments that support REST API 1.0, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6 and 1.7 .
- 64-bit Windows Server or Client operating system .
- This release requires an operating system that supports the TLS 1.1/1.2 protocols such as Windows 7 or higher and Windows Server 2008 R2 or higher .
- SQL Server 2008 SMO or SSMS .
- SQL Server 2016 or above in order for the data masking functionality to work .

### Installation

This module should always be downloaded and installed from the Powershell gallery as follows:

PS> Save-Module -Name PureStorageDbaTools -Path <path>

PS> Install-Module -Name PureStorageDbaTools

### Usage

Once installed full documentation including example can be obtained on the three functions that the module contains via the Get-Help 
cmdlet:

1. Get-Help  Invoke-PfaDbRefresh 

will provide basic information on how the function can be used

2.  Get-Help  Invoke-PfaDbRefresh -Detailed

will provide detailed information on how the function can be used including examples. Both the Invoke-PfaDbRefresh and New-PfaDbSnapshot  
functions use powershell credentials objects in order to comply with the security best practices and polices mandated by the Powershell gallery .

If we then call the  Invoke-PfaDbRefresh, in this example the tpch-no-compression database on  Z-STN-WIN2016-A\DEVOPSPRD is being used to refresh  Z-STN-WIN2016-A\DEVOPSDEV1 and Z-STN-WIN2016-A\DEVOPSDEV2, the -ApplyDataMasks switch will cause the data mask to be applied:

### Examples

$Pwd   = Get-Content ‘C:\Temp\Secure-Credentials.txt’ | ConvertTo-SecureString
$Creds = New-Object System.Management.Automation.PSCredential ("pureuser", $pwd)
$Targets = @('DEVOPSDEV1', 'DEVOPSDEV2')

Invoke-PfaDbRefresh -RefreshDatabase tpch          `
                    -RefreshSource   DEVOPSPRD     `
                    -DestSqlInstance $Targets      `
                    -PfaEndpoint     10.223.112.05 `
                    -PfaCredentials  $Creds `
                    -ApplyDataMasks

## Restrictions

- This code assumes that each database resides in a single FlashArray volume, i.e. there is one window logical volume per database
- The code does not work with database(s) that reside on SQL Server fail over instances
- All database(s) used when performing a database to database refresh reside on the same FlashArray

## Authors

Chris Adkin, EMEA SQL Server Solutions Architect at Pure Storage.

## License

This module is available to use under the Apache 2.0 license, stipulated as follows:

Copyright 2018 Pure Storage, Inc.
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at
    http://www.apache.org/licenses/LICENSE-2.0
Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on  an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

## Acknowledgements

Thanks to the community behind the dbatools module .

## Links

https://www.powershellgallery.com/packages/PureStorageDbaTools

https://www.purepowershellguy.com/?p=8431
