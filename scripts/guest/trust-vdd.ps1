param(
    [string]$VddDir = 'C:\Admin\VDD'
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new()

$dll = Join-Path $VddDir 'MttVDD.dll'
$cer = Join-Path $VddDir 'vdd-signer.cer'

$sig = Get-AuthenticodeSignature -FilePath $dll
if (-not $sig.SignerCertificate) {
    throw 'No signer certificate found on MttVDD.dll'
}

Write-Output ("Signer: {0}" -f $sig.SignerCertificate.Subject)
Write-Output ("Thumbprint: {0}" -f $sig.SignerCertificate.Thumbprint)

Export-Certificate -Cert $sig.SignerCertificate -FilePath $cer -Type CERT -Force | Out-Null

Import-Certificate -FilePath $cer -CertStoreLocation 'Cert:\LocalMachine\Root' -ErrorAction Stop | Out-Null
Import-Certificate -FilePath $cer -CertStoreLocation 'Cert:\LocalMachine\TrustedPublisher' -ErrorAction Stop | Out-Null

Write-Output "Installed signer certificate into LocalMachine\Root and TrustedPublisher"
Get-ChildItem 'Cert:\LocalMachine\TrustedPublisher' |
    Where-Object { $_.Thumbprint -eq $sig.SignerCertificate.Thumbprint } |
    Format-List Subject, Thumbprint, NotAfter | Out-String | Write-Output
