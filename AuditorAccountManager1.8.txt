<#
.SYNOPSIS
This script automates the creation of auditor accounts.

.DESCRIPTION
This script creates and manages auditor accounts. It checks for duplicate accounts, enables/disables accounts, 
creates accounts with secure passwords, and passes account details to users clipboard, logging actions to temp folder on the machines public documents folder.

#>

import-Module ActiveDirectory

# Set the log file path to a folder in the PUBLIC profile
$publicProfilePath = [System.Environment]::GetFolderPath('CommonDocuments')
$logFolderPath = "$publicProfilePath\Temp\AuditorAccountLogs"
if (-not (Test-Path $logFolderPath)) {
    New-Item -Path $logFolderPath -ItemType Directory | Out-Null
}
$logFilePath = "$logFolderPath\AuditorAccountLog.txt"

# Function to write log entries
function Write-Log {
    param (
        [string]$message
    )
    $timestamp = Get-Date -Format "yy-MM-dd HH:mm:ss"
    $logEntry = "$timestamp - $message"
    Add-Content -Path $logFilePath -Value $logEntry
}

# Function to generate a random password
function Set-Password {
    $passwordLength = 10
    $lowercase = [char[]]"abcdefghijklmnopqrstuvwxyz"
    $uppercase = [char[]]"ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    $numbers = [char[]]"0123456789"
    $symbols = [char[]]"!#$@&"

    $password = @(
        Get-Random -InputObject $lowercase
        Get-Random -InputObject $uppercase
        Get-Random -InputObject $numbers
        Get-Random -InputObject $symbols
    )

    while ($password.Length -lt $passwordLength) {
        $password += Get-Random -InputObject ($lowercase + $uppercase + $numbers + $symbols)
    }

    # Shuffle the password to ensure randomness
    $password = $password | Get-Random -Count $password.Length

    # Convert the array to a string
    return -join $password
}
# Function to append technician action to account description with a new line before each amendment
function Append-Description {
    param (
        [string]$Username,
        [string]$Action
    )
    $TechnicianUsername = ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name).Split("\")[1]
    $ExistingDescription = (Get-ADUser -Identity $Username -Properties Description).Description
    $Timestamp = (Get-Date).ToUniversalTime().AddHours(-5).ToString("MM/dd/yy HH:mm") # Convert to EST and format
    $NewEntry = "`n- $Action by $TechnicianUsername ($Timestamp)"
    $MaxDescriptionLength = 1024

    # Calculate the total length of the description including the new entry
    $TotalLength = $ExistingDescription.Length + $NewEntry.Length

    # Truncate by removing whole lines from the beginning until the total length is within the limit
    while ($TotalLength -ge $MaxDescriptionLength) {
        $ExistingDescription = $ExistingDescription.Substring($ExistingDescription.IndexOf("`n") + 2)
        $TotalLength = $ExistingDescription.Length + $NewEntry.Length
    }

    # Update the description with the new entry always on a new line
    $UpdatedDescription = "$ExistingDescription$NewEntry"
    Set-ADUser -Identity $Username -Description $UpdatedDescription.Trim()
    Write-Log "Updated account description for $Username with action: $Action by $TechnicianUsername"
}



# Function to check if an OU exists
function Test-OUExists {
    param (
        [string]$OUPath
    )
    try {
        Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$OUPath'" -ErrorAction Stop | Out-Null
        return $true
    } catch {
        return $false
    }
}

# Function to check if an account is disabled and prompt for enabling it if necessary
function Ensure-AccountEnabled {
    param (
        [string]$Username
    )
    $User = Get-ADUser -Identity $Username -Properties Enabled
    if ($User.Enabled -eq $false) {
        Write-Host "Account $Username is currently disabled." -ForegroundColor Yellow
        $enableAccount = Read-Host "Would you like to enable the account before taking action? (Y/N)"
        if ($enableAccount -eq 'Y' -or $enableAccount -eq 'y') {
            Enable-ADAccount -Identity $Username
            Append-Description -Username $Username -Action "Enabled"
            Write-Log "Enabled account: $Username"
            Write-Host "Account $Username has been enabled." -ForegroundColor Green
        } else {
            Write-Host "Action aborted. The account must be enabled to proceed." -ForegroundColor Red
            throw "Account $Username is disabled and was not enabled."
        }
    }
}

# Function to handle duplicate accounts
function Handle-DuplicateAccounts {
    param (
        [array]$DuplicateAccounts
    )
    Write-Host "Duplicate accounts found!" -ForegroundColor Yellow
    $DuplicateAccounts | ForEach-Object {
        $accountInfo = Get-ADUser -Identity $_ -Properties LastLogonDate
        Write-Host "Account: $($_.SamAccountName), Last Logon Date: $($accountInfo.LastLogonDate)"
    }
    $oldestAccount = $DuplicateAccounts | Sort-Object {
        $logonDate = (Get-ADUser -Identity $_ -Properties LastLogonDate).LastLogonDate
        if ($logonDate) {
            return $logonDate
        } else {
            return $_.WhenCreated
        }
    } | Select-Object -First 1
    $deleteOldest = Read-Host "Would you like to delete the account with the oldest Last Login/Created Date?: $($oldestAccount.SamAccountName)? (Y/N)"
    if ($deleteOldest -eq 'Y' -or $deleteOldest -eq 'y') {
        Remove-ADUser -Identity $oldestAccount.SamAccountName -Confirm:$false
        Write-Log "Deleted duplicate account: $($oldestAccount.SamAccountName)"
        Write-Host "Deleted duplicate account: $($oldestAccount.SamAccountName)" -ForegroundColor Green
    } else {
        Write-Host "Duplicate account was not deleted." -ForegroundColor Red
    }
}

function Set-Account {
    $AccountWasCreated = $false  # Track if the account was actually created
    $Username = $null
    
    try {
        $FirstName = Read-Host "Enter First Name"
        $LastName = Read-Host "Enter Last Name"
        $OUPath = "OU=Audit,OU=Users,OU=ENT,DC=chenmed,DC=local"
        if ($FirstName -notmatch "^[a-zA-Z'-]+$" -or $LastName -notmatch "^[a-zA-Z'-]+$") {
            Write-Host "First Name and Last Name must only contain alphabetic characters, hyphens, or apostrophes, and must not contain spaces." -ForegroundColor Red
            Write-Log "Invalid input detected: Non-alphabetic characters, spaces, or invalid symbols in First Name or Last Name."
            return
        }

        # Check for existing user before asking for Company Name
        $ExistingUser = Get-ADUser -Filter "GivenName -like '$FirstName' -and Surname -like '$LastName'" -SearchBase $OUPath -Properties DisplayName, GivenName, Surname, UserPrincipalName
        if ($ExistingUser) {
            Write-Host "`n========================================" -ForegroundColor Yellow
            Write-Host "Auditor account for $FirstName $LastName already exists." -ForegroundColor Yellow
            Write-Host "UPN: $($ExistingUser.UserPrincipalName)" -ForegroundColor Yellow
            Write-Host "========================================`n" -ForegroundColor Yellow
            Write-Log "Attempted to create duplicate account for $FirstName $LastName"
            return  # Exit if an existing account is found
        }

        # Proceed to ask for Company Name only if no duplicate is found
        $FullCompanyName = Read-Host "Enter Company Name"

        # Generate the username
        $FirstNameTrimmed = $FirstName.Trim().ToLower()
        $LastNameTrimmed = $LastName.Trim().ToLower()
        $CompanyNameTrimmed = $FullCompanyName.Trim().ToLower()

        # Truncate company name to 8 characters if it's longer
        if ($CompanyNameTrimmed.Length -gt 8) {
            $CompanyNameTrimmed = $CompanyNameTrimmed.Substring(0, 8)
        }

        # Truncate first name to 6 characters if it's longer
        if ($FirstNameTrimmed.Length -gt 12) {
            $FirstNameTrimmed = $FirstNameTrimmed.Substring(0, 6)
        }

        $Username = "aud.$CompanyNameTrimmed.$FirstNameTrimmed$($LastNameTrimmed[0])"

        # Ensure the username does not exceed 20 characters
        $MaxUsernameLength = 20
        if ($Username.Length -gt $MaxUsernameLength) {
            $ExcessLength = $Username.Length - $MaxUsernameLength
            $FirstNameTrimmed = $FirstNameTrimmed.Substring(0, [Math]::Max($FirstNameTrimmed.Length - $ExcessLength, 1))
            $Username = "aud.$CompanyNameTrimmed.$FirstNameTrimmed$($LastNameTrimmed[0])"
            if ($Username.Length -gt $MaxUsernameLength) {
                $Username = $Username.Substring(0, $MaxUsernameLength) # Ensure it's within the limit
            }
        }

        # Validate the username
        if ($Username -match '[^a-zA-Z0-9._-]') {
            throw "The username '$Username' contains invalid characters."
        }

        # Remove trailing period if the username is too short after truncation
        $Username = $Username.Trim('.')

        # Ensure the username is not empty after sanitization and truncation
        if ([string]::IsNullOrWhiteSpace($Username) -or $Username -eq 'aud..') {
            throw "The username '$Username' is not valid after sanitization."
        }

        # Log the generated username
        Write-Log "Generated username: $Username"

        $PlainTextPassword = Set-Password
        $SecurePassword = ConvertTo-SecureString -String $PlainTextPassword -AsPlainText -Force  # Convert the password to SecureString

        $UPN = "$Username@chenmed.local"
        $EmailAddress = "$Username@chenmed.com"
        $FormattedFirstName = $FirstName.Substring(0,1).ToUpper() + $FirstName.Substring(1).ToLower()
        $FormattedLastName = $LastName.Substring(0,1).ToUpper() + $LastName.Substring(1).ToLower()
        $FormattedFullCompanyName = $FullCompanyName.Substring(0,1).ToUpper() + $FullCompanyName.Substring(1).ToLower()
        $AccountDescription = "Auditor account for $FormattedFirstName $FormattedLastName"

        # Log the details being passed to New-ADUser
        Write-Log "Creating AD user with the following details: Name=$FormattedFirstName $FormattedLastName, SamAccountName=$Username, DisplayName=$FormattedFirstName $FormattedLastName, GivenName=$FormattedFirstName, Surname=$FormattedLastName, UserPrincipalName=$UPN, EmailAddress=$EmailAddress, Description=$AccountDescription, Company=$FullCompanyName, Path=$OUPath"

        # Try creating the user with the generated UPN
        try {
            New-ADUser -Name "$FormattedFirstName $FormattedLastName" `
                       -SamAccountName $Username `
                       -DisplayName "$FormattedFirstName $FormattedLastName" `
                       -GivenName $FormattedFirstName `
                       -Surname $FormattedLastName `
                       -UserPrincipalName $UPN `
                       -EmailAddress $EmailAddress `
                       -Description $AccountDescription `
                       -Company $FormattedFullCompanyName `
                       -Path $OUPath `
                       -AccountPassword $SecurePassword  # Use the SecureString password here
            $AccountWasCreated = $true
            Write-Log "Created account for $FormattedFirstName $FormattedLastName with username $Username"
        } catch {
            if ($_ -match "UPN value provided for addition/modification is not unique") {
                Write-Host "The generated UPN is not unique. You will need to enter a custom username." -ForegroundColor Yellow
                Write-Log "Generated UPN not unique: $UPN"
                
                # Allow the user to enter a custom username
                $Username = Read-Host "Enter a unique username (without domain suffix)"
                $UPN = "$Username@chenmed.local"
                $EmailAddress = "$Username@chenmed.com"
                
                # Retry account creation with the custom username
                try {
                    New-ADUser -Name "$FormattedFirstName $FormattedLastName" `
                               -SamAccountName $Username `
                               -DisplayName "$FormattedFirstName $FormattedLastName" `
                               -GivenName $FormattedFirstName `
                               -Surname $FormattedLastName `
                               -UserPrincipalName $UPN `
                               -EmailAddress $EmailAddress `
                               -Description $AccountDescription `
                               -Company $FormattedFullCompanyName `
                               -Path $OUPath `
                               -AccountPassword $SecurePassword  # Use the SecureString password here
                    $AccountWasCreated = $true
                    Write-Log "Created account for $FormattedFirstName $FormattedLastName with custom username $Username"
                } catch {
                    Write-Host "An error occurred while creating the account with the custom username: $_" -ForegroundColor Red
                    Write-Log "Error creating account with custom username: $_"
                    return
                }
            } else {
                throw  # Re-throw the error if it's not related to UPN uniqueness
            }
        }

        # Enable the account after creation
        Enable-ADAccount -Identity $Username

        # Set additional properties like password settings
        Set-ADUser -Identity $Username -ChangePasswordAtLogon $True -CannotChangePassword $False

        $validDate = $false
        do {
            try {
                $ExpirationInput = Read-Host "Enter Expiration Date (MM/DD/YYYY)"
                $ExpirationDate = [datetime]::ParseExact($ExpirationInput, "MM/dd/yyyy", $null).AddHours(23).AddMinutes(59).AddSeconds(59)

                Set-ADUser -Identity $Username -AccountExpirationDate $ExpirationDate
                $validDate = $true
                Write-Log "Set expiration date for $Username to $ExpirationDate"
            } catch {
                Write-Host "Invalid date format. Please enter the expiration date in MM/DD/YYYY format." -ForegroundColor Red
                Write-Log "Invalid date format entered for expiration date"
            }
        } while (-not $validDate)
        
        # Prepare account details for clipboard
        $usernameWithoutDomain = $UPN.Split('@')[0]
        $clipboardOutput = @(
            "Auditor: $FormattedFirstName $FormattedLastName",
            "Username: $usernameWithoutDomain",
            "Password: $PlainTextPassword",  # Keep this as PlainText for the clipboard
            "Company: $FormattedFullCompanyName",
            "Expires: $($ExpirationDate.ToString('MM/dd/yy HH:mm:'))",
            "Reminder: Please submit a USB unlock request for this audit here: https://cnmd.io/n4je1h"
        )

        # Copy account details to clipboard
        $clipboardOutput | Out-String | Set-Clipboard

        # Simplify console output to show success message and clipboard notification
        Write-Host "`n========================================" -ForegroundColor Green
        Write-Host "Account created successfully." -ForegroundColor Green
        Write-Host "Account details (including password) have been copied to your clipboard." -ForegroundColor Green
        Write-Host "========================================`n" -ForegroundColor Green

        # Append creation action to the description
        Append-Description -Username $Username -Action "Created"
        
    } catch {
        Write-Host "An error occurred while creating the account: $_" -ForegroundColor Red
        Write-Log "Error creating account: $_"
    }
}





# Function to get account details and perform actions
function Get-AccountDetails {
    try {
        $FirstName = Read-Host "Enter First Name"
        $LastName = Read-Host "Enter Last Name"

        # Specify the OU in the -SearchBase parameter
        $OUPath = "OU=Audit,OU=Users,OU=ENT,DC=chenmed,DC=local"

        # Make the search case-insensitive using -like
        $UserDetails = Get-ADUser -Filter "GivenName -like '*$FirstName*' -and Surname -like '*$LastName*'" -SearchBase $OUPath -Properties DisplayName, GivenName, Surname, UserPrincipalName, EmailAddress, AccountExpirationDate, Enabled, LastLogonDate, Description, Company

        Write-Host "`n========================================"
        if ($UserDetails.Count -gt 1) {
            Handle-DuplicateAccounts -DuplicateAccounts $UserDetails
        } elseif ($UserDetails) {
            $FormattedFirstName = $UserDetails.GivenName.Substring(0,1).ToUpper() + $UserDetails.GivenName.Substring(1).ToLower()
            $FormattedLastName = $UserDetails.Surname.Substring(0,1).ToUpper() + $UserDetails.Surname.Substring(1).ToLower()
            $FormattedCompanyName = if ($UserDetails.Company) { $UserDetails.Company.Substring(0,1).ToUpper() + $UserDetails.Company.Substring(1).ToLower() } else { "N/A" }

            Write-Host "Details for ${FormattedFirstName} ${FormattedLastName}"
            Write-Host "========================================"
            Write-Host "First Name: $FormattedFirstName"
            Write-Host "Last Name: $FormattedLastName"
            Write-Host "UPN: $($UserDetails.UserPrincipalName.Split('@')[0])"
            Write-Host "Account Expiration Date: $($UserDetails.AccountExpirationDate.ToString('MM/dd/yyyy HH:mm:ss'))"
            if ($UserDetails.Enabled -eq $true) {
                Write-Host "Account Status: Enabled" -ForegroundColor Green
            } else {
                Write-Host "Account Status: Disabled" -ForegroundColor Red
            }
            Write-Host "Last Logon Date: $($UserDetails.LastLogonDate)"
            Write-Host "Description: $($UserDetails.Description)"
            Write-Host "Company: $FormattedCompanyName"
            Write-Log "Displayed details for $FirstName $LastName"

            # Prepare account details for clipboard
            $usernameWithoutDomain = $UserDetails.UserPrincipalName.Split('@')[0]
            $clipboardOutput = @(
                "Auditor: $FormattedFirstName $FormattedLastName",
                "Username: $usernameWithoutDomain",
                "Password: Please reset password for returning auditors",
                "Company: $FormattedCompanyName",
                "Expires: $($UserDetails.AccountExpirationDate.ToString('MM/dd/yyyy HH:mm:ss'))"
            )
            $clipboardOutput | Out-String | Set-Clipboard

            # Extract the username without domain
            $Username = $UserDetails.UserPrincipalName.Split('@')[0]

            # Sub-menu for additional actions
            do {
                Write-Host "`nWould you like to:"
                Write-Host "1. Reset Password"
                Write-Host "2. Set Expiration Date"
                Write-Host "3. Enable/Disable Account"
                Write-Host "N. Return to Main Menu"
                $subChoice = Read-Host "Please select an option"

                switch ($subChoice) {
                    "1" { 
                        Ensure-AccountEnabled -Username $Username
                        Reset-Password -Username $Username 
                    }
                    "2" { 
                        Ensure-AccountEnabled -Username $Username
                        Set-Expiration -Username $Username 
                    }
                    "3" { 
                        $Action = Read-Host "Enter 'enable' to enable the account or 'disable' to disable the account"
                        Enable-DisableAccount -Username $Username -Action $Action
                    }
                    "N" { break }
                    default { Write-Host "Invalid choice, please try again." -ForegroundColor Red }
                }
            } while ($subChoice -ne "N")
        } else {
            Write-Host "No auditor account found for $FirstName $LastName in the specified OU."
            Write-Log "Checked for existing account: No account found for $FirstName $LastName"
        }
        Write-Host "========================================`n"
    } catch {
       Write-Host "An error occurred while checking if auditor account exists: $_" -ForegroundColor Red
       Write-Log "Error checking for existing account: $_"
    }
}

# Function for enabling or disabling an auditor account
function Enable-DisableAccount {
    param (
        [string]$Username,
        [string]$Action
    )
    try {
        # Ensure Username is correctly formatted without domain
        $Username = $Username.Split('@')[0]

        # Retrieve the user based on the username
        $User = Get-ADUser -Filter "SamAccountName -eq '$Username'" -Properties AccountExpirationDate, LockedOut, Enabled -ErrorAction Stop
        
        if ($User) {
            # Check if the account is expired
            if ($User.AccountExpirationDate -lt (Get-Date)) {
                if ($Action -eq 'enable') {
                    Write-Host "Account $Username is expired. Please update the expiration date before enabling." -ForegroundColor Yellow
                    $UpdateExpiration = Read-Host "Would you like to update the expiration date? (Y/N)"
                    if ($UpdateExpiration -eq 'Y' -or $UpdateExpiration -eq 'y') {
                        $NewExpirationDate = Read-Host "Enter new expiration date (MM/DD/YYYY)"
                        try {
                            $ExpirationDate = [datetime]::ParseExact($NewExpirationDate, "MM/dd/yyyy", $null).AddHours(23).AddMinutes(59).AddSeconds(59)
                            Set-ADUser -Identity $Username -AccountExpirationDate $ExpirationDate
                            Write-Log "Updated expiration date for $Username to $ExpirationDate"
                        } catch {
                            Write-Host "Invalid date format. Please enter the expiration date in MM/DD/YYYY format." -ForegroundColor Red
                            Write-Log "Failed to update expiration date for $Username. Error: $_"
                            return
                        }
                    } else {
                        Write-Log "Enable action aborted for expired account: $Username"
                        return
                    }
                } elseif ($Action -eq 'disable' -and $User.Enabled) {
                    # Proceed to disable the account without requiring expiration update
                    Disable-ADAccount -Identity $Username -ErrorAction Stop
                    Append-Description -Username $Username -Action "Disabled"
                    Write-Log "Disabled account: $Username"
                    Write-Host "Account $Username disabled." -ForegroundColor Green
                    return
                }
            }

            # Get the user's OU
            $UserOU = $User.DistinguishedName

            # Check if the user is in the Audit OU
            if ($UserOU -like "*OU=Audit,OU=Users,OU=ENT,DC=chenmed,DC=local*") {
                Write-Host "`n========================================"

                if ($Action -eq 'enable') {
                    Enable-ADAccount -Identity $User.SamAccountName -ErrorAction Stop
                    Append-Description -Username $Username -Action "Enabled"
                    Write-Log "Enabled account: $Username"
                    Write-Host "Account $Username enabled." -ForegroundColor Green
                } elseif ($Action -eq 'disable') {
                    Disable-ADAccount -Identity $User.SamAccountName -ErrorAction Stop
                    Append-Description -Username $Username -Action "Disabled"
                    Write-Log "Disabled account: $Username"
                    Write-Host "Account $Username disabled." -ForegroundColor Green
                } else {
                    throw "Invalid action specified. Please enter 'enable' or 'disable'."
                }

                Write-Host "========================================`n"
            } else {
                Write-Host "`n========================================"
                Write-Host "This function can only enable/disable accounts in the Audit OU."
                Write-Host "Account $Username is not in the Audit OU."
                Write-Host "========================================`n"
                Write-Log "Attempted to enable/disable account not in Audit OU: $Username"
            }
        } else {
            Write-Host "`n========================================"
            Write-Host "Account $Username does not exist."
            Write-Host "========================================`n"
            Write-Log "Attempted to enable/disable non-existent account: $Username"
        }
    } catch {
        Write-Host "An error occurred while enabling/disabling account: $_" -ForegroundColor Red
        Write-Log "Error enabling/disabling account: $_"
    }
}




# Function for resetting auditor account password
function Reset-Password {
    param (
        [string]$Username
    )
    try {
        if (-not $Username) {
            $Username = Read-Host "Enter Username to reset password"
        }

        # Check if the user exists
        $User = Get-ADUser -Filter "SamAccountName -eq '$Username'"
        if ($User) {
            # Get the user's OU
            $UserOU = $User.DistinguishedName

            # Check if the user is in the Audit OU
            if ($UserOU -like "*OU=Audit,OU=Users,OU=ENT,DC=chenmed,DC=local*") {
                Ensure-AccountEnabled -Username $Username

                $NewPassword = Set-Password
                $SecureNewPassword = ConvertTo-SecureString -String $NewPassword -AsPlainText -Force

                # Reset the password using Set-ADAccountPassword
                Set-ADAccountPassword -Identity $Username -Reset -NewPassword $SecureNewPassword

                # Set the ChangePasswordAtLogon and AllowPasswordChange options
                Set-ADUser -Identity $Username -ChangePasswordAtLogon $True -CannotChangePassword $False

                # Prepare the output message
                $output = @(
                    "========================================",
                    "Password reset for user $Username.",
                    "New Password: [PASSWORD COPIED TO CLIPBOARD]",
                    "========================================"
                )

                # Display the output message without the actual password
                $output | Write-Host

                # Copy the new password to the clipboard
                $clipboardOutput = @(
                    "Username: $Username",
                    "Password: $NewPassword", 
                    "Reminder: Please submit a USB unlock request for this audit here: https://cnmd.io/n4je1h"
                )
                
                $clipboardOutput | Set-Clipboard
                Write-Host "New password copied to clipboard, do not copy anything before pasting it in a message for the requestor " -ForegroundColor Green
                Write-Log "Password reset for $Username"

                # Append password reset action to the description
                Append-Description -Username $Username -Action "Password reset"

            } else {
                Write-Host "`n========================================"
                Write-Host "This function can only reset passwords for accounts in the Audit OU."
                Write-Host "Account $Username is not in the Audit OU."
                Write-Host "========================================`n"
                Write-Log "Attempted password reset for account not in Audit OU: $Username"
            }
        } else {
            Write-Host "`n========================================"
            Write-Host "Account $Username does not exist."
            Write-Host "========================================`n"
            Write-Log "Attempted password reset for non-existent account: $Username"
        }
    } catch {
        Write-Host "An error occurred while resetting the password: $_" -ForegroundColor Red
        Write-Log "Error resetting password: $_"
    }
}

# Function for setting auditor account expiration date
function Set-Expiration {
    param (
        [string]$Username
    )
    try {
        if (-not $Username) {
            $Username = Read-Host "Enter Username"
        }

        # Check if the user exists
        if (Get-ADUser -Filter "SamAccountName -eq '$Username'") {
            # Get the user's OU
            $UserOU = (Get-ADUser -Identity $Username).DistinguishedName

            # Check if the user is in the Audit OU
            if ($UserOU -like "*OU=Audit,OU=Users,OU=ENT,DC=chenmed,DC=local*") {
                $ExpirationInput = Read-Host "Enter Expiration Date (MM/DD/YYYY)"

                try {
                    # Convert the input to a datetime object and set time to 23:59:59 (end of day)
                    $ExpirationDate = [datetime]::ParseExact($ExpirationInput, "MM/dd/yyyy", $null).AddHours(23).AddMinutes(59).AddSeconds(59)

                    Set-ADUser -Identity $Username -AccountExpirationDate $ExpirationDate
                    Write-Host "Account expiration date set to end of day on $ExpirationInput"
                    Write-Log "Set expiration date for $Username to $ExpirationDate"

                    # Append expiration date action to the description
                    Append-Description -Username $Username -Action "Expiration date set to $ExpirationDate"

                } catch {
                    Write-Host "Invalid date format. Please enter the expiration date in MM/DD/YYYY format." -ForegroundColor Red
                    Write-Log "Invalid date format entered for setting expiration date"
                }
            } else {
                Write-Host "`n========================================"
                Write-Host "This function can only set expiration for accounts in the Audit OU."
                Write-Host "Account $Username is not in the Audit OU."
                Write-Host "========================================`n"
                Write-Log "Attempted to set expiration for account not in Audit OU: $Username"
            }
        } else {
            Write-Host "`n========================================"
            Write-Host "Account $Username does not exist."
            Write-Host "========================================`n"
            Write-Log "Attempted to set expiration for non-existent account: $Username"
        }
    } catch {
       Write-Host "An error occurred while setting account expiration: $_" -ForegroundColor Red
       Write-Log "Error setting expiration date: $_"
    }
}

# Updated Get-Menu function
function Get-Menu {
    do {
        Clear-Host
        Write-Host "==================~Auditor Account Manager~==================`n"
        Write-Host "1. Create Account"
        Write-Host "2. Check Account Details"
        Write-Host "3. Reset Password"
        Write-Host "4. Set Expiration"
        Write-Host "5. Enable/Disable Account"
        Write-Host "6. Exit"
        Write-Host "Account passwords and details will be saved to your clipboard, only paste them into messages intended for requestor" -ForegroundColor Green
        $choice = Read-Host "Please select an option"

        switch ($choice) {
            "1" { Set-Account }
            "2" { Get-AccountDetails }
            "3" { Reset-Password }
            "4" { Set-Expiration }
            "5" { 
                $Username = Read-Host "Enter the Username (e.g., aud.ciox.testerl)"
                $Action = Read-Host "Enter 'enable' to enable the account or 'disable' to disable the account"
                Enable-DisableAccount -Username $Username -Action $Action 
            }
            "6" { return }  # Exit the menu
            default { Write-Host "Invalid choice, please try again." -ForegroundColor Red }
        }

        # Ask the user if they want to make another choice
        $continue = Read-Host "Would you like to continue using app? Enter 'Y' to continue, 'N' to quit"
        if ($continue -eq "N" -or $continue -eq "n") {
            break  # Exit the loop if the user chooses not to continue
        }
    } while ($true)
}

# Call the Auditor Menu function
Get-Menu

