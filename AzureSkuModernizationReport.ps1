[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string[]]$SubscriptionIds,

    [Parameter(Mandatory = $false)]
    [string]$TenantId,

    [Parameter(Mandatory = $false)]
    [switch]$UseDeviceAuthentication,

    [Parameter(Mandatory = $false)]
    [string[]]$Regions,

    [Parameter(Mandatory = $false)]
    [string]$OutputRoot = ".\\out",

    [Parameter(Mandatory = $false)]
    [int]$TopCandidates = 3,

    [Parameter(Mandatory = $false)]
    [double]$MaxRecommendedVcpuIncreaseRatio = 1.5,

    [Parameter(Mandatory = $false)]
    [double]$MaxRecommendedMemoryIncreaseRatio = 1.5,

    [Parameter(Mandatory = $false)]
    [double]$MaxRecommendedCostIncreasePercent = 20,

    [Parameter(Mandatory = $false)]
    [double]$MinRecommendedPerfRatio = 0.95,

    [Parameter(Mandatory = $false)]
    [double]$EquivalentVcpuTolerancePercent = 15,

    [Parameter(Mandatory = $false)]
    [double]$EquivalentMemoryTolerancePercent = 20,

    [Parameter(Mandatory = $false)]
    [switch]$AllowArchitectureChange,

    [Parameter(Mandatory = $false)]
    [switch]$SkipAdvisor,

    [Parameter(Mandatory = $false)]
    [switch]$SkipRetailApi,

    [Parameter(Mandatory = $false)]
    [int]$RetailExpectedPages = 180,

    [Parameter(Mandatory = $false)]
    [int]$RetailMaxRetries = 5,

    [Parameter(Mandatory = $false)]
    [int]$RetailRetryBaseDelaySec = 1,

    [Parameter(Mandatory = $false)]
    [int]$RetailRetryMaxDelaySec = 30,

    [Parameter(Mandatory = $false)]
    [int]$RetailMaxParallelRequests = 6,

    [Parameter(Mandatory = $false)]
    [int]$RetailApiTimeoutSec = 15,

    # ISO currency code passed to the Azure Retail Prices API (e.g. USD, EUR, GBP). The API defaults to
    # USD when omitted; set this so the reported delta is in the currency the report should display.
    [Parameter(Mandatory = $false)]
    [string]$Currency = "USD",

    [Parameter(Mandatory = $false)]
    [bool]$DetailedRunLog = $true,

    [Parameter(Mandatory = $false)]
    [bool]$UseOfficialRetirementList = $true,

    [Parameter(Mandatory = $false)]
    [bool]$UsePortalRetirementSource = $true,

    # Advisor recommendation type IDs that are operational/monitoring lifecycle signals
    # (e.g. Dependency Agent / VM Insights Map retirement) and must NEVER be promoted to a
    # compute SKU retirement signal. Parametric so it can be extended without code changes.
    [Parameter(Mandatory = $false)]
    [string[]]$AdvisorRetirementTypeIdBlocklist = @(
        'f49d7356-7251-4e15-a577-a3398527f3fd', # Migrate from Dependency Agent and VM Insights Map (Azure Monitor feature EOL, not SKU retirement)
        'beae2503-c504-47b1-8ca4-d0e708559af9'  # Dependency Agent / VM Insights Map lifecycle signal observed without stable recommendation text
    ),

    # Fallback text match (Option B) for Advisor recommendations whose type ID is not in the
    # blocklist but whose text clearly indicates an agent/monitoring migration, not SKU retirement.
    [Parameter(Mandatory = $false)]
    [string]$AdvisorRetirementNameBlockPattern = '(?i)dependency agent|vm insights|log analytics agent|microsoft monitoring agent|azure monitor agent',

    # LIVE-ONLY MODE: Retirement data must come from live sources only.
    # If $RequireLiveRetirementSource=true and both live streams fail, the script throws (no fabricated data).
    # If $RequireLiveRetirementSource=false and live sources fail, the report shows only available data.
    [Parameter(Mandatory = $false)]
    [bool]$RequireLiveRetirementSource = $false,

    [Parameter(Mandatory = $false)]
    [bool]$UseResourceSkusRestApi = $true,

    [Parameter(Mandatory = $false)]
    [string]$ResourceSkusApiVersion = "2026-03-02",

    [Parameter(Mandatory = $false)]
    [bool]$IncludeExtendedLocationsInSkuApi = $true,

    [Parameter(Mandatory = $false)]
    [bool]$UsePersistentCache = $true,

    [Parameter(Mandatory = $false)]
    [string]$CacheRoot,

    [Parameter(Mandatory = $false)]
    [int]$SkuCacheTtlHours = 168,

    [Parameter(Mandatory = $false)]
    [int]$RetailCacheTtlHours = 24,

    [Parameter(Mandatory = $false)]
    [switch]$ForceRefreshCache
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:RetailLastPageCount = 0
$script:RetailLastDownloadComplete = $true
$script:CommitmentLastDownloadComplete = $true
$script:EffectiveTenantId = $null
$script:ApiCallLog = @()
$script:ApiLogJsonPath = $null
$script:ApiLogCsvPath = $null
$script:RunLogPath = $null

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $false)][ValidateSet("INFO", "WARN", "ERROR", "DEBUG")][string]$Level = "INFO"
    )

    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts][$Level] $Message"

    # Keep console concise: suppress detailed API call traces and print only message text.
    $isDetailedTrace = $Message.StartsWith("API_CALL|", [System.StringComparison]::OrdinalIgnoreCase)
    if (-not $isDetailedTrace) {
        Write-Host $Message
    }

    if (-not [string]::IsNullOrWhiteSpace($script:RunLogPath)) {
        try {
            Add-Content -LiteralPath $script:RunLogPath -Value $line -Encoding UTF8
        }
        catch {
            # Keep logging to console even if file append fails.
        }
    }
}

function Set-MainProgress {
    param(
        [Parameter(Mandatory = $true)][int]$Stage,
        [Parameter(Mandatory = $true)][int]$TotalStages,
        [Parameter(Mandatory = $true)][string]$Activity,
        [Parameter(Mandatory = $true)][string]$Status
    )

    $pct = [int][math]::Round(($Stage / $TotalStages) * 100, 0)
    $pct = [math]::Min(100, [math]::Max(0, $pct))

    Write-Progress -Id 1 -Activity $Activity -Status $Status -PercentComplete $pct
}

function Add-ApiCallLog {
    param(
        [Parameter(Mandatory = $true)][string]$Api,
        [Parameter(Mandatory = $true)][string]$Provider,
        [Parameter(Mandatory = $false)][string]$TenantId,
        [Parameter(Mandatory = $false)][string]$SubscriptionId,
        [Parameter(Mandatory = $false)][string]$Request,
        [Parameter(Mandatory = $true)][datetime]$StartedAt,
        [Parameter(Mandatory = $true)][datetime]$EndedAt,
        [Parameter(Mandatory = $true)][bool]$Success,
        [Parameter(Mandatory = $false)][string]$ErrorMessage,
        [Parameter(Mandatory = $false)][hashtable]$Meta
    )

    $durationMs = [int][math]::Round(($EndedAt - $StartedAt).TotalMilliseconds, 0)
    $script:ApiCallLog += [pscustomobject]@{
        Timestamp      = $StartedAt.ToString("o")
        Api            = $Api
        Provider       = $Provider
        TenantId       = if ($TenantId) { $TenantId } else { "N/A" }
        SubscriptionId = if ($SubscriptionId) { $SubscriptionId } else { "N/A" }
        Request        = if ($Request) { $Request } else { "N/A" }
        DurationMs     = $durationMs
        Success        = $Success
        ErrorMessage   = if ($ErrorMessage) { $ErrorMessage } else { "N/A" }
        Meta           = if ($Meta) { $Meta } else { @{} }
    }

    if ($DetailedRunLog) {
        $status = if ($Success) { "SUCCESS" } else { "FAILED" }
        $metaText = "N/A"
        if ($Meta -and $Meta.Count -gt 0) {
            try {
                $metaText = ($Meta | ConvertTo-Json -Depth 10 -Compress)
            }
            catch {
                $metaText = "<meta-serialization-error>"
            }
        }

        $requestText = if ($Request) { $Request } else { "N/A" }
        $tenantText = if ($TenantId) { $TenantId } else { "N/A" }
        $subscriptionText = if ($SubscriptionId) { $SubscriptionId } else { "N/A" }
        $errorText = if ($ErrorMessage) { $ErrorMessage } else { "N/A" }

        $logLevel = "INFO"
        if (-not $Success) {
            $logLevel = "WARN"
        }

        Write-Log ("API_CALL|provider=$Provider|api=$Api|status=$status|durationMs=$durationMs|tenant=$tenantText|subscription=$subscriptionText|request=$requestText|meta=$metaText|error=$errorText") $logLevel
    }
}

function Save-ApiCallLogs {
    param(
        [Parameter(Mandatory = $true)][string]$JsonPath,
        [Parameter(Mandatory = $true)][string]$CsvPath
    )

    $entries = @($script:ApiCallLog)
    if (@($entries).Count -eq 0) {
        $entries = @([pscustomobject]@{
            Timestamp      = (Get-Date).ToString("o")
            Api            = "N/A"
            Provider       = "N/A"
            TenantId       = if ($script:EffectiveTenantId) { $script:EffectiveTenantId } else { "N/A" }
            SubscriptionId = "N/A"
            Request        = "N/A"
            DurationMs     = 0
            Success        = $true
            ErrorMessage   = "N/A"
            Meta           = @{}
        })
    }

    $entries | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $JsonPath -Encoding UTF8

    $entries |
        Select-Object Timestamp, Api, Provider, TenantId, SubscriptionId, Request, DurationMs, Success, ErrorMessage,
            @{ Name = "MetaJson"; Expression = { $_.Meta | ConvertTo-Json -Depth 6 -Compress } } |
        Export-Csv -LiteralPath $CsvPath -NoTypeInformation -Encoding UTF8
}

function Get-RetailExpectedPagesFromHistory {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][int]$Fallback
    )

    $statsPath = Join-Path $Root "run_stats.json"
    if (-not (Test-Path -LiteralPath $statsPath)) {
        return $Fallback
    }

    try {
        $stats = Get-Content -LiteralPath $statsPath -Raw | ConvertFrom-Json
        if ($stats -and $stats.RetailLastPageCount -and [int]$stats.RetailLastPageCount -gt 0) {
            return [int][math]::Max($Fallback, [int][math]::Ceiling(([int]$stats.RetailLastPageCount) * 1.10))
        }
    }
    catch {
        Write-Log "run_stats.json history not readable, using Retail ETA fallback" "WARN"
    }

    return $Fallback
}

function Save-RunStats {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][int]$RetailPageCount
    )

    $statsPath = Join-Path $Root "run_stats.json"
    $effectiveRetailPageCount = $RetailPageCount
    if ($effectiveRetailPageCount -le 0 -and (Test-Path -LiteralPath $statsPath)) {
        try {
            $existing = Get-Content -LiteralPath $statsPath -Raw | ConvertFrom-Json
            if ($existing -and $existing.RetailLastPageCount -and [int]$existing.RetailLastPageCount -gt 0) {
                $effectiveRetailPageCount = [int]$existing.RetailLastPageCount
            }
        }
        catch {
            # ignore and keep current value
        }
    }

    $obj = [pscustomobject]@{
        UpdatedAt           = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        RetailLastPageCount = $effectiveRetailPageCount
    }

    $obj | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statsPath -Encoding UTF8
}

function Ensure-Module {
    param([Parameter(Mandatory = $true)][string]$Name)

    if (-not (Get-Module -ListAvailable -Name $Name)) {
        throw "Required module not found: $Name. Install with: Install-Module $Name -Scope CurrentUser"
    }

    Import-Module $Name -ErrorAction Stop | Out-Null
}

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Get-StringSha256 {
    param([Parameter(Mandatory = $true)][string]$InputText)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($InputText)
        $hashBytes = $sha.ComputeHash($bytes)
        return ([System.BitConverter]::ToString($hashBytes) -replace "-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function New-CacheFilePath {
    param(
        [Parameter(Mandatory = $true)][string]$CacheDir,
        [Parameter(Mandatory = $true)][string]$Prefix,
        [Parameter(Mandatory = $true)]$Context
    )

    $ctxJson = ($Context | ConvertTo-Json -Depth 8 -Compress)
    $hash = Get-StringSha256 -InputText $ctxJson
    return (Join-Path $CacheDir ("{0}_{1}.json" -f $Prefix, $hash))
}

function Test-CacheFileFresh {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int]$TtlHours
    )

    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    if ($TtlHours -le 0) { return $false }

    $lastWrite = (Get-Item -LiteralPath $Path).LastWriteTimeUtc
    $ageHours = ((Get-Date).ToUniversalTime() - $lastWrite).TotalHours
    return ($ageHours -le $TtlHours)
}

function Save-CacheEnvelope {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$CacheKind,
        [Parameter(Mandatory = $true)]$Context,
        [Parameter(Mandatory = $true)]$Data
    )

    $envelope = [pscustomobject]@{
        CacheVersion = 1
        CacheKind    = $CacheKind
        CachedAtUtc  = (Get-Date).ToUniversalTime().ToString("o")
        Context      = $Context
        Data         = $Data
    }

    $envelope | ConvertTo-Json -Depth 25 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Read-CacheEnvelope {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
    }
    catch {
        Write-Log "Cache not readable ($Path): $($_.Exception.Message)" "WARN"
        return $null
    }
}

function ConvertTo-NormalizedCatalogEntries {
    param([Parameter(Mandatory = $true)][object[]]$Catalog)

    $normalized = New-Object 'System.Collections.Generic.List[object]'
    foreach ($c in @($Catalog)) {
        if (-not $c) { continue }

        $cap = @{}
        if ($c.PSObject.Properties.Match("Cap").Count -gt 0 -and $c.Cap) {
            if ($c.Cap -is [hashtable]) {
                $cap = $c.Cap
            }
            else {
                foreach ($p in $c.Cap.PSObject.Properties) {
                    $cap[[string]$p.Name] = [string]$p.Value
                }
            }
        }

        $locations = @()
        if ($c.PSObject.Properties.Match("Locations").Count -gt 0 -and $c.Locations) {
            $locations = @($c.Locations | ForEach-Object { Normalize-Location ([string]$_) } | Where-Object { $_ })
        }

        $normalized.Add([pscustomobject]@{
            Name         = if ($c.PSObject.Properties.Match("Name").Count -gt 0) { [string]$c.Name } else { "" }
            Family       = if ($c.PSObject.Properties.Match("Family").Count -gt 0) { [string]$c.Family } else { "" }
            Tier         = if ($c.PSObject.Properties.Match("Tier").Count -gt 0) { [string]$c.Tier } else { "" }
            Size         = if ($c.PSObject.Properties.Match("Size").Count -gt 0) { [string]$c.Size } else { "" }
            Locations    = $locations
            Cap          = $cap
            Restrictions = if ($c.PSObject.Properties.Match("Restrictions").Count -gt 0) { $c.Restrictions } else { $null }
            LocationInfo = if ($c.PSObject.Properties.Match("LocationInfo").Count -gt 0) { $c.LocationInfo } else { $null }
            ApiVersions  = if ($c.PSObject.Properties.Match("ApiVersions").Count -gt 0) { $c.ApiVersions } else { $null }
        })
    }

    return $normalized.ToArray()
}

function Convert-PriceMapToCacheEntries {
    param([Parameter(Mandatory = $true)][hashtable]$PriceMap)

    $entries = New-Object 'System.Collections.Generic.List[object]'
    foreach ($key in @($PriceMap.Keys)) {
        $p = $PriceMap[$key]
        if (-not $p) { continue }

        $entries.Add([pscustomobject]@{
            Key                = [string]$key
            ArmSkuName         = [string]$p.ArmSkuName
            Region             = [string]$p.Region
            CurrencyCode       = [string]$p.CurrencyCode
            UnitPrice          = [double]$p.UnitPrice
            LinuxUnitPrice     = if ($p.PSObject.Properties.Match('LinuxUnitPrice').Count -gt 0 -and $null -ne $p.LinuxUnitPrice -and ([string]$p.LinuxUnitPrice).Trim() -ne '') { [double]$p.LinuxUnitPrice } else { $null }
            WindowsUnitPrice   = if ($p.PSObject.Properties.Match('WindowsUnitPrice').Count -gt 0 -and $null -ne $p.WindowsUnitPrice -and ([string]$p.WindowsUnitPrice).Trim() -ne '') { [double]$p.WindowsUnitPrice } else { $null }
            UnitOfMeasure      = [string]$p.UnitOfMeasure
            MeterName          = [string]$p.MeterName
            ProductName        = [string]$p.ProductName
            SkuName            = [string]$p.SkuName
            EffectiveStartDate = Format-NullableDate $p.EffectiveStartDate
        })
    }

    return $entries.ToArray()
}

function Convert-CacheEntriesToPriceMap {
    param([Parameter(Mandatory = $true)][object[]]$Entries)

    $priceMap = @{}
    foreach ($e in @($Entries)) {
        if (-not $e) { continue }

        $sku = if ($e.PSObject.Properties.Match("ArmSkuName").Count -gt 0) { [string]$e.ArmSkuName } else { "" }
        $region = if ($e.PSObject.Properties.Match("Region").Count -gt 0) { Normalize-Location ([string]$e.Region) } else { "" }
        if (-not $sku -or -not $region) { continue }

        $key = if ($e.PSObject.Properties.Match("Key").Count -gt 0 -and $e.Key) { [string]$e.Key } else { "{0}|{1}" -f $sku, $region }

        $priceMap[$key] = [pscustomobject]@{
            ArmSkuName         = $sku
            Region             = $region
            CurrencyCode       = if ($e.PSObject.Properties.Match("CurrencyCode").Count -gt 0) { [string]$e.CurrencyCode } else { "" }
            UnitPrice          = if ($e.PSObject.Properties.Match("UnitPrice").Count -gt 0) { [double]$e.UnitPrice } else { 0.0 }
            LinuxUnitPrice     = if ($e.PSObject.Properties.Match("LinuxUnitPrice").Count -gt 0 -and $null -ne $e.LinuxUnitPrice -and ([string]$e.LinuxUnitPrice).Trim() -ne '') { [double]$e.LinuxUnitPrice } else { $null }
            WindowsUnitPrice   = if ($e.PSObject.Properties.Match("WindowsUnitPrice").Count -gt 0 -and $null -ne $e.WindowsUnitPrice -and ([string]$e.WindowsUnitPrice).Trim() -ne '') { [double]$e.WindowsUnitPrice } else { $null }
            UnitOfMeasure      = if ($e.PSObject.Properties.Match("UnitOfMeasure").Count -gt 0) { [string]$e.UnitOfMeasure } else { "" }
            MeterName          = if ($e.PSObject.Properties.Match("MeterName").Count -gt 0) { [string]$e.MeterName } else { "" }
            ProductName        = if ($e.PSObject.Properties.Match("ProductName").Count -gt 0) { [string]$e.ProductName } else { "" }
            SkuName            = if ($e.PSObject.Properties.Match("SkuName").Count -gt 0) { [string]$e.SkuName } else { "" }
            EffectiveStartDate = if ($e.PSObject.Properties.Match("EffectiveStartDate").Count -gt 0) { Format-NullableDate $e.EffectiveStartDate } else { "N/A" }
        }
    }

    return $priceMap
}

function Convert-CommitmentMapToCacheEntries {
    param([Parameter(Mandatory = $true)][hashtable]$CommitmentMap)

    $entries = New-Object 'System.Collections.Generic.List[object]'
    foreach ($key in @($CommitmentMap.Keys)) {
        $c = $CommitmentMap[$key]
        if (-not $c) { continue }

        $entries.Add([pscustomobject]@{
            Key                                = [string]$key
            ArmSkuName                         = [string]$c.ArmSkuName
            Region                             = [string]$c.Region
            SupportsReservedInstance           = [bool]$c.SupportsReservedInstance
            SupportsSavingsPlan                = [bool]$c.SupportsSavingsPlan
            ReservedInstanceFirstSeenDate      = Format-NullableDate $c.ReservedInstanceFirstSeenDate
            SavingsPlanFirstSeenDate           = Format-NullableDate $c.SavingsPlanFirstSeenDate
        })
    }

    return $entries.ToArray()
}

function Convert-CacheEntriesToCommitmentMap {
    param([Parameter(Mandatory = $true)][object[]]$Entries)

    $map = @{}
    foreach ($e in @($Entries)) {
        if (-not $e) { continue }

        $sku = if ($e.PSObject.Properties.Match("ArmSkuName").Count -gt 0) { [string]$e.ArmSkuName } else { "" }
        $region = if ($e.PSObject.Properties.Match("Region").Count -gt 0) { Normalize-Location ([string]$e.Region) } else { "" }
        if (-not $sku -or -not $region) { continue }

        $key = if ($e.PSObject.Properties.Match("Key").Count -gt 0 -and $e.Key) { [string]$e.Key } else { "{0}|{1}" -f $sku, $region }

        $map[$key] = [pscustomobject]@{
            ArmSkuName                    = $sku
            Region                        = $region
            SupportsReservedInstance      = if ($e.PSObject.Properties.Match("SupportsReservedInstance").Count -gt 0) { [bool]$e.SupportsReservedInstance } else { $false }
            SupportsSavingsPlan           = if ($e.PSObject.Properties.Match("SupportsSavingsPlan").Count -gt 0) { [bool]$e.SupportsSavingsPlan } else { $false }
            ReservedInstanceFirstSeenDate = if ($e.PSObject.Properties.Match("ReservedInstanceFirstSeenDate").Count -gt 0) { Format-NullableDate $e.ReservedInstanceFirstSeenDate } else { "N/A" }
            SavingsPlanFirstSeenDate      = if ($e.PSObject.Properties.Match("SavingsPlanFirstSeenDate").Count -gt 0) { Format-NullableDate $e.SavingsPlanFirstSeenDate } else { "N/A" }
        }
    }

    return $map
}

function Get-EarlierDateString {
    param(
        [Parameter(Mandatory = $false)][string]$Current,
        [Parameter(Mandatory = $false)][string]$Candidate
    )

    if ([string]::IsNullOrWhiteSpace($Current) -or $Current -eq "N/A") { return (Format-NullableDate $Candidate) }
    if ([string]::IsNullOrWhiteSpace($Candidate) -or $Candidate -eq "N/A") { return (Format-NullableDate $Current) }

    $d1 = [datetime]::MinValue
    $d2 = [datetime]::MinValue
    if (-not [datetime]::TryParse($Current, [ref]$d1)) { return (Format-NullableDate $Candidate) }
    if (-not [datetime]::TryParse($Candidate, [ref]$d2)) { return (Format-NullableDate $Current) }

    if ($d1 -le $d2) { return $d1.ToString("yyyy-MM-dd") }
    return $d2.ToString("yyyy-MM-dd")
}

function Get-HttpStatusCodeFromError {
    param([Parameter(Mandatory = $true)]$ErrorRecord)

    try {
        if ($ErrorRecord -and $ErrorRecord.Exception -and $ErrorRecord.Exception.Response) {
            $resp = $ErrorRecord.Exception.Response
            if ($resp.StatusCode) {
                return [int]$resp.StatusCode
            }
        }
    }
    catch {
        # ignore
    }

    return 0
}

function Test-IsExcludedRetailVmPriceRecord {
    param([Parameter(Mandatory = $true)]$Item)

    $fields = @(
        [string]$Item.productName,
        [string]$Item.skuName,
        [string]$Item.meterName
    )

    foreach ($f in $fields) {
        if ([string]::IsNullOrWhiteSpace($f)) { continue }
        if ($f -match '(?i)\bspot\b|\blow[\s-]?priority\b') { return $true }
    }

    return $false
}

function Test-IsPayGPriceEntry {
    param([Parameter(Mandatory = $false)]$PriceEntry)

    if (-not $PriceEntry) { return $false }

    $fields = @()
    if ($PriceEntry.PSObject.Properties.Match("ProductName").Count -gt 0) { $fields += [string]$PriceEntry.ProductName }
    if ($PriceEntry.PSObject.Properties.Match("SkuName").Count -gt 0) { $fields += [string]$PriceEntry.SkuName }
    if ($PriceEntry.PSObject.Properties.Match("MeterName").Count -gt 0) { $fields += [string]$PriceEntry.MeterName }

    foreach ($f in $fields) {
        if ([string]::IsNullOrWhiteSpace($f)) { continue }
        if ($f -match '(?i)\bspot\b|\blow[\s-]?priority\b') { return $false }
    }

    $unit = 0.0
    if ($PriceEntry.PSObject.Properties.Match("UnitPrice").Count -gt 0) { $unit = [double]$PriceEntry.UnitPrice }
    if ($unit -le 0) { return $false }

    return $true
}


function Resolve-RetailPriceForOs {
    <#
    .SYNOPSIS
    Selects the OS-appropriate unit price from a price entry and reports HOW it was chosen.
    .DESCRIPTION
    For the same armSkuName the Retail Prices API returns multiple meters (Linux and Windows); the Windows
    meter is dearer. Keeping only the lowest price per SKU|Region would price every VM as Linux and
    understate the cost of Windows VMs. This selects the meter matching the VM's OS (from inventory OsType),
    falling back to the OS-agnostic lowest price when the specific OS meter is unavailable.
    Returns an object carrying the chosen Price, the Basis used (Windows/Linux/OsAgnosticFallback/NoPrice)
    and whether Windows/Linux meters were available. The Basis makes silent Linux-pricing of a Windows VM
    detectable downstream (see the pricing invariant in Assert-ReportConsistency).
    #>
    param(
        [Parameter(Mandatory = $false)]$PriceEntry,
        [Parameter(Mandatory = $false)][string]$OsType = ""
    )

    if (-not $PriceEntry) {
        return [pscustomobject]@{ Price = 0.0; Basis = 'NoPrice'; WindowsAvailable = $false; LinuxAvailable = $false }
    }

    $fallback = if ($PriceEntry.PSObject.Properties.Match('UnitPrice').Count -gt 0) { [double]$PriceEntry.UnitPrice } else { 0.0 }

    $winVal = $null
    if ($PriceEntry.PSObject.Properties.Match('WindowsUnitPrice').Count -gt 0 -and $null -ne $PriceEntry.WindowsUnitPrice -and ([string]$PriceEntry.WindowsUnitPrice).Trim() -ne '' -and [double]$PriceEntry.WindowsUnitPrice -gt 0) {
        $winVal = [double]$PriceEntry.WindowsUnitPrice
    }
    $linVal = $null
    if ($PriceEntry.PSObject.Properties.Match('LinuxUnitPrice').Count -gt 0 -and $null -ne $PriceEntry.LinuxUnitPrice -and ([string]$PriceEntry.LinuxUnitPrice).Trim() -ne '' -and [double]$PriceEntry.LinuxUnitPrice -gt 0) {
        $linVal = [double]$PriceEntry.LinuxUnitPrice
    }

    $winAvailable = ($null -ne $winVal)
    $linAvailable = ($null -ne $linVal)
    $osIsWindows = ($OsType -match '(?i)windows')

    if ($osIsWindows) {
        if ($winAvailable) {
            return [pscustomobject]@{ Price = $winVal; Basis = 'Windows'; WindowsAvailable = $winAvailable; LinuxAvailable = $linAvailable }
        }
        # No Windows meter in the data for this SKU|Region: legitimate fallback (NOT a silent misroute).
        return [pscustomobject]@{ Price = $fallback; Basis = 'OsAgnosticFallback'; WindowsAvailable = $winAvailable; LinuxAvailable = $linAvailable }
    }

    if ($linAvailable) {
        return [pscustomobject]@{ Price = $linVal; Basis = 'Linux'; WindowsAvailable = $winAvailable; LinuxAvailable = $linAvailable }
    }
    return [pscustomobject]@{ Price = $fallback; Basis = 'OsAgnosticFallback'; WindowsAvailable = $winAvailable; LinuxAvailable = $linAvailable }
}

function Get-RetailUnitPriceForOs {
    <#
    .SYNOPSIS
    Returns the OS-appropriate unit price from a price entry (Windows vs Linux).
    .DESCRIPTION
    Thin wrapper over Resolve-RetailPriceForOs that returns only the numeric price, for callers that do
    not need the selection basis.
    #>
    param(
        [Parameter(Mandatory = $false)]$PriceEntry,
        [Parameter(Mandatory = $false)][string]$OsType = ""
    )

    return (Resolve-RetailPriceForOs -PriceEntry $PriceEntry -OsType $OsType).Price
}


function Get-ComputeSkuCatalogCached {
    param(
        [Parameter(Mandatory = $false)][string[]]$RegionsFilter,
        [Parameter(Mandatory = $false)][string]$SubscriptionIdForRest,
        [Parameter(Mandatory = $false)][bool]$UseRestApi = $true,
        [Parameter(Mandatory = $false)][string]$ApiVersion = "2026-03-02",
        [Parameter(Mandatory = $false)][bool]$IncludeExtendedLocations = $true,
        [Parameter(Mandatory = $true)][string]$CacheDir,
        [Parameter(Mandatory = $true)][bool]$UseCache,
        [Parameter(Mandatory = $true)][int]$TtlHours,
        [Parameter(Mandatory = $true)][bool]$ForceRefresh,
        [Parameter(Mandatory = $false)][string]$TenantId
    )

    $context = @{
        scope                 = "compute-sku"
        tenantId              = if ($TenantId) { $TenantId } else { "N/A" }
        subscriptionIdForRest = if ($SubscriptionIdForRest) { $SubscriptionIdForRest } else { "N/A" }
        regions               = @($RegionsFilter | ForEach-Object { Normalize-Location ([string]$_) } | Sort-Object -Unique)
        useRestApi            = $UseRestApi
        apiVersion            = $ApiVersion
        includeExtended       = $IncludeExtendedLocations
    }
    $cachePath = New-CacheFilePath -CacheDir $CacheDir -Prefix "compute_sku" -Context $context

    if ($UseCache -and (-not $ForceRefresh) -and (Test-CacheFileFresh -Path $cachePath -TtlHours $TtlHours)) {
        $cacheStart = Get-Date
        $envelope = Read-CacheEnvelope -Path $cachePath
        if ($envelope -and $envelope.Data) {
            $catalog = ConvertTo-NormalizedCatalogEntries -Catalog @($envelope.Data)
            if (@($catalog).Count -gt 0) {
                Add-ApiCallLog -Api "LocalCacheRead" -Provider "LocalCache" -TenantId $script:EffectiveTenantId -SubscriptionId $SubscriptionIdForRest -Request $cachePath -StartedAt $cacheStart -EndedAt (Get-Date) -Success $true -Meta @{ CacheKind = "ComputeSku"; CacheHit = $true; Count = @($catalog).Count; TtlHours = $TtlHours }
                Write-Log "SKU catalog from local cache: $cachePath"
                return $catalog
            }
        }
        Add-ApiCallLog -Api "LocalCacheRead" -Provider "LocalCache" -TenantId $script:EffectiveTenantId -SubscriptionId $SubscriptionIdForRest -Request $cachePath -StartedAt $cacheStart -EndedAt (Get-Date) -Success $false -ErrorMessage "Empty/invalid cache"
    }

    $catalogFresh = Get-ComputeSkuCatalog -RegionsFilter $RegionsFilter -SubscriptionIdForRest $SubscriptionIdForRest -UseRestApi $UseRestApi -ApiVersion $ApiVersion -IncludeExtendedLocations:$IncludeExtendedLocations
    $catalogFresh = ConvertTo-NormalizedCatalogEntries -Catalog @($catalogFresh)

    if ($UseCache -and @($catalogFresh).Count -gt 0) {
        $cacheWriteStart = Get-Date
        try {
            Save-CacheEnvelope -Path $cachePath -CacheKind "ComputeSku" -Context $context -Data $catalogFresh
            Add-ApiCallLog -Api "LocalCacheWrite" -Provider "LocalCache" -TenantId $script:EffectiveTenantId -SubscriptionId $SubscriptionIdForRest -Request $cachePath -StartedAt $cacheWriteStart -EndedAt (Get-Date) -Success $true -Meta @{ CacheKind = "ComputeSku"; Count = @($catalogFresh).Count }
        }
        catch {
            Add-ApiCallLog -Api "LocalCacheWrite" -Provider "LocalCache" -TenantId $script:EffectiveTenantId -SubscriptionId $SubscriptionIdForRest -Request $cachePath -StartedAt $cacheWriteStart -EndedAt (Get-Date) -Success $false -ErrorMessage $_.Exception.Message
            Write-Log "Unable to save SKU cache: $($_.Exception.Message)" "WARN"
        }
    }

    return $catalogFresh
}

function Get-RetailPricesForVirtualMachinesCached {
    param(
        [Parameter(Mandatory = $false)][string[]]$RegionsFilter,
        [Parameter(Mandatory = $false)][int]$ExpectedPages = 180,
        [Parameter(Mandatory = $false)][int]$MaxRetries = 5,
        [Parameter(Mandatory = $false)][int]$RetryBaseDelaySec = 1,
        [Parameter(Mandatory = $false)][int]$RetryMaxDelaySec = 30,
        [Parameter(Mandatory = $false)][int]$MaxParallelRequests = 6,
        [Parameter(Mandatory = $false)][int]$TimeoutSec = 15,
        [Parameter(Mandatory = $false)][string]$Currency = "USD",
        [Parameter(Mandatory = $true)][string]$CacheDir,
        [Parameter(Mandatory = $true)][bool]$UseCache,
        [Parameter(Mandatory = $true)][int]$TtlHours,
        [Parameter(Mandatory = $true)][bool]$ForceRefresh,
        [Parameter(Mandatory = $false)][string]$TenantId
    )

    $context = [ordered]@{
        scope    = "retail-vm-prices"
        tenantId = if ($TenantId) { $TenantId } else { "N/A" }
        currency = if ($Currency) { $Currency } else { "USD" }
        regions  = @($RegionsFilter | ForEach-Object { Normalize-Location ([string]$_) } | Sort-Object -Unique)
    }
    # Adaptive validity floor: NextPageLink guarantees a complete per-region download, so a fresh download
    # is trusted on its own COMPLETENESS flag (below), not on a fixed key count. For deciding whether a
    # CACHED map is usable we only require it to be non-empty - this stops small/new regions (< the old
    # fixed 500 floor) from being perpetually rejected and re-downloaded.
    $minimumExpectedPriceKeys = 1
    $cachePath = New-CacheFilePath -CacheDir $CacheDir -Prefix "retail_vm_prices" -Context $context

    if ($UseCache -and (-not $ForceRefresh) -and (Test-CacheFileFresh -Path $cachePath -TtlHours $TtlHours)) {
        $cacheStart = Get-Date
        $envelope = Read-CacheEnvelope -Path $cachePath
        if ($envelope -and $envelope.Data) {
            $cachedMap = Convert-CacheEntriesToPriceMap -Entries @($envelope.Data)
            $cachedPriceCount = @($cachedMap.Keys).Count
            if ($cachedPriceCount -ge $minimumExpectedPriceKeys) {
                Add-ApiCallLog -Api "LocalCacheRead" -Provider "LocalCache" -TenantId $script:EffectiveTenantId -SubscriptionId "N/A" -Request $cachePath -StartedAt $cacheStart -EndedAt (Get-Date) -Success $true -Meta @{ CacheKind = "RetailPrices"; CacheHit = $true; Count = $cachedPriceCount; TtlHours = $TtlHours; Currency = $context.currency }
                Write-Log "Retail prices from local cache: $cachePath"
                return $cachedMap
            }
            Write-Log "Retail price cache ignored: empty cache for the requested region/currency scope. Refreshing from Azure Retail Prices API." "WARN"
        }
        Add-ApiCallLog -Api "LocalCacheRead" -Provider "LocalCache" -TenantId $script:EffectiveTenantId -SubscriptionId "N/A" -Request $cachePath -StartedAt $cacheStart -EndedAt (Get-Date) -Success $false -ErrorMessage "Empty/invalid cache"
    }

    if ($UseCache -and (-not $ForceRefresh)) {
        # Compatible-cache reuse: a cache whose region set is a SUPERSET of the requested regions (same
        # tenant + currency) can serve this run - we just filter its map down to the requested regions.
        # This lets a uksouth+italynorth cache satisfy a uksouth-only run without re-downloading.
        $requestedSet = @($context.regions | ForEach-Object { Normalize-Location ([string]$_) } | Sort-Object -Unique)
        $compatibleCaches = New-Object 'System.Collections.Generic.List[object]'
        foreach ($candidateCache in @(Get-ChildItem -LiteralPath $CacheDir -Filter 'retail_vm_prices_*.json' -File -ErrorAction SilentlyContinue)) {
            if ($candidateCache.FullName -eq (Resolve-Path -LiteralPath $cachePath -ErrorAction SilentlyContinue)) { continue }
            $candidateEnvelope = Read-CacheEnvelope -Path $candidateCache.FullName
            if (-not $candidateEnvelope -or -not $candidateEnvelope.Data -or -not $candidateEnvelope.Context) { continue }
            if ([string]$candidateEnvelope.Context.scope -ne 'retail-vm-prices') { continue }
            if ([string]$candidateEnvelope.Context.tenantId -ne [string]$context.tenantId) { continue }
            $candidateCurrency = if ($candidateEnvelope.Context.PSObject.Properties.Match('currency').Count -gt 0) { [string]$candidateEnvelope.Context.currency } else { '' }
            if ($candidateCurrency -ne [string]$context.currency) { continue }
            $candidateRegions = @($candidateEnvelope.Context.regions | ForEach-Object { Normalize-Location ([string]$_) } | Sort-Object -Unique)
            if ($requestedSet.Count -eq 0) { continue }
            $missingFromCandidate = @($requestedSet | Where-Object { $_ -notin $candidateRegions })
            if ($missingFromCandidate.Count -gt 0) { continue }
            $candidateMapFull = Convert-CacheEntriesToPriceMap -Entries @($candidateEnvelope.Data)
            $candidateMap = @{}
            foreach ($k in @($candidateMapFull.Keys)) {
                if ([string]$candidateMapFull[$k].Region -in $requestedSet) { $candidateMap[$k] = $candidateMapFull[$k] }
            }
            $candidateCount = @($candidateMap.Keys).Count
            if ($candidateCount -ge $minimumExpectedPriceKeys) {
                $compatibleCaches.Add([pscustomobject]@{ Path = $candidateCache.FullName; Count = $candidateCount; Map = $candidateMap }) | Out-Null
            }
        }

        $bestCompatibleCache = @($compatibleCaches.ToArray() | Sort-Object Count -Descending | Select-Object -First 1)
        if (@($bestCompatibleCache).Count -gt 0) {
            Add-ApiCallLog -Api "LocalCacheRead" -Provider "LocalCache" -TenantId $script:EffectiveTenantId -SubscriptionId "N/A" -Request $bestCompatibleCache[0].Path -StartedAt (Get-Date) -EndedAt (Get-Date) -Success $true -Meta @{ CacheKind = "RetailPrices"; CacheHit = $true; CompatibleFallback = $true; SupersetFiltered = $true; Count = $bestCompatibleCache[0].Count; TtlHours = $TtlHours; Currency = $context.currency }
            Write-Log "Retail prices from compatible (superset) local cache: $($bestCompatibleCache[0].Path)"
            return $bestCompatibleCache[0].Map
        }
    }

    try {
        $freshMap = Get-RetailPricesForVirtualMachines -RegionsFilter $RegionsFilter -ExpectedPages $ExpectedPages -MaxRetries $MaxRetries -RetryBaseDelaySec $RetryBaseDelaySec -RetryMaxDelaySec $RetryMaxDelaySec -MaxParallelRequests $MaxParallelRequests -TimeoutSec $TimeoutSec -Currency $Currency
    }
    catch {
        if ($UseCache -and (Test-Path -LiteralPath $cachePath)) {
            $staleEnvelope = Read-CacheEnvelope -Path $cachePath
            if ($staleEnvelope -and $staleEnvelope.Data) {
                $staleMap = Convert-CacheEntriesToPriceMap -Entries @($staleEnvelope.Data)
                $stalePriceCount = @($staleMap.Keys).Count
                if ($stalePriceCount -ge $minimumExpectedPriceKeys) {
                    Write-Log "Retail API unavailable/throttled. Using stale cache: $cachePath" "WARN"
                    Add-ApiCallLog -Api "LocalCacheRead" -Provider "LocalCache" -TenantId $script:EffectiveTenantId -SubscriptionId "N/A" -Request $cachePath -StartedAt (Get-Date) -EndedAt (Get-Date) -Success $true -Meta @{ CacheKind = "RetailPrices"; CacheHit = $true; StaleFallback = $true; Count = $stalePriceCount }
                    return $staleMap
                }
                Write-Log "Retail API unavailable/throttled and stale price cache is empty." "WARN"
            }
        }

        throw
    }

    $freshPriceCount = @($freshMap.Keys).Count
    # Save only a COMPLETE download (every region's cursor ran to the end) - never persist a partial map
    # from a region that aborted mid-cursor, which would silently understate coverage on later runs.
    if ($UseCache -and $script:RetailLastDownloadComplete -and $freshPriceCount -gt 0) {
        $cacheWriteStart = Get-Date
        try {
            $cacheEntries = Convert-PriceMapToCacheEntries -PriceMap $freshMap
            Save-CacheEnvelope -Path $cachePath -CacheKind "RetailPrices" -Context $context -Data $cacheEntries
            Add-ApiCallLog -Api "LocalCacheWrite" -Provider "LocalCache" -TenantId $script:EffectiveTenantId -SubscriptionId "N/A" -Request $cachePath -StartedAt $cacheWriteStart -EndedAt (Get-Date) -Success $true -Meta @{ CacheKind = "RetailPrices"; Count = $freshPriceCount; Currency = $context.currency }
        }
        catch {
            Add-ApiCallLog -Api "LocalCacheWrite" -Provider "LocalCache" -TenantId $script:EffectiveTenantId -SubscriptionId "N/A" -Request $cachePath -StartedAt $cacheWriteStart -EndedAt (Get-Date) -Success $false -ErrorMessage $_.Exception.Message
            Write-Log "Unable to save Retail cache: $($_.Exception.Message)" "WARN"
        }
    }
    elseif ($UseCache -and -not $script:RetailLastDownloadComplete) {
        Write-Log "Retail price download was incomplete (one or more regions aborted mid-cursor); not caching a partial map." "WARN"
    }

    return $freshMap
}

function Get-RetailCommitmentSignalsForVirtualMachines {
    param(
        [Parameter(Mandatory = $false)][string[]]$RegionsFilter,
        [Parameter(Mandatory = $false)][int]$ExpectedPages = 120,
        [Parameter(Mandatory = $false)][int]$MaxRetries = 5,
        [Parameter(Mandatory = $false)][int]$RetryBaseDelaySec = 1,
        [Parameter(Mandatory = $false)][int]$RetryMaxDelaySec = 30,
        [Parameter(Mandatory = $false)][int]$MaxParallelRequests = 6,
        [Parameter(Mandatory = $false)][int]$TimeoutSec = 15,
        [Parameter(Mandatory = $false)][string]$Currency = "USD"
    )

    # Uses the SAME reliable pattern as the consumption-price download: region-scoped OData filter paged to
    # completion with NextPageLink (NOT the old discovery-Count + deep $skip scheme, which stops returning
    # rows past a few thousand records). Parallelized across region/kind filters. RI is required; SP is
    # optional (some scopes reject the SavingsPlan filter with 400 and are treated as unavailable).
    $baseUrl = "https://prices.azure.com/api/retail/prices"
    $currencyQuery = if (-not [string]::IsNullOrWhiteSpace($Currency)) { "&currencyCode='$Currency'" } else { "" }

    $normalizedRegions = @()
    if ($RegionsFilter -and $RegionsFilter.Count -gt 0) {
        $normalizedRegions = @($RegionsFilter | ForEach-Object { Normalize-Location ([string]$_) } | Where-Object { $_ } | Sort-Object -Unique)
    }

    $kinds = @(
        [pscustomobject]@{ Kind = 'RI'; PriceType = 'Reservation'; Optional = $false },
        [pscustomobject]@{ Kind = 'SP'; PriceType = 'SavingsPlan'; Optional = $true }
    )

    $filterTargets = New-Object 'System.Collections.Generic.List[object]'
    foreach ($k in $kinds) {
        if ($normalizedRegions.Count -gt 0) {
            foreach ($region in $normalizedRegions) {
                $filterTargets.Add([pscustomobject]@{ Region = $region; Kind = $k.Kind; Optional = $k.Optional; Filter = "serviceName eq 'Virtual Machines' and priceType eq '$($k.PriceType)' and armRegionName eq '$region'" }) | Out-Null
            }
        }
        else {
            $filterTargets.Add([pscustomobject]@{ Region = '*'; Kind = $k.Kind; Optional = $k.Optional; Filter = "serviceName eq 'Virtual Machines' and priceType eq '$($k.PriceType)'" }) | Out-Null
        }
    }

    Write-Log "Retail Commitment Signals: downloading RI/SP prices for $($filterTargets.Count) region/kind filter(s) via NextPageLink (currency=$Currency)" "INFO"
    Write-Progress -Id 24 -ParentId 1 -Activity "Retail commitment signals" -Status "Downloading $($filterTargets.Count) filter(s)" -PercentComplete 0

    $worker = {
        param($Target, $BaseUrl, $CurrencyQuery, $TimeoutSec, $MaxRetries, $RetryBaseDelaySec, $RetryMaxDelaySec)
        $encodedFilter = [uri]::EscapeDataString([string]$Target.Filter)
        $nextUrl = "$BaseUrl`?`$filter=$encodedFilter$CurrencyQuery"
        $items = New-Object 'System.Collections.Generic.List[object]'
        $pages = 0
        $complete = $true
        $errText = $null
        $statusCode = 0
        while ($nextUrl) {
            $attempt = 0
            $maxAttempts = [math]::Max(1, $MaxRetries + 1)
            $page = $null
            $ok = $false
            while ($attempt -lt $maxAttempts) {
                $attempt++
                try {
                    $page = Invoke-RestMethod -Uri $nextUrl -Method Get -TimeoutSec $TimeoutSec -ErrorAction Stop
                    $ok = $true
                    break
                }
                catch {
                    $sc = 0
                    try { if ($_.Exception.Response -and $_.Exception.Response.StatusCode) { $sc = [int]$_.Exception.Response.StatusCode } } catch { $sc = 0 }
                    $statusCode = $sc
                    $retryable = (($sc -eq 429) -or ($sc -ge 500 -and $sc -lt 600))
                    if ($retryable -and $attempt -lt $maxAttempts) {
                        Start-Sleep -Seconds ([int][math]::Min($RetryMaxDelaySec, $RetryBaseDelaySec * [math]::Pow(2, $attempt - 1)))
                        continue
                    }
                    $errText = "HTTP $sc - $($_.Exception.Message)"
                    $complete = $false
                    break
                }
            }
            if (-not $ok) { break }
            $pages++
            foreach ($it in @($page.Items)) { $items.Add($it) | Out-Null }
            $nextUrl = if ($page -and $page.PSObject.Properties.Match("NextPageLink").Count -gt 0 -and $page.NextPageLink) { [string]$page.NextPageLink } else { $null }
        }
        [pscustomobject]@{ Region = [string]$Target.Region; Kind = [string]$Target.Kind; Optional = [bool]$Target.Optional; Items = $items.ToArray(); Pages = $pages; Complete = $complete; Error = $errText; StatusCode = $statusCode }
    }

    $targetResults = $null
    if ($PSVersionTable.PSVersion.Major -ge 7 -and $filterTargets.Count -gt 1) {
        $throttle = [math]::Max(1, [math]::Min($MaxParallelRequests, $filterTargets.Count))
        $workerText = $worker.ToString()
        $targetResults = $filterTargets.ToArray() | ForEach-Object -ThrottleLimit $throttle -Parallel {
            $w = [scriptblock]::Create($using:workerText)
            & $w $_ $using:baseUrl $using:currencyQuery $using:TimeoutSec $using:MaxRetries $using:RetryBaseDelaySec $using:RetryMaxDelaySec
        }
    }
    else {
        $targetResults = foreach ($t in $filterTargets) {
            & $worker $t $baseUrl $currencyQuery $TimeoutSec $MaxRetries $RetryBaseDelaySec $RetryMaxDelaySec
        }
    }

    $map = @{}
    $overallComplete = $true
    foreach ($tr in @($targetResults)) {
        $regionOk = [bool]$tr.Complete
        if (-not $regionOk) {
            if ($tr.Optional -and $tr.StatusCode -eq 400) {
                Write-Log "Retail Commitment Signals ($($tr.Kind)) not supported for the requested OData filter (region $($tr.Region)); signal treated as unavailable for this run." "WARN"
            }
            else {
                # A non-optional (RI) abort, or an SP abort that is not a clean 400-unsupported, means the
                # RI/SP coverage set is incomplete for this run -> do not cache it as authoritative.
                $overallComplete = $false
                Write-Log "Retail Commitment Signals ($($tr.Kind)) region '$($tr.Region)' incomplete (cursor aborted): $($tr.Error)" "WARN"
            }
        }
        Add-ApiCallLog -Api "Invoke-RestMethod" -Provider "AzureRetailPrices" -TenantId $script:EffectiveTenantId -SubscriptionId "N/A" -Request "CommitmentSignals kind=$($tr.Kind) region=$($tr.Region)" -StartedAt (Get-Date) -EndedAt (Get-Date) -Success $regionOk -ErrorMessage $tr.Error -Meta @{ Kind = $tr.Kind; Region = $tr.Region; Pages = $tr.Pages; RawItems = @($tr.Items).Count; Currency = $Currency }

        foreach ($item in @($tr.Items)) {
            if (-not $item.armSkuName) { continue }
            if (-not $item.armRegionName) { continue }

            $skuName = [string]$item.armSkuName
            $region = Normalize-Location ([string]$item.armRegionName)
            if ($normalizedRegions.Count -gt 0 -and $region -notin $normalizedRegions) { continue }

            $key = "{0}|{1}" -f $skuName, $region
            if (-not $map.ContainsKey($key)) {
                $map[$key] = [pscustomobject]@{
                    ArmSkuName                    = $skuName
                    Region                        = $region
                    SupportsReservedInstance      = $false
                    SupportsSavingsPlan           = $false
                    ReservedInstanceFirstSeenDate = "N/A"
                    SavingsPlanFirstSeenDate      = "N/A"
                }
            }

            if ($tr.Kind -eq "RI") {
                $map[$key].SupportsReservedInstance = $true
                $map[$key].ReservedInstanceFirstSeenDate = Get-EarlierDateString -Current ([string]$map[$key].ReservedInstanceFirstSeenDate) -Candidate (Format-NullableDate $item.effectiveStartDate)
            }
            elseif ($tr.Kind -eq "SP") {
                $map[$key].SupportsSavingsPlan = $true
                $map[$key].SavingsPlanFirstSeenDate = Get-EarlierDateString -Current ([string]$map[$key].SavingsPlanFirstSeenDate) -Candidate (Format-NullableDate $item.effectiveStartDate)
            }
        }
    }

    $script:CommitmentLastDownloadComplete = $overallComplete
    Write-Progress -Id 24 -ParentId 1 -Activity "Retail commitment signals" -Status "Completed - keys: $(@($map.Keys).Count)" -Completed
    return $map
}

function Get-RetailCommitmentSignalsForVirtualMachinesCached {
    param(
        [Parameter(Mandatory = $false)][string[]]$RegionsFilter,
        [Parameter(Mandatory = $false)][int]$ExpectedPages = 120,
        [Parameter(Mandatory = $false)][int]$MaxRetries = 5,
        [Parameter(Mandatory = $false)][int]$RetryBaseDelaySec = 1,
        [Parameter(Mandatory = $false)][int]$RetryMaxDelaySec = 30,
        [Parameter(Mandatory = $false)][int]$MaxParallelRequests = 6,
        [Parameter(Mandatory = $false)][int]$TimeoutSec = 15,
        [Parameter(Mandatory = $false)][string]$Currency = "USD",
        [Parameter(Mandatory = $true)][string]$CacheDir,
        [Parameter(Mandatory = $true)][bool]$UseCache,
        [Parameter(Mandatory = $true)][int]$TtlHours,
        [Parameter(Mandatory = $true)][bool]$ForceRefresh,
        [Parameter(Mandatory = $false)][string]$TenantId
    )

    $context = [ordered]@{
        scope    = "retail-vm-commitment-signals"
        tenantId = if ($TenantId) { $TenantId } else { "N/A" }
        currency = if ($Currency) { $Currency } else { "USD" }
        regions  = @($RegionsFilter | ForEach-Object { Normalize-Location ([string]$_) } | Sort-Object -Unique)
    }
    $cachePath = New-CacheFilePath -CacheDir $CacheDir -Prefix "retail_vm_commitments" -Context $context

    if ($UseCache -and (-not $ForceRefresh) -and (Test-CacheFileFresh -Path $cachePath -TtlHours $TtlHours)) {
        $cacheStart = Get-Date
        $envelope = Read-CacheEnvelope -Path $cachePath
        if ($envelope -and $envelope.Data) {
            $cachedMap = Convert-CacheEntriesToCommitmentMap -Entries @($envelope.Data)
            if (@($cachedMap.Keys).Count -gt 0) {
                Add-ApiCallLog -Api "LocalCacheRead" -Provider "LocalCache" -TenantId $script:EffectiveTenantId -SubscriptionId "N/A" -Request $cachePath -StartedAt $cacheStart -EndedAt (Get-Date) -Success $true -Meta @{ CacheKind = "RetailCommitmentSignals"; CacheHit = $true; Count = @($cachedMap.Keys).Count; TtlHours = $TtlHours }
                Write-Log "Retail commitment signals from local cache: $cachePath"
                return $cachedMap
            }
        }
        Add-ApiCallLog -Api "LocalCacheRead" -Provider "LocalCache" -TenantId $script:EffectiveTenantId -SubscriptionId "N/A" -Request $cachePath -StartedAt $cacheStart -EndedAt (Get-Date) -Success $false -ErrorMessage "Empty/invalid cache"
    }

    try {
        $freshMap = Get-RetailCommitmentSignalsForVirtualMachines -RegionsFilter $RegionsFilter -ExpectedPages $ExpectedPages -MaxRetries $MaxRetries -RetryBaseDelaySec $RetryBaseDelaySec -RetryMaxDelaySec $RetryMaxDelaySec -MaxParallelRequests $MaxParallelRequests -TimeoutSec $TimeoutSec -Currency $Currency
    }
    catch {
        if ($UseCache -and (Test-Path -LiteralPath $cachePath)) {
            $staleEnvelope = Read-CacheEnvelope -Path $cachePath
            if ($staleEnvelope -and $staleEnvelope.Data) {
                $staleMap = Convert-CacheEntriesToCommitmentMap -Entries @($staleEnvelope.Data)
                if (@($staleMap.Keys).Count -gt 0) {
                    Write-Log "Retail commitment API unavailable/throttled. Using stale cache: $cachePath" "WARN"
                    Add-ApiCallLog -Api "LocalCacheRead" -Provider "LocalCache" -TenantId $script:EffectiveTenantId -SubscriptionId "N/A" -Request $cachePath -StartedAt (Get-Date) -EndedAt (Get-Date) -Success $true -Meta @{ CacheKind = "RetailCommitmentSignals"; CacheHit = $true; StaleFallback = $true; Count = @($staleMap.Keys).Count }
                    return $staleMap
                }
            }
        }

        throw
    }

    if ($UseCache -and $script:CommitmentLastDownloadComplete -and @($freshMap.Keys).Count -gt 0) {
        $cacheWriteStart = Get-Date
        try {
            $cacheEntries = Convert-CommitmentMapToCacheEntries -CommitmentMap $freshMap
            Save-CacheEnvelope -Path $cachePath -CacheKind "RetailCommitmentSignals" -Context $context -Data $cacheEntries
            Add-ApiCallLog -Api "LocalCacheWrite" -Provider "LocalCache" -TenantId $script:EffectiveTenantId -SubscriptionId "N/A" -Request $cachePath -StartedAt $cacheWriteStart -EndedAt (Get-Date) -Success $true -Meta @{ CacheKind = "RetailCommitmentSignals"; Count = @($freshMap.Keys).Count }
        }
        catch {
            Add-ApiCallLog -Api "LocalCacheWrite" -Provider "LocalCache" -TenantId $script:EffectiveTenantId -SubscriptionId "N/A" -Request $cachePath -StartedAt $cacheWriteStart -EndedAt (Get-Date) -Success $false -ErrorMessage $_.Exception.Message
            Write-Log "Unable to save Retail commitment signals cache: $($_.Exception.Message)" "WARN"
        }
    }
    elseif ($UseCache -and -not $script:CommitmentLastDownloadComplete) {
        Write-Log "Retail commitment (RI/SP) download was incomplete (one or more required region cursors aborted); not caching a partial map." "WARN"
    }

    return $freshMap
}

function Resolve-TargetSubscriptionIds {
    param(
        [Parameter(Mandatory = $false)][string]$Tenant,
        [Parameter(Mandatory = $false)][string[]]$RequestedSubscriptionIds
    )

    if ($Tenant) {
        $startedAt = Get-Date
        try {
            $allSubs = Get-AzSubscription -TenantId $Tenant
            Add-ApiCallLog -Api "Get-AzSubscription" -Provider "Az.Accounts" -TenantId $Tenant -SubscriptionId "N/A" -Request "TenantId=$Tenant" -StartedAt $startedAt -EndedAt (Get-Date) -Success $true -Meta @{ ResultCount = @($allSubs).Count }
        }
        catch {
            Add-ApiCallLog -Api "Get-AzSubscription" -Provider "Az.Accounts" -TenantId $Tenant -SubscriptionId "N/A" -Request "TenantId=$Tenant" -StartedAt $startedAt -EndedAt (Get-Date) -Success $false -ErrorMessage $_.Exception.Message
            throw
        }
    }
    else {
        $startedAt = Get-Date
        try {
            $allSubs = Get-AzSubscription
            Add-ApiCallLog -Api "Get-AzSubscription" -Provider "Az.Accounts" -TenantId $script:EffectiveTenantId -SubscriptionId "N/A" -Request "DefaultContext" -StartedAt $startedAt -EndedAt (Get-Date) -Success $true -Meta @{ ResultCount = @($allSubs).Count }
        }
        catch {
            Add-ApiCallLog -Api "Get-AzSubscription" -Provider "Az.Accounts" -TenantId $script:EffectiveTenantId -SubscriptionId "N/A" -Request "DefaultContext" -StartedAt $startedAt -EndedAt (Get-Date) -Success $false -ErrorMessage $_.Exception.Message
            throw
        }
    }

    $enabledSubs = @($allSubs | Where-Object { [string]$_.State -eq "Enabled" })
    if (@($enabledSubs).Count -eq 0) {
        throw "No Enabled subscription found in the current tenant/scope."
    }

    if ($RequestedSubscriptionIds -and $RequestedSubscriptionIds.Count -gt 0) {
        $requestedSet = @($RequestedSubscriptionIds | ForEach-Object { [string]$_ })
        $selected = @($enabledSubs | Where-Object { [string]$_.Id -in $requestedSet })

        $foundSet = @($selected | ForEach-Object { [string]$_.Id })
        $missing = @($requestedSet | Where-Object { $_ -notin $foundSet })
        if (@($missing).Count -gt 0) {
            throw "Subscriptions not found or not Enabled in the current tenant: $($missing -join ', ')"
        }

        return @($selected | Select-Object -ExpandProperty Id -Unique)
    }

    return @($enabledSubs | Select-Object -ExpandProperty Id -Unique)
}

function Normalize-Location {
    param([Parameter(Mandatory = $true)][string]$Location)

    return $Location.Trim().ToLowerInvariant().Replace(" ", "")
}

function Normalize-SkuName {
    param([Parameter(Mandatory = $true)][string]$SkuName)

    return $SkuName.Trim().ToLowerInvariant()
}

function Format-NullableDate {
    param([Parameter(Mandatory = $false)]$Value)

    if ($null -eq $Value) { return "N/A" }
    if ([string]::IsNullOrWhiteSpace([string]$Value)) { return "N/A" }

    try {
        return (Get-Date $Value).ToString("yyyy-MM-dd")
    }
    catch {
        return [string]$Value
    }
}

function Get-ComputeSkuCatalogFromRest {
    param(
        [Parameter(Mandatory = $true)][string]$SubscriptionId,
        [Parameter(Mandatory = $false)][string[]]$RegionsFilter,
        [Parameter(Mandatory = $false)][string]$ApiVersion = "2026-03-02",
        [Parameter(Mandatory = $false)][bool]$IncludeExtendedLocations = $true
    )

    $ctxStart = Get-Date
    try {
        $currentContext = Get-AzContext -ErrorAction SilentlyContinue
        $currentSubscription = if ($currentContext -and $currentContext.Subscription) { [string]$currentContext.Subscription.Id } else { "" }
        if ($currentSubscription -ne $SubscriptionId) {
            Set-AzContext -Subscription $SubscriptionId -ErrorAction Stop | Out-Null
            Write-Log "Resource SKUs REST API context switched to subscription $SubscriptionId"
        }
        Add-ApiCallLog -Api "Set-AzContext" -Provider "Az.Accounts" -TenantId $script:EffectiveTenantId -SubscriptionId $SubscriptionId -Request "Subscription=$SubscriptionId" -StartedAt $ctxStart -EndedAt (Get-Date) -Success $true
    }
    catch {
        Add-ApiCallLog -Api "Set-AzContext" -Provider "Az.Accounts" -TenantId $script:EffectiveTenantId -SubscriptionId $SubscriptionId -Request "Subscription=$SubscriptionId" -StartedAt $ctxStart -EndedAt (Get-Date) -Success $false -ErrorMessage $_.Exception.Message
        throw
    }

    $tokenStart = Get-Date
    $tokenValue = $null
    try {
        $token = Get-AzAccessToken -ResourceUrl "https://management.azure.com/"
        Add-ApiCallLog -Api "Get-AzAccessToken" -Provider "Az.Accounts" -TenantId $script:EffectiveTenantId -SubscriptionId $SubscriptionId -Request "ResourceUrl=https://management.azure.com/" -StartedAt $tokenStart -EndedAt (Get-Date) -Success $true

        if ($token -and $token.PSObject.Properties.Match("Token").Count -gt 0 -and $token.Token) {
            if ($token.Token -is [System.Security.SecureString]) {
                $tokenValue = [System.Net.NetworkCredential]::new("", $token.Token).Password
            }
            else {
                $tokenValue = [string]$token.Token
            }
        }

        if ([string]::IsNullOrWhiteSpace($tokenValue)) {
            throw "Get-AzAccessToken returned an empty token value."
        }
    }
    catch {
        Add-ApiCallLog -Api "Get-AzAccessToken" -Provider "Az.Accounts" -TenantId $script:EffectiveTenantId -SubscriptionId $SubscriptionId -Request "ResourceUrl=https://management.azure.com/" -StartedAt $tokenStart -EndedAt (Get-Date) -Success $false -ErrorMessage $_.Exception.Message
        throw
    }

    $headers = @{ Authorization = "Bearer $tokenValue" }
    $base = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Compute/skus?api-version=$ApiVersion"
    if ($IncludeExtendedLocations) {
        $base = "$base&includeExtendedLocations=true"
    }

    $url = $base
    $all = New-Object 'System.Collections.Generic.List[object]'
    $page = 0

    while ($url) {
        $page++
        $restStart = Get-Date
        try {
            $resp = Invoke-RestMethod -Uri $url -Method Get -Headers $headers -ErrorAction Stop
            Add-ApiCallLog -Api "Invoke-RestMethod" -Provider "AzureComputeResourceSkus" -TenantId $script:EffectiveTenantId -SubscriptionId $SubscriptionId -Request $url -StartedAt $restStart -EndedAt (Get-Date) -Success $true -Meta @{ Page = $page; Items = @($resp.value).Count }
        }
        catch {
            Add-ApiCallLog -Api "Invoke-RestMethod" -Provider "AzureComputeResourceSkus" -TenantId $script:EffectiveTenantId -SubscriptionId $SubscriptionId -Request $url -StartedAt $restStart -EndedAt (Get-Date) -Success $false -ErrorMessage $_.Exception.Message -Meta @{ Page = $page }
            throw
        }

        if ($resp -and $resp.value) {
            foreach ($item in @($resp.value)) {
                $all.Add($item)
            }
        }

        $url = if ($resp -and $resp.PSObject.Properties.Match("nextLink").Count -gt 0 -and $resp.nextLink) { [string]$resp.nextLink } else { $null }
    }

    $allArr = $all.ToArray()
    $totalSkus = @($allArr).Count
    $idx = 0
    $catalog = foreach ($sku in $allArr) {
        if ([string]$sku.resourceType -ne "virtualMachines") { continue }

        $idx++
        $pct = if ($totalSkus -gt 0) { [int][math]::Round(($idx / $totalSkus) * 100, 0) } else { 100 }
        Write-Progress -Id 12 -ParentId 1 -Activity "Compute SKU catalog (REST)" -Status "Analyzing SKU $idx/$totalSkus" -PercentComplete $pct

        $locations = @($sku.locations | ForEach-Object { Normalize-Location ([string]$_) })
        if ($RegionsFilter -and $RegionsFilter.Count -gt 0) {
            $normalizedRegions = $RegionsFilter | ForEach-Object { Normalize-Location $_ }
            if (-not ($locations | Where-Object { $_ -in $normalizedRegions })) {
                continue
            }
        }

        $cap = @{}
        foreach ($c in @($sku.capabilities)) {
            $cap[[string]$c.name] = [string]$c.value
        }

        $familyVal = if ($sku.PSObject.Properties.Match("family").Count -gt 0) { [string]$sku.family } else { "" }
        $tierVal = if ($sku.PSObject.Properties.Match("tier").Count -gt 0) { [string]$sku.tier } else { "" }
        $sizeVal = if ($sku.PSObject.Properties.Match("size").Count -gt 0) { [string]$sku.size } else { "" }
        $restrictionsVal = if ($sku.PSObject.Properties.Match("restrictions").Count -gt 0) { $sku.restrictions } else { @() }
        $locationInfoVal = if ($sku.PSObject.Properties.Match("locationInfo").Count -gt 0) { $sku.locationInfo } else { @() }
        $apiVersionsVal = if ($sku.PSObject.Properties.Match("apiVersions").Count -gt 0) { $sku.apiVersions } else { @() }

        [pscustomobject]@{
            Name         = [string]$sku.name
            Family       = $familyVal
            Tier         = $tierVal
            Size         = $sizeVal
            Locations    = $locations
            Cap          = $cap
            Restrictions = $restrictionsVal
            LocationInfo = $locationInfoVal
            ApiVersions  = $apiVersionsVal
        }
    }

    Write-Progress -Id 12 -ParentId 1 -Activity "Compute SKU catalog (REST)" -Status "Completed" -Completed
    return $catalog
}

function Get-VersionFromVmSize {
    param([Parameter(Mandatory = $true)][string]$VmSize)

    $m = [regex]::Match($VmSize, "_v(?<ver>\d+)$", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
        return [int]$m.Groups["ver"].Value
    }

    return 1
}

function Get-ResourceGraphVmInventory {
    param(
        [Parameter(Mandatory = $false)][string[]]$Subscriptions
    )

    $query = @"
Resources
| where type =~ 'microsoft.compute/virtualmachines'
| extend vmSize = tostring(properties.hardwareProfile.vmSize)
| extend osType = tostring(properties.storageProfile.osDisk.osType)
| extend vmCreatedDate = tostring(properties.timeCreated)
| extend tagsText = tostring(tags)
| extend idLower = tolower(id)
| join kind=leftouter (
    Resources
    | where type =~ 'microsoft.compute/virtualmachines/extensions'
    | extend vmId = tolower(substring(id, 0, indexof(id, '/extensions/')))
    | extend extPublisher = tostring(properties.publisher)
    | extend extType = tostring(properties.type)
    | summarize extensions = make_list(strcat(extPublisher, '/', extType)) by vmId
) on `$left.idLower == `$right.vmId
| extend extensionsText = tostring(extensions)
| project subscriptionId, resourceGroup, name, location, vmSize, osType, vmCreatedDate, tagsText, extensionsText
"@

    $subList = @($Subscriptions)
    if (@($subList).Count -eq 0) {
        $ctx = Get-AzContext -ErrorAction SilentlyContinue
        if ($ctx -and $ctx.Subscription) {
            $subList = @([string]$ctx.Subscription.Id)
        }
    }

    $inventory = New-Object 'System.Collections.Generic.List[object]'
    $totalSubs = @($subList).Count
    $subIdx = 0

    foreach ($subId in $subList) {
        $subIdx++
        $subPct = if ($totalSubs -gt 0) { [int][math]::Round(($subIdx / $totalSubs) * 100, 0) } else { 100 }
        Write-Progress -Id 11 -ParentId 1 -Activity "Resource Graph" -Status "Subscription $subIdx/$totalSubs ($subId)" -PercentComplete $subPct

        $pageSize = 1000
        $allRows = New-Object 'System.Collections.Generic.List[object]'
        $pageNumber = 0
        $skipToken = $null

        do {
            $pageNumber++
            Write-Progress -Id 18 -ParentId 11 -Activity "Resource Graph paging" -Status "Sub $subIdx/$totalSubs - page $pageNumber - rows: $($allRows.Count)" -PercentComplete ([math]::Min(95, $pageNumber * 7))

            $graphArgs = @{
                Query        = $query
                First        = $pageSize
                Subscription = [string]$subId
            }

            if ($skipToken) {
                $graphArgs["SkipToken"] = $skipToken
            }

            $searchStart = Get-Date
            try {
                $page = Search-AzGraph @graphArgs
                Add-ApiCallLog -Api "Search-AzGraph" -Provider "Az.ResourceGraph" -TenantId $script:EffectiveTenantId -SubscriptionId ([string]$subId) -Request "First=$pageSize;SkipToken=$([bool]$skipToken)" -StartedAt $searchStart -EndedAt (Get-Date) -Success $true -Meta @{ ReturnedRows = @($page).Count }
            }
            catch {
                Add-ApiCallLog -Api "Search-AzGraph" -Provider "Az.ResourceGraph" -TenantId $script:EffectiveTenantId -SubscriptionId ([string]$subId) -Request "First=$pageSize;SkipToken=$([bool]$skipToken)" -StartedAt $searchStart -EndedAt (Get-Date) -Success $false -ErrorMessage $_.Exception.Message
                throw
            }

            foreach ($item in @($page)) {
                $allRows.Add($item)
            }
            $skipToken = if ($page) { $page.SkipToken } else { $null }
        } while ($skipToken)

        foreach ($r in $allRows) {
            $inventory.Add([pscustomobject]@{
                SubscriptionId = [string]$r.subscriptionId
                ResourceGroup  = [string]$r.resourceGroup
                VmName         = [string]$r.name
                Location       = Normalize-Location ([string]$r.location)
                VmSize         = [string]$r.vmSize
                OsType         = [string]$r.osType
                VmCreatedDate  = Format-NullableDate ([string]$r.vmCreatedDate)
                TagsText       = if ($r.PSObject.Properties.Match("tagsText").Count -gt 0) { [string]$r.tagsText } else { "" }
                ExtensionsText = if ($r.PSObject.Properties.Match("extensionsText").Count -gt 0) { [string]$r.extensionsText } else { "" }
            })
        }
    }

    $totalInventoryCount = $inventory.Count
    Write-Progress -Id 18 -ParentId 11 -Activity "Resource Graph paging" -Status "Completed" -Completed
    Write-Progress -Id 11 -ParentId 1 -Activity "Resource Graph" -Status "Completed - total VMs: $totalInventoryCount" -Completed

    return $inventory.ToArray()
}

function Get-ComputeSkuCatalog {
    param(
        [Parameter(Mandatory = $false)][string[]]$RegionsFilter,
        [Parameter(Mandatory = $false)][string]$SubscriptionIdForRest,
        [Parameter(Mandatory = $false)][bool]$UseRestApi = $true,
        [Parameter(Mandatory = $false)][string]$ApiVersion = "2026-03-02",
        [Parameter(Mandatory = $false)][bool]$IncludeExtendedLocations = $true
    )

    if ($UseRestApi -and $SubscriptionIdForRest) {
        try {
            Write-Log "SKU catalog via Resource SKUs REST API (subscription $SubscriptionIdForRest)"
            return Get-ComputeSkuCatalogFromRest -SubscriptionId $SubscriptionIdForRest -RegionsFilter $RegionsFilter -ApiVersion $ApiVersion -IncludeExtendedLocations:$IncludeExtendedLocations
        }
        catch {
            $statusCode = "N/A"
            try {
                if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                    $statusCode = [int]$_.Exception.Response.StatusCode
                }
            }
            catch {
                $statusCode = "N/A"
            }

            Write-Log "Resource SKUs REST API failed (subscription=$SubscriptionIdForRest, status=$statusCode); falling back to Get-AzComputeResourceSku. Error: $($_.Exception.Message)" "WARN"
            if ($statusCode -eq 401) {
                Write-Log "HTTP 401 on Resource SKUs REST API: verify RBAC on subscription $SubscriptionIdForRest and token tenant alignment." "WARN"
            }
        }
    }

    $startedAt = Get-Date
    try {
        $all = Get-AzComputeResourceSku | Where-Object { $_.ResourceType -eq "virtualMachines" }
        Add-ApiCallLog -Api "Get-AzComputeResourceSku" -Provider "Az.Compute" -TenantId $script:EffectiveTenantId -SubscriptionId "N/A" -Request "ResourceType=virtualMachines" -StartedAt $startedAt -EndedAt (Get-Date) -Success $true -Meta @{ ResultCount = @($all).Count }
    }
    catch {
        Add-ApiCallLog -Api "Get-AzComputeResourceSku" -Provider "Az.Compute" -TenantId $script:EffectiveTenantId -SubscriptionId "N/A" -Request "ResourceType=virtualMachines" -StartedAt $startedAt -EndedAt (Get-Date) -Success $false -ErrorMessage $_.Exception.Message
        throw
    }

    $totalSkus = @($all).Count
    $idx = 0
    $catalog = foreach ($sku in $all) {
        $idx++
        $pct = if ($totalSkus -gt 0) { [int][math]::Round(($idx / $totalSkus) * 100, 0) } else { 100 }
        Write-Progress -Id 12 -ParentId 1 -Activity "Compute SKU catalog" -Status "Analyzing SKU $idx/$totalSkus" -PercentComplete $pct

        $locations = @($sku.Locations | ForEach-Object { Normalize-Location ([string]$_) })
        if ($RegionsFilter -and $RegionsFilter.Count -gt 0) {
            $normalizedRegions = $RegionsFilter | ForEach-Object { Normalize-Location $_ }
            if (-not ($locations | Where-Object { $_ -in $normalizedRegions })) {
                continue
            }
        }

        $cap = @{}
        foreach ($c in $sku.Capabilities) {
            $cap[$c.Name] = $c.Value
        }

        [pscustomobject]@{
            Name       = [string]$sku.Name
            Family     = [string]$sku.Family
            Tier       = [string]$sku.Tier
            Size       = [string]$sku.Size
            Locations  = $locations
            Cap        = $cap
            Restrictions = $sku.Restrictions
        }
    }

    Write-Progress -Id 12 -ParentId 1 -Activity "Compute SKU catalog" -Status "Completed" -Completed

    return $catalog
}

function Get-RetailPricesForVirtualMachines {
    param(
        [Parameter(Mandatory = $false)][string[]]$RegionsFilter,
        [Parameter(Mandatory = $false)][int]$ExpectedPages = 180,
        [Parameter(Mandatory = $false)][int]$MaxRetries = 5,
        [Parameter(Mandatory = $false)][int]$RetryBaseDelaySec = 1,
        [Parameter(Mandatory = $false)][int]$RetryMaxDelaySec = 30,
        [Parameter(Mandatory = $false)][int]$MaxParallelRequests = 6,
        [Parameter(Mandatory = $false)][int]$TimeoutSec = 15,
        [Parameter(Mandatory = $false)][string]$Currency = "USD"
    )

    $baseUrl = "https://prices.azure.com/api/retail/prices"
    $timer = [System.Diagnostics.Stopwatch]::StartNew()

    # Region-scope the OData filter so each download is small and can be paged to completion by
    # following NextPageLink. The previous approach downloaded the ENTIRE global VM consumption price
    # list and paged with $skip; the Retail Prices API serves deep $skip offsets unreliably (it stops
    # returning rows past a few thousand records), so a large/global scope silently produced only a few
    # in-region keys (e.g. 218 < the minimum) and left RetailDeltaMonthly null. NextPageLink is the
    # officially supported cursor and returns every page for the requested (region-scoped) filter.
    $normalizedRegions = @()
    if ($RegionsFilter -and $RegionsFilter.Count -gt 0) {
        $normalizedRegions = @($RegionsFilter | ForEach-Object { Normalize-Location ([string]$_) } | Where-Object { $_ } | Sort-Object -Unique)
    }

    $filterTargets = New-Object 'System.Collections.Generic.List[object]'
    if ($normalizedRegions.Count -gt 0) {
        foreach ($region in $normalizedRegions) {
            $filterTargets.Add([pscustomobject]@{
                Region = $region
                Filter = "serviceName eq 'Virtual Machines' and priceType eq 'Consumption' and armRegionName eq '$region'"
            }) | Out-Null
        }
    }
    else {
        $filterTargets.Add([pscustomobject]@{
            Region = '*'
            Filter = "serviceName eq 'Virtual Machines' and priceType eq 'Consumption'"
        }) | Out-Null
    }

    # currencyCode is a query parameter (NOT part of $filter). Omitting it defaults to USD.
    $currencyQuery = if (-not [string]::IsNullOrWhiteSpace($Currency)) { "&currencyCode='$Currency'" } else { "" }

    Write-Log "Retail Prices API: downloading VM consumption prices for $($filterTargets.Count) region-scoped filter(s) via NextPageLink (currency=$Currency; parallel across regions)" "INFO"
    Write-Progress -Id 13 -ParentId 1 -Activity "Retail Prices API" -Status "Downloading prices for $($filterTargets.Count) region(s)" -PercentComplete 0

    # Per-region worker: follows THIS region's own NextPageLink cursor to completion. Do NOT send $top:
    # the API ignores it (returns 1000/page) but then builds NextPageLink with a corrupted
    # `$top = suppliedTop - itemsReturned` (e.g. 100 - 1000 = -900) -> HTTP 400. A page that fails
    # non-retryably marks ONLY this region incomplete (the cursor cannot be resumed) without aborting the
    # other regions. 429/5xx are retried with exponential backoff.
    $worker = {
        param($Target, $BaseUrl, $CurrencyQuery, $TimeoutSec, $MaxRetries, $RetryBaseDelaySec, $RetryMaxDelaySec)
        $encodedFilter = [uri]::EscapeDataString([string]$Target.Filter)
        $nextUrl = "$BaseUrl`?`$filter=$encodedFilter$CurrencyQuery"
        $items = New-Object 'System.Collections.Generic.List[object]'
        $pages = 0
        $complete = $true
        $errText = $null
        while ($nextUrl) {
            $attempt = 0
            $maxAttempts = [math]::Max(1, $MaxRetries + 1)
            $page = $null
            $ok = $false
            while ($attempt -lt $maxAttempts) {
                $attempt++
                try {
                    $page = Invoke-RestMethod -Uri $nextUrl -Method Get -TimeoutSec $TimeoutSec -ErrorAction Stop
                    $ok = $true
                    break
                }
                catch {
                    $sc = 0
                    try { if ($_.Exception.Response -and $_.Exception.Response.StatusCode) { $sc = [int]$_.Exception.Response.StatusCode } } catch { $sc = 0 }
                    $retryable = (($sc -eq 429) -or ($sc -ge 500 -and $sc -lt 600))
                    if ($retryable -and $attempt -lt $maxAttempts) {
                        Start-Sleep -Seconds ([int][math]::Min($RetryMaxDelaySec, $RetryBaseDelaySec * [math]::Pow(2, $attempt - 1)))
                        continue
                    }
                    $errText = "HTTP $sc - $($_.Exception.Message)"
                    $complete = $false
                    break
                }
            }
            if (-not $ok) { break }
            $pages++
            foreach ($it in @($page.Items)) { $items.Add($it) | Out-Null }
            $nextUrl = if ($page -and $page.PSObject.Properties.Match("NextPageLink").Count -gt 0 -and $page.NextPageLink) { [string]$page.NextPageLink } else { $null }
        }
        [pscustomobject]@{ Region = [string]$Target.Region; Items = $items.ToArray(); Pages = $pages; Complete = $complete; Error = $errText }
    }

    $regionResults = $null
    if ($PSVersionTable.PSVersion.Major -ge 7 -and $filterTargets.Count -gt 1) {
        # Parallelize ACROSS regions (each region stays sequential on its own cursor). Throttle to limit
        # concurrent requests against the anonymous, IP-rate-limited Retail API.
        $throttle = [math]::Max(1, [math]::Min($MaxParallelRequests, $filterTargets.Count))
        $workerText = $worker.ToString()
        $regionResults = $filterTargets.ToArray() | ForEach-Object -ThrottleLimit $throttle -Parallel {
            $w = [scriptblock]::Create($using:workerText)
            & $w $_ $using:baseUrl $using:currencyQuery $using:TimeoutSec $using:MaxRetries $using:RetryBaseDelaySec $using:RetryMaxDelaySec
        }
    }
    else {
        $regionResults = foreach ($t in $filterTargets) {
            & $worker $t $baseUrl $currencyQuery $TimeoutSec $MaxRetries $RetryBaseDelaySec $RetryMaxDelaySec
        }
    }

    $results = New-Object 'System.Collections.Generic.List[object]'
    $failedRequests = 0
    $totalPages = 0
    $overallComplete = $true

    foreach ($rr in @($regionResults)) {
        $totalPages += [int]$rr.Pages
        $regionOk = [bool]$rr.Complete
        if (-not $regionOk) {
            $overallComplete = $false
            $failedRequests++
            Write-Log "Retail Prices API: region '$($rr.Region)' incomplete (cursor aborted, cannot resume): $($rr.Error)" "WARN"
        }
        Add-ApiCallLog -Api "Invoke-RestMethod" -Provider "AzureRetailPrices" -TenantId $script:EffectiveTenantId -SubscriptionId "N/A" -Request "RegionScopedPrices region=$($rr.Region)" -StartedAt (Get-Date) -EndedAt (Get-Date) -Success $regionOk -ErrorMessage $rr.Error -Meta @{ Region = $rr.Region; Pages = $rr.Pages; RawItems = @($rr.Items).Count; Currency = $Currency }

        $regionRecordCount = 0
        foreach ($item in @($rr.Items)) {
            if (-not $item.armSkuName) { continue }
            if (-not $item.armRegionName) { continue }
            if (Test-IsExcludedRetailVmPriceRecord -Item $item) { continue }

            $region = Normalize-Location ([string]$item.armRegionName)
            if ($normalizedRegions.Count -gt 0 -and $region -notin $normalizedRegions) { continue }

            $results.Add([pscustomobject]@{
                ArmSkuName         = [string]$item.armSkuName
                Region             = $region
                CurrencyCode       = [string]$item.currencyCode
                UnitPrice          = [double]$item.unitPrice
                UnitOfMeasure      = [string]$item.unitOfMeasure
                MeterName          = [string]$item.meterName
                ProductName        = [string]$item.productName
                SkuName            = [string]$item.skuName
                EffectiveStartDate = Format-NullableDate $item.effectiveStartDate
                IsWindows          = ([string]$item.productName -match '(?i)windows')
            })
            $regionRecordCount++
        }

        if ($regionRecordCount -eq 0 -and $rr.Region -ne '*' -and $regionOk) {
            Write-Log "Retail Prices API: 0 in-region records for '$($rr.Region)'. This region may be an extended location/edge zone whose armRegionName differs from the normalized name; its prices will be missing from the delta." "WARN"
        }
    }

    $script:RetailLastDownloadComplete = $overallComplete
    $script:RetailLastPageCount = $totalPages

    if ($results.Count -eq 0) {
        Write-Log "Retail Prices API: No records found for the requested region scope" "WARN"
        $timer.Stop()
        Write-Progress -Id 13 -ParentId 1 -Activity "Retail Prices API" -Status "No records" -Completed
        return @{}
    }

    # Build price map. Keep the lowest price per SKU|Region for back-compat (UnitPrice), PLUS the lowest
    # Linux and lowest Windows meter separately so a Windows VM is not priced with the (cheaper) Linux
    # meter. Windows meters carry "Windows" in productName; everything else is treated as Linux/other.
    Write-Progress -Id 14 -ParentId 1 -Activity "Retail Prices API" -Status "Indexing $($results.Count) records..." -PercentComplete 95
    $priceMap = @{}
    $groups = $results.ToArray() | Group-Object -Property ArmSkuName, Region
    $totalGroups = @($groups).Count
    $gidx = 0

    foreach ($g in $groups) {
        $gidx++
        $pct = if ($totalGroups -gt 0) { [int][math]::Round(($gidx / $totalGroups) * 100, 0) } else { 100 }
        Write-Progress -Id 14 -ParentId 1 -Activity "Retail Prices API" -Status "Indexing prices $gidx/$totalGroups" -PercentComplete $pct

        $groupArr = @($g.Group)
        $overall = $groupArr | Sort-Object UnitPrice | Select-Object -First 1
        $linuxEntry = @($groupArr | Where-Object { -not $_.IsWindows } | Sort-Object UnitPrice | Select-Object -First 1)
        $windowsEntry = @($groupArr | Where-Object { $_.IsWindows } | Sort-Object UnitPrice | Select-Object -First 1)
        $linuxPrice = if (@($linuxEntry).Count -gt 0) { [double]$linuxEntry[0].UnitPrice } else { $null }
        $windowsPrice = if (@($windowsEntry).Count -gt 0) { [double]$windowsEntry[0].UnitPrice } else { $null }

        $key = "{0}|{1}" -f $overall.ArmSkuName, $overall.Region
        $priceMap[$key] = [pscustomobject]@{
            ArmSkuName         = [string]$overall.ArmSkuName
            Region             = [string]$overall.Region
            CurrencyCode       = [string]$overall.CurrencyCode
            UnitPrice          = [double]$overall.UnitPrice
            LinuxUnitPrice     = $linuxPrice
            WindowsUnitPrice   = $windowsPrice
            UnitOfMeasure      = [string]$overall.UnitOfMeasure
            MeterName          = [string]$overall.MeterName
            ProductName        = [string]$overall.ProductName
            SkuName            = [string]$overall.SkuName
            EffectiveStartDate = $overall.EffectiveStartDate
        }
    }

    $timer.Stop()

    Write-Log "Retail Prices API: Complete in $([int]$timer.Elapsed.TotalSeconds)s. Pages=$totalPages, Records=$($results.Count), PriceKeys=$($priceMap.Count), FailedRequests=$failedRequests, DownloadComplete=$overallComplete, Currency=$Currency" "INFO"
    Write-Progress -Id 13 -ParentId 1 -Activity "Retail Prices API" -Status "Download complete - pages: $totalPages" -Completed
    Write-Progress -Id 14 -ParentId 1 -Activity "Retail Prices API" -Status "Indexing complete - keys: $($priceMap.Count)" -Completed

    return $priceMap
}

# ============================================================================
# STREAM B: SKU-FAMILY RETIREMENT (Live from Microsoft Learn)
# ============================================================================

function Get-OfficialRetirementsFromLearnMarkdown {
    <#
    .SYNOPSIS
    Fetch official SKU-family retirement announcements live from Microsoft Learn markdown.
    
    .DESCRIPTION
    SOURCE FOR STREAM B (SKU-family retirement):
    Parses the official retired VM sizes list from Learn docs (GitHub raw markdown).
    Tables map series name (Dv2-series, Av2/Amv2-series, etc.) to planned retirement date (MM/DD/YY format in table).
    Converts dates from US format (MM/DD/YY) to ISO (yyyy-MM-dd) with explicit en-US culture to avoid silent date reversals.
    
    If fetch fails: returns Ok=$false; caller decides whether to throw.
    If table structure changes: returns 0 entries → BLOCK (fail-safe, logs clearly).
    
    .OUTPUTS
    PSCustomObject with:
      - Ok : bool (true if fetch+parse succeeded and found rows)
      - Series : [array] of retirement entries with SeriesName, RetireOn (ISO), Source="LiveLearnMarkdown", AsOf=[timestamp]
      - Url : the source URL fetched
      - ParsedRowCount : count of table rows parsed
      - Error : error message if fetch failed
    #>
    param(
        [Parameter(Mandatory = $false)][string]$Url = "https://raw.githubusercontent.com/MicrosoftDocs/azure-compute-docs/main/articles/virtual-machines/sizes/retirement/retired-sizes-list.md"
    )

    $entries = @()
    $parsedRowCount = 0
    
    try {
        Write-Log "Fetching official retirement list from Learn markdown: $Url" "INFO"
        
        $fetchStart = Get-Date
        $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
        Add-ApiCallLog -Api "Invoke-WebRequest" -Provider "Learn.Microsoft.Com" -TenantId $script:EffectiveTenantId -SubscriptionId "N/A" -Request "Retired VM Sizes Markdown" -StartedAt $fetchStart -EndedAt (Get-Date) -Success $true -Meta @{ ContentLength = $response.Content.Length }
        
        $markdown = [string]$response.Content
        
        # Parse markdown tables: each table row is "| Series name | ... | Planned Retirement Date |"
        # Rows start after header separator (---), and retirement date column is US format MM/DD/YY
        $lines = $markdown -split "`n"
        
        # Find header row and identify column indices
        $headerRowIdx = -1
        $headerLine = ""
        
        for ($lineIdx = 0; $lineIdx -lt $lines.Count; $lineIdx++) {
            if ($lines[$lineIdx] -like "*Series*" -and $lines[$lineIdx] -like "*|*") {
                $headerLine = $lines[$lineIdx]
                $headerRowIdx = $lineIdx
                break
            }
        }
        
        if ($headerRowIdx -lt 0) {
            Write-Log "Learn markdown: header row not found" "ERROR"
            return [pscustomobject]@{
                Ok              = $false
                Series          = @()
                Url             = $Url
                ParsedRowCount  = 0
                Error           = "Header row not found in markdown table"
            }
        }
        
        # Parse header to find column indices
        $headerCols = $headerLine -split "\|"
        $headerCols = $headerCols | ForEach-Object { $_.Trim() }
        $headerCols = $headerCols | Where-Object { $_ }
        
        # Find "Planned Retirement Date" column index
        $dateColIdx = -1
        for ($i = 0; $i -lt $headerCols.Count; $i++) {
            if ($headerCols[$i] -like "*Planned*Retirement*Date*") {
                $dateColIdx = $i
                break
            }
        }
        
        if ($dateColIdx -lt 0) {
            Write-Log "Learn markdown: 'Planned Retirement Date' column not found. Headers: $($headerCols -join ' | ')" "ERROR"
            return [pscustomobject]@{
                Ok              = $false
                Series          = @()
                Url             = $Url
                ParsedRowCount  = 0
                Error           = "Planned Retirement Date column not found"
            }
        }
        
        # Parse data rows with per-row error handling
        $culture = [System.Globalization.CultureInfo]::new("en-US")
        $parsedRowCount = 0
        
        for ($i = $headerRowIdx + 2; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            
            # Skip empty lines and end of table
            if ([string]::IsNullOrWhiteSpace($line) -or -not ($line -like "|*")) {
                break
            }
            
            # Parse columns
            $cols = $line -split "\|"
            $cols = $cols | ForEach-Object { $_.Trim() }
            $cols = $cols | Where-Object { $_ }
            
            if ($cols.Count -eq 0) {
                continue
            }
            
            $seriesName = $cols[0]
            $dateStr = if ($cols.Count -gt $dateColIdx) { $cols[$dateColIdx] } else { "" }
            
            # Try to parse date (per-row error handling) — ONLY parsing logic
            $parseSuccess = $false
            $dt = $null
            
            try {
                $dt = [DateTime]::ParseExact($dateStr, "MM/dd/yy", $culture)
                $parseSuccess = $true
            }
            catch {
                Write-Log "Learn markdown parse error for series=$seriesName, date='$dateStr': $($_.Exception.Message)" "WARN"
            }
            
            # Logging is OUTSIDE the parse try/catch, so an error logging can never discard a parsed row
            if ($parseSuccess) {
                $retireOnIso = $dt.ToString("yyyy-MM-dd")
                $parsedRowCount++
                
                # Safe logging (error here won't discard data)
                Write-Log "Learn markdown parsed: series=$seriesName, date=$dateStr -> $retireOnIso" "DEBUG"
                
                $entries += [pscustomobject]@{
                    SeriesName         = $seriesName
                    Status             = "Announced"
                    RetireOn           = $retireOnIso
                    Announcement       = "Official Azure retirement announcement (Learn markdown)"
                    MigrationGuide     = "https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/retirement/retired-sizes-list"
                    Notes              = "LiveLearnMarkdown - SKU-family exposure (verify scope per-VM)"
                    MatchRegexes       = @()
                    Source             = "LiveLearnMarkdown"
                    SourceUrl          = $Url
                    AsOf               = (Get-Date).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                }
            }
        }
        
        if ($parsedRowCount -eq 0) {
            Write-Log "Learn markdown: 0 retirement rows parsed. Table structure may have changed." "WARN"
            return [pscustomobject]@{
                Ok              = $false
                Series          = @()
                Url             = $Url
                ParsedRowCount  = 0
                Error           = "No retirement rows parsed from Learn markdown. Table structure may have changed."
            }
        }
        
        Write-Log "Learn markdown parse succeeded: $parsedRowCount series retirement announcements fetched and parsed" "INFO"
        
        return [pscustomobject]@{
            Ok              = $true
            Series          = $entries
            Url             = $Url
            ParsedRowCount  = $parsedRowCount
            Error           = $null
        }
    }
    catch {
        $errMsg = $_.Exception.Message
        Write-Log "Learn markdown fetch/parse failed: $errMsg" "ERROR"
        Add-ApiCallLog -Api "Invoke-WebRequest" -Provider "Learn.Microsoft.Com" -TenantId $script:EffectiveTenantId -SubscriptionId "N/A" -Request "Retired VM Sizes Markdown" -StartedAt $fetchStart -EndedAt (Get-Date) -Success $false -ErrorMessage $errMsg
        
        return [pscustomobject]@{
            Ok              = $false
            Series          = @()
            Url             = $Url
            ParsedRowCount  = 0
            Error           = $errMsg
        }
    }
}

function Convert-SkuToSeriesKey {
    <#
    .SYNOPSIS
    Normalize a VM SKU name to the series key used in Learn retirement tables.
    
    .DESCRIPTION
    Maps Standard_D2_v2 → Dv2-series, Standard_A1_v2 → Av2/Amv2-series, etc.
    Used to match SKU against the Learn tables for retirement lookups.
    
    .OUTPUTS
    [string] series key (e.g., "Dv2-series") or $null if unrecognized.
    #>
    param([Parameter(Mandatory = $true)][string]$SkuName)
    
    $normalized = Normalize-SkuName $SkuName
    
    # Mapping table: normalized SKU pattern → Learn series key
    $mapping = @{
        "^standard_d\d+[a-z-]*_v2$"       = "Dv2-series"
        "^standard_ds\d+[a-z-]*_v2$"      = "Dsv2-series"
        "^standard_d\d+[a-z-]*(?!_v2)$"   = "D-series"
        "^standard_ds\d+[a-z-]*(?!_v2)$"  = "Ds-series"
        "^standard_l\d+[a-z-]*$"          = "Ls-series"
        "^standard_l\d+[a-z-]*_v2$"       = "Lsv2-series"
        "^standard_a\d+m?_v2$"            = "Av2/Amv2-series"
        "^standard_b\d+[a-z-]*$"          = "B-series (V1)"
        "^standard_f\d+[a-z-]*$"          = "F-series"
        "^standard_fs\d+[a-z-]*$"         = "Fs-series"
        "^standard_f\d+[a-z-]*_v2$"       = "Fsv2-series"
        "^standard_fs\d+[a-z-]*_v2$"      = "Fsv2-series"
        "^standard_g\d+[a-z-]*$"          = "G-series"
        "^standard_gs\d+[a-z-]*$"         = "Gs-series"
    }
    
    foreach ($pattern in $mapping.Keys) {
        if ($normalized -match $pattern) {
            return $mapping[$pattern]
        }
    }
    
    return $null  # SKU not in any retirement series
}

function Resolve-OfficialRetirementLiveOnly {
    <#
    .SYNOPSIS
    Resolve retirement signal for a SKU using LIVE sources only (ARG + Learn).
    
    .DESCRIPTION
    Priority:
    1. LiveAdvisorArg: per-resource Advisor recommendation (Stream A)
    2. LiveLearnMarkdown: SKU-family retirement from Learn (Stream B)
    
    **NO FALLBACK.** If neither source covers the SKU, return $null.
    If caller requires live and both sources are unavailable, **caller throws**.
    
    .OUTPUTS
    PSCustomObject or $null.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$SkuName,
        [Parameter(Mandatory = $false)][hashtable]$LiveAdvisorArgByResourceId = @{},
        [Parameter(Mandatory = $false)][object[]]$LiveLearnSeries = @()
    )
    
    $normalizedSku = Normalize-SkuName $SkuName
    
    # Priority 1: Check live Advisor ARG (per-resource, Stream A)
    # (This is checked per-VM-resource by caller, not here)
    
    # Priority 2: Check live Learn series (SKU-family, Stream B)
    $seriesKey = Convert-SkuToSeriesKey -SkuName $SkuName
    if ($seriesKey) {
        $seriesEntry = @($LiveLearnSeries | Where-Object { $_.SeriesName -eq $seriesKey }) | Select-Object -First 1
        if ($seriesEntry) {
            return [pscustomobject]@{
                Status         = "Announced"
                RetireOn       = $seriesEntry.RetireOn
                Source         = "LiveLearnMarkdown"
                SeriesName     = $seriesKey
                SourceUrl      = $seriesEntry.SourceUrl
                AsOf           = $seriesEntry.AsOf
                SourceGate     = "LiveLearnMarkdown"
                IsLive         = $true
            }
        }
    }
    
    # No signal: return null
    return $null
}
# ============================================================================

function Get-LiveRetirementsFromAdvisorArg {
    <#
    .SYNOPSIS
    Fetch retirement signals directly from Azure Advisor via ARG (advisorresources).
    Subcategory 'Service Upgrade and Retirement' + pattern match.
    
    .DESCRIPTION
    This is SOURCE 1 (primary): real retirement data from Azure Advisor in real-time.
    Matches per-resource (resourceId), returns RecId, TypeId, dates, feature names.
    If this succeeds, the exposure is backed by live Advisor signal, not hardcoded regex.
    
    .OUTPUTS
    PSCustomObject with properties:
    - ByVmResourceId : [hashtable] - keyed on VM resource ID
    - Series : [array] - series-level entries if available
    - IsLive : [bool] - true (confirms this is live source)
    #>
    param(
        [Parameter(Mandatory = $false)][string[]]$Subscriptions,
        [Parameter(Mandatory = $false)][string[]]$TypeIdBlocklist = @(),
        [Parameter(Mandatory = $false)][string]$NameBlockPattern = ''
    )

    $query = @"
AdvisorResources
| where type =~ 'microsoft.advisor/recommendations'
| extend category = tostring(properties.category)
| extend impact = tostring(properties.impact)
| extend recType = tostring(properties.recommendationTypeId)
| extend problem = tostring(properties.shortDescription.problem)
| extend solution = tostring(properties.shortDescription.solution)
| extend resourceId = tostring(properties.resourceMetadata.resourceId)
| extend ext = properties.extendedProperties
| extend recommendationSubCategory = tostring(ext.recommendationSubCategory)
| extend retirementDate = tostring(ext.retirementDate)
| extend retiringService = tostring(ext.retiringService)
| extend retiringFeature = tostring(ext.retiringFeature)
| where recommendationSubCategory =~ 'ServiceUpgradeAndRetirement' or isnotempty(retirementDate)
| project subscriptionId, advisorRecId = name, resourceId, category, impact, recType, recommendationSubCategory, problem, solution, retirementDate, retiringService, retiringFeature
"@

    $subList = @($Subscriptions)
    if (@($subList).Count -eq 0) {
        $ctx = Get-AzContext -ErrorAction SilentlyContinue
        if ($ctx -and $ctx.Subscription) {
            $subList = @([string]$ctx.Subscription.Id)
        }
    }

    $byVmResourceId = @{}
    $seriesEntries = @()
    $blockedTypeIds = @($TypeIdBlocklist | Where-Object { $_ } | ForEach-Object { $_.Trim().ToLowerInvariant() })
    $blockedCount = 0
    $monitoringLifecycle = New-Object 'System.Collections.Generic.List[object]'
    # Phase 3: the Service Upgrade and Retirement subcategory contains BOTH real retirements
    # (a retirementDate is present) and pure upgrade prompts (no retirementDate). Upgrade-only
    # signals are captured here and are NOT counted on the retirement path.
    $upgradeSignals = New-Object 'System.Collections.Generic.List[object]'
    $upgradeOnlyCount = 0

    foreach ($subId in $subList) {
        $pageSize = 1000
        $skipToken = $null
        do {
            $graphArgs = @{
                Query        = $query
                First        = $pageSize
                Subscription = [string]$subId
            }
            if ($skipToken) {
                $graphArgs["SkipToken"] = $skipToken
            }

            $searchStart = Get-Date
            try {
                $page = Search-AzGraph @graphArgs
                Add-ApiCallLog -Api "Search-AzGraph" -Provider "Az.ResourceGraph" -TenantId $script:EffectiveTenantId -SubscriptionId ([string]$subId) -Request "AdvisorResources (Live Retirement Source)" -StartedAt $searchStart -EndedAt (Get-Date) -Success $true -Meta @{ ReturnedRows = @($page).Count }
            }
            catch {
                Add-ApiCallLog -Api "Search-AzGraph" -Provider "Az.ResourceGraph" -TenantId $script:EffectiveTenantId -SubscriptionId ([string]$subId) -Request "AdvisorResources (Live)" -StartedAt $searchStart -EndedAt (Get-Date) -Success $false -ErrorMessage $_.Exception.Message
                Write-Log "Live retirement source (Advisor ARG) fetch failed on subscription ${subId}: $($_.Exception.Message)" "WARN"
                break
            }

            foreach ($r in @($page)) {
                $resourceId = if ($r.PSObject.Properties.Match("resourceId").Count -gt 0) { ([string]$r.resourceId).ToLowerInvariant() } else { "" }
                $retireOn = if ($r.PSObject.Properties.Match("retirementDate").Count -gt 0) { Format-NullableDate ([string]$r.retirementDate) } else { "N/A" }
                $advRecId = if ($r.PSObject.Properties.Match("advisorRecId").Count -gt 0 -and $r.advisorRecId) { [string]$r.advisorRecId } else { "N/A" }
                $advRecTypeId = if ($r.PSObject.Properties.Match("recType").Count -gt 0 -and $r.recType) { [string]$r.recType } else { "N/A" }
                $advSubCategory = if ($r.PSObject.Properties.Match("recommendationSubCategory").Count -gt 0 -and $r.recommendationSubCategory) { [string]$r.recommendationSubCategory } else { "N/A" }
                $problem = if ($r.PSObject.Properties.Match("problem").Count -gt 0) { [string]$r.problem } else { "" }
                $solution = if ($r.PSObject.Properties.Match("solution").Count -gt 0) { [string]$r.solution } else { "" }
                $retiringFeature = if ($r.PSObject.Properties.Match("retiringFeature").Count -gt 0) { [string]$r.retiringFeature } else { "" }
                $retiringService = if ($r.PSObject.Properties.Match("retiringService").Count -gt 0) { [string]$r.retiringService } else { "" }
                $advRecName = if (-not [string]::IsNullOrWhiteSpace($problem)) { $problem } elseif (-not [string]::IsNullOrWhiteSpace($retiringFeature)) { $retiringFeature } else { "N/A" }

                $typeIdBlocked = ($blockedTypeIds.Count -gt 0 -and ($advRecTypeId.ToLowerInvariant() -in $blockedTypeIds))
                $nameBlocked = ($NameBlockPattern -and (
                    ($advRecName -and $advRecName -match $NameBlockPattern) -or
                    ($problem -and $problem -match $NameBlockPattern) -or
                    ($solution -and $solution -match $NameBlockPattern) -or
                    ($retiringFeature -and $retiringFeature -match $NameBlockPattern) -or
                    ($retiringService -and $retiringService -match $NameBlockPattern)
                ))
                if ($typeIdBlocked -or $nameBlocked) {
                    $blockedCount++
                    if ($resourceId) {
                        $monitoringLifecycle.Add([pscustomobject]@{
                            ResourceId                  = $resourceId
                            RetireOn                    = $retireOn
                            AdvisorRecommendationId     = $advRecId
                            AdvisorRecommendationName   = $advRecName
                            AdvisorRecommendationTypeId = $advRecTypeId
                            AdvisorSubCategory          = $advSubCategory
                            Reason                      = if ($typeIdBlocked) { "TypeId blocklist" } else { "Name pattern" }
                        }) | Out-Null
                    }
                    continue
                }

                # Phase 3: a real retirement carries a retirement date; a pure upgrade prompt does not.
                # $retireOn is 'N/A' when the source retirementDate is empty (Format-NullableDate).
                $isRealRetirement = (-not [string]::IsNullOrWhiteSpace($retireOn)) -and ($retireOn -ne 'N/A')

                $entry = [pscustomobject]@{
                    Status                      = if ($isRealRetirement) { "Impacted" } else { "UpgradeSignal" }
                    ResourceId                  = $resourceId
                    SubscriptionId              = if ($r.PSObject.Properties.Match("subscriptionId").Count -gt 0) { [string]$r.subscriptionId } else { "" }
                    AdvisorRecommendationId     = $advRecId
                    AdvisorRecommendationTypeId = $advRecTypeId
                    AdvisorSubCategory          = $advSubCategory
                    Problem                     = $problem
                    Solution                    = $solution
                    RetireOn                    = $retireOn
                    RetiringService             = $retiringService
                    RetiringFeature             = $retiringFeature
                    Source                      = "LiveAdvisorArg"
                    SignalKind                  = if ($isRealRetirement) { "Retirement" } else { "UpgradeOnly" }
                    IsLive                      = $true
                }

                if ($resourceId) {
                    if ($isRealRetirement) {
                        if (-not $byVmResourceId.ContainsKey($resourceId)) {
                            $byVmResourceId[$resourceId] = $entry
                        }
                    }
                    else {
                        # Upgrade-only Advisor signal (no retirement date): recorded but not counted as a retirement.
                        $upgradeOnlyCount++
                        $upgradeSignals.Add($entry) | Out-Null
                    }
                }
            }

            $skipToken = if ($page) { $page.SkipToken } else { $null }
        } while ($skipToken)
    }

    if ($blockedCount -gt 0) {
        Write-Log ("Advisor retirement filter: excluded {0} operational/monitoring recommendation(s) (agent/VM Insights EOL) from SKU retirement signals." -f $blockedCount) "INFO"
    }
    if ($upgradeOnlyCount -gt 0) {
        Write-Log ("Advisor Service Upgrade and Retirement: {0} upgrade-only signal(s) (no retirement date) captured separately and NOT counted on the retirement path." -f $upgradeOnlyCount) "INFO"
    }

    return [pscustomobject]@{
        ByVmResourceId      = $byVmResourceId
        Series              = @($seriesEntries)
        MonitoringLifecycle = $monitoringLifecycle.ToArray()
        UpgradeSignals      = $upgradeSignals.ToArray()
        IsLive              = $true
    }
}

function Load-Retirements {
    <#
    .SYNOPSIS
    Load retirement data from LIVE sources only (no fallback).
    
    .DESCRIPTION
    Combines two live streams:
    - STREAM A: Live Advisor ARG (per-resource recommendations)
    - STREAM B: Live Microsoft Learn markdown (SKU-family retirement waves)
    
    Both are fetched; if both fail and $RequireLiveRetirementSource=true, script throws.
    If only one fails, logs WARN and returns the available stream.
    
    No hardcoded list fallback — all retirement data is live or absent.
    #>
    param(
        [Parameter(Mandatory = $false)][bool]$UseOfficialList = $true,
        [Parameter(Mandatory = $false)][bool]$UsePortalSource = $true,
        [Parameter(Mandatory = $false)][string[]]$Subscriptions,
        [Parameter(Mandatory = $false)][string[]]$AdvisorRetirementTypeIdBlocklist = @(),
        [Parameter(Mandatory = $false)][string]$AdvisorRetirementNameBlockPattern = '',
        [Parameter(Mandatory = $false)][bool]$RequireLiveRetirementSource = $false
    )

    Write-Log "Load-Retirements: Starting LIVE-ONLY mode (no fallback). Streams: ARG (per-resource) + Learn (SKU-family). RequireLiveRetirementSource=$RequireLiveRetirementSource" "INFO"

    $liveAdvisorArg = $null
    $liveAdvisorArgOk = $false
    $liveAdvisorArgError = $null
    
    $liveLearnMarkdown = $null
    $liveLearnMarkdownOk = $false
    $liveLearnMarkdownError = $null

    # ========================================
    # STREAM A: TRY LIVE ADVISOR ARG
    # ========================================
    if ($UsePortalSource) {
        Write-Log "Load-Retirements: Attempting STREAM A (live Advisor ARG)..." "INFO"
        try {
            $liveAdvisorArg = Get-LiveRetirementsFromAdvisorArg -Subscriptions $Subscriptions -TypeIdBlocklist $AdvisorRetirementTypeIdBlocklist -NameBlockPattern $AdvisorRetirementNameBlockPattern
            $liveAdvisorArgOk = $true
            # NOTE: ByVmResourceId is a HASHTABLE. @($hashtable).Count wraps it in a 1-element array and
            # always reports 1; use .Count (key count) so the log shows the true number of per-resource
            # retirement entries fetched (tenant-wide, BEFORE the inventory join that yields AdvisorConfirmed).
            $streamAPerResourceEntries = if ($liveAdvisorArg -and $liveAdvisorArg.ByVmResourceId) { $liveAdvisorArg.ByVmResourceId.Count } else { 0 }
            Write-Log "Load-Retirements: STREAM A succeeded. Per-resource entries (pre-inventory join): $streamAPerResourceEntries" "INFO"
        }
        catch {
            $liveAdvisorArgError = $_.Exception.Message
            $liveAdvisorArgOk = $false
            Write-Log "Load-Retirements: STREAM A failed: $liveAdvisorArgError" "WARN"
        }
    }

    # ========================================
    # STREAM B: TRY LIVE LEARN MARKDOWN
    # ========================================
    if ($UseOfficialList) {
        Write-Log "Load-Retirements: Attempting STREAM B (live Learn markdown)..." "INFO"
        $learnResult = Get-OfficialRetirementsFromLearnMarkdown
        if ($learnResult.Ok) {
            $liveLearnMarkdown = $learnResult
            $liveLearnMarkdownOk = $true
            Write-Log "Load-Retirements: STREAM B succeeded. Series: $(@($learnResult.Series).Count)" "INFO"
        }
        else {
            $liveLearnMarkdownError = $learnResult.Error
            $liveLearnMarkdownOk = $false
            Write-Log "Load-Retirements: STREAM B failed: $liveLearnMarkdownError" "WARN"
        }
    }

    # ========================================
    # CHECK REQUIREMENTS: Do we have the sources we need?
    # ========================================
    if ($RequireLiveRetirementSource -and -not $liveAdvisorArgOk -and -not $liveLearnMarkdownOk) {
        $msg = "FATAL: RequireLiveRetirementSource=true but both live sources failed. STREAM A error: $liveAdvisorArgError. STREAM B error: $liveLearnMarkdownError. No retirement data available; refusing to proceed."
        Write-Log $msg "ERROR"
        throw $msg
    }

    # ========================================
    # BUILD OUTPUT (combine both live streams)
    # ========================================
    $portalByVmResourceId = @{}
    $seriesEntries = @()
    $exact = @{}
    $monitoringLifecycle = @()

    # Add STREAM A entries (live Advisor ARG, per-resource)
    if ($liveAdvisorArgOk -and $liveAdvisorArg) {
        Write-Log "Load-Retirements: Adding STREAM A (Advisor ARG) entries..." "INFO"
        if ($liveAdvisorArg.PSObject.Properties.Match("ByVmResourceId").Count -gt 0 -and $liveAdvisorArg.ByVmResourceId) {
            $portalByVmResourceId = $liveAdvisorArg.ByVmResourceId
        }
        if ($liveAdvisorArg.PSObject.Properties.Match("Series").Count -gt 0 -and $liveAdvisorArg.Series) {
            $seriesEntries += @($liveAdvisorArg.Series)
        }
    }

    # Add STREAM B entries (live Learn markdown, SKU-family)
    if ($liveLearnMarkdownOk -and $liveLearnMarkdown) {
        Write-Log "Load-Retirements: Adding STREAM B (Learn markdown) entries..." "INFO"
        foreach ($entry in $liveLearnMarkdown.Series) {
            $seriesEntries += $entry
            $seriesKey = $entry.SeriesName
            if ($seriesKey) {
                $exact[$seriesKey] = [pscustomobject]@{
                    Status         = $entry.Status
                    RetireOn       = $entry.RetireOn
                    Notes          = $entry.Notes
                    Source         = "LiveLearnMarkdown"
                    SeriesName     = $entry.SeriesName
                    MigrationGuide = $entry.MigrationGuide
                    Announcement   = $entry.Announcement
                    SourceUrl      = $entry.SourceUrl
                    AsOf           = $entry.AsOf
                    SourceGate     = "LiveLearnMarkdown"
                    IsLive         = $true
                }
            }
        }
    }

    # Fetch monitoring lifecycle (via ARG if available)
    if ($liveAdvisorArgOk -and $liveAdvisorArg -and $liveAdvisorArg.PSObject.Properties.Match("MonitoringLifecycle").Count -gt 0) {
        $monitoringLifecycle = @($liveAdvisorArg.MonitoringLifecycle)
    }

    Write-Log "Load-Retirements: Complete. STREAM A OK=$liveAdvisorArgOk STREAM B OK=$liveLearnMarkdownOk. SeriesEntries=$(@($seriesEntries).Count) ByVmResourceId=$($portalByVmResourceId.Count) Exact=$($exact.Count)" "INFO"

    return [pscustomobject]@{
        Exact              = $exact
        Series             = @($seriesEntries)
        ByVmResourceId     = $portalByVmResourceId
        MonitoringLifecycle = @($monitoringLifecycle)
        StreamAOk          = $liveAdvisorArgOk
        StreamBOk          = $liveLearnMarkdownOk
        StreamAError       = $liveAdvisorArgError
        StreamBError       = $liveLearnMarkdownError
    }
}

function Resolve-RetirementForVmOrSku {
    param(
        [Parameter(Mandatory = $true)]$Vm,
        [Parameter(Mandatory = $false)]$Retirements
    )

    if (-not $Retirements) { return $null }

    $resourceId = ("/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.Compute/virtualMachines/{2}" -f [string]$Vm.SubscriptionId, [string]$Vm.ResourceGroup, [string]$Vm.VmName).ToLowerInvariant()
    if ($Retirements.PSObject.Properties.Match("ByVmResourceId").Count -gt 0 -and $Retirements.ByVmResourceId) {
        if ($Retirements.ByVmResourceId.ContainsKey($resourceId)) {
            return $Retirements.ByVmResourceId[$resourceId]
        }
    }

    return Resolve-RetirementForSku -SkuName ([string]$Vm.VmSize) -Retirements $Retirements
}

function Resolve-RetirementForSku {
    param(
        [Parameter(Mandatory = $true)][string]$SkuName,
        [Parameter(Mandatory = $false)]$Retirements
    )

    if (-not $Retirements) { return $null }

    $normalizedSku = Normalize-SkuName $SkuName
    if ($Retirements.PSObject.Properties.Match("Exact").Count -gt 0 -and $Retirements.Exact) {
        if ($Retirements.Exact.ContainsKey($normalizedSku)) {
            return $Retirements.Exact[$normalizedSku]
        }
    }

    if ($Retirements.PSObject.Properties.Match("Series").Count -gt 0 -and $Retirements.Series) {
        foreach ($entry in $Retirements.Series) {
            $regexes = @()
            if ($entry.PSObject.Properties.Match("MatchRegexes").Count -gt 0) {
                $regexes = @($entry.MatchRegexes)
            }

            foreach ($rx in $regexes) {
                if ([string]::IsNullOrWhiteSpace([string]$rx)) { continue }
                if ($normalizedSku -match $rx) {
                    return [pscustomobject]@{
                        Status         = [string]$entry.Status
                        RetireOn       = [string]$entry.RetireOn
                        Notes          = [string]$entry.Notes
                        Source         = "OfficialMicrosoftLearn"
                        SeriesName     = [string]$entry.SeriesName
                        MigrationGuide = [string]$entry.MigrationGuide
                        Announcement   = [string]$entry.Announcement
                    }
                }
            }
        }
    }

    return $null
}

function Get-AdvisorHintsForVm {
    param(
        [Parameter(Mandatory = $true)]$Vm,
        [Parameter(Mandatory = $false)][object[]]$AdvisorHints = @()
    )

    if (-not $AdvisorHints -or $AdvisorHints.Count -eq 0) { 
        return @() 
    }

    # Build resource ID for matching
    $vmResourceId = ("/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.Compute/virtualMachines/{2}" -f [string]$Vm.SubscriptionId, [string]$Vm.ResourceGroup, [string]$Vm.VmName).ToLowerInvariant()
    
    # Find matching Advisor hints for this VM
    $matchingHints = @($AdvisorHints | Where-Object {
        if ($_ -and $_.PSObject.Properties.Match("ResourceId").Count -gt 0 -and $_.ResourceId) {
            ([string]$_.ResourceId).ToLowerInvariant() -eq $vmResourceId
        } else {
            $false
        }
    })
    
    return $matchingHints
}

function Save-Snapshot {
    param(
        [Parameter(Mandatory = $true)][string]$SnapshotDir,
        [Parameter(Mandatory = $true)][object[]]$Inventory,
        [Parameter(Mandatory = $false)][hashtable]$PriceMap
    )

    Ensure-Directory -Path $SnapshotDir
    $snapshotDate = Get-Date -Format "yyyy-MM-dd"
    $snapshotPath = Join-Path $SnapshotDir ("sku_snapshot_{0}.json" -f $snapshotDate)

    $rows = foreach ($i in $Inventory) {
        $key = "{0}|{1}" -f $i.VmSize, $i.Location
        $price = $null
        if ($PriceMap -and $PriceMap.ContainsKey($key)) {
            $price = $PriceMap[$key].UnitPrice
        }

        [pscustomobject]@{
            Date          = $snapshotDate
            Subscription  = $i.SubscriptionId
            Region        = $i.Location
            VmSize        = $i.VmSize
            VmName        = $i.VmName
            VmCreatedDate = $i.VmCreatedDate
            UnitPrice     = $price
        }
    }

    $rows | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $snapshotPath -Encoding UTF8
    return $snapshotPath
}

function Get-FirstSeenDates {
    param(
        [Parameter(Mandatory = $true)][string]$SnapshotDir,
        [Parameter(Mandatory = $true)][object[]]$CurrentInventory
    )

    $firstSeen = @{}
    if (-not (Test-Path -LiteralPath $SnapshotDir)) {
        return $firstSeen
    }

    $files = Get-ChildItem -LiteralPath $SnapshotDir -Filter "sku_snapshot_*.json" -File | Sort-Object Name
    $totalFiles = @($files).Count
    $fileIdx = 0
    foreach ($f in $files) {
        $fileIdx++
        $filePct = if ($totalFiles -gt 0) { [int][math]::Round(($fileIdx / $totalFiles) * 100, 0) } else { 100 }
        Write-Progress -Id 15 -ParentId 1 -Activity "First-seen date" -Status "Reading snapshot $fileIdx/$totalFiles" -PercentComplete $filePct

        try {
            $data = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
        }
        catch {
            Write-Log "Snapshot not readable: $($f.FullName)" "WARN"
            continue
        }

        foreach ($row in $data) {
            if (-not $row.VmSize -or -not $row.Region -or -not $row.Date) { continue }
            $k = "{0}|{1}" -f [string]$row.VmSize, (Normalize-Location ([string]$row.Region))
            $d = Get-Date ([string]$row.Date)

            if (-not $firstSeen.ContainsKey($k) -or $d -lt $firstSeen[$k]) {
                $firstSeen[$k] = $d
            }
        }
    }

    $today = Get-Date
    $totalInv = @($CurrentInventory).Count
    $invIdx = 0
    foreach ($i in $CurrentInventory) {
        $invIdx++
        $invPct = if ($totalInv -gt 0) { [int][math]::Round(($invIdx / $totalInv) * 100, 0) } else { 100 }
        Write-Progress -Id 15 -ParentId 1 -Activity "First-seen date" -Status "Completing current map $invIdx/$totalInv" -PercentComplete $invPct

        $k = "{0}|{1}" -f $i.VmSize, $i.Location
        if (-not $firstSeen.ContainsKey($k)) {
            $firstSeen[$k] = $today
        }
    }

    Write-Progress -Id 15 -ParentId 1 -Activity "First-seen date" -Status "Completed" -Completed

    return $firstSeen
}

function Get-CapBool {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Cap,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if (-not $Cap.ContainsKey($Name)) { return $false }
    $v = [string]$Cap[$Name]
    return $v -in @("True", "true", "1", "Yes", "yes")
}

function Get-CapNumber {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Cap,
        [Parameter(Mandatory = $true)][string]$Name,
        [double]$Default = 0
    )

    if (-not $Cap.ContainsKey($Name)) { return $Default }
    $s = [string]$Cap[$Name]
    $n = 0.0
    if ([double]::TryParse($s, [ref]$n)) {
        return $n
    }

    return $Default
}

function Get-CapString {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Cap,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Default = "N/A"
    )

    if (-not $Cap.ContainsKey($Name)) { return $Default }
    $s = [string]$Cap[$Name]
    if ([string]::IsNullOrWhiteSpace($s)) { return $Default }
    return $s
}

function Get-SkuShapeKey {
    param([Parameter(Mandatory = $true)][string]$SkuName)

    $n = Normalize-SkuName $SkuName
    $m = [regex]::Match($n, "^standard_(?<series>[a-z]+)(?<size>\d+)[a-z]*(?:_v\d+)?$", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($m.Success) {
        return ("{0}{1}" -f $m.Groups["series"].Value.ToLowerInvariant(), $m.Groups["size"].Value)
    }

    return $n
}

function Get-Architecture {
    param([Parameter(Mandatory = $true)][hashtable]$Cap)

    if ($Cap.ContainsKey("CpuArchitectureType")) {
        return [string]$Cap["CpuArchitectureType"]
    }

    return "Unknown"
}

function Get-PerformanceModelResult {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Cap,
        [Parameter(Mandatory = $false)][string]$VmSize = "",
        [Parameter(Mandatory = $false)][bool]$PreferAcu = $true
    )

    $vcpu = Get-CapNumber -Cap $Cap -Name "vCPUs" -Default 0
    $mem = Get-CapNumber -Cap $Cap -Name "MemoryGB" -Default 0
    $acu = Get-CapNumber -Cap $Cap -Name "ACUs" -Default 0
    $cachedIops = Get-CapNumber -Cap $Cap -Name "CombinedTempDiskAndCachedIOPS" -Default 0
    $uncachedIops = Get-CapNumber -Cap $Cap -Name "UncachedDiskIOPS" -Default 0

    if ($vcpu -eq 0 -and $mem -eq 0) {
        return [pscustomobject]@{
            Index  = 0.0
            Method = "NoPerfData*"
        }
    }

    $archMultiplier = 1.0
    $arch = Get-Architecture -Cap $Cap
    if ($arch -eq "Arm64") {
        $archMultiplier = 1.05
    }

    if ($PreferAcu -and $acu -gt 0) {
        # Prefer ACUs when available: they provide an official CPU-comparative baseline.
        $cpuComponent = $vcpu * $acu
        $memComponent = $mem * 25.0
        $iopsRaw = [math]::Max($cachedIops, $uncachedIops)
        $iopsComponent = [math]::Min(250.0, ($iopsRaw / 40.0))
        $indexAcu = [math]::Round(($cpuComponent + $memComponent + $iopsComponent) * $archMultiplier, 3)

        return [pscustomobject]@{
            Index  = $indexAcu
            Method = "ACUComposite_v1*"
        }
    }

    $version = 1
    if (-not [string]::IsNullOrWhiteSpace($VmSize)) {
        $version = Get-VersionFromVmSize -VmSize $VmSize
    }

    # Newer generations generally provide faster CPU and memory subsystems.
    $memoryWeight = 0.25
    if ($version -ge 7) { $memoryWeight = 0.33 }
    elseif ($version -ge 6) { $memoryWeight = 0.31 }
    elseif ($version -ge 5) { $memoryWeight = 0.29 }

    $base = ($vcpu * 1.0) + ($mem * $memoryWeight)

    $cpuGenerationMultiplier = 1.0
    if ($version -ge 7) { $cpuGenerationMultiplier = 1.20 }
    elseif ($version -ge 6) { $cpuGenerationMultiplier = 1.15 }
    elseif ($version -ge 5) { $cpuGenerationMultiplier = 1.10 }
    elseif ($version -ge 4) { $cpuGenerationMultiplier = 1.06 }
    elseif ($version -ge 3) { $cpuGenerationMultiplier = 1.03 }

    $indexFallback = [math]::Round($base * $cpuGenerationMultiplier * $archMultiplier, 3)

    return [pscustomobject]@{
        Index  = $indexFallback
        Method = "GenAwareHeuristic_v2*"
    }
}

function Get-ModernFeatureScore {
    param([Parameter(Mandatory = $true)][hashtable]$Cap)

    $checks = @(
        (Get-CapBool -Cap $Cap -Name "EphemeralOSDiskSupported"),
        (Get-CapBool -Cap $Cap -Name "AcceleratedNetworkingEnabled"),
        (Get-CapBool -Cap $Cap -Name "PremiumIO"),
        (Get-CapBool -Cap $Cap -Name "EncryptionAtHostSupported"),
        (Get-CapBool -Cap $Cap -Name "UltraSSDAvailable")
    )

    $gen2 = $false
    if ($Cap.ContainsKey("HyperVGenerations")) {
        $gen2 = ([string]$Cap["HyperVGenerations"]).ToUpperInvariant().Contains("V2")
    }
    $checks += $gen2

    $total = @($checks).Count
    $positive = @($checks | Where-Object { $_ -eq $true }).Count

    if ($total -eq 0) { return 0 }
    return [math]::Round(($positive / $total) * 100, 2)
}

function Get-MigrationPriority {
    param(
        [double]$CostDeltaPercent,
        [int]$VersionGap
    )

    if ($VersionGap -ge 2) {
        if ($CostDeltaPercent -le 10) { return "High" }
        return "Medium"
    }

    if ($VersionGap -eq 1) {
        if ($CostDeltaPercent -le 5) { return "Medium" }
        return "Low"
    }

    return "Low"
}

function Get-MigrationRiskList {
    param(
        [Parameter(Mandatory = $true)][hashtable]$CurrentCap,
        [Parameter(Mandatory = $true)][hashtable]$CandidateCap,
        [Parameter(Mandatory = $true)][string]$CurrentArch,
        [Parameter(Mandatory = $true)][string]$CandidateArch
    )

    $risks = @()

    $risks += "Technical workload/extension compatibility: verify kernel support, VM agent and marketplace images"

    if ($CurrentArch -ne "Unknown" -and $CandidateArch -ne "Unknown" -and $CurrentArch -ne $CandidateArch) {
        $risks += "CPU architecture change ($CurrentArch -> $CandidateArch): validate binaries, native libraries and toolchain"
    }
    else {
        $risks += "CPU/architecture differences: confirm x64/Arm compatibility even if the SKU does not change"
    }

    $risks += "Disk/network/zone constraints: check Premium SSD, Ultra SSD, accelerated networking, zone support"
    $risks += "Software and driver dependencies: plan application tests, security and monitoring drivers"
    $risks += "Downtime and cutover: define maintenance window and blue/green or side-by-side strategy"
    $risks += "Rollback plan: snapshot/managed disks + fast rollback procedure"
    $risks += "One-time costs: operational effort, testing, possible re-licensing and pipeline updates"

    return $risks
}

function Get-DateDiffDays {
    param(
        [Parameter(Mandatory = $false)][string]$FromDate,
        [Parameter(Mandatory = $false)][string]$ToDate
    )

    $d1 = [datetime]::MinValue
    $d2 = [datetime]::MinValue
    if (-not [datetime]::TryParse([string]$FromDate, [ref]$d1)) { return $null }
    if (-not [datetime]::TryParse([string]$ToDate, [ref]$d2)) { return $null }

    return [int][math]::Round(($d2 - $d1).TotalDays, 0)
}

function Get-SupportHorizonOutcome {
    param([Parameter(Mandatory = $false)]$DeltaDays)

    if ($null -eq $DeltaDays) { return "Unknown" }
    if ([int]$DeltaDays -gt 0) { return "Extended" }
    if ([int]$DeltaDays -lt 0) { return "Reduced" }
    return "Unchanged"
}

function Get-CommitmentSupportForSkuRegion {
    param(
        [Parameter(Mandatory = $true)][string]$SkuName,
        [Parameter(Mandatory = $true)][string]$Region,
        [Parameter(Mandatory = $false)][hashtable]$CommitmentMap
    )

    if (-not $CommitmentMap) {
        return [pscustomobject]@{
            SupportsReservedInstance      = $false
            SupportsSavingsPlan           = $false
            ReservedInstanceFirstSeenDate = "N/A"
            SavingsPlanFirstSeenDate      = "N/A"
        }
    }

    $key = "{0}|{1}" -f [string]$SkuName, (Normalize-Location ([string]$Region))
    if ($CommitmentMap.ContainsKey($key)) {
        return $CommitmentMap[$key]
    }

    return [pscustomobject]@{
        SupportsReservedInstance      = $false
        SupportsSavingsPlan           = $false
        ReservedInstanceFirstSeenDate = "N/A"
        SavingsPlanFirstSeenDate      = "N/A"
    }
}

function Test-CandidateTechnicalCompatibility {
    param(
        [Parameter(Mandatory = $true)]$CurrentCap,
        [Parameter(Mandatory = $true)]$CandidateCap,
        [Parameter(Mandatory = $true)][double]$CurrentVcpu,
        [Parameter(Mandatory = $true)][double]$CurrentMemGb,
        [Parameter(Mandatory = $false)][double]$VcpuTolerancePercent = 15,
        [Parameter(Mandatory = $false)][double]$MemoryTolerancePercent = 20,
        [Parameter(Mandatory = $false)][switch]$IgnoreNicRegression
    )

    $currCapHash = @{}
    if ($CurrentCap -is [hashtable]) {
        $currCapHash = $CurrentCap
    }
    elseif ($CurrentCap) {
        foreach ($p in $CurrentCap.PSObject.Properties) {
            $currCapHash[[string]$p.Name] = [string]$p.Value
        }
    }

    $candCapHash = @{}
    if ($CandidateCap -is [hashtable]) {
        $candCapHash = $CandidateCap
    }
    elseif ($CandidateCap) {
        foreach ($p in $CandidateCap.PSObject.Properties) {
            $candCapHash[[string]$p.Name] = [string]$p.Value
        }
    }

    $candVcpu = Get-CapNumber -Cap $candCapHash -Name "vCPUs" -Default 0
    $candMem = Get-CapNumber -Cap $candCapHash -Name "MemoryGB" -Default 0

    $vcpuTolRatio = [math]::Max(0.0, [double]$VcpuTolerancePercent / 100.0)
    $memTolRatio = [math]::Max(0.0, [double]$MemoryTolerancePercent / 100.0)
    if ($CurrentVcpu -gt 0) {
        $vcpuDiffRatio = [math]::Abs(($candVcpu - $CurrentVcpu) / $CurrentVcpu)
        if ($vcpuDiffRatio -gt $vcpuTolRatio) { return $false }
    }
    if ($CurrentMemGb -gt 0) {
        $memDiffRatio = [math]::Abs(($candMem - $CurrentMemGb) / $CurrentMemGb)
        if ($memDiffRatio -gt $memTolRatio) { return $false }
    }

    $currMaxDisks = Get-CapNumber -Cap $currCapHash -Name "MaxDataDiskCount" -Default 0
    $candMaxDisks = Get-CapNumber -Cap $candCapHash -Name "MaxDataDiskCount" -Default 0
    if ($currMaxDisks -gt 0 -and $candMaxDisks -lt $currMaxDisks) { return $false }

    if ((Get-CapBool -Cap $currCapHash -Name "PremiumIO") -and (-not (Get-CapBool -Cap $candCapHash -Name "PremiumIO"))) { return $false }
    if ((Get-CapBool -Cap $currCapHash -Name "UltraSSDAvailable") -and (-not (Get-CapBool -Cap $candCapHash -Name "UltraSSDAvailable"))) { return $false }

    $currMaxNics = Get-CapNumber -Cap $currCapHash -Name "MaxNetworkInterfaces" -Default 0
    $candMaxNics = Get-CapNumber -Cap $candCapHash -Name "MaxNetworkInterfaces" -Default 0
    if (-not $IgnoreNicRegression) {
        if ($currMaxNics -gt 0 -and $candMaxNics -lt $currMaxNics) { return $false }
    }

    if ((Get-CapBool -Cap $currCapHash -Name "AcceleratedNetworkingEnabled") -and (-not (Get-CapBool -Cap $candCapHash -Name "AcceleratedNetworkingEnabled"))) { return $false }

    return $true
}

function Get-RetirementEvidence {
    param([Parameter(Mandatory = $false)]$RetirementEntry)

    if (-not $RetirementEntry) {
        return [pscustomobject]@{
            EvidenceType = "NoAnnouncedRetirementFound"
            Confidence   = "N/A"
        }
    }

    $source = ""
    if ($RetirementEntry.PSObject.Properties.Match("Source").Count -gt 0 -and $RetirementEntry.Source) {
        $source = [string]$RetirementEntry.Source
    }

    switch -Regex ($source) {
        "OfficialMicrosoftLearn|LiveLearnMarkdown" { return [pscustomobject]@{ EvidenceType = "PublicOfficialAnnouncement"; Confidence = "High" } }
        "LiveAdvisorArg" { return [pscustomobject]@{ EvidenceType = "TenantSpecificAdvisorSignal"; Confidence = "High" } }
        default { return [pscustomobject]@{ EvidenceType = "UnknownSource"; Confidence = "Low" } }
    }
}

function Test-IsBurstableSku {
    param([Parameter(Mandatory = $true)][string]$SkuName)

    $n = (Normalize-SkuName $SkuName)
    # Standard_B... family (burstable). Matches B1s, B2ms, B4ms, B2s_v2, B4as_v2, Bpsv2, etc.
    return ($n -match '^standard_b[0-9]')
}

function Get-WorkloadRole {
    param(
        [Parameter(Mandatory = $true)][string]$VmName,
        [Parameter(Mandatory = $false)][string]$TagsText = "",
        [Parameter(Mandatory = $false)][string]$ExtensionsText = ""
    )

    $n = $VmName.ToLowerInvariant()
    $tags = ([string]$TagsText).ToLowerInvariant()
    $ext = ([string]$ExtensionsText).ToLowerInvariant()
    $combined = "$n `n$tags `n$ext"

    # Signals from installed extensions (strong indicators of workload type).
    if ($ext -match "microsoft\.azureadconnect|aadconnecthealth|adsync") {
        return [pscustomobject]@{ Role = "Identity-DirectorySync"; Conservative = $true; Source = "extension" }
    }
    if ($ext -match "sqliaasextension|sqlserver") {
        return [pscustomobject]@{ Role = "Data-SQLServer"; Conservative = $true; Source = "extension" }
    }

    # Signals from tags (role/workload/function/app tags).
    if ($tags -match "domain\s*controller|\bdc\b|active\s*directory|\bad\b") {
        return [pscustomobject]@{ Role = "Infrastructure-DomainController"; Conservative = $true; Source = "tag" }
    }
    if ($tags -match "adfs|federation") {
        return [pscustomobject]@{ Role = "Identity-ADFS"; Conservative = $true; Source = "tag" }
    }
    if ($tags -match "sql|database|dbms") {
        return [pscustomobject]@{ Role = "Data-SQLServer"; Conservative = $true; Source = "tag" }
    }
    if ($tags -match "firewall|gateway|\bnva\b|network|hub") {
        return [pscustomobject]@{ Role = "Network-Hub"; Conservative = $true; Source = "tag" }
    }

    # Fallback: name-based heuristics (weakest signal).
    if ($n -match "(^|[-_])dc(\d+)?([-_]|$)|domaincontroller|addc") {
        return [pscustomobject]@{ Role = "Infrastructure-DomainController"; Conservative = $true; Source = "name" }
    }
    if ($n -match "adfs|sts|federation") {
        return [pscustomobject]@{ Role = "Identity-ADFS"; Conservative = $true; Source = "name" }
    }
    if ($n -match "adcon|adsync|aadconnect|entraconnect") {
        return [pscustomobject]@{ Role = "Identity-DirectorySync"; Conservative = $true; Source = "name" }
    }
    if ($n -match "(^|[-_])hub([-_]|$)|firewall|gateway|nva|vpn") {
        return [pscustomobject]@{ Role = "Network-Hub"; Conservative = $true; Source = "name" }
    }
    if ($n -match "sql|mysql|postgres") {
        return [pscustomobject]@{ Role = "Data-SQLServer"; Conservative = $true; Source = "name" }
    }

    return [pscustomobject]@{ Role = "GeneralCompute"; Conservative = $false; Source = "default" }
}

function Get-RetirementRisk {
    param(
        [Parameter(Mandatory = $false)]$RetirementEntry,
        [Parameter(Mandatory = $false)][string]$EvidenceType = "NoAnnouncedRetirementFound",
        [Parameter(Mandatory = $true)][int]$CurrentVersion
    )

    $daysToRetire = $null
    if ($RetirementEntry -and $RetirementEntry.PSObject.Properties.Match("RetireOn").Count -gt 0 -and $RetirementEntry.RetireOn) {
        $rd = [datetime]::MinValue
        if ([datetime]::TryParse([string]$RetirementEntry.RetireOn, [ref]$rd)) {
            $daysToRetire = [int][math]::Round(($rd - (Get-Date)).TotalDays, 0)
        }
    }

    $hasOfficial = ($EvidenceType -eq "PublicOfficialAnnouncement")

    if ($null -ne $daysToRetire -and $hasOfficial) {
        if ($daysToRetire -le 365) { return [pscustomobject]@{ Level = "Critical"; Reason = "Official retirement within 12 months" } }
        if ($daysToRetire -le 730) { return [pscustomobject]@{ Level = "High"; Reason = "Official retirement within 24 months" } }
        return [pscustomobject]@{ Level = "Medium"; Reason = "Official retirement announced beyond 24 months" }
    }

    if ($null -ne $daysToRetire -and -not $hasOfficial) {
        return [pscustomobject]@{ Level = "Watch"; Reason = "Non-official retirement signal (advisor/tenant)" }
    }

    if ($CurrentVersion -le 2) {
        return [pscustomobject]@{ Level = "Medium"; Reason = "Dated generation without announced retirement" }
    }

    return [pscustomobject]@{ Level = "Low"; Reason = "No announced retirement and recent generation" }
}

function Get-RecommendationBasis {
    param(
        [Parameter(Mandatory = $false)][string]$CandidateStrategy = ""
    )

    switch ($CandidateStrategy) {
        "same-family"              { return "Rule-based: same family / same workload model" }
        "same-shape-newer-version" { return "Same-shape refresh: same vCPU/RAM profile but newer generation" }
        "burstable-modernization"  { return "Rule-based: burstable continuity (same CPU credit model)" }
        "nearby-family-compatible" { return "Heuristic: cross-family migration (requires architecture validation)" }
        default                    { return "Unknown / no candidate" }
    }
}

function Get-HeuristicLevel {
    param(
        [Parameter(Mandatory = $false)][string]$CandidateStrategy = "",
        [Parameter(Mandatory = $false)][double]$CompatibilityScore = $null
    )

    if (-not $CandidateStrategy) { return "N/A" }

    $baseLevel = switch ($CandidateStrategy) {
        "same-family"              { "Low" }
        "burstable-modernization"  { "Low" }
        "same-shape-newer-version" { "Medium" }
        "nearby-family-compatible" { "High" }
        default                    { "Medium" }
    }

    # Adjust down if compatibility is very low
    if ($null -ne $CompatibilityScore -and $CompatibilityScore -lt 50 -and $baseLevel -eq "Medium") {
        return "High"
    }
    return $baseLevel
}

function Get-FinancialValidationStatusLabel {
    param(
        [Parameter(Mandatory = $false)][string]$FinancialValidationStatus = "",
        [Parameter(Mandatory = $false)][bool]$CostDeltaPublishable = $false
    )

    if ($FinancialValidationStatus -eq "FullyValidated") {
        return "Fully validated (PAYG + Cost Management + RI/SP)"
    }
    elseif ($FinancialValidationStatus -eq "ValidatedPayG" -and $CostDeltaPublishable) {
        return "Indicative: PAYG retail comparison available. Cost Management, RI, Savings Plan and Azure Hybrid Benefit coverage not evaluated."
    }
    else {
        return "Not validated: Cost Management, RI, Savings Plan and Azure Hybrid Benefit coverage not yet checked."
    }
}

function Get-ObjectPropertyValue {
    param(
        [Parameter(Mandatory = $false)]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Object) { return $null }

    if ($Object -is [hashtable]) {
        if ($Object.ContainsKey($Name)) {
            return $Object[$Name]
        }
        return $null
    }

    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) {
        return $prop.Value
    }

    return $null
}

function Get-CatalogOptimizationContext {
    param([Parameter(Mandatory = $true)][object[]]$Catalog)

    $byName = @{}
    $byFamilyLoc = @{}
    $byFamilyLocArch = @{}
    $byShapeLoc = @{}
    $byShapeLocArch = @{}

    foreach ($c in $Catalog) {
        $perfRes = Get-PerformanceModelResult -Cap $c.Cap -VmSize ([string]$c.Name)

        $entry = [pscustomobject]@{
            Name         = [string]$c.Name
            Family       = [string]$c.Family
            Tier         = [string]$c.Tier
            Size         = [string]$c.Size
            ShapeKey     = Get-SkuShapeKey -SkuName ([string]$c.Name)
            Locations    = @($c.Locations)
            Cap          = $c.Cap
            Restrictions = $c.Restrictions
            LocationInfo = if ($c.PSObject.Properties.Match("LocationInfo").Count -gt 0) { $c.LocationInfo } else { $null }
            Arch         = Get-Architecture -Cap $c.Cap
            Version      = Get-VersionFromVmSize -VmSize ([string]$c.Name)
            FeatureScore = Get-ModernFeatureScore -Cap $c.Cap
            PerfIndex    = [double]$perfRes.Index
            PerfModel    = [string]$perfRes.Method
        }

        if (-not $byName.ContainsKey($entry.Name)) {
            $byName[$entry.Name] = New-Object 'System.Collections.Generic.List[object]'
        }
        $byName[$entry.Name].Add($entry)

        foreach ($loc in @($entry.Locations)) {
            $famLocKey = "{0}|{1}" -f $entry.Family, $loc
            if (-not $byFamilyLoc.ContainsKey($famLocKey)) {
                $byFamilyLoc[$famLocKey] = New-Object 'System.Collections.Generic.List[object]'
            }
            $byFamilyLoc[$famLocKey].Add($entry)

            $famLocArchKey = "{0}|{1}|{2}" -f $entry.Family, $loc, $entry.Arch
            if (-not $byFamilyLocArch.ContainsKey($famLocArchKey)) {
                $byFamilyLocArch[$famLocArchKey] = New-Object 'System.Collections.Generic.List[object]'
            }
            $byFamilyLocArch[$famLocArchKey].Add($entry)

            $shapeLocKey = "{0}|{1}" -f $entry.ShapeKey, $loc
            if (-not $byShapeLoc.ContainsKey($shapeLocKey)) {
                $byShapeLoc[$shapeLocKey] = New-Object 'System.Collections.Generic.List[object]'
            }
            $byShapeLoc[$shapeLocKey].Add($entry)

            $shapeLocArchKey = "{0}|{1}|{2}" -f $entry.ShapeKey, $loc, $entry.Arch
            if (-not $byShapeLocArch.ContainsKey($shapeLocArchKey)) {
                $byShapeLocArch[$shapeLocArchKey] = New-Object 'System.Collections.Generic.List[object]'
            }
            $byShapeLocArch[$shapeLocArchKey].Add($entry)
        }
    }

    $familyLocKeys = New-Object 'System.Collections.Generic.List[string]'
    foreach ($k in $byFamilyLoc.Keys) {
        $familyLocKeys.Add([string]$k)
    }
    foreach ($key in $familyLocKeys) {
        $byFamilyLoc[$key] = ($byFamilyLoc[$key] | Sort-Object @{ Expression = "Version"; Descending = $true }, @{ Expression = "FeatureScore"; Descending = $true })
    }

    $familyLocArchKeys = New-Object 'System.Collections.Generic.List[string]'
    foreach ($k in $byFamilyLocArch.Keys) {
        $familyLocArchKeys.Add([string]$k)
    }
    foreach ($key in $familyLocArchKeys) {
        $byFamilyLocArch[$key] = ($byFamilyLocArch[$key] | Sort-Object @{ Expression = "Version"; Descending = $true }, @{ Expression = "FeatureScore"; Descending = $true })
    }

    $shapeLocKeys = New-Object 'System.Collections.Generic.List[string]'
    foreach ($k in $byShapeLoc.Keys) {
        $shapeLocKeys.Add([string]$k)
    }
    foreach ($key in $shapeLocKeys) {
        $byShapeLoc[$key] = ($byShapeLoc[$key] | Sort-Object @{ Expression = "Version"; Descending = $true }, @{ Expression = "FeatureScore"; Descending = $true })
    }

    $shapeLocArchKeys = New-Object 'System.Collections.Generic.List[string]'
    foreach ($k in $byShapeLocArch.Keys) {
        $shapeLocArchKeys.Add([string]$k)
    }
    foreach ($key in $shapeLocArchKeys) {
        $byShapeLocArch[$key] = ($byShapeLocArch[$key] | Sort-Object @{ Expression = "Version"; Descending = $true }, @{ Expression = "FeatureScore"; Descending = $true })
    }

    return [pscustomobject]@{
        ByName          = $byName
        ByFamilyLoc     = $byFamilyLoc
        ByFamilyLocArch = $byFamilyLocArch
        ByShapeLoc      = $byShapeLoc
        ByShapeLocArch  = $byShapeLocArch
    }
}

function Build-Recommendations {
    param(
        [Parameter(Mandatory = $true)][object[]]$Inventory,
        [Parameter(Mandatory = $true)][object[]]$Catalog,
        [Parameter(Mandatory = $true)][hashtable]$PriceMap,
        [Parameter(Mandatory = $false)][hashtable]$CommitmentMap,
        [Parameter(Mandatory = $true)][hashtable]$FirstSeenMap,
        [Parameter(Mandatory = $true)]$Retirements,
        [Parameter(Mandatory = $false)][object[]]$AdvisorHints = @(),
        [int]$Top = 3,
        [switch]$AllowArchChange,
        [double]$MaxVcpuIncreaseRatio = 1.5,
        [double]$MaxMemoryIncreaseRatio = 1.5,
        [double]$MaxCostIncreasePercent = 20,
        [double]$MinPerfRatio = 0.95,
        [double]$EquivalentVcpuTolerancePercent = 15,
        [double]$EquivalentMemoryTolerancePercent = 20
    )

    $catalogCtx = Get-CatalogOptimizationContext -Catalog $Catalog
    $catalogByName = $catalogCtx.ByName
    $catalogByFamilyLoc = $catalogCtx.ByFamilyLoc
    $catalogByFamilyLocArch = $catalogCtx.ByFamilyLocArch
    $catalogByShapeLoc = $catalogCtx.ByShapeLoc
    $catalogByShapeLocArch = $catalogCtx.ByShapeLocArch
    $allCatalogEntries = New-Object 'System.Collections.Generic.List[object]'
    foreach ($c in @($Catalog)) {
        if (-not $c) { continue }

        $perfRes = Get-PerformanceModelResult -Cap $c.Cap -VmSize ([string]$c.Name)

        $entry = [pscustomobject]@{
            Name         = [string]$c.Name
            Family       = [string]$c.Family
            Tier         = [string]$c.Tier
            Size         = [string]$c.Size
            ShapeKey     = Get-SkuShapeKey -SkuName ([string]$c.Name)
            Locations    = @($c.Locations)
            Cap          = $c.Cap
            Restrictions = $c.Restrictions
            LocationInfo = if ($c.PSObject.Properties.Match("LocationInfo").Count -gt 0) { $c.LocationInfo } else { $null }
            Arch         = Get-Architecture -Cap $c.Cap
            Version      = Get-VersionFromVmSize -VmSize ([string]$c.Name)
            FeatureScore = Get-ModernFeatureScore -Cap $c.Cap
            PerfIndex    = [double]$perfRes.Index
            PerfModel    = [string]$perfRes.Method
        }

        $allCatalogEntries.Add($entry)
    }

    $rows = New-Object 'System.Collections.Generic.List[object]'
    $totalVms = @($Inventory).Count
    $vmIdx = 0
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $analysisDate = (Get-Date).ToString("yyyy-MM-dd")

    foreach ($vm in $Inventory) {
        $vmIdx++
        $pct = if ($totalVms -gt 0) { [int][math]::Round(($vmIdx / $totalVms) * 100, 0) } else { 100 }
        $avgSecPerVm = if ($vmIdx -gt 0) { $timer.Elapsed.TotalSeconds / $vmIdx } else { 0 }
        $remaining = [math]::Max(0, $totalVms - $vmIdx)
        $etaSec = [int][math]::Round($avgSecPerVm * $remaining, 0)
        Write-Progress -Id 16 -ParentId 1 -Activity "Computing modernity and recommendations" -Status "Processing VM $vmIdx/$totalVms ($($vm.VmName))" -PercentComplete $pct -SecondsRemaining $etaSec

        $vmKey = "{0}|{1}" -f $vm.VmSize, $vm.Location
        $vmOsType = if ($vm.PSObject.Properties.Match('OsType').Count -gt 0) { [string]$vm.OsType } else { "" }

        $currentPrice = 0.0
        $currentPriceEffectiveStartDate = "N/A"
        $currentPriceOsBasis = 'NoPrice'
        $currentWindowsMeterAvailable = $false
        if ($PriceMap.ContainsKey($vmKey)) {
            $currentPriceSelection = Resolve-RetailPriceForOs -PriceEntry $PriceMap[$vmKey] -OsType $vmOsType
            $currentPrice = $currentPriceSelection.Price
            $currentPriceOsBasis = $currentPriceSelection.Basis
            $currentWindowsMeterAvailable = [bool]$currentPriceSelection.WindowsAvailable
            $currentPriceEffectiveStartDate = Format-NullableDate $PriceMap[$vmKey].EffectiveStartDate
        }

        $currSku = $null
        if ($catalogByName.ContainsKey($vm.VmSize)) {
            $currSku = $catalogByName[$vm.VmSize] | Where-Object { $_.Locations -contains $vm.Location } | Select-Object -First 1
            if (-not $currSku) {
                $currSku = $catalogByName[$vm.VmSize] | Select-Object -First 1
            }
        }

        if (-not $currSku) {
            Write-Log "SKU not found in compute catalog: $($vm.VmSize)" "WARN"
            continue
        }

        $currentVersion = [int]$currSku.Version
        $currentArch = [string]$currSku.Arch

        $workloadRole = Get-WorkloadRole -VmName ([string]$vm.VmName) -TagsText ([string]$vm.TagsText) -ExtensionsText ([string]$vm.ExtensionsText)

        if (-not $AllowArchChange) {
            $famKey = "{0}|{1}|{2}" -f $currSku.Family, $vm.Location, $currentArch
            $familySkus = if ($catalogByFamilyLocArch.ContainsKey($famKey)) { @($catalogByFamilyLocArch[$famKey]) } else { @() }
        }
        else {
            $famKey = "{0}|{1}" -f $currSku.Family, $vm.Location
            $familySkus = if ($catalogByFamilyLoc.ContainsKey($famKey)) { @($catalogByFamilyLoc[$famKey]) } else { @() }
        }

        $candidateSkus = @($familySkus | Where-Object {
            $_.Name -ne $vm.VmSize -and $_.Version -ge $currentVersion
        })

        $currentVcpu = Get-CapNumber -Cap $currSku.Cap -Name "vCPUs" -Default 0
        $currentMemGb = Get-CapNumber -Cap $currSku.Cap -Name "MemoryGB" -Default 0

        $minVcpu = if ($currentVcpu -gt 0) { $currentVcpu * 0.75 } else { 0 }
        $maxVcpu = if ($currentVcpu -gt 0) { $currentVcpu * [math]::Max(1.0, $MaxVcpuIncreaseRatio) } else { 0 }
        $minMem = if ($currentMemGb -gt 0) { $currentMemGb * 0.75 } else { 0 }
        $maxMem = if ($currentMemGb -gt 0) { $currentMemGb * [math]::Max(1.0, $MaxMemoryIncreaseRatio) } else { 0 }
        $minPerf = if ($currSku.PerfIndex -gt 0) { [double]$currSku.PerfIndex * [math]::Max(0.1, $MinPerfRatio) } else { 0 }

        $candidatePool = @($candidateSkus | Where-Object {
            $candVcpu = Get-CapNumber -Cap $_.Cap -Name "vCPUs" -Default $currentVcpu
            $candMem = Get-CapNumber -Cap $_.Cap -Name "MemoryGB" -Default $currentMemGb

            $sizeWithinLower = (($currentVcpu -le 0 -or $candVcpu -ge $minVcpu) -and ($currentMemGb -le 0 -or $candMem -ge $minMem))
            $sizeWithinUpper = (($currentVcpu -le 0 -or $candVcpu -le $maxVcpu) -and ($currentMemGb -le 0 -or $candMem -le $maxMem))
            $perfOk = ($minPerf -le 0 -or [double]$_.PerfIndex -ge $minPerf)
            $techOk = Test-CandidateTechnicalCompatibility -CurrentCap $currSku.Cap -CandidateCap $_.Cap -CurrentVcpu $currentVcpu -CurrentMemGb $currentMemGb -VcpuTolerancePercent $EquivalentVcpuTolerancePercent -MemoryTolerancePercent $EquivalentMemoryTolerancePercent

            $costOk = $true
            if ($currentPrice -gt 0) {
                $candKey = "{0}|{1}" -f $_.Name, $vm.Location
                if ($PriceMap.ContainsKey($candKey)) {
                    $candPriceLocal = Get-RetailUnitPriceForOs -PriceEntry $PriceMap[$candKey] -OsType $vmOsType
                    if ($candPriceLocal -gt 0) {
                        $candDeltaPctLocal = (($candPriceLocal - $currentPrice) / $currentPrice) * 100
                        if ($candDeltaPctLocal -gt $MaxCostIncreasePercent) {
                            $costOk = $false
                        }
                    }
                }
            }

            ($sizeWithinLower -and $sizeWithinUpper -and $perfOk -and $costOk -and $techOk)
        })

        $candidateStrategy = "same-family"
        if (@($candidatePool).Count -eq 0) {
            $shapeKey = Get-SkuShapeKey -SkuName ([string]$vm.VmSize)
            if (-not $AllowArchChange) {
                $shapeLookupKey = "{0}|{1}|{2}" -f $shapeKey, $vm.Location, $currentArch
                $shapeCandidates = if ($catalogByShapeLocArch.ContainsKey($shapeLookupKey)) { @($catalogByShapeLocArch[$shapeLookupKey]) } else { @() }
            }
            else {
                $shapeLookupKey = "{0}|{1}" -f $shapeKey, $vm.Location
                $shapeCandidates = if ($catalogByShapeLoc.ContainsKey($shapeLookupKey)) { @($catalogByShapeLoc[$shapeLookupKey]) } else { @() }
            }

            $candidatePool = @($shapeCandidates | Where-Object {
                $_.Name -ne $vm.VmSize -and
                $_.Version -gt $currentVersion -and
                (Test-CandidateTechnicalCompatibility -CurrentCap $currSku.Cap -CandidateCap $_.Cap -CurrentVcpu $currentVcpu -CurrentMemGb $currentMemGb -VcpuTolerancePercent $EquivalentVcpuTolerancePercent -MemoryTolerancePercent $EquivalentMemoryTolerancePercent)
            })

            if (@($candidatePool).Count -gt 0) {
                $candidateStrategy = "same-shape-newer-version"
            }
        }

        $currentIsBurstable = Test-IsBurstableSku -SkuName ([string]$vm.VmSize)
        if (@($candidatePool).Count -eq 0 -and $currentIsBurstable) {
            $burstablePool = @($allCatalogEntries | Where-Object {
                $_.Name -ne $vm.VmSize -and
                (Test-IsBurstableSku -SkuName ([string]$_.Name)) -and
                $_.Version -gt $currentVersion -and
                ($_.Locations -contains $vm.Location) -and
                ($AllowArchChange -or $_.Arch -eq $currentArch) -and
                (Test-CandidateTechnicalCompatibility -CurrentCap $currSku.Cap -CandidateCap $_.Cap -CurrentVcpu $currentVcpu -CurrentMemGb $currentMemGb -VcpuTolerancePercent $EquivalentVcpuTolerancePercent -MemoryTolerancePercent $EquivalentMemoryTolerancePercent -IgnoreNicRegression)
            })

            if (@($burstablePool).Count -gt 0) {
                $candidatePool = $burstablePool
                $candidateStrategy = "burstable-modernization"
            }
        }

        # Always propose a candidate: even for sensitive workloads (domain controllers, SQL, etc.) we
        # surface a cross-family target and attach a warning note instead of withholding it. Any SKU change
        # on any VM warrants validation/testing; sensitive roles simply get an extra caution flag rather
        # than being left without a recommendation.
        $crossFamilySuppressed = $false
        if (@($candidatePool).Count -eq 0) {
            $nearbyFamilyPool = @($allCatalogEntries | Where-Object {
                $_.Name -ne $vm.VmSize -and
                $_.Family -ne $currSku.Family -and
                $_.Version -ge $currentVersion -and
                ($_.Locations -contains $vm.Location) -and
                ($AllowArchChange -or $_.Arch -eq $currentArch) -and
                (Test-CandidateTechnicalCompatibility -CurrentCap $currSku.Cap -CandidateCap $_.Cap -CurrentVcpu $currentVcpu -CurrentMemGb $currentMemGb -VcpuTolerancePercent $EquivalentVcpuTolerancePercent -MemoryTolerancePercent $EquivalentMemoryTolerancePercent)
            })

            if (@($nearbyFamilyPool).Count -gt 0) {
                $candidatePool = $nearbyFamilyPool
                $candidateStrategy = "nearby-family-compatible"
            }
        }

        $orderedCandidates = New-Object 'System.Collections.Generic.List[object]'
        $candidateRanked = foreach ($cand in $candidatePool) {
            $candKey = "{0}|{1}" -f $cand.Name, $vm.Location
            $candPrice = 0.0
            $hasPrice = $false
            if ($PriceMap.ContainsKey($candKey)) {
                $candPrice = Get-RetailUnitPriceForOs -PriceEntry $PriceMap[$candKey] -OsType $vmOsType
                if ($candPrice -gt 0) {
                    $hasPrice = $true
                }
            }

            $candVcpu = Get-CapNumber -Cap $cand.Cap -Name "vCPUs" -Default $currentVcpu
            $candMem = Get-CapNumber -Cap $cand.Cap -Name "MemoryGB" -Default $currentMemGb

            $vcpuDeltaAbs = if ($currentVcpu -gt 0) { [math]::Abs(($candVcpu - $currentVcpu) / $currentVcpu) } else { 0 }
            $memDeltaAbs = if ($currentMemGb -gt 0) { [math]::Abs(($candMem - $currentMemGb) / $currentMemGb) } else { 0 }
            $upsizePenalty = 0.0
            if ($currentVcpu -gt 0 -and $candVcpu -gt $currentVcpu) {
                $upsizePenalty += (($candVcpu - $currentVcpu) / $currentVcpu)
            }
            if ($currentMemGb -gt 0 -and $candMem -gt $currentMemGb) {
                $upsizePenalty += (($candMem - $currentMemGb) / $currentMemGb)
            }

            $costDeltaPctCandidate = 0.0
            if ($currentPrice -gt 0 -and $hasPrice) {
                $costDeltaPctCandidate = (($candPrice - $currentPrice) / $currentPrice) * 100
            }
            elseif ($currentPrice -gt 0 -and -not $hasPrice) {
                $costDeltaPctCandidate = 999
            }

            $score = (($upsizePenalty * 4.0) + ($vcpuDeltaAbs * 2.5) + ($memDeltaAbs * 2.0) + ([math]::Max(0, $costDeltaPctCandidate) / 50.0)) - (($cand.Version - $currentVersion) * 0.15) - ($cand.FeatureScore / 500.0)

            [pscustomobject]@{
                Score = $score
                CostDeltaPctCandidate = $costDeltaPctCandidate
                Cand = $cand
                CandPrice = $candPrice
            }
        }

        foreach ($ranked in ($candidateRanked | Sort-Object Score, CostDeltaPctCandidate, @{ Expression = { $_.Cand.Version }; Descending = $true }, @{ Expression = { $_.Cand.FeatureScore }; Descending = $true } | Select-Object -First $Top)) {
            $cand = $ranked.Cand
            $candPrice = [double]$ranked.CandPrice

            $orderedCandidates.Add([pscustomobject]@{
                Name      = $cand.Name
                Version   = [int]$cand.Version
                Price     = $candPrice
                Perf      = [double]$cand.PerfIndex
                PerfModel = if ($cand.PSObject.Properties.Match("PerfModel").Count -gt 0) { [string]$cand.PerfModel } else { "Unknown*" }
                Arch      = [string]$cand.Arch
                Feature   = [double]$cand.FeatureScore
                Cap       = $cand.Cap
                Restrictions = $cand.Restrictions
                LocationInfo = $cand.LocationInfo
            })
        }

        $orderedCandidatesArr = $orderedCandidates.ToArray()
        $bestCandidate = @($orderedCandidatesArr | Select-Object -First 1)
        if (@($bestCandidate).Count -gt 0) { $bestCandidate = $bestCandidate[0] } else { $bestCandidate = $null }
        $latestVersion = $currentVersion
        if (@($candidateSkus).Count -gt 0) {
            $latestVersion = [int](($candidateSkus | Measure-Object -Property Version -Maximum).Maximum)
        }

        $currentPerf = [double]$currSku.PerfIndex
        $currentPerfModel = if ($currSku.PSObject.Properties.Match("PerfModel").Count -gt 0 -and $currSku.PerfModel) { [string]$currSku.PerfModel } else { "Unknown*" }
        $firstSeen = if ($FirstSeenMap.ContainsKey($vmKey)) { [datetime]$FirstSeenMap[$vmKey] } else { Get-Date }

        $retirement = Resolve-RetirementForVmOrSku -Vm $vm -Retirements $Retirements
        $suggestedRetirement = $null
        if ($bestCandidate) {
            $suggestedRetirement = Resolve-RetirementForSku -SkuName ([string]$bestCandidate.Name) -Retirements $Retirements
        }

        # Match Advisor hints for this VM (all categories, not just retirement-related)
        $vmAdvisorHints = Get-AdvisorHintsForVm -Vm $vm -AdvisorHints $AdvisorHints

        $currentRetirementDate = if ($retirement) { Format-NullableDate $retirement.RetireOn } else { "N/A" }
        $suggestedRetirementDate = if ($suggestedRetirement) { Format-NullableDate $suggestedRetirement.RetireOn } else { "N/A" }

        $supportHorizonDeltaDays = $null
        $supportHorizonOutcome = if ($bestCandidate) { "Unknown" } else { "NoTarget" }
        if ($bestCandidate) {
            $supportHorizonDeltaDays = Get-DateDiffDays -FromDate $currentRetirementDate -ToDate $suggestedRetirementDate
            $supportHorizonOutcome = Get-SupportHorizonOutcome -DeltaDays $supportHorizonDeltaDays
        }

        $currentCommit = Get-CommitmentSupportForSkuRegion -SkuName ([string]$vm.VmSize) -Region ([string]$vm.Location) -CommitmentMap $CommitmentMap
        $targetCommit = if ($bestCandidate) {
            Get-CommitmentSupportForSkuRegion -SkuName ([string]$bestCandidate.Name) -Region ([string]$vm.Location) -CommitmentMap $CommitmentMap
        }
        else {
            [pscustomobject]@{
                SupportsReservedInstance      = $false
                SupportsSavingsPlan           = $false
                ReservedInstanceFirstSeenDate = "N/A"
                SavingsPlanFirstSeenDate      = "N/A"
            }
        }

        $currentRiRetirementDate = if ($currentCommit.SupportsReservedInstance) { $currentRetirementDate } else { "N/A" }
        $targetRiRetirementDate = if ($targetCommit.SupportsReservedInstance) { $suggestedRetirementDate } else { "N/A" }
        $currentSpRetirementDate = if ($currentCommit.SupportsSavingsPlan) { $currentRetirementDate } else { "N/A" }
        $targetSpRetirementDate = if ($targetCommit.SupportsSavingsPlan) { $suggestedRetirementDate } else { "N/A" }

        $currentRiRetirementBasis = if ($currentCommit.SupportsReservedInstance) { "SkuRetirementProxy" } else { "N/A" }
        $targetRiRetirementBasis = if ($targetCommit.SupportsReservedInstance) { "SkuRetirementProxy" } else { "N/A" }
        $currentSpRetirementBasis = if ($currentCommit.SupportsSavingsPlan) { "SkuRetirementProxy" } else { "N/A" }
        $targetSpRetirementBasis = if ($targetCommit.SupportsSavingsPlan) { "SkuRetirementProxy" } else { "N/A" }

        $bestCandidatePerfModel = if ($bestCandidate -and $bestCandidate.PSObject.Properties.Match("PerfModel").Count -gt 0 -and $bestCandidate.PerfModel) { [string]$bestCandidate.PerfModel } else { "N/A" }

        if ($bestCandidate -and $currentPerfModel -ne $bestCandidatePerfModel) {
            $currentPerfComparable = (Get-PerformanceModelResult -Cap $currSku.Cap -VmSize ([string]$vm.VmSize) -PreferAcu:$false)
            $targetPerfComparable = (Get-PerformanceModelResult -Cap $bestCandidate.Cap -VmSize ([string]$bestCandidate.Name) -PreferAcu:$false)

            $currentPerf = [double]$currentPerfComparable.Index
            $currentPerfModel = [string]$currentPerfComparable.Method
            $bestCandidatePerfModel = [string]$targetPerfComparable.Method
        }
        $bestCandidatePriceEffectiveStartDate = "N/A"
        if ($bestCandidate) {
            $bestCandidateKey = "{0}|{1}" -f $bestCandidate.Name, $vm.Location
            if ($PriceMap.ContainsKey($bestCandidateKey)) {
                $bestCandidatePriceEffectiveStartDate = Format-NullableDate $PriceMap[$bestCandidateKey].EffectiveStartDate
            }
        }

        # Generation-boundary detection: if the current SKU can run as Gen1 (HyperVGenerations includes V1)
        # but the recommended target is Gen2-only, the move is NOT a simple resize - it may require the OS
        # image to be Gen2 plus boot/driver validation. Flagged per row and totalled in the executive summary.
        $currentHyperVGenerations = Get-CapString -Cap $currSku.Cap -Name "HyperVGenerations" -Default "N/A"
        $targetHyperVGenerations = if ($bestCandidate) { Get-CapString -Cap $bestCandidate.Cap -Name "HyperVGenerations" -Default "N/A" } else { "N/A" }
        $currentSupportsGen1 = ($currentHyperVGenerations -match "(?i)V1")
        $targetSupportsGen1 = ($targetHyperVGenerations -match "(?i)V1")
        $targetSupportsGen2 = ($targetHyperVGenerations -match "(?i)V2")
        $generationChange = [bool]($bestCandidate -and $currentSupportsGen1 -and -not $targetSupportsGen1 -and $targetSupportsGen2)

        $costDeltaPct = $null
        $perfDeltaPct = $null
        $versionGap = [math]::Max(0, ($latestVersion - $currentVersion))

        if ($bestCandidate) {
            if ($currentPrice -gt 0 -and [double]$bestCandidate.Price -gt 0) {
                $costDeltaPct = [math]::Round((($bestCandidate.Price - $currentPrice) / $currentPrice) * 100, 2)
            }
            if ($currentPerf -gt 0.1 -and [double]$bestCandidate.Perf -gt 0.1) {
                $rawPerfDelta = (($bestCandidate.Perf - $currentPerf) / $currentPerf) * 100
                if ([math]::Abs($rawPerfDelta) -le 500) {
                    $perfDeltaPct = [math]::Round($rawPerfDelta, 2)
                }
            }
        }

        $perfDeltaMethod = if ($bestCandidate) {
            if ($currentPerfModel -eq $bestCandidatePerfModel) {
                $currentPerfModel
            }
            else {
                "$currentPerfModel -> $bestCandidatePerfModel"
            }
        }
        else {
            "N/A"
        }

        $priorityCostForDecision = if ($null -eq $costDeltaPct) { 999.0 } else { [double]$costDeltaPct }
        $priority = Get-MigrationPriority -CostDeltaPercent $priorityCostForDecision -VersionGap $versionGap

        $riskList = @()
        if ($bestCandidate) {
            $riskList = Get-MigrationRiskList -CurrentCap $currSku.Cap -CandidateCap $bestCandidate.Cap -CurrentArch $currentArch -CandidateArch $bestCandidate.Arch
        }
        else {
            $riskList = Get-MigrationRiskList -CurrentCap $currSku.Cap -CandidateCap $currSku.Cap -CurrentArch $currentArch -CandidateArch $currentArch
        }

        $recommendationText = "No equivalent alternative found in family; keep and monitor roadmap"
        if ($bestCandidate) {
            $impactNotes = New-Object 'System.Collections.Generic.List[string]'

            $currentHyperV = Get-CapString -Cap $currSku.Cap -Name "HyperVGenerations" -Default "N/A"
            $targetHyperV = Get-CapString -Cap $bestCandidate.Cap -Name "HyperVGenerations" -Default "N/A"
            if ($targetHyperV -notin @("", "N/A")) {
                if (($currentHyperV -match "(?i)V1") -and ($targetHyperV -notmatch "(?i)V1")) {
                    $impactNotes.Add("Warning: target supports Gen2 only ($targetHyperV). Verify the VM is Gen2 before resizing")
                }
                else {
                    $impactNotes.Add("Hyper-V Gen compatibility: current=$currentHyperV, target=$targetHyperV")
                }
            }

            $currEncrypt = Get-CapBool -Cap $currSku.Cap -Name "EncryptionAtHostSupported"
            $tgtEncrypt = Get-CapBool -Cap $bestCandidate.Cap -Name "EncryptionAtHostSupported"
            if ($currEncrypt -and -not $tgtEncrypt) {
                $impactNotes.Add("Possible security regression: EncryptionAtHost not supported on target")
            }
            elseif ($tgtEncrypt) {
                $impactNotes.Add("EncryptionAtHost also supported on target")
            }

            $currAccel = Get-CapBool -Cap $currSku.Cap -Name "AcceleratedNetworkingEnabled"
            $tgtAccel = Get-CapBool -Cap $bestCandidate.Cap -Name "AcceleratedNetworkingEnabled"
            if ($currAccel -and -not $tgtAccel) {
                $impactNotes.Add("Possible network regression: Accelerated Networking not supported on target")
            }
            elseif ($tgtAccel) {
                $impactNotes.Add("Accelerated Networking available on target")
            }

            $impactNotes.Add("Driver/agent: usually unchanged in Azure resize, but validate extensions and security/monitoring drivers")

            if ($null -ne $costDeltaPct) {
                $impactNotes.Add("Estimated cost delta: $costDeltaPct%")
            }
            else {
                $impactNotes.Add("Cost delta unavailable: missing Retail price for comparison")
            }

            if ($null -ne $perfDeltaPct) {
                $impactNotes.Add("Estimated performance index delta: $perfDeltaPct%")
            }

            if ($supportHorizonOutcome -eq "Extended" -and $null -ne $supportHorizonDeltaDays) {
                $impactNotes.Add("Support horizon extended by $supportHorizonDeltaDays days (current=$currentRetirementDate, target=$suggestedRetirementDate)")
            }
            elseif ($supportHorizonOutcome -eq "Reduced" -and $null -ne $supportHorizonDeltaDays) {
                $impactNotes.Add("Support horizon reduced by $([math]::Abs([int]$supportHorizonDeltaDays)) days (current=$currentRetirementDate, target=$suggestedRetirementDate)")
            }
            elseif ($supportHorizonOutcome -eq "Unchanged") {
                $impactNotes.Add("Support horizon unchanged (current=$currentRetirementDate, target=$suggestedRetirementDate)")
            }

            $impactNotes.Add("Reserved Instance: current=$($currentCommit.SupportsReservedInstance), target=$($targetCommit.SupportsReservedInstance)")
            $impactNotes.Add("Savings Plan: current=$($currentCommit.SupportsSavingsPlan), target=$($targetCommit.SupportsSavingsPlan)")

            $recommendationText = "Migrate to $($bestCandidate.Name) with priority $priority; impacts: " + ($impactNotes -join " | ")
        }

        $retirementEvidence = Get-RetirementEvidence -RetirementEntry $retirement

        # LIVE-ONLY: Use Resolve-OfficialRetirementLiveOnly (no fallback to hardcoded list)
        # Extract live Learn series from retirements object
        $liveSeries = @($Retirements.Series | Where-Object { $_.PSObject.Properties.Match("Source").Count -gt 0 -and $_.Source -eq "LiveLearnMarkdown" })
        $officialLiveRetirement = Resolve-OfficialRetirementLiveOnly -SkuName ([string]$vm.VmSize) -LiveLearnSeries $liveSeries
        
        $advisorSignalPresent = ($retirement -and $retirementEvidence.EvidenceType -eq "TenantSpecificAdvisorSignal")

        if ($officialLiveRetirement) {
            $officialRetirementDate = Format-NullableDate $officialLiveRetirement.RetireOn
            $evidenceSource = if ($advisorSignalPresent) { "LiveLearnMarkdown + AdvisorSignal" } else { "LiveLearnMarkdown" }
            $effectiveEvidenceType = "PublicOfficialAnnouncement"
        }
        elseif ($advisorSignalPresent) {
            $officialRetirementDate = "No live retirement source"
            $evidenceSource = "AdvisorSignalOnly"
            $effectiveEvidenceType = "TenantSpecificAdvisorSignal"
        }
        elseif ($retirement) {
            $officialRetirementDate = if ($retirementEvidence.EvidenceType -eq "PublicOfficialAnnouncement") { Format-NullableDate $retirement.RetireOn } else { "No live retirement source" }
            $evidenceSource = if ($retirementEvidence.EvidenceType -eq "PublicOfficialAnnouncement") { "PublicOfficialAnnouncement" } else { "AdvisorSignalOnly" }
            $effectiveEvidenceType = $retirementEvidence.EvidenceType
        }
        else {
            $officialRetirementDate = "No live retirement source"
            $evidenceSource = "NoSignal"
            $effectiveEvidenceType = "NoAnnouncedRetirementFound"
        }

        # Authoritative retirement date/source for the row.
        # For public/announced-wave rows, the date comes from the announced-wave list (not any leaked
        # Advisor date), and the source is the announcement list - preventing the "Advisor date leaked
        # into a Workbook row" defect. For Advisor-only rows, use the Advisor object's date/source.
        if ($effectiveEvidenceType -eq "PublicOfficialAnnouncement") {
            $effectiveRetirementDate = $officialRetirementDate
            $effectiveRetirementSource = if ($retirement -and $retirement.PSObject.Properties.Match("Source").Count -gt 0 -and ([string]$retirement.Source -match "OfficialMicrosoftLearn")) { [string]$retirement.Source } else { "AnnouncedRetirementWaveList" }
        }
        elseif ($retirement) {
            $effectiveRetirementDate = Format-NullableDate $retirement.RetireOn
            $effectiveRetirementSource = if ($retirement.PSObject.Properties.Match("Source").Count -gt 0) { [string]$retirement.Source } else { "N/A" }
        }
        else {
            $effectiveRetirementDate = "N/A"
            $effectiveRetirementSource = "N/A"
        }

        # Commitment (RI / Savings Plan) retirement impact flag: if the current SKU is covered by an RI or
        # a Savings Plan AND the SKU/family is on a retirement path, that commitment coverage is impacted
        # when the SKU retires. The exact financial effect (effective RI/SP pricing) is out of scope, so we
        # raise a WARNING FLAG plus the "when" (retirement date) rather than a computed number.
        $hasCommitment = ([bool]$currentCommit.SupportsReservedInstance -or [bool]$currentCommit.SupportsSavingsPlan)
        $isOnRetirementPath = ($effectiveEvidenceType -eq 'PublicOfficialAnnouncement' -or $effectiveEvidenceType -eq 'TenantSpecificAdvisorSignal')
        $commitmentRetirementImpact = [bool]($hasCommitment -and $isOnRetirementPath)
        $commitmentRetirementKindsList = New-Object 'System.Collections.Generic.List[string]'
        if ($currentCommit.SupportsReservedInstance) { $commitmentRetirementKindsList.Add('Reserved Instance') | Out-Null }
        if ($currentCommit.SupportsSavingsPlan) { $commitmentRetirementKindsList.Add('Savings Plan') | Out-Null }
        $commitmentRetirementKinds = ($commitmentRetirementKindsList.ToArray() -join ' and ')
        $commitmentRetirementImpactDate = if ($commitmentRetirementImpact) { $effectiveRetirementDate } else { 'N/A' }
        $commitmentRetirementImpactNote = if ($commitmentRetirementImpact) {
            "Commitment cost impact: this SKU is covered by $commitmentRetirementKinds and is on a retirement path (retires $effectiveRetirementDate). The existing commitment coverage is impacted when the SKU retires; the exact financial effect is not quantified here."
        }
        else { '' }
        if ($commitmentRetirementImpact) {
            Write-Log "Commitment retirement impact: $($vm.VmName) ($($vm.VmSize)) has $commitmentRetirementKinds coverage and retires $effectiveRetirementDate." "WARN"
        }

        # Source gate: LIVE-ONLY (no fallback to hardcoded list)
        # Only two sources: LiveAdvisorArg (Advisor ARG) or LiveLearnMarkdown (Microsoft Learn)
        if ($effectiveEvidenceType -eq "PublicOfficialAnnouncement" -and $officialLiveRetirement) {
            $retirementSourceGate = "LiveLearnMarkdown"
            $retirementSourceAsOf = (Get-Date).ToString("yyyy-MM-dd")
        } elseif ($effectiveEvidenceType -eq "TenantSpecificAdvisorSignal") {
            $retirementSourceGate = "LiveAdvisorArg"
            $retirementSourceAsOf = (Get-Date).ToString("yyyy-MM-dd")
        } else {
            $retirementSourceGate = "N/A"
            $retirementSourceAsOf = "N/A"
        }

        $retirementRisk = Get-RetirementRisk -RetirementEntry $retirement -EvidenceType $effectiveEvidenceType -CurrentVersion $currentVersion

        $advisorRetirementSignalDate = if ($retirement -and $retirementEvidence.EvidenceType -eq "TenantSpecificAdvisorSignal") { Format-NullableDate $retirement.RetireOn } else { "N/A" }

        $currentPriceEntry = if ($PriceMap.ContainsKey($vmKey)) { $PriceMap[$vmKey] } else { $null }
        $candidatePriceEntry = $null
        if ($bestCandidate) {
            $bestCandidateKeyForPrice = "{0}|{1}" -f $bestCandidate.Name, $vm.Location
            if ($PriceMap.ContainsKey($bestCandidateKeyForPrice)) { $candidatePriceEntry = $PriceMap[$bestCandidateKeyForPrice] }
        }

        $currentPayG = Test-IsPayGPriceEntry -PriceEntry $currentPriceEntry
        $candidatePayG = Test-IsPayGPriceEntry -PriceEntry $candidatePriceEntry
        $pricingValidated = ($bestCandidate -and $currentPayG -and $candidatePayG)

        if ($bestCandidate) {
            if ($pricingValidated) {
                $costDeltaStatus = "ValidatedPayG"
                $costDeltaPublishable = $true
            }
            else {
                $costDeltaStatus = "NotValidated_MeterCheckRequired"
                $costDeltaPublishable = $false
            }
        }
        else {
            $costDeltaStatus = "N/A"
            $costDeltaPublishable = $false
        }

        # Financial validation (Cost Management + RI/SP effective pricing) is out of V2 scope.
        $financialValidationStatus = if ($bestCandidate) { "NotValidated_RequiresCostManagement_RI_SP" } else { "N/A" }

        $costDeltaReported = if ($costDeltaPublishable) { $costDeltaPct } else { $null }
        $retailDeltaMonthly = if ($bestCandidate -and $currentPrice -gt 0 -and [double]$bestCandidate.Price -gt 0) {
            [math]::Round((([double]$bestCandidate.Price - [double]$currentPrice) * 730), 2)
        }
        else {
            $null
        }

        $usageDataStatus = "SKU metadata only; workload telemetry not evaluated"

        $advisorCategory = if ($retirement -and $retirement.PSObject.Properties.Match("AdvisorCategory").Count -gt 0) { [string]$retirement.AdvisorCategory } else { "N/A" }
        $advisorImpact = if ($retirement -and $retirement.PSObject.Properties.Match("AdvisorImpact").Count -gt 0) { [string]$retirement.AdvisorImpact } else { "N/A" }
        $advisorSubCategory = if ($retirement -and $retirement.PSObject.Properties.Match("AdvisorSubCategory").Count -gt 0) { [string]$retirement.AdvisorSubCategory } else { "N/A" }
        $advisorRecId = if ($retirement -and $retirement.PSObject.Properties.Match("AdvisorRecommendationId").Count -gt 0) { [string]$retirement.AdvisorRecommendationId } else { "N/A" }
        $advisorRecName = if ($retirement -and $retirement.PSObject.Properties.Match("AdvisorRecommendationName").Count -gt 0) { [string]$retirement.AdvisorRecommendationName } else { "N/A" }
        $advisorRecTypeId = if ($retirement -and $retirement.PSObject.Properties.Match("AdvisorRecommendationTypeId").Count -gt 0) { [string]$retirement.AdvisorRecommendationTypeId } else { "N/A" }

        $validationChecklist = "Gen1/Gen2 OS; NVMe support; temp/local disk; disk caching; accelerated networking; RI/Savings Plan; quota; Availability Zone"

        $rows.Add([pscustomobject]@{
            SubscriptionId         = $vm.SubscriptionId
            ResourceGroup          = $vm.ResourceGroup
            VmName                 = $vm.VmName
            Region                 = $vm.Location
            CurrentSku             = $vm.VmSize
            CurrentArch            = $currentArch
            OsType                 = $vmOsType
            CurrentPriceOsBasis    = $currentPriceOsBasis
            CurrentWindowsMeterAvailable = [bool]$currentWindowsMeterAvailable
            VmCreatedDate          = $vm.VmCreatedDate
            AnalysisDate           = $analysisDate
            FirstSeenDate          = $firstSeen.ToString("yyyy-MM-dd")
            LaunchDateSource       = "first-seen"
            CurrentSkuPriceEffectiveStartDate   = $currentPriceEffectiveStartDate
            SuggestedSkuPriceEffectiveStartDate = $bestCandidatePriceEffectiveStartDate
            Confidence             = "OfficialDataHigh_HeuristicScoreMedium"
            SuggestedSkus          = (($orderedCandidatesArr | ForEach-Object { $_.Name }) -join "; ")
            SuggestedPrimarySku    = if ($bestCandidate) { $bestCandidate.Name } else { "N/A" }
            CandidateTargetSku     = if ($bestCandidate) { $bestCandidate.Name } else { "N/A" }
            UsageDataStatus        = $usageDataStatus
            WorkloadRole           = $workloadRole.Role
            WorkloadRoleSource     = ("{0} (inferred, low confidence)" -f $workloadRole.Source)
            AdvisorCategory        = $advisorCategory
            AdvisorImpact          = $advisorImpact
            AdvisorSubCategory     = $advisorSubCategory
            AdvisorRecommendationId = $advisorRecId
            AdvisorRecommendationName = $advisorRecName
            AdvisorRecommendationTypeId = $advisorRecTypeId
            VmAdvisorHints         = ($vmAdvisorHints | ConvertTo-Json -Compress)
            CrossFamilySuppressed  = [bool]$crossFamilySuppressed
            SensitiveWorkload      = [bool]$workloadRole.Conservative
            GenerationChange       = [bool]$generationChange
            CurrentHyperVGenerations = $currentHyperVGenerations
            TargetHyperVGenerations  = $targetHyperVGenerations
            ValidationChecklist    = $validationChecklist
            SuggestedPrimaryArch   = if ($bestCandidate) { $bestCandidate.Arch } else { "N/A" }
            CostDeltaPercent       = $costDeltaPct
            CostDeltaReported      = $costDeltaReported
            RetailDeltaMonthly     = $retailDeltaMonthly
            CostDeltaStatus        = $costDeltaStatus
            CostDeltaPublishable   = [bool]$costDeltaPublishable
            FinancialValidationStatus = $financialValidationStatus
            PerfDeltaPercent       = $perfDeltaPct
            PerfDeltaMethod        = $perfDeltaMethod
            PerfModelCurrent       = $currentPerfModel
            PerfModelTarget        = $bestCandidatePerfModel
            MigrationPriority      = $priority
            MigrationEffort        = if ($priority -eq "High") { "Medium" } elseif ($priority -eq "Medium") { "Medium/High" } else { "Low/Medium" }
            MigrationRisk          = if ($versionGap -ge 2) { "High" } elseif ($versionGap -eq 1) { "Medium" } else { "Low" }
            MigrationRisksAndBlocks = ($riskList -join " | ")
            RetirementStatus       = if ($retirement) { $retirement.Status } else { "Unknown" }
            RetirementDate         = $effectiveRetirementDate
            RetirementSource       = $effectiveRetirementSource
            RetirementSourceGate   = $retirementSourceGate
            RetirementEvidenceScope = if ($retirementSourceGate -eq "LiveAdvisorArg") { "Per-resource confirmed (Advisor ARG)" } elseif ($retirementSourceGate -eq "LiveLearnMarkdown") { "SKU-family exposure (Microsoft Learn) - verify this VM's scope in Workbook" } else { "No live evidence" }
            RetirementSourceAsOf   = $retirementSourceAsOf
            RetirementEvidenceType = $effectiveEvidenceType
            RetirementEvidenceConfidence = $retirementEvidence.Confidence
            EvidenceSource         = $evidenceSource
            OfficialRetirementDate = $officialRetirementDate
            AdvisorRetirementSignalDate = $advisorRetirementSignalDate
            RetirementRiskLevel    = $retirementRisk.Level
            RetirementRiskReason   = $retirementRisk.Reason
            RetirementSeriesMatch  = if ($retirement -and $retirement.PSObject.Properties.Match("SeriesName").Count -gt 0) { $retirement.SeriesName } else { "N/A" }
            RetirementAnnouncement = if ($retirement -and $retirement.PSObject.Properties.Match("Announcement").Count -gt 0) { $retirement.Announcement } else { "N/A" }
            RetirementMigrationGuide = if ($retirement -and $retirement.PSObject.Properties.Match("MigrationGuide").Count -gt 0) { $retirement.MigrationGuide } else { "N/A" }
            SuggestedRetirementStatus       = if ($suggestedRetirement) { $suggestedRetirement.Status } else { "Unknown" }
            SuggestedRetirementDate         = if ($suggestedRetirement) { $suggestedRetirement.RetireOn } else { "N/A" }
            SuggestedRetirementSource       = if ($suggestedRetirement -and $suggestedRetirement.PSObject.Properties.Match("Source").Count -gt 0) { $suggestedRetirement.Source } else { "N/A" }
            SuggestedRetirementSeriesMatch  = if ($suggestedRetirement -and $suggestedRetirement.PSObject.Properties.Match("SeriesName").Count -gt 0) { $suggestedRetirement.SeriesName } else { "N/A" }
            SuggestedRetirementAnnouncement = if ($suggestedRetirement -and $suggestedRetirement.PSObject.Properties.Match("Announcement").Count -gt 0) { $suggestedRetirement.Announcement } else { "N/A" }
            SuggestedRetirementMigrationGuide = if ($suggestedRetirement -and $suggestedRetirement.PSObject.Properties.Match("MigrationGuide").Count -gt 0) { $suggestedRetirement.MigrationGuide } else { "N/A" }
            SupportHorizonOutcome   = $supportHorizonOutcome
            SupportHorizonDeltaDays = $supportHorizonDeltaDays
            CurrentSupportsReservedInstance = [bool]$currentCommit.SupportsReservedInstance
            SuggestedSupportsReservedInstance = [bool]$targetCommit.SupportsReservedInstance
            CurrentSupportsSavingsPlan = [bool]$currentCommit.SupportsSavingsPlan
            SuggestedSupportsSavingsPlan = [bool]$targetCommit.SupportsSavingsPlan
            CurrentReservedInstanceFirstSeenDate = Format-NullableDate $currentCommit.ReservedInstanceFirstSeenDate
            SuggestedReservedInstanceFirstSeenDate = Format-NullableDate $targetCommit.ReservedInstanceFirstSeenDate
            CurrentSavingsPlanFirstSeenDate = Format-NullableDate $currentCommit.SavingsPlanFirstSeenDate
            SuggestedSavingsPlanFirstSeenDate = Format-NullableDate $targetCommit.SavingsPlanFirstSeenDate
            CurrentReservedInstanceRetirementDate = $currentRiRetirementDate
            SuggestedReservedInstanceRetirementDate = $targetRiRetirementDate
            CurrentSavingsPlanRetirementDate = $currentSpRetirementDate
            SuggestedSavingsPlanRetirementDate = $targetSpRetirementDate
            CurrentReservedInstanceRetirementBasis = $currentRiRetirementBasis
            SuggestedReservedInstanceRetirementBasis = $targetRiRetirementBasis
            CurrentSavingsPlanRetirementBasis = $currentSpRetirementBasis
            SuggestedSavingsPlanRetirementBasis = $targetSpRetirementBasis
            CommitmentRetirementImpact       = [bool]$commitmentRetirementImpact
            CommitmentRetirementImpactKinds  = $commitmentRetirementKinds
            CommitmentRetirementImpactDate   = $commitmentRetirementImpactDate
            CommitmentRetirementImpactNote   = $commitmentRetirementImpactNote
            RecommendationBasis     = Get-RecommendationBasis -CandidateStrategy $candidateStrategy
            HeuristicLevel          = Get-HeuristicLevel -CandidateStrategy $candidateStrategy
            FinancialValidationStatusLabel = Get-FinancialValidationStatusLabel -FinancialValidationStatus $financialValidationStatus -CostDeltaPublishable $costDeltaPublishable
            Recommendation          = $recommendationText
        })
    }

    $timer.Stop()

    Write-Progress -Id 16 -ParentId 1 -Activity "Computing modernity and recommendations" -Status "Completed" -Completed

    return $rows.ToArray()
}

function Export-BacklogItems {
    param(
        [Parameter(Mandatory = $true)][object[]]$Rows,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $items = $Rows |
        Where-Object { $_.MigrationPriority -in @("High", "Medium") } |
        Select-Object @(
            @{ Name = "Title"; Expression = { "SKU modernization - " + $_.VmName } },
            @{ Name = "Priority"; Expression = { $_.MigrationPriority } },
            @{ Name = "Risk"; Expression = { $_.MigrationRisk } },
            @{ Name = "CurrentSku"; Expression = { $_.CurrentSku } },
            @{ Name = "TargetSku"; Expression = { $_.SuggestedPrimarySku } },
            @{ Name = "Region"; Expression = { $_.Region } },
            @{ Name = "Recommendation"; Expression = { $_.Recommendation } },
            @{ Name = "MigrationRisks"; Expression = { $_.MigrationRisksAndBlocks } }
        )

    $items | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
}

function Resolve-EvidenceSource {
    <#
    .SYNOPSIS
    Reconciles each row's EvidenceSource field against the real Azure Advisor query result.
    .DESCRIPTION
    Authoritative source is RetirementEvidenceType (the effective, deterministic classification):
      - PublicOfficialAnnouncement   -> public/workbook retirement (workbook is authoritative)
      - TenantSpecificAdvisorSignal  -> Advisor-sourced retirement signal (must have real Advisor metadata)
      - NoAnnouncedRetirementFound   -> report-derived finding only
    Hard rule: a row may only assert an Advisor retirement signal if it carries a real
    AdvisorRecommendationId. Rows claiming TenantSpecificAdvisorSignal without metadata are
    downgraded to NoAnnouncedRetirementFound (report-derived). EvidenceSource is normalised to match.
    #>
    param(
        [Parameter(Mandatory = $true)][object[]]$Rows
    )

    foreach ($row in $Rows) {
        $hasRealAdvisorId = ($row.PSObject.Properties.Match('AdvisorRecommendationId').Count -gt 0 -and
                             $row.AdvisorRecommendationId -and $row.AdvisorRecommendationId -ne 'N/A')

        $effectiveType = if ($row.PSObject.Properties.Match('RetirementEvidenceType').Count -gt 0) { [string]$row.RetirementEvidenceType } else { '' }

        # Downgrade unbacked Advisor retirement signals to report-derived
        if ($effectiveType -eq 'TenantSpecificAdvisorSignal' -and -not $hasRealAdvisorId) {
            $row.RetirementEvidenceType = 'NoAnnouncedRetirementFound'
            $effectiveType = 'NoAnnouncedRetirementFound'
        }

        # Normalise EvidenceSource to align with the authoritative effective type
        switch ($effectiveType) {
            'PublicOfficialAnnouncement'  { $row.EvidenceSource = 'PublicOfficialAnnouncement' }
            'TenantSpecificAdvisorSignal' { $row.EvidenceSource = 'AdvisorSignalOnly' }
            'NoAnnouncedRetirementFound'  { $row.EvidenceSource = 'NoSignal' }
            default { }
        }
    }

    return @($Rows)
}

function Get-DependencyAgentDetectionQuery {
    <#
    .SYNOPSIS
    ARG query that finds VMs with the Azure Monitor Dependency Agent extension installed.
    .DESCRIPTION
    Turns the vague "verify agent/DCR" caveat into deterministic evidence: the Dependency Agent
    (VM Insights Map) is identified by extension publisher Microsoft.Azure.Monitoring.DependencyAgent.
    #>
    return @"
Resources
| where type =~ 'microsoft.compute/virtualmachines/extensions'
| where tostring(properties.publisher) =~ 'Microsoft.Azure.Monitoring.DependencyAgent'
| extend vmId = tolower(substring(id, 0, indexof(id, '/extensions/')))
| project vmId, extensionName = name, publisher = tostring(properties.publisher), extType = tostring(properties.type)
"@
}

function Confirm-MonitoringAgentPresence {
    <#
    .SYNOPSIS
    Marks each monitoring-lifecycle row as Confirmed / Unconfirmed / Unknown based on real agent presence.
    .DESCRIPTION
    The "Migrate from Dependency Agent" Advisor recommendation can surface on VMs WITHOUT the agent
    installed (residual DCR/Policy "Processes and dependencies (Map)"). This resolves that ambiguity:
      - Confirmed   = Dependency Agent extension is actually installed on the VM (real offboarding action)
      - Unconfirmed = recommendation fired but no agent extension found (likely DCR/Policy residue)
      - Unknown     = detection query failed (fail-safe; do not assert an action either way)
    #>
    param(
        [Parameter(Mandatory = $false)][object[]]$MonitoringRows = @(),
        [Parameter(Mandatory = $false)][string[]]$Subscriptions
    )

    $rows = @($MonitoringRows)
    if ($rows.Count -eq 0) { return $rows }

    $agentVmIds = $null
    try {
        if (Get-Command -Name Search-AzGraph -ErrorAction SilentlyContinue) {
            $query = Get-DependencyAgentDetectionQuery
            $agentVmIds = New-Object 'System.Collections.Generic.HashSet[string]'
            $subList = @($Subscriptions)
            if ($subList.Count -eq 0) {
                $ctx = Get-AzContext -ErrorAction SilentlyContinue
                if ($ctx -and $ctx.Subscription) { $subList = @([string]$ctx.Subscription.Id) }
            }
            foreach ($subId in $subList) {
                $skipToken = $null
                do {
                    $graphArgs = @{ Query = $query; First = 1000; Subscription = [string]$subId }
                    if ($skipToken) { $graphArgs["SkipToken"] = $skipToken }
                    $searchStart = Get-Date
                    try {
                        $page = Search-AzGraph @graphArgs
                        Add-ApiCallLog -Api "Search-AzGraph" -Provider "Az.ResourceGraph" -TenantId $script:EffectiveTenantId -SubscriptionId ([string]$subId) -Request "DependencyAgentExtensions;Publisher=Microsoft.Azure.Monitoring.DependencyAgent;First=1000;SkipToken=$([bool]$skipToken)" -StartedAt $searchStart -EndedAt (Get-Date) -Success $true -Meta @{ ReturnedRows = @($page).Count }
                    }
                    catch {
                        Add-ApiCallLog -Api "Search-AzGraph" -Provider "Az.ResourceGraph" -TenantId $script:EffectiveTenantId -SubscriptionId ([string]$subId) -Request "DependencyAgentExtensions;Publisher=Microsoft.Azure.Monitoring.DependencyAgent;First=1000;SkipToken=$([bool]$skipToken)" -StartedAt $searchStart -EndedAt (Get-Date) -Success $false -ErrorMessage $_.Exception.Message
                        throw
                    }
                    foreach ($p in @($page)) {
                        if ($p.vmId) { [void]$agentVmIds.Add(([string]$p.vmId).ToLowerInvariant()) }
                    }
                    $skipToken = if ($page) { $page.SkipToken } else { $null }
                } while ($skipToken)
            }
        }
    }
    catch {
        Write-Log "Dependency Agent detection query failed; monitoring rows marked Unknown (fail-safe): $($_.Exception.Message)" "WARN"
        $agentVmIds = $null
    }

    foreach ($row in $rows) {
        $vmId = if ($row.PSObject.Properties.Match("ResourceId").Count -gt 0 -and $row.ResourceId) { ([string]$row.ResourceId).ToLowerInvariant() } else { "" }
        $state = if ($null -eq $agentVmIds) { "Unknown" }
                 elseif ($vmId -and $agentVmIds.Contains($vmId)) { "Confirmed" }
                 else { "Unconfirmed" }
        $stateSource = if ($null -eq $agentVmIds) { "DependencyAgentDetectionFailed" } else { "DependencyAgentArg" }
        if ($row.PSObject.Properties.Match("AgentPresence").Count -gt 0) { $row.AgentPresence = $state }
        else { $row | Add-Member -NotePropertyName AgentPresence -NotePropertyValue $state -Force }
        if ($row.PSObject.Properties.Match("AgentPresenceSource").Count -gt 0) { $row.AgentPresenceSource = $stateSource }
        else { $row | Add-Member -NotePropertyName AgentPresenceSource -NotePropertyValue $stateSource -Force }
    }

    return $rows
}

function Normalize-MonitoringLifecycleRows {
    param([Parameter(Mandatory = $false)][object[]]$MonitoringRows = @())

    $rows = @($MonitoringRows | Where-Object { $_ })
    if ($rows.Count -eq 0) { return @() }

    $normalized = New-Object 'System.Collections.Generic.List[object]'
    $groups = $rows | Group-Object -Property @{ Expression = {
        $resourceId = if ($_.PSObject.Properties.Match('ResourceId').Count -gt 0 -and $_.ResourceId) { ([string]$_.ResourceId).ToLowerInvariant() } else { 'unknown-resource' }
        $feature = if ($_.PSObject.Properties.Match('Feature').Count -gt 0 -and $_.Feature) { [string]$_.Feature } else { 'DependencyAgentVmInsightsMap' }
        "$resourceId|$feature"
    } }

    foreach ($group in $groups) {
        $items = @($group.Group)
        $selected = $items | Select-Object -First 1
        $discarded = @($items | Select-Object -Skip 1)
        foreach ($duplicate in $discarded) {
            $duplicateDate = if ($duplicate.PSObject.Properties.Match('RetireOn').Count -gt 0 -and $duplicate.RetireOn) { [string]$duplicate.RetireOn } else { 'N/A' }
            $duplicateTypeId = if ($duplicate.PSObject.Properties.Match('AdvisorRecommendationTypeId').Count -gt 0 -and $duplicate.AdvisorRecommendationTypeId) { [string]$duplicate.AdvisorRecommendationTypeId } else { 'N/A' }
            Write-Log "Monitoring lifecycle duplicate discarded for $($group.Name): date=$duplicateDate recommendationTypeId=$duplicateTypeId" "INFO"
        }

        $normalized.Add([pscustomobject]@{
            ResourceId                  = if ($selected.PSObject.Properties.Match('ResourceId').Count -gt 0) { [string]$selected.ResourceId } else { '' }
            Feature                     = 'DependencyAgentVmInsightsMap'
            RetireOn                    = '2028-06-30'
            AdvisorRecommendationId     = if ($selected.PSObject.Properties.Match('AdvisorRecommendationId').Count -gt 0) { [string]$selected.AdvisorRecommendationId } else { 'N/A' }
            AdvisorRecommendationName   = if ($selected.PSObject.Properties.Match('AdvisorRecommendationName').Count -gt 0) { [string]$selected.AdvisorRecommendationName } else { 'Dependency Agent / VM Insights Map' }
            AdvisorRecommendationTypeId = if ($selected.PSObject.Properties.Match('AdvisorRecommendationTypeId').Count -gt 0) { [string]$selected.AdvisorRecommendationTypeId } else { 'N/A' }
            AdvisorSubCategory          = if ($selected.PSObject.Properties.Match('AdvisorSubCategory').Count -gt 0) { [string]$selected.AdvisorSubCategory } else { 'N/A' }
            Reason                      = if ($selected.PSObject.Properties.Match('Reason').Count -gt 0) { [string]$selected.Reason } else { 'Monitoring lifecycle' }
            AgentPresence               = if ($selected.PSObject.Properties.Match('AgentPresence').Count -gt 0 -and $selected.AgentPresence) { [string]$selected.AgentPresence } else { 'Unknown' }
            AgentPresenceSource         = if ($selected.PSObject.Properties.Match('AgentPresenceSource').Count -gt 0 -and $selected.AgentPresenceSource) { [string]$selected.AgentPresenceSource } else { 'DependencyAgentDetectionUnknown' }
        }) | Out-Null
    }

    return @($normalized.ToArray() | Sort-Object ResourceId)
}

function Render-MonitoringLifecycleTrack {
    <#
    .SYNOPSIS
    Renders the monitoring-lifecycle track (Dependency Agent / VM Insights Map EOL) as a SEPARATE
    section - explicitly NOT a compute SKU retirement - with verified facts and per-agent-state action.
    #>
    param([Parameter(Mandatory = $false)][object[]]$MonitoringRows = @())

    $rows = @(Normalize-MonitoringLifecycleRows -MonitoringRows $MonitoringRows)
    if ($rows.Count -eq 0) { return "" }

    $confirmed = @($rows | Where-Object { $_.AgentPresence -eq 'Confirmed' } | Select-Object -ExpandProperty ResourceId -Unique).Count
    $unconfirmed = @($rows | Where-Object { $_.AgentPresence -eq 'Unconfirmed' } | Select-Object -ExpandProperty ResourceId -Unique).Count
    $unknown = @($rows | Where-Object { $_.AgentPresence -eq 'Unknown' -or -not $_.AgentPresence } | Select-Object -ExpandProperty ResourceId -Unique).Count

    $html = "<section class='report-section' data-section-key='monitoring-lifecycle' data-audience='technical'>"
    $html += "<details>"
    $html += "<summary><h2 style='display:inline; margin:0; font-size:16px'>Monitoring Lifecycle (separate track - not a compute SKU retirement)</h2></summary>"
    $html += "<div class='details-content'>"
    $html += "<p><strong>Azure Monitor VM Insights &lsquo;Map&rsquo; feature &amp; Dependency Agent retire on 2028-06-30.</strong> "
    $html += "This is an <strong>Azure Monitor feature</strong> retirement, <strong>not</strong> a retirement of the VM or its compute SKU. It is tracked here separately so it is neither lost nor mistaken for a SKU retirement.</p>"
    $html += "<ul style='font-size:13px'>"
    $html += "<li><strong>No direct replacement.</strong> Azure Monitor Agent (AMA) does <strong>not</strong> replace the Map feature; AMA covers inventory tracking only. Process/dependency mapping requires a solution from Azure Marketplace.</li>"
    $html += "<li><strong>Timeline:</strong> no new OS/regions after 2025-06-30; portal onboarding blocked after 2025-09-30; full retirement 2028-06-30.</li>"
    $html += "<li><strong>Agent presence is verified deterministically</strong> via the <code>Microsoft.Azure.Monitoring.DependencyAgent</code> extension publisher (ARG), because the Advisor recommendation can fire on VMs without the agent installed (residual DCR/Policy &lsquo;Processes and dependencies (Map)&rsquo;).</li>"
    $html += "</ul>"
    $html += "<p style='font-size:13px'><strong>Agent presence:</strong> <span style='color:#dc2626;font-weight:600'>$confirmed Confirmed</span> (real offboarding action) &middot; <span style='color:#666;font-weight:600'>$unconfirmed Unconfirmed</span> (likely DCR/Policy residue - no action) &middot; <span style='color:#b45309;font-weight:600'>$unknown Unknown</span> (detection unavailable - verify manually)</p>"

    $html += "<table style='width:100%;border-collapse:collapse;margin:12px 0;border:1px solid #ccc;font-size:12px'>"
    $html += "<tr style='background-color:#f5f5f5;border-bottom:2px solid #666'>"
    $html += "<th style='padding:8px;text-align:left;border:1px solid #ccc'>VM (resource)</th>"
    $html += "<th style='padding:8px;text-align:left;border:1px solid #ccc'>Feature retiring</th>"
    $html += "<th style='padding:8px;text-align:left;border:1px solid #ccc'>Retirement date</th>"
    $html += "<th style='padding:8px;text-align:left;border:1px solid #ccc'>Agent present?</th>"
    $html += "<th style='padding:8px;text-align:left;border:1px solid #ccc'>Action</th>"
    $html += "</tr>"
    foreach ($row in $rows) {
        $state = if ($row.AgentPresence) { [string]$row.AgentPresence } else { "Unknown" }
        $vmDisplay = if ($row.ResourceId) { ([string]$row.ResourceId -split '/')[-1] } else { "N/A" }
        $action = switch ($state) {
            'Confirmed'   { "Plan offboarding before 2028-06-30; select a Marketplace mapping solution if process/dependency data is required (AMA covers inventory only)." }
            'Unconfirmed' { "No action: agent not detected on this VM. Likely a residual DCR/Policy assignment - review and remove the &lsquo;Processes and dependencies (Map)&rsquo; data collection if unused." }
            default       { "Verify manually whether the Dependency Agent is installed (detection query unavailable)." }
        }
        $stateColor = switch ($state) { 'Confirmed' { '#dc2626' } 'Unconfirmed' { '#666' } default { '#b45309' } }
        $retireDate = if ($row.RetireOn) { [string]$row.RetireOn } else { "2028-06-30" }
        $html += "<tr style='border-bottom:1px solid #ddd'>"
        $html += "<td style='padding:8px;border:1px solid #ccc;font-weight:600'>$vmDisplay</td>"
        $html += "<td style='padding:8px;border:1px solid #ccc'>Dependency Agent / VM Insights Map</td>"
        $html += "<td style='padding:8px;border:1px solid #ccc'>$retireDate</td>"
        $html += "<td style='padding:8px;border:1px solid #ccc;color:$stateColor;font-weight:600'>$state</td>"
        $html += "<td style='padding:8px;border:1px solid #ccc'>$action</td>"
        $html += "</tr>"
    }
    $html += "</table>"
    $html += "<p class='small' style='color:#666'>Sources: Azure Monitor VM Insights Map retirement (learn.microsoft.com). Dates are feature-level, not per-resource contractual deadlines.</p>"
    $html += "</div></details></section>"
    return $html
}

function Get-RetirementSourceHealth {
    <#
    .SYNOPSIS
    Evaluates the health of retirement sources (live-only mode).
    
    .DESCRIPTION
    Live-only verdict:
      - OK    : All retirement rows backed by live sources (LiveAdvisorArg / LiveLearnMarkdown).
      - WARN  : At least one live source available, but not all rows are live-backed.
      - BLOCK : No live sources available; report cannot be published without live evidence.
    #>
    param(
        [Parameter(Mandatory = $true)][object[]]$Rows
    )

    $rowsArr = @($Rows)

    # A row is a "retirement finding" ONLY when it is actually on a retirement path - i.e. it would
    # become a retirement fact row in Build-ReportFacts (retirementClass != None). Rows with no signal
    # (gate 'N/A' / EvidenceSource 'NoSignal' / no retirement date) are just VMs analysed for
    # modernisation and MUST NOT inflate the denominator, otherwise a non-retiring VM is mislabelled as a
    # "stale/unknown retirement finding" and produces a false WARN that contradicts Facts.RetireCount.
    $isRetirementFinding = {
        param($r)
        $gate = if ($r.PSObject.Properties.Match('RetirementSourceGate').Count -gt 0) { [string]$r.RetirementSourceGate } else { '' }
        $es = if ($r.PSObject.Properties.Match('EvidenceSource').Count -gt 0) { [string]$r.EvidenceSource } else { '' }
        if ($gate -eq 'LiveLearnMarkdown' -or $es -eq 'LiveLearnMarkdown' -or $es -eq 'LiveLearnMarkdown + AdvisorSignal') { return $true }
        if ($gate -eq 'LiveAdvisorArg' -or $es -eq 'AdvisorSignalOnly') { return $true }
        return $false
    }
    $findingRows = @($rowsArr | Where-Object { & $isRetirementFinding $_ })
    $liveRows = @($findingRows | Where-Object {
        $_.PSObject.Properties.Match('RetirementSourceGate').Count -gt 0 -and
        ($_.RetirementSourceGate -eq 'LiveAdvisorArg' -or $_.RetirementSourceGate -eq 'LiveLearnMarkdown')
    }).Count

    $totalRows = $findingRows.Count
    $hasRetirementEvidence = $totalRows -gt 0

    if (-not $hasRetirementEvidence) {
        $status = "OK"
        $message = "No retirement findings detected; live sources not required."
        $color = "#16a34a"; $bg = "#dcfce7"
    }
    elseif ($liveRows -eq $totalRows) {
        $status = "OK"
        $message = "All $($liveRows) retirement finding(s) backed by live sources (Azure Advisor ARG / Microsoft Learn)."
        $color = "#16a34a"; $bg = "#dcfce7"
    }
    elseif ($liveRows -gt 0) {
        $status = "WARN"
        $staleCount = $totalRows - $liveRows
        $message = "$liveRows of $totalRows retirement finding(s) backed by live sources; $staleCount from stale/unknown sources. Live sources available but coverage incomplete."
        $color = "#b45309"; $bg = "#fef3c7"
    }
    else {
        $status = "BLOCK"
        $message = "CRITICAL: No live retirement sources available. All $totalRows finding(s) lack live evidence (Advisor ARG or Learn markdown). Report cannot be published without live source verification."
        $color = "#b91c1c"; $bg = "#fee2e2"
    }

    $banner = "<div style='padding:10px 14px;margin:12px 0;border-radius:6px;background:$bg;border:1px solid $color'><strong style='color:$color'>Retirement source health: $status.</strong> <span style='font-size:13px'>$message</span></div>"

    return [pscustomobject]@{
        Status      = $status
        Message     = $message
        Banner      = $banner
        LiveCount   = $liveRows
        TotalCount  = $totalRows
    }
}

function Build-ReportFacts {
    param(
        [Parameter(Mandatory = $true)][object[]]$Rows,
        [Parameter(Mandatory = $false)][object[]]$MonitoringLifecycle = @()
    )

    $factRows = New-Object 'System.Collections.Generic.List[object]'
    $monitoringRows = @(Normalize-MonitoringLifecycleRows -MonitoringRows $MonitoringLifecycle)

    foreach ($row in @($Rows)) {
        $evidenceSource = if ($row.PSObject.Properties.Match('EvidenceSource').Count -gt 0) { [string]$row.EvidenceSource } else { '' }
        $sourceGate = if ($row.PSObject.Properties.Match('RetirementSourceGate').Count -gt 0) { [string]$row.RetirementSourceGate } else { '' }
        $retirementClass = 'None'
        if ($sourceGate -eq 'LiveLearnMarkdown' -or $evidenceSource -eq 'LiveLearnMarkdown' -or $evidenceSource -eq 'LiveLearnMarkdown + AdvisorSignal') {
            $retirementClass = 'SkuFamily'
        }
        elseif ($sourceGate -eq 'LiveAdvisorArg' -or $evidenceSource -eq 'AdvisorSignalOnly') {
            $retirementClass = 'AdvisorConfirmed'
        }

        if ($retirementClass -eq 'None') { continue }

        $retailDeltaMonthly = $null
        if ($row.PSObject.Properties.Match('RetailDeltaMonthly').Count -gt 0 -and $null -ne $row.RetailDeltaMonthly -and ([string]$row.RetailDeltaMonthly).Trim() -ne '') {
            $retailDeltaMonthly = [double]$row.RetailDeltaMonthly
        }

        $costDeltaPercent = $null
        if ($row.PSObject.Properties.Match('CostDeltaReported').Count -gt 0 -and $null -ne $row.CostDeltaReported -and ([string]$row.CostDeltaReported).Trim() -ne '') {
            $costDeltaPercent = [double]$row.CostDeltaReported
        }
        elseif ($row.PSObject.Properties.Match('CostDeltaPercent').Count -gt 0 -and $null -ne $row.CostDeltaPercent -and ([string]$row.CostDeltaPercent).Trim() -ne '') {
            $costDeltaPercent = [double]$row.CostDeltaPercent
        }

        $whatHappens = if ($retirementClass -eq 'AdvisorConfirmed') {
            'Advisor retirement signal: per-resource confirmed'
        }
        else {
            'Microsoft Learn SKU-family retirement: verify VM scope in Workbook'
        }

        $validation = if ($null -ne $retailDeltaMonthly) {
            'Retail/list price delta calculated from cached Azure Retail Prices (730h/month). Not a validated saving.'
        }
        else {
            'Retail/list price delta unavailable or meter check required.'
        }

        $nextStep = if ($retirementClass -eq 'AdvisorConfirmed') {
            'Open Advisor recommendation, confirm affected resource and plan remediation.'
        }
        else {
            'Validate affected VM in Azure Retirement Workbook, then schedule SKU migration.'
        }

        # A recommended SKU is ALWAYS proposed when a compatible target exists. Instead of withholding a
        # target for sensitive workloads, we attach warning notes: (a) a generation-boundary caution when
        # the move crosses Gen1 -> Gen2 (image/driver validation, not a simple resize) and (b) a sensitive-
        # workload caution (domain controller, SQL, etc.). Any SKU change warrants testing; these are the
        # cases that most deserve explicit attention. Only when NO compatible target exists do we show N/A.
        $recommendedSku = if ($row.PSObject.Properties.Match('CandidateTargetSku').Count -gt 0 -and $row.CandidateTargetSku) { [string]$row.CandidateTargetSku } else { 'N/A' }
        $generationChange = ($row.PSObject.Properties.Match('GenerationChange').Count -gt 0 -and [bool]$row.GenerationChange)
        $sensitiveWorkload = ($row.PSObject.Properties.Match('SensitiveWorkload').Count -gt 0 -and [bool]$row.SensitiveWorkload)
        $workloadRoleVal = if ($row.PSObject.Properties.Match('WorkloadRole').Count -gt 0) { [string]$row.WorkloadRole } else { '' }
        $noteParts = New-Object 'System.Collections.Generic.List[string]'
        if ($recommendedSku -eq 'N/A') {
            $noteParts.Add('No compatible in-family or same-shape target found; keep the current SKU and monitor the roadmap.') | Out-Null
        }
        else {
            if ($generationChange) {
                $noteParts.Add('Generation change (current SKU allows Gen1, target is Gen2-only): not a simple resize - confirm the OS image is Gen2 (or plan a Gen1->Gen2 conversion) and validate boot, drivers and extensions before migrating.') | Out-Null
            }
            if ($sensitiveWorkload) {
                $noteParts.Add("Sensitive workload$(if ($workloadRoleVal -and $workloadRoleVal -ne 'GeneralCompute') { " ($workloadRoleVal)" } else { '' }): change is delicate - validate carefully and test in a non-production window before migrating.") | Out-Null
            }
        }
        $recommendedSkuNote = ($noteParts.ToArray() -join ' ')

        # RI / Savings Plan retirement impact: surface the warning flag/note (raised in Build-Recommendations)
        # in the report. We cannot quantify the financial effect, so we append the caution to the Validation
        # cell and count it so the reader sees which retiring VMs carry impacted commitment coverage.
        $commitmentImpact = ($row.PSObject.Properties.Match('CommitmentRetirementImpact').Count -gt 0 -and [bool]$row.CommitmentRetirementImpact)
        $commitmentImpactNote = if ($row.PSObject.Properties.Match('CommitmentRetirementImpactNote').Count -gt 0) { [string]$row.CommitmentRetirementImpactNote } else { '' }
        if ($commitmentImpact -and $commitmentImpactNote) {
            $validation = "$validation $commitmentImpactNote"
        }

        $factRows.Add([pscustomobject]@{
            VmName             = [string]$row.VmName
            CurrentSku         = [string]$row.CurrentSku
            Region             = [string]$row.Region
            OsType             = if ($row.PSObject.Properties.Match('OsType').Count -gt 0 -and $row.OsType) { [string]$row.OsType } else { 'Unknown' }
            CurrentPriceOsBasis = if ($row.PSObject.Properties.Match('CurrentPriceOsBasis').Count -gt 0 -and $row.CurrentPriceOsBasis) { [string]$row.CurrentPriceOsBasis } else { 'N/A' }
            CurrentWindowsMeterAvailable = ($row.PSObject.Properties.Match('CurrentWindowsMeterAvailable').Count -gt 0 -and [bool]$row.CurrentWindowsMeterAvailable)
            RetirementClass    = $retirementClass
            WhatHappens        = $whatHappens
            RetirementDate     = if ($row.PSObject.Properties.Match('RetirementDate').Count -gt 0) { [string]$row.RetirementDate } else { 'N/A' }
            SourceTag          = if ($retirementClass -eq 'AdvisorConfirmed') { 'Advisor (per-resource, confirmed)' } else { 'Learn (SKU-family, verify in Workbook)' }
            RecommendedSku     = $recommendedSku
            RecommendedSkuNote = $recommendedSkuNote
            GenerationChange   = $generationChange
            CommitmentImpact   = $commitmentImpact
            RetailDeltaMonthly = $retailDeltaMonthly
            CostDeltaPercent   = $costDeltaPercent
            CostCovered        = ($null -ne $retailDeltaMonthly)
            Validation         = $validation
            NextStep           = $nextStep
            SortRank           = if ($retirementClass -eq 'AdvisorConfirmed') { 0 } else { 1 }
            AdvisorRecommendationId = if ($row.PSObject.Properties.Match('AdvisorRecommendationId').Count -gt 0) { [string]$row.AdvisorRecommendationId } else { 'N/A' }
        }) | Out-Null
    }

    $retirementRows = @($factRows.ToArray())
    $advisorConfirmed = @($retirementRows | Where-Object { $_.RetirementClass -eq 'AdvisorConfirmed' }).Count
    $skuFamily = @($retirementRows | Where-Object { $_.RetirementClass -eq 'SkuFamily' }).Count
    $costCovered = @($retirementRows | Where-Object { $_.CostCovered }).Count
    $costMissing = @($retirementRows | Where-Object { -not $_.CostCovered }).Count
    $recommendationWithheld = @($retirementRows | Where-Object { $_.RecommendedSku -eq 'N/A' }).Count
    $commitmentImpactCount = @($retirementRows | Where-Object { $_.CommitmentImpact }).Count
    $recommendedRows = @($retirementRows | Where-Object { $_.RecommendedSku -ne 'N/A' })
    $skuChangeWithGenChange = @($recommendedRows | Where-Object { $_.GenerationChange }).Count
    $skuChangeWithoutGenChange = @($recommendedRows | Where-Object { -not $_.GenerationChange }).Count
    $deltaValues = @($retirementRows | Where-Object { $null -ne $_.RetailDeltaMonthly } | ForEach-Object { [double]$_.RetailDeltaMonthly })
    $deltaTotal = if ($deltaValues.Count -gt 0) { [math]::Round((($deltaValues | Measure-Object -Sum).Sum), 2) } else { $null }
    $monitoringConfirmed = @($monitoringRows | Where-Object { $_.AgentPresence -eq 'Confirmed' } | Select-Object -ExpandProperty ResourceId -Unique).Count
    $monitoringUnconfirmed = @($monitoringRows | Where-Object { $_.AgentPresence -eq 'Unconfirmed' } | Select-Object -ExpandProperty ResourceId -Unique).Count
    $monitoringUnknown = @($monitoringRows | Where-Object { $_.AgentPresence -eq 'Unknown' -or -not $_.AgentPresence } | Select-Object -ExpandProperty ResourceId -Unique).Count
    $monitoringDistinctVmCount = @($monitoringRows | Select-Object -ExpandProperty ResourceId -Unique).Count

    return [pscustomobject]@{
        GeneratedAtUtc     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
        TotalVmCount       = @($Rows).Count
        RetireCount        = $retirementRows.Count
        AdvisorConfirmed   = $advisorConfirmed
        SkuFamily          = $skuFamily
        RecommendationWithheldCount = $recommendationWithheld
        CommitmentImpactCount       = $commitmentImpactCount
        SkuChangeWithGenChange      = $skuChangeWithGenChange
        SkuChangeWithoutGenChange   = $skuChangeWithoutGenChange
        CostCovered        = $costCovered
        CostMissing        = $costMissing
        RetailDeltaMonthly = $deltaTotal
        Rows               = @($retirementRows | Sort-Object SortRank, RetirementDate, VmName)
        MonitoringRows     = @($monitoringRows)
        MonitoringConfirmed = $monitoringConfirmed
        MonitoringUnconfirmed = $monitoringUnconfirmed
        MonitoringUnknown = $monitoringUnknown
        MonitoringDistinctVmCount = $monitoringDistinctVmCount
    }
}

function Assert-ReportConsistency {
    param(
        [Parameter(Mandatory = $true)]$Facts,
        [Parameter(Mandatory = $false)][object[]]$Rows = @()
    )

    if (($Facts.AdvisorConfirmed + $Facts.SkuFamily) -ne $Facts.RetireCount) {
        throw "Report consistency failure: AdvisorConfirmed + SkuFamily must equal RetireCount. AdvisorConfirmed=$($Facts.AdvisorConfirmed), SkuFamily=$($Facts.SkuFamily), RetireCount=$($Facts.RetireCount)."
    }

    if (($Facts.CostCovered + $Facts.CostMissing) -ne $Facts.RetireCount) {
        throw "Report consistency failure: CostCovered + CostMissing must equal RetireCount. CostCovered=$($Facts.CostCovered), CostMissing=$($Facts.CostMissing), RetireCount=$($Facts.RetireCount)."
    }

    if ($Facts.PSObject.Properties.Match('SkuChangeWithGenChange').Count -gt 0 -and $Facts.PSObject.Properties.Match('SkuChangeWithoutGenChange').Count -gt 0) {
        $recommendedRowCount = @($Facts.Rows | Where-Object { $_.RecommendedSku -ne 'N/A' }).Count
        if (($Facts.SkuChangeWithGenChange + $Facts.SkuChangeWithoutGenChange) -ne $recommendedRowCount) {
            throw "Report consistency failure: SkuChangeWithGenChange + SkuChangeWithoutGenChange must equal recommended-SKU rows. WithGen=$($Facts.SkuChangeWithGenChange), WithoutGen=$($Facts.SkuChangeWithoutGenChange), Recommended=$recommendedRowCount."
        }
    }

    $monitoringRows = @($Facts.MonitoringRows)
    $duplicateMonitoring = @($monitoringRows | Group-Object -Property ResourceId | Where-Object { $_.Count -gt 1 })
    if ($duplicateMonitoring.Count -gt 0) {
        throw "Report consistency failure: Monitoring lifecycle contains duplicate ResourceId row(s): $((@($duplicateMonitoring | ForEach-Object { $_.Name }) -join ', '))."
    }

    if (($Facts.MonitoringConfirmed + $Facts.MonitoringUnconfirmed + $Facts.MonitoringUnknown) -ne $Facts.MonitoringDistinctVmCount) {
        throw "Report consistency failure: Monitoring presence counters must equal distinct monitoring VM count. Confirmed=$($Facts.MonitoringConfirmed), Unconfirmed=$($Facts.MonitoringUnconfirmed), Unknown=$($Facts.MonitoringUnknown), Distinct=$($Facts.MonitoringDistinctVmCount)."
    }

    $advisorRowsWithRealId = @($Facts.Rows | Where-Object { $_.RetirementClass -eq 'AdvisorConfirmed' -and $_.AdvisorRecommendationId -and $_.AdvisorRecommendationId -ne 'N/A' }).Count
    if ($Facts.AdvisorConfirmed -ne $advisorRowsWithRealId) {
        throw "Report consistency failure: AdvisorConfirmed must equal Advisor-confirmed rows with a real recommendation ID. AdvisorConfirmed=$($Facts.AdvisorConfirmed), RowsWithRealAdvisorId=$advisorRowsWithRealId."
    }

    $confirmedWithoutArg = @($monitoringRows | Where-Object { $_.AgentPresence -eq 'Confirmed' -and $_.AgentPresenceSource -ne 'DependencyAgentArg' })
    if ($confirmedWithoutArg.Count -gt 0) {
        throw "Report consistency failure: Monitoring row(s) marked Confirmed without DependencyAgent ARG detection source: $((@($confirmedWithoutArg | ForEach-Object { $_.ResourceId }) -join ', '))."
    }

    # Pricing OS invariant: a Windows VM must be priced with the Windows retail meter WHENEVER one is
    # available for its SKU|Region. This closes the "silently priced as Linux" defect: if a Windows meter
    # exists but the row was priced on a different basis, the cost is wrong and we throw instead of shipping
    # it. A legitimate data gap (no Windows meter in the retail data) is allowed and is recorded as the
    # 'OsAgnosticFallback' basis rather than being hidden.
    foreach ($priceRow in @($Rows)) {
        if ($priceRow.PSObject.Properties.Match('OsType').Count -eq 0 -or
            $priceRow.PSObject.Properties.Match('CurrentPriceOsBasis').Count -eq 0 -or
            $priceRow.PSObject.Properties.Match('CurrentWindowsMeterAvailable').Count -eq 0) {
            continue
        }
        $osType = [string]$priceRow.OsType
        if ($osType -notmatch '(?i)windows') { continue }
        if (-not [bool]$priceRow.CurrentWindowsMeterAvailable) { continue }
        $basis = [string]$priceRow.CurrentPriceOsBasis
        if ($basis -ne 'Windows') {
            $vmNameForErr = if ($priceRow.PSObject.Properties.Match('VmName').Count -gt 0) { [string]$priceRow.VmName } else { '(unknown)' }
            $skuForErr = if ($priceRow.PSObject.Properties.Match('CurrentSku').Count -gt 0) { [string]$priceRow.CurrentSku } else { '(unknown)' }
            throw "Pricing invariant failure: Windows VM '$vmNameForErr' ($skuForErr) has a Windows retail meter available but was priced on basis '$basis'. Windows VMs must use the Windows meter (OsType=Windows => Windows price)."
        }
    }
}

function Assert-DeliveryReady {
    <#
    .SYNOPSIS
    Automated delivery-readiness gate. Ticks the "Run" (section 2) and "Post-run" (section 3)
    items of the one-page delivery checklist by reading the run activity log and the report
    facts and rows, then emits a single DELIVERY READY / NOT READY verdict.

    .DESCRIPTION
    This is the machine version of the delivery checklist. It does NOT replace the hard
    guardians that throw earlier in the pipeline (Get-RetirementSourceHealth = BLOCK,
    Assert-ReportConsistency). It re-verifies
    their outcomes plus the "10-second" manual checks in one auditable place, so a report is only
    shipped when every guardian is green and every money figure has a traceable live source.

    Golden rule: if a number has no traceable live source, the report is not delivery-ready.

    Section 2 - Run (live sources + guardians), read from the run log:
      - STREAM A OK=True (live Advisor ARG)
      - STREAM B succeeded with Series > 0 (live Learn markdown)
      - No "Retirement source health = BLOCK"
      - No "Status property not found" defect signature
      - Assert-ReportConsistency did not throw (implicit: this runs after it)

    Section 3 - Post-run (facts / rows):
      - Money-line: sum of per-row retail deltas == Executive total
      - Quadrature: RetireCount == AdvisorConfirmed + SkuFamily
      - Monitoring counted OUTSIDE the retirement total
      - OS canary: every Windows VM with a Windows meter is priced on the Windows basis
      - RI/SP retirement-impact flag surfaced
      - Provenance: live retirement source + as-of date
    #>
    param(
        [Parameter(Mandatory = $true)]$Facts,
        [Parameter(Mandatory = $false)][object[]]$Rows = @(),
        [Parameter(Mandatory = $false)]$RetirementSourceHealth,
        [Parameter(Mandatory = $false)][string]$RunLogPath = $script:RunLogPath,
        [Parameter(Mandatory = $false)][bool]$ThrowOnNotReady = $true
    )

    $checks = [System.Collections.Generic.List[object]]::new()
    $record = {
        param([string]$Section, [string]$Name, [string]$Status, [string]$Detail)
        $checks.Add([pscustomobject]@{ Section = $Section; Name = $Name; Status = $Status; Detail = $Detail }) | Out-Null
    }

    # ---- Section 2: Run (live sources + guardians), read from the run activity log ----
    $logText = ''
    if (-not [string]::IsNullOrWhiteSpace($RunLogPath) -and (Test-Path -LiteralPath $RunLogPath)) {
        try { $logText = [string](Get-Content -LiteralPath $RunLogPath -Raw -ErrorAction Stop) } catch { $logText = '' }
    }
    $haveLog = -not [string]::IsNullOrWhiteSpace($logText)

    if (-not $haveLog) {
        & $record '2. Run' 'Run activity log readable' 'WARN' "Run log not available ($RunLogPath); log-based checks skipped."
    }
    else {
        # STREAM A (live Advisor ARG)
        if ($logText -match 'STREAM A OK=True') {
            & $record '2. Run' 'STREAM A live (Advisor ARG)' 'PASS' 'STREAM A OK=True'
        }
        elseif ($logText -match 'STREAM A OK=False' -or $logText -match 'STREAM A failed') {
            & $record '2. Run' 'STREAM A live (Advisor ARG)' 'WARN' 'STREAM A did not succeed (Advisor ARG); relying on STREAM B.'
        }
        else {
            & $record '2. Run' 'STREAM A live (Advisor ARG)' 'WARN' 'STREAM A status not found in log.'
        }

        # STREAM B (live Learn markdown) - require Series > 0
        $streamBMatch = [regex]::Match($logText, 'STREAM B succeeded\. Series:\s*(\d+)')
        if ($streamBMatch.Success) {
            $seriesCount = [int]$streamBMatch.Groups[1].Value
            if ($seriesCount -gt 0) {
                & $record '2. Run' 'STREAM B live (Learn markdown)' 'PASS' "STREAM B succeeded; Series=$seriesCount"
            }
            else {
                & $record '2. Run' 'STREAM B live (Learn markdown)' 'FAIL' 'STREAM B succeeded but Series=0 (Learn markdown returned no retirement rows).'
            }
        }
        elseif ($logText -match 'STREAM B OK=True') {
            & $record '2. Run' 'STREAM B live (Learn markdown)' 'PASS' 'STREAM B OK=True'
        }
        elseif ($logText -match 'STREAM B (failed|OK=False)') {
            & $record '2. Run' 'STREAM B live (Learn markdown)' 'FAIL' 'STREAM B failed (Learn markdown unavailable).'
        }
        else {
            & $record '2. Run' 'STREAM B live (Learn markdown)' 'WARN' 'STREAM B status not found in log.'
        }

        # No BLOCK verdict from the retirement source health gate
        if ($logText -match 'Retirement source health = BLOCK') {
            & $record '2. Run' 'Retirement source health not BLOCK' 'FAIL' 'Log contains "Retirement source health = BLOCK".'
        }
        else {
            & $record '2. Run' 'Retirement source health not BLOCK' 'PASS' 'No BLOCK verdict in log.'
        }

        # Known defect signature: "Status property not found"
        if ($logText -match 'Status property not found') {
            & $record '2. Run' 'No "Status property not found" defect' 'FAIL' 'Log contains the "Status property not found" defect signature.'
        }
        else {
            & $record '2. Run' 'No "Status property not found" defect' 'PASS' 'Defect signature not present.'
        }
    }

    # Consistency guardian: we run AFTER Assert-ReportConsistency, so reaching this point means it
    # did not throw. Recorded explicitly so the checklist has an entry for it.
    & $record '2. Run' 'Assert-ReportConsistency passed' 'PASS' 'No consistency exception was thrown before this gate.'

    # ---- Section 3: Post-run (facts / rows) ----

    # Money-line: sum of per-row retail deltas == Executive total.
    $factRows = @()
    if ($Facts.PSObject.Properties.Match('Rows').Count -gt 0) { $factRows = @($Facts.Rows) }
    $rowDeltaValues = @($factRows | Where-Object {
            $_.PSObject.Properties.Match('RetailDeltaMonthly').Count -gt 0 -and $null -ne $_.RetailDeltaMonthly
        } | ForEach-Object { [double]$_.RetailDeltaMonthly })
    $recomputedDelta = if ($rowDeltaValues.Count -gt 0) { [math]::Round((($rowDeltaValues | Measure-Object -Sum).Sum), 2) } else { $null }
    $declaredDelta = if ($Facts.PSObject.Properties.Match('RetailDeltaMonthly').Count -gt 0) { $Facts.RetailDeltaMonthly } else { $null }
    if ($null -eq $recomputedDelta -and $null -eq $declaredDelta) {
        & $record '3. Post-run' 'Money-line sums to Executive total' 'PASS' 'No priced retail deltas to sum.'
    }
    elseif ($null -ne $recomputedDelta -and $null -ne $declaredDelta -and [math]::Abs([double]$recomputedDelta - [double]$declaredDelta) -le 0.01) {
        & $record '3. Post-run' 'Money-line sums to Executive total' 'PASS' ("Row-delta sum {0:0.00} == Executive total {1:0.00}" -f $recomputedDelta, [double]$declaredDelta)
    }
    else {
        & $record '3. Post-run' 'Money-line sums to Executive total' 'FAIL' ("Row-delta sum {0} != Executive total {1}." -f $recomputedDelta, $declaredDelta)
    }

    # Quadrature: RetireCount == AdvisorConfirmed + SkuFamily.
    $advisorConfirmed = if ($Facts.PSObject.Properties.Match('AdvisorConfirmed').Count -gt 0) { [int]$Facts.AdvisorConfirmed } else { 0 }
    $skuFamily = if ($Facts.PSObject.Properties.Match('SkuFamily').Count -gt 0) { [int]$Facts.SkuFamily } else { 0 }
    $retireCount = if ($Facts.PSObject.Properties.Match('RetireCount').Count -gt 0) { [int]$Facts.RetireCount } else { 0 }
    if (($advisorConfirmed + $skuFamily) -eq $retireCount) {
        & $record '3. Post-run' 'Quadrature (retirement path)' 'PASS' "$retireCount = $advisorConfirmed (Advisor) + $skuFamily (SKU-family)"
    }
    else {
        & $record '3. Post-run' 'Quadrature (retirement path)' 'FAIL' "$retireCount != $advisorConfirmed + $skuFamily."
    }

    # Monitoring counted OUTSIDE the retirement total.
    $monitoringDistinct = if ($Facts.PSObject.Properties.Match('MonitoringDistinctVmCount').Count -gt 0) { [int]$Facts.MonitoringDistinctVmCount } else { 0 }
    if ($retireCount -eq @($factRows).Count) {
        & $record '3. Post-run' 'Monitoring separate from retirement total' 'PASS' "Retire=$retireCount (retirement rows only); monitoring distinct VMs=$monitoringDistinct tracked separately."
    }
    else {
        & $record '3. Post-run' 'Monitoring separate from retirement total' 'FAIL' "RetireCount=$retireCount does not match retirement row count $(@($factRows).Count); monitoring may be mixed into the retirement total."
    }

    # OS canary: every Windows VM with a Windows meter available is priced on the Windows basis.
    $windowsMeterRows = @($Rows | Where-Object {
            $_.PSObject.Properties.Match('OsType').Count -gt 0 -and ([string]$_.OsType) -match '(?i)windows' -and
            $_.PSObject.Properties.Match('CurrentWindowsMeterAvailable').Count -gt 0 -and [bool]$_.CurrentWindowsMeterAvailable
        })
    $windowsMispriced = @($windowsMeterRows | Where-Object {
            $_.PSObject.Properties.Match('CurrentPriceOsBasis').Count -gt 0 -and ([string]$_.CurrentPriceOsBasis) -ne 'Windows'
        })
    $windowsDataGap = @($Rows | Where-Object {
            $_.PSObject.Properties.Match('OsType').Count -gt 0 -and ([string]$_.OsType) -match '(?i)windows' -and
            $_.PSObject.Properties.Match('CurrentWindowsMeterAvailable').Count -gt 0 -and -not [bool]$_.CurrentWindowsMeterAvailable
        })
    if ($windowsMispriced.Count -gt 0) {
        $misNames = (@($windowsMispriced | ForEach-Object { if ($_.PSObject.Properties.Match('VmName').Count -gt 0) { [string]$_.VmName } else { '(unknown)' } }) -join ', ')
        & $record '3. Post-run' 'OS canary (Windows meter)' 'FAIL' "Windows VM(s) not priced on the Windows meter: $misNames."
    }
    elseif ($windowsMeterRows.Count -gt 0) {
        $gapNote = if ($windowsDataGap.Count -gt 0) { " ($($windowsDataGap.Count) Windows VM(s) priced on OsAgnosticFallback due to a genuine meter data gap.)" } else { '' }
        & $record '3. Post-run' 'OS canary (Windows meter)' 'PASS' "$($windowsMeterRows.Count) Windows VM(s) priced on the Windows meter.$gapNote"
    }
    else {
        & $record '3. Post-run' 'OS canary (Windows meter)' 'PASS' 'No Windows VMs with an available Windows meter to verify.'
    }

    # RI / Savings Plan retirement-impact flag: when a commitment-covered VM is on a retirement path the
    # pipeline raises a warning flag (no cost math). Confirm the flag count reconciles with the flagged rows
    # so the "impacted commitment" caution is actually surfaced in the report.
    $commitmentImpactCount = if ($Facts.PSObject.Properties.Match('CommitmentImpactCount').Count -gt 0) { [int]$Facts.CommitmentImpactCount } else { 0 }
    $commitmentFlaggedRows = @($factRows | Where-Object { $_.PSObject.Properties.Match('CommitmentImpact').Count -gt 0 -and [bool]$_.CommitmentImpact }).Count
    if ($commitmentImpactCount -ne $commitmentFlaggedRows) {
        & $record '3. Post-run' 'RI/SP retirement-impact flag surfaced' 'FAIL' "CommitmentImpactCount=$commitmentImpactCount does not match flagged retirement rows ($commitmentFlaggedRows)."
    }
    elseif ($commitmentImpactCount -gt 0) {
        & $record '3. Post-run' 'RI/SP retirement-impact flag surfaced' 'PASS' "$commitmentImpactCount retiring VM(s) with RI/SP coverage flagged (warning only, no cost math)."
    }
    else {
        & $record '3. Post-run' 'RI/SP retirement-impact flag surfaced' 'PASS' 'No RI/SP-covered VM on a retirement path.'
    }

    # Provenance: live retirement source (from source-health) + as-of date on rows.
    $healthStatus = ''
    if ($RetirementSourceHealth -and $RetirementSourceHealth.PSObject.Properties.Match('Status').Count -gt 0) {
        $healthStatus = [string]$RetirementSourceHealth.Status
    }
    if ($healthStatus -eq 'BLOCK') {
        & $record '3. Post-run' 'Provenance: live retirement source' 'FAIL' 'Retirement source health = BLOCK (no live evidence).'
    }
    elseif ($healthStatus -eq 'WARN') {
        $hmsg = if ($RetirementSourceHealth.PSObject.Properties.Match('Message').Count -gt 0) { [string]$RetirementSourceHealth.Message } else { 'coverage incomplete' }
        & $record '3. Post-run' 'Provenance: live retirement source' 'WARN' $hmsg
    }
    elseif ($healthStatus -eq 'OK') {
        $liveCount = if ($RetirementSourceHealth.PSObject.Properties.Match('LiveCount').Count -gt 0) { [int]$RetirementSourceHealth.LiveCount } else { 0 }
        & $record '3. Post-run' 'Provenance: live retirement source' 'PASS' "Retirement source health = OK ($liveCount live-backed finding(s))."
    }
    else {
        # Fall back to inspecting the rows directly when no health object was provided.
        $liveRows = @($Rows | Where-Object {
                $_.PSObject.Properties.Match('RetirementSourceGate').Count -gt 0 -and
                ($_.RetirementSourceGate -eq 'LiveAdvisorArg' -or $_.RetirementSourceGate -eq 'LiveLearnMarkdown')
            }).Count
        if ($retireCount -gt 0 -and $liveRows -ge $retireCount) {
            & $record '3. Post-run' 'Provenance: live retirement source' 'PASS' "$liveRows retirement row(s) backed by a live source gate."
        }
        elseif ($retireCount -eq 0) {
            & $record '3. Post-run' 'Provenance: live retirement source' 'PASS' 'No retirement findings; live source not required.'
        }
        else {
            & $record '3. Post-run' 'Provenance: live retirement source' 'WARN' "Only $liveRows of $retireCount retirement row(s) carry a live source gate."
        }
    }

    # As-of provenance: retirement rows should carry an as-of date; AI provenance carries model+timestamp.
    $retireGateRows = @($Rows | Where-Object {
            $_.PSObject.Properties.Match('RetirementSourceGate').Count -gt 0 -and
            ($_.RetirementSourceGate -eq 'LiveAdvisorArg' -or $_.RetirementSourceGate -eq 'LiveLearnMarkdown')
        })
    $rowsMissingAsOf = @($retireGateRows | Where-Object {
            $_.PSObject.Properties.Match('RetirementSourceAsOf').Count -eq 0 -or
            [string]::IsNullOrWhiteSpace([string]$_.RetirementSourceAsOf) -or
            ([string]$_.RetirementSourceAsOf) -eq 'N/A'
        })
    if ($retireGateRows.Count -eq 0) {
        & $record '3. Post-run' 'Provenance: as-of timestamp' 'PASS' 'No live retirement rows requiring an as-of stamp.'
    }
    elseif ($rowsMissingAsOf.Count -eq 0) {
        & $record '3. Post-run' 'Provenance: as-of timestamp' 'PASS' "All $($retireGateRows.Count) live retirement row(s) carry an as-of date."
    }
    else {
        & $record '3. Post-run' 'Provenance: as-of timestamp' 'WARN' "$($rowsMissingAsOf.Count) live retirement row(s) missing an as-of date."
    }

    # ---- Verdict ----
    $failed = @($checks | Where-Object { $_.Status -eq 'FAIL' })
    $warned = @($checks | Where-Object { $_.Status -eq 'WARN' })
    $passed = @($checks | Where-Object { $_.Status -eq 'PASS' })
    $ready = ($failed.Count -eq 0)

    Write-Log "===== DELIVERY CHECKLIST (Assert-DeliveryReady) =====" "INFO"
    foreach ($c in $checks) {
        $lvl = switch ($c.Status) { 'PASS' { 'INFO' } 'WARN' { 'WARN' } 'FAIL' { 'ERROR' } default { 'INFO' } }
        Write-Log ("DELIVERY [{0}] {1} :: {2} - {3}" -f $c.Status, $c.Section, $c.Name, $c.Detail) $lvl
    }

    if ($ready) {
        Write-Log ("DELIVERY READY: {0} passed, {1} warning(s), 0 blocking. Report is defensible for client delivery." -f $passed.Count, $warned.Count) "INFO"
    }
    else {
        $names = (@($failed | ForEach-Object { $_.Name }) -join '; ')
        Write-Log ("DELIVERY NOT READY: {0} blocking check(s) failed: {1}. Golden rule: if a number has no traceable live source, the report does not ship." -f $failed.Count, $names) "ERROR"
        if ($ThrowOnNotReady) {
            throw "Delivery-readiness gate failed ($($failed.Count) blocking check(s)): $names."
        }
    }

    return [pscustomobject]@{
        Ready    = $ready
        Passed   = $passed.Count
        Warnings = $warned.Count
        Failed   = $failed.Count
        Checks   = @($checks.ToArray())
    }
}

function Get-SkuFamilyToken {
    <#
    .SYNOPSIS
    Extracts the VM family token (the leading letters before the first digit) from a SKU name, used to
    decide whether a recommendation crosses VM families (e.g. A1_v2 -> F1als_v7 is A -> F = cross-family).
    #>
    param([Parameter(Mandatory = $false)][string]$Sku)
    if ([string]::IsNullOrWhiteSpace($Sku)) { return '' }
    $s = $Sku -replace '^(?i)standard_', ''
    if ($s -match '^([A-Za-z]+)') { return $matches[1].ToUpperInvariant() }
    return ''
}

function Get-RemediationCostFlag {
    <#
    .SYNOPSIS
    Deterministic cost caveat (a rule, not an intuition): a delta above +30% that also crosses VM families
    reflects a compute-class change (e.g. burstable/basic -> compute-optimized), not a pure price rise.
    Returns the caveat text, or $null when the rule does not fire.
    #>
    param(
        [Parameter(Mandatory = $false)]$CostDeltaPercent,
        [Parameter(Mandatory = $false)][bool]$CrossFamily
    )
    if ($null -ne $CostDeltaPercent -and [double]$CostDeltaPercent -gt 30 -and $CrossFamily) {
        $pct = ([double]$CostDeltaPercent).ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture)
        return "The +$pct% reflects a compute-class change (e.g. burstable/basic -> compute-optimized), not a pure price rise: validate the workload truly needs sustained CPU; if it is bursty, a B-series target may be cheaper."
    }
    return $null
}

function Get-RemediationRationale {
    <#
    .SYNOPSIS
    Builds the per-VM rationale deterministically from the row's own RecommendationBasis (already computed
    upstream), plus a generation-boundary caution and the cost-class caveat when they apply. No AI.
    #>
    param(
        [Parameter(Mandatory = $true)]$Row,
        [Parameter(Mandatory = $false)][string]$CostFlag
    )
    $parts = New-Object 'System.Collections.Generic.List[string]'
    $basis = if ($Row.PSObject.Properties.Match('RecommendationBasis').Count -gt 0 -and $Row.RecommendationBasis) { [string]$Row.RecommendationBasis } else { '' }
    if ($basis) { $parts.Add($basis) | Out-Null }
    if ($Row.PSObject.Properties.Match('GenerationChange').Count -gt 0 -and [bool]$Row.GenerationChange) {
        $parts.Add('Gen1->Gen2: not a simple resize - confirm the OS image is Gen2 (UEFI) and validate boot, drivers and extensions first.') | Out-Null
    }
    if ($CostFlag) { $parts.Add($CostFlag) | Out-Null }
    return ($parts.ToArray() -join ' ')
}

function Get-RemediationChecklist {
    <#
    .SYNOPSIS
    Static, class-conditioned validation checklist for a remediation row: an always-on quota/capacity
    check plus conditional items driven by GenerationChange, cross-family, sensitive workload and RI/SP
    coverage. Deterministic - no AI.
    #>
    param(
        [Parameter(Mandatory = $true)]$Row,
        [Parameter(Mandatory = $false)][bool]$CrossFamily
    )
    $list = New-Object 'System.Collections.Generic.List[string]'
    $list.Add('Verify regional quota / capacity for the target SKU before scheduling.') | Out-Null
    if ($Row.PSObject.Properties.Match('GenerationChange').Count -gt 0 -and [bool]$Row.GenerationChange) {
        $list.Add('Gen1->Gen2: confirm the OS image is Gen2 (UEFI); validate boot, drivers and extensions.') | Out-Null
    }
    if ($CrossFamily) {
        $list.Add('Cross-family: validate CPU architecture / performance profile (sustained vs burstable) and application compatibility.') | Out-Null
    }
    if ($Row.PSObject.Properties.Match('SensitiveWorkload').Count -gt 0 -and [bool]$Row.SensitiveWorkload) {
        $role = if ($Row.PSObject.Properties.Match('WorkloadRole').Count -gt 0 -and $Row.WorkloadRole) { [string]$Row.WorkloadRole } else { 'sensitive' }
        $list.Add("Sensitive workload ($role): test in a non-production window (e.g. authentication / replication / directory sync) before cutover.") | Out-Null
    }
    if ($Row.PSObject.Properties.Match('CommitmentRetirementImpact').Count -gt 0 -and [bool]$Row.CommitmentRetirementImpact) {
        $list.Add('Reserved Instance / Savings Plan coverage is impacted on retirement - review the affected commitment.') | Out-Null
    }
    return $list.ToArray()
}

function Build-RemediationPlan {
    <#
    .SYNOPSIS
    Deterministic remediation wave plan. Assigns each retirement-path VM to exactly one wave using
    FIRST-MATCH rules (evaluation order matters), then attaches a rationale and a class checklist.

    .DESCRIPTION
    First-match wave rules (evaluated top to bottom; the first that matches wins, so a row is never
    double-counted):
      Wave 0 - Urgent (deadline < 24 months) : RetirementRiskLevel is Critical or High.
      Wave 1 - Advisor-confirmed & sensitive : gate = LiveAdvisorArg AND SensitiveWorkload.
      Wave 2 - Sensitive, same-generation    : SensitiveWorkload AND NOT GenerationChange.
      Wave 3 - Cross-family Gen1->Gen2        : GenerationChange AND cross-family.
      Wave 4 - Simple same-generation resize  : everything else.
    Order resolves the tricky rows without double counting: an Advisor-confirmed sensitive DC lands in
    Wave 1 (not Wave 3 even if it changes generation), and a High-risk row lands in Wave 0 (not Wave 3
    even if it is cross-family/gen-change). Operates only on retirement-path rows, so the wave counts
    sum to the retirement path total.
    #>
    param([Parameter(Mandatory = $true)][object[]]$Rows)

    $isRetirementFinding = {
        param($r)
        $gate = if ($r.PSObject.Properties.Match('RetirementSourceGate').Count -gt 0) { [string]$r.RetirementSourceGate } else { '' }
        $es = if ($r.PSObject.Properties.Match('EvidenceSource').Count -gt 0) { [string]$r.EvidenceSource } else { '' }
        if ($gate -eq 'LiveLearnMarkdown' -or $es -eq 'LiveLearnMarkdown' -or $es -eq 'LiveLearnMarkdown + AdvisorSignal') { return $true }
        if ($gate -eq 'LiveAdvisorArg' -or $es -eq 'AdvisorSignalOnly') { return $true }
        return $false
    }

    $waveMeta = @(
        [pscustomobject]@{ Number = 0; Title = 'Wave 0 - Urgent (deadline < 24 months)'; Note = 'Nearest retirement deadlines; schedule first.' }
        [pscustomobject]@{ Number = 1; Title = 'Wave 1 - Advisor-confirmed & sensitive'; Note = 'Per-resource Advisor signals on delicate workloads.' }
        [pscustomobject]@{ Number = 2; Title = 'Wave 2 - Sensitive workload, simple resize (same generation)'; Note = 'Same-generation resize on sensitive workloads; low technical risk.' }
        [pscustomobject]@{ Number = 3; Title = 'Wave 3 - Cross-family Gen1->Gen2 (needs architecture validation)'; Note = 'Highest validation effort: class change plus generation boundary.' }
        [pscustomobject]@{ Number = 4; Title = 'Wave 4 - Simple same-generation resize'; Note = 'Low-risk quick wins, often cost-negative.' }
    )
    $byWave = @{}; foreach ($w in $waveMeta) { $byWave[$w.Number] = New-Object 'System.Collections.Generic.List[object]' }

    $total = 0
    foreach ($row in @($Rows)) {
        if (-not (& $isRetirementFinding $row)) { continue }
        $total++

        $currentSku = if ($row.PSObject.Properties.Match('CurrentSku').Count -gt 0) { [string]$row.CurrentSku } else { '' }
        $targetSku = if ($row.PSObject.Properties.Match('CandidateTargetSku').Count -gt 0 -and $row.CandidateTargetSku) { [string]$row.CandidateTargetSku } else { 'N/A' }
        $riskLevel = if ($row.PSObject.Properties.Match('RetirementRiskLevel').Count -gt 0) { [string]$row.RetirementRiskLevel } else { '' }
        $gate = if ($row.PSObject.Properties.Match('RetirementSourceGate').Count -gt 0) { [string]$row.RetirementSourceGate } else { '' }
        $sensitive = ($row.PSObject.Properties.Match('SensitiveWorkload').Count -gt 0 -and [bool]$row.SensitiveWorkload)
        $genChange = ($row.PSObject.Properties.Match('GenerationChange').Count -gt 0 -and [bool]$row.GenerationChange)
        $crossFamily = ($targetSku -ne 'N/A' -and (Get-SkuFamilyToken $currentSku) -ne (Get-SkuFamilyToken $targetSku))

        $pct = $null
        if ($row.PSObject.Properties.Match('CostDeltaReported').Count -gt 0 -and $null -ne $row.CostDeltaReported -and ([string]$row.CostDeltaReported).Trim() -ne '') { $pct = [double]$row.CostDeltaReported }
        $delta = $null
        if ($row.PSObject.Properties.Match('RetailDeltaMonthly').Count -gt 0 -and $null -ne $row.RetailDeltaMonthly -and ([string]$row.RetailDeltaMonthly).Trim() -ne '') { $delta = [double]$row.RetailDeltaMonthly }
        $moneyText = if ($null -ne $delta) {
            $sign = if ($delta -gt 0) { '+' } else { '' }
            $m = "$sign$($delta.ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture))/mo"
            if ($null -ne $pct) { $ps = if ($pct -gt 0) { '+' } else { '' }; $m += " ($ps$($pct.ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture))%)" }
            $m
        }
        else { 'retail delta n/a' }

        $costFlag = Get-RemediationCostFlag -CostDeltaPercent $pct -CrossFamily $crossFamily

        # FIRST-MATCH wave assignment (order matters).
        $wave = if ($riskLevel -in @('Critical', 'High')) { 0 }
                elseif ($gate -eq 'LiveAdvisorArg' -and $sensitive) { 1 }
                elseif ($sensitive -and -not $genChange) { 2 }
                elseif ($genChange -and $crossFamily) { 3 }
                else { 4 }

        $item = [pscustomobject]@{
            VmName         = if ($row.PSObject.Properties.Match('VmName').Count -gt 0) { [string]$row.VmName } else { '(unknown)' }
            CurrentSku     = $currentSku
            TargetSku      = $targetSku
            Region         = if ($row.PSObject.Properties.Match('Region').Count -gt 0) { [string]$row.Region } else { '' }
            RetirementDate = if ($row.PSObject.Properties.Match('RetirementDate').Count -gt 0) { [string]$row.RetirementDate } else { 'N/A' }
            RiskLevel      = $riskLevel
            MoneyText      = $moneyText
            DeltaMonthly   = $delta
            DeltaPercent   = $pct
            CostFlag       = $costFlag
            ChangeClass    = if ($crossFamily) { 'CrossFamily' } else { 'SameFamily' }
            CrossFamily    = $crossFamily
            GenerationChange = $genChange
            Sensitive      = $sensitive
            Rationale      = Get-RemediationRationale -Row $row -CostFlag $costFlag
            Checklist      = @(Get-RemediationChecklist -Row $row -CrossFamily $crossFamily)
        }
        $byWave[$wave].Add($item) | Out-Null
    }

    $waves = foreach ($w in $waveMeta) {
        [pscustomobject]@{
            Number = $w.Number
            Title  = $w.Title
            Note   = $w.Note
            Items  = @($byWave[$w.Number].ToArray())
        }
    }

    return [pscustomobject]@{
        Waves    = @($waves)
        TotalVms = $total
    }
}

function ConvertTo-RemediationPlanHtml {
    <#
    .SYNOPSIS
    Renders the deterministic remediation wave plan (from Build-RemediationPlan) as HTML. Waves with no
    VMs are omitted.
    #>
    param([Parameter(Mandatory = $false)]$Plan)

    function ConvertTo-PlanText([object]$Value) {
        if ($null -eq $Value) { return '' }
        return [System.Net.WebUtility]::HtmlEncode([string]$Value)
    }

    if (-not $Plan -or @($Plan.Waves).Count -eq 0 -or [int]$Plan.TotalVms -eq 0) {
        return "<div class=`"note`">No retirement-path VMs to schedule; the remediation wave plan is empty for this scope.</div>"
    }

    $sb = New-Object 'System.Text.StringBuilder'
    foreach ($wave in @($Plan.Waves)) {
        $items = @($wave.Items)
        if ($items.Count -eq 0) { continue }
        [void]$sb.Append("<div class=`"wave`"><h3>$(ConvertTo-PlanText $wave.Title) <span class=`"wave-count`">($($items.Count) VM$(if ($items.Count -ne 1) { 's' }))</span></h3>")
        [void]$sb.Append("<p class=`"wave-note`">$(ConvertTo-PlanText $wave.Note)</p><ul class=`"wave-list`">")
        foreach ($it in $items) {
            $arrow = if ($it.TargetSku -and $it.TargetSku -ne 'N/A') { "$(ConvertTo-PlanText $it.CurrentSku) &rarr; $(ConvertTo-PlanText $it.TargetSku)" } else { "$(ConvertTo-PlanText $it.CurrentSku) (no compatible target)" }
            $retire = if ($it.RetirementDate -and $it.RetirementDate -ne 'N/A') { " &mdash; retires <strong>$(ConvertTo-PlanText $it.RetirementDate)</strong>" } else { '' }
            [void]$sb.Append("<li><strong>$(ConvertTo-PlanText $it.VmName)</strong> ($arrow, $(ConvertTo-PlanText $it.Region))$retire. <em>$(ConvertTo-PlanText $it.MoneyText)</em>")
            if ($it.Rationale) { [void]$sb.Append("<br/><span class=`"wave-rationale`">$(ConvertTo-PlanText $it.Rationale)</span>") }
            $checks = @($it.Checklist)
            if ($checks.Count -gt 0) {
                [void]$sb.Append('<ul class="wave-checklist">')
                foreach ($c in $checks) { [void]$sb.Append("<li>$(ConvertTo-PlanText $c)</li>") }
                [void]$sb.Append('</ul>')
            }
            [void]$sb.Append('</li>')
        }
        [void]$sb.Append('</ul></div>')
    }
    return $sb.ToString()
}

function ConvertTo-SimplifiedReportHtml {
    param(
        [Parameter(Mandatory = $true)]$Facts,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $false)]$RemediationPlan,
        [Parameter(Mandatory = $false)]$Provenance,
        [Parameter(Mandatory = $false)][string]$ExecutiveNarrativeText
    )

    function ConvertTo-HtmlText([object]$Value) {
        if ($null -eq $Value) { return '' }
        return [System.Net.WebUtility]::HtmlEncode([string]$Value)
    }

    function Format-ReportMoney([object]$Value) {
        if ($null -eq $Value -or ([string]$Value).Trim() -eq '') { return 'N/A' }
        $number = [double]$Value
        $sign = if ($number -gt 0) { '+' } else { '' }
        return ('{0}{1:N2} / month' -f $sign, $number)
    }

    function Format-ReportPercent([object]$Value) {
        if ($null -eq $Value -or ([string]$Value).Trim() -eq '') { return '' }
        $number = [double]$Value
        $sign = if ($number -gt 0) { '+' } else { '' }
        return (' ({0}{1:N2}%)' -f $sign, $number)
    }

    function Format-CompactMoney([object]$Value) {
        if ($null -eq $Value -or ([string]$Value).Trim() -eq '') { return 'n/a' }
        $number = [double]$Value
        $sign = if ($number -gt 0) { '+' } else { '' }
        return ('{0}{1:N2}/mo' -f $sign, $number)
    }

    $costImpact = if ($null -ne $Facts.RetailDeltaMonthly) { Format-ReportMoney $Facts.RetailDeltaMonthly } else { 'N/A' }
    $costImpactCompact = if ($null -ne $Facts.RetailDeltaMonthly) { Format-CompactMoney $Facts.RetailDeltaMonthly } else { 'n/a' }
    $monitoringCount = @($Facts.MonitoringRows).Count
    $genChangeCount = if ($Facts.PSObject.Properties.Match('SkuChangeWithGenChange').Count -gt 0) { [int]$Facts.SkuChangeWithGenChange } else { 0 }
    $noGenChangeCount = if ($Facts.PSObject.Properties.Match('SkuChangeWithoutGenChange').Count -gt 0) { [int]$Facts.SkuChangeWithoutGenChange } else { 0 }
    $commitmentImpactCount = if ($Facts.PSObject.Properties.Match('CommitmentImpactCount').Count -gt 0) { [int]$Facts.CommitmentImpactCount } else { 0 }

    $generatedUtc = if ($Provenance -and $Provenance.PSObject.Properties.Match('GeneratedUtc').Count -gt 0) { [string]$Provenance.GeneratedUtc } else { [string]$Facts.GeneratedAtUtc }
    $tenantCount = if ($Provenance -and $Provenance.PSObject.Properties.Match('TenantCount').Count -gt 0) { [string]$Provenance.TenantCount } else { '' }
    $subscriptionCount = if ($Provenance -and $Provenance.PSObject.Properties.Match('SubscriptionCount').Count -gt 0) { [string]$Provenance.SubscriptionCount } else { '' }
    $liveSources = if ($Provenance -and $Provenance.PSObject.Properties.Match('LiveSources').Count -gt 0) { [string]$Provenance.LiveSources } else { '' }
    $liveSourcesOk = ($Provenance -and $Provenance.PSObject.Properties.Match('LiveSourcesOk').Count -gt 0 -and [bool]$Provenance.LiveSourcesOk)
    $liveSourcesText = if ($liveSourcesOk) { 'OK' } else { 'CHECK' }
    $freshnessText = if ($liveSourcesOk) { 'Fresh' } else { 'Review' }
    $asOfText = if ($Provenance -and $Provenance.PSObject.Properties.Match('AsOf').Count -gt 0) { [string]$Provenance.AsOf } else { '' }
    $deadlineText = if ($Provenance -and $Provenance.PSObject.Properties.Match('NearestRetirementDate').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$Provenance.NearestRetirementDate)) { [string]$Provenance.NearestRetirementDate } else { 'n/a' }
    $deadlineVm = if ($Provenance -and $Provenance.PSObject.Properties.Match('NearestRetirementVm').Count -gt 0) { [string]$Provenance.NearestRetirementVm } else { '' }

    $increaseValue = $null
    foreach ($propName in @('RetailIncreaseMonthly', 'TotalRetailIncreaseMonthly', 'MonthlyRetailIncrease', 'TotalIncreaseMonthly')) {
        if ($Facts.PSObject.Properties.Match($propName).Count -gt 0 -and $null -ne $Facts.$propName) { $increaseValue = $Facts.$propName; break }
    }
    $decreaseValue = $null
    foreach ($propName in @('RetailDecreaseMonthly', 'TotalRetailDecreaseMonthly', 'MonthlyRetailDecrease', 'TotalDecreaseMonthly')) {
        if ($Facts.PSObject.Properties.Match($propName).Count -gt 0 -and $null -ne $Facts.$propName) { $decreaseValue = $Facts.$propName; break }
    }
    $hasCostSplit = ($null -ne $increaseValue -and $null -ne $decreaseValue)

    $liveCoverage = 'live sources partial'
    if ([int]$Facts.RetireCount -eq 0) {
        $liveCoverage = 'live sources n/a'
    }
    elseif (([int]$Facts.AdvisorConfirmed + [int]$Facts.SkuFamily) -eq [int]$Facts.RetireCount) {
        $liveCoverage = 'live sources ok'
    }

    $statusLine = "$(ConvertTo-HtmlText $Facts.RetireCount)/$(ConvertTo-HtmlText $Facts.TotalVmCount) on retirement path | $(ConvertTo-HtmlText $costImpactCompact) | nearest deadline $(ConvertTo-HtmlText $deadlineText) | $(ConvertTo-HtmlText $liveCoverage)"

    function Get-WaveCssClass([object]$Number) {
        return ('w{0}' -f [int]$Number)
    }

    function Get-WaveUrgency([object]$Number) {
        switch ([int]$Number) {
            0 { return 'Critical' }
            1 { return 'High' }
            2 { return 'Medium' }
            3 { return 'Architecture validation' }
            default { return 'Low' }
        }
    }

    $waveByVm = @{}
    $timelineBuilder = New-Object 'System.Text.StringBuilder'
    $waveBuilder = New-Object 'System.Text.StringBuilder'
    foreach ($wave in @($RemediationPlan.Waves)) {
        $items = @($wave.Items)
        $count = $items.Count
        $accentClass = Get-WaveCssClass $wave.Number
        $urgencyText = Get-WaveUrgency $wave.Number
        [void]$timelineBuilder.Append("<article class='timeline-card $accentClass'><div class='timeline-top'><span class='wave-code'>W$($wave.Number)</span><span class='urgency'>$(ConvertTo-HtmlText $urgencyText)</span></div><div class='timeline-count'>$(ConvertTo-HtmlText $count)</div><div class='timeline-label'>$(ConvertTo-HtmlText $wave.Title)</div></article>")

        if ($count -eq 0) { continue }
        $openAttr = if ($wave.Number -le 1) { ' open' } else { '' }
        [void]$waveBuilder.Append("<details class='wave-card $accentClass'$openAttr><summary><span class='wave-head'><span class='wave-code'>W$($wave.Number)</span> $(ConvertTo-HtmlText $wave.Title)</span><span class='wave-head-count'>$(ConvertTo-HtmlText $count) VM$(if ($count -ne 1) { 's' }) &middot; $(ConvertTo-HtmlText $urgencyText)</span></summary>")
        [void]$waveBuilder.Append("<p class='wave-note'>$(ConvertTo-HtmlText $wave.Note)</p>")
        foreach ($it in $items) {
            if ($it.PSObject.Properties.Match('VmName').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$it.VmName)) {
                $waveByVm[[string]$it.VmName] = [pscustomobject]@{ Number = [int]$wave.Number; Urgency = $urgencyText; CssClass = $accentClass }
            }
            $pathText = if ($it.TargetSku -and $it.TargetSku -ne 'N/A') {
                "$(ConvertTo-HtmlText $it.CurrentSku) &rarr; $(ConvertTo-HtmlText $it.TargetSku)"
            }
            else {
                "$(ConvertTo-HtmlText $it.CurrentSku) &rarr; no compatible target"
            }
            $deltaText = if ($null -ne $it.DeltaMonthly) { Format-CompactMoney $it.DeltaMonthly } else { ConvertTo-HtmlText $it.MoneyText }
            $deltaClass = if ($null -ne $it.DeltaMonthly -and [double]$it.DeltaMonthly -gt 0) { 'delta-up' } elseif ($null -ne $it.DeltaMonthly -and [double]$it.DeltaMonthly -lt 0) { 'delta-down' } else { 'delta-flat' }
            $badges = New-Object 'System.Collections.Generic.List[string]'
            if ($it.GenerationChange) { $badges.Add("<span class='pill pill-gen'>Gen1&rarr;Gen2</span>") | Out-Null }
            if ($it.Sensitive) { $badges.Add("<span class='pill pill-sensitive'>Sensitive</span>") | Out-Null }
            if ($it.CrossFamily) { $badges.Add("<span class='pill pill-family'>Cross-family</span>") | Out-Null }
            if ($it.CostFlag) {
                $flagText = if ($it.PSObject.Properties.Match('DeltaPercent').Count -gt 0 -and $null -ne $it.DeltaPercent) {
                    "class change (+$(([double]$it.DeltaPercent).ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture))%)"
                }
                else { 'class change' }
                $badges.Add("<span class='pill pill-flag'>$(ConvertTo-HtmlText $flagText)</span>") | Out-Null
            }
            $retireInfo = if ($it.RetirementDate -and $it.RetirementDate -ne 'N/A') { "<span class='meta'>retire date: $(ConvertTo-HtmlText $it.RetirementDate)</span>" } else { "<span class='meta'>retire date: n/a</span>" }
            [void]$waveBuilder.Append("<article class='wave-item'><div class='wave-item-top'><strong>$(ConvertTo-HtmlText $it.VmName)</strong><span class='meta'>$(ConvertTo-HtmlText $it.Region)</span></div><div class='wave-item-path'>$pathText</div><div class='wave-item-meta'><span class='delta $deltaClass'>$(ConvertTo-HtmlText $deltaText)</span>$retireInfo</div><div class='wave-item-badges'>$($badges -join '')</div>")
            if ($it.Rationale) {
                [void]$waveBuilder.Append("<div class='wave-item-rationale'>$(ConvertTo-HtmlText $it.Rationale)</div>")
            }
            $checks = @($it.Checklist | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
            if ($checks.Count -gt 0) {
                [void]$waveBuilder.Append("<details class='mini'><summary>Checklist</summary><ul>")
                foreach ($c in $checks) {
                    [void]$waveBuilder.Append("<li>$(ConvertTo-HtmlText $c)</li>")
                }
                [void]$waveBuilder.Append("</ul></details>")
            }
            [void]$waveBuilder.Append("</article>")
        }
        [void]$waveBuilder.Append("</details>")
    }

    $monitoringTableHtml = ''
    if ($monitoringCount -gt 0) {
        $monitoringTable = New-Object 'System.Text.StringBuilder'
        [void]$monitoringTable.Append("<div class='table-wrap'><table class='monitor-table'><thead><tr><th>VM</th><th>Feature retiring</th><th>Retirement date</th><th>Agent state</th><th>Action</th></tr></thead><tbody>")
        foreach ($monitoringRow in @($Facts.MonitoringRows)) {
            $state = if ($monitoringRow.PSObject.Properties.Match('AgentPresence').Count -gt 0 -and $monitoringRow.AgentPresence) { [string]$monitoringRow.AgentPresence } else { 'Unknown' }
            $resourceId = if ($monitoringRow.PSObject.Properties.Match('ResourceId').Count -gt 0) { [string]$monitoringRow.ResourceId } else { '' }
            $vmDisplay = if ($resourceId) { ($resourceId -split '/')[-1] } else { 'N/A' }
            $retireDate = if ($monitoringRow.PSObject.Properties.Match('RetireOn').Count -gt 0 -and $monitoringRow.RetireOn) { [string]$monitoringRow.RetireOn } else { '2028-06-30' }
            $stateClass = switch ($state) { 'Confirmed' { 'tag-gen' } 'Unconfirmed' { 'tag-os' } default { 'tag-advisor' } }
            $action = switch ($state) {
                'Confirmed'   { 'Plan offboarding before 2028-06-30; select a Marketplace mapping solution if process/dependency data is required.' }
                'Unconfirmed' { 'No action: Dependency Agent not detected; review residual DCR/Policy assignment if unused.' }
                default       { 'Verify manually whether the Dependency Agent is installed.' }
            }
            [void]$monitoringTable.Append("<tr><td><strong>$(ConvertTo-HtmlText $vmDisplay)</strong></td><td>Dependency Agent / VM Insights Map</td><td>$(ConvertTo-HtmlText $retireDate)</td><td><span class='tag $stateClass'>$(ConvertTo-HtmlText $state)</span></td><td>$(ConvertTo-HtmlText $action)</td></tr>")
        }
        [void]$monitoringTable.Append('</tbody></table></div>')
        $monitoringTableHtml = $monitoringTable.ToString()
    }

    $html = @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Azure SKU Modernization Report</title>
<style>
body { font-family: Segoe UI, Arial, sans-serif; color: #1f2937; margin: 0; background: linear-gradient(180deg, #f8fafc 0%, #ffffff 220px); }
main { max-width: 1180px; margin: 0 auto; padding: 24px 20px 30px; }
h1 { font-size: 28px; margin: 0 0 4px; }
h2 { font-size: 18px; margin: 18px 0 10px; }
p { line-height: 1.45; margin: 0; }
a { text-decoration: none; color: #464feb; }
.meta { color: #6b7280; font-size: 12px; }
.statusbar { margin: 14px 0 16px; border: 1px solid #dbe4ff; background: #eef2ff; color: #1e3a8a; border-radius: 10px; padding: 10px 12px; font-weight: 600; font-size: 13px; }
.kpis { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 12px; margin: 14px 0 16px; }
.kpi { border: 1px solid #e6e6e6; padding: 14px; border-radius: 10px; background: #ffffff; box-shadow: 0 1px 0 rgba(15,23,42,0.04); }
.kpi-label { color: #6b7280; font-size: 12px; }
.kpi-value { font-size: 24px; font-weight: 700; margin-top: 4px; }
.timeline { display: grid; grid-template-columns: repeat(5, minmax(0, 1fr)); gap: 8px; margin: 10px 0 14px; }
.wave-chip { border-radius: 999px; padding: 8px 10px; display: flex; align-items: center; justify-content: space-between; border: 1px solid transparent; font-weight: 700; }
.wave-chip-title { font-size: 12px; }
.wave-chip-count { font-size: 14px; }
.w0 { background: #fee2e2; border-color: #fecaca; color: #991b1b; }
.w1 { background: #ffedd5; border-color: #fed7aa; color: #9a3412; }
.w2 { background: #fef3c7; border-color: #fde68a; color: #92400e; }
.w3 { background: #dcfce7; border-color: #bbf7d0; color: #166534; }
.w4 { background: #dbeafe; border-color: #bfdbfe; color: #1e40af; }
.wave-card { border: 1px solid #e6e6e6; border-left-width: 6px; border-radius: 10px; background: #ffffff; margin: 10px 0; overflow: hidden; }
.wave-card > summary { list-style: none; cursor: pointer; padding: 12px 14px; display: flex; justify-content: space-between; align-items: center; background: #f8fafc; }
.wave-card > summary::-webkit-details-marker { display: none; }
.wave-head { font-weight: 700; font-size: 14px; }
.wave-head-count { color: #475569; font-size: 12px; font-weight: 700; }
.wave-card.w0 { border-left-color: #dc2626; }
.wave-card.w1 { border-left-color: #ea580c; }
.wave-card.w2 { border-left-color: #d97706; }
.wave-card.w3 { border-left-color: #16a34a; }
.wave-card.w4 { border-left-color: #2563eb; }
.wave-note { color: #475569; font-size: 12px; padding: 0 14px 10px; }
.wave-item { border-top: 1px solid #e6e6e6; padding: 12px 14px; }
.wave-item-top { display: flex; justify-content: space-between; gap: 10px; margin-bottom: 3px; }
.wave-item-path { font-size: 13px; margin-bottom: 6px; }
.wave-item-meta { display: flex; gap: 10px; align-items: center; margin-bottom: 6px; }
.delta { font-weight: 700; font-size: 12px; border-radius: 999px; padding: 2px 8px; }
.delta-up { background: #fee2e2; color: #991b1b; }
.delta-down { background: #dcfce7; color: #166534; }
.delta-flat { background: #e5e7eb; color: #374151; }
.wave-item-badges { display: flex; gap: 6px; flex-wrap: wrap; margin-bottom: 6px; }
.pill { border-radius: 999px; font-size: 11px; font-weight: 700; padding: 2px 8px; }
.pill-gen { background: #fee2e2; color: #991b1b; }
.pill-sensitive { background: #e0f2fe; color: #075985; }
.pill-family { background: #ede9fe; color: #5b21b6; }
.pill-flag { background: #fff7ed; color: #c2410c; border: 1px solid #fed7aa; }
.wave-item-rationale { color: #334155; font-size: 12px; margin: 3px 0 6px; }
.mini > summary { cursor: pointer; font-size: 12px; color: #334155; }
.mini ul { margin: 6px 0 0; padding-left: 18px; font-size: 12px; color: #475569; }
.tag { display: inline-block; padding: 2px 7px; border-radius: 999px; font-size: 11px; font-weight: 600; white-space: nowrap; }
.tag-advisor { background: #fef3c7; color: #92400e; }
.tag-learn { background: #e0f2fe; color: #075985; }
.tag-gen { background: #fee2e2; color: #b91c1c; }
.tag-os { background: #e5e7eb; color: #374151; }
.tag-osflag { background: #fef3c7; color: #92400e; }
.note { background: #f8fafc; border-left: 4px solid #64748b; padding: 12px 14px; margin: 12px 0; }
.disclaimer { background: #fff7ed; border-left: 4px solid #ea580c; padding: 12px 14px; margin: 16px 0; font-size: 13px; }
.coverage { background: #f0f9ff; border-left: 4px solid #0284c7; padding: 12px 16px; margin: 16px 0; font-size: 13px; }
.coverage ul { margin: 8px 0 0; padding-left: 20px; }
.accordion { border: 1px solid #e6e6e6; border-radius: 10px; background: #ffffff; margin: 12px 0; overflow: hidden; }
.accordion > summary { cursor: pointer; list-style: none; padding: 12px 14px; font-weight: 700; background: #f8fafc; }
.accordion > summary::-webkit-details-marker { display: none; }
.accordion-body { padding: 12px 14px 14px; }
.footer { color: #6b7280; font-size: 12px; margin-top: 32px; border-top: 1px solid #e6e6e6; padding-top: 16px; }
table { width: 100%; border-collapse: collapse; font-size: 12px; }
tr th, tr td { border: 1px solid #e6e6e6; vertical-align: top; }
tr th { background-color: #f5f5f5; text-align: left; padding: 8px; }
td { padding: 8px; }
ul { margin-top: 8px; }
.layout { display: grid; grid-template-columns: 280px minmax(0, 1fr); min-height: 100vh; }
.sidebar { position: fixed; inset: 0 auto 0 0; width: 240px; overflow: auto; background: #0f172a; color: #f8fafc; padding: 24px 20px; }
.sidebar h1 { font-size: 21px; line-height: 1.15; margin-bottom: 14px; }
.sidebar .side-muted, .sidebar .side-item span { color: #cbd5e1; }
.sidebar .side-item { border-top: 1px solid rgba(255,255,255,0.12); padding: 12px 0; font-size: 12px; }
.sidebar .side-item strong { display: block; color: #ffffff; font-size: 15px; margin-top: 3px; }
.freshness-badge { display: inline-flex; align-items: center; gap: 6px; border-radius: 999px; padding: 5px 9px; font-weight: 800; font-size: 11px; margin-top: 8px; }
.freshness-ok { background: #dcfce7; color: #166534; }
.freshness-warn { background: #fef3c7; color: #92400e; }
.dashboard { margin-left: 280px; padding: 22px 24px 34px; max-width: 1360px; }
.exec-band { background: #ffffff; border: 1px solid #e2e8f0; border-radius: 12px; padding: 18px; box-shadow: 0 10px 24px rgba(15,23,42,0.06); }
.exec-grid { display: grid; grid-template-columns: minmax(0, 1fr) 340px; gap: 16px; align-items: start; }
.exec-grid .kpis { grid-template-columns: repeat(2, minmax(0, 1fr)); margin: 0; }
.monitoring-panel .kpis { grid-template-columns: repeat(3, minmax(0, 1fr)); margin: 10px 0; }
.exec-narrative { color: #334155; font-size: 15px; line-height: 1.5; margin: 8px 0 12px; }
.exec-bullets { margin: 10px 0 0; padding-left: 18px; color: #334155; }
.exec-bullets li { margin: 4px 0; }
.info-strip { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 10px; margin: 14px 0; }
.info-card { border: 1px solid #e2e8f0; border-radius: 10px; background: #f8fafc; padding: 12px; }
.info-label { color: #64748b; font-size: 11px; font-weight: 800; text-transform: uppercase; letter-spacing: .04em; }
.info-value { font-size: 16px; font-weight: 800; margin-top: 5px; color: #0f172a; }
.content-grid { display: grid; grid-template-columns: minmax(0, 1fr) 360px; gap: 18px; align-items: start; margin-top: 18px; }
.panel { border: 1px solid #e2e8f0; border-radius: 12px; background: #ffffff; padding: 16px; box-shadow: 0 1px 0 rgba(15,23,42,0.04); }
.monitoring-panel { border-left: 6px solid #475569; background: #f8fafc; }
.monitoring-panel h2 { margin-top: 0; }
.outside-count { display: inline-block; border: 1px solid #cbd5e1; background: #ffffff; color: #334155; border-radius: 999px; padding: 4px 9px; font-size: 11px; font-weight: 800; margin: 6px 0 10px; }
.timeline { display: grid; grid-template-columns: repeat(5, minmax(0, 1fr)); gap: 10px; margin: 10px 0 14px; }
.timeline-card { border-radius: 10px; padding: 12px; border: 1px solid transparent; min-height: 108px; }
.timeline-top { display: flex; justify-content: space-between; gap: 8px; align-items: center; }
.wave-code { font-weight: 900; letter-spacing: .03em; }
.urgency { font-size: 11px; font-weight: 800; }
.timeline-count { font-size: 30px; font-weight: 900; line-height: 1; margin-top: 14px; }
.timeline-label { font-size: 12px; line-height: 1.25; margin-top: 8px; }
.w0 { background: #fee2e2; border-color: #fecaca; color: #991b1b; }
.w1 { background: #ffedd5; border-color: #fed7aa; color: #9a3412; }
.w2 { background: #fef3c7; border-color: #fde68a; color: #92400e; }
.w3 { background: #dbeafe; border-color: #bfdbfe; color: #1e40af; }
.w4 { background: #dcfce7; border-color: #bbf7d0; color: #166534; }
.wave-badge { display: inline-flex; align-items: center; gap: 5px; border: 1px solid transparent; border-radius: 999px; padding: 3px 8px; font-size: 11px; font-weight: 900; white-space: nowrap; }
.summary-split { display: grid; grid-template-columns: 92px minmax(0, 1fr); gap: 14px; align-items: center; }
.donut { width: 82px; height: 82px; border-radius: 50%; background: conic-gradient(#2563eb 0 50%, #b91c1c 50% 100%); position: relative; }
.donut:after { content: ''; position: absolute; inset: 18px; border-radius: 50%; background: #ffffff; }
.legend { display: grid; gap: 6px; font-size: 13px; }
.legend-row { display: flex; justify-content: space-between; gap: 10px; }
.legend-key { display: inline-flex; align-items: center; gap: 7px; }
.swatch { width: 10px; height: 10px; border-radius: 2px; display: inline-block; }
.swatch-blue { background: #2563eb; }
.swatch-red { background: #b91c1c; }
.money-grid { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 8px; }
.money-cell { border: 1px solid #e2e8f0; border-radius: 9px; padding: 10px; background: #ffffff; }
.money-label { color: #64748b; font-size: 11px; font-weight: 800; }
.money-value { font-weight: 900; margin-top: 4px; }
.table-wrap { overflow-x: auto; }
.monitor-table { margin-top: 10px; }
@media print { body { background: #ffffff; } .layout { display: block; } .sidebar { position: static; width: auto; color: #0f172a; background: #ffffff; border-bottom: 1px solid #cbd5e1; } .sidebar .side-muted, .sidebar .side-item span { color: #334155; } .sidebar .side-item strong { color: #0f172a; } .dashboard { margin-left: 0; padding: 12px 0; max-width: none; } .exec-grid, .content-grid, .info-strip, .kpis, .timeline, .money-grid { display: block; } .panel, .exec-band, .timeline-card, .kpi, .info-card { break-inside: avoid; box-shadow: none; margin: 8px 0; } details, details:not([open]) > * { display: block !important; } summary { display: block; } }
@media (max-width: 920px) { .kpis { grid-template-columns: 1fr 1fr; } .timeline { grid-template-columns: 1fr 1fr 1fr; } }
@media (max-width: 760px) { .layout { display: block; } .sidebar { position: static; width: auto; } .dashboard { margin-left: 0; padding: 14px; } .exec-grid, .content-grid, .info-strip { grid-template-columns: 1fr; } .kpis { grid-template-columns: 1fr; } .timeline { grid-template-columns: 1fr; } .wave-item-top { flex-direction: column; align-items: flex-start; } table { font-size: 11px; } }
</style>
</head>
<body>
<div class="layout">
<aside class="sidebar">
<h1>Azure SKU Modernization Report</h1>
<p class="side-muted">Not an official Microsoft tool. Validate all signals in Azure Advisor, Service Health and the Azure Retirement Workbook before migration decisions.</p>
<div class="freshness-badge $(if ($liveSourcesOk) { 'freshness-ok' } else { 'freshness-warn' })">Data Freshness: $(ConvertTo-HtmlText $freshnessText) &middot; Live sources $(ConvertTo-HtmlText $liveSourcesText) &middot; As-of $(ConvertTo-HtmlText $asOfText)</div>
<div class="side-item"><span>Generated (UTC)</span><strong>$(ConvertTo-HtmlText $generatedUtc)</strong></div>
<div class="side-item"><span>Live sources</span><strong>$(ConvertTo-HtmlText $liveSources)</strong></div>
<div class="side-item"><span>Tenants / subscriptions</span><strong>$(ConvertTo-HtmlText $tenantCount) / $(ConvertTo-HtmlText $subscriptionCount)</strong></div>
<div class="side-item"><span>As-of</span><strong>$(ConvertTo-HtmlText $asOfText)</strong></div>
</aside>
<main class="dashboard">
<section class="exec-band">
<div class="exec-grid">
<div>
<h2>Executive Summary</h2>
$(if (-not [string]::IsNullOrWhiteSpace($ExecutiveNarrativeText)) { "<p class='exec-narrative'>$(ConvertTo-HtmlText $ExecutiveNarrativeText)</p>" } else { '' })
<ul class="exec-bullets">
<li><strong>Retirement path:</strong> $(ConvertTo-HtmlText $Facts.RetireCount) VM(s) = $(ConvertTo-HtmlText $Facts.AdvisorConfirmed) Advisor-confirmed + $(ConvertTo-HtmlText $Facts.SkuFamily) SKU-family exposure.</li>
<li><strong>Retail delta/month:</strong> $(ConvertTo-HtmlText $costImpact). PAYG/list-price signal only; not a validated saving.</li>
<li><strong>Generation split:</strong> $(ConvertTo-HtmlText $noGenChangeCount) same-generation resize(s) &middot; $(ConvertTo-HtmlText $genChangeCount) Gen1&rarr;Gen2 change(s).</li>
<li><strong>Monitoring lifecycle:</strong> $(ConvertTo-HtmlText $Facts.MonitoringDistinctVmCount) VM(s) tracked separately, outside compute retirement count.</li>
</ul>
</div>
<div class="kpis">
<div class="kpi"><div class="kpi-label">Retirement path</div><div class="kpi-value">$(ConvertTo-HtmlText $Facts.RetireCount)</div></div>
<div class="kpi"><div class="kpi-label">Advisor confirmed</div><div class="kpi-value">$(ConvertTo-HtmlText $Facts.AdvisorConfirmed)</div></div>
<div class="kpi"><div class="kpi-label">SKU-family exposure</div><div class="kpi-value">$(ConvertTo-HtmlText $Facts.SkuFamily)</div></div>
<div class="kpi"><div class="kpi-label">Retail delta / month</div><div class="kpi-value">$(ConvertTo-HtmlText $costImpact)</div></div>
</div>
</div>
</section>

<section class="info-strip">
<div class="info-card"><div class="info-label">Nearest retirement deadline</div><div class="info-value">$(ConvertTo-HtmlText $deadlineText)</div><div class="meta">$(if ($deadlineVm) { "VM: $(ConvertTo-HtmlText $deadlineVm)" } else { 'No dated retirement row' })</div></div>
<div class="info-card"><div class="info-label">SKU change vs generation change</div><div class="info-value">$(ConvertTo-HtmlText $noGenChangeCount) same-gen &middot; $(ConvertTo-HtmlText $genChangeCount) Gen1&rarr;Gen2</div><div class="meta">Counts read from report facts.</div></div>
<div class="info-card"><div class="info-label">RI / Savings Plan impact</div><div class="info-value">$(ConvertTo-HtmlText $commitmentImpactCount) flagged</div><div class="meta">Warning only; no cost math invented.</div></div>
</section>

<div class="content-grid">
<div>
<section class="panel">
<h2>Remediation Plan (waves)</h2>
<div class="timeline">$($timelineBuilder.ToString())</div>
$($waveBuilder.ToString())
</section>

<section class="panel">
<h2>Summary by Change Type</h2>
<div class="summary-split"><div class="donut" aria-hidden="true"></div><div class="legend"><div class="legend-row"><span class="legend-key"><span class="swatch swatch-blue"></span>Same-generation resize</span><strong>$(ConvertTo-HtmlText $noGenChangeCount)</strong></div><div class="legend-row"><span class="legend-key"><span class="swatch swatch-red"></span>Gen1&rarr;Gen2</span><strong>$(ConvertTo-HtmlText $genChangeCount)</strong></div></div></div>
</section>

<section class="panel">
<h2>Cost Impact (monthly)</h2>
$(if ($hasCostSplit) { "<div class='money-grid'><div class='money-cell'><div class='money-label'>Total increase</div><div class='money-value'>$(ConvertTo-HtmlText (Format-ReportMoney $increaseValue))</div></div><div class='money-cell'><div class='money-label'>Total decrease</div><div class='money-value'>$(ConvertTo-HtmlText (Format-ReportMoney $decreaseValue))</div></div><div class='money-cell'><div class='money-label'>Net</div><div class='money-value'>$(ConvertTo-HtmlText $costImpact)</div></div></div>" } else { "<div class='money-grid'><div class='money-cell'><div class='money-label'>Net</div><div class='money-value'>$(ConvertTo-HtmlText $costImpact)</div></div></div>" })
</section>
</div>

<aside class="panel monitoring-panel">
<h2>Monitoring Lifecycle</h2>
<span class="outside-count">Separate track &middot; outside compute retirement count</span>
$(if ($monitoringCount -gt 0) { "<p>Dependency Agent / VM Insights Map retirement is tracked separately and does not contribute to the $(ConvertTo-HtmlText $Facts.RetireCount) compute retirement count.</p>" } else { "<p>No Dependency Agent / VM Insights Map action detected in this scope.</p>" })
<div class="kpis">
<div class="kpi"><div class="kpi-label">Confirmed</div><div class="kpi-value">$(ConvertTo-HtmlText $Facts.MonitoringConfirmed)</div></div>
<div class="kpi"><div class="kpi-label">Unconfirmed</div><div class="kpi-value">$(ConvertTo-HtmlText $Facts.MonitoringUnconfirmed)</div></div>
<div class="kpi"><div class="kpi-label">Unknown</div><div class="kpi-value">$(ConvertTo-HtmlText $Facts.MonitoringUnknown)</div></div>
</div>
$monitoringTableHtml
</aside>
</div>

<section class="panel">
<h2>CSA / Engineer Detail</h2>
<div class="table-wrap">
<table>
<thead><tr><th>Wave</th><th>VM</th><th>Current SKU</th><th>OS</th><th>What happens</th><th>Recommended SKU</th><th>Retail cost delta / month</th><th>Validation</th><th>Next step</th></tr></thead>
<tbody>
"@

    foreach ($row in @($Facts.Rows)) {
        $tagClass = if ($row.RetirementClass -eq 'AdvisorConfirmed') { 'tag-advisor' } else { 'tag-learn' }
        $costText = "$(Format-ReportMoney $row.RetailDeltaMonthly)$(Format-ReportPercent $row.CostDeltaPercent)"
        $waveInfo = if ($waveByVm.ContainsKey([string]$row.VmName)) { $waveByVm[[string]$row.VmName] } else { $null }
        $waveCell = if ($waveInfo) {
            "<span class='wave-badge $($waveInfo.CssClass)'>W$($waveInfo.Number) &middot; $(ConvertTo-HtmlText $waveInfo.Urgency)</span>"
        }
        else {
            "<span class='wave-badge'>Not assigned</span>"
        }
        $html += "<tr>"
        $html += "<td>$waveCell</td>"
        $html += "<td><strong>$(ConvertTo-HtmlText $row.VmName)</strong><br/><span class='meta'>$(ConvertTo-HtmlText $row.Region)</span></td>"
        $html += "<td>$(ConvertTo-HtmlText $row.CurrentSku)</td>"
        $osType = if ($row.PSObject.Properties.Match('OsType').Count -gt 0 -and $row.OsType) { [string]$row.OsType } else { 'Unknown' }
        $priceBasis = if ($row.PSObject.Properties.Match('CurrentPriceOsBasis').Count -gt 0 -and $row.CurrentPriceOsBasis) { [string]$row.CurrentPriceOsBasis } else { 'N/A' }
        $basisLabel = switch ($priceBasis) {
            'Windows'             { 'priced on Windows meter' }
            'Linux'               { 'priced on Linux meter' }
            'OsAgnosticFallback'  { 'priced on OS-agnostic meter (no OS-specific meter in retail data)' }
            'NoPrice'             { 'no retail price available' }
            default               { $priceBasis }
        }
        $osCell = "<span class='tag tag-os'>$(ConvertTo-HtmlText $osType)</span><br/><span class='meta'>$(ConvertTo-HtmlText $basisLabel)</span>"
        if ($osType -match '(?i)windows' -and $priceBasis -eq 'OsAgnosticFallback') {
            $osCell += "<br/><span class='tag tag-osflag'>Windows priced OS-agnostic</span>"
        }
        $html += "<td>$osCell</td>"
        $html += "<td>$(ConvertTo-HtmlText $row.WhatHappens)<br/><span class='tag $tagClass'>$(ConvertTo-HtmlText $row.SourceTag)</span><br/><span class='meta'>Date: $(ConvertTo-HtmlText $row.RetirementDate)</span></td>"
        $recommendedCell = ConvertTo-HtmlText $row.RecommendedSku
        if ($row.PSObject.Properties.Match('GenerationChange').Count -gt 0 -and $row.GenerationChange) {
            $recommendedCell = "$recommendedCell <span class='tag tag-gen'>Gen1&rarr;Gen2</span>"
        }
        if ($row.PSObject.Properties.Match('RecommendedSkuNote').Count -gt 0 -and $row.RecommendedSkuNote) {
            $recommendedCell = "$recommendedCell<br/><span class='meta'>$(ConvertTo-HtmlText $row.RecommendedSkuNote)</span>"
        }
        $html += "<td>$recommendedCell</td>"
        $html += "<td>$(ConvertTo-HtmlText $costText)</td>"
        $html += "<td>$(ConvertTo-HtmlText $row.Validation)</td>"
        $html += "<td>$(ConvertTo-HtmlText $row.NextStep)</td>"
        $html += "</tr>"
    }

    $html += @"
</tbody>
</table>
</div>
</section>

<details class="accordion" open>
<summary>Analysis Coverage</summary>
<div class="accordion-body">
<div class="coverage">
<p><strong>What this script covers:</strong> Azure Advisor recommendations in the <em>Reliability &rarr; Service Upgrade and Retirement</em> subcategory, across all SKU families (no fixed list), with retirement date / retiring feature when available.</p>
<p><strong>What it does NOT cover / manual verification required:</strong></p>
<ul>
<li>Retirements present <strong>only in Azure Service Health</strong> (not emitted by Advisor). &rarr; Check <em>Service Health &rarr; Health advisories</em> and the <em>Impacted Resources</em> tab.</li>
<li>Services not yet covered by the <em>Service Retirement Workbook</em> (partial coverage). &rarr; Verify in <em>Advisor &rarr; Workbooks &rarr; Service Retirement</em>.</li>
<li>Public announcements without a mapping to a resource. &rarr; Check <em>Azure Updates</em>.</li>
<li>Service Health retention in Azure Resource Graph is 90 days: reconcile within that window.</li>
</ul>
</div>
</div>
</details>
"@

    $html += @"
<div class="footer"><strong>Provenance:</strong> generated at $(ConvertTo-HtmlText $generatedUtc), live sources: $(ConvertTo-HtmlText $liveSources), as-of: $(ConvertTo-HtmlText $asOfText). <strong>Disclaimer:</strong> this script is not an official Microsoft tool; always validate in authoritative sources before decisions.</div>
</main>
</div>
</body>
</html>
"@

    Set-Content -Path $Path -Value $html -Encoding UTF8
}

function ConvertTo-ReportHtml {
    param(
        [Parameter(Mandatory = $true)][object[]]$Rows,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $false)][object[]]$MonitoringLifecycle = @()
    )

    $Rows = Resolve-EvidenceSource -Rows $Rows

    $retirementSourceHealth = Get-RetirementSourceHealth -Rows $Rows
    if ($retirementSourceHealth.Status -eq "BLOCK") {
        Write-Log "Retirement source health = BLOCK: $($retirementSourceHealth.Message)" "ERROR"
        throw "Report generation blocked: $($retirementSourceHealth.Message)"
    }
    elseif ($retirementSourceHealth.Status -like "WARN*") {
        Write-Log "Retirement source health = $($retirementSourceHealth.Status): $($retirementSourceHealth.Message)" "WARN"
    }

    $facts = Build-ReportFacts -Rows $Rows -MonitoringLifecycle $MonitoringLifecycle
    Assert-ReportConsistency -Facts $facts -Rows $Rows
    # Final delivery-readiness gate (section 2-3 of the delivery checklist). Runs after the hard
    # guardians; throws if any blocking check fails so a non-defensible report is never written.
    Assert-DeliveryReady -Facts $facts -Rows $Rows -RetirementSourceHealth $retirementSourceHealth | Out-Null

    # Deterministic remediation wave plan (first-match over the retirement-path rows). The wave counts
    # must sum to the retirement path total - assert it so a plan can never silently drop or double-count.
    $remediationPlan = Build-RemediationPlan -Rows $Rows
    if ([int]$remediationPlan.TotalVms -ne [int]$facts.RetireCount) {
        throw "Report consistency failure: remediation wave plan covers $($remediationPlan.TotalVms) VM(s) but the retirement path is $($facts.RetireCount). The two must be equal."
    }

    $tenantIds = @($Rows | Where-Object { $_.PSObject.Properties.Match('TenantId').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$_.TenantId) } | ForEach-Object { [string]$_.TenantId } | Select-Object -Unique)
    if ($tenantIds.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$script:EffectiveTenantId)) {
        $tenantIds = @([string]$script:EffectiveTenantId)
    }

    $subscriptionIds = @($Rows | Where-Object { $_.PSObject.Properties.Match('SubscriptionId').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$_.SubscriptionId) } | ForEach-Object { [string]$_.SubscriptionId } | Select-Object -Unique)
    if ($subscriptionIds.Count -eq 0) {
        Write-Log "Provenance assembly: subscription count is 0 because no SubscriptionId property was available on report rows." "WARN"
    }

    $asOf = ''
    if ($retirementSourceHealth -and $retirementSourceHealth.PSObject.Properties.Match('AsOf').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$retirementSourceHealth.AsOf)) {
        $asOf = [string]$retirementSourceHealth.AsOf
    }
    else {
        $asOfValues = @($Rows | Where-Object {
                $_.PSObject.Properties.Match('RetirementSourceAsOf').Count -gt 0 -and
                -not [string]::IsNullOrWhiteSpace([string]$_.RetirementSourceAsOf) -and
                ([string]$_.RetirementSourceAsOf) -ne 'N/A'
            } | ForEach-Object { [string]$_.RetirementSourceAsOf } | Select-Object -Unique)
        if ($asOfValues.Count -gt 0) { $asOf = ($asOfValues -join ', ') }
    }

    $nearestRetirementDate = ''
    $nearestRetirementVm = ''
    $nearestDateValue = $null
    foreach ($retireRow in @($facts.Rows)) {
        if ($retireRow.PSObject.Properties.Match('RetirementDate').Count -eq 0) { continue }
        $dateText = [string]$retireRow.RetirementDate
        if ([string]::IsNullOrWhiteSpace($dateText) -or $dateText -eq 'N/A') { continue }
        $parsedDate = [datetime]::MinValue
        if (-not [datetime]::TryParse($dateText, [ref]$parsedDate)) { continue }
        if ($null -eq $nearestDateValue -or $parsedDate -lt $nearestDateValue) {
            $nearestDateValue = $parsedDate
            $nearestRetirementDate = $dateText
            $nearestRetirementVm = if ($retireRow.PSObject.Properties.Match('VmName').Count -gt 0) { [string]$retireRow.VmName } else { '' }
        }
    }

    $provenance = [pscustomobject]@{
        GeneratedUtc          = [string]$facts.GeneratedAtUtc
        TenantCount           = $tenantIds.Count
        SubscriptionCount     = $subscriptionIds.Count
        LiveSources           = 'Azure Advisor (ARG), Microsoft Learn (Service Retirement Workbook)'
        LiveSourcesOk         = ($retirementSourceHealth.Status -eq 'OK')
        AsOf                  = $asOf
        NearestRetirementDate = $nearestRetirementDate
        NearestRetirementVm   = $nearestRetirementVm
    }

    $executiveNarrativeText = "This run identifies $($facts.RetireCount) VM(s) on the compute retirement path: $($facts.AdvisorConfirmed) Advisor-confirmed and $($facts.SkuFamily) SKU-family exposure. Monthly retail/list-price delta is $(if ($null -ne $facts.RetailDeltaMonthly) { ('{0}{1:N2}' -f $(if ([double]$facts.RetailDeltaMonthly -gt 0) { '+' } else { '' }), [double]$facts.RetailDeltaMonthly) } else { 'N/A' }); monitoring lifecycle findings remain separate at $($facts.MonitoringDistinctVmCount) VM(s)."

    ConvertTo-SimplifiedReportHtml -Facts $facts -Path $Path -RemediationPlan $remediationPlan -Provenance $provenance -ExecutiveNarrativeText $executiveNarrativeText
}
function Get-AdvisorHints {
    param([Parameter(Mandatory = $false)][string[]]$SubscriptionIds)

    # STAGE 0: PROBE (gate) - verify Advisor is reachable via ARG
    $probe = $null
    try {
        $probeStart = Get-Date
        $probe = Invoke-ArgQuery -Subs $SubscriptionIds -Query @"
advisorresources
| where type =~ 'microsoft.advisor/recommendations'
| summarize advisorTotal = count()
"@
        Add-ApiCallLog -Api "Invoke-ArgQuery (Probe)" -Provider "Az.ResourceGraph" -TenantId $script:EffectiveTenantId -SubscriptionId ($SubscriptionIds -join ",") -Request "AdvisorProbe" -StartedAt $probeStart -EndedAt (Get-Date) -Success $true -Meta @{ Total = if ($probe) { [int]$probe[0].advisorTotal } else { 0 } }
    } catch {
        Add-ApiCallLog -Api "Invoke-ArgQuery (Probe)" -Provider "Az.ResourceGraph" -TenantId $script:EffectiveTenantId -SubscriptionId ($SubscriptionIds -join ",") -Request "AdvisorProbe" -StartedAt $probeStart -EndedAt (Get-Date) -Success $false -ErrorMessage $_.Exception.Message
        throw "ADVISOR NOT QUERIED: Azure Resource Graph query on advisorresources failed. Verify Connect-AzAccount, Reader role, and Az.ResourceGraph module. Error: $_"
    }

    if ($null -eq $probe) {
        throw "ADVISOR NOT QUERIED: ARG returned null."
    }

    # Store probe result for Provenance block
    $script:AdvisorProbe = [pscustomobject]@{
        AdvisorQueried   = $true
        AdvisorReachable = $true
        AdvisorTotal     = [int]$probe[0].advisorTotal
        ProbeUtc         = (Get-Date).ToUniversalTime().ToString('o')
    }

    # STAGE 1: Query Service Upgrade & Retirement recommendations from ARG
    $recs = @()
    try {
        $recStart = Get-Date
        $recs = Invoke-ArgQuery -Subs $SubscriptionIds -Query @"
advisorresources
| where type =~ 'microsoft.advisor/recommendations'
| where tostring(properties.category) == 'HighAvailability'
| extend sub = tostring(properties.extendedProperties.recommendationSubCategory)
| where sub has 'Retirement' or sub has 'Upgrade'
| extend resourceId    = tolower(tostring(properties.resourceMetadata.resourceId))
| extend recTypeId     = tostring(properties.recommendationTypeId)
| extend recName       = tostring(properties.shortDescription.solution)
| extend retireDate    = tostring(properties.extendedProperties.retirementDate)
| extend retireFeature = tostring(properties.extendedProperties.retiringFeature)
| extend recStatus     = tostring(properties.recommendationStatus)
| project resourceId, recName, recId = name, recTypeId,
          subCategory = sub, retireDate, retireFeature, recStatus
"@
        Add-ApiCallLog -Api "Invoke-ArgQuery (Retirement/Upgrade)" -Provider "Az.ResourceGraph" -TenantId $script:EffectiveTenantId -SubscriptionId ($SubscriptionIds -join ",") -Request "AdvisorRetirementExtraction" -StartedAt $recStart -EndedAt (Get-Date) -Success $true -Meta @{ ResultCount = @($recs).Count }
    } catch {
        Add-ApiCallLog -Api "Invoke-ArgQuery (Retirement/Upgrade)" -Provider "Az.ResourceGraph" -TenantId $script:EffectiveTenantId -SubscriptionId ($SubscriptionIds -join ",") -Request "AdvisorRetirementExtraction" -StartedAt $recStart -EndedAt (Get-Date) -Success $false -ErrorMessage $_.Exception.Message
        Write-Log "Advisor retirement query failed (non-blocking): $($_.Exception.Message)" "WARN"
        $recs = @()
    }

    Write-Verbose "Get-AdvisorHints: Probe=$($script:AdvisorProbe.AdvisorTotal) total, $(@($recs).Count) retirement/upgrade matches"
    return @($recs)
}

# ============================================================================
#  ADVISOR RECONCILIATION: ARG-based extraction + Metadata API enrichment
# ============================================================================

# --- Helper: Invoke-ArgQuery with pagination (SkipToken handling) ---------
function Invoke-ArgQuery {
    param(
        [string] $Query,
        [string[]] $Subs,
        [bool] $UseTenantScope = $false
    )
    $all = @()
    $skipToken = $null
    do {
        $splat = @{ Query = $Query; First = 1000 }
        if ($Subs)        { $splat.Subscription = $Subs }
        elseif ($UseTenantScope) { $splat.UseTenantScope = $true }
        if ($skipToken)   { $splat.SkipToken = $skipToken }

        $resp = Search-AzGraph @splat -ErrorAction Stop
        if ($resp) { $all += $resp }
        $skipToken = $resp.SkipToken
    } while ($skipToken)
    return @($all)
}

try {
    $totalStages = if ($SkipAdvisor) { 10 } else { 11 }
    $stage = 0

    $runStamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $runDir = Join-Path $OutputRoot $runStamp
    $snapshotDir = Join-Path $OutputRoot "snapshots"
    $script:ApiLogJsonPath = Join-Path $runDir "api_calls_log.json"
    $script:ApiLogCsvPath = Join-Path $runDir "api_calls_log.csv"
    $script:RunLogPath = Join-Path $runDir "run_activity.log"

    Ensure-Directory -Path $OutputRoot
    Ensure-Directory -Path $runDir
    Ensure-Directory -Path $snapshotDir

    $runHeader = "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))][INFO] Run log initialized at '$($script:RunLogPath)'"
    Set-Content -LiteralPath $script:RunLogPath -Value $runHeader -Encoding UTF8

    Write-Log "Starting Azure SKU Modernization Analyst (MVP)"
    $stage++
    Set-MainProgress -Stage $stage -TotalStages $totalStages -Activity "Azure SKU Modernization Analyst" -Status "Initializing modules"

    Ensure-Module -Name Az.Accounts
    Ensure-Module -Name Az.ResourceGraph
    Ensure-Module -Name Az.Compute

    if (-not $SkipAdvisor) {
        Ensure-Module -Name Az.Advisor
    }

    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    $mustLogin = $false

    if (-not $ctx) {
        $mustLogin = $true
    }

    if ($ctx -and $TenantId -and $ctx.Tenant.Id -ne $TenantId) {
        Write-Log "Current tenant ($($ctx.Tenant.Id)) differs from requested tenant ($TenantId). Performing new login." "WARN"
        $mustLogin = $true
    }

    if ($mustLogin) {
        Write-Log "Starting Azure authentication"
        if ($TenantId) {
            if ($UseDeviceAuthentication) {
                $loginStart = Get-Date
                try {
                    Connect-AzAccount -Tenant $TenantId -UseDeviceAuthentication | Out-Null
                    Add-ApiCallLog -Api "Connect-AzAccount" -Provider "Az.Accounts" -TenantId $TenantId -SubscriptionId "N/A" -Request "Tenant=$TenantId;UseDeviceAuthentication=true" -StartedAt $loginStart -EndedAt (Get-Date) -Success $true
                }
                catch {
                    Add-ApiCallLog -Api "Connect-AzAccount" -Provider "Az.Accounts" -TenantId $TenantId -SubscriptionId "N/A" -Request "Tenant=$TenantId;UseDeviceAuthentication=true" -StartedAt $loginStart -EndedAt (Get-Date) -Success $false -ErrorMessage $_.Exception.Message
                    throw
                }
            }
            else {
                $loginStart = Get-Date
                try {
                    Connect-AzAccount -Tenant $TenantId | Out-Null
                    Add-ApiCallLog -Api "Connect-AzAccount" -Provider "Az.Accounts" -TenantId $TenantId -SubscriptionId "N/A" -Request "Tenant=$TenantId" -StartedAt $loginStart -EndedAt (Get-Date) -Success $true
                }
                catch {
                    Add-ApiCallLog -Api "Connect-AzAccount" -Provider "Az.Accounts" -TenantId $TenantId -SubscriptionId "N/A" -Request "Tenant=$TenantId" -StartedAt $loginStart -EndedAt (Get-Date) -Success $false -ErrorMessage $_.Exception.Message
                    throw
                }
            }
        }
        else {
            if ($UseDeviceAuthentication) {
                $loginStart = Get-Date
                try {
                    Connect-AzAccount -UseDeviceAuthentication | Out-Null
                    Add-ApiCallLog -Api "Connect-AzAccount" -Provider "Az.Accounts" -TenantId $script:EffectiveTenantId -SubscriptionId "N/A" -Request "DefaultTenant;UseDeviceAuthentication=true" -StartedAt $loginStart -EndedAt (Get-Date) -Success $true
                }
                catch {
                    Add-ApiCallLog -Api "Connect-AzAccount" -Provider "Az.Accounts" -TenantId $script:EffectiveTenantId -SubscriptionId "N/A" -Request "DefaultTenant;UseDeviceAuthentication=true" -StartedAt $loginStart -EndedAt (Get-Date) -Success $false -ErrorMessage $_.Exception.Message
                    throw
                }
            }
            else {
                $loginStart = Get-Date
                try {
                    Connect-AzAccount | Out-Null
                    Add-ApiCallLog -Api "Connect-AzAccount" -Provider "Az.Accounts" -TenantId $script:EffectiveTenantId -SubscriptionId "N/A" -Request "DefaultTenant" -StartedAt $loginStart -EndedAt (Get-Date) -Success $true
                }
                catch {
                    Add-ApiCallLog -Api "Connect-AzAccount" -Provider "Az.Accounts" -TenantId $script:EffectiveTenantId -SubscriptionId "N/A" -Request "DefaultTenant" -StartedAt $loginStart -EndedAt (Get-Date) -Success $false -ErrorMessage $_.Exception.Message
                    throw
                }
            }
        }

        $ctx = Get-AzContext -ErrorAction SilentlyContinue
        if (-not $ctx) {
            throw "Azure authentication failed. Repeat Connect-AzAccount and verify MFA/tenant."
        }
    }

    $effectiveTenantId = $TenantId
    if (-not $effectiveTenantId) {
        $effectiveTenantId = [string]$ctx.Tenant.Id
    }

    if (-not $effectiveTenantId) {
        throw "Unable to determine the effective tenant from the current context. Specify -TenantId."
    }
    $script:EffectiveTenantId = $effectiveTenantId

    Write-Log "Effective tenant in use: $effectiveTenantId"
    $effectiveSubscriptionIds = Resolve-TargetSubscriptionIds -Tenant $effectiveTenantId -RequestedSubscriptionIds $SubscriptionIds
    Write-Log "Subscriptions in scope: $(@($effectiveSubscriptionIds).Count)"

    if (@($effectiveSubscriptionIds).Count -gt 0) {
        Write-Log "Setting context to initial subscription: $($effectiveSubscriptionIds[0])"
        $ctxInitStart = Get-Date
        try {
            Set-AzContext -SubscriptionId $effectiveSubscriptionIds[0] | Out-Null
            Add-ApiCallLog -Api "Set-AzContext" -Provider "Az.Accounts" -TenantId $script:EffectiveTenantId -SubscriptionId ([string]$effectiveSubscriptionIds[0]) -Request "InitialContext" -StartedAt $ctxInitStart -EndedAt (Get-Date) -Success $true
        }
        catch {
            Add-ApiCallLog -Api "Set-AzContext" -Provider "Az.Accounts" -TenantId $script:EffectiveTenantId -SubscriptionId ([string]$effectiveSubscriptionIds[0]) -Request "InitialContext" -StartedAt $ctxInitStart -EndedAt (Get-Date) -Success $false -ErrorMessage $_.Exception.Message
            throw
        }
    }

    $effectiveCacheRoot = $CacheRoot
    if (-not $effectiveCacheRoot) {
        $effectiveCacheRoot = Join-Path $OutputRoot "cache"
    }
    Ensure-Directory -Path $effectiveCacheRoot

    $forceSkuCacheRefresh = [bool]$ForceRefreshCache
    $forceRetailCacheRefresh = [bool]$ForceRefreshCache

    if ($UsePersistentCache) {
        Write-Log "Persistent cache enabled (path: $effectiveCacheRoot; SKU TTL: ${SkuCacheTtlHours}h; Retail TTL: ${RetailCacheTtlHours}h)"
    }
    else {
        Write-Log "Persistent cache disabled (UsePersistentCache=false)" "WARN"
    }

    $effectiveRetailExpectedPages = $RetailExpectedPages
    if (-not $PSBoundParameters.ContainsKey("RetailExpectedPages")) {
        $effectiveRetailExpectedPages = Get-RetailExpectedPagesFromHistory -Root $OutputRoot -Fallback $RetailExpectedPages
    }

    $stage++
    Set-MainProgress -Stage $stage -TotalStages $totalStages -Activity "Azure SKU Modernization Analyst" -Status "Collecting VM inventory"
    Write-Log "Collecting VM inventory from Resource Graph"
    $inventory = Get-ResourceGraphVmInventory -Subscriptions $effectiveSubscriptionIds

    if (-not $inventory -or $inventory.Count -eq 0) {
        throw "No VM found. Check subscription scope/permissions."
    }

    $detectedRegions = $inventory | Select-Object -ExpandProperty Location -Unique
    if (-not $Regions -or $Regions.Count -eq 0) {
        $Regions = $detectedRegions
    }

    Write-Log "Regions analyzed: $($Regions -join ', ')"

    $stage++
    Set-MainProgress -Stage $stage -TotalStages $totalStages -Activity "Azure SKU Modernization Analyst" -Status "Collecting compute SKU catalog"
    Write-Log "Collecting compute SKU catalog"
    $catalog = Get-ComputeSkuCatalogCached -RegionsFilter $Regions -SubscriptionIdForRest $effectiveSubscriptionIds[0] -UseRestApi $UseResourceSkusRestApi -ApiVersion $ResourceSkusApiVersion -IncludeExtendedLocations:$IncludeExtendedLocationsInSkuApi -CacheDir $effectiveCacheRoot -UseCache $UsePersistentCache -TtlHours $SkuCacheTtlHours -ForceRefresh $forceSkuCacheRefresh -TenantId $script:EffectiveTenantId

    $priceMap = @{}
    $commitmentMap = @{}
    if (-not $SkipRetailApi) {
        $stage++
        Set-MainProgress -Stage $stage -TotalStages $totalStages -Activity "Azure SKU Modernization Analyst" -Status "Collecting Retail API prices"
        Write-Log "Collecting prices from Azure Retail Prices API"
        $priceMap = Get-RetailPricesForVirtualMachinesCached -RegionsFilter $Regions -ExpectedPages $effectiveRetailExpectedPages -MaxRetries $RetailMaxRetries -RetryBaseDelaySec $RetailRetryBaseDelaySec -RetryMaxDelaySec $RetailRetryMaxDelaySec -MaxParallelRequests $RetailMaxParallelRequests -TimeoutSec $RetailApiTimeoutSec -Currency $Currency -CacheDir $effectiveCacheRoot -UseCache $UsePersistentCache -TtlHours $RetailCacheTtlHours -ForceRefresh $forceRetailCacheRefresh -TenantId $script:EffectiveTenantId

        Write-Log "Collecting Reserved Instance / Savings Plan support from Azure Retail Prices API"
        $commitmentMap = Get-RetailCommitmentSignalsForVirtualMachinesCached -RegionsFilter $Regions -ExpectedPages $effectiveRetailExpectedPages -MaxRetries $RetailMaxRetries -RetryBaseDelaySec $RetailRetryBaseDelaySec -RetryMaxDelaySec $RetailRetryMaxDelaySec -MaxParallelRequests $RetailMaxParallelRequests -TimeoutSec $RetailApiTimeoutSec -Currency $Currency -CacheDir $effectiveCacheRoot -UseCache $UsePersistentCache -TtlHours $RetailCacheTtlHours -ForceRefresh $forceRetailCacheRefresh -TenantId $script:EffectiveTenantId
    }
    else {
        $stage++
        Set-MainProgress -Stage $stage -TotalStages $totalStages -Activity "Azure SKU Modernization Analyst" -Status "Retail API skipped"
        Write-Log "Retail API disabled (-SkipRetailApi)" "WARN"
    }

    $stage++
    Set-MainProgress -Stage $stage -TotalStages $totalStages -Activity "Azure SKU Modernization Analyst" -Status "Saving snapshot"
    Write-Log "Saving daily snapshot"
    $snapPath = Save-Snapshot -SnapshotDir $snapshotDir -Inventory $inventory -PriceMap $priceMap

    $stage++
    Set-MainProgress -Stage $stage -TotalStages $totalStages -Activity "Azure SKU Modernization Analyst" -Status "Computing first-seen"
    Write-Log "Computing first-seen dates from historical snapshots"
    $firstSeenMap = Get-FirstSeenDates -SnapshotDir $snapshotDir -CurrentInventory $inventory

    $stage++
    Set-MainProgress -Stage $stage -TotalStages $totalStages -Activity "Azure SKU Modernization Analyst" -Status "Loading retirement data"
    $retirements = Load-Retirements -UseOfficialList $UseOfficialRetirementList -UsePortalSource $UsePortalRetirementSource -Subscriptions $effectiveSubscriptionIds -AdvisorRetirementTypeIdBlocklist $AdvisorRetirementTypeIdBlocklist -AdvisorRetirementNameBlockPattern $AdvisorRetirementNameBlockPattern -RequireLiveRetirementSource $RequireLiveRetirementSource

    # Monitoring-lifecycle track (Dependency Agent / VM Insights Map EOL): confirm real agent presence
    # so the separate track shows deterministic Confirmed/Unconfirmed/Unknown instead of a vague caveat.
    $monitoringLifecycle = @()
    if ($retirements -and $retirements.PSObject.Properties.Match("MonitoringLifecycle").Count -gt 0 -and $retirements.MonitoringLifecycle) {
        $monitoringLifecycle = Confirm-MonitoringAgentPresence -MonitoringRows @($retirements.MonitoringLifecycle) -Subscriptions $effectiveSubscriptionIds
    }

    $advisorHints = @()
    if (-not $SkipAdvisor) {
        $stage++
        Set-MainProgress -Stage $stage -TotalStages $totalStages -Activity "Azure SKU Modernization Analyst" -Status "Collecting Azure Advisor"
        Write-Log "Collecting recommendations from Azure Advisor"
        $advisorHints = Get-AdvisorHints -SubscriptionIds $effectiveSubscriptionIds
    }

    $stage++
    Set-MainProgress -Stage $stage -TotalStages $totalStages -Activity "Azure SKU Modernization Analyst" -Status "Computing recommendations"
    Write-Log "Computing recommendations"
    $results = Build-Recommendations -Inventory $inventory -Catalog $catalog -PriceMap $priceMap -CommitmentMap $commitmentMap -FirstSeenMap $firstSeenMap -Retirements $retirements -AdvisorHints $advisorHints -Top $TopCandidates -AllowArchChange:$AllowArchitectureChange -MaxVcpuIncreaseRatio $MaxRecommendedVcpuIncreaseRatio -MaxMemoryIncreaseRatio $MaxRecommendedMemoryIncreaseRatio -MaxCostIncreasePercent $MaxRecommendedCostIncreasePercent -MinPerfRatio $MinRecommendedPerfRatio -EquivalentVcpuTolerancePercent $EquivalentVcpuTolerancePercent -EquivalentMemoryTolerancePercent $EquivalentMemoryTolerancePercent

    $stage++
    Set-MainProgress -Stage $stage -TotalStages $totalStages -Activity "Azure SKU Modernization Analyst" -Status "Generating report output"

    $results = @($results | Sort-Object VmName)

    $csvPath = Join-Path $runDir "sku_modernization_report.csv"
    $jsonPath = Join-Path $runDir "sku_modernization_report.json"
    $htmlPath = Join-Path $runDir "sku_modernization_report.html"
    $backlogPath = Join-Path $runDir "migration_backlog_items.csv"
    $advisorPath = Join-Path $runDir "advisor_hints.json"

    $results |
        Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8

    [pscustomobject]@{
        Items = $results
    } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

    Export-BacklogItems -Rows $results -Path $backlogPath

    ConvertTo-ReportHtml -Rows $results -Path $htmlPath -MonitoringLifecycle $monitoringLifecycle

    $stage++
    Set-MainProgress -Stage $stage -TotalStages $totalStages -Activity "Azure SKU Modernization Analyst" -Status "Saving advisor hints"
    $advisorHints | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $advisorPath -Encoding UTF8

    Save-RunStats -Root $OutputRoot -RetailPageCount $script:RetailLastPageCount
    Save-ApiCallLogs -JsonPath $script:ApiLogJsonPath -CsvPath $script:ApiLogCsvPath

    Write-Progress -Id 1 -Activity "Azure SKU Modernization Analyst" -Status "Completed" -Completed
    Write-Log "Report completed"
    Write-Host ""
    Write-Host "Output:" -ForegroundColor Cyan
    Write-Host "- Snapshot: $snapPath"
    Write-Host "- CSV report: $csvPath"
    Write-Host "- JSON report: $jsonPath"
    Write-Host "- HTML report: $htmlPath"
    Write-Host "- Migration backlog: $backlogPath"
    Write-Host "- Advisor hints: $advisorPath"
    Write-Host "- API call log (JSON): $($script:ApiLogJsonPath)"
    Write-Host "- API call log (CSV): $($script:ApiLogCsvPath)"
    Write-Host "- Run activity log: $($script:RunLogPath)"

    Write-Host ""
    Write-Host "Recommended automation:" -ForegroundColor Cyan
    Write-Host "1) Daily job: run script (snapshot + prices)"
    Write-Host "2) Weekly job: re-run scoring and delta analysis"
    Write-Host "3) Monthly job: publish HTML/JSON to storage/wiki"
}
catch {
    if ($script:ApiLogJsonPath -and $script:ApiLogCsvPath) {
        try {
            Save-ApiCallLogs -JsonPath $script:ApiLogJsonPath -CsvPath $script:ApiLogCsvPath
        }
        catch {
            Write-Log "Unable to save API call log during error handling: $($_.Exception.Message)" "WARN"
        }
    }

    Write-Progress -Id 1 -Activity "Azure SKU Modernization Analyst" -Status "Error" -Completed
    Write-Log $_.Exception.Message "ERROR"
    throw
}



