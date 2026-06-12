# Define constants
$desktopPath = [System.IO.Path]::Combine($env:USERPROFILE, "Desktop")
$csvFile = Join-Path $desktopPath "Expired_AD_Accounts.csv"
$currentUser = $env:USERNAME
do {
    Clear-Host
    Write-Host "============================================="
    Write-Host "Disable Expired Auditors in Active Directory"
    Write-Host "============================================="
    Write-Host ""
    $restart = $false
    # Prompt user to enter number of days since expiration
    Write-Host "Enter 'Q' to quit or enter number of days since expiration (e.g. 20)"
    $input = Read-Host
    if ($input -match '^[Qq]$') {
        break
    }
    [int]$daysThreshold = $input
    # Get today's date
    $today = Get-Date
    # Initialize output arrays
    $clipboardLines = @()
    $csvLines = @("SamAccountName         , Name                          , ExpiredOn       , DaysExpired")
    $usersToDisable = @()
    $disabledAccounts = @()
    # Query Active Directory
    Get-ADUser -Filter * -SearchBase "OU=Audit,OU=Users,OU=ENT,DC=chenmed,DC=local" -Properties AccountExpires, Enabled, Name |
    Where-Object {
        $_.Enabled -eq $true -and
        $_.AccountExpires -ne 0 -and
        $_.AccountExpires -lt [DateTime]::MaxValue.Ticks
    } |
    ForEach-Object {
        $expireDate = [datetime]::FromFileTime($_.AccountExpires)
        $daysExpired = [int]($today - $expireDate).Days
        if ($expireDate -lt $today -and $daysExpired -gt $daysThreshold) {
            $sam = $_.SamAccountName
            $name = $_.Name
            $shortDate = $expireDate.ToShortDateString()
            $line = "{0,-24}, {1,-30}, {2,-15}, {3,5}" -f $sam, $name, $shortDate, $daysExpired
            $csvLine = $line
            $clipboardLines += $line
            $csvLines += $csvLine
            $usersToDisable += [PSCustomObject]@{
                SamAccountName = $sam
                Name           = $name
                ExpiredOn      = $shortDate
                DaysExpired    = $daysExpired
            }
        }
    }
    if ($usersToDisable.Count -gt 0) {
        Write-Host "`nThe following accounts are expired more than $daysThreshold days:`n"
        $clipboardLines | ForEach-Object { Write-Host $_ }
        # Copy to clipboard
        ($clipboardLines -join "`r`n") | Set-Clipboard
        Write-Host "`nList copied to clipboard."
        # Write CSV to desktop
        try {
            $csvLines | Out-File -FilePath $csvFile -Encoding UTF8
            Write-Host "Saved CSV to: $csvFile"
            if (Test-Path $csvFile) {
                Start-Process notepad.exe $csvFile
            }
        }
        catch {
            Write-Warning "❌ Failed to write file. Check path or permissions."
        }
        $bulkDelete = Read-Host "`nWould you like to disable ALL of these accounts now? (Y/N)"
        if ($bulkDelete -match '^[Yy]$') {
            foreach ($user in $usersToDisable) {
                try {
                    Disable-ADAccount -Identity $user.SamAccountName
                    Write-Host "✅ Disabled: $($user.SamAccountName)"
                    $disabledAccounts += $user
                }
                catch {
                    Write-Warning "❌ Failed to disable $($user.SamAccountName): $_"
                }
            }
        }
        else {
            foreach ($user in $usersToDisable) {
                $msg = "Disable user '$($user.Name)' (Expired on: $($user.ExpiredOn), $($user.DaysExpired) days ago)? (Y/N)"
                $confirm = Read-Host $msg
                if ($confirm -match '^[Yy]$') {
                    try {
                        Disable-ADAccount -Identity $user.SamAccountName
                        Write-Host "✅ Disabled: $($user.SamAccountName)"
                        $disabledAccounts += $user
                    }
                    catch {
                        Write-Warning "❌ Failed to disable $($user.SamAccountName): $_"
                    }
                } else {
                    Write-Host "⏭️ Skipped: $($user.SamAccountName)"
                }
            }
        }
        # Append disabled user list to CSV and copy to clipboard
        if ($disabledAccounts.Count -gt 0) {
            $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            $header = "Username [$currentUser] disabled the following accounts on ${timestamp}:`r`n"
            $header += "SamAccountName         , Name                          , ExpiredOn       , DaysExpired"
            $disabledLines = $disabledAccounts | ForEach-Object {
                "{0,-24}, {1,-30}, {2,-15}, {3,5}" -f $_.SamAccountName, $_.Name, $_.ExpiredOn, $_.DaysExpired
            }
            $fullOutput = @($header) + $disabledLines
            $fullOutput | Add-Content -Path $csvFile
            ($fullOutput -join "`r`n") | Set-Clipboard
            Write-Host "`n✅ Disabled user list copied to clipboard and appended to CSV."
        }
    }
    else {
        Write-Host "`nNo expired accounts found beyond $daysThreshold days."
    }
    Read-Host "Press Enter to continue..."
} while ($true)