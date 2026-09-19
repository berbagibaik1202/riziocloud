param(
    [string]$DnsName = 'localhost',
    [string]$OpenSsl = 'openssl'
)
$ErrorActionPreference = 'Stop'
if ($DnsName -notmatch '^[A-Za-z0-9.-]+$') { throw 'DnsName tidak valid.' }
if (-not (Get-Command $OpenSsl -ErrorAction SilentlyContinue)) {
    $gitOpenSsl = 'C:\Program Files\Git\usr\bin\openssl.exe'
    if (Test-Path -LiteralPath $gitOpenSsl) { $OpenSsl = $gitOpenSsl }
    else { throw 'OpenSSL tidak ditemukan. Pasang OpenSSL atau gunakan -OpenSsl.' }
}
$certDir = Join-Path $PSScriptRoot 'certs'
New-Item -ItemType Directory -Path $certDir -Force | Out-Null
foreach ($name in @('ca.key', 'ca.crt', 'server.key', 'server.crt')) {
    if (Test-Path -LiteralPath (Join-Path $certDir $name)) {
        throw 'Sertifikat sudah ada. Gunakan direktori ini tanpa menimpa identitas CA.'
    }
}
$configPath = Join-Path $certDir 'server.cnf'
@"
[req]
distinguished_name = dn
prompt = no
req_extensions = v3_req
[dn]
CN = $DnsName
[v3_req]
subjectAltName = @alt_names
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
[alt_names]
DNS.1 = $DnsName
DNS.2 = localhost
DNS.3 = emqx
IP.1 = 127.0.0.1
"@ | Set-Content -LiteralPath $configPath -Encoding ascii
& $OpenSsl req -x509 -newkey rsa:2048 -nodes -sha256 -days 365 -subj '/CN=RizIO Development CA' -keyout (Join-Path $certDir 'ca.key') -out (Join-Path $certDir 'ca.crt')
if ($LASTEXITCODE -ne 0) { throw 'Gagal membuat CA.' }
& $OpenSsl req -new -newkey rsa:2048 -nodes -keyout (Join-Path $certDir 'server.key') -out (Join-Path $certDir 'server.csr') -config $configPath
if ($LASTEXITCODE -ne 0) { throw 'Gagal membuat CSR.' }
& $OpenSsl x509 -req -in (Join-Path $certDir 'server.csr') -CA (Join-Path $certDir 'ca.crt') -CAkey (Join-Path $certDir 'ca.key') -CAcreateserial -out (Join-Path $certDir 'server.crt') -days 90 -sha256 -extfile $configPath -extensions v3_req
if ($LASTEXITCODE -ne 0) { throw 'Gagal menandatangani sertifikat.' }
& $OpenSsl verify -CAfile (Join-Path $certDir 'ca.crt') (Join-Path $certDir 'server.crt')
if ($LASTEXITCODE -ne 0) { throw 'Verifikasi sertifikat gagal.' }
Write-Host 'Sertifikat development dibuat. Instal ke trust store perangkat uji; jangan menonaktifkan verifikasi TLS.'
