function Test-DanewSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [string]$ExpectedSha256
    )

    if (-not (Test-Path -Path $FilePath)) {
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($ExpectedSha256)) {
        return $false
    }

    $actual = (Get-FileHash -Path $FilePath -Algorithm SHA256).Hash
    return ($actual -eq $ExpectedSha256)
}

function Test-DanewSignature {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    if (-not (Test-Path -Path $FilePath)) {
        return $false
    }

    try {
        $sig = Get-AuthenticodeSignature -FilePath $FilePath
        return $sig.Status -eq 'Valid'
    }
    catch {
        return $false
    }
}

function Get-DanewSignerVendor {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    if (-not (Test-Path -Path $FilePath)) {
        return ''
    }

    try {
        $sig = Get-AuthenticodeSignature -FilePath $FilePath
        if (-not $sig.SignerCertificate) {
            return ''
        }

        $subject = $sig.SignerCertificate.Subject
        if ($subject -match 'CN=([^,]+)') {
            return $Matches[1].Trim()
        }

        return $subject
    }
    catch {
        return ''
    }
}

function Test-DanewVendorTrust {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Vendor,
        [Parameter(Mandatory = $true)]
        [object]$SecurityPolicy
    )

    if ([string]::IsNullOrWhiteSpace($Vendor)) {
        return $false
    }

    foreach ($b in $SecurityPolicy.blocked_vendors) {
        if ($Vendor -match [regex]::Escape($b)) {
            return $false
        }
    }

    foreach ($t in $SecurityPolicy.trusted_vendors) {
        if ($Vendor -match [regex]::Escape($t)) {
            return $true
        }
    }

    return $false
}

function Find-DanewToolBinaryPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputPath,
        [Parameter(Mandatory = $true)]
        [string]$ToolName
    )

    $candidates = @($ToolName)
    if ($ToolName -notmatch '\.') {
        $candidates += "$ToolName.exe"
    }

    foreach ($c in $candidates) {
        $found = Get-ChildItem -Path $InputPath -Recurse -File -Filter $c -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) {
            return $found.FullName
        }
    }

    return ''
}

function Invoke-DanewSecurityValidation {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InputPath,
        [Parameter(Mandatory = $true)]
        [object]$CatalogContext
    )

    $policy = $CatalogContext.SecurityPolicy
    $violations = @()
    $checked = 0
    $passed = 0

    foreach ($tool in $CatalogContext.ToolsCatalog.items) {
        $filePath = Find-DanewToolBinaryPath -InputPath $InputPath -ToolName $tool.name
        if ([string]::IsNullOrWhiteSpace($filePath)) {
            continue
        }

        $checked += 1
        $toolOk = $true

        $mustCheckSig = $false
        if ($policy.require_signature_for_critical -and $tool.priority -eq 'critical') {
            $mustCheckSig = $true
        }
        if ($policy.require_signature_for_portable -and $tool.portable) {
            $mustCheckSig = $true
        }
        if ($tool.signature_required) {
            $mustCheckSig = $true
        }

        if ($mustCheckSig) {
            $sigOk = Test-DanewSignature -FilePath $filePath
            if (-not $sigOk) {
                $toolOk = $false
                $violations += [pscustomobject]@{
                    tool = $tool.name
                    file = $filePath
                    type = 'signature'
                    severity = if ($policy.strict_mode) { 'critical' } else { 'recommended' }
                    message = 'Authenticode signature invalid or missing'
                }
            }
        }

        $requiresHash = $false
        if ($policy.require_sha256_for_downloaded -and -not [string]::IsNullOrWhiteSpace($tool.download_url)) {
            $requiresHash = $true
        }
        if ($policy.strict_mode -and -not [string]::IsNullOrWhiteSpace($tool.download_url)) {
            $requiresHash = $true
        }

        if ($requiresHash) {
            $hashOk = Test-DanewSha256 -FilePath $filePath -ExpectedSha256 $tool.sha256
            if (-not $hashOk) {
                $toolOk = $false
                $violations += [pscustomobject]@{
                    tool = $tool.name
                    file = $filePath
                    type = 'sha256'
                    severity = if ($policy.strict_mode) { 'critical' } else { 'recommended' }
                    message = 'SHA256 mismatch or expected hash is missing'
                }
            }
        }

        $vendor = Get-DanewSignerVendor -FilePath $filePath
        if ([string]::IsNullOrWhiteSpace($vendor)) {
            $vendor = [string]$tool.vendor
        }

        $vendorOk = Test-DanewVendorTrust -Vendor $vendor -SecurityPolicy $policy
        if (-not $vendorOk) {
            $toolOk = $false
            $violations += [pscustomobject]@{
                tool = $tool.name
                file = $filePath
                type = 'vendor'
                severity = if ($policy.strict_mode) { 'critical' } else { 'optional' }
                message = "Vendor not trusted by policy: $vendor"
            }
        }

        if ($toolOk) {
            $passed += 1
        }
    }

    return [pscustomobject]@{
        strict_mode = [bool]$policy.strict_mode
        checked = $checked
        passed = $passed
        failed = ($checked - $passed)
        violations = $violations
    }
}
