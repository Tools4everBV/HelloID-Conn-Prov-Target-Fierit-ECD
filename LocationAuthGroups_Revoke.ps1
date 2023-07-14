######################################################################
# HelloID-Conn-Prov-Target-Fierit-ECD-Entitlement-RevokeLocationAuthGroup
#
# Version: 1.0.2
######################################################################
# Initialize default values
$config = $configuration | ConvertFrom-Json
$p = $person | ConvertFrom-Json
$aRef = $AccountReference | ConvertFrom-Json
$pRef = $permissionReference | ConvertFrom-Json
$success = $false
$auditLogs = [System.Collections.Generic.List[PSCustomObject]]::new()

# Enable TLS1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

# Set debug logging
switch ($($config.IsDebug)) {
    $true { $VerbosePreference = 'Continue' }
    $false { $VerbosePreference = 'SilentlyContinue' }
}

#region functions
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
#endregion

try {
    Write-Verbose 'Setting authorization header'
    $token = Get-AccessToken
    $headers = Set-AuthorizationHeaders -Token $token

    foreach ($employment in $aRef) {
        try {
            Write-Verbose "Getting user with usercode [$($employment.UserId)]"
            $splatParams = @{
                Uri     = "$($config.BaseUrl)/users/user?usercode=$($employment.UserId)"
                Method  = 'GET'
                Headers = $headers
            }
            $responseUser = Invoke-FieritWebRequest @splatParams  -UseBasicParsing
            if ($null -eq $responseUser) {
                $userFound = 'NotFound'
                if ($dryRun -eq $true) {
                    Write-Warning "[DryRun] [$($employment.UserId)] Fierit-ECD account not found. Possibly already deleted, skipping action."
                }
            } else {
                $userFound = 'Found'
            }

            # Add an auditMessage showing what will happen during enforcement
            if ($dryRun -eq $true) {
                Write-Warning "[DryRun] [$($employment.UserId)] Revoke Fierit-ECD locationAuthGroup entitlement: [$($pRef.Name)] to: [$($p.DisplayName)] will be executed during enforcement"
            }

            if (-not($dryRun -eq $true)) {
                switch ($userFound) {
                    'Found' {
                        Write-Verbose "Revoking Fierit-ECD locationAuthGroup entitlement: [$($pRef.Name)]"

                        if (($responseUser.locationauthorisationgroup.Length -eq 0) -or
                            ($responseUser.locationauthorisationgroup.code -notcontains $pRef.code)) {

                            $auditMessage = "Revoke Fierit-ECD locationAuthGroup entitlement: [$($pRef.Name)]. Already removed"

                        } else {
                            Write-Verbose 'Creating list of currently assigned locationAuthGroups'
                            $currentLocationAuthGroups = [System.Collections.Generic.List[object]]::new()
                            $currentLocationAuthGroups.AddRange($responseUser.locationauthorisationgroup)

                            Write-Verbose 'Removing locationAuthGroup from the list'
                            $locationAuthGroupToRemove = $currentLocationAuthGroups | Where-Object { $_.code -eq $pRef.Code }
                            [void]$currentLocationAuthGroups.Remove($locationAuthGroupToRemove)

                            $responseUser.locationauthorisationgroup = $currentLocationAuthGroups

                            # An empty array doensn't remove the locationauthorisationgroup
                            if ($responseUser.locationauthorisationgroup.count -eq 0) {
                                $responseUser.locationauthorisationgroup = $null
                            }

                            $splatPatchUserParams = @{
                                Uri     = "$($config.BaseUrl)/users/user"
                                Method  = 'PATCH'
                                Headers = $headers
                                Body    = ($responseUser | ConvertTo-Json -Depth 10)
                            }
                            $auditMessage = "Revoke Fierit-ECD locationAuthGroup entitlement: [$($pRef.Name)] was successful"

                            $responseUser = Invoke-FieritWebRequest @splatPatchUserParams -UseBasicParsing
                        }
                        $auditLogs.Add([PSCustomObject]@{
                                Message = "[$($employment.UserId)] $auditMessage"
                                IsError = $false
                            })
                    }
                    'NotFound' {
                        $auditLogs.Add([PSCustomObject]@{
                                Message = "[$($employment.UserId)] Fierit-ECD account not found. Possibly already deleted, skipping action."
                                IsError = $false
                            })
                    }
                }
            }
        } catch {
            $ex = $PSItem
            $errorObj = Resolve-HTTPError -ErrorObject $ex
            Write-Verbose "[$($employment.UserId)] Could not Revoke Fierit-ECD locationAuthGroup entitlement. Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
            $auditLogs.Add([PSCustomObject]@{
                    Message = "[$($employment.UserId)] Could not Revoke Fierit-ECD locationAuthGroup entitlement. Error: $($errorObj.FriendlyMessage)"
                    IsError = $true
                })
        }
    }
    if (-not ($auditLogs.isError -contains $true)) {
        $success = $true
    }
} catch {
    $ex = $PSItem
    $errorObj = Resolve-HTTPError -ErrorObject $ex
    Write-Verbose "Could not Revoke Fierit-ECD locationAuthGroup entitlement. Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    $auditLogs.Add([PSCustomObject]@{
            Message = "Could not Revoke Fierit-ECD locationAuthGroup entitlement. Error: $($errorObj.FriendlyMessage)"
            IsError = $true
        })
} finally {
    $result = [PSCustomObject]@{
        Success   = $success
        Auditlogs = $auditLogs
    }
    Write-Output $result | ConvertTo-Json -Depth 10
}
