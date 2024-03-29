#####################################################
# HelloID-Conn-Prov-Target-Fierit-ECD-Update
#
# Version: 1.0.2
#####################################################

# Initialize default values
$config = $configuration | ConvertFrom-Json
$p = $person | ConvertFrom-Json
# $pp = $previousPerson | ConvertFrom-Json
$aRef = $AccountReference | ConvertFrom-Json
$success = $false
$auditLogs = [System.Collections.Generic.List[PSCustomObject]]::new()
$accountReferenceList = [System.Collections.Generic.List[PSCustomObject]]::new()

# Account mapping

$gender = 'M'
if ( $p.Details.Gender -eq 'Vrouw') {
    $gender = 'V'
}

# Calculated based on employment primary contract in conditions. And will be added to the accountEmployee object seperate for each employement.
$contractMapping = @{
    begindate    = { $_.StartDate }
    enddate      = { $_.endDate }
    costcentre   = { $_.CostCenter.code }
    locationcode = { $_.Department.ExternalId }
}

$emzfunctionMapping = @{
    code      = { $_.Title.Name }
    begindate = { [DateTime]::Parse($_.StartDate).ToString('yyyy-MM-dd') }
    enddate   = { [DateTime]::Parse($_.endDate).ToString('yyyy-MM-dd') }
}

# Employeecode : $contractCustomProperty Will be added during the processing below.
# When choose to update the existing contact objects are overridden.
# EmzFunction Will be added based on the [emzfunctionMapping]
$accountEmployee = [PSCustomObject]@{
    employeecode        = $null
    gender              = $gender # M / V
    dateofbirth         = $p.Details.BirthDate
    caregivercode       = ''
    functiondescription = $p.PrimaryContract.Title.Name
    salutation          = $p.Details.HonorificPrefix  #  Fixedvalue    # Dhr. | Mevr. | .?
    movetimetoroster    = $false
    emzfunction         = @()
    name                = [PSCustomObject]@{
        firstname      = $p.Name.NickName
        initials       = $p.Name.Initials
        prefix         = $p.Name.FamilyNamePrefix
        surname        = $p.Name.FamilyName
        partnerprefix  = $p.Name.FamilyNamePartnerPrefix
        partnersurname = $p.Name.FamilyNamePartner
        nameassembly   = 'Eigennaam'  # 'Partnernaam'
    }
    contact             = @(
        # When choose to update the existing contact objects are overridden.
        [PSCustomObject]@{
            device = 'vast'
            type   = 'werk'
            value  = $p.Contact.Business.Phone.Mobile
        },
        [PSCustomObject]@{
            device = 'email'
            type   = 'werk'
            value  = $p.Contact.Business.Email
        }
    )
}

# Not all properties are suitable to be updated during correlation. By default, only the Name property will be updated
# Code : $contractCustomProperty Will be added during the processing below.
# Employeecode: $contractCustomProperty Will be added during the processing below.
# The employee Code is used for the relation between Employee and the user account (See readme)
# Active : Account created in the Update script needed to be Active, Because there is no Enable or Disable process triggered.
# A Role is Mandatory when creating a new User account

$accountUser = [PSCustomObject]@{
    code         = $null
    name         = "$($p.Name.GivenName) $($p.Name.FamilyName)".trim(' ')
    ssoname      = $p.Accounts.MicrosoftActiveDirectory.mail
    mfaname      = $p.Accounts.MicrosoftActiveDirectory.mail
    active       = $true
    employeecode = $null
    role         = @(
        @{
            id        = "$($config.DefaultTeamAssignmentGuid)"
            startdate = (Get-Date -f 'yyyy-MM-dd')
            enddate   = $null
        }
    )
}

$contractCustomProperty = { $_.Custom.FieritECDEmploymentIdentifier }

# Primary Contract Calculation foreach employment
$firstProperty = @{ Expression = { $_.Details.Fte } ; Descending = $true }
$secondProperty = @{ Expression = { $_.Details.HoursPerWeek }; Descending = $true }
# $thirdProperty =  @{ Expression = { $_.Details.Percentage };      Descending = $false }

#Priority Calculation Order (High priority -> Low priority)
$splatSortObject = @{
    Property = @(
        $firstProperty,
        $secondProperty
        #etc..
    )
}
# Enable TLS1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

# Set debug logging
switch ($($config.IsDebug)) {
    $true { $VerbosePreference = 'Continue' }
    $false { $VerbosePreference = 'SilentlyContinue' }
}

#region functions
function Find-SingleActiveUserAccount {
    [CmdletBinding()]
    param(
        $UserAccountList
    )
    $userAccount = [array]$UserAccountList | Where-Object { $_.active -eq $true }
    if ($userAccount.Length -eq 0) {
        throw "Mulitple user accounts found without a single active for Employee [$($UserAccountList.employeecode|Select -First 1)], Codes: [$($UserAccountList.code -join ',')] Currently not Supported"

    } elseif ($userAccount.Length -gt 1) {
        throw "Mulitple active user accounts found for Employee [$($userAccount.employeecode |Select -First 1)], Codes: [$($userAccount.code -join ',')] Currently not Supported"
    }
    Write-Output $userAccount
}

function Get-AccessToken {
    [CmdletBinding()]
    param ()
    try {
        $tokenHeaders = [System.Collections.Generic.Dictionary[[String], [String]]]::new()
        $tokenHeaders.Add('Content-Type', 'application/x-www-form-urlencoded')
        $body = @{
            grant_type     = 'client_credentials'
            client_id      = $config.ClientId
            client_secret  = $config.ClientSecret
            organisationId = $config.OrganisationId
            environment    = $config.Environment
        }
        $response = Invoke-RestMethod $config.TokenUrl -Method 'POST' -Headers $tokenHeaders -Body $body -Verbose:$false
        Write-Output $response.access_token
    } catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }
}
function Set-AuthorizationHeaders {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        $Token
    )
    try {
        $headers = [System.Collections.Generic.Dictionary[[String], [String]]]::new()
        #$headers.Add('Accept', 'application/json; charset=utf-8')
        $headers.Add('Content-Type', 'application/json')
        $headers.Add('Authorization', "Bearer $token")
        $headers.Add('callingParty', 'Tools4ever')
        $headers.Add('callingApplication', 'HelloID')

        Write-Output $headers
    } catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }
}

function Resolve-HTTPError {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory,
            ValueFromPipeline
        )]
        [object]$ErrorObject
    )
    process {
        $httpErrorObj = [PSCustomObject]@{
            ScriptLineNumber = $ErrorObject.InvocationInfo.ScriptLineNumber
            Line             = $ErrorObject.InvocationInfo.Line
            ErrorDetails     = ''
            FriendlyMessage  = ''
        }
        if ($ErrorObject.Exception.GetType().FullName -eq 'System.Net.WebException') {
            if ($null -eq $ErrorObject.Exception.Response) {
                $httpErrorObj.ErrorDetails = $ErrorObject.Exception.Message
                $httpErrorObj.FriendlyMessage = $ErrorObject.Exception.Message
            } else {
                $streamReaderResponse = [System.IO.StreamReader]::new($ErrorObject.Exception.Response.GetResponseStream()).ReadToEnd()
                $httpErrorObj.ErrorDetails = "$($ErrorObject.Exception.Message) $streamReaderResponse"
                if ($null -ne $streamReaderResponse) {
                    $errorResponse = ( $streamReaderResponse | ConvertFrom-Json)
                    $httpErrorObj.FriendlyMessage = switch ($errorResponse) {
                        { $_.error_description } { $errorResponse.error_description }
                        { $_.issue.details } { $errorResponse.issue.details }
                        { $_.error.message } { "Probably OrganisationId or Environment not found: Error: $($errorResponse.error.message)" }
                        default { ($errorResponse | ConvertTo-Json) }
                    }
                }
            }
        } else {
            $httpErrorObj.ErrorDetails = $ErrorObject.Exception.Message
            $httpErrorObj.FriendlyMessage = $ErrorObject.Exception.Message
        }
        Write-Output $httpErrorObj
    }
}

function Merge-Object {
    # With the exception of arrays, these are overridden by the array from the $updates, but only if the array does exist in $updates.
    [CmdletBinding()]
    param(
        [PSCustomObject]
        $Object,

        [PSCustomObject]
        $Updates

    )
    foreach ($property in $Updates.PSObject.Properties) {
        if (
            -not (
                $property.TypeNameOfValue -eq 'System.Object[]' -or
                $property.TypeNameOfValue -eq 'System.Management.Automation.PSCustomObject' -or
                $property.TypeNameOfValue -eq 'System.Collections.Hashtable'
            )
        ) {
            Write-Verbose ('Existing: ' + $($property.Name) + ':' + $Object.$($property.Name))
            Write-Verbose ('New:      ' + $($property.Name) + ':' + $Updates.$($property.Name))
            # Override Properties at the current object if exist in the acocunt object
            if ($Object.PSObject.Properties.Name -eq $($property.Name)) {
                $Object.$($property.Name) = $Updates.$($property.Name)
            } else {
                $Object | Add-Member -NotePropertyMembers @{
                    $($property.Name) = $Updates.$($property.Name)
                }
            }
        } else {
            if ($property.TypeNameOfValue -eq 'System.Object[]') {
                # Override objects in array if exist in the acocunt object
                if ($null -ne $Object.$($property.Name)) {
                    $Object.$($property.Name) = $Updates.$($property.Name)
                } else {
                    $Object | Add-Member -NotePropertyMembers @{
                        $($property.Name) = $Updates.$($property.Name)
                    }
                }
            } else {
                # One level lower
                Merge-Object -Object $Object.$($property.name) -Updates $Updates.$($property.name)
            }
        }
    }
}
function Compare-Join {
    [OutputType([array], [array], [array])] # $Left , $Right, $common
    param(
        [parameter()]
        [string[]]$ReferenceObject,

        [parameter()]
        [string[]]$DifferenceObject
    )
    if ($null -eq $DifferenceObject) {
        $Left = $ReferenceObject
    } elseif ($null -eq $ReferenceObject ) {
        $right = $DifferenceObject
    } else {
        $left = [string[]][Linq.Enumerable]::Except($ReferenceObject, $DifferenceObject)
        $right = [string[]][Linq.Enumerable]::Except($DifferenceObject, $ReferenceObject)
        $common = [string[]][Linq.Enumerable]::Intersect($ReferenceObject, $DifferenceObject)
    }
    Write-Output $Left.Where({ -not [string]::IsNullOrEmpty($_) }) , $Right, $common
}

function Invoke-FieritWebRequest {
    [CmdletBinding()]
    param(
        [System.Uri]
        $Uri,

        [string]
        $Method = 'Get',

        $Headers,

        [switch]
        $UseBasicParsing,


        $body
    )
    try {
        $splatWebRequest = @{
            Uri             = $Uri
            Method          = $Method
            Headers         = $Headers
            UseBasicParsing = $UseBasicParsing
        }

        if ( -not [string]::IsNullOrEmpty( $body )) {
            $utf8Encoding = [System.Text.Encoding]::UTF8
            $encodedBody = $utf8Encoding.GetBytes($body)
            $splatWebRequest['Body'] = $encodedBody
        }
        $rawResult = Invoke-WebRequest @splatWebRequest -Verbose:$false -ErrorAction Stop
        if ($null -ne $rawResult.Headers -and (-not [string]::IsNullOrEmpty($($rawResult.Headers['processIdentifier'])))) {
            Write-Verbose "WebCall executed. Successfull [URL: $($Uri.PathAndQuery) Method: $($Method) ProcessID: $($rawResult.Headers['processIdentifier'])]"
        }
        if ($rawResult.Content) {
            Write-Output ($rawResult.Content | ConvertFrom-Json )
        }
    } catch {
        if ($null -ne $_.Exception.Response.Headers -and (-not [string]::IsNullOrEmpty($($_.Exception.Response.Headers['processIdentifier'])))) {
            Write-Verbose "WebCall executed. Failed [URL: $($Uri.PathAndQuery) Method: $($Method) ProcessID: $($_.Exception.Response.Headers['processIdentifier'])]" -Verbose
        }
        $PSCmdlet.ThrowTerminatingError($_)
    }
}

function Add-ContractProperties {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        $Object,

        [Parameter(Mandatory)]
        [System.Collections.Hashtable]
        $Mapping,

        [Parameter(Mandatory)]
        $Contract,

        [Parameter()]
        [switch]
        $OverrideExisiting
    )
    try {
        foreach ($prop in $Mapping.GetEnumerator()) {
            Write-verbose "Added [$($prop.Name) - $(($Contract | Select-Object -Property $prop.Value).$($prop.value))]" -Verbose
            $Object | Add-Member -NotePropertyMembers @{
                $prop.Name = $(($Contract | Select-Object -Property $prop.Value)."$($prop.value)")
            } -Force:$OverrideExisiting
        }

    } catch {
        $PSCmdlet.ThrowTerminatingError($_)
    }
}
#endregion

try {
    #region Calculate desired accounts
    [array]$desiredContracts = $p.Contracts | Where-Object { $_.Context.InConditions -eq $true }
    if ($desiredContracts.length -lt 1) {
        Write-Verbose 'No Contracts in scope [InConditions] found!' -Verbose
        throw 'No Contracts in scope [InConditions] found!'
    }
    if ((($desiredContracts | Select-Object $contractCustomProperty).$contractCustomProperty | Measure-Object).count -ne $desiredContracts.count) {
        Write-Verbose "Not all contracts hold a value with the Custom Property [$contractCustomProperty]. Verify the custom Property or your source mapping." -Verbose
        throw  "Not all contracts hold a value with the Custom Property [$contractCustomProperty]. Verify the custom Property or your source mapping."
    }
    $desiredContractsGrouped = $desiredContracts | Group-Object -Property $contractCustomProperty

    [array]$accountToCreate, [array]$accountToRevoke, [array]$accountToUpdate = Compare-Join -ReferenceObject $desiredContractsGrouped.Name -DifferenceObject ($aRef.EmployeeId)
    Write-Verbose "[$($p.DisplayName)] Account(s) To Create [$($accountToCreate -join ', ')]"
    Write-Verbose "[$($p.DisplayName)] Account(s) To Revoke [$($accountToRevoke -join ', ')]"
    Write-Verbose "[$($p.DisplayName)] Account(s) To Update [$($accountToUpdate -join ', ')]"
    #endregion


    #region Initialize account Objects
    $token = Get-AccessToken
    $headers = Set-AuthorizationHeaders -Token $token

    $allAccounts = [System.Collections.Generic.List[object]]::new()
    $allAccounts.AddRange($accountToCreate)
    $allAccounts.AddRange($accountToRevoke)
    $allAccounts.AddRange($accountToUpdate)
    $currentAccountList = @{}
    foreach ($accountNr in $allAccounts ) {
        # Get Employee
        $accountEmployeeLoop = $accountEmployee.psobject.copy()
        $accountEmployeeLoop.emzfunction = $accountEmployee.emzfunction.PSObject.Copy()

        $primaryContract = $null
        $primaryContract = ($desiredContractsGrouped | Where-Object { $_.name -eq $accountNr }).Group | Sort-Object @splatSortObject  | Select-Object -First 1
        if ( $primaryContract) {
            $accountEmployeeLoop.employeecode = "$accountNr"
            $accountEmployeeLoop | Add-ContractProperties -Mapping $contractMapping -Contract $primaryContract

            # Update the emzFunction Object
            $emzObject = [PSCustomObject]::new()
            $emzObject | Add-ContractProperties -Mapping $emzfunctionMapping  -Contract $primaryContract
            $accountEmployeeLoop.emzfunction += $emzObject
            # To remove a function [$accountEmployeeLoop.emzfunction = @()] Not sure if required to implement!
        } else {
            throw "No primary contract found for [$accountNr]"
        }

        Write-Verbose "Get Employee with employeeCode [$($accountNr)]"
        $splatGetEmployee = @{
            Uri     = "$($config.BaseUrl.Trim('/'))/employees/employee?employeecode=$($accountNr)"
            Method  = 'GET'
            Headers = $headers
        }
        $currentEmployee = $null
        $currentEmployee = Invoke-FieritWebRequest @splatGetEmployee -UseBasicParsing

        # Get User
        $accountUserLoop = $accountUser.psobject.copy()
        $accountUserLoop.employeecode = "$accountNr"

        $currentAref = $null
        $currentAref = $aref | Where-Object { $_.employeeId -eq $accountNr }

        if ($null -ne $currentAref ) {
            $accountUserLoop.code = $currentAref.UserId
            Write-Verbose "Get user with Code [$($accountUserLoop.code)]"
            $splatGetUser = @{
                Uri     = "$($config.BaseUrl.Trim('/'))/users/user?usercode=$($accountUserLoop.code)"
                Method  = 'GET'
                Headers = $headers
            }
            $currentUser = $null
            $currentUser = Invoke-FieritWebRequest @splatGetUser -UseBasicParsing
        } else {
            $accountUserLoop.code = "$accountNr"
            Write-Verbose "Get user with employeeCode [$($accountNr)]"
            $splatGetUser = @{
                Uri     = "$($config.BaseUrl.Trim('/'))/users/user?employeecode=$($accountNr)"
                Method  = 'GET'
                Headers = $headers
            }
            $currentUser = Invoke-FieritWebRequest @splatGetUser -UseBasicParsing
            if ($null -eq $currentUser) {
                $currentUser = Find-SingleActiveUserAccount -UserAccountList $currentUser
            }
            $accountUserLoop.code = $currentUser.code
        }

        $currentAccountList["$accountNr"] += @{
            CurrentEmployee = $currentEmployee
            EmployeeFound   = "$(if ($null -eq $currentEmployee) { 'NotFound' } Else { 'Found' })"
            accountEmployee = $accountEmployeeLoop
            CurrentUser     = $currentUser
            UserFound       = "$(if ($null -eq $currentUser) { 'NotFound' } Else { 'Found' })"
            accountUser     = $accountUserLoop
        }

    }
    #endregion


    #region Process Account to Create
    foreach ($accountNr in $accountToCreate ) {
        try {
            $currentAccount = $null
            $currentAccount = $currentAccountList[$accountNr]
            # Add an auditMessage showing what will happen during enforcement
            if ($dryRun -eq $true) {
                Write-Warning "[DryRun] Create Fierit-ECD account [$accountNr] for: [$($p.DisplayName)], will be executed during enforcement"
            } else {
                switch ($currentAccount.EmployeeFound) {
                    'Found' {
                        $splatCompareProperties = @{
                            ReferenceObject  = @($currentAccount.accountEmployee.PSObject.Properties)
                            DifferenceObject = @($currentAccount.CurrentEmployee.PSObject.Properties)
                        }
                        $propertiesChanged = (Compare-Object @splatCompareProperties -PassThru).Where({ $_.SideIndicator -eq '=>' })
                        if ($propertiesChanged) {
                            # Update Emploee

                            Write-Verbose "Correlate + Update employee [$($currentAccount.CurrentEmployee.employeecode)]"
                            Merge-Object -Object $currentAccount.CurrentEmployee -Updates $currentAccount.accountEmployee  -Verbose:$false
                            $splatNewEmployee = @{
                                Uri     = "$($config.BaseUrl.Trim('/'))/employees/employee"
                                Method  = 'PATCH'
                                Headers = $headers
                                body    = ($currentAccount.CurrentEmployee | ConvertTo-Json  -Depth 10)
                            }
                            $responseEmployee = Invoke-FieritWebRequest @splatNewEmployee -UseBasicParsing
                        } else {
                            $auditLogs.Add([PSCustomObject]@{
                                    Action  = 'CreateAccount'
                                    Message = "[$accountNr] Correlate account was successful. Employee Reference is: [$($currentAccount.CurrentEmployee.employeecode)] account: [$($currentAccount.CurrentUser.code)]"
                                    IsError = $false
                                })
                        }
                        break
                    }
                    'NotFound' {
                        # Create Employee
                        Write-Verbose "Create employee [$($currentAccount.accountEmployee.employeecode)]"
                        $splatNewEmployee = @{
                            Uri     = "$($config.BaseUrl.Trim('/'))/employees/employee"
                            Method  = 'POST'
                            Headers = $headers
                            body    = ($currentAccount.accountEmployee | ConvertTo-Json  -Depth 10)
                        }
                        $responseEmployee = Invoke-FieritWebRequest @splatNewEmployee -UseBasicParsing
                        break
                    }
                }

                switch ($currentAccount.UserFound) {
                    'Found' {
                        Write-Verbose "Correlate + Update User [$($currentAccount.CurrentUser.code)]"

                        # Update Properties
                        $currentAccount.CurrentUser.name = $currentAccount.accountUser.name
                        $currentAccount.CurrentUser.active = $true

                        $splatNewUser = @{
                            Uri     = "$($config.BaseUrl.Trim('/'))/users/user"
                            Method  = 'Patch'
                            Headers = $headers
                            body    = ( $currentAccount.CurrentUser | ConvertTo-Json -Depth 10)
                        }
                        $responseUser = Invoke-FieritWebRequest @splatNewUser -UseBasicParsing
                        break;
                    }
                    'NotFound' {
                        # Create User
                        Write-Verbose "Create User [$($currentAccount.accountUser.code)]"
                        $splatNewUser = @{
                            Uri     = "$($config.BaseUrl.Trim('/'))/users/user"
                            Method  = 'POST'
                            Headers = $headers
                            body    = ($currentAccount.accountUser | ConvertTo-Json  -Depth 10)
                        }
                        $responseUser = Invoke-FieritWebRequest @splatNewUser -UseBasicParsing
                        break
                    }
                }
                $accountReferenceList.Add(@{
                        EmployeeId = $($responseEmployee.employeecode)
                        UserId     = $($responseUser.code)
                    })

                $auditLogs.Add([PSCustomObject]@{
                        Action  = 'CreateAccount'
                        Message = "[$accountNr] Create account was successful. Employee Reference is: [$($currentAccount.CurrentEmployee.employeecode)] account: [$($currentAccount.CurrentUser.code)]"
                        IsError = $false
                    })
            }
        } catch {
            $ex = $PSItem
            $errorObj = Resolve-HTTPError -ErrorObject $ex
            $errorMessage = "[$accountNr] Could not Create Fierit-ECD account. Error:  $($ex.Exception.Message), $($errorObj.FriendlyMessage)"
            Write-Verbose $errorMessage
            $auditLogs.Add([PSCustomObject]@{
                    Action  = 'CreateAccount'
                    Message = $errorMessage
                    IsError = $true
                })
        }
    }
    #endregion


    #region Process Account to Update
    foreach ($accountNr in $accountToUpdate ) {
        try {
            $currentAccount = $null
            $currentAccount = $currentAccountList[$accountNr]
            if ($dryRun -eq $true) {
                Write-Warning "[DryRun] Update Fierit-ECD account [$accountNr] for: [$($p.DisplayName)], will be executed during enforcement"
            } else {
                #($dryRun -eq $true) {
                switch ($currentAccount.EmployeeFound) {
                    'Found' {
                        # Employee
                        $splatCompareProperties = @{
                            ReferenceObject  = @($currentAccount.accountEmployee.PSObject.Properties)
                            DifferenceObject = @($currentAccount.CurrentEmployee.PSObject.Properties)
                        }
                        $currentAccount.CurrentEmployee.name.psobject.Properties.Remove('sortname')

                        $propertiesChanged = (Compare-Object @splatCompareProperties -PassThru).Where({ $_.SideIndicator -eq '=>' })
                        if ($propertiesChanged) {

                            Write-Verbose "Update employee [$($currentAccount.accountEmployee.employeecode)]"
                            Merge-Object -Object $currentAccount.CurrentEmployee -Updates $currentAccount.accountEmployee  -Verbose:$false
                            $splatNewEmployee = @{
                                Uri     = "$($config.BaseUrl.Trim('/'))/employees/employee"
                                Method  = 'PATCH'
                                Headers = $headers
                                body    = ($currentAccount.CurrentEmployee | ConvertTo-Json  -Depth 10)
                            }
                            $responseEmployee = Invoke-FieritWebRequest @splatNewEmployee -UseBasicParsing

                            switch ($currentAccount.UserFound) {
                                'Found' {
                                    # User
                                    Write-Verbose "Update User [$($currentAccount.accountUser.code)]"
                                    $currentAccount.CurrentUser.name = $currentAccount.accountUser.name
                                    $splatNewUser = @{
                                        Uri     = "$($config.BaseUrl.Trim('/'))/users/user"
                                        Method  = 'Patch'
                                        Headers = $headers
                                        body    = ( $currentAccount.CurrentUser | ConvertTo-Json -Depth 10)
                                    }
                                    $responseUser = Invoke-FieritWebRequest @splatNewUser -UseBasicParsing
                                    $accountReferenceList.Add(@{
                                            EmployeeId = $($currentAccount.CurrentEmployee.employeecode)
                                            UserId     = $($currentAccount.CurrentUser.code)
                                        })

                                    $auditLogs.Add([PSCustomObject]@{
                                            Action  = 'UpdateAccount'
                                            Message = "[$accountNr] Update account was successful. Employee Reference is: [$($currentAccount.CurrentEmployee.employeecode)] account: [$($currentAccount.CurrentUser.code)]"
                                            IsError = $false
                                        })
                                    break
                                }
                                'NotFound' {
                                    # User
                                    $auditLogs.Add([PSCustomObject]@{
                                            Action  = 'UpdateAccount'
                                            Message = "[$accountNr] Could not Update Fierit-ECD account User Acocunt seems to be deleted from Fierit"
                                            IsError = $true
                                        })
                                    break
                                }
                            }
                        } else {
                            $accountReferenceList.Add(@{
                                    EmployeeId = $($currentAccount.CurrentEmployee.employeecode)
                                    UserId     = $($currentAccount.CurrentUser.code)
                                })
                            $auditLogs.Add([PSCustomObject]@{
                                    Action  = 'UpdateAccount'
                                    Message = "[$accountNr] Update account was successful. Employee Reference is: [$($currentAccount.CurrentEmployee.employeecode)] account: [$($currentAccount.CurrentUser.code)], No Change required"
                                    IsError = $false
                                })
                        }
                        break
                    }
                    'NotFound' {
                        # Employee
                        $auditLogs.Add([PSCustomObject]@{
                                Action  = 'UpdateAccount'
                                Message = "[$accountNr] Could not Update Fierit-ECD account, Employee Acocunt seems to be deleted from Fierit"
                                IsError = $true
                            })
                        break
                    }
                }
            }
        } catch {
            $ex = $PSItem
            $errorObj = Resolve-HTTPError -ErrorObject $ex
            $errorMessage = "[$accountNr] Could not Update Fierit-ECD account. Error:  $($ex.Exception.Message), $($errorObj.FriendlyMessage)"
            Write-Verbose $errorMessage
            $auditLogs.Add([PSCustomObject]@{
                    Action  = 'UpdateAccount'
                    Message = $errorMessage
                    IsError = $true
                })
        }
    }
    #endregion


    #region Process Account to Delete
    foreach ($accountNr in $accountToRevoke ) {
        try {
            $auditLogsIfRevokeSuccess = [System.Collections.Generic.List[PSCustomObject]]::new()
            $currentAccount = $null
            $currentAccount = $currentAccountList[$accountNr]
            if ($dryRun -eq $true) {
                Write-Warning "[DryRun] Delete Fierit-ECD account [$accountNr] for: [$($p.DisplayName)], will be executed during enforcement"
            } else {
                switch ($currentAccount.EmployeeFound) {
                    'Found' {
                        # Update Emploee
                        Write-Verbose "Revoke employee [$($currentAccount.accountEmployee.employeecode)]"

                        if ($currentAccount.CurrentEmployee.team.Length -gt 0) {
                            Write-Verbose "Revoke All Teams assigned to the employee [$($currentAccount.CurrentEmployee.team.name -join ',')]"
                            $auditLogsIfRevokeSuccess.Add([PSCustomObject]@{
                                    Action  = 'DeleteAccount'
                                    Message = "[$accountNr] Revoke Fierit-ECD Team entitlement(s): [$($currentAccount.CurrentEmployee.team.name -join ',')] was successful"
                                    IsError = $false
                                })
                            $currentAccount.CurrentEmployee.PSObject.Properties.Remove('team')
                        }
                        $splatNewEmployee = @{
                            Uri     = "$($config.BaseUrl.Trim('/'))/employees/employee"
                            Method  = 'PATCH'
                            Headers = $headers
                            body    = ($currentAccount.CurrentEmployee | ConvertTo-Json  -Depth 10)
                        }
                        $responseEmployee = Invoke-FieritWebRequest @splatNewEmployee -UseBasicParsing

                        if ($currentAccount.UserFound) {
                            # Update User
                            Write-Verbose "Update User [$($currentAccount.accountUser.code)]"
                            Write-Verbose "Disable userAccount [$($currentAccount.accountUser.code)]"
                            $currentAccount.CurrentUser.active = $false
                            $auditLogsIfRevokeSuccess.Add([PSCustomObject]@{
                                    Action  = 'DeleteAccount'
                                    Message = "[$accountNr]  Disable account [$($currentAccount.accountUser.code)] was successful"
                                    IsError = $false
                                })

                            if ($currentAccount.CurrentUser.locationauthorisationgroup.Length -gt 0) {
                                Write-Verbose "Revoke All Locationauthorisationgroup(s) [$($currentAccount.CurrentUser.locationauthorisationgroup.code -join ',')]"
                                $auditLogsIfRevokeSuccess.Add([PSCustomObject]@{
                                        Action  = 'DeleteAccount'
                                        Message = "[$accountNr] Revoke Fierit-ECD locationAuthGroup entitlement(s): [$($currentAccount.CurrentUser.locationauthorisationgroup.code -join ',')] was successful"
                                        IsError = $false
                                    })
                                $currentAccount.CurrentUser.Locationauthorisationgroup = $null
                            }

                            if ($currentAccount.CurrentUser.role.Length -gt 0 -and $currentAccount.CurrentUser.role -notcontains $($config.DefaultTeamAssignmentGuid)) {
                                Write-Verbose "Revoke All assigned roles and assign default group [$($currentAccount.CurrentUser.Role.code -join ',')]"
                                $auditLogsIfRevokeSuccess.Add([PSCustomObject]@{
                                        Action  = 'DeleteAccount'
                                        Message = "[$accountNr] Revoke Fierit-ECD Role entitlement(s): [$($currentAccount.CurrentUser.Role.code -join ',')] was successful"
                                        IsError = $false
                                    })
                                $currentAccount.CurrentUser.role = @(@{
                                        id        = "$($config.DefaultTeamAssignmentGuid)"
                                        startdate = (Get-Date -f 'yyyy-MM-dd')
                                        enddate   = $null
                                    }
                                )

                            }
                            $splatNewUser = @{
                                Uri     = "$($config.BaseUrl.Trim('/'))/users/user"
                                Method  = 'Patch'
                                Headers = $headers
                                body    = ( $currentAccount.CurrentUser | ConvertTo-Json -Depth 10)
                            }
                            $responseUser = Invoke-FieritWebRequest @splatNewUser -UseBasicParsing

                            $auditLogs.AddRange($auditLogsIfRevokeSuccess)
                            $auditLogs.Add([PSCustomObject]@{
                                    Action  = 'DeleteAccount'
                                    Message = "[$accountNr] Delete account was successful"
                                    IsError = $false
                                })
                        } else {
                            $auditLogs.Add([PSCustomObject]@{
                                    Action  = 'DeleteAccount'
                                    Message = "[$accountNr] Fierit-ECD User account not found. Possibly already deleted, skipping action."
                                    IsError = $false
                                })
                            break
                        }
                        break
                    }
                    'NotFound' {
                        $auditLogs.Add([PSCustomObject]@{
                                Action  = 'DeleteAccount'
                                Message = "[$accountNr] Fierit-ECD Employee account not found. Possibly already deleted, skipping action."
                                IsError = $false
                            })
                        break
                    }
                }
            }
        } catch {
            $ex = $PSItem
            $errorObj = Resolve-HTTPError -ErrorObject $ex
            $errorMessage = "[$accountNr] Could not Delete Fierit-ECD account. Error:  $($ex.Exception.Message), $($errorObj.FriendlyMessage)"
            Write-Verbose $errorMessage
            $auditLogs.Add([PSCustomObject]@{
                    Action  = 'DeleteAccount'
                    Message = $errorMessage
                    IsError = $true
                })
        }
    }
    #endregion

    # Verify Success
    if (-not ($auditLogs.isError -contains $true)) {
        $success = $true
    }
} catch {
    $ex = $PSItem
    $errorObj = Resolve-HTTPError -ErrorObject $ex
    Write-Verbose "Could not Update Fierit-ECD account. Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    $auditLogs.Add([PSCustomObject]@{
            Message = "Could not Update Fierit-ECD account. Error: $($errorObj.FriendlyMessage)"
            IsError = $true
        })
} finally {
    $result = [PSCustomObject]@{
        AccountReference = $accountReferenceList
        Success          = $success
        Auditlogs        = $auditLogs
    }
    Write-Output $result | ConvertTo-Json -Depth 10
}
