# Stores the Bitwarden Secrets Manager access token in the Windows Credential Manager
# (PasswordVault, resource "bws", user "token"). Input is hidden.
$ErrorActionPreference = 'Stop'

$secure = Read-Host -AsSecureString 'bws access token'
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try {
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
} finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}

if ([string]::IsNullOrWhiteSpace($plain)) { throw 'empty token' }

[void][Windows.Security.Credentials.PasswordVault, Windows.Security.Credentials, ContentType = WindowsRuntime]
$vault = New-Object Windows.Security.Credentials.PasswordVault
try { $vault.Remove($vault.Retrieve('bws', 'token')) } catch { }
$vault.Add((New-Object Windows.Security.Credentials.PasswordCredential('bws', 'token', $plain)))

$check = (New-Object Windows.Security.Credentials.PasswordVault).Retrieve('bws', 'token').Password
Write-Host ("stored: {0} chars" -f $check.Length)
