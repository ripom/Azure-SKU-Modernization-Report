[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Write-Log is a local script helper; keeping the established name avoids broad call-site churn.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'This is an interactive report generator and intentionally emits concise progress/status text to the console.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Some parameters are retained for CLI/backward compatibility or future source compatibility.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseBOMForUnicodeEncodedFile', '', Justification = 'Repository uses UTF-8 without BOM; HTML text contains non-ASCII entities and symbols intentionally.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'State-changing helpers operate on report output/cache paths and are not exposed as user-facing cmdlets.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Internal helper names reflect domain collections such as prices, recommendations, facts, and retirements.')]
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
    # If $RequireLiveRetirementSource=true and all enabled live streams fail, the script throws (no fabricated data).
    # If $RequireLiveRetirementSource=false and live sources fail, the report shows only available data.
    [Parameter(Mandatory = $false)]
    [bool]$RequireLiveRetirementSource = $false,

    [Parameter(Mandatory = $false)]
    [bool]$UseResourceSkusRestApi = $true,

    [Parameter(Mandatory = $false)]
    [string]$ResourceSkusApiVersion = "2026-03-02",

    [Parameter(Mandatory = $false)]
    [string]$BatchManagementApiVersion = "2025-06-01",

    [Parameter(Mandatory = $false)]
    [bool]$UseReleaseCommunicationsApi = $true,

    [Parameter(Mandatory = $false)]
    [string]$ReleaseCommunicationsApiUrl = "https://www.microsoft.com/releasecommunications/api/v2/azure?`$filter=tags/any(t:%20t%20eq%20%27Retirements%27)%20and%20(products/any(p:%20p%20eq%20%27Azure%20Dedicated%20Host%27)%20or%20products/any(p:%20p%20eq%20%27Azure%20Kubernetes%20Service%20(AKS)%27)%20or%20products/any(p:%20p%20eq%20%27Azure%20Linux%27)%20or%20products/any(p:%20p%20eq%20%27Batch%27)%20or%20products/any(p:%20p%20eq%20%27Linux%20Virtual%20Machines%27)%20or%20products/any(p:%20p%20eq%20%27Virtual%20Machine%20Scale%20Sets%27)%20or%20products/any(p:%20p%20eq%20%27Virtual%20Machines%27)%20or%20products/any(p:%20p%20eq%20%27Windows%20Virtual%20Machines%27))&`$orderby=modified%20desc",

    [Parameter(Mandatory = $false)]
    [int]$ReleaseCommunicationsLookbackMonths = 0,

    [Parameter(Mandatory = $false)]
    [int]$ReleaseCommunicationsCacheTtlHours = 24,

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
# Retirement risk thresholds. Keep these as the single source of truth for risk labels and wave urgency.
[int]$script:RiskCriticalDays = 365
[int]$script:RiskHighDays = 730
$script:WaveOrder = [ordered]@{ W0 = 0; W1 = 1; W2 = 2; W3 = 3; W4 = 4 }
[string]$script:ReportVersion = '0.10'
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
            Write-Verbose "Run log append failed; continuing with console logging. $($_.Exception.Message)"
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
            Write-Verbose "Existing run_stats.json could not be read; keeping current page count. $($_.Exception.Message)"
        }
    }

    $obj = [pscustomobject]@{
        UpdatedAt           = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        RetailLastPageCount = $effectiveRetailPageCount
    }

    $obj | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statsPath -Encoding UTF8
}

function Assert-ModuleInstalled {
    param([Parameter(Mandatory = $true)][string]$Name)

    if (-not (Get-Module -ListAvailable -Name $Name)) {
        throw "Required module not found: $Name. Install with: Install-Module $Name -Scope CurrentUser"
    }

    Import-Module $Name -ErrorAction Stop | Out-Null
}

function New-DirectoryIfMissing {
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
            $locations = @($c.Locations | ForEach-Object { ConvertTo-NormalizedLocation ([string]$_) } | Where-Object { $_ })
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
        $region = if ($e.PSObject.Properties.Match("Region").Count -gt 0) { ConvertTo-NormalizedLocation ([string]$e.Region) } else { "" }
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
        $region = if ($e.PSObject.Properties.Match("Region").Count -gt 0) { ConvertTo-NormalizedLocation ([string]$e.Region) } else { "" }
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
        Write-Verbose "HTTP status code could not be extracted from error record. $($_.Exception.Message)"
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
        regions               = @($RegionsFilter | ForEach-Object { ConvertTo-NormalizedLocation ([string]$_) } | Sort-Object -Unique)
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

function Get-ComputeSkuCatalogsBySubscription {
    param(
        [Parameter(Mandatory = $true)][string[]]$SubscriptionIds,
        [Parameter(Mandatory = $true)][object[]]$Inventory,
        [Parameter(Mandatory = $false)][string[]]$RegionsFilter,
        [Parameter(Mandatory = $false)][bool]$UseRestApi = $true,
        [Parameter(Mandatory = $false)][string]$ApiVersion = "2026-03-02",
        [Parameter(Mandatory = $false)][bool]$IncludeExtendedLocations = $true,
        [Parameter(Mandatory = $true)][string]$CacheDir,
        [Parameter(Mandatory = $true)][bool]$UseCache,
        [Parameter(Mandatory = $true)][int]$TtlHours,
        [Parameter(Mandatory = $true)][bool]$ForceRefresh,
        [Parameter(Mandatory = $false)][string]$TenantId
    )

    $catalogs = @{}
    $allowedRegions = @($RegionsFilter | ForEach-Object { ConvertTo-NormalizedLocation ([string]$_) } | Where-Object { $_ } | Sort-Object -Unique)
    foreach ($subscriptionId in @($SubscriptionIds | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)) {
        $subscriptionRegions = @($Inventory |
            Where-Object { [string]$_.SubscriptionId -eq [string]$subscriptionId } |
            ForEach-Object { ConvertTo-NormalizedLocation ([string]$_.Location) } |
            Where-Object { $_ -and ($allowedRegions.Count -eq 0 -or $_ -in $allowedRegions) } |
            Sort-Object -Unique)

        if ($subscriptionRegions.Count -eq 0) {
            Write-Log "SKU catalog skipped for subscription ${subscriptionId}: no inventory regions are in the requested region scope." "WARN"
            $catalogs[[string]$subscriptionId] = @()
            continue
        }

        try {
            $catalogs[[string]$subscriptionId] = @(Get-ComputeSkuCatalogCached `
                -RegionsFilter $subscriptionRegions `
                -SubscriptionIdForRest ([string]$subscriptionId) `
                -UseRestApi $UseRestApi `
                -ApiVersion $ApiVersion `
                -IncludeExtendedLocations:$IncludeExtendedLocations `
                -CacheDir $CacheDir `
                -UseCache $UseCache `
                -TtlHours $TtlHours `
                -ForceRefresh $ForceRefresh `
                -TenantId $TenantId)
        }
        catch {
            Write-Log "SKU catalog unavailable for subscription ${subscriptionId}; its VM recommendations require manual review. $($_.Exception.Message)" "WARN"
            $catalogs[[string]$subscriptionId] = @()
        }
    }

    return $catalogs
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
        regions  = @($RegionsFilter | ForEach-Object { ConvertTo-NormalizedLocation ([string]$_) } | Sort-Object -Unique)
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
        $requestedSet = @($context.regions | ForEach-Object { ConvertTo-NormalizedLocation ([string]$_) } | Sort-Object -Unique)
        $compatibleCaches = New-Object 'System.Collections.Generic.List[object]'
        foreach ($candidateCache in @(Get-ChildItem -LiteralPath $CacheDir -Filter 'retail_vm_prices_*.json' -File -ErrorAction SilentlyContinue)) {
            if ($candidateCache.FullName -eq (Resolve-Path -LiteralPath $cachePath -ErrorAction SilentlyContinue)) { continue }
            $candidateEnvelope = Read-CacheEnvelope -Path $candidateCache.FullName
            if (-not $candidateEnvelope -or -not $candidateEnvelope.Data -or -not $candidateEnvelope.Context) { continue }
            if ([string]$candidateEnvelope.Context.scope -ne 'retail-vm-prices') { continue }
            if ([string]$candidateEnvelope.Context.tenantId -ne [string]$context.tenantId) { continue }
            $candidateCurrency = if ($candidateEnvelope.Context.PSObject.Properties.Match('currency').Count -gt 0) { [string]$candidateEnvelope.Context.currency } else { '' }
            if ($candidateCurrency -ne [string]$context.currency) { continue }
            $candidateRegions = @($candidateEnvelope.Context.regions | ForEach-Object { ConvertTo-NormalizedLocation ([string]$_) } | Sort-Object -Unique)
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
    # rows past a few thousand records). Reservation signals are represented as standalone Retail price
    # records; Savings Plan eligibility must be read from nested data on Consumption records, not queried as
    # a standalone priceType here.
    $baseUrl = "https://prices.azure.com/api/retail/prices"
    $currencyQuery = if (-not [string]::IsNullOrWhiteSpace($Currency)) { "&currencyCode='$Currency'" } else { "" }

    $normalizedRegions = @()
    if ($RegionsFilter -and $RegionsFilter.Count -gt 0) {
        $normalizedRegions = @($RegionsFilter | ForEach-Object { ConvertTo-NormalizedLocation ([string]$_) } | Where-Object { $_ } | Sort-Object -Unique)
    }

    $kinds = @(
        [pscustomobject]@{ Kind = 'RI'; PriceType = 'Reservation'; Optional = $false }
    )

    $filterTargets = New-Object 'System.Collections.Generic.List[object]'
    $targetIndex = 0
    foreach ($k in $kinds) {
        if ($normalizedRegions.Count -gt 0) {
            foreach ($region in $normalizedRegions) {
                $targetIndex++
                $filterTargets.Add([pscustomobject]@{ Region = $region; Kind = $k.Kind; Optional = $k.Optional; Filter = "serviceName eq 'Virtual Machines' and priceType eq '$($k.PriceType)' and armRegionName eq '$region'"; ProgressId = (240 + $targetIndex) }) | Out-Null
            }
        }
        else {
            $targetIndex++
            $filterTargets.Add([pscustomobject]@{ Region = '*'; Kind = $k.Kind; Optional = $k.Optional; Filter = "serviceName eq 'Virtual Machines' and priceType eq '$($k.PriceType)'"; ProgressId = (240 + $targetIndex) }) | Out-Null
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
            Write-Progress -Id ([int]$Target.ProgressId) -ParentId 24 -Activity "Commitment $($Target.Kind): $($Target.Region)" -Status "Downloading page $($pages + 1)" -PercentComplete -1
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
        Write-Progress -Id ([int]$Target.ProgressId) -ParentId 24 -Activity "Commitment $($Target.Kind): $($Target.Region)" -Status "Completed - pages: $pages" -Completed
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
    $completedTargets = 0
    foreach ($tr in @($targetResults)) {
        $completedTargets++
        $targetPct = if ($filterTargets.Count -gt 0) { [int][math]::Round(($completedTargets / $filterTargets.Count) * 100, 0) } else { 100 }
        Write-Progress -Id 24 -ParentId 1 -Activity "Retail commitment signals" -Status "Processing filter $completedTargets/$($filterTargets.Count): $($tr.Region)" -PercentComplete $targetPct
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
            $region = ConvertTo-NormalizedLocation ([string]$item.armRegionName)
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
        regions  = @($RegionsFilter | ForEach-Object { ConvertTo-NormalizedLocation ([string]$_) } | Sort-Object -Unique)
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

function ConvertTo-NormalizedLocation {
    param([Parameter(Mandatory = $true)][string]$Location)

    return $Location.Trim().ToLowerInvariant().Replace(" ", "")
}

function ConvertTo-NormalizedSkuName {
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
    $normalizedRegions = @($RegionsFilter | ForEach-Object { ConvertTo-NormalizedLocation ([string]$_) } | Where-Object { $_ } | Sort-Object -Unique)
    $queryTargets = @(if ($normalizedRegions.Count -gt 0) { $normalizedRegions } else { '*' })
    $catalog = New-Object 'System.Collections.Generic.List[object]'
    $targetIndex = 0

    foreach ($targetRegion in $queryTargets) {
        $targetIndex++
        $base = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Compute/skus?api-version=$ApiVersion"
        if ($targetRegion -ne '*') {
            $encodedFilter = [uri]::EscapeDataString("location eq '$targetRegion'")
            $base = "$base&`$filter=$encodedFilter"
        }
        if ($IncludeExtendedLocations) {
            $base = "$base&includeExtendedLocations=true"
        }

        $url = $base
        $page = 0
        while ($url) {
            $page++
            $targetPct = [int][math]::Round((($targetIndex - 1) / $queryTargets.Count) * 100, 0)
            Write-Progress -Id 12 -ParentId 1 -Activity "Compute SKU catalog (REST)" -Status "Region $targetIndex/$($queryTargets.Count) ($targetRegion), page $page; retained $($catalog.Count)" -PercentComplete $targetPct
            $restStart = Get-Date
            try {
                $resp = Invoke-RestMethod -Uri $url -Method Get -Headers $headers -ErrorAction Stop
                Add-ApiCallLog -Api "Invoke-RestMethod" -Provider "AzureComputeResourceSkus" -TenantId $script:EffectiveTenantId -SubscriptionId $SubscriptionId -Request $url -StartedAt $restStart -EndedAt (Get-Date) -Success $true -Meta @{ Region = $targetRegion; Page = $page; Items = @($resp.value).Count }
            }
            catch {
                Add-ApiCallLog -Api "Invoke-RestMethod" -Provider "AzureComputeResourceSkus" -TenantId $script:EffectiveTenantId -SubscriptionId $SubscriptionId -Request $url -StartedAt $restStart -EndedAt (Get-Date) -Success $false -ErrorMessage $_.Exception.Message -Meta @{ Region = $targetRegion; Page = $page }
                throw
            }

            foreach ($sku in @($resp.value)) {
                if ([string]$sku.resourceType -ne "virtualMachines") { continue }

                $locations = @($sku.locations | ForEach-Object { ConvertTo-NormalizedLocation ([string]$_) } | Where-Object { $_ })
                if ($targetRegion -ne '*' -and $targetRegion -notin $locations) { continue }

                $cap = @{}
                foreach ($c in @($sku.capabilities)) {
                    $cap[[string]$c.name] = [string]$c.value
                }

                $catalog.Add([pscustomobject]@{
                    Name         = [string]$sku.name
                    Family       = if ($sku.PSObject.Properties.Match("family").Count -gt 0) { [string]$sku.family } else { "" }
                    Tier         = if ($sku.PSObject.Properties.Match("tier").Count -gt 0) { [string]$sku.tier } else { "" }
                    Size         = if ($sku.PSObject.Properties.Match("size").Count -gt 0) { [string]$sku.size } else { "" }
                    Locations    = $locations
                    Cap          = $cap
                    Restrictions = if ($sku.PSObject.Properties.Match("restrictions").Count -gt 0) { $sku.restrictions } else { @() }
                    LocationInfo = if ($sku.PSObject.Properties.Match("locationInfo").Count -gt 0) { $sku.locationInfo } else { @() }
                    ApiVersions  = if ($sku.PSObject.Properties.Match("apiVersions").Count -gt 0) { $sku.apiVersions } else { @() }
                }) | Out-Null
            }

            $url = if ($resp -and $resp.PSObject.Properties.Match("nextLink").Count -gt 0 -and $resp.nextLink) { [string]$resp.nextLink } else { $null }
            $resp = $null
        }
    }

    Write-Progress -Id 12 -ParentId 1 -Activity "Compute SKU catalog (REST)" -Status "Completed" -Completed
    return $catalog.ToArray()
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
                Location       = ConvertTo-NormalizedLocation ([string]$r.location)
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

function Get-ResourceGraphBatchPoolInventory {
    param(
        [Parameter(Mandatory = $false)][string[]]$Subscriptions,
        [Parameter(Mandatory = $false)][string]$BatchApiVersion = "2025-06-01"
    )

    $query = @"
Resources
| where type =~ 'microsoft.batch/batchaccounts/pools'
| extend idLower = tolower(id)
| extend batchAccountName = tostring(extract('(?i)/batchAccounts/([^/]+)/pools/', 1, id))
| extend poolName = tostring(extract('(?i)/pools/([^/]+)$', 1, id))
| extend vmSize = tostring(properties.vmSize)
| extend allocationState = tostring(properties.allocationState)
| extend targetDedicatedNodes = tostring(properties.scaleSettings.fixedScale.targetDedicatedNodes)
| extend targetLowPriorityNodes = tostring(properties.scaleSettings.fixedScale.targetLowPriorityNodes)
| extend targetSpotNodes = tostring(properties.scaleSettings.fixedScale.targetSpotNodes)
| extend currentDedicatedNodes = tostring(properties.currentDedicatedNodes)
| extend currentLowPriorityNodes = tostring(properties.currentLowPriorityNodes)
| project subscriptionId, resourceGroup, idLower, location, batchAccountName, poolName, vmSize, allocationState, targetDedicatedNodes, targetLowPriorityNodes, targetSpotNodes, currentDedicatedNodes, currentLowPriorityNodes
"@

    $accountQuery = @"
Resources
| where type =~ 'microsoft.batch/batchaccounts'
| project subscriptionId, resourceGroup, name, location
"@

    $subList = @($Subscriptions)
    if (@($subList).Count -eq 0) {
        $ctx = Get-AzContext -ErrorAction SilentlyContinue
        if ($ctx -and $ctx.Subscription) {
            $subList = @([string]$ctx.Subscription.Id)
        }
    }

    $inventory = New-Object 'System.Collections.Generic.List[object]'
    $batchAccounts = New-Object 'System.Collections.Generic.List[object]'
    $totalSubs = @($subList).Count
    $subIdx = 0
    foreach ($subId in $subList) {
        $subIdx++
        $pageSize = 1000
        $skipToken = $null
        $pageNumber = 0
        do {
            $pageNumber++
            $subPct = if ($totalSubs -gt 0) { [int][math]::Round((($subIdx - 1) / $totalSubs) * 100, 0) } else { 0 }
            Write-Progress -Id 20 -ParentId 1 -Activity 'Batch inventory' -Status "Pools: subscription $subIdx/$totalSubs, page $pageNumber" -PercentComplete $subPct
            $graphArgs = @{
                Query        = $query
                First        = $pageSize
                Subscription = [string]$subId
            }
            if ($skipToken) {
                $graphArgs['SkipToken'] = $skipToken
            }

            $searchStart = Get-Date
            try {
                $page = Search-AzGraph @graphArgs
                Add-ApiCallLog -Api 'Search-AzGraph' -Provider 'Az.ResourceGraph' -TenantId $script:EffectiveTenantId -SubscriptionId ([string]$subId) -Request 'BatchPoolsPublicPreview' -StartedAt $searchStart -EndedAt (Get-Date) -Success $true -Meta @{ ReturnedRows = @($page).Count }
            }
            catch {
                Add-ApiCallLog -Api 'Search-AzGraph' -Provider 'Az.ResourceGraph' -TenantId $script:EffectiveTenantId -SubscriptionId ([string]$subId) -Request 'BatchPoolsPublicPreview' -StartedAt $searchStart -EndedAt (Get-Date) -Success $false -ErrorMessage $_.Exception.Message
                Write-Log "Batch pool public preview inventory failed on subscription ${subId}: $($_.Exception.Message)" 'WARN'
                break
            }

            foreach ($r in @($page)) {
                $targetDedicated = if ($r.PSObject.Properties.Match('targetDedicatedNodes').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$r.targetDedicatedNodes)) { [string]$r.targetDedicatedNodes } else { 'N/A' }
                $targetLowPriority = if ($r.PSObject.Properties.Match('targetLowPriorityNodes').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$r.targetLowPriorityNodes)) { [string]$r.targetLowPriorityNodes } else { 'N/A' }
                $targetSpot = if ($r.PSObject.Properties.Match('targetSpotNodes').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$r.targetSpotNodes)) { [string]$r.targetSpotNodes } else { 'N/A' }
                $inventory.Add([pscustomobject]@{
                    ResourceId              = [string]$r.idLower
                    SubscriptionId          = [string]$r.subscriptionId
                    ResourceGroup           = [string]$r.resourceGroup
                    BatchAccountName        = if ($r.PSObject.Properties.Match('batchAccountName').Count -gt 0 -and $r.batchAccountName) { [string]$r.batchAccountName } else { 'N/A' }
                    PoolName                = if ($r.PSObject.Properties.Match('poolName').Count -gt 0 -and $r.poolName) { [string]$r.poolName } else { 'N/A' }
                    Location                = ConvertTo-NormalizedLocation ([string]$r.location)
                    VmSize                  = [string]$r.vmSize
                    AllocationState         = if ($r.PSObject.Properties.Match('allocationState').Count -gt 0 -and $r.allocationState) { [string]$r.allocationState } else { 'N/A' }
                    TargetDedicatedNodes    = $targetDedicated
                    TargetLowPriorityNodes  = $targetLowPriority
                    TargetSpotNodes         = $targetSpot
                    CurrentDedicatedNodes   = if ($r.PSObject.Properties.Match('currentDedicatedNodes').Count -gt 0 -and $r.currentDedicatedNodes) { [string]$r.currentDedicatedNodes } else { 'N/A' }
                    CurrentLowPriorityNodes = if ($r.PSObject.Properties.Match('currentLowPriorityNodes').Count -gt 0 -and $r.currentLowPriorityNodes) { [string]$r.currentLowPriorityNodes } else { 'N/A' }
                }) | Out-Null
            }
            $skipToken = if ($page) { $page.SkipToken } else { $null }
        } while ($skipToken)

        $skipToken = $null
        $pageNumber = 0
        do {
            $pageNumber++
            Write-Progress -Id 20 -ParentId 1 -Activity 'Batch inventory' -Status "Accounts: subscription $subIdx/$totalSubs, page $pageNumber" -PercentComplete $subPct
            $accountGraphArgs = @{
                Query        = $accountQuery
                First        = $pageSize
                Subscription = [string]$subId
            }
            if ($skipToken) {
                $accountGraphArgs['SkipToken'] = $skipToken
            }

            $accountSearchStart = Get-Date
            try {
                $accountPage = Search-AzGraph @accountGraphArgs
                Add-ApiCallLog -Api 'Search-AzGraph' -Provider 'Az.ResourceGraph' -TenantId $script:EffectiveTenantId -SubscriptionId ([string]$subId) -Request 'BatchAccountsPublicPreview' -StartedAt $accountSearchStart -EndedAt (Get-Date) -Success $true -Meta @{ ReturnedRows = @($accountPage).Count }
            }
            catch {
                Add-ApiCallLog -Api 'Search-AzGraph' -Provider 'Az.ResourceGraph' -TenantId $script:EffectiveTenantId -SubscriptionId ([string]$subId) -Request 'BatchAccountsPublicPreview' -StartedAt $accountSearchStart -EndedAt (Get-Date) -Success $false -ErrorMessage $_.Exception.Message
                Write-Log "Batch account public preview inventory failed on subscription ${subId}: $($_.Exception.Message)" 'WARN'
                break
            }

            foreach ($account in @($accountPage)) {
                $batchAccounts.Add([pscustomobject]@{
                    SubscriptionId = [string]$account.subscriptionId
                    ResourceGroup  = [string]$account.resourceGroup
                    AccountName    = [string]$account.name
                    Location       = ConvertTo-NormalizedLocation ([string]$account.location)
                }) | Out-Null
            }
            $skipToken = if ($accountPage) { $accountPage.SkipToken } else { $null }
        } while ($skipToken)
    }

    if ($batchAccounts.Count -eq 0) {
        Write-Progress -Id 20 -ParentId 1 -Activity 'Batch inventory' -Status "Completed - pools: $($inventory.Count)" -Completed
        Write-Log 'Batch pool public preview: no Batch accounts found in subscription scope.'
        return $inventory.ToArray()
    }

    Write-Log "Batch pool public preview: found $($batchAccounts.Count) Batch account(s); listing pools with Azure Batch Management REST API version $BatchApiVersion."

    $tokenValue = $null
    $tokenStart = Get-Date
    try {
        $token = Get-AzAccessToken -ResourceUrl 'https://management.azure.com/'
        Add-ApiCallLog -Api 'Get-AzAccessToken' -Provider 'Az.Accounts' -TenantId $script:EffectiveTenantId -SubscriptionId 'N/A' -Request 'ResourceUrl=https://management.azure.com/;BatchPoolsPublicPreview' -StartedAt $tokenStart -EndedAt (Get-Date) -Success $true
        if ($token -and $token.PSObject.Properties.Match('Token').Count -gt 0 -and $token.Token) {
            if ($token.Token -is [System.Security.SecureString]) {
                $tokenValue = [System.Net.NetworkCredential]::new('', $token.Token).Password
            }
            else {
                $tokenValue = [string]$token.Token
            }
        }
        if ([string]::IsNullOrWhiteSpace($tokenValue)) {
            throw 'Get-AzAccessToken returned an empty token value.'
        }
    }
    catch {
        Add-ApiCallLog -Api 'Get-AzAccessToken' -Provider 'Az.Accounts' -TenantId $script:EffectiveTenantId -SubscriptionId 'N/A' -Request 'ResourceUrl=https://management.azure.com/;BatchPoolsPublicPreview' -StartedAt $tokenStart -EndedAt (Get-Date) -Success $false -ErrorMessage $_.Exception.Message
        Write-Progress -Id 20 -ParentId 1 -Activity 'Batch inventory' -Status 'REST fallback skipped' -Completed
        Write-Log "Batch pool public preview REST fallback skipped: unable to acquire ARM token. $($_.Exception.Message)" 'WARN'
        return $inventory.ToArray()
    }

    $headers = @{ Authorization = "Bearer $tokenValue" }
    $seenPoolIds = @{}
    foreach ($existingPool in @($inventory.ToArray())) {
        if ($existingPool.PSObject.Properties.Match('ResourceId').Count -gt 0 -and $existingPool.ResourceId) {
            $seenPoolIds[[string]$existingPool.ResourceId] = $true
        }
    }

    $accountItems = @($batchAccounts.ToArray())
    $accountIndex = 0
    foreach ($account in $accountItems) {
        $accountIndex++
        if ([string]::IsNullOrWhiteSpace([string]$account.SubscriptionId) -or [string]::IsNullOrWhiteSpace([string]$account.ResourceGroup) -or [string]::IsNullOrWhiteSpace([string]$account.AccountName)) { continue }
        $encodedResourceGroup = [uri]::EscapeDataString([string]$account.ResourceGroup)
        $encodedAccountName = [uri]::EscapeDataString([string]$account.AccountName)
        $url = "https://management.azure.com/subscriptions/$($account.SubscriptionId)/resourceGroups/$encodedResourceGroup/providers/Microsoft.Batch/batchAccounts/$encodedAccountName/pools?api-version=$BatchApiVersion"
        $pageNumber = 0
        while ($url) {
            $pageNumber++
            $accountPct = if ($accountItems.Count -gt 0) { [int][math]::Round((($accountIndex - 1) / $accountItems.Count) * 100, 0) } else { 0 }
            Write-Progress -Id 20 -ParentId 1 -Activity 'Batch inventory' -Status "REST account $accountIndex/$($accountItems.Count), page $pageNumber ($($account.AccountName))" -PercentComplete $accountPct
            $poolRestStart = Get-Date
            try {
                $resp = Invoke-RestMethod -Uri $url -Method Get -Headers $headers -ErrorAction Stop
                Add-ApiCallLog -Api 'Invoke-RestMethod' -Provider 'AzureBatchManagement' -TenantId $script:EffectiveTenantId -SubscriptionId ([string]$account.SubscriptionId) -Request $url -StartedAt $poolRestStart -EndedAt (Get-Date) -Success $true -Meta @{ Account = [string]$account.AccountName; Items = @($resp.value).Count }
            }
            catch {
                Add-ApiCallLog -Api 'Invoke-RestMethod' -Provider 'AzureBatchManagement' -TenantId $script:EffectiveTenantId -SubscriptionId ([string]$account.SubscriptionId) -Request $url -StartedAt $poolRestStart -EndedAt (Get-Date) -Success $false -ErrorMessage $_.Exception.Message -Meta @{ Account = [string]$account.AccountName }
                Write-Log "Batch pool public preview REST fallback failed for account $($account.AccountName) in subscription $($account.SubscriptionId): $($_.Exception.Message)" 'WARN'
                break
            }

            foreach ($pool in @($resp.value)) {
                if (-not $pool) { continue }
                $poolId = if ($pool.PSObject.Properties.Match('id').Count -gt 0 -and $pool.id) { ([string]$pool.id).ToLowerInvariant() } else { "/subscriptions/$($account.SubscriptionId)/resourceGroups/$($account.ResourceGroup)/providers/Microsoft.Batch/batchAccounts/$($account.AccountName)/pools/$($pool.name)".ToLowerInvariant() }
                if ($seenPoolIds.ContainsKey($poolId)) { continue }
                $seenPoolIds[$poolId] = $true

                $properties = if ($pool.PSObject.Properties.Match('properties').Count -gt 0 -and $pool.properties) { $pool.properties } else { $null }
                $fixedScale = if ($properties -and $properties.PSObject.Properties.Match('scaleSettings').Count -gt 0 -and $properties.scaleSettings -and $properties.scaleSettings.PSObject.Properties.Match('fixedScale').Count -gt 0) { $properties.scaleSettings.fixedScale } else { $null }
                $poolName = if ($pool.PSObject.Properties.Match('name').Count -gt 0 -and $pool.name) { [string]$pool.name } else { ($poolId -split '/')[-1] }

                $inventory.Add([pscustomobject]@{
                    ResourceId              = $poolId
                    SubscriptionId          = [string]$account.SubscriptionId
                    ResourceGroup           = [string]$account.ResourceGroup
                    BatchAccountName        = [string]$account.AccountName
                    PoolName                = $poolName
                    Location                = [string]$account.Location
                    VmSize                  = if ($properties -and $properties.PSObject.Properties.Match('vmSize').Count -gt 0) { [string]$properties.vmSize } else { '' }
                    AllocationState         = if ($properties -and $properties.PSObject.Properties.Match('allocationState').Count -gt 0 -and $properties.allocationState) { [string]$properties.allocationState } else { 'N/A' }
                    TargetDedicatedNodes    = if ($fixedScale -and $fixedScale.PSObject.Properties.Match('targetDedicatedNodes').Count -gt 0 -and $null -ne $fixedScale.targetDedicatedNodes) { [string]$fixedScale.targetDedicatedNodes } else { 'N/A' }
                    TargetLowPriorityNodes  = if ($fixedScale -and $fixedScale.PSObject.Properties.Match('targetLowPriorityNodes').Count -gt 0 -and $null -ne $fixedScale.targetLowPriorityNodes) { [string]$fixedScale.targetLowPriorityNodes } else { 'N/A' }
                    TargetSpotNodes         = 'N/A'
                    CurrentDedicatedNodes   = if ($properties -and $properties.PSObject.Properties.Match('currentDedicatedNodes').Count -gt 0 -and $null -ne $properties.currentDedicatedNodes) { [string]$properties.currentDedicatedNodes } else { 'N/A' }
                    CurrentLowPriorityNodes = if ($properties -and $properties.PSObject.Properties.Match('currentLowPriorityNodes').Count -gt 0 -and $null -ne $properties.currentLowPriorityNodes) { [string]$properties.currentLowPriorityNodes } else { 'N/A' }
                }) | Out-Null
            }

            $url = if ($resp -and $resp.PSObject.Properties.Match('nextLink').Count -gt 0 -and $resp.nextLink) { [string]$resp.nextLink } else { $null }
        }
    }

    Write-Progress -Id 20 -ParentId 1 -Activity 'Batch inventory' -Status "Completed - pools: $($inventory.Count)" -Completed
    return $inventory.ToArray()
}

function Build-BatchPoolRetirementPreview {
    param(
        [Parameter(Mandatory = $false)][object[]]$BatchPools = @(),
        [Parameter(Mandatory = $false)]$Retirements
    )

    $rows = New-Object 'System.Collections.Generic.List[object]'
    $batchPoolItems = @($BatchPools | Where-Object { $null -ne $_ })
    $liveSeries = @()
    $advisorByResourceId = @{}
    if ($Retirements) {
        if ($Retirements.PSObject.Properties.Match('Series').Count -gt 0) {
            $liveSeries = @($Retirements.Series | Where-Object { $_.PSObject.Properties.Match('Source').Count -gt 0 -and $_.Source -in @('LiveLearnMarkdown', 'ReleaseCommunicationsApi') })
        }
        if ($Retirements.PSObject.Properties.Match('ByVmResourceId').Count -gt 0 -and $Retirements.ByVmResourceId) {
            $advisorByResourceId = $Retirements.ByVmResourceId
        }
    }

    foreach ($pool in $batchPoolItems) {
        $vmSize = if ($pool.PSObject.Properties.Match('VmSize').Count -gt 0) { [string]$pool.VmSize } else { '' }
        if ([string]::IsNullOrWhiteSpace($vmSize)) { continue }

        $resourceId = if ($pool.PSObject.Properties.Match('ResourceId').Count -gt 0) { ([string]$pool.ResourceId).ToLowerInvariant() } else { '' }
        $advisorSignal = $null
        if ($resourceId -and $advisorByResourceId.ContainsKey($resourceId)) {
            $advisorSignal = $advisorByResourceId[$resourceId]
        }

        $officialRetirement = Resolve-OfficialRetirementLiveOnly -SkuName $vmSize -LiveLearnSeries $liveSeries
        if (-not $advisorSignal -and -not $officialRetirement) { continue }

        $retirementDate = if ($officialRetirement) { Format-NullableDate $officialRetirement.RetireOn } elseif ($advisorSignal) { Format-NullableDate $advisorSignal.RetireOn } else { 'N/A' }
        $officialSource = if ($officialRetirement -and $officialRetirement.Source) { [string]$officialRetirement.Source } else { 'LiveLearnMarkdown' }
        $source = if ($officialRetirement -and $advisorSignal) { "$officialSource + AdvisorSignal" } elseif ($officialRetirement) { $officialSource } else { 'LiveAdvisorArg' }
        $seriesName = if ($officialRetirement -and $officialRetirement.PSObject.Properties.Match('SeriesName').Count -gt 0) { [string]$officialRetirement.SeriesName } else { Convert-SkuToSeriesKey -SkuName $vmSize }

        $rows.Add([pscustomobject]@{
            ResourceType           = 'BatchPool'
            Capability             = 'Public Preview'
            SubscriptionId         = if ($pool.PSObject.Properties.Match('SubscriptionId').Count -gt 0) { [string]$pool.SubscriptionId } else { 'N/A' }
            ResourceGroup          = if ($pool.PSObject.Properties.Match('ResourceGroup').Count -gt 0) { [string]$pool.ResourceGroup } else { 'N/A' }
            BatchAccountName       = if ($pool.PSObject.Properties.Match('BatchAccountName').Count -gt 0) { [string]$pool.BatchAccountName } else { 'N/A' }
            PoolName               = if ($pool.PSObject.Properties.Match('PoolName').Count -gt 0) { [string]$pool.PoolName } else { 'N/A' }
            Region                 = if ($pool.PSObject.Properties.Match('Location').Count -gt 0) { [string]$pool.Location } else { 'N/A' }
            CurrentSku             = $vmSize
            SeriesName             = if ($seriesName) { [string]$seriesName } else { 'N/A' }
            RetirementDate         = $retirementDate
            EvidenceSource         = $source
            AllocationState        = if ($pool.PSObject.Properties.Match('AllocationState').Count -gt 0) { [string]$pool.AllocationState } else { 'N/A' }
            TargetDedicatedNodes   = if ($pool.PSObject.Properties.Match('TargetDedicatedNodes').Count -gt 0) { [string]$pool.TargetDedicatedNodes } else { 'N/A' }
            TargetLowPriorityNodes = if ($pool.PSObject.Properties.Match('TargetLowPriorityNodes').Count -gt 0) { [string]$pool.TargetLowPriorityNodes } else { 'N/A' }
            TargetSpotNodes        = if ($pool.PSObject.Properties.Match('TargetSpotNodes').Count -gt 0) { [string]$pool.TargetSpotNodes } else { 'N/A' }
            NextStep               = 'Validate Batch pool VM size, image/node agent compatibility, quota and capacity; recreate or resize the pool with a supported VM size.'
        }) | Out-Null
    }

    $previewRows = @($rows.ToArray() | Sort-Object RetirementDate, BatchAccountName, PoolName)
    return [pscustomobject]@{
        Capability             = 'Public Preview'
        TotalBatchPoolsScanned = $batchPoolItems.Count
        RetirementPathCount    = $previewRows.Count
        Rows                   = $previewRows
    }
}

function Get-ResourceGraphVmssInventory {
    param(
        [Parameter(Mandatory = $false)][string[]]$Subscriptions
    )

    $query = @"
Resources
| where type =~ 'microsoft.compute/virtualmachinescalesets'
| extend idLower = tolower(id)
| extend vmSize = tostring(sku.name)
| extend capacity = tostring(sku.capacity)
| extend skuTier = tostring(sku.tier)
| extend orchestrationMode = tostring(properties.orchestrationMode)
| extend upgradeMode = tostring(properties.upgradePolicy.mode)
| extend provisioningState = tostring(properties.provisioningState)
| extend osType = tostring(properties.virtualMachineProfile.storageProfile.osDisk.osType)
| project subscriptionId, resourceGroup, idLower, name, location, vmSize, capacity, skuTier, orchestrationMode, upgradeMode, provisioningState, osType
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
        $pageSize = 1000
        $skipToken = $null
        $pageNumber = 0
        do {
            $pageNumber++
            $subPct = if ($totalSubs -gt 0) { [int][math]::Round(($subIdx / $totalSubs) * 100, 0) } else { 100 }
            Write-Progress -Id 21 -ParentId 1 -Activity 'VM Scale Set inventory' -Status "Subscription $subIdx/$totalSubs, page $pageNumber" -PercentComplete $subPct
            $graphArgs = @{
                Query        = $query
                First        = $pageSize
                Subscription = [string]$subId
            }
            if ($skipToken) {
                $graphArgs['SkipToken'] = $skipToken
            }

            $searchStart = Get-Date
            try {
                $page = Search-AzGraph @graphArgs
                Add-ApiCallLog -Api 'Search-AzGraph' -Provider 'Az.ResourceGraph' -TenantId $script:EffectiveTenantId -SubscriptionId ([string]$subId) -Request 'VmssPublicPreview' -StartedAt $searchStart -EndedAt (Get-Date) -Success $true -Meta @{ ReturnedRows = @($page).Count }
            }
            catch {
                Add-ApiCallLog -Api 'Search-AzGraph' -Provider 'Az.ResourceGraph' -TenantId $script:EffectiveTenantId -SubscriptionId ([string]$subId) -Request 'VmssPublicPreview' -StartedAt $searchStart -EndedAt (Get-Date) -Success $false -ErrorMessage $_.Exception.Message
                Write-Log "VMSS public preview inventory failed on subscription ${subId}: $($_.Exception.Message)" 'WARN'
                break
            }

            foreach ($r in @($page)) {
                $inventory.Add([pscustomobject]@{
                    ResourceId         = [string]$r.idLower
                    SubscriptionId     = [string]$r.subscriptionId
                    ResourceGroup      = [string]$r.resourceGroup
                    VmssName           = if ($r.PSObject.Properties.Match('name').Count -gt 0 -and $r.name) { [string]$r.name } else { 'N/A' }
                    Location           = ConvertTo-NormalizedLocation ([string]$r.location)
                    VmSize             = [string]$r.vmSize
                    Capacity           = if ($r.PSObject.Properties.Match('capacity').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$r.capacity)) { [string]$r.capacity } else { 'N/A' }
                    SkuTier            = if ($r.PSObject.Properties.Match('skuTier').Count -gt 0 -and $r.skuTier) { [string]$r.skuTier } else { 'N/A' }
                    OrchestrationMode  = if ($r.PSObject.Properties.Match('orchestrationMode').Count -gt 0 -and $r.orchestrationMode) { [string]$r.orchestrationMode } else { 'N/A' }
                    UpgradeMode        = if ($r.PSObject.Properties.Match('upgradeMode').Count -gt 0 -and $r.upgradeMode) { [string]$r.upgradeMode } else { 'N/A' }
                    ProvisioningState  = if ($r.PSObject.Properties.Match('provisioningState').Count -gt 0 -and $r.provisioningState) { [string]$r.provisioningState } else { 'N/A' }
                    OsType             = if ($r.PSObject.Properties.Match('osType').Count -gt 0 -and $r.osType) { [string]$r.osType } else { 'Unknown' }
                }) | Out-Null
            }
            $skipToken = if ($page) { $page.SkipToken } else { $null }
        } while ($skipToken)
    }

    Write-Progress -Id 21 -ParentId 1 -Activity 'VM Scale Set inventory' -Status "Completed - scale sets: $($inventory.Count)" -Completed
    return $inventory.ToArray()
}

function Build-VmssRetirementPreview {
    param(
        [Parameter(Mandatory = $false)][object[]]$VmScaleSets = @(),
        [Parameter(Mandatory = $false)]$Retirements
    )

    $rows = New-Object 'System.Collections.Generic.List[object]'
    $vmssItems = @($VmScaleSets | Where-Object { $null -ne $_ })
    $liveSeries = @()
    $advisorByResourceId = @{}
    if ($Retirements) {
        if ($Retirements.PSObject.Properties.Match('Series').Count -gt 0) {
            $liveSeries = @($Retirements.Series | Where-Object { $_.PSObject.Properties.Match('Source').Count -gt 0 -and $_.Source -in @('LiveLearnMarkdown', 'ReleaseCommunicationsApi') })
        }
        if ($Retirements.PSObject.Properties.Match('ByVmResourceId').Count -gt 0 -and $Retirements.ByVmResourceId) {
            $advisorByResourceId = $Retirements.ByVmResourceId
        }
    }

    foreach ($vmss in $vmssItems) {
        $vmSize = if ($vmss.PSObject.Properties.Match('VmSize').Count -gt 0) { [string]$vmss.VmSize } else { '' }
        if ([string]::IsNullOrWhiteSpace($vmSize)) { continue }

        $resourceId = if ($vmss.PSObject.Properties.Match('ResourceId').Count -gt 0) { ([string]$vmss.ResourceId).ToLowerInvariant() } else { '' }
        $advisorSignal = $null
        if ($resourceId -and $advisorByResourceId.ContainsKey($resourceId)) {
            $advisorSignal = $advisorByResourceId[$resourceId]
        }

        $officialRetirement = Resolve-OfficialRetirementLiveOnly -SkuName $vmSize -LiveLearnSeries $liveSeries
        if (-not $advisorSignal -and -not $officialRetirement) { continue }

        $retirementDate = if ($officialRetirement) { Format-NullableDate $officialRetirement.RetireOn } elseif ($advisorSignal) { Format-NullableDate $advisorSignal.RetireOn } else { 'N/A' }
        $officialSource = if ($officialRetirement -and $officialRetirement.Source) { [string]$officialRetirement.Source } else { 'LiveLearnMarkdown' }
        $source = if ($officialRetirement -and $advisorSignal) { "$officialSource + AdvisorSignal" } elseif ($officialRetirement) { $officialSource } else { 'LiveAdvisorArg' }
        $seriesName = if ($officialRetirement -and $officialRetirement.PSObject.Properties.Match('SeriesName').Count -gt 0) { [string]$officialRetirement.SeriesName } else { Convert-SkuToSeriesKey -SkuName $vmSize }

        $rows.Add([pscustomobject]@{
            ResourceType        = 'VirtualMachineScaleSet'
            Capability          = 'Public Preview'
            SubscriptionId      = if ($vmss.PSObject.Properties.Match('SubscriptionId').Count -gt 0) { [string]$vmss.SubscriptionId } else { 'N/A' }
            ResourceGroup       = if ($vmss.PSObject.Properties.Match('ResourceGroup').Count -gt 0) { [string]$vmss.ResourceGroup } else { 'N/A' }
            VmssName            = if ($vmss.PSObject.Properties.Match('VmssName').Count -gt 0) { [string]$vmss.VmssName } else { 'N/A' }
            Region              = if ($vmss.PSObject.Properties.Match('Location').Count -gt 0) { [string]$vmss.Location } else { 'N/A' }
            CurrentSku          = $vmSize
            SeriesName          = if ($seriesName) { [string]$seriesName } else { 'N/A' }
            RetirementDate      = $retirementDate
            EvidenceSource      = $source
            Capacity            = if ($vmss.PSObject.Properties.Match('Capacity').Count -gt 0) { [string]$vmss.Capacity } else { 'N/A' }
            SkuTier             = if ($vmss.PSObject.Properties.Match('SkuTier').Count -gt 0) { [string]$vmss.SkuTier } else { 'N/A' }
            OrchestrationMode   = if ($vmss.PSObject.Properties.Match('OrchestrationMode').Count -gt 0) { [string]$vmss.OrchestrationMode } else { 'N/A' }
            UpgradeMode         = if ($vmss.PSObject.Properties.Match('UpgradeMode').Count -gt 0) { [string]$vmss.UpgradeMode } else { 'N/A' }
            ProvisioningState   = if ($vmss.PSObject.Properties.Match('ProvisioningState').Count -gt 0) { [string]$vmss.ProvisioningState } else { 'N/A' }
            OsType              = if ($vmss.PSObject.Properties.Match('OsType').Count -gt 0) { [string]$vmss.OsType } else { 'Unknown' }
            NextStep            = 'Validate VMSS model, orchestration mode, image compatibility, capacity/quota and upgrade policy; roll to a supported VM size through a controlled scale set update.'
        }) | Out-Null
    }

    $previewRows = @($rows.ToArray() | Sort-Object RetirementDate, VmssName)
    return [pscustomobject]@{
        Capability          = 'Public Preview'
        TotalVmssScanned    = $vmssItems.Count
        RetirementPathCount = $previewRows.Count
        Rows                = $previewRows
    }
}

function Convert-SkuToReservedInstanceCutoffFamily {
    param([Parameter(Mandatory = $true)][string]$SkuName)

    $normalized = ConvertTo-NormalizedSkuName $SkuName
    if ($normalized -notmatch '^standard_([a-z]+)(\d+)([a-z]*)(?:_v(\d+))?$') { return $null }

    $prefix = [string]$Matches[1]
    $suffix = [string]$Matches[3]
    $version = [string]$Matches[4]
    $stem = "$prefix$suffix"
    if ($prefix -eq 'b' -and -not $version) {
        $seriesToken = 'Bv1'
    }
    elseif ($prefix -eq 'a' -and $version -eq '2') {
        $seriesToken = if ($stem -match 'm') { 'Amv2' } else { 'Av2' }
    }
    elseif ($prefix -eq 'f' -and $version -eq '2') {
        $seriesToken = 'Fsv2'
    }
    else {
        $seriesToken = $stem.Substring(0, 1).ToUpperInvariant() + $stem.Substring(1)
        if ($version) { $seriesToken += "v$version" }
    }

    return "$seriesToken-series"
}

function Get-ReleaseCommunicationReservedInstanceCutoff {
    param([Parameter(Mandatory = $false)][object[]]$Items = @())

    foreach ($item in @($Items)) {
        if (-not $item) { continue }
        $text = [System.Net.WebUtility]::HtmlDecode((([string]$item.Title, [string]$item.Description) -join ' ')) -replace '<[^>]+>', ' ' -replace '\s+', ' '
        $tags = if ($item.PSObject.Properties.Match('Tags').Count -gt 0) { @($item.Tags | ForEach-Object { [string]$_ }) } else { @() }
        if ($text -notmatch '(?i)reserved\s+(?:virtual\s+machine|vm)\s+instances?' -or $text -notmatch '(?i)purchase|renewal' -or 'Pricing & Offerings' -notin $tags) { continue }
        $cutoffDate = Get-ReleaseCommunicationRetirementDate -Item $item
        if (-not $cutoffDate) { continue }
        return [pscustomobject]@{
            CutoffDate = $cutoffDate
            Text       = $text
            SourceUrl  = [string]$item.Link
        }
    }

    return $null
}

function Test-ReleaseCommunicationReservedInstanceFamily {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Family
    )

    $baseName = ($Family -replace '(?i)-series(?:\s*\(V1\))?$', '').Trim()
    $terms = @($baseName)
    if ($Family -match '(?i)\(V1\)' -and $baseName -notmatch '(?i)v1$') { $terms += "${baseName}v1" }
    if ($baseName -match '/') { $terms += @($baseName -split '/') }
    foreach ($term in @($terms | Where-Object { $_ } | Select-Object -Unique)) {
        $escaped = [regex]::Escape($term)
        if ($Text -match "(?i)(?<![a-z0-9])$escaped(?![a-z0-9])") { return $true }
    }
    return $false
}

function Build-ReservedInstanceCutoffPreview {
    param(
        [Parameter(Mandatory = $false)][object[]]$VmRows = @(),
        [Parameter(Mandatory = $false)][object[]]$BatchPools = @(),
        [Parameter(Mandatory = $false)][object[]]$VmScaleSets = @(),
        [Parameter(Mandatory = $false)]$Retirements,
        [Parameter(Mandatory = $false)][object[]]$ReleaseCommunicationItems = @()
    )

    $cutoff = Get-ReleaseCommunicationReservedInstanceCutoff -Items $ReleaseCommunicationItems
    $cutoffDate = if ($cutoff) { [string]$cutoff.CutoffDate } else { 'N/A' }
    $rows = New-Object 'System.Collections.Generic.List[object]'
    $vmItems = @($VmRows | Where-Object { $null -ne $_ })
    $batchPoolItems = @($BatchPools | Where-Object { $null -ne $_ })
    $vmssItems = @($VmScaleSets | Where-Object { $null -ne $_ })
    $liveSeries = @()
    if ($Retirements -and $Retirements.PSObject.Properties.Match('Series').Count -gt 0) {
        $liveSeries = @($Retirements.Series | Where-Object { $_.PSObject.Properties.Match('Source').Count -gt 0 -and $_.Source -in @('LiveLearnMarkdown', 'ReleaseCommunicationsApi') })
    }

    function Add-RiCutoffRow {
        param(
            [Parameter(Mandatory = $true)][string]$ResourceType,
            [Parameter(Mandatory = $true)][string]$ResourceName,
            [Parameter(Mandatory = $false)][string]$ParentResource,
            [Parameter(Mandatory = $false)][string]$SubscriptionId,
            [Parameter(Mandatory = $false)][string]$ResourceGroup,
            [Parameter(Mandatory = $false)][string]$Region,
            [Parameter(Mandatory = $true)][string]$CurrentSku,
            [Parameter(Mandatory = $false)][string]$RetirementDate
        )

        if ([string]::IsNullOrWhiteSpace($CurrentSku)) { return }
        $family = Convert-SkuToReservedInstanceCutoffFamily -SkuName $CurrentSku
        if (-not $cutoff -or -not $family -or -not (Test-ReleaseCommunicationReservedInstanceFamily -Text $cutoff.Text -Family $family)) { return }

        $resolvedRetirementDate = if (-not [string]::IsNullOrWhiteSpace($RetirementDate) -and $RetirementDate -ne 'N/A') { $RetirementDate } else { 'N/A' }
        if ($resolvedRetirementDate -eq 'N/A') {
            $officialRetirement = Resolve-OfficialRetirementLiveOnly -SkuName $CurrentSku -LiveLearnSeries $liveSeries
            if ($officialRetirement) {
                $resolvedRetirementDate = Format-NullableDate $officialRetirement.RetireOn
            }
        }

        $rows.Add([pscustomobject]@{
            ResourceType     = $ResourceType
            ResourceName     = $ResourceName
            ParentResource   = if ($ParentResource) { $ParentResource } else { 'N/A' }
            SubscriptionId   = if ($SubscriptionId) { $SubscriptionId } else { 'N/A' }
            ResourceGroup    = if ($ResourceGroup) { $ResourceGroup } else { 'N/A' }
            Region           = if ($Region) { $Region } else { 'N/A' }
            CurrentSku       = $CurrentSku
            Family           = $family
            CutoffDate       = $cutoffDate
            RetirementDate   = $resolvedRetirementDate
            Signal           = 'Reserved VM Instance new purchase/renewal cutoff'
            Source           = $cutoff.SourceUrl
            Action           = 'FinOps planning: this row does not prove an active RI exists. If there is no RI estate for this scope, treat it as roadmap context only; otherwise review renewal plans, coverage/utilization and migration timing before the cutoff.'
        }) | Out-Null
    }

    foreach ($vm in $vmItems) {
        $sku = if ($vm.PSObject.Properties.Match('CurrentSku').Count -gt 0) { [string]$vm.CurrentSku } elseif ($vm.PSObject.Properties.Match('VmSize').Count -gt 0) { [string]$vm.VmSize } else { '' }
        $resourceName = if ($vm.PSObject.Properties.Match('VmName').Count -gt 0) { [string]$vm.VmName } else { 'N/A' }
        $subscriptionId = if ($vm.PSObject.Properties.Match('SubscriptionId').Count -gt 0) { [string]$vm.SubscriptionId } else { 'N/A' }
        $resourceGroup = if ($vm.PSObject.Properties.Match('ResourceGroup').Count -gt 0) { [string]$vm.ResourceGroup } else { 'N/A' }
        $region = if ($vm.PSObject.Properties.Match('Region').Count -gt 0) { [string]$vm.Region } elseif ($vm.PSObject.Properties.Match('Location').Count -gt 0) { [string]$vm.Location } else { 'N/A' }
        $retirementDate = if ($vm.PSObject.Properties.Match('RetirementDate').Count -gt 0) { [string]$vm.RetirementDate } else { 'N/A' }
        Add-RiCutoffRow -ResourceType 'VirtualMachine' -ResourceName $resourceName -SubscriptionId $subscriptionId -ResourceGroup $resourceGroup -Region $region -CurrentSku $sku -RetirementDate $retirementDate
    }

    foreach ($pool in $batchPoolItems) {
        $resourceName = if ($pool.PSObject.Properties.Match('PoolName').Count -gt 0) { [string]$pool.PoolName } else { 'N/A' }
        $parentResource = if ($pool.PSObject.Properties.Match('BatchAccountName').Count -gt 0) { [string]$pool.BatchAccountName } else { 'N/A' }
        $subscriptionId = if ($pool.PSObject.Properties.Match('SubscriptionId').Count -gt 0) { [string]$pool.SubscriptionId } else { 'N/A' }
        $resourceGroup = if ($pool.PSObject.Properties.Match('ResourceGroup').Count -gt 0) { [string]$pool.ResourceGroup } else { 'N/A' }
        $region = if ($pool.PSObject.Properties.Match('Location').Count -gt 0) { [string]$pool.Location } else { 'N/A' }
        $sku = if ($pool.PSObject.Properties.Match('VmSize').Count -gt 0) { [string]$pool.VmSize } else { '' }
        Add-RiCutoffRow -ResourceType 'BatchPool' -ResourceName $resourceName -ParentResource $parentResource -SubscriptionId $subscriptionId -ResourceGroup $resourceGroup -Region $region -CurrentSku $sku -RetirementDate 'N/A'
    }

    foreach ($vmss in $vmssItems) {
        $resourceName = if ($vmss.PSObject.Properties.Match('VmssName').Count -gt 0) { [string]$vmss.VmssName } else { 'N/A' }
        $subscriptionId = if ($vmss.PSObject.Properties.Match('SubscriptionId').Count -gt 0) { [string]$vmss.SubscriptionId } else { 'N/A' }
        $resourceGroup = if ($vmss.PSObject.Properties.Match('ResourceGroup').Count -gt 0) { [string]$vmss.ResourceGroup } else { 'N/A' }
        $region = if ($vmss.PSObject.Properties.Match('Location').Count -gt 0) { [string]$vmss.Location } else { 'N/A' }
        $sku = if ($vmss.PSObject.Properties.Match('VmSize').Count -gt 0) { [string]$vmss.VmSize } else { '' }
        Add-RiCutoffRow -ResourceType 'VirtualMachineScaleSet' -ResourceName $resourceName -SubscriptionId $subscriptionId -ResourceGroup $resourceGroup -Region $region -CurrentSku $sku -RetirementDate 'N/A'
    }

    $previewRows = @($rows.ToArray() | Sort-Object CutoffDate, ResourceType, Family, ResourceName)
    return [pscustomobject]@{
        Capability          = 'Public Preview'
        CutoffDate          = $cutoffDate
        TotalResourcesScanned = ($vmItems.Count + $batchPoolItems.Count + $vmssItems.Count)
        ImpactCount         = $previewRows.Count
        Rows                = $previewRows
    }
}

function Get-ReportCountSnapshot {
    param(
        [Parameter(Mandatory = $false)][object[]]$Rows = @(),
        [Parameter(Mandatory = $false)][object[]]$MonitoringLifecycle = @()
    )

    $retireCount = 0
    $advisorConfirmed = 0
    $skuFamily = 0
    foreach ($row in @($Rows)) {
        if (-not $row) { continue }
        $gate = if ($row.PSObject.Properties.Match('RetirementSourceGate').Count -gt 0) { [string]$row.RetirementSourceGate } else { '' }
        $evidence = if ($row.PSObject.Properties.Match('EvidenceSource').Count -gt 0) { [string]$row.EvidenceSource } else { '' }
        if ($gate -eq 'LiveAdvisorArg' -or $evidence -eq 'AdvisorSignalOnly') {
            $retireCount++
            $advisorConfirmed++
        }
        elseif ($gate -in @('LiveLearnMarkdown', 'ReleaseCommunicationsApi') -or $evidence -in @('LiveLearnMarkdown', 'LiveLearnMarkdown + AdvisorSignal', 'ReleaseCommunicationsApi', 'ReleaseCommunicationsApi + AdvisorSignal')) {
            $retireCount++
            $skuFamily++
        }
    }

    $monitoringCount = @(ConvertTo-NormalizedMonitoringLifecycleRows -MonitoringRows $MonitoringLifecycle | Select-Object -ExpandProperty ResourceId -Unique).Count
    $waveSum = (Build-RemediationPlan -Rows $Rows).TotalVms

    return [pscustomobject]@{
        RetireCount      = [int]$retireCount
        AdvisorConfirmed = [int]$advisorConfirmed
        SkuFamily        = [int]$skuFamily
        MonitoringCount  = [int]$monitoringCount
        WaveSum          = [int]$waveSum
    }
}

function Assert-CountsUnchangedAfterReleaseCommunicationCoverage {
    param(
        [Parameter(Mandatory = $true)]$Before,
        [Parameter(Mandatory = $true)]$After
    )

    foreach ($name in @('RetireCount', 'AdvisorConfirmed', 'SkuFamily', 'MonitoringCount', 'WaveSum')) {
        $beforeValue = if ($Before.PSObject.Properties.Match($name).Count -gt 0) { [int]$Before.$name } else { 0 }
        $afterValue = if ($After.PSObject.Properties.Match($name).Count -gt 0) { [int]$After.$name } else { 0 }
        if ($beforeValue -ne $afterValue) {
            throw "Release Communications coverage invariant failure: $name changed while building the coverage section. Before=$beforeValue After=$afterValue. Coverage rendering must not mutate report findings."
        }
    }
}

function ConvertFrom-ReleaseCommunicationApiRecord {
    param(
        [Parameter(Mandatory = $true)]$Record,
        [Parameter(Mandatory = $true)][string]$ApiBaseUrl
    )

    $published = [datetime]::MinValue
    $publishedValue = if ($Record.PSObject.Properties.Match('created').Count -gt 0 -and $null -ne $Record.created) { $Record.created } elseif ($Record.PSObject.Properties.Match('modified').Count -gt 0 -and $null -ne $Record.modified) { $Record.modified } else { $null }
    if ($publishedValue -is [datetime]) {
        $published = [datetime]$publishedValue
    }
    elseif ($null -eq $publishedValue -or -not [datetime]::TryParse([string]$publishedValue, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$published)) {
        $published = [datetime]::MinValue
    }

    $modified = [datetime]::MinValue
    $modifiedValue = if ($Record.PSObject.Properties.Match('modified').Count -gt 0) { $Record.modified } else { $null }
    if ($modifiedValue -is [datetime]) {
        $modified = [datetime]$modifiedValue
    }
    elseif ($null -eq $modifiedValue -or -not [datetime]::TryParse([string]$modifiedValue, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$modified)) {
        $modified = [datetime]::MinValue
    }

    $categories = @(
        @([string]$Record.status)
        @($Record.productCategories | ForEach-Object { [string]$_ })
        @($Record.products | ForEach-Object { [string]$_ })
        @($Record.tags | ForEach-Object { [string]$_ })
        @($Record.availabilities | ForEach-Object { [string]$_.ring })
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
    $id = if ($Record.id) { [string]$Record.id } else { '' }

    return [pscustomobject]@{
        Guid          = $id
        Title         = if ($Record.title) { [string]$Record.title } else { '' }
        Description   = if ($Record.description) { [string]$Record.description } else { '' }
        Link          = if ($id) { "https://azure.microsoft.com/updates?id=$([uri]::EscapeDataString($id))" } else { '' }
        PublishedDate = if ($published -ne [datetime]::MinValue) { $published.ToUniversalTime().ToString('yyyy-MM-dd') } else { 'N/A' }
        ModifiedUtc   = if ($modified -ne [datetime]::MinValue) { $modified.ToUniversalTime().ToString('o') } else { 'N/A' }
        Categories    = @($categories)
        Products      = @($Record.products | ForEach-Object { [string]$_ })
        Tags          = @($Record.tags | ForEach-Object { [string]$_ })
        Availabilities = @($Record.availabilities)
    }
}

function Get-ReleaseCommunicationRetirementDate {
    param([Parameter(Mandatory = $true)]$Item)

    $retirementAvailability = @($Item.Availabilities | Where-Object {
            $_ -and $_.PSObject.Properties.Match('ring').Count -gt 0 -and [string]$_.ring -match '(?i)retire'
        } | Select-Object -First 1)
    if ($retirementAvailability.Count -eq 0) { return $null }

    $availability = $retirementAvailability[0]
    $year = if ($availability.PSObject.Properties.Match('year').Count -gt 0) { [int]$availability.year } else { 0 }
    $monthText = if ($availability.PSObject.Properties.Match('month').Count -gt 0) { [string]$availability.month } else { '' }
    $monthDate = [datetime]::MinValue
    if ($year -lt 2000 -or [string]::IsNullOrWhiteSpace($monthText) -or -not [datetime]::TryParseExact("$monthText $year", 'MMMM yyyy', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$monthDate)) {
        return $null
    }

    $text = "$([string]$Item.Title) $([string]$Item.Description)"
    $datePatterns = @(
        '\b\d{4}-\d{2}-\d{2}\b',
        '\b(?:January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{1,2}(?:st|nd|rd|th)?,?\s+\d{4}\b',
        '\b\d{1,2}\s+(?:January|February|March|April|May|June|July|August|September|October|November|December)\s+\d{4}\b',
        '\b\d{1,2}/\d{1,2}/\d{4}\b'
    )
    foreach ($pattern in $datePatterns) {
        foreach ($match in [regex]::Matches($text, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
            $candidateText = $match.Value -replace '(?i)(\d)(st|nd|rd|th)\b', '$1'
            $candidate = [datetime]::MinValue
            if ([datetime]::TryParse($candidateText, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AllowWhiteSpaces, [ref]$candidate) -and $candidate.Year -eq $year -and $candidate.Month -eq $monthDate.Month) {
                return $candidate.ToString('yyyy-MM-dd')
            }
        }
    }

    return ([datetime]::new($year, $monthDate.Month, 1)).ToString('yyyy-MM-dd')
}

function Get-ReleaseCommunicationRetirementSeries {
    param(
        [Parameter(Mandatory = $false)][object[]]$Items = @(),
        [Parameter(Mandatory = $false)][string[]]$SkuNames = @()
    )

    $seriesKeys = @($SkuNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { Convert-SkuToSeriesKey -SkuName $_ } | Where-Object { $_ } | Sort-Object -Unique)
    $seriesByName = @{}
    foreach ($item in @($Items)) {
        if (-not $item) { continue }
        $itemText = [System.Net.WebUtility]::HtmlDecode((([string]$item.Title, [string]$item.Description) -join ' '))
        $itemTags = if ($item.PSObject.Properties.Match('Tags').Count -gt 0) { @($item.Tags | ForEach-Object { [string]$_ }) } else { @() }
        if ('Pricing & Offerings' -in $itemTags -and $itemText -match '(?i)reserved\s+(?:virtual\s+machine|vm)\s+instances?|purchase|renewal') { continue }
        $retireOn = Get-ReleaseCommunicationRetirementDate -Item $item
        if (-not $retireOn) { continue }
        $text = (([string]$item.Title, [string]$item.Description, (@($item.Categories) -join ' ')) -join ' ').ToLowerInvariant()
        foreach ($seriesName in $seriesKeys) {
            $matched = $false
            foreach ($term in @(New-ReleaseCommunicationSeriesTerms -SeriesName $seriesName)) {
                if (Test-ReleaseCommunicationSeriesMention -Text $text -Term $term) { $matched = $true; break }
            }
            if (-not $matched) { continue }

            $entry = [pscustomobject]@{
                SeriesName     = $seriesName
                Status         = 'Announced'
                RetireOn       = $retireOn
                Announcement   = [string]$item.Link
                MigrationGuide = [string]$item.Link
                Notes          = 'Official Microsoft Release Communications SKU-family retirement matched to tenant inventory.'
                Source         = 'ReleaseCommunicationsApi'
                SourceUrl      = [string]$item.Link
                AsOf           = (Get-Date).ToUniversalTime().ToString('o')
                SourceGate     = 'ReleaseCommunicationsApi'
                IsLive         = $true
            }
            if (-not $seriesByName.ContainsKey($seriesName) -or ([datetime]$retireOn) -lt ([datetime]$seriesByName[$seriesName].RetireOn)) {
                $seriesByName[$seriesName] = $entry
            }
        }
    }

    return @($seriesByName.Values | Sort-Object SeriesName)
}

function Get-ReleaseCommunicationsApiItems {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $false)][int]$LookbackMonths = 0,
        [Parameter(Mandatory = $false)][string]$CacheDir,
        [Parameter(Mandatory = $false)][bool]$UseCache = $false,
        [Parameter(Mandatory = $false)][int]$CacheTtlHours = 24,
        [Parameter(Mandatory = $false)][bool]$ForceRefresh = $false
    )

    $checkedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    $cutoffDate = if ($LookbackMonths -gt 0) { (Get-Date).ToUniversalTime().AddMonths(-1 * $LookbackMonths) } else { $null }
    $apiBaseUrl = $Url.Split('?')[0].TrimEnd('/')
    $cacheContext = [ordered]@{ source = $Url; schema = 1 }
    $indexCachePath = if ($UseCache -and $CacheDir) { New-CacheFilePath -CacheDir $CacheDir -Prefix 'release_communications_retirements_index' -Context $cacheContext } else { $null }
    $detailCacheDir = if ($UseCache -and $CacheDir) { Join-Path $CacheDir 'release_communications_retirement_details' } else { $null }
    if ($detailCacheDir) { New-DirectoryIfMissing -Path $detailCacheDir }

    $indexEnvelope = if ($indexCachePath -and (Test-Path -LiteralPath $indexCachePath)) { Read-CacheEnvelope -Path $indexCachePath } else { $null }
    $hasValidIndex = ($indexEnvelope -and $indexEnvelope.Data -and $indexEnvelope.Data.PSObject.Properties.Match('Records').Count -gt 0)
    [object[]]$cachedRecords = @(if ($hasValidIndex) { $indexEnvelope.Data.Records })
    $cacheIsFresh = ($hasValidIndex -and $indexCachePath -and (-not $ForceRefresh) -and (Test-CacheFileFresh -Path $indexCachePath -TtlHours $CacheTtlHours))
    $syncMode = if ($cacheIsFresh) { 'CacheHit' } elseif ($cachedRecords.Count -gt 0 -and -not $ForceRefresh) { 'DeltaRefresh' } else { 'FullRefresh' }
    $pageCount = 0
    $changedIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $syncWatermarkUtc = (Get-Date).ToUniversalTime().ToString('o')

    try {
        if (-not $cacheIsFresh) {
            $requestUrl = $Url
            if ($syncMode -eq 'DeltaRefresh') {
                $lastWatermark = if ($indexEnvelope.Data.PSObject.Properties.Match('LastSyncWatermarkUtc').Count -gt 0) { [string]$indexEnvelope.Data.LastSyncWatermarkUtc } else { [string]$indexEnvelope.CachedAtUtc }
                $watermark = [uri]::EscapeDataString(([datetime]$lastWatermark).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))
                if ($requestUrl -match '(?i)(\$filter=[^&]+)') {
                    $requestUrl = $requestUrl -replace '(?i)(\$filter=[^&]+)', "`$1%20and%20modified%20gt%20$watermark"
                }
                else {
                    $separator = if ($requestUrl.Contains('?')) { '&' } else { '?' }
                    $requestUrl += "$separator`$filter=modified%20gt%20$watermark"
                }
            }
            if ($requestUrl -notmatch '(?i)(?:\?|&)\$orderby=') {
                $separator = if ($requestUrl.Contains('?')) { '&' } else { '?' }
                $requestUrl += "$separator`$orderby=modified%20desc"
            }
            $currentRequestUrl = $requestUrl
            $downloadedRecords = New-Object 'System.Collections.Generic.List[object]'
            do {
                if ($pageCount -ge 100) { throw 'Release Communications API pagination exceeded 100 pages.' }
                $pageStart = Get-Date
                $response = Invoke-WebRequest -Uri $currentRequestUrl -UseBasicParsing -Headers @{ Accept = 'application/json' } -TimeoutSec 30 -ErrorAction Stop
                $jsonText = ([string]$response.Content).TrimStart([char]0xFEFF)
                $payload = $jsonText | ConvertFrom-Json -ErrorAction Stop
                if ($payload.PSObject.Properties.Match('value').Count -eq 0) { throw "Release Communications API response does not contain a 'value' collection." }
                foreach ($record in @($payload.value)) {
                    if (-not $record -or -not $record.id) { continue }
                    $downloadedRecords.Add($record) | Out-Null
                    [void]$changedIds.Add([string]$record.id)
                }
                $pageCount++
                Add-ApiCallLog -Api 'Invoke-WebRequest' -Provider 'MicrosoftReleaseCommunications' -TenantId $script:EffectiveTenantId -SubscriptionId 'N/A' -Request $currentRequestUrl -StartedAt $pageStart -EndedAt (Get-Date) -Success $true -Meta @{ ContentLength = $jsonText.Length; SyncMode = $syncMode; Page = $pageCount; ItemCount = @($payload.value).Count }
                $currentRequestUrl = if ($payload.PSObject.Properties.Match('@odata.nextLink').Count -gt 0) { [string]$payload.'@odata.nextLink' } else { '' }
            } while (-not [string]::IsNullOrWhiteSpace($currentRequestUrl))

            if ($syncMode -eq 'DeltaRefresh') {
                $recordMap = @{}
                foreach ($record in $cachedRecords) { if ($record.id) { $recordMap[[string]$record.id] = $record } }
                foreach ($record in @($downloadedRecords.ToArray())) { $recordMap[[string]$record.id] = $record }
                $cachedRecords = @($recordMap.Values)
            }
            else {
                $cachedRecords = @($downloadedRecords.ToArray())
            }
        }

        $details = New-Object 'System.Collections.Generic.List[object]'
        $detailTotal = @($cachedRecords).Count
        $detailIndex = 0
        $detailDownloadCount = 0
        $detailCacheHitCount = 0
        $detailTimer = [System.Diagnostics.Stopwatch]::StartNew()
        foreach ($record in $cachedRecords) {
            $detailIndex++
            if (-not $record -or -not $record.id) { continue }
            $id = [string]$record.id
            $detailPath = if ($detailCacheDir) { New-CacheFilePath -CacheDir $detailCacheDir -Prefix 'retirement' -Context @{ id = $id } } else { $null }
            $detailEnvelope = if ($detailPath -and (Test-Path -LiteralPath $detailPath)) { Read-CacheEnvelope -Path $detailPath } else { $null }
            $mustDownloadDetail = (-not $detailEnvelope -or $changedIds.Contains($id) -or $ForceRefresh)
            $detailPercent = if ($detailTotal -gt 0) { [int][math]::Floor((($detailIndex - 1) / $detailTotal) * 100) } else { 100 }
            $detailAction = if ($mustDownloadDetail) { 'Downloading' } else { 'Reading cache' }
            Write-Progress -Id 17 -ParentId 1 -Activity 'Release Communications retirement details' -Status "$detailAction $detailIndex/$detailTotal (ID $id; downloaded $detailDownloadCount; cached $detailCacheHitCount)" -PercentComplete $detailPercent
            if ($mustDownloadDetail) {
                $detailUrl = "$apiBaseUrl/$([uri]::EscapeDataString($id))"
                $detailStart = Get-Date
                $detailResponse = Invoke-WebRequest -Uri $detailUrl -UseBasicParsing -Headers @{ Accept = 'application/json' } -TimeoutSec 30 -ErrorAction Stop
                $detail = ([string]$detailResponse.Content).TrimStart([char]0xFEFF) | ConvertFrom-Json -ErrorAction Stop
                $detailDownloadCount++
                Add-ApiCallLog -Api 'Invoke-WebRequest' -Provider 'MicrosoftReleaseCommunicationsDetail' -TenantId $script:EffectiveTenantId -SubscriptionId 'N/A' -Request $detailUrl -StartedAt $detailStart -EndedAt (Get-Date) -Success $true -Meta @{ Id = $id; SyncMode = $syncMode }
                if ($detailPath) { Save-CacheEnvelope -Path $detailPath -CacheKind 'ReleaseCommunicationRetirementDetail' -Context @{ id = $id; source = $detailUrl } -Data $detail }
            }
            else {
                $detail = $detailEnvelope.Data
                $detailCacheHitCount++
            }
            if ($detail) { $details.Add($detail) | Out-Null }
            $detailPercent = if ($detailTotal -gt 0) { [int][math]::Floor(($detailIndex / $detailTotal) * 100) } else { 100 }
            $detailSecondsRemaining = if ($detailIndex -gt 0) { [int][math]::Max(0, [math]::Round(($detailTimer.Elapsed.TotalSeconds / $detailIndex) * ($detailTotal - $detailIndex), 0)) } else { 0 }
            Write-Progress -Id 17 -ParentId 1 -Activity 'Release Communications retirement details' -Status "Processed $detailIndex/$detailTotal (downloaded $detailDownloadCount; cached $detailCacheHitCount)" -PercentComplete $detailPercent -SecondsRemaining $detailSecondsRemaining
        }
        $detailTimer.Stop()
        Write-Progress -Id 17 -ParentId 1 -Activity 'Release Communications retirement details' -Status "Completed - $detailTotal processed; $detailDownloadCount downloaded; $detailCacheHitCount cached" -Completed

        if ($indexCachePath -and -not $cacheIsFresh) {
            Save-CacheEnvelope -Path $indexCachePath -CacheKind 'ReleaseCommunicationRetirementIndex' -Context $cacheContext -Data ([pscustomobject]@{ LastSyncWatermarkUtc = $syncWatermarkUtc; Records = @($cachedRecords) })
        }

        $items = @($details.ToArray() | ForEach-Object { ConvertFrom-ReleaseCommunicationApiRecord -Record $_ -ApiBaseUrl $apiBaseUrl } | Where-Object {
            if ($null -eq $cutoffDate -or $_.ModifiedUtc -eq 'N/A') { return $true }
            return (([datetime]$_.ModifiedUtc) -ge $cutoffDate)
            })

        return [pscustomobject]@{
            Ok             = $true
            Status         = 'OK'
            Url            = $Url
            CheckedAtUtc   = $checkedAtUtc
            LookbackMonths = $LookbackMonths
            Items          = @($items)
            PageCount      = $pageCount
            CachedTotal    = @($cachedRecords).Count
            DetailUpdates  = $changedIds.Count
            CacheMode      = $syncMode
            Error          = 'N/A'
        }
    }
    catch {
        Write-Progress -Id 17 -ParentId 1 -Activity 'Release Communications retirement details' -Status 'Stopped' -Completed
        $errorMessage = $_.Exception.Message
        if ($errorMessage.Length -gt 500) { $errorMessage = $errorMessage.Substring(0, 500) + '...' }
        Add-ApiCallLog -Api 'Invoke-WebRequest' -Provider 'MicrosoftReleaseCommunications' -TenantId $script:EffectiveTenantId -SubscriptionId 'N/A' -Request $Url -StartedAt (Get-Date) -EndedAt (Get-Date) -Success $false -ErrorMessage $errorMessage -Meta @{ SyncMode = $syncMode; Page = ($pageCount + 1) }
        Write-Log "Release Communications API unavailable; continuing without official communications context. $errorMessage" 'WARN'
        return [pscustomobject]@{
            Ok             = $false
            Status         = 'Unavailable'
            Url            = $Url
            CheckedAtUtc   = $checkedAtUtc
            LookbackMonths = $LookbackMonths
            Items          = @()
            PageCount      = $pageCount
            CachedTotal    = @($cachedRecords).Count
            DetailUpdates  = $changedIds.Count
            CacheMode      = $syncMode
            Error          = $errorMessage
        }
    }
}

function New-ReleaseCommunicationSeriesTerms {
    param([Parameter(Mandatory = $true)][string]$SeriesName)

    $terms = New-Object 'System.Collections.Generic.List[string]'
    $series = $SeriesName.Trim()
    if ([string]::IsNullOrWhiteSpace($series)) { return @() }
    $terms.Add($series) | Out-Null
    $terms.Add(($series -replace '-series', ' series')) | Out-Null
    if ($series -match 'B-series') { $terms.Add('B series') | Out-Null; $terms.Add('B-series') | Out-Null }
    if ($series -match 'Av2/Amv2') { $terms.Add('Av2') | Out-Null; $terms.Add('Amv2') | Out-Null }
    return @($terms.ToArray() | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_.Trim().Length -ge 2 } | Select-Object -Unique)
}

function Test-ReleaseCommunicationSeriesMention {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Term
    )

    if ([string]::IsNullOrWhiteSpace($Term) -or $Term.Trim().Length -lt 2) { return $false }
    $escapedTerm = [regex]::Escape($Term.Trim().ToLowerInvariant())
    return ($Text -match "(?<![a-z0-9])$escapedTerm(?![a-z0-9])")
}

function Get-ReleaseCommunicationsPreview {
    param(
        [Parameter(Mandatory = $false)][bool]$Enabled = $true,
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $false)][int]$LookbackMonths = 0,
        [Parameter(Mandatory = $false)][string]$CacheDir,
        [Parameter(Mandatory = $false)][bool]$UseCache = $false,
        [Parameter(Mandatory = $false)][int]$CacheTtlHours = 24,
        [Parameter(Mandatory = $false)][bool]$ForceRefresh = $false,
        [Parameter(Mandatory = $false)]$ApiResult,
        [Parameter(Mandatory = $false)][object[]]$Rows = @(),
        [Parameter(Mandatory = $false)]$BatchPoolPreview,
        [Parameter(Mandatory = $false)]$VmssPreview,
        [Parameter(Mandatory = $false)]$ReservedInstanceCutoffPreview
    )

    $checkedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    if (-not $Enabled) {
        return [pscustomobject]@{ Ok = $false; Status = 'Disabled'; Url = $Url; CheckedAtUtc = $checkedAtUtc; LookbackMonths = $LookbackMonths; TotalItems = 0; RelevantCount = 0; CorroboratedCount = 0; FinOpsCount = 0; ReviewOnlyCount = 0; Rows = @(); Error = 'Disabled by parameter' }
    }

    $apiResult = $ApiResult
    if (-not $apiResult) {
        $apiResult = Get-ReleaseCommunicationsApiItems -Url $Url -LookbackMonths $LookbackMonths -CacheDir $CacheDir -UseCache $UseCache -CacheTtlHours $CacheTtlHours -ForceRefresh $ForceRefresh
    }
    if (-not $apiResult.Ok) {
        return [pscustomobject]@{ Ok = $false; Status = $apiResult.Status; Url = $Url; CheckedAtUtc = $apiResult.CheckedAtUtc; LookbackMonths = $LookbackMonths; TotalItems = 0; RelevantCount = 0; CorroboratedCount = 0; FinOpsCount = 0; ReviewOnlyCount = 0; Rows = @(); Error = $apiResult.Error }
    }

    $resourceIds = New-Object 'System.Collections.Generic.List[string]'
    $seriesNames = New-Object 'System.Collections.Generic.List[string]'
    foreach ($row in @($Rows)) {
        if (-not $row) { continue }
        $gate = if ($row.PSObject.Properties.Match('RetirementSourceGate').Count -gt 0) { [string]$row.RetirementSourceGate } else { '' }
        $evidence = if ($row.PSObject.Properties.Match('EvidenceSource').Count -gt 0) { [string]$row.EvidenceSource } else { '' }
        $isRetirement = ($gate -eq 'LiveAdvisorArg' -or $gate -in @('LiveLearnMarkdown', 'ReleaseCommunicationsApi') -or $evidence -eq 'AdvisorSignalOnly' -or $evidence -in @('LiveLearnMarkdown', 'LiveLearnMarkdown + AdvisorSignal', 'ReleaseCommunicationsApi', 'ReleaseCommunicationsApi + AdvisorSignal'))
        if (-not $isRetirement) { continue }
        if ($row.PSObject.Properties.Match('SubscriptionId').Count -gt 0 -and $row.PSObject.Properties.Match('ResourceGroup').Count -gt 0 -and $row.PSObject.Properties.Match('VmName').Count -gt 0) {
            $resourceIds.Add(('/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.Compute/virtualMachines/{2}' -f [string]$row.SubscriptionId, [string]$row.ResourceGroup, [string]$row.VmName).ToLowerInvariant()) | Out-Null
        }
        $sku = if ($row.PSObject.Properties.Match('CurrentSku').Count -gt 0) { [string]$row.CurrentSku } else { '' }
        $series = if ($sku) { Convert-SkuToSeriesKey -SkuName $sku } else { $null }
        if ($series) { $seriesNames.Add($series) | Out-Null }
    }
    foreach ($preview in @($BatchPoolPreview, $VmssPreview)) {
        if (-not $preview -or $preview.PSObject.Properties.Match('Rows').Count -eq 0) { continue }
        foreach ($sidecarRow in @($preview.Rows)) {
            if ($sidecarRow.PSObject.Properties.Match('SeriesName').Count -gt 0 -and $sidecarRow.SeriesName) { $seriesNames.Add([string]$sidecarRow.SeriesName) | Out-Null }
            if ($sidecarRow.PSObject.Properties.Match('ResourceId').Count -gt 0 -and $sidecarRow.ResourceId) { $resourceIds.Add(([string]$sidecarRow.ResourceId).ToLowerInvariant()) | Out-Null }
        }
    }
    $seriesNames = @($seriesNames.ToArray() | Select-Object -Unique)
    $resourceIds = @($resourceIds.ToArray() | Select-Object -Unique)

    $notices = New-Object 'System.Collections.Generic.List[object]'
    foreach ($item in @($apiResult.Items)) {
        $title = [string]$item.Title
        $description = [string]$item.Description
        $categories = @($item.Categories)
        $text = (($title, $description, ($categories -join ' '), [string]$item.Link) -join ' ').ToLowerInvariant()
        $hasRetirementVerb = ($text -match '(?i)\b(retire|retirement|retiring|deprecated|deprecation|end of support|end-of-support)\b')
        $hasFinOpsSignal = ($text -match '(?i)\b(reserved|reservation|reserved vm instance|savings plan|price|pricing|billing|purchase|renewal|offer|commercial)\b')
        $hasComputeSignal = ($text -match '(?i)\b(virtual machine|virtual machines|\bvm\b|vmss|scale set|batch|compute|sku|size|sizes)\b')
        $matchedTopic = 'Review-only official notice'
        $bucket = 'Review-only'
        $usage = 'Read-only: official notice was not mapped deterministically to a report resource or SKU-family. Excluded from counts, waves and backlog.'
        $matchedSeries = @()
        $resourceMatch = $false
        foreach ($rid in $resourceIds) {
            if ($rid -and $text.Contains($rid)) { $resourceMatch = $true; break }
        }
        foreach ($series in $seriesNames) {
            foreach ($term in @(New-ReleaseCommunicationSeriesTerms -SeriesName $series)) {
                if (Test-ReleaseCommunicationSeriesMention -Text $text -Term $term) { $matchedSeries += $series; break }
            }
        }
        $matchedSeries = @($matchedSeries | Select-Object -Unique)

        if (($resourceMatch -and $hasRetirementVerb) -or ($hasRetirementVerb -and $hasComputeSignal -and $matchedSeries.Count -gt 0)) {
            $bucket = 'Corroborated'
            $matchedTopic = if ($matchedSeries.Count -gt 0) { 'SKU-family retirement: ' + ($matchedSeries -join ', ') } else { 'Exact resource reference' }
            $usage = 'Corroborates retirement evidence already found by Advisor or Microsoft Learn. Does not add impacted resources.'
        }
        elseif ($hasFinOpsSignal) {
            $bucket = 'FinOps'
            $matchedTopic = 'Commercial / reservation / pricing notice'
            $usage = 'FinOps context only. Does not create a technical retirement finding.'
        }
        $service = if ($categories.Count -gt 0) { ($categories | Select-Object -Last 1) } else { 'Azure' }
        $notices.Add([pscustomobject]@{
            Bucket        = $bucket
            PublishedDate = [string]$item.PublishedDate
            Title         = $title
            Service       = [string]$service
            MatchedTopic  = $matchedTopic
            Link          = [string]$item.Link
            ReportUsage   = $usage
            Categories    = @($categories)
            MatchedSeries = @($matchedSeries)
        }) | Out-Null
    }

    $rows = @($notices.ToArray() | Sort-Object `
            @{ Expression = { if ($_.Bucket -eq 'Corroborated') { 0 } elseif ($_.Bucket -eq 'FinOps') { 1 } else { 2 } }; Ascending = $true },
            @{ Expression = {
                    $published = [datetime]::MinValue
                    if ([datetime]::TryParse([string]$_.PublishedDate, [ref]$published)) { $published } else { [datetime]::MinValue }
                }; Descending = $true })
    return [pscustomobject]@{
        Ok                = $true
        Status            = 'OK'
        Url               = $Url
        CheckedAtUtc      = $apiResult.CheckedAtUtc
        LookbackMonths    = $LookbackMonths
        TotalItems        = @($apiResult.Items).Count
        RelevantCount     = $rows.Count
        CorroboratedCount = @($rows | Where-Object { $_.Bucket -eq 'Corroborated' }).Count
        FinOpsCount       = @($rows | Where-Object { $_.Bucket -eq 'FinOps' }).Count
        ReviewOnlyCount   = @($rows | Where-Object { $_.Bucket -eq 'Review-only' }).Count
        Rows              = $rows
        Error             = 'N/A'
    }
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

            if ($_.Exception.Message -match 'OutOfMemoryException|out of memory') {
                if ($IncludeExtendedLocations) {
                    Write-Log "Resource SKUs REST API exhausted memory while including extended locations; retrying the region-scoped REST query without extended-location metadata." "WARN"
                    return Get-ComputeSkuCatalogFromRest -SubscriptionId $SubscriptionIdForRest -RegionsFilter $RegionsFilter -ApiVersion $ApiVersion -IncludeExtendedLocations:$false
                }
                throw
            }

            Write-Log "Resource SKUs REST API failed (subscription=$SubscriptionIdForRest, status=$statusCode); falling back to Get-AzComputeResourceSku. Error: $($_.Exception.Message)" "WARN"
            if ($statusCode -eq 401) {
                Write-Log "HTTP 401 on Resource SKUs REST API: verify RBAC on subscription $SubscriptionIdForRest and token tenant alignment." "WARN"
            }
        }
    }

    if ($SubscriptionIdForRest) {
        $currentContext = Get-AzContext -ErrorAction SilentlyContinue
        $currentSubscriptionId = if ($currentContext -and $currentContext.Subscription) { [string]$currentContext.Subscription.Id } else { '' }
        if ($currentSubscriptionId -ne $SubscriptionIdForRest) {
            Set-AzContext -SubscriptionId $SubscriptionIdForRest -ErrorAction Stop | Out-Null
            Write-Log "Compute SKU cmdlet context switched to subscription $SubscriptionIdForRest"
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

        $locations = @($sku.Locations | ForEach-Object { ConvertTo-NormalizedLocation ([string]$_) })
        if ($RegionsFilter -and $RegionsFilter.Count -gt 0) {
            $normalizedRegions = $RegionsFilter | ForEach-Object { ConvertTo-NormalizedLocation $_ }
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
        $normalizedRegions = @($RegionsFilter | ForEach-Object { ConvertTo-NormalizedLocation ([string]$_) } | Where-Object { $_ } | Sort-Object -Unique)
    }

    $filterTargets = New-Object 'System.Collections.Generic.List[object]'
    $targetIndex = 0
    if ($normalizedRegions.Count -gt 0) {
        foreach ($region in $normalizedRegions) {
            $targetIndex++
            $filterTargets.Add([pscustomobject]@{
                Region     = $region
                Filter     = "serviceName eq 'Virtual Machines' and priceType eq 'Consumption' and armRegionName eq '$region'"
                ProgressId = 130 + $targetIndex
            }) | Out-Null
        }
    }
    else {
        $targetIndex++
        $filterTargets.Add([pscustomobject]@{
            Region     = '*'
            Filter     = "serviceName eq 'Virtual Machines' and priceType eq 'Consumption'"
            ProgressId = 130 + $targetIndex
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
            Write-Progress -Id ([int]$Target.ProgressId) -ParentId 13 -Activity "Retail prices: $($Target.Region)" -Status "Downloading page $($pages + 1)" -PercentComplete -1
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
        Write-Progress -Id ([int]$Target.ProgressId) -ParentId 13 -Activity "Retail prices: $($Target.Region)" -Status "Completed - pages: $pages" -Completed
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
    $completedRegions = 0

    foreach ($rr in @($regionResults)) {
        $completedRegions++
        $regionPct = if ($filterTargets.Count -gt 0) { [int][math]::Round(($completedRegions / $filterTargets.Count) * 100, 0) } else { 100 }
        Write-Progress -Id 13 -ParentId 1 -Activity "Retail Prices API" -Status "Processing region $completedRegions/$($filterTargets.Count): $($rr.Region)" -PercentComplete $regionPct
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

            $region = ConvertTo-NormalizedLocation ([string]$item.armRegionName)
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
        
        # Parse every markdown table shaped like the Learn retirement list.
        $lines = $markdown -split "`n"

        $getMarkdownColumns = {
            param([string]$Line)

            $trimmed = ([string]$Line).Trim()
            if (-not $trimmed.StartsWith('|')) { return @() }
            if ($trimmed.EndsWith('|')) { $trimmed = $trimmed.Substring(0, $trimmed.Length - 1) }
            if ($trimmed.StartsWith('|')) { $trimmed = $trimmed.Substring(1) }
            return @($trimmed -split '\|' | ForEach-Object { $_.Trim() })
        }

        $getCleanCell = {
            param([string]$Value)

            $clean = [string]$Value
            $clean = $clean -replace '<br\s*/?>', ' '
            $clean = $clean -replace '\[([^\]]+)\]\([^\)]+\)', '$1'
            $clean = $clean -replace '[*_`]', ''
            $clean = $clean -replace '\s+', ' '
            return $clean.Trim()
        }

        $learnPageUrl = 'https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/retirement/retired-sizes-list'
        $getMarkdownLinkUrl = {
            param([string]$Value)

            $match = [regex]::Match([string]$Value, '\[[^\]]+\]\(([^\)\s]+)')
            if (-not $match.Success) { return $null }

            $target = $match.Groups[1].Value
            $absoluteUri = $null
            if ([uri]::TryCreate($target, [System.UriKind]::Absolute, [ref]$absoluteUri)) {
                return $absoluteUri.AbsoluteUri
            }

            return ([uri]::new([uri]$learnPageUrl, $target)).AbsoluteUri
        }

        $testSeparatorRow = {
            param([object[]]$Columns)

            if (-not $Columns -or $Columns.Count -eq 0) { return $false }
            foreach ($col in @($Columns)) {
                if (($col -replace '[:\-\s]', '') -ne '') { return $false }
            }
            return $true
        }

        $parseLearnDate = {
            param([string]$Value)

            $dateText = (& $getCleanCell $Value)
            if ([string]::IsNullOrWhiteSpace($dateText) -or $dateText -eq '-') { return $null }

            $culture = [System.Globalization.CultureInfo]::InvariantCulture
            $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal
            $formats = @('M/d/yy', 'MM/dd/yy', 'M/d/yyyy', 'MM/dd/yyyy', 'd/M/yy', 'dd/M/yy', 'd/M/yyyy', 'dd/M/yyyy', 'yyyy-MM-dd')
            $dt = [datetime]::MinValue
            foreach ($format in $formats) {
                if ([datetime]::TryParseExact($dateText, $format, $culture, $styles, [ref]$dt)) {
                    return $dt
                }
            }

            return $null
        }

        $foundRetirementTable = $false
        $parsedRowCount = 0

        for ($lineIdx = 0; $lineIdx -lt $lines.Count; $lineIdx++) {
            $headerCols = @(& $getMarkdownColumns $lines[$lineIdx])
            if ($headerCols.Count -eq 0) { continue }

            $seriesColIdx = -1
            $statusColIdx = -1
            $announcementColIdx = -1
            $dateColIdx = -1
            $migrationGuideColIdx = -1
            for ($i = 0; $i -lt $headerCols.Count; $i++) {
                $header = (& $getCleanCell $headerCols[$i]).ToLowerInvariant()
                if ($header -like '*series*name*') { $seriesColIdx = $i }
                elseif ($header -like '*retirement*status*') { $statusColIdx = $i }
                elseif ($header -like '*retirement*announcement*') { $announcementColIdx = $i }
                elseif ($header -like '*planned*retirement*date*') { $dateColIdx = $i }
                elseif ($header -like '*migration*guide*') { $migrationGuideColIdx = $i }
            }

            if ($seriesColIdx -lt 0 -or $dateColIdx -lt 0) { continue }

            $foundRetirementTable = $true
            $rowIdx = $lineIdx + 1
            if ($rowIdx -lt $lines.Count -and (& $testSeparatorRow @(& $getMarkdownColumns $lines[$rowIdx]))) {
                $rowIdx++
            }

            for ($rowIdx; $rowIdx -lt $lines.Count; $rowIdx++) {
                $line = $lines[$rowIdx]
                if ([string]::IsNullOrWhiteSpace($line) -or -not ([string]$line).Trim().StartsWith('|')) {
                    break
                }

                $cols = @(& $getMarkdownColumns $line)
                if ($cols.Count -eq 0 -or (& $testSeparatorRow $cols)) { continue }

                $seriesName = if ($cols.Count -gt $seriesColIdx) { & $getCleanCell $cols[$seriesColIdx] } else { '' }
                $dateStr = if ($cols.Count -gt $dateColIdx) { & $getCleanCell $cols[$dateColIdx] } else { '' }
                if ([string]::IsNullOrWhiteSpace($seriesName)) { continue }

                $dt = & $parseLearnDate $dateStr
                if (-not $dt) {
                    Write-Log "Learn markdown parse error for series=$seriesName, date='$dateStr': unsupported date format" "WARN"
                    continue
                }

                $status = if ($statusColIdx -ge 0 -and $cols.Count -gt $statusColIdx) { & $getCleanCell $cols[$statusColIdx] } else { 'Announced' }
                if ([string]::IsNullOrWhiteSpace($status) -or $status -eq '-') { $status = 'Announced' }
                $announcement = if ($announcementColIdx -ge 0 -and $cols.Count -gt $announcementColIdx) { & $getMarkdownLinkUrl $cols[$announcementColIdx] } else { $null }
                if ([string]::IsNullOrWhiteSpace($announcement)) { $announcement = $learnPageUrl }
                $migrationGuide = if ($migrationGuideColIdx -ge 0 -and $cols.Count -gt $migrationGuideColIdx) { & $getMarkdownLinkUrl $cols[$migrationGuideColIdx] } else { $null }
                if ([string]::IsNullOrWhiteSpace($migrationGuide)) { $migrationGuide = $learnPageUrl }

                $retireOnIso = $dt.ToString('yyyy-MM-dd')
                $parsedRowCount++

                Write-Log "Learn markdown parsed: series=$seriesName, status=$status, date=$dateStr -> $retireOnIso" "DEBUG"

                $entries += [pscustomobject]@{
                    SeriesName         = $seriesName
                    Status             = $status
                    RetireOn           = $retireOnIso
                    Announcement       = $announcement
                    MigrationGuide     = $migrationGuide
                    Notes              = "LiveLearnMarkdown - SKU-family exposure (verify scope per-VM)"
                    MatchRegexes       = @()
                    Source             = "LiveLearnMarkdown"
                    SourceUrl          = $Url
                    AsOf               = (Get-Date).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
                }
            }
        }

        if (-not $foundRetirementTable) {
            Write-Log "Learn markdown: retirement table header not found" "ERROR"
            return [pscustomobject]@{
                Ok              = $false
                Series          = @()
                Url             = $Url
                ParsedRowCount  = 0
                Error           = "Retirement markdown table header not found"
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
    
    $normalized = ConvertTo-NormalizedSkuName $SkuName
    
    # Mapping table: normalized SKU pattern -> Learn series key
    $mapping = @{
        "^standard_ds\d+(?:-\d+)?[a-z]*_v2$" = "Dsv2-series"
        "^standard_d\d+(?:-\d+)?[a-z]*_v2$"  = "Dv2-series"
        "^standard_fs\d+(?:-\d+)?[a-z]*_v2$" = "Fsv2-series"
        "^standard_f\d+(?:-\d+)?[a-z]*_v2$"  = "Fsv2-series"
        "^standard_l\d+(?:-\d+)?[a-z]*_v2$"  = "Lsv2-series"
        "^standard_nv\d+[a-z-]*_v3$"      = "NVv3-series"
        "^standard_np\d+[a-z-]*$"         = "NP-series"
        "^standard_nc\d+[a-z-]*_v3$"      = "NCv3-Series"
        "^standard_ds\d+[a-z-]*$"         = "Ds-series"
        "^standard_d\d+[a-z-]*$"          = "D-series"
        "^standard_l\d+[a-z-]*$"          = "Ls-series"
        "^standard_a\d+m?_v2$"            = "Av2/Amv2-series"
        "^standard_b\d+[a-z-]*$"          = "B-series (V1)"
        "^standard_fs\d+[a-z-]*$"         = "Fs-series"
        "^standard_f\d+[a-z-]*$"          = "F-series"
        "^standard_gs\d+[a-z-]*$"         = "Gs-series"
        "^standard_g\d+[a-z-]*$"          = "G-series"
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
    2. Official SKU-family retirement from Learn (Stream B) or Release Communications (Stream C)
    
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
    
    # Priority 1: Check live Advisor ARG (per-resource, Stream A)
    # (This is checked per-VM-resource by caller, not here)
    
    # Priority 2: Check live Learn series (SKU-family, Stream B)
    $seriesKey = Convert-SkuToSeriesKey -SkuName $SkuName
    if ($seriesKey) {
        $seriesEntry = @($LiveLearnSeries | Where-Object { $_.SeriesName -eq $seriesKey }) | Select-Object -First 1
        if ($seriesEntry) {
            return [pscustomobject]@{
                Status         = [string]$seriesEntry.Status
                RetireOn       = $seriesEntry.RetireOn
                Source         = if ($seriesEntry.PSObject.Properties.Match('Source').Count -gt 0 -and $seriesEntry.Source) { [string]$seriesEntry.Source } else { 'LiveLearnMarkdown' }
                SeriesName     = $seriesKey
                SourceUrl      = $seriesEntry.SourceUrl
                AsOf           = $seriesEntry.AsOf
                MigrationGuide = $seriesEntry.MigrationGuide
                Announcement   = $seriesEntry.Announcement
                SourceGate     = if ($seriesEntry.PSObject.Properties.Match('SourceGate').Count -gt 0 -and $seriesEntry.SourceGate) { [string]$seriesEntry.SourceGate } else { 'LiveLearnMarkdown' }
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
    $sourceComplete = $true

    $totalSubs = @($subList).Count
    $subIdx = 0
    foreach ($subId in $subList) {
        $subIdx++
        $pageSize = 1000
        $skipToken = $null
        $pageNumber = 0
        do {
            $pageNumber++
            $subPct = if ($totalSubs -gt 0) { [int][math]::Round(($subIdx / $totalSubs) * 100, 0) } else { 100 }
            Write-Progress -Id 23 -ParentId 1 -Activity 'Advisor retirement signals' -Status "Subscription $subIdx/$totalSubs, page $pageNumber" -PercentComplete $subPct
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
                $sourceComplete = $false
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

    Write-Progress -Id 23 -ParentId 1 -Activity 'Advisor retirement signals' -Status "Completed - recommendations: $($byVmResourceId.Count)" -Completed
    if (-not $sourceComplete) {
        throw "Live retirement source (Advisor ARG) incomplete; at least one subscription fetch failed."
    }

    return [pscustomobject]@{
        ByVmResourceId      = $byVmResourceId
        Series              = @($seriesEntries)
        MonitoringLifecycle = $monitoringLifecycle.ToArray()
        UpgradeSignals      = $upgradeSignals.ToArray()
        IsLive              = $true
    }
}

function Get-Retirements {
    <#
    .SYNOPSIS
    Load retirement data from LIVE sources only (no fallback).
    
    .DESCRIPTION
    Combines three live streams:
    - STREAM A: Live Advisor ARG (per-resource recommendations)
    - STREAM B: Live Microsoft Learn markdown (SKU-family retirement waves)
    - STREAM C: Microsoft Release Communications API (SKU-family retirement announcements)
    
    Enabled streams are fetched; if all fail and $RequireLiveRetirementSource=true, script throws.
    If one or more fail, logs WARN and returns the available streams.
    
    No hardcoded list fallback — all retirement data is live or absent.
    #>
    param(
        [Parameter(Mandatory = $false)][bool]$UseOfficialList = $true,
        [Parameter(Mandatory = $false)][bool]$UsePortalSource = $true,
        [Parameter(Mandatory = $false)][string[]]$Subscriptions,
        [Parameter(Mandatory = $false)][string[]]$AdvisorRetirementTypeIdBlocklist = @(),
        [Parameter(Mandatory = $false)][string]$AdvisorRetirementNameBlockPattern = '',
        [Parameter(Mandatory = $false)][bool]$RequireLiveRetirementSource = $false,
        [Parameter(Mandatory = $false)][object[]]$ReleaseCommunicationItems = @(),
        [Parameter(Mandatory = $false)][string[]]$InventorySkuNames = @(),
        [Parameter(Mandatory = $false)][bool]$ReleaseCommunicationsOk = $false
    )

    Write-Log "Load-Retirements: Starting LIVE-ONLY mode (no fallback). Streams: ARG (per-resource) + Learn (SKU-family) + Release Communications (SKU-family). RequireLiveRetirementSource=$RequireLiveRetirementSource" "INFO"

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
    if ($RequireLiveRetirementSource -and -not $liveAdvisorArgOk -and -not $liveLearnMarkdownOk -and -not $ReleaseCommunicationsOk) {
        $msg = "FATAL: RequireLiveRetirementSource=true but all live sources failed. STREAM A error: $liveAdvisorArgError. STREAM B error: $liveLearnMarkdownError. STREAM C unavailable. No retirement data available; refusing to proceed."
        Write-Log $msg "ERROR"
        throw $msg
    }

    # ========================================
    # BUILD OUTPUT (combine all available live streams)
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

    # Add STREAM C entries (Microsoft Release Communications API, SKU-family).
    # Learn keeps priority for a family already present in Exact/Series; Stream C fills only uncovered families.
    $releaseCommunicationSeries = @(Get-ReleaseCommunicationRetirementSeries -Items $ReleaseCommunicationItems -SkuNames $InventorySkuNames)
    $streamCAddedCount = 0
    $streamCSupersededByLearnCount = 0
    foreach ($entry in $releaseCommunicationSeries) {
        $alreadyCovered = @($seriesEntries | Where-Object { [string]$_.SeriesName -eq [string]$entry.SeriesName }).Count -gt 0
        if ($alreadyCovered) {
            $streamCSupersededByLearnCount++
            continue
        }
        $seriesEntries += $entry
        $streamCAddedCount++
    }
    Write-Log "Load-Retirements: STREAM C succeeded. Tenant-matched series=$($releaseCommunicationSeries.Count); added=$streamCAddedCount; superseded by Learn=$streamCSupersededByLearnCount." "INFO"

    # Fetch monitoring lifecycle (via ARG if available)
    if ($liveAdvisorArgOk -and $liveAdvisorArg -and $liveAdvisorArg.PSObject.Properties.Match("MonitoringLifecycle").Count -gt 0) {
        $monitoringLifecycle = @($liveAdvisorArg.MonitoringLifecycle)
    }

    Write-Log "Load-Retirements: Complete. STREAM A OK=$liveAdvisorArgOk STREAM B OK=$liveLearnMarkdownOk STREAM C OK=$ReleaseCommunicationsOk Matched=$($releaseCommunicationSeries.Count) Added=$streamCAddedCount. SeriesEntries=$(@($seriesEntries).Count) ByVmResourceId=$($portalByVmResourceId.Count) Exact=$($exact.Count)" "INFO"

    return [pscustomobject]@{
        Exact              = $exact
        Series             = @($seriesEntries)
        ByVmResourceId     = $portalByVmResourceId
        MonitoringLifecycle = @($monitoringLifecycle)
        StreamAOk          = $liveAdvisorArgOk
        StreamBOk          = $liveLearnMarkdownOk
        StreamAError       = $liveAdvisorArgError
        StreamBError       = $liveLearnMarkdownError
        StreamCOk          = $ReleaseCommunicationsOk
        StreamCSeriesCount = $releaseCommunicationSeries.Count
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

    $normalizedSku = ConvertTo-NormalizedSkuName $SkuName
    if ($Retirements.PSObject.Properties.Match("Exact").Count -gt 0 -and $Retirements.Exact) {
        if ($Retirements.Exact.ContainsKey($normalizedSku)) {
            return $Retirements.Exact[$normalizedSku]
        }
    }

    if ($Retirements.PSObject.Properties.Match("Series").Count -gt 0 -and $Retirements.Series) {
        $seriesKey = Convert-SkuToSeriesKey -SkuName $SkuName
        if ($seriesKey) {
            $seriesEntry = @($Retirements.Series | Where-Object { $_.SeriesName -eq $seriesKey }) | Select-Object -First 1
            if ($seriesEntry) {
                return [pscustomobject]@{
                    Status         = [string]$seriesEntry.Status
                    RetireOn       = [string]$seriesEntry.RetireOn
                    Notes          = [string]$seriesEntry.Notes
                    Source         = if ($seriesEntry.PSObject.Properties.Match('Source').Count -gt 0 -and $seriesEntry.Source) { [string]$seriesEntry.Source } else { 'OfficialMicrosoftLearn' }
                    SeriesName     = [string]$seriesEntry.SeriesName
                    MigrationGuide = [string]$seriesEntry.MigrationGuide
                    Announcement   = [string]$seriesEntry.Announcement
                    SourceUrl      = if ($seriesEntry.PSObject.Properties.Match('SourceUrl').Count -gt 0) { [string]$seriesEntry.SourceUrl } else { '' }
                    AsOf           = if ($seriesEntry.PSObject.Properties.Match('AsOf').Count -gt 0) { [string]$seriesEntry.AsOf } else { '' }
                }
            }
        }

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

    New-DirectoryIfMissing -Path $SnapshotDir
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
            $k = "{0}|{1}" -f [string]$row.VmSize, (ConvertTo-NormalizedLocation ([string]$row.Region))
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

    $n = ConvertTo-NormalizedSkuName $SkuName
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

function Get-CpuVendor {
    param(
        [Parameter(Mandatory = $true)][string]$SkuName,
        [Parameter(Mandatory = $true)][hashtable]$Cap
    )

    $architecture = Get-Architecture -Cap $Cap
    if ($architecture -eq 'Arm64') { return 'ARM' }

    foreach ($capabilityName in @('CpuManufacturer', 'CpuVendor', 'ProcessorManufacturer')) {
        if (-not $Cap.ContainsKey($capabilityName)) { continue }
        $capabilityValue = [string]$Cap[$capabilityName]
        if ($capabilityValue -match '(?i)AMD|EPYC') { return 'AMD' }
        if ($capabilityValue -match '(?i)Intel|Xeon') { return 'Intel' }
        if ($capabilityValue -match '(?i)ARM|Ampere') { return 'ARM' }
    }

    if ($architecture -ne 'x64') { return 'Unknown' }
    $normalizedName = ConvertTo-NormalizedSkuName $SkuName
    $nameMatch = [regex]::Match($normalizedName, '^standard_[a-z]+\d+(?<variant>[a-z]*)(?:_v\d+)?$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($nameMatch.Success -and $nameMatch.Groups['variant'].Value -match '(?i)a') { return 'AMD' }
    if ($nameMatch.Success) { return 'Intel' }
    return 'Unknown'
}

function Get-EffectiveVcpuCount {
    param(
        [Parameter(Mandatory = $true)]$Cap,
        [Parameter(Mandatory = $false)][double]$Default = 0
    )

    $availableVcpu = Get-CapNumber -Cap $Cap -Name "vCPUsAvailable" -Default 0
    if ($availableVcpu -gt 0) { return $availableVcpu }
    return (Get-CapNumber -Cap $Cap -Name "vCPUs" -Default $Default)
}

function Get-SkuWorkloadClass {
    param([Parameter(Mandatory = $false)][string]$SkuName = '')

    $normalizedName = ConvertTo-NormalizedSkuName $SkuName
    if ($normalizedName -match '^standard_n') { return 'GpuAccelerated' }
    if ($normalizedName -match '^standard_h') { return 'Hpc' }
    if ($normalizedName -match '^standard_(dc|ec)') { return 'Confidential' }
    return 'GeneralPurpose'
}

function Get-PerformanceModelResult {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Cap,
        [Parameter(Mandatory = $false)][string]$VmSize = "",
        [Parameter(Mandatory = $false)][bool]$PreferAcu = $true
    )

    $vcpu = Get-EffectiveVcpuCount -Cap $Cap
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

function Test-CandidateMeetsPerformanceFloor {
    param(
        [Parameter(Mandatory = $true)]$Current,
        [Parameter(Mandatory = $true)]$Candidate,
        [Parameter(Mandatory = $false)][double]$MinimumRatio = 0.95
    )

    $currentIndex = [double]$Current.PerfIndex
    $candidateIndex = [double]$Candidate.PerfIndex
    $currentModel = if ($Current.PSObject.Properties.Match('PerfModel').Count -gt 0) { [string]$Current.PerfModel } else { '' }
    $candidateModel = if ($Candidate.PSObject.Properties.Match('PerfModel').Count -gt 0) { [string]$Candidate.PerfModel } else { '' }

    if ($currentModel -ne $candidateModel) {
        $currentComparable = Get-PerformanceModelResult -Cap $Current.Cap -VmSize ([string]$Current.Name) -PreferAcu:$false
        $candidateComparable = Get-PerformanceModelResult -Cap $Candidate.Cap -VmSize ([string]$Candidate.Name) -PreferAcu:$false
        $currentIndex = [double]$currentComparable.Index
        $candidateIndex = [double]$candidateComparable.Index
    }

    if ($currentIndex -le 0) { return $true }
    return ($candidateIndex -ge ($currentIndex * [math]::Max(0.1, $MinimumRatio)))
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

    $key = "{0}|{1}" -f [string]$SkuName, (ConvertTo-NormalizedLocation ([string]$Region))
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

function Test-HasLocalTemporaryStorage {
    param(
        [Parameter(Mandatory = $true)]$Cap,
        [Parameter(Mandatory = $false)][string]$SkuName = ''
    )

    foreach ($capabilityName in @(
        'MaxResourceVolumeMB',
        'ResourceDiskSizeGB',
        'CachedDiskBytes',
        'NvmeDiskSizeInMiB',
        'NvmeSizePerDiskInMiB',
        'LocalStorageSizeInGiB'
    )) {
        if ((Get-CapNumber -Cap $Cap -Name $capabilityName -Default 0) -gt 0) {
            return $true
        }
    }

    $placements = Get-CapString -Cap $Cap -Name 'SupportedEphemeralOSDiskPlacements' -Default ''
    if ($placements -match '(?i)(ResourceDisk|CacheDisk|NvmeDisk)') {
        return $true
    }

    $normalizedName = ConvertTo-NormalizedSkuName $SkuName
    $nameMatch = [regex]::Match($normalizedName, '^standard_[a-z]+\d+(?<variant>[a-z]*)(?:_v\d+)?$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    return ($nameMatch.Success -and $nameMatch.Groups['variant'].Value -match '(?i)d')
}

function Get-LocalTemporaryStorageKind {
    param(
        [Parameter(Mandatory = $true)]$Cap,
        [Parameter(Mandatory = $false)][string]$SkuName = ''
    )

    $hasNvme = ((Get-CapNumber -Cap $Cap -Name 'NvmeDiskSizeInMiB' -Default 0) -gt 0) -or
        ((Get-CapNumber -Cap $Cap -Name 'NvmeSizePerDiskInMiB' -Default 0) -gt 0)
    if ($hasNvme) { return 'Local NVMe' }
    if (Test-HasLocalTemporaryStorage -Cap $Cap -SkuName $SkuName) { return 'Resource/cache disk' }
    return 'None'
}

function Get-CandidateEquivalenceResult {
    param(
        [Parameter(Mandatory = $true)]$CurrentCap,
        [Parameter(Mandatory = $true)]$CandidateCap,
        [Parameter(Mandatory = $false)][string]$CurrentSkuName = '',
        [Parameter(Mandatory = $false)][string]$CandidateSkuName = ''
    )

    $differences = New-Object 'System.Collections.Generic.List[string]'
    $comparisons = @(
        [pscustomobject]@{ Label = 'vCPU available'; Current = Get-EffectiveVcpuCount -Cap $CurrentCap; Candidate = Get-EffectiveVcpuCount -Cap $CandidateCap }
        [pscustomobject]@{ Label = 'memory GB'; Current = Get-CapNumber -Cap $CurrentCap -Name 'MemoryGB' -Default 0; Candidate = Get-CapNumber -Cap $CandidateCap -Name 'MemoryGB' -Default 0 }
        [pscustomobject]@{ Label = 'maximum data disks'; Current = Get-CapNumber -Cap $CurrentCap -Name 'MaxDataDiskCount' -Default 0; Candidate = Get-CapNumber -Cap $CandidateCap -Name 'MaxDataDiskCount' -Default 0 }
        [pscustomobject]@{ Label = 'maximum NICs'; Current = Get-CapNumber -Cap $CurrentCap -Name 'MaxNetworkInterfaces' -Default 0; Candidate = Get-CapNumber -Cap $CandidateCap -Name 'MaxNetworkInterfaces' -Default 0 }
        [pscustomobject]@{ Label = 'Premium IO'; Current = Get-CapBool -Cap $CurrentCap -Name 'PremiumIO'; Candidate = Get-CapBool -Cap $CandidateCap -Name 'PremiumIO' }
        [pscustomobject]@{ Label = 'Ultra SSD'; Current = Get-CapBool -Cap $CurrentCap -Name 'UltraSSDAvailable'; Candidate = Get-CapBool -Cap $CandidateCap -Name 'UltraSSDAvailable' }
        [pscustomobject]@{ Label = 'Accelerated Networking'; Current = Get-CapBool -Cap $CurrentCap -Name 'AcceleratedNetworkingEnabled'; Candidate = Get-CapBool -Cap $CandidateCap -Name 'AcceleratedNetworkingEnabled' }
    )

    foreach ($comparison in $comparisons) {
        if ($comparison.Current -ne $comparison.Candidate) {
            $differences.Add("$($comparison.Label): $($comparison.Current) -> $($comparison.Candidate)")
        }
    }

    $currentWorkloadProfile = Get-SkuCommercialWorkloadProfile -SkuName $CurrentSkuName
    $candidateWorkloadProfile = Get-SkuCommercialWorkloadProfile -SkuName $CandidateSkuName
    if ($currentWorkloadProfile -ne 'Unknown' -and $candidateWorkloadProfile -ne 'Unknown' -and $currentWorkloadProfile -ne $candidateWorkloadProfile) {
        $differences.Add("workload profile: $currentWorkloadProfile -> $candidateWorkloadProfile")
    }

    $currentCpuVendor = Get-CpuVendor -SkuName $CurrentSkuName -Cap $CurrentCap
    $candidateCpuVendor = Get-CpuVendor -SkuName $CandidateSkuName -Cap $CandidateCap
    if ($currentCpuVendor -in @('Intel', 'AMD') -and $candidateCpuVendor -in @('Intel', 'AMD') -and $currentCpuVendor -ne $candidateCpuVendor) {
        $differences.Add("CPU vendor: $currentCpuVendor -> $candidateCpuVendor")
    }

    $currentLocalStorage = Get-LocalTemporaryStorageKind -Cap $CurrentCap -SkuName $CurrentSkuName
    $candidateLocalStorage = Get-LocalTemporaryStorageKind -Cap $CandidateCap -SkuName $CandidateSkuName
    if ($currentLocalStorage -ne $candidateLocalStorage) {
        $differences.Add("temporary/local storage: $currentLocalStorage -> $candidateLocalStorage")
    }

    $isEquivalent = ($differences.Count -eq 0)
    return [pscustomobject]@{
        IsEquivalent = $isEquivalent
        Status       = if ($isEquivalent) { 'Equivalent' } else { 'NotEquivalent' }
        Differences  = $differences.ToArray()
        Summary      = if ($isEquivalent) { '100% match on compared SKU capabilities' } else { $differences.ToArray() -join '; ' }
    }
}

function Get-CandidateSelectionReason {
    param(
        [Parameter(Mandatory = $false)][string]$CandidateStrategy = '',
        [Parameter(Mandatory = $false)][string]$CurrentSkuName = '',
        [Parameter(Mandatory = $false)][string]$CandidateSkuName = ''
    )

    $currentFamily = Get-SkuFamilyToken $CurrentSkuName
    $candidateFamily = Get-SkuFamilyToken $CandidateSkuName
    switch ($CandidateStrategy) {
        'same-family' { return "Same commercial family $currentFamily; lowest Retail price among candidates that passed the hard gates." }
        'same-shape-newer-version' { return 'Same vCPU/RAM shape on a newer generation; lowest Retail price among equally close candidates.' }
        'burstable-modernization' { return 'Burstable continuity with the nearest vCPU/RAM profile; lowest Retail price among equally close candidates.' }
        'family-affinity' { return "Basic-family affinity $currentFamily -> $candidateFamily; preferred workload model first, then nearest vCPU/RAM profile and lowest Retail price." }
        'nearby-family-compatible' { return "Cross-family $currentFamily -> $candidateFamily; nearest vCPU/RAM profile, then lowest Retail price among equally close candidates." }
        'retirement-governed-fallback' { return "Retirement fallback $currentFamily -> $candidateFamily; nearest non-retiring vCPU/RAM profile, then lowest Retail price among equally close candidates." }
        'no-compatible-candidate' { return 'No candidate passed the hard safety gates.' }
        default { return 'Candidate selection reason unavailable.' }
    }
}

function Get-CandidateCapabilityWarnings {
    param(
        [Parameter(Mandatory = $true)]$CurrentCap,
        [Parameter(Mandatory = $true)]$CandidateCap,
        [Parameter(Mandatory = $false)][string]$CurrentSkuName = '',
        [Parameter(Mandatory = $false)][string]$CandidateSkuName = ''
    )

    $warnings = New-Object 'System.Collections.Generic.List[string]'
    $equivalence = Get-CandidateEquivalenceResult -CurrentCap $CurrentCap -CandidateCap $CandidateCap -CurrentSkuName $CurrentSkuName -CandidateSkuName $CandidateSkuName
    if (-not $equivalence.IsEquivalent) {
        $warnings.Add("Warning check: target is not 100% capability-equivalent: $($equivalence.Summary)")
    }
    $currentHasLocalStorage = Test-HasLocalTemporaryStorage -Cap $CurrentCap -SkuName $CurrentSkuName
    $candidateHasLocalStorage = Test-HasLocalTemporaryStorage -Cap $CandidateCap -SkuName $CandidateSkuName
    $currentHasNvme = ((Get-CapNumber -Cap $CurrentCap -Name 'NvmeDiskSizeInMiB' -Default 0) -gt 0) -or
        ((Get-CapNumber -Cap $CurrentCap -Name 'NvmeSizePerDiskInMiB' -Default 0) -gt 0)
    $candidateHasNvme = ((Get-CapNumber -Cap $CandidateCap -Name 'NvmeDiskSizeInMiB' -Default 0) -gt 0) -or
        ((Get-CapNumber -Cap $CandidateCap -Name 'NvmeSizePerDiskInMiB' -Default 0) -gt 0)

    if ($currentHasLocalStorage -and -not $candidateHasLocalStorage) {
        $warnings.Add('Warning check: target has no temporary/local disk; verify the workload does not depend on resource disk, cache disk or local NVMe')
    }
    elseif ($currentHasLocalStorage -and $candidateHasLocalStorage -and $currentHasNvme -ne $candidateHasNvme) {
        $warnings.Add('Warning check: temporary storage type changes between resource/cache disk and local NVMe; validate caching, drive mapping and data lifecycle')
    }

    $currentMaxDisks = Get-CapNumber -Cap $CurrentCap -Name 'MaxDataDiskCount' -Default 0
    $candidateMaxDisks = Get-CapNumber -Cap $CandidateCap -Name 'MaxDataDiskCount' -Default 0
    if ($currentMaxDisks -gt 0 -and $candidateMaxDisks -lt $currentMaxDisks) {
        $warnings.Add("Warning check: maximum data disks decrease from $currentMaxDisks to $candidateMaxDisks; verify actual attached-disk count")
    }

    $currentMaxNics = Get-CapNumber -Cap $CurrentCap -Name 'MaxNetworkInterfaces' -Default 0
    $candidateMaxNics = Get-CapNumber -Cap $CandidateCap -Name 'MaxNetworkInterfaces' -Default 0
    if ($currentMaxNics -gt 0 -and $candidateMaxNics -lt $currentMaxNics) {
        $warnings.Add("Warning check: maximum NICs decrease from $currentMaxNics to $candidateMaxNics; verify actual attached-NIC count")
    }

    return $warnings.ToArray()
}

function Test-CandidateTechnicalCompatibility {
    param(
        [Parameter(Mandatory = $true)]$CurrentCap,
        [Parameter(Mandatory = $true)]$CandidateCap,
        [Parameter(Mandatory = $false)][string]$CurrentSkuName = '',
        [Parameter(Mandatory = $false)][string]$CandidateSkuName = '',
        [Parameter(Mandatory = $true)][double]$CurrentVcpu,
        [Parameter(Mandatory = $true)][double]$CurrentMemGb,
        [Parameter(Mandatory = $false)][double]$VcpuTolerancePercent = 15,
        [Parameter(Mandatory = $false)][double]$MemoryTolerancePercent = 20,
        [Parameter(Mandatory = $false)][switch]$AllowComputeUpsize,
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

    $candVcpu = Get-EffectiveVcpuCount -Cap $candCapHash
    $candMem = Get-CapNumber -Cap $candCapHash -Name "MemoryGB" -Default 0

    if ((Get-SkuWorkloadClass -SkuName $CurrentSkuName) -ne (Get-SkuWorkloadClass -SkuName $CandidateSkuName)) { return $false }

    $vcpuTolRatio = [math]::Max(0.0, [double]$VcpuTolerancePercent / 100.0)
    $memTolRatio = [math]::Max(0.0, [double]$MemoryTolerancePercent / 100.0)
    if ($CurrentVcpu -gt 0 -and -not $AllowComputeUpsize) {
        $vcpuDiffRatio = [math]::Abs(($candVcpu - $CurrentVcpu) / $CurrentVcpu)
        if ($vcpuDiffRatio -gt $vcpuTolRatio) { return $false }
    }
    if ($CurrentMemGb -gt 0 -and -not $AllowComputeUpsize) {
        $memDiffRatio = [math]::Abs(($candMem - $CurrentMemGb) / $CurrentMemGb)
        if ($memDiffRatio -gt $memTolRatio) { return $false }
    }

    if ((Get-CapBool -Cap $currCapHash -Name "PremiumIO") -and (-not (Get-CapBool -Cap $candCapHash -Name "PremiumIO"))) { return $false }
    if ((Get-CapBool -Cap $currCapHash -Name "UltraSSDAvailable") -and (-not (Get-CapBool -Cap $candCapHash -Name "UltraSSDAvailable"))) { return $false }

    if ((Get-CapBool -Cap $currCapHash -Name "AcceleratedNetworkingEnabled") -and (-not (Get-CapBool -Cap $candCapHash -Name "AcceleratedNetworkingEnabled"))) { return $false }

    return $true
}

function Test-CandidateAllowedForScope {
    param(
        [Parameter(Mandatory = $true)]$Candidate,
        [Parameter(Mandatory = $true)][string]$Location,
        [Parameter(Mandatory = $false)][string]$SubscriptionId = ''
    )

    $normalizedLocation = ConvertTo-NormalizedLocation $Location
    foreach ($restriction in @($Candidate.Restrictions)) {
        if (-not $restriction) { continue }

        $reasonCode = if ($restriction.PSObject.Properties.Match('reasonCode').Count -gt 0) { [string]$restriction.reasonCode } else { '' }
        if ($reasonCode -and $reasonCode -notmatch '(?i)NotAvailable|NotSupported') { continue }

        $restrictedLocations = @()
        if ($restriction.PSObject.Properties.Match('values').Count -gt 0 -and $restriction.values) {
            $restrictedLocations += @($restriction.values | ForEach-Object { ConvertTo-NormalizedLocation ([string]$_) })
        }
        if ($restriction.PSObject.Properties.Match('restrictionInfo').Count -gt 0 -and $restriction.restrictionInfo) {
            $info = $restriction.restrictionInfo
            if ($info.PSObject.Properties.Match('locations').Count -gt 0 -and $info.locations) {
                $restrictedLocations += @($info.locations | ForEach-Object { ConvertTo-NormalizedLocation ([string]$_) })
            }
        }

        $restrictedLocations = @($restrictedLocations | Where-Object { $_ } | Sort-Object -Unique)
        if ($restrictedLocations.Count -eq 0 -or $normalizedLocation -in $restrictedLocations) {
            return $false
        }
    }

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
        "ReleaseCommunicationsApi" { return [pscustomobject]@{ EvidenceType = "PublicOfficialAnnouncement"; Confidence = "High" } }
        "LiveAdvisorArg" { return [pscustomobject]@{ EvidenceType = "TenantSpecificAdvisorSignal"; Confidence = "High" } }
        default { return [pscustomobject]@{ EvidenceType = "UnknownSource"; Confidence = "Low" } }
    }
}

function Test-IsBurstableSku {
    param([Parameter(Mandatory = $true)][string]$SkuName)

    $n = (ConvertTo-NormalizedSkuName $SkuName)
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

function Get-RetirementRiskLevel {
    param(
        [Parameter(Mandatory = $false)]$RetirementDate,
        [Parameter(Mandatory = $false)][datetime]$AsOf = (Get-Date),
        [Parameter(Mandatory = $false)][bool]$AdvisorConfirmedImminent = $false
    )

    if ($AdvisorConfirmedImminent) { return 'Critical' }
    if ($null -eq $RetirementDate) { return 'Watch' }

    if (-not ($script:RiskCriticalDays -gt 0) -or -not ($script:RiskHighDays -gt 0)) {
        throw 'Risk thresholds are not initialized.'
    }
    $criticalDays = [int]$script:RiskCriticalDays
    $highDays = [int]$script:RiskHighDays
    $daysToRetire = [int][math]::Floor((([datetime]$RetirementDate) - $AsOf).TotalDays)
    if ($daysToRetire -le $criticalDays) { return 'Critical' }
    if ($daysToRetire -le $highDays) { return 'High' }
    return 'Medium'
}

function Get-RetirementRisk {
    param(
        [Parameter(Mandatory = $false)]$RetirementEntry,
        [Parameter(Mandatory = $false)][string]$EvidenceType = "NoAnnouncedRetirementFound",
        [Parameter(Mandatory = $true)][int]$CurrentVersion
    )

    $retireOn = $null
    if ($RetirementEntry -and $RetirementEntry.PSObject.Properties.Match("RetireOn").Count -gt 0 -and $RetirementEntry.RetireOn) {
        $rd = [datetime]::MinValue
        if ([datetime]::TryParse([string]$RetirementEntry.RetireOn, [ref]$rd)) {
            $retireOn = $rd
        }
    }

    $hasOfficial = ($EvidenceType -eq "PublicOfficialAnnouncement")
    if ($null -ne $retireOn) {
        $riskLevel = Get-RetirementRiskLevel -RetirementDate $retireOn
        $daysLabel = if ($riskLevel -eq 'Critical') { 'within 12 months' } elseif ($riskLevel -eq 'High') { 'within 24 months' } else { 'beyond 24 months' }
        if ($hasOfficial) {
            return [pscustomobject]@{ Level = $riskLevel; Reason = "Official retirement $daysLabel" }
        }
        return [pscustomobject]@{ Level = $riskLevel; Reason = "Retirement signal $daysLabel" }
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
        "family-affinity"          { return "Rule-based: preferred successor family for the current workload model" }
        "nearby-family-compatible" { return "Heuristic: cross-family migration (requires architecture validation)" }
        "retirement-governed-fallback" { return "Retirement fallback: compatible non-retiring alternative passed hard safety gates" }
        "no-compatible-candidate"  { return "No compatible non-retiring alternative passed hard safety gates" }
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
        "family-affinity"          { "Medium" }
        "nearby-family-compatible" { "High" }
        "retirement-governed-fallback" { "High" }
        "no-compatible-candidate"  { "N/A" }
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
    param([Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()][object[]]$Catalog)

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
            NormalizedFamily = Get-SkuFamilyToken -Sku ([string]$c.Name)
            Tier         = [string]$c.Tier
            Size         = [string]$c.Size
            ShapeKey     = Get-SkuShapeKey -SkuName ([string]$c.Name)
            Locations    = @($c.Locations)
            Cap          = $c.Cap
            Restrictions = $c.Restrictions
            LocationInfo = if ($c.PSObject.Properties.Match("LocationInfo").Count -gt 0) { $c.LocationInfo } else { $null }
            Arch         = Get-Architecture -Cap $c.Cap
            CpuVendor    = Get-CpuVendor -SkuName ([string]$c.Name) -Cap $c.Cap
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
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()][object[]]$Catalog,
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
    $catalogByShapeLoc = $catalogCtx.ByShapeLoc
    $catalogByShapeLocArch = $catalogCtx.ByShapeLocArch
    $allCatalogEntries = New-Object 'System.Collections.Generic.List[object]'
    foreach ($c in @($Catalog)) {
        if (-not $c) { continue }

        $perfRes = Get-PerformanceModelResult -Cap $c.Cap -VmSize ([string]$c.Name)

        $entry = [pscustomobject]@{
            Name         = [string]$c.Name
            Family       = [string]$c.Family
            NormalizedFamily = Get-SkuFamilyToken -Sku ([string]$c.Name)
            Tier         = [string]$c.Tier
            Size         = [string]$c.Size
            ShapeKey     = Get-SkuShapeKey -SkuName ([string]$c.Name)
            Locations    = @($c.Locations)
            Cap          = $c.Cap
            Restrictions = $c.Restrictions
            LocationInfo = if ($c.PSObject.Properties.Match("LocationInfo").Count -gt 0) { $c.LocationInfo } else { $null }
            Arch         = Get-Architecture -Cap $c.Cap
            CpuVendor    = Get-CpuVendor -SkuName ([string]$c.Name) -Cap $c.Cap
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
        $retirement = Resolve-RetirementForVmOrSku -Vm $vm -Retirements $Retirements
        $requiresRetirementAlternative = ($null -ne $retirement)

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
            $retirementEvidence = Get-RetirementEvidence -RetirementEntry $retirement
            $effectiveRetirementDate = if ($retirement) { Format-NullableDate $retirement.RetireOn } else { 'N/A' }
            $retirementRisk = Get-RetirementRisk -RetirementEntry $retirement -EvidenceType $retirementEvidence.EvidenceType -CurrentVersion 0

            $rows.Add([pscustomobject]@{
                SubscriptionId         = $vm.SubscriptionId
                ResourceGroup          = $vm.ResourceGroup
                VmName                 = $vm.VmName
                Region                 = $vm.Location
                CurrentSku             = $vm.VmSize
                CurrentArch            = 'Unknown'
                CurrentCpuVendor       = 'Unknown'
                TargetCpuVendor        = 'Unknown'
                CpuVendorChange        = $false
                CpuVendorChangeReason  = 'N/A'
                OsType                 = $vmOsType
                CurrentPriceOsBasis    = $currentPriceOsBasis
                CurrentWindowsMeterAvailable = [bool]$currentWindowsMeterAvailable
                VmCreatedDate          = $vm.VmCreatedDate
                AnalysisDate           = $analysisDate
                FirstSeenDate          = $analysisDate
                LaunchDateSource       = 'analysis-date'
                Confidence             = 'CatalogUnavailable_NeedsManualReview'
                SuggestedSkus          = ''
                SuggestedPrimarySku    = 'N/A'
                CandidateTargetSku     = 'N/A'
                CandidateEquivalenceStatus = 'Unknown'
                CandidateEquivalenceDetails = 'Current SKU missing from compute catalog.'
                CandidateSelectionReason = 'No candidate selected because the current SKU is missing from the compute catalog.'
                UsageDataStatus        = 'Current SKU not found in compute catalog; manual validation required.'
                WorkloadRole           = 'Unknown'
                WorkloadRoleSource     = 'N/A'
                CrossFamilySuppressed  = $false
                SensitiveWorkload      = $false
                GenerationChange       = $false
                CurrentHyperVGenerations = 'N/A'
                TargetHyperVGenerations  = 'N/A'
                ValidationChecklist    = 'Manual review required: current SKU missing from compute catalog.'
                SuggestedPrimaryArch   = 'N/A'
                CostDeltaPercent       = $null
                CostDeltaReported      = $null
                RetailDeltaMonthly     = $null
                CostDeltaStatus        = 'N/A'
                CostDeltaPublishable   = $false
                FinancialValidationStatus = 'N/A'
                PerfDeltaPercent       = $null
                PerfDeltaMethod        = 'N/A'
                PerfModelCurrent       = 'N/A'
                PerfModelTarget        = 'N/A'
                MigrationPriority      = 'High'
                MigrationEffort        = 'ManualReview'
                MigrationRisk          = 'High'
                MigrationRisksAndBlocks = 'Current SKU missing from compute catalog; no automated target selected.'
                RetirementStatus       = if ($retirement) { $retirement.Status } else { 'Unknown' }
                RetirementDate         = $effectiveRetirementDate
                RetirementSource       = if ($retirement -and $retirement.PSObject.Properties.Match('Source').Count -gt 0) { [string]$retirement.Source } else { 'N/A' }
                RetirementSourceGate   = if ($retirementEvidence.EvidenceType -eq 'TenantSpecificAdvisorSignal') { 'LiveAdvisorArg' } elseif ($retirementEvidence.EvidenceType -eq 'PublicOfficialAnnouncement' -and $retirement.Source -eq 'ReleaseCommunicationsApi') { 'ReleaseCommunicationsApi' } elseif ($retirementEvidence.EvidenceType -eq 'PublicOfficialAnnouncement') { 'LiveLearnMarkdown' } else { 'N/A' }
                RetirementEvidenceType = $retirementEvidence.EvidenceType
                RetirementEvidenceConfidence = $retirementEvidence.Confidence
                EvidenceSource         = if ($retirementEvidence.EvidenceType -eq 'TenantSpecificAdvisorSignal') { 'AdvisorSignalOnly' } elseif ($retirementEvidence.EvidenceType -eq 'PublicOfficialAnnouncement' -and $retirement.Source -eq 'ReleaseCommunicationsApi') { 'ReleaseCommunicationsApi' } elseif ($retirementEvidence.EvidenceType -eq 'PublicOfficialAnnouncement') { 'LiveLearnMarkdown' } else { 'NoSignal' }
                OfficialRetirementDate = $effectiveRetirementDate
                AdvisorRetirementSignalDate = 'N/A'
                RetirementRiskLevel    = $retirementRisk.Level
                RetirementRiskReason   = $retirementRisk.Reason
                RetirementSeriesMatch  = if ($retirement -and $retirement.PSObject.Properties.Match('SeriesName').Count -gt 0) { $retirement.SeriesName } else { 'N/A' }
                RetirementAnnouncement = if ($retirement -and $retirement.PSObject.Properties.Match('Announcement').Count -gt 0) { $retirement.Announcement } else { 'N/A' }
                RetirementMigrationGuide = if ($retirement -and $retirement.PSObject.Properties.Match('MigrationGuide').Count -gt 0) { $retirement.MigrationGuide } else { 'N/A' }
                SuggestedRetirementStatus = 'N/A'
                SuggestedRetirementDate = 'N/A'
                SupportHorizonOutcome   = 'NoTarget'
                SupportHorizonDeltaDays = $null
                CommitmentRetirementImpact = $false
                CommitmentRetirementImpactKinds = ''
                CommitmentRetirementImpactDate = 'N/A'
                CommitmentRetirementImpactNote = ''
                RecommendationBasis     = 'Catalog unavailable'
                HeuristicLevel          = 'N/A'
                FinancialValidationStatusLabel = 'Not validated: current SKU missing from compute catalog.'
                Recommendation          = 'Current SKU not found in compute catalog; keep inventory row and review manually.'
            }) | Out-Null
            continue
        }

        $currentVersion = [int]$currSku.Version
        $currentArch = [string]$currSku.Arch
        $currentCpuVendor = [string]$currSku.CpuVendor
        $currentNormalizedFamily = Get-SkuFamilyToken -Sku ([string]$currSku.Name)

        $workloadRole = Get-WorkloadRole -VmName ([string]$vm.VmName) -TagsText ([string]$vm.TagsText) -ExtensionsText ([string]$vm.ExtensionsText)

        $familySkus = @($allCatalogEntries | Where-Object {
            $_.NormalizedFamily -eq $currentNormalizedFamily -and
            ($_.Locations -contains $vm.Location) -and
            ($AllowArchChange -or $_.Arch -eq $currentArch)
        })

        $candidateSkus = @($familySkus | Where-Object {
            $_.Name -ne $vm.VmSize -and $_.Version -ge $currentVersion
        })

        $currentVcpu = Get-EffectiveVcpuCount -Cap $currSku.Cap
        $currentMemGb = Get-CapNumber -Cap $currSku.Cap -Name "MemoryGB" -Default 0

        $minVcpu = if ($currentVcpu -gt 0) { $currentVcpu * 0.75 } else { 0 }
        $maxVcpu = if ($currentVcpu -gt 0) { $currentVcpu * [math]::Max(1.0, $MaxVcpuIncreaseRatio) } else { 0 }
        $minMem = if ($currentMemGb -gt 0) { $currentMemGb * 0.75 } else { 0 }
        $maxMem = if ($currentMemGb -gt 0) { $currentMemGb * [math]::Max(1.0, $MaxMemoryIncreaseRatio) } else { 0 }
        $candidatePool = @($candidateSkus | Where-Object {
            $candVcpu = Get-EffectiveVcpuCount -Cap $_.Cap -Default $currentVcpu
            $candMem = Get-CapNumber -Cap $_.Cap -Name "MemoryGB" -Default $currentMemGb

            $sizeWithinLower = (($currentVcpu -le 0 -or $candVcpu -ge $minVcpu) -and ($currentMemGb -le 0 -or $candMem -ge $minMem))
            $sizeWithinUpper = (($currentVcpu -le 0 -or $candVcpu -le $maxVcpu) -and ($currentMemGb -le 0 -or $candMem -le $maxMem))
            $perfOk = Test-CandidateMeetsPerformanceFloor -Current $currSku -Candidate $_ -MinimumRatio $MinPerfRatio
            $techOk = Test-CandidateTechnicalCompatibility -CurrentCap $currSku.Cap -CandidateCap $_.Cap -CurrentSkuName ([string]$currSku.Name) -CandidateSkuName ([string]$_.Name) -CurrentVcpu $currentVcpu -CurrentMemGb $currentMemGb -VcpuTolerancePercent $EquivalentVcpuTolerancePercent -MemoryTolerancePercent $EquivalentMemoryTolerancePercent

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
                (Test-CandidateTechnicalCompatibility -CurrentCap $currSku.Cap -CandidateCap $_.Cap -CurrentSkuName ([string]$currSku.Name) -CandidateSkuName ([string]$_.Name) -CurrentVcpu $currentVcpu -CurrentMemGb $currentMemGb -VcpuTolerancePercent $EquivalentVcpuTolerancePercent -MemoryTolerancePercent $EquivalentMemoryTolerancePercent)
            })

            if (@($candidatePool).Count -gt 0) {
                $candidateStrategy = "same-shape-newer-version"
            }
        }

        $currentIsBurstable = Test-IsBurstableSku -SkuName ([string]$vm.VmSize)
        if (@($candidatePool).Count -eq 0 -and $currentIsBurstable) {
            $burstableMaxVcpu = if ($currentVcpu -eq 1) { [math]::Max(2, $maxVcpu) } else { $maxVcpu }
            $burstablePool = @($allCatalogEntries | Where-Object {
                $candidateVcpu = Get-EffectiveVcpuCount -Cap $_.Cap
                $candidateMemGb = Get-CapNumber -Cap $_.Cap -Name "MemoryGB" -Default 0
                $_.Name -ne $vm.VmSize -and
                (Test-IsBurstableSku -SkuName ([string]$_.Name)) -and
                $_.Version -gt $currentVersion -and
                ($_.Locations -contains $vm.Location) -and
                ($AllowArchChange -or $_.Arch -eq $currentArch) -and
                ($currentVcpu -le 0 -or ($candidateVcpu -ge $currentVcpu -and $candidateVcpu -le $burstableMaxVcpu)) -and
                ($currentMemGb -le 0 -or ($candidateMemGb -ge $currentMemGb -and $candidateMemGb -le $maxMem)) -and
                (Test-CandidateTechnicalCompatibility -CurrentCap $currSku.Cap -CandidateCap $_.Cap -CurrentSkuName ([string]$currSku.Name) -CandidateSkuName ([string]$_.Name) -CurrentVcpu $currentVcpu -CurrentMemGb $currentMemGb -VcpuTolerancePercent $EquivalentVcpuTolerancePercent -MemoryTolerancePercent $EquivalentMemoryTolerancePercent -AllowComputeUpsize -IgnoreNicRegression)
            })

            if (@($burstablePool).Count -gt 0) {
                $candidatePool = $burstablePool
                $candidateStrategy = "burstable-modernization"
            }
        }

        if (@($candidatePool).Count -eq 0) {
            $preferredSuccessorFamilies = @(Get-PreferredSuccessorFamilies -SkuName ([string]$vm.VmSize))
            foreach ($preferredFamily in $preferredSuccessorFamilies) {
                $affinityMaxVcpu = if ($currentVcpu -gt 0) { [math]::Max($maxVcpu, $currentVcpu * 2.0) } else { 0 }
                $affinityMaxMemory = if ($currentMemGb -gt 0) { [math]::Max($maxMem, $currentMemGb * 2.0) } else { 0 }
                $affinityPool = @($allCatalogEntries | Where-Object {
                    $candidateVcpu = Get-EffectiveVcpuCount -Cap $_.Cap
                    $candidateMemGb = Get-CapNumber -Cap $_.Cap -Name "MemoryGB" -Default 0
                    $candidateRetirement = Resolve-RetirementForSku -SkuName ([string]$_.Name) -Retirements $Retirements
                    $affinityCostOk = $true
                    if ($currentPrice -gt 0) {
                        $affinityPriceKey = "{0}|{1}" -f $_.Name, $vm.Location
                        if ($PriceMap.ContainsKey($affinityPriceKey)) {
                            $affinityPrice = Get-RetailUnitPriceForOs -PriceEntry $PriceMap[$affinityPriceKey] -OsType $vmOsType
                            if ($affinityPrice -gt 0) {
                                $affinityCostDelta = (($affinityPrice - $currentPrice) / $currentPrice) * 100
                                $affinityCostOk = ($affinityCostDelta -le $MaxCostIncreasePercent)
                            }
                        }
                    }
                    $_.Name -ne $vm.VmSize -and
                    $_.NormalizedFamily -eq $preferredFamily -and
                    $_.Version -ge $currentVersion -and
                    ($_.Locations -contains $vm.Location) -and
                    ($AllowArchChange -or $_.Arch -eq $currentArch) -and
                    ($currentVcpu -le 0 -or ($candidateVcpu -ge $currentVcpu -and $candidateVcpu -le $affinityMaxVcpu)) -and
                    ($currentMemGb -le 0 -or ($candidateMemGb -ge $currentMemGb -and $candidateMemGb -le $affinityMaxMemory)) -and
                    (Test-CandidateTechnicalCompatibility -CurrentCap $currSku.Cap -CandidateCap $_.Cap -CurrentSkuName ([string]$currSku.Name) -CandidateSkuName ([string]$_.Name) -CurrentVcpu $currentVcpu -CurrentMemGb $currentMemGb -VcpuTolerancePercent $EquivalentVcpuTolerancePercent -MemoryTolerancePercent $EquivalentMemoryTolerancePercent -AllowComputeUpsize) -and
                    (Test-CandidateAllowedForScope -Candidate $_ -Location ([string]$vm.Location) -SubscriptionId ([string]$vm.SubscriptionId)) -and
                    (Test-CandidateMeetsPerformanceFloor -Current $currSku -Candidate $_ -MinimumRatio $MinPerfRatio) -and
                    ($null -eq $candidateRetirement) -and
                    $affinityCostOk
                })

                if ($affinityPool.Count -gt 0) {
                    $candidatePool = $affinityPool
                    $candidateStrategy = 'family-affinity'
                    break
                }
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
                $_.NormalizedFamily -ne $currentNormalizedFamily -and
                $_.Version -ge $currentVersion -and
                ($_.Locations -contains $vm.Location) -and
                ($AllowArchChange -or $_.Arch -eq $currentArch) -and
                (Test-CandidateTechnicalCompatibility -CurrentCap $currSku.Cap -CandidateCap $_.Cap -CurrentSkuName ([string]$currSku.Name) -CandidateSkuName ([string]$_.Name) -CurrentVcpu $currentVcpu -CurrentMemGb $currentMemGb -VcpuTolerancePercent $EquivalentVcpuTolerancePercent -MemoryTolerancePercent $EquivalentMemoryTolerancePercent)
            })

            if (@($nearbyFamilyPool).Count -gt 0) {
                $candidatePool = $nearbyFamilyPool
                $candidateStrategy = "nearby-family-compatible"
            }
        }

        $candidatePool = @($candidatePool | Where-Object {
            $scopeOk = Test-CandidateAllowedForScope -Candidate $_ -Location ([string]$vm.Location) -SubscriptionId ([string]$vm.SubscriptionId)
            $crossesArmBoundary = (($currentArch -eq 'Arm64') -xor ($_.Arch -eq 'Arm64'))
            $architectureOk = (-not $crossesArmBoundary -and ($AllowArchChange -or $_.Arch -eq $currentArch))
            $performanceOk = Test-CandidateMeetsPerformanceFloor -Current $currSku -Candidate $_ -MinimumRatio $MinPerfRatio
            $candidateNotRetiring = ($null -eq (Resolve-RetirementForSku -SkuName ([string]$_.Name) -Retirements $Retirements))
            $costOk = $true
            if ($currentPrice -gt 0) {
                $candKey = "{0}|{1}" -f $_.Name, $vm.Location
                if ($PriceMap.ContainsKey($candKey)) {
                    $candPriceLocal = Get-RetailUnitPriceForOs -PriceEntry $PriceMap[$candKey] -OsType $vmOsType
                    if ($candPriceLocal -gt 0) {
                        $candDeltaPctLocal = (($candPriceLocal - $currentPrice) / $currentPrice) * 100
                        $costOk = ($candDeltaPctLocal -le $MaxCostIncreasePercent)
                    }
                }
            }

            ($scopeOk -and $architectureOk -and $performanceOk -and $candidateNotRetiring -and $costOk)
        })

        if (@($candidatePool).Count -eq 0 -and $requiresRetirementAlternative) {
            $candidatePool = @($allCatalogEntries | Where-Object {
                $candidateVcpu = Get-EffectiveVcpuCount -Cap $_.Cap
                $candidateMemGb = Get-CapNumber -Cap $_.Cap -Name "MemoryGB" -Default 0
                $candidateRetirement = Resolve-RetirementForSku -SkuName ([string]$_.Name) -Retirements $Retirements

                $_.Name -ne $vm.VmSize -and
                ($_.Locations -contains $vm.Location) -and
                $_.Arch -eq $currentArch -and
                ($currentVcpu -le 0 -or $candidateVcpu -ge $currentVcpu) -and
                ($currentMemGb -le 0 -or $candidateMemGb -ge $currentMemGb) -and
                ($null -eq $candidateRetirement) -and
                (Test-CandidateAllowedForScope -Candidate $_ -Location ([string]$vm.Location) -SubscriptionId ([string]$vm.SubscriptionId)) -and
                (Test-CandidateMeetsPerformanceFloor -Current $currSku -Candidate $_ -MinimumRatio $MinPerfRatio) -and
                (Test-CandidateTechnicalCompatibility -CurrentCap $currSku.Cap -CandidateCap $_.Cap -CurrentSkuName ([string]$currSku.Name) -CandidateSkuName ([string]$_.Name) -CurrentVcpu $currentVcpu -CurrentMemGb $currentMemGb -VcpuTolerancePercent $EquivalentVcpuTolerancePercent -MemoryTolerancePercent $EquivalentMemoryTolerancePercent -AllowComputeUpsize)
            })

            if (@($candidatePool).Count -gt 0) {
                $candidateStrategy = "retirement-governed-fallback"
            }
        }

        if (@($candidatePool).Count -eq 0) {
            $candidateStrategy = "no-compatible-candidate"
        }

        $orderedCandidates = New-Object 'System.Collections.Generic.List[object]'
        $candidateRanked = @(foreach ($cand in $candidatePool) {
            $candKey = "{0}|{1}" -f $cand.Name, $vm.Location
            $candPrice = 0.0
            $hasPrice = $false
            if ($PriceMap.ContainsKey($candKey)) {
                $candPrice = Get-RetailUnitPriceForOs -PriceEntry $PriceMap[$candKey] -OsType $vmOsType
                if ($candPrice -gt 0) {
                    $hasPrice = $true
                }
            }

            $candVcpu = Get-EffectiveVcpuCount -Cap $cand.Cap -Default $currentVcpu
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

            $vcpuUpsizeRatio = if ($currentVcpu -gt 0) { [math]::Max(0, ($candVcpu - $currentVcpu) / $currentVcpu) } else { 0 }
            $memoryUpsizeRatio = if ($currentMemGb -gt 0) { [math]::Max(0, ($candMem - $currentMemGb) / $currentMemGb) } else { 0 }
            $score = (($upsizePenalty * 4.0) + ($vcpuDeltaAbs * 2.5) + ($memDeltaAbs * 2.0) + ([math]::Max(0, $costDeltaPctCandidate) / 50.0)) - (($cand.Version - $currentVersion) * 0.15) - ($cand.FeatureScore / 500.0)

            [pscustomobject]@{
                Score = $score
                ShapeUpsizeRatio = $vcpuUpsizeRatio + $memoryUpsizeRatio
                VcpuUpsizeRatio = $vcpuUpsizeRatio
                MemoryUpsizeRatio = $memoryUpsizeRatio
                CostDeltaPctCandidate = $costDeltaPctCandidate
                Cand = $cand
                CandPrice = $candPrice
                HasPrice = $hasPrice
                CpuVendor = [string]$cand.CpuVendor
                VendorRank = 0
                VendorChangeReason = 'N/A'
            }
        })

        $knownCurrentVendor = ($currentCpuVendor -in @('Intel', 'AMD'))
        $sameVendorRanked = @(if ($knownCurrentVendor) { $candidateRanked | Where-Object { $_.CpuVendor -eq $currentCpuVendor } })
        $sameVendorPrices = @($sameVendorRanked | Where-Object { $_.HasPrice } | ForEach-Object { [double]$_.CandPrice })
        $lowestSameVendorPrice = if ($sameVendorPrices.Count -gt 0) { [double](($sameVendorPrices | Measure-Object -Minimum).Minimum) } else { $null }
        foreach ($rankedCandidate in $candidateRanked) {
            if (-not $knownCurrentVendor -or $rankedCandidate.CpuVendor -notin @('Intel', 'AMD') -or $rankedCandidate.CpuVendor -eq $currentCpuVendor) { continue }

            if ($sameVendorRanked.Count -eq 0) {
                $rankedCandidate.VendorChangeReason = 'NoSameVendorAlternative'
            }
            elseif ($rankedCandidate.HasPrice -and $null -ne $lowestSameVendorPrice -and [double]$rankedCandidate.CandPrice -lt $lowestSameVendorPrice) {
                $rankedCandidate.VendorRank = -1
                $rankedCandidate.VendorChangeReason = 'LowerRetailPrice'
            }
            else {
                $rankedCandidate.VendorRank = 1
                $rankedCandidate.VendorChangeReason = 'SameVendorPreferred'
            }
        }

        $rankedCandidatesOrdered = switch ($candidateStrategy) {
            'same-family' {
                @($candidateRanked | Sort-Object CostDeltaPctCandidate, ShapeUpsizeRatio, VendorRank, @{ Expression = { $_.Cand.Version }; Descending = $true }, @{ Expression = { [string]$_.Cand.Name } })
            }
            { $_ -in @('same-shape-newer-version', 'burstable-modernization') } {
                @($candidateRanked | Sort-Object ShapeUpsizeRatio, CostDeltaPctCandidate, VendorRank, @{ Expression = { $_.Cand.Version }; Descending = $true }, @{ Expression = { [string]$_.Cand.Name } })
            }
            default {
                @($candidateRanked | Sort-Object ShapeUpsizeRatio, CostDeltaPctCandidate, VcpuUpsizeRatio, MemoryUpsizeRatio, VendorRank, @{ Expression = { $_.Cand.Version }; Descending = $true }, @{ Expression = { [string]$_.Cand.Name } })
            }
        }

        foreach ($ranked in ($rankedCandidatesOrdered | Select-Object -First $Top)) {
            $cand = $ranked.Cand
            $candPrice = [double]$ranked.CandPrice

            $orderedCandidates.Add([pscustomobject]@{
                Name      = $cand.Name
                Version   = [int]$cand.Version
                Price     = $candPrice
                Perf      = [double]$cand.PerfIndex
                PerfModel = if ($cand.PSObject.Properties.Match("PerfModel").Count -gt 0) { [string]$cand.PerfModel } else { "Unknown*" }
                Arch      = [string]$cand.Arch
                CpuVendor = [string]$cand.CpuVendor
                VendorChangeReason = [string]$ranked.VendorChangeReason
                Feature   = [double]$cand.FeatureScore
                Cap       = $cand.Cap
                Restrictions = $cand.Restrictions
                LocationInfo = $cand.LocationInfo
            })
        }

        $orderedCandidatesArr = $orderedCandidates.ToArray()
        $bestCandidate = @($orderedCandidatesArr | Select-Object -First 1)
        if (@($bestCandidate).Count -gt 0) { $bestCandidate = $bestCandidate[0] } else { $bestCandidate = $null }
        $targetCpuVendor = if ($bestCandidate) { [string]$bestCandidate.CpuVendor } else { 'Unknown' }
        $cpuVendorChange = [bool]($bestCandidate -and $currentCpuVendor -in @('Intel', 'AMD') -and $targetCpuVendor -in @('Intel', 'AMD') -and $currentCpuVendor -ne $targetCpuVendor)
        $cpuVendorChangeReason = if ($cpuVendorChange) { [string]$bestCandidate.VendorChangeReason } else { 'N/A' }
        $latestVersion = $currentVersion
        if (@($candidateSkus).Count -gt 0) {
            $latestVersion = [int](($candidateSkus | Measure-Object -Property Version -Maximum).Maximum)
        }

        $currentPerf = [double]$currSku.PerfIndex
        $currentPerfModel = if ($currSku.PSObject.Properties.Match("PerfModel").Count -gt 0 -and $currSku.PerfModel) { [string]$currSku.PerfModel } else { "Unknown*" }
        $firstSeen = if ($FirstSeenMap.ContainsKey($vmKey)) { [datetime]$FirstSeenMap[$vmKey] } else { Get-Date }

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
            $riskList += @(Get-CandidateCapabilityWarnings -CurrentCap $currSku.Cap -CandidateCap $bestCandidate.Cap -CurrentSkuName ([string]$currSku.Name) -CandidateSkuName ([string]$bestCandidate.Name))
        }
        else {
            $riskList = Get-MigrationRiskList -CurrentCap $currSku.Cap -CandidateCap $currSku.Cap -CurrentArch $currentArch -CandidateArch $currentArch
        }

        $recommendationText = "No compatible non-retiring alternative passed hard safety gates; manual architecture review required"
        if ($bestCandidate) {
            $impactNotes = New-Object 'System.Collections.Generic.List[string]'

            if ($cpuVendorChange) {
                if ($cpuVendorChangeReason -eq 'LowerRetailPrice') {
                    $impactNotes.Add("CPU vendor change: $currentCpuVendor -> $targetCpuVendor selected for lower retail price than the compatible $currentCpuVendor alternative")
                }
                else {
                    $impactNotes.Add("CPU vendor change: $currentCpuVendor -> $targetCpuVendor because no compatible same-vendor alternative was available")
                }
            }

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

        # LIVE-ONLY: official SKU-family sources are Learn and Release Communications.
        $liveSeries = @($Retirements.Series | Where-Object { $_.PSObject.Properties.Match("Source").Count -gt 0 -and $_.Source -in @('LiveLearnMarkdown', 'ReleaseCommunicationsApi') })
        $officialLiveRetirement = Resolve-OfficialRetirementLiveOnly -SkuName ([string]$vm.VmSize) -LiveLearnSeries $liveSeries
        
        $advisorSignalPresent = ($retirement -and $retirementEvidence.EvidenceType -eq "TenantSpecificAdvisorSignal")

        if ($officialLiveRetirement) {
            $officialRetirementDate = Format-NullableDate $officialLiveRetirement.RetireOn
            $officialSourceName = [string]$officialLiveRetirement.Source
            $evidenceSource = if ($advisorSignalPresent) { "$officialSourceName + AdvisorSignal" } else { $officialSourceName }
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

        # Source gate: LIVE-ONLY (no fallback to hardcoded list).
        if ($effectiveEvidenceType -eq "PublicOfficialAnnouncement" -and $officialLiveRetirement) {
            $retirementSourceGate = if ($officialLiveRetirement.SourceGate) { [string]$officialLiveRetirement.SourceGate } else { [string]$officialLiveRetirement.Source }
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

        $equivalenceResult = if ($bestCandidate) {
            Get-CandidateEquivalenceResult -CurrentCap $currSku.Cap -CandidateCap $bestCandidate.Cap -CurrentSkuName ([string]$currSku.Name) -CandidateSkuName ([string]$bestCandidate.Name)
        }
        else {
            [pscustomobject]@{ IsEquivalent = $false; Status = 'NoTarget'; Differences = @(); Summary = 'No compatible target selected.' }
        }
        $candidateSelectionReason = Get-CandidateSelectionReason -CandidateStrategy $candidateStrategy -CurrentSkuName ([string]$currSku.Name) -CandidateSkuName $(if ($bestCandidate) { [string]$bestCandidate.Name } else { '' })
        $capabilityWarnings = if ($bestCandidate) {
            @(Get-CandidateCapabilityWarnings -CurrentCap $currSku.Cap -CandidateCap $bestCandidate.Cap -CurrentSkuName ([string]$currSku.Name) -CandidateSkuName ([string]$bestCandidate.Name))
        }
        else { @() }
        $validationChecklist = (@("Gen1/Gen2 OS", "NVMe support", "temp/local disk", "disk caching", "accelerated networking", "RI/Savings Plan", "quota", "Availability Zone") + $capabilityWarnings) -join '; '

        $rows.Add([pscustomobject]@{
            SubscriptionId         = $vm.SubscriptionId
            ResourceGroup          = $vm.ResourceGroup
            VmName                 = $vm.VmName
            Region                 = $vm.Location
            CurrentSku             = $vm.VmSize
            CurrentArch            = $currentArch
            CurrentCpuVendor       = $currentCpuVendor
            TargetCpuVendor        = $targetCpuVendor
            CpuVendorChange        = $cpuVendorChange
            CpuVendorChangeReason  = $cpuVendorChangeReason
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
            CandidateEquivalenceStatus = [string]$equivalenceResult.Status
            CandidateEquivalenceDetails = [string]$equivalenceResult.Summary
            CandidateSelectionReason = $candidateSelectionReason
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
            RetirementEvidenceScope = if ($retirementSourceGate -eq "LiveAdvisorArg") { "Per-resource confirmed (Advisor ARG)" } elseif ($retirementSourceGate -eq "LiveLearnMarkdown") { "SKU-family exposure (Microsoft Learn) - verify this VM's scope in Workbook" } elseif ($retirementSourceGate -eq 'ReleaseCommunicationsApi') { 'SKU-family exposure (Microsoft Release Communications) - verify impacted resources in Service Health' } else { "No live evidence" }
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

function Build-RecommendationsBySubscription {
    param(
        [Parameter(Mandatory = $true)][object[]]$Inventory,
        [Parameter(Mandatory = $true)][hashtable]$CatalogBySubscription,
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

    $rows = New-Object 'System.Collections.Generic.List[object]'
    $subscriptionIds = @($Inventory |
        ForEach-Object { [string]$_.SubscriptionId } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object -Unique)

    foreach ($subscriptionId in $subscriptionIds) {
        $subscriptionInventory = @($Inventory | Where-Object { [string]$_.SubscriptionId -eq $subscriptionId })
        $catalog = if ($CatalogBySubscription.ContainsKey($subscriptionId)) { @($CatalogBySubscription[$subscriptionId]) } else { @() }
        if ($catalog.Count -eq 0) {
            Write-Log "No SKU catalog available for subscription $subscriptionId; retaining $($subscriptionInventory.Count) VM row(s) for manual review." "WARN"
        }

        $subscriptionRows = @(Build-Recommendations `
            -Inventory $subscriptionInventory `
            -Catalog $catalog `
            -PriceMap $PriceMap `
            -CommitmentMap $CommitmentMap `
            -FirstSeenMap $FirstSeenMap `
            -Retirements $Retirements `
            -AdvisorHints $AdvisorHints `
            -Top $Top `
            -AllowArchChange:$AllowArchChange `
            -MaxVcpuIncreaseRatio $MaxVcpuIncreaseRatio `
            -MaxMemoryIncreaseRatio $MaxMemoryIncreaseRatio `
            -MaxCostIncreasePercent $MaxCostIncreasePercent `
            -MinPerfRatio $MinPerfRatio `
            -EquivalentVcpuTolerancePercent $EquivalentVcpuTolerancePercent `
            -EquivalentMemoryTolerancePercent $EquivalentMemoryTolerancePercent)
        foreach ($row in $subscriptionRows) {
            $rows.Add($row) | Out-Null
        }
    }

    return $rows.ToArray()
}

function Export-BacklogItems {
    param(
        [Parameter(Mandatory = $true)][object[]]$Rows,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $items = $Rows |
        Where-Object {
            $risk = if ($_.PSObject.Properties.Match('RetirementRiskLevel').Count -gt 0) { [string]$_.RetirementRiskLevel } else { '' }
            $gate = if ($_.PSObject.Properties.Match('RetirementSourceGate').Count -gt 0) { [string]$_.RetirementSourceGate } else { '' }
            $retirementDate = if ($_.PSObject.Properties.Match('RetirementDate').Count -gt 0) { [string]$_.RetirementDate } else { '' }
            $hasRetirementDate = (-not [string]::IsNullOrWhiteSpace($retirementDate) -and $retirementDate -notin @('N/A', 'No live retirement source'))
            ($risk -in @('Critical', 'High') -or $gate -in @('LiveAdvisorArg', 'LiveLearnMarkdown', 'ReleaseCommunicationsApi') -or $hasRetirementDate)
        } |
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
            $totalSubs = $subList.Count
            $subIdx = 0
            foreach ($subId in $subList) {
                $subIdx++
                $skipToken = $null
                $pageNumber = 0
                do {
                    $pageNumber++
                    $subPct = if ($totalSubs -gt 0) { [int][math]::Round(($subIdx / $totalSubs) * 100, 0) } else { 100 }
                    Write-Progress -Id 22 -ParentId 1 -Activity 'Dependency Agent verification' -Status "Subscription $subIdx/$totalSubs, page $pageNumber" -PercentComplete $subPct
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

    Write-Progress -Id 22 -ParentId 1 -Activity 'Dependency Agent verification' -Status "Completed - rows: $($rows.Count)" -Completed
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

function ConvertTo-NormalizedMonitoringLifecycleRows {
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
        $items = @($group.Group | Sort-Object @{ Expression = {
                        if ($_.PSObject.Properties.Match('RetireOn').Count -gt 0 -and $_.RetireOn -and [string]$_.RetireOn -ne 'N/A') { 0 } else { 1 }
                    } })
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
            RetireOn                    = if ($selected.PSObject.Properties.Match('RetireOn').Count -gt 0 -and $selected.RetireOn) { [string]$selected.RetireOn } else { 'N/A' }
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

function ConvertTo-MonitoringLifecycleTrackHtml {
    <#
    .SYNOPSIS
    Renders the monitoring-lifecycle track (Dependency Agent / VM Insights Map EOL) as a SEPARATE
    section - explicitly NOT a compute SKU retirement - with verified facts and per-agent-state action.
    #>
    param([Parameter(Mandatory = $false)][object[]]$MonitoringRows = @())

    $rows = @(ConvertTo-NormalizedMonitoringLifecycleRows -MonitoringRows $MonitoringRows)
    if ($rows.Count -eq 0) { return "" }

    $confirmed = @($rows | Where-Object { $_.AgentPresence -eq 'Confirmed' } | Select-Object -ExpandProperty ResourceId -Unique).Count
    $unconfirmed = @($rows | Where-Object { $_.AgentPresence -eq 'Unconfirmed' } | Select-Object -ExpandProperty ResourceId -Unique).Count
    $unknown = @($rows | Where-Object { $_.AgentPresence -eq 'Unknown' -or -not $_.AgentPresence } | Select-Object -ExpandProperty ResourceId -Unique).Count

    $html = "<section class='report-section' data-section-key='monitoring-lifecycle' data-audience='technical'>"
    $html += "<details>"
    $html += "<summary><h2 style='display:inline; margin:0; font-size:16px'>Monitoring Lifecycle (separate track - not a compute SKU retirement)</h2></summary>"
    $html += "<div class='details-content'>"
    $retirementDates = @($rows | Where-Object { $_.RetireOn -and $_.RetireOn -ne 'N/A' } | ForEach-Object { [string]$_.RetireOn } | Sort-Object -Unique)
    $retirementDateText = if ($retirementDates.Count -gt 0) { $retirementDates -join ', ' } else { 'N/A (Advisor did not provide a retirement date)' }
    $html += "<p><strong>Azure Monitor VM Insights &lsquo;Map&rsquo; feature &amp; Dependency Agent retirement date: $retirementDateText.</strong> "
    $html += "This is an <strong>Azure Monitor feature</strong> retirement, <strong>not</strong> a retirement of the VM or its compute SKU. It is tracked here separately so it is neither lost nor mistaken for a SKU retirement.</p>"
    $html += "<ul style='font-size:13px'>"
    $html += "<li><strong>No direct replacement.</strong> Azure Monitor Agent (AMA) does <strong>not</strong> replace the Map feature; AMA covers inventory tracking only. Process/dependency mapping requires a solution from Azure Marketplace.</li>"
    $html += "<li><strong>Timeline source:</strong> retirement dates shown here come from the live Azure Advisor recommendation for each affected resource.</li>"
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
            'Confirmed'   { "Plan offboarding before the Advisor retirement date; select a Marketplace mapping solution if process/dependency data is required (AMA covers inventory only)." }
            'Unconfirmed' { "No action: agent not detected on this VM. Likely a residual DCR/Policy assignment - review and remove the &lsquo;Processes and dependencies (Map)&rsquo; data collection if unused." }
            default       { "Verify manually whether the Dependency Agent is installed (detection query unavailable)." }
        }
        $stateColor = switch ($state) { 'Confirmed' { '#dc2626' } 'Unconfirmed' { '#666' } default { '#b45309' } }
        $retireDate = if ($row.RetireOn) { [string]$row.RetireOn } else { 'N/A' }
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
    - OK    : All retirement rows backed by live sources (Advisor / Learn / Release Communications).
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
        if ($gate -in @('LiveLearnMarkdown', 'ReleaseCommunicationsApi') -or $es -in @('LiveLearnMarkdown', 'LiveLearnMarkdown + AdvisorSignal', 'ReleaseCommunicationsApi', 'ReleaseCommunicationsApi + AdvisorSignal')) { return $true }
        if ($gate -eq 'LiveAdvisorArg' -or $es -eq 'AdvisorSignalOnly') { return $true }
        return $false
    }
    $findingRows = @($rowsArr | Where-Object { & $isRetirementFinding $_ })
    $liveRows = @($findingRows | Where-Object {
        $_.PSObject.Properties.Match('RetirementSourceGate').Count -gt 0 -and
        ($_.RetirementSourceGate -in @('LiveAdvisorArg', 'LiveLearnMarkdown', 'ReleaseCommunicationsApi'))
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
        $message = "All $($liveRows) retirement finding(s) backed by live sources (Azure Advisor ARG / Microsoft Learn / Microsoft Release Communications)."
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
    $monitoringRows = @(ConvertTo-NormalizedMonitoringLifecycleRows -MonitoringRows $MonitoringLifecycle)

    foreach ($row in @($Rows)) {
        $evidenceSource = if ($row.PSObject.Properties.Match('EvidenceSource').Count -gt 0) { [string]$row.EvidenceSource } else { '' }
        $sourceGate = if ($row.PSObject.Properties.Match('RetirementSourceGate').Count -gt 0) { [string]$row.RetirementSourceGate } else { '' }
        $retirementClass = 'None'
        if ($sourceGate -in @('LiveLearnMarkdown', 'ReleaseCommunicationsApi') -or $evidenceSource -in @('LiveLearnMarkdown', 'LiveLearnMarkdown + AdvisorSignal', 'ReleaseCommunicationsApi', 'ReleaseCommunicationsApi + AdvisorSignal')) {
            $retirementClass = 'SkuFamily'
        }
        elseif ($sourceGate -eq 'LiveAdvisorArg' -or $evidenceSource -eq 'AdvisorSignalOnly') {
            $retirementClass = 'AdvisorConfirmed'
        }

        if ($retirementClass -eq 'None') { continue }

        $costDeltaPublishable = if ($row.PSObject.Properties.Match('CostDeltaPublishable').Count -gt 0) { [bool]$row.CostDeltaPublishable } else { $true }

        $retailDeltaMonthly = $null
        if ($costDeltaPublishable -and $row.PSObject.Properties.Match('RetailDeltaMonthly').Count -gt 0 -and $null -ne $row.RetailDeltaMonthly -and ([string]$row.RetailDeltaMonthly).Trim() -ne '') {
            $retailDeltaMonthly = [double]$row.RetailDeltaMonthly
        }

        $costDeltaPercent = $null
        if ($costDeltaPublishable -and $row.PSObject.Properties.Match('CostDeltaReported').Count -gt 0 -and $null -ne $row.CostDeltaReported -and ([string]$row.CostDeltaReported).Trim() -ne '') {
            $costDeltaPercent = [double]$row.CostDeltaReported
        }
        elseif ($costDeltaPublishable -and $row.PSObject.Properties.Match('CostDeltaPercent').Count -gt 0 -and $null -ne $row.CostDeltaPercent -and ([string]$row.CostDeltaPercent).Trim() -ne '') {
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
        $equivalenceStatus = if ($row.PSObject.Properties.Match('CandidateEquivalenceStatus').Count -gt 0 -and $row.CandidateEquivalenceStatus) { [string]$row.CandidateEquivalenceStatus } else { 'Unknown' }
        $equivalenceDetails = if ($row.PSObject.Properties.Match('CandidateEquivalenceDetails').Count -gt 0 -and $row.CandidateEquivalenceDetails) { [string]$row.CandidateEquivalenceDetails } else { 'Equivalence details unavailable.' }
        $selectionReason = if ($row.PSObject.Properties.Match('CandidateSelectionReason').Count -gt 0 -and $row.CandidateSelectionReason) { [string]$row.CandidateSelectionReason } else { 'Selection reason unavailable.' }
        if ($equivalenceStatus -eq 'NotEquivalent') {
            $validation = "$validation Not a validated 1:1 equivalent; see the compared-capability differences in the recommendation column."
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
            $noteParts.Add('No compatible non-retiring alternative passed availability, architecture, capability and performance hard gates; manual architecture review is required.') | Out-Null
        }
        else {
            # The selection rationale is surfaced separately as "Why selected"; only additional migration
            # cautions (generation, CPU vendor, sensitive workload) belong in the note to avoid duplication.
            if ($generationChange) {
                $noteParts.Add('Generation change (current SKU allows Gen1, target is Gen2-only): not a simple resize - confirm the OS image is Gen2 (or plan a Gen1->Gen2 conversion) and validate boot, drivers and extensions before migrating.') | Out-Null
            }
            $cpuVendorChange = ($row.PSObject.Properties.Match('CpuVendorChange').Count -gt 0 -and [bool]$row.CpuVendorChange)
            if ($cpuVendorChange) {
                $currentCpuVendor = if ($row.PSObject.Properties.Match('CurrentCpuVendor').Count -gt 0) { [string]$row.CurrentCpuVendor } else { 'Unknown' }
                $targetCpuVendor = if ($row.PSObject.Properties.Match('TargetCpuVendor').Count -gt 0) { [string]$row.TargetCpuVendor } else { 'Unknown' }
                $cpuVendorReason = if ($row.PSObject.Properties.Match('CpuVendorChangeReason').Count -gt 0) { [string]$row.CpuVendorChangeReason } else { 'N/A' }
                $vendorNote = if ($cpuVendorReason -eq 'LowerRetailPrice') {
                    "CPU vendor change ($currentCpuVendor -> $targetCpuVendor): selected for lower retail price than the compatible same-vendor alternative; validate vendor-sensitive licensing and performance assumptions."
                }
                else {
                    "CPU vendor change ($currentCpuVendor -> $targetCpuVendor): no compatible same-vendor alternative was available; validate vendor-sensitive licensing and performance assumptions."
                }
                $noteParts.Add($vendorNote) | Out-Null
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
            EquivalenceStatus  = $equivalenceStatus
            EquivalenceDetails = $equivalenceDetails
            SelectionReason    = $selectionReason
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
        ReportVersion      = $script:ReportVersion
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
            & $record '2. Run' 'STREAM B live (Learn markdown)' 'WARN' 'STREAM B failed (Learn markdown unavailable); partial-source policy permits remaining live source unless source health is BLOCK.'
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
                ($_.RetirementSourceGate -in @('LiveAdvisorArg', 'LiveLearnMarkdown', 'ReleaseCommunicationsApi'))
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
            ($_.RetirementSourceGate -in @('LiveAdvisorArg', 'LiveLearnMarkdown', 'ReleaseCommunicationsApi'))
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
    Extracts the VM family token from a SKU name, used to decide whether a recommendation crosses VM
    families (e.g. A1_v2 -> F1als_v7 is A -> F = cross-family). Legacy Premium Storage names place
    the capability suffix S before the size digit (for example DS2_v2); normalize that suffix so a
    Dsv2 -> Dadsv7 move remains in the D family.
    #>
    param([Parameter(Mandatory = $false)][string]$Sku)
    if ([string]::IsNullOrWhiteSpace($Sku)) { return '' }
    $s = $Sku -replace '^(?i)standard_', ''
    if ($s -match '^([A-Za-z]+)') {
        $token = $matches[1].ToUpperInvariant()
        if ($token -match '^(D|G)S$') { return $matches[1] }
        return $token
    }
    return ''
}

function Get-SkuCommercialWorkloadProfile {
    param([Parameter(Mandatory = $false)][string]$SkuName)

    switch (Get-SkuFamilyToken -Sku $SkuName) {
        'A' { return 'General purpose' }
        'B' { return 'Burstable general purpose' }
        'D' { return 'General purpose' }
        'DC' { return 'Confidential compute' }
        'E' { return 'Memory optimized' }
        'EC' { return 'Confidential compute' }
        'F' { return 'Compute optimized' }
        'G' { return 'Memory optimized' }
        'H' { return 'High performance compute' }
        'L' { return 'Storage optimized' }
        'M' { return 'Memory optimized' }
        'N' { return 'GPU accelerated' }
        default { return 'Unknown' }
    }
}

function Get-PreferredSuccessorFamilies {
    param([Parameter(Mandatory = $false)][string]$SkuName)

    switch (Get-SkuFamilyToken -Sku $SkuName) {
        'A' { return @('B', 'D') }
        default { return @() }
    }
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
        [Parameter(Mandatory = $false)][string]$CostFlag,
        [Parameter(Mandatory = $false)][bool]$CrossFamily = $false
    )
    $parts = New-Object 'System.Collections.Generic.List[string]'
    $targetSku = if ($Row.PSObject.Properties.Match('CandidateTargetSku').Count -gt 0 -and $Row.CandidateTargetSku) { [string]$Row.CandidateTargetSku } else { 'N/A' }
    if ($targetSku -eq 'N/A') {
        # No compatible target survived selection. The upstream candidate-strategy basis (e.g. a
        # cross-family attempt) describes an attempt that produced NO target, so echoing it here would
        # contradict both the N/A outcome and the low-complexity wave. Report the honest no-target line.
        return 'No compatible in-family or same-shape target found; keep the current SKU and monitor the roadmap.'
    }
    $basis = if ($Row.PSObject.Properties.Match('CandidateSelectionReason').Count -gt 0 -and $Row.CandidateSelectionReason) {
        [string]$Row.CandidateSelectionReason
    }
    elseif ($Row.PSObject.Properties.Match('RecommendationBasis').Count -gt 0 -and $Row.RecommendationBasis) {
        [string]$Row.RecommendationBasis
    }
    else { '' }
    if (-not $CrossFamily -and $basis -match '(?i)\bcross-family migration\b') {
        $basis = 'Heuristic: compatible same-family modernization (requires architecture validation)'
    }
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
    if ($Row.PSObject.Properties.Match('CandidateEquivalenceStatus').Count -gt 0 -and [string]$Row.CandidateEquivalenceStatus -eq 'NotEquivalent') {
        $details = if ($Row.PSObject.Properties.Match('CandidateEquivalenceDetails').Count -gt 0) { [string]$Row.CandidateEquivalenceDetails } else { 'Capability details unavailable.' }
        $list.Add("Not 100% equivalent: $details") | Out-Null
    }
    return $list.ToArray()
}

function Test-MeaningfulChecklistEntry {
    param([Parameter(Mandatory = $false)]$Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $false }
    $decoded = [System.Net.WebUtility]::HtmlDecode([string]$Value)
    $plainText = [regex]::Replace($decoded, '<[^>]+>', '').Trim()
    return -not [string]::IsNullOrWhiteSpace($plainText)
}

function Resolve-RemediationWaveFloor {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Critical', 'High', 'Medium', 'Watch')][string]$RiskLevel,
        [Parameter(Mandatory = $false)][bool]$IsSensitiveWorkload = $false,
        [Parameter(Mandatory = $false)][bool]$IsGenerationChange = $false,
        [Parameter(Mandatory = $false)][bool]$IsCrossFamily = $false
    )

    if ($null -eq $script:WaveOrder -or $script:WaveOrder.Count -eq 0) {
        throw 'Wave order is not initialized.'
    }

    $urgencyFloor = switch ($RiskLevel) {
        'Critical' { 'W0' }
        'High' { 'W1' }
        default { 'W4' }
    }

    $complexityFloor = if ($IsCrossFamily -or $IsGenerationChange) { 'W3' }
        elseif ($IsSensitiveWorkload) { 'W2' }
        else { 'W4' }

    $wave = if ([int]$script:WaveOrder[$urgencyFloor] -le [int]$script:WaveOrder[$complexityFloor]) { $urgencyFloor } else { $complexityFloor }

    return [pscustomobject]@{
        Wave            = $wave
        WaveNumber      = [int]$script:WaveOrder[$wave]
        UrgencyFloor    = $urgencyFloor
        ComplexityFloor = $complexityFloor
    }
}

function Resolve-RemediationWave {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Critical', 'High', 'Medium', 'Watch')][string]$RiskLevel,
        [Parameter(Mandatory = $false)][bool]$IsSensitiveWorkload = $false,
        [Parameter(Mandatory = $false)][string]$SensitiveReason = '',
        [Parameter(Mandatory = $false)][bool]$IsGenerationChange = $false,
        [Parameter(Mandatory = $false)][bool]$IsCrossFamily = $false,
        [Parameter(Mandatory = $false)][bool]$AdvisorConfirmed = $false
    )

    $floor = Resolve-RemediationWaveFloor -RiskLevel $RiskLevel -IsSensitiveWorkload $IsSensitiveWorkload -IsGenerationChange $IsGenerationChange -IsCrossFamily $IsCrossFamily

    $reasons = New-Object 'System.Collections.Generic.List[string]'
    switch ($RiskLevel) {
        'Critical' { $reasons.Add('UrgencyCritical') | Out-Null }
        'High' { $reasons.Add('UrgencyHigh') | Out-Null }
        default { $reasons.Add("UrgencyNone($RiskLevel)") | Out-Null }
    }
    if ($IsCrossFamily) { $reasons.Add('ComplexityCrossFamily') | Out-Null }
    if ($IsGenerationChange) { $reasons.Add('ComplexityGen1ToGen2') | Out-Null }
    if ($IsSensitiveWorkload) {
        $reason = if (-not [string]::IsNullOrWhiteSpace($SensitiveReason)) { $SensitiveReason } else { 'sensitive' }
        $reasons.Add("Sensitive:$reason") | Out-Null
    }
    if ($AdvisorConfirmed) { $reasons.Add('AdvisorConfirmed') | Out-Null }

    return [pscustomobject]@{
        Wave            = $floor.Wave
        WaveNumber      = $floor.WaveNumber
        UrgencyFloor    = $floor.UrgencyFloor
        ComplexityFloor = $floor.ComplexityFloor
        RiskLevel       = $RiskLevel
        ReasonCodes     = @($reasons.ToArray())
    }
}

function Get-WaveChipLabel {
    param([Parameter(Mandatory = $true)]$WaveResult)

    switch ([string]$WaveResult.Wave) {
        'W0' { return 'W0 · Time-critical' }
        'W1' {
            $reasonCodes = @($WaveResult.ReasonCodes)
            $hasAdvisor = ($reasonCodes -contains 'AdvisorConfirmed')
            $hasSensitive = @($reasonCodes | Where-Object { $_ -like 'Sensitive:*' }).Count -gt 0
            if ($hasAdvisor -and $hasSensitive) { return 'W1 · Advisor + sensitive' }
            if ($hasAdvisor) { return 'W1 · Advisor-confirmed' }
            if ($hasSensitive) { return 'W1 · Sensitive, high urgency' }
            return 'W1 · High urgency'
        }
        'W2' { return 'W2 · Sensitive validation' }
        'W3' { return 'W3 · Architecture' }
        default { return 'W4 · Low complexity' }
    }
}

function Get-WaveCardHeader {
    param(
        [Parameter(Mandatory = $true)][int]$WaveNumber,
        [Parameter(Mandatory = $false)][object[]]$Items = @(),
        [Parameter(Mandatory = $false)][string]$DefaultTitle = '',
        [Parameter(Mandatory = $false)][string]$DefaultNote = ''
    )

    $reasonCodes = New-Object 'System.Collections.Generic.List[string]'
    $itemReasonSets = New-Object 'System.Collections.Generic.List[object]'
    foreach ($item in @($Items)) {
        if ($null -eq $item -or $item.PSObject.Properties.Match('WaveReasons').Count -eq 0) { continue }
        $itemReasons = @($item.WaveReasons | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        if ($itemReasons.Count -gt 0) { $itemReasonSets.Add($itemReasons) | Out-Null }
        foreach ($reason in @($item.WaveReasons)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$reason)) {
                $reasonCodes.Add([string]$reason) | Out-Null
            }
        }
    }

    if ($WaveNumber -ne 3 -and $WaveNumber -ne 4) {
        return [pscustomobject]@{ Title = $DefaultTitle; Note = $DefaultNote }
    }

    $hasCrossFamily = ($reasonCodes -contains 'ComplexityCrossFamily')
    $hasGenerationChange = ($reasonCodes -contains 'ComplexityGen1ToGen2')
    $itemReasonSetCount = $itemReasonSets.Count
    $crossFamilyItemCount = @($itemReasonSets | Where-Object { @($_) -contains 'ComplexityCrossFamily' }).Count
    $allItemsCrossFamily = ($itemReasonSetCount -gt 0 -and $crossFamilyItemCount -eq $itemReasonSetCount)

    if ($WaveNumber -eq 4) {
        $complexityReasonSets = @(
            $itemReasonSets | ForEach-Object {
                $complexityReasons = @($_ | Where-Object { [string]$_ -like 'Complexity*' } | Sort-Object -Unique)
                if ($complexityReasons.Count -eq 0) { 'None' } else { $complexityReasons -join '|' }
            } | Sort-Object -Unique
        )
        $moveShapeSets = @(
            $Items | Where-Object { $_ } | ForEach-Object {
                if ($_.PSObject.Properties.Match('TargetSku').Count -gt 0 -and [string]$_.TargetSku -eq 'N/A') { 'NoCompatibleTarget' }
                elseif ($_.PSObject.Properties.Match('GenerationChange').Count -gt 0 -and [bool]$_.GenerationChange) { 'GenerationBoundary' }
                elseif ($_.PSObject.Properties.Match('CrossFamily').Count -gt 0 -and [bool]$_.CrossFamily) { 'CrossFamily' }
                else { 'SameGenerationResize' }
            } | Sort-Object -Unique
        )

        if ($complexityReasonSets.Count -eq 1 -and $complexityReasonSets[0] -eq 'None' -and $moveShapeSets.Count -eq 1 -and $moveShapeSets[0] -eq 'SameGenerationResize') {
            $title = 'Wave 4 - Low-complexity same-generation resize'
            $note = 'Low-complexity quick wins with no architecture or generation-boundary reason code; validate normal resize runbook prerequisites.'
        }
        else {
            $title = 'Wave 4 - Low-complexity moves (mixed)'
            $note = 'Low-complexity catch-all with mixed move characteristics; validate each workload against its row-level reason codes before batching.'
        }

        return [pscustomobject]@{ Title = $title; Note = $note }
    }

    if ($allItemsCrossFamily) {
        $title = 'Wave 3 - Cross-family Gen1->Gen2 (architecture validation)'
        $note = 'Highest validation effort: class change; validate architecture, capacity and rollback path.'
    }
    elseif ($hasCrossFamily -and $hasGenerationChange) {
        $title = 'Wave 3 - Architecture validation (Gen1->Gen2 / cross-family)'
        $note = 'Highest validation effort: class change and generation boundary; validate architecture, image generation, capacity and rollback path.'
    }
    elseif ($hasGenerationChange) {
        $title = 'Wave 3 - Same-family Gen1->Gen2 (generation boundary)'
        $note = 'Highest validation effort: generation boundary; validate image generation, boot/runtime assumptions, extensions and rollback path.'
    }
    else {
        $title = $DefaultTitle
        $note = $DefaultNote
    }

    return [pscustomobject]@{ Title = $title; Note = $note }
}

function Build-RemediationPlan {
    <#
    .SYNOPSIS
    Deterministic remediation wave plan. Assigns each retirement-path VM to exactly one wave using
    deterministic urgency and complexity floors, then attaches a rationale and a class checklist.

    .DESCRIPTION
    Wave routing uses the most governed lane from two deterministic floors:
    Wave 0 - Urgent retirement deadline      : RetirementRiskLevel is Critical.
    Wave 1 - High urgency / governed validation : RetirementRiskLevel is High.
    Wave 2 - Sensitive workload, same-generation resize : SensitiveWorkload when no higher urgency/complexity floor applies.
    Wave 3 - Cross-family or Gen1->Gen2     : GenerationChange OR cross-family.
    Wave 4 - Low-complexity same-generation resize : everything else.
    Order resolves the tricky rows without double counting: an Advisor-confirmed sensitive DC lands in
    Wave 1 (not Wave 3 even if it changes generation), and a Critical-risk row lands in Wave 0 (not Wave 3
    even if it is cross-family/gen-change). Operates only on retirement-path rows, so the wave counts
    sum to the retirement path total.
    #>
    param([Parameter(Mandatory = $true)][object[]]$Rows)

    $isRetirementFinding = {
        param($r)
        $gate = if ($r.PSObject.Properties.Match('RetirementSourceGate').Count -gt 0) { [string]$r.RetirementSourceGate } else { '' }
        $es = if ($r.PSObject.Properties.Match('EvidenceSource').Count -gt 0) { [string]$r.EvidenceSource } else { '' }
        if ($gate -in @('LiveLearnMarkdown', 'ReleaseCommunicationsApi') -or $es -in @('LiveLearnMarkdown', 'LiveLearnMarkdown + AdvisorSignal', 'ReleaseCommunicationsApi', 'ReleaseCommunicationsApi + AdvisorSignal')) { return $true }
        if ($gate -eq 'LiveAdvisorArg' -or $es -eq 'AdvisorSignalOnly') { return $true }
        return $false
    }

    $waveMeta = @(
        [pscustomobject]@{ Number = 0; Title = 'Wave 0 - Critical retirement deadline'; Note = 'Critical retirement path (within the configured critical-day threshold); schedule first.' }
        [pscustomobject]@{ Number = 1; Title = 'Wave 1 - High urgency / governed validation'; Note = 'High urgency retirement path, with Advisor/sensitive reason codes shown per workload when present.' }
        [pscustomobject]@{ Number = 2; Title = 'Wave 2 - Sensitive workload, same-generation resize'; Note = 'Lower technical change, but validation is still required for sensitive workloads.' }
        [pscustomobject]@{ Number = 3; Title = 'Wave 3 - Cross-family Gen1->Gen2 (needs architecture validation)'; Note = 'Highest validation effort: class change plus generation boundary.' }
        [pscustomobject]@{ Number = 4; Title = 'Wave 4 - Low-complexity same-generation resize'; Note = 'Low-complexity quick wins, often cost-negative.' }
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
        $es = if ($row.PSObject.Properties.Match('EvidenceSource').Count -gt 0) { [string]$row.EvidenceSource } else { '' }
        $sensitive = ($row.PSObject.Properties.Match('SensitiveWorkload').Count -gt 0 -and [bool]$row.SensitiveWorkload)
        $sensitiveReason = if ($row.PSObject.Properties.Match('WorkloadRole').Count -gt 0 -and $row.WorkloadRole) { [string]$row.WorkloadRole } else { '' }
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

        $advisorConfirmed = ($gate -eq 'LiveAdvisorArg' -or $es -eq 'AdvisorSignalOnly')
        $waveResult = Resolve-RemediationWave -RiskLevel $riskLevel -IsSensitiveWorkload $sensitive -SensitiveReason $sensitiveReason -IsGenerationChange $genChange -IsCrossFamily $crossFamily -AdvisorConfirmed $advisorConfirmed

        $r = [pscustomobject]@{
            Wave           = [string]$waveResult.Wave
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
            WaveReasons    = @($waveResult.ReasonCodes)
            UrgencyFloor   = $waveResult.UrgencyFloor
            ComplexityFloor = $waveResult.ComplexityFloor
            WaveChipLabel  = Get-WaveChipLabel -WaveResult $waveResult
            Rationale      = Get-RemediationRationale -Row $row -CostFlag $costFlag -CrossFamily $crossFamily
            Checklist      = @(Get-RemediationChecklist -Row $row -CrossFamily $crossFamily)
        }
        $expectedWave = Resolve-RemediationWaveFloor -RiskLevel $riskLevel -IsSensitiveWorkload $sensitive -IsGenerationChange $genChange -IsCrossFamily $crossFamily
        if ($r.Wave -ne $expectedWave.Wave) {
            throw "Wave invariant violated on $($r.VmName): $($r.Wave) != $($expectedWave.Wave) [$($r.WaveReasons -join ',')] facts risk=$riskLevel sensitive=$sensitive generationChange=$genChange crossFamily=$crossFamily"
        }
        $wave = [int]$script:WaveOrder[$r.Wave]
        $byWave[$wave].Add($r) | Out-Null
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
            $checks = @(
                foreach ($check in @($it.Checklist)) {
                    if (Test-MeaningfulChecklistEntry $check) { $check }
                }
            )
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

function ConvertTo-ReleaseCommunicationHtml {
    param([Parameter(Mandatory = $false)]$ReleaseCommunicationContext)

    function ConvertTo-ReleaseHtmlText([object]$Value) {
        if ($null -eq $Value) { return '' }
        return [System.Net.WebUtility]::HtmlEncode([string]$Value)
    }

    if (-not $ReleaseCommunicationContext) { return '' }

    $status = if ($ReleaseCommunicationContext.PSObject.Properties.Match('Status').Count -gt 0) { [string]$ReleaseCommunicationContext.Status } else { 'Unknown' }
    $checkedAt = if ($ReleaseCommunicationContext.PSObject.Properties.Match('CheckedAtUtc').Count -gt 0) { [string]$ReleaseCommunicationContext.CheckedAtUtc } else { 'N/A' }
    $lookback = if ($ReleaseCommunicationContext.PSObject.Properties.Match('LookbackMonths').Count -gt 0) { [int]$ReleaseCommunicationContext.LookbackMonths } else { 0 }
    $historyScope = if ($lookback -gt 0) { "over the last $lookback month(s)" } else { 'across all available history' }
    $url = if ($ReleaseCommunicationContext.PSObject.Properties.Match('Url').Count -gt 0) { [string]$ReleaseCommunicationContext.Url } else { '' }
    $rows = if ($ReleaseCommunicationContext.PSObject.Properties.Match('Rows').Count -gt 0) { @($ReleaseCommunicationContext.Rows) } else { @() }

    $builder = New-Object 'System.Text.StringBuilder'
    [void]$builder.Append("<section class='panel release-panel'><h2>Official Microsoft Communications <span class='tag tag-preview'>Official source</span></h2>")
    [void]$builder.Append("<p class='meta'>Microsoft Release Communications API checked at $(ConvertTo-ReleaseHtmlText $checkedAt) $(ConvertTo-ReleaseHtmlText $historyScope). Deterministic SKU-family matches with structured retirement availability are used as authoritative findings; unmatched notices remain coverage context.</p>")
    if ($status -ne 'OK') {
        $errorText = if ($ReleaseCommunicationContext.PSObject.Properties.Match('Error').Count -gt 0) { [string]$ReleaseCommunicationContext.Error } else { 'N/A' }
        [void]$builder.Append("<p class='meta'>API status: <strong>$(ConvertTo-ReleaseHtmlText $status)</strong>. Report numbers are unchanged. $(ConvertTo-ReleaseHtmlText $errorText)</p>")
        [void]$builder.Append('</section>')
        return $builder.ToString()
    }

    [void]$builder.Append("<div class='kpis preview-kpis'><div class='kpi'><div class='kpi-label'>Relevant notices</div><div class='kpi-value'>$(ConvertTo-ReleaseHtmlText $ReleaseCommunicationContext.RelevantCount)</div></div><div class='kpi'><div class='kpi-label'>Corroborated</div><div class='kpi-value'>$(ConvertTo-ReleaseHtmlText $ReleaseCommunicationContext.CorroboratedCount)</div></div><div class='kpi'><div class='kpi-label'>FinOps</div><div class='kpi-value'>$(ConvertTo-ReleaseHtmlText $ReleaseCommunicationContext.FinOpsCount)</div></div><div class='kpi'><div class='kpi-label'>Review-only</div><div class='kpi-value'>$(ConvertTo-ReleaseHtmlText $ReleaseCommunicationContext.ReviewOnlyCount)</div></div></div>")

    if ($rows.Count -eq 0) {
        [void]$builder.Append("<p class='meta'>No VM, VMSS, Batch or retirement notices were returned by the configured API query. Source: <a href='$(ConvertTo-ReleaseHtmlText $url)'>Release Communications API</a>.</p>")
        [void]$builder.Append('</section>')
        return $builder.ToString()
    }

    foreach ($bucket in @('Corroborated', 'FinOps', 'Review-only')) {
        $bucketRows = @($rows | Where-Object { [string]$_.Bucket -eq $bucket })
        if ($bucketRows.Count -eq 0) { continue }
        [void]$builder.Append("<h3>$(ConvertTo-ReleaseHtmlText $bucket)</h3><div class='table-wrap'><table><thead><tr><th>Published</th><th>Title</th><th>Service / topic</th><th>How the report uses it</th><th>Link</th></tr></thead><tbody>")
        foreach ($row in $bucketRows) {
            $link = if ($row.PSObject.Properties.Match('Link').Count -gt 0) { [string]$row.Link } else { '' }
            $linkHtml = if (-not [string]::IsNullOrWhiteSpace($link)) { "<a href='$(ConvertTo-ReleaseHtmlText $link)'>Open notice</a>" } else { 'N/A' }
            $topic = if ($row.PSObject.Properties.Match('MatchedTopic').Count -gt 0 -and $row.MatchedTopic) { [string]$row.MatchedTopic } else { [string]$row.Service }
            [void]$builder.Append("<tr><td>$(ConvertTo-ReleaseHtmlText $row.PublishedDate)</td><td><strong>$(ConvertTo-ReleaseHtmlText $row.Title)</strong><br/><span class='meta'>$(ConvertTo-ReleaseHtmlText $row.Service)</span></td><td>$(ConvertTo-ReleaseHtmlText $topic)</td><td>$(ConvertTo-ReleaseHtmlText $row.ReportUsage)</td><td>$linkHtml</td></tr>")
        }
        [void]$builder.Append('</tbody></table></div>')
    }

    [void]$builder.Append('</section>')
    return $builder.ToString()
}

function ConvertTo-SimplifiedReportHtml {
    param(
        [Parameter(Mandatory = $true)]$Facts,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $false)]$RemediationPlan,
        [Parameter(Mandatory = $false)]$Provenance,
        [Parameter(Mandatory = $false)]$BatchPoolPreview,
        [Parameter(Mandatory = $false)]$VmssPreview,
        [Parameter(Mandatory = $false)]$ReservedInstanceCutoffPreview,
        [Parameter(Mandatory = $false)]$ReleaseCommunicationContext,
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
    $costCoveredCount = if ($Facts.PSObject.Properties.Match('CostCovered').Count -gt 0) { [int]$Facts.CostCovered } else { 0 }
    $costMissingCount = if ($Facts.PSObject.Properties.Match('CostMissing').Count -gt 0) { [int]$Facts.CostMissing } else { [math]::Max(0, [int]$Facts.RetireCount - $costCoveredCount) }
    $costPopulationCount = $costCoveredCount + $costMissingCount
    $monitoringCount = @($Facts.MonitoringRows).Count
    $genChangeCount = if ($Facts.PSObject.Properties.Match('SkuChangeWithGenChange').Count -gt 0) { [int]$Facts.SkuChangeWithGenChange } else { 0 }
    $noGenChangeCount = if ($Facts.PSObject.Properties.Match('SkuChangeWithoutGenChange').Count -gt 0) { [int]$Facts.SkuChangeWithoutGenChange } else { 0 }
    $withheldChangeCount = if ($Facts.PSObject.Properties.Match('RecommendationWithheldCount').Count -gt 0) { [int]$Facts.RecommendationWithheldCount } else { 0 }
    $commitmentImpactCount = if ($Facts.PSObject.Properties.Match('CommitmentImpactCount').Count -gt 0) { [int]$Facts.CommitmentImpactCount } else { 0 }

    $batchPreviewRows = @()
    $batchPreviewScanned = 0
    if ($BatchPoolPreview) {
        if ($BatchPoolPreview.PSObject.Properties.Match('Rows').Count -gt 0) { $batchPreviewRows = @($BatchPoolPreview.Rows) }
        if ($BatchPoolPreview.PSObject.Properties.Match('TotalBatchPoolsScanned').Count -gt 0) { $batchPreviewScanned = [int]$BatchPoolPreview.TotalBatchPoolsScanned }
    }

    $vmssPreviewRows = @()
    $vmssPreviewScanned = 0
    if ($VmssPreview) {
        if ($VmssPreview.PSObject.Properties.Match('Rows').Count -gt 0) { $vmssPreviewRows = @($VmssPreview.Rows) }
        if ($VmssPreview.PSObject.Properties.Match('TotalVmssScanned').Count -gt 0) { $vmssPreviewScanned = [int]$VmssPreview.TotalVmssScanned }
    }

    $riCutoffRows = @()
    $riCutoffScanned = 0
    $riCutoffDate = 'N/A'
    if ($ReservedInstanceCutoffPreview) {
        if ($ReservedInstanceCutoffPreview.PSObject.Properties.Match('Rows').Count -gt 0) { $riCutoffRows = @($ReservedInstanceCutoffPreview.Rows) }
        if ($ReservedInstanceCutoffPreview.PSObject.Properties.Match('TotalResourcesScanned').Count -gt 0) { $riCutoffScanned = [int]$ReservedInstanceCutoffPreview.TotalResourcesScanned }
        if ($ReservedInstanceCutoffPreview.PSObject.Properties.Match('CutoffDate').Count -gt 0 -and $ReservedInstanceCutoffPreview.CutoffDate) { $riCutoffDate = [string]$ReservedInstanceCutoffPreview.CutoffDate }
    }

    $sidecarRetirementCount = $batchPreviewRows.Count + $vmssPreviewRows.Count
    $computeRetirementCount = [int]$Facts.RetireCount + $sidecarRetirementCount
    $computeScannedCount = [int]$Facts.TotalVmCount + $batchPreviewScanned + $vmssPreviewScanned
    $releaseCommunicationHtml = ConvertTo-ReleaseCommunicationHtml -ReleaseCommunicationContext $ReleaseCommunicationContext
    $releaseCommunicationStatusText = 'not checked'
    if ($ReleaseCommunicationContext) {
        $communicationStatus = if ($ReleaseCommunicationContext.PSObject.Properties.Match('Status').Count -gt 0) { [string]$ReleaseCommunicationContext.Status } else { 'Unknown' }
        $communicationChecked = if ($ReleaseCommunicationContext.PSObject.Properties.Match('CheckedAtUtc').Count -gt 0) { [string]$ReleaseCommunicationContext.CheckedAtUtc } else { 'N/A' }
        $communicationRelevant = if ($ReleaseCommunicationContext.PSObject.Properties.Match('RelevantCount').Count -gt 0) { [int]$ReleaseCommunicationContext.RelevantCount } else { 0 }
        $communicationReviewOnly = if ($ReleaseCommunicationContext.PSObject.Properties.Match('ReviewOnlyCount').Count -gt 0) { [int]$ReleaseCommunicationContext.ReviewOnlyCount } else { 0 }
        if ($communicationStatus -eq 'OK') {
            $releaseCommunicationStatusText = "checked $communicationChecked | $communicationRelevant relevant | $communicationReviewOnly review-only"
        }
        else {
            $releaseCommunicationStatusText = "$communicationStatus | report numbers unchanged"
        }
    }

    $previewCoverageHtml = @"
<section class="panel preview-panel">
<h2>Preview Sidecar Coverage <span class="tag tag-preview">Public Preview</span></h2>
<p class="meta">VMSS and Batch are scanned as separate compute sidecars. They are visible here even when zero resources are impacted, and remain outside standalone VM waves and backlog counts.</p>
<div class="kpis preview-kpis">
<div class="kpi"><div class="kpi-label">VMSS scanned</div><div class="kpi-value">$(ConvertTo-HtmlText $vmssPreviewScanned)</div><div class="kpi-sub">$(ConvertTo-HtmlText $vmssPreviewRows.Count) on retirement path</div></div>
<div class="kpi"><div class="kpi-label">Batch pools scanned</div><div class="kpi-value">$(ConvertTo-HtmlText $batchPreviewScanned)</div><div class="kpi-sub">$(ConvertTo-HtmlText $batchPreviewRows.Count) on retirement path</div></div>
</div>
</section>
"@

    $generatedUtc = if ($Provenance -and $Provenance.PSObject.Properties.Match('GeneratedUtc').Count -gt 0) { [string]$Provenance.GeneratedUtc } else { [string]$Facts.GeneratedAtUtc }
    $reportVersion = if ($Facts.PSObject.Properties.Match('ReportVersion').Count -gt 0) { [string]$Facts.ReportVersion } else { 'N/A' }
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

    $statusLine = "$(ConvertTo-HtmlText $computeRetirementCount)/$(ConvertTo-HtmlText $computeScannedCount) compute resources on retirement path | VM $(ConvertTo-HtmlText $Facts.RetireCount), VMSS $(ConvertTo-HtmlText $vmssPreviewRows.Count), Batch $(ConvertTo-HtmlText $batchPreviewRows.Count) | $(ConvertTo-HtmlText $costImpactCompact) | nearest deadline $(ConvertTo-HtmlText $deadlineText)"

    function Get-WaveCssClass([object]$Number) {
        return ('w{0}' -f [int]$Number)
    }

    function Get-WaveUrgency([object]$Number) {
        switch ([int]$Number) {
            0 { return 'Time-critical' }
            1 { return 'High urgency' }
            2 { return 'Sensitive validation' }
            3 { return 'Architecture' }
            default { return 'Low complexity' }
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
        $waveHeader = Get-WaveCardHeader -WaveNumber ([int]$wave.Number) -Items $items -DefaultTitle ([string]$wave.Title) -DefaultNote ([string]$wave.Note)
        [void]$timelineBuilder.Append("<article class='timeline-card $accentClass'><div class='timeline-top'><span class='wave-code'>W$($wave.Number)</span><span class='urgency'>$(ConvertTo-HtmlText $urgencyText)</span></div><div class='timeline-count'>$(ConvertTo-HtmlText $count)</div><div class='timeline-label'>$(ConvertTo-HtmlText $waveHeader.Title)</div></article>")

        if ($count -eq 0) { continue }
        $openAttr = if ($wave.Number -le 1) { ' open' } else { '' }
        [void]$waveBuilder.Append("<details class='wave-card $accentClass'$openAttr><summary><span class='wave-head'><span class='wave-code'>W$($wave.Number)</span> $(ConvertTo-HtmlText $waveHeader.Title)</span><span class='wave-head-count'>$(ConvertTo-HtmlText $count) VM$(if ($count -ne 1) { 's' }) &middot; $(ConvertTo-HtmlText $urgencyText)</span></summary>")
        [void]$waveBuilder.Append("<p class='wave-note'>$(ConvertTo-HtmlText $waveHeader.Note)</p>")
        foreach ($it in $items) {
            if ($it.PSObject.Properties.Match('VmName').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$it.VmName)) {
                $chipLabel = if ($it.PSObject.Properties.Match('WaveChipLabel').Count -gt 0 -and $it.WaveChipLabel) { [string]$it.WaveChipLabel } else { "W$($wave.Number) · $urgencyText" }
                $waveByVm[[string]$it.VmName] = [pscustomobject]@{ Number = [int]$wave.Number; Urgency = $urgencyText; CssClass = $accentClass; ChipLabel = $chipLabel }
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
            $checks = @(
                foreach ($check in @($it.Checklist)) {
                    if (Test-MeaningfulChecklistEntry $check) { $check }
                }
            )
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

    $waveCountByNumber = @{}
    foreach ($wave in @($RemediationPlan.Waves)) {
        $waveCountByNumber[[int]$wave.Number] = @($wave.Items).Count
    }
    $w0Count = if ($waveCountByNumber.ContainsKey(0)) { [int]$waveCountByNumber[0] } else { 0 }
    $w1Count = if ($waveCountByNumber.ContainsKey(1)) { [int]$waveCountByNumber[1] } else { 0 }
    $w2Count = if ($waveCountByNumber.ContainsKey(2)) { [int]$waveCountByNumber[2] } else { 0 }
    $w3Count = if ($waveCountByNumber.ContainsKey(3)) { [int]$waveCountByNumber[3] } else { 0 }
    $w4Count = if ($waveCountByNumber.ContainsKey(4)) { [int]$waveCountByNumber[4] } else { 0 }

    $actNowCount = $w0Count
    $planNowCount = $w1Count + $w2Count + $w3Count
    $quickWinCount = $w4Count
    $advisorConfidencePercent = if ([int]$Facts.RetireCount -gt 0) {
        [int][math]::Round(([double]$Facts.AdvisorConfirmed / [double]$Facts.RetireCount) * 100.0, 0)
    }
    else { 0 }

    $topDeadlines = New-Object 'System.Collections.Generic.List[object]'
    foreach ($factRow in @($Facts.Rows)) {
        if ($factRow.PSObject.Properties.Match('RetirementDate').Count -eq 0) { continue }
        $dateText = [string]$factRow.RetirementDate
        if ([string]::IsNullOrWhiteSpace($dateText) -or $dateText -eq 'N/A') { continue }
        $parsed = [datetime]::MinValue
        if (-not [datetime]::TryParse($dateText, [ref]$parsed)) { continue }
        $vmName = if ($factRow.PSObject.Properties.Match('VmName').Count -gt 0) { [string]$factRow.VmName } else { 'N/A' }
        $nextStep = if ($factRow.PSObject.Properties.Match('NextStep').Count -gt 0) { [string]$factRow.NextStep } else { '' }
        $topDeadlines.Add([pscustomobject]@{
                Date    = $parsed
                DateText = $dateText
                VmName  = $vmName
                NextStep = $nextStep
            }) | Out-Null
    }

    $countdownBuilder = New-Object 'System.Text.StringBuilder'
    $topDeadlineRows = @($topDeadlines | Sort-Object -Property Date | Select-Object -First 4)
    if ($topDeadlineRows.Count -gt 0) {
        [void]$countdownBuilder.Append("<ol class='countdown-list'>")
        foreach ($d in $topDeadlineRows) {
            $subtitle = if (-not [string]::IsNullOrWhiteSpace([string]$d.NextStep)) { [string]$d.NextStep } else { 'Validate migration sequence and execution window.' }
            [void]$countdownBuilder.Append("<li><span class='deadline-date'>$(ConvertTo-HtmlText $d.DateText)</span><strong>$(ConvertTo-HtmlText $d.VmName)</strong><span>$(ConvertTo-HtmlText $subtitle)</span></li>")
        }
        [void]$countdownBuilder.Append("</ol>")
    }
    else {
        [void]$countdownBuilder.Append("<p class='meta'>No dated retirement rows available in this scope.</p>")
    }

    $monitoringTableHtml = ''
    if ($monitoringCount -gt 0) {
        $monitoringTable = New-Object 'System.Text.StringBuilder'
        [void]$monitoringTable.Append("<div class='table-wrap'><table class='monitor-table'><thead><tr><th>VM</th><th>Feature retiring</th><th>Retirement date</th><th>Agent state</th><th>Action</th></tr></thead><tbody>")
        foreach ($monitoringRow in @($Facts.MonitoringRows)) {
            $state = if ($monitoringRow.PSObject.Properties.Match('AgentPresence').Count -gt 0 -and $monitoringRow.AgentPresence) { [string]$monitoringRow.AgentPresence } else { 'Unknown' }
            $resourceId = if ($monitoringRow.PSObject.Properties.Match('ResourceId').Count -gt 0) { [string]$monitoringRow.ResourceId } else { '' }
            $vmDisplay = if ($resourceId) { ($resourceId -split '/')[-1] } else { 'N/A' }
            $retireDate = if ($monitoringRow.PSObject.Properties.Match('RetireOn').Count -gt 0 -and $monitoringRow.RetireOn) { [string]$monitoringRow.RetireOn } else { 'N/A' }
            $stateClass = switch ($state) { 'Confirmed' { 'tag-gen' } 'Unconfirmed' { 'tag-os' } default { 'tag-advisor' } }
            $action = switch ($state) {
                'Confirmed'   { 'Plan offboarding before the Advisor retirement date; select a Marketplace mapping solution if process/dependency data is required.' }
                'Unconfirmed' { 'No action: Dependency Agent not detected; review residual DCR/Policy assignment if unused.' }
                default       { 'Verify manually whether the Dependency Agent is installed.' }
            }
            [void]$monitoringTable.Append("<tr><td><strong>$(ConvertTo-HtmlText $vmDisplay)</strong></td><td>Dependency Agent / VM Insights Map</td><td>$(ConvertTo-HtmlText $retireDate)</td><td><span class='tag $stateClass'>$(ConvertTo-HtmlText $state)</span></td><td>$(ConvertTo-HtmlText $action)</td></tr>")
        }
        [void]$monitoringTable.Append('</tbody></table></div>')
        $monitoringTableHtml = $monitoringTable.ToString()
    }

    $batchPoolPreviewHtml = ''

    if ($batchPreviewScanned -gt 0 -or $batchPreviewRows.Count -gt 0) {
        $batchBuilder = New-Object 'System.Text.StringBuilder'
        [void]$batchBuilder.Append("<section class='panel preview-panel'><h2>Azure Batch Pool Exposure <span class='tag tag-preview'>Public Preview</span></h2>")
        [void]$batchBuilder.Append("<p class='meta'>Batch pools are separate Azure Batch resources that use normal Azure VM sizes. This preview reuses the same VM-size retirement resolver, but keeps Batch out of the VM retirement totals.</p>")
        [void]$batchBuilder.Append("<div class='kpis preview-kpis'><div class='kpi'><div class='kpi-label'>Batch pools scanned</div><div class='kpi-value'>$(ConvertTo-HtmlText $batchPreviewScanned)</div></div><div class='kpi'><div class='kpi-label'>On retirement path</div><div class='kpi-value'>$(ConvertTo-HtmlText $batchPreviewRows.Count)</div></div></div>")
        if ($batchPreviewRows.Count -gt 0) {
            [void]$batchBuilder.Append("<div class='table-wrap'><table><thead><tr><th>Batch account / pool</th><th>VM size</th><th>Retirement</th><th>Pool capacity</th><th>Action</th></tr></thead><tbody>")
            foreach ($batchRow in $batchPreviewRows) {
                $poolLabel = "$(ConvertTo-HtmlText $batchRow.BatchAccountName)<br/><strong>$(ConvertTo-HtmlText $batchRow.PoolName)</strong><br/><span class='meta'>$(ConvertTo-HtmlText $batchRow.Region)</span>"
                $capacityText = "Dedicated target: $(ConvertTo-HtmlText $batchRow.TargetDedicatedNodes)<br/>Low priority target: $(ConvertTo-HtmlText $batchRow.TargetLowPriorityNodes)<br/>Spot target: $(ConvertTo-HtmlText $batchRow.TargetSpotNodes)<br/><span class='meta'>State: $(ConvertTo-HtmlText $batchRow.AllocationState)</span>"
                [void]$batchBuilder.Append("<tr><td>$poolLabel</td><td>$(ConvertTo-HtmlText $batchRow.CurrentSku)<br/><span class='meta'>$(ConvertTo-HtmlText $batchRow.SeriesName)</span></td><td><span class='tag tag-learn'>$(ConvertTo-HtmlText $batchRow.EvidenceSource)</span><br/><span class='meta'>Date: $(ConvertTo-HtmlText $batchRow.RetirementDate)</span></td><td>$capacityText</td><td>$(ConvertTo-HtmlText $batchRow.NextStep)</td></tr>")
            }
            [void]$batchBuilder.Append('</tbody></table></div>')
        }
        else {
            [void]$batchBuilder.Append('<p class="meta">No Batch pool VM sizes matched the current retirement path in this scope.</p>')
        }
        [void]$batchBuilder.Append('</section>')
        $batchPoolPreviewHtml = $batchBuilder.ToString()
    }

    $vmssPreviewHtml = ''

    if ($vmssPreviewScanned -gt 0 -or $vmssPreviewRows.Count -gt 0) {
        $vmssBuilder = New-Object 'System.Text.StringBuilder'
        [void]$vmssBuilder.Append("<section class='panel preview-panel'><h2>Virtual Machine Scale Set Exposure <span class='tag tag-preview'>Public Preview</span></h2>")
        [void]$vmssBuilder.Append("<p class='meta'>VM Scale Sets are separate compute resources that use normal Azure VM sizes. This preview matches VMSS <code>sku.name</code> against the same live VM-size retirement resolver, but keeps VMSS out of the VM retirement totals.</p>")
        [void]$vmssBuilder.Append("<div class='kpis preview-kpis'><div class='kpi'><div class='kpi-label'>VMSS scanned</div><div class='kpi-value'>$(ConvertTo-HtmlText $vmssPreviewScanned)</div></div><div class='kpi'><div class='kpi-label'>On retirement path</div><div class='kpi-value'>$(ConvertTo-HtmlText $vmssPreviewRows.Count)</div></div></div>")
        if ($vmssPreviewRows.Count -gt 0) {
            [void]$vmssBuilder.Append("<div class='table-wrap'><table><thead><tr><th>Scale set</th><th>VM size</th><th>Retirement</th><th>Scale set model</th><th>Action</th></tr></thead><tbody>")
            foreach ($vmssRow in $vmssPreviewRows) {
                $vmssLabel = "<strong>$(ConvertTo-HtmlText $vmssRow.VmssName)</strong><br/><span class='meta'>$(ConvertTo-HtmlText $vmssRow.Region)</span>"
                $modelText = "Capacity: $(ConvertTo-HtmlText $vmssRow.Capacity)<br/>Orchestration: $(ConvertTo-HtmlText $vmssRow.OrchestrationMode)<br/>Upgrade: $(ConvertTo-HtmlText $vmssRow.UpgradeMode)<br/><span class='meta'>OS: $(ConvertTo-HtmlText $vmssRow.OsType) &middot; State: $(ConvertTo-HtmlText $vmssRow.ProvisioningState)</span>"
                [void]$vmssBuilder.Append("<tr><td>$vmssLabel</td><td>$(ConvertTo-HtmlText $vmssRow.CurrentSku)<br/><span class='meta'>$(ConvertTo-HtmlText $vmssRow.SeriesName)</span></td><td><span class='tag tag-learn'>$(ConvertTo-HtmlText $vmssRow.EvidenceSource)</span><br/><span class='meta'>Date: $(ConvertTo-HtmlText $vmssRow.RetirementDate)</span></td><td>$modelText</td><td>$(ConvertTo-HtmlText $vmssRow.NextStep)</td></tr>")
            }
            [void]$vmssBuilder.Append('</tbody></table></div>')
        }
        else {
            [void]$vmssBuilder.Append('<p class="meta">No VM Scale Set VM sizes matched the current retirement path in this scope.</p>')
        }
        [void]$vmssBuilder.Append('</section>')
        $vmssPreviewHtml = $vmssBuilder.ToString()
    }

    $previewRemediationHtml = ''
    if ($sidecarRetirementCount -gt 0) {
        $previewRemediationBuilder = New-Object 'System.Text.StringBuilder'
        [void]$previewRemediationBuilder.Append("<section class='panel preview-panel'><h2>Preview Remediation Queue - VMSS and Batch <span class='tag tag-preview'>Public Preview</span></h2>")
        [void]$previewRemediationBuilder.Append("<p class='meta'>Operational remediation queue for preview sidecars. These resources are visible in executive totals, but remain outside standalone VM waves because VMSS and Batch require model-level rollout and pool-level replacement patterns.</p>")
        [void]$previewRemediationBuilder.Append("<div class='table-wrap'><table><thead><tr><th>Priority</th><th>Resource</th><th>Operational model</th><th>Remediation pattern</th><th>Guardrails</th></tr></thead><tbody>")

        $previewQueueRows = New-Object 'System.Collections.Generic.List[object]'
        foreach ($vmssRow in $vmssPreviewRows) {
            $dateText = if ($vmssRow.PSObject.Properties.Match('RetirementDate').Count -gt 0) { [string]$vmssRow.RetirementDate } else { 'N/A' }
            $parsedDate = [datetime]::MaxValue
            $hasDate = [datetime]::TryParse($dateText, [ref]$parsedDate)
            $upgradeMode = if ($vmssRow.PSObject.Properties.Match('UpgradeMode').Count -gt 0 -and $vmssRow.UpgradeMode) { [string]$vmssRow.UpgradeMode } else { 'N/A' }
            $orchestrationMode = if ($vmssRow.PSObject.Properties.Match('OrchestrationMode').Count -gt 0 -and $vmssRow.OrchestrationMode) { [string]$vmssRow.OrchestrationMode } else { 'N/A' }
            $vmssAction = switch -Regex ($upgradeMode) {
                'Manual' { 'Update the scale set model to a supported VM size, then roll instances in controlled batches using planned upgrade/reimage windows.'; break }
                'Rolling|Automatic' { 'Update the scale set model to a supported VM size and use the configured upgrade policy for a staged rollout.'; break }
                default { 'Update the scale set model to a supported VM size and choose a controlled rollout method before changing production capacity.' }
            }
            $previewQueueRows.Add([pscustomobject]@{
                    SortDate    = if ($hasDate) { $parsedDate } else { [datetime]::MaxValue }
                    SortType    = 0
                    SortName    = [string]$vmssRow.VmssName
                    Priority    = if ($hasDate) { $dateText } else { 'Date n/a' }
                    Resource    = "<strong>$(ConvertTo-HtmlText $vmssRow.VmssName)</strong><br/><span class='meta'>VMSS &middot; $(ConvertTo-HtmlText $vmssRow.Region)</span>"
                    Model       = "SKU: $(ConvertTo-HtmlText $vmssRow.CurrentSku)<br/>Capacity: $(ConvertTo-HtmlText $vmssRow.Capacity)<br/><span class='meta'>Orchestration: $(ConvertTo-HtmlText $orchestrationMode) &middot; Upgrade: $(ConvertTo-HtmlText $upgradeMode)</span>"
                    Pattern     = $vmssAction
                    Guardrails  = 'Validate image generation, extensions, health probes, autoscale rules, regional quota/capacity and rollback path before applying the model update.'
                }) | Out-Null
        }

        foreach ($batchRow in $batchPreviewRows) {
            $dateText = if ($batchRow.PSObject.Properties.Match('RetirementDate').Count -gt 0) { [string]$batchRow.RetirementDate } else { 'N/A' }
            $parsedDate = [datetime]::MaxValue
            $hasDate = [datetime]::TryParse($dateText, [ref]$parsedDate)
            $allocationState = if ($batchRow.PSObject.Properties.Match('AllocationState').Count -gt 0 -and $batchRow.AllocationState) { [string]$batchRow.AllocationState } else { 'N/A' }
            $previewQueueRows.Add([pscustomobject]@{
                    SortDate    = if ($hasDate) { $parsedDate } else { [datetime]::MaxValue }
                    SortType    = 1
                    SortName    = "$(ConvertTo-HtmlText $batchRow.BatchAccountName)/$(ConvertTo-HtmlText $batchRow.PoolName)"
                    Priority    = if ($hasDate) { $dateText } else { 'Date n/a' }
                    Resource    = "$(ConvertTo-HtmlText $batchRow.BatchAccountName)<br/><strong>$(ConvertTo-HtmlText $batchRow.PoolName)</strong><br/><span class='meta'>Batch pool &middot; $(ConvertTo-HtmlText $batchRow.Region)</span>"
                    Model       = "SKU: $(ConvertTo-HtmlText $batchRow.CurrentSku)<br/>Dedicated: $(ConvertTo-HtmlText $batchRow.TargetDedicatedNodes) &middot; Low priority: $(ConvertTo-HtmlText $batchRow.TargetLowPriorityNodes) &middot; Spot: $(ConvertTo-HtmlText $batchRow.TargetSpotNodes)<br/><span class='meta'>Allocation: $(ConvertTo-HtmlText $allocationState)</span>"
                    Pattern     = 'Create a replacement pool with a supported VM size and compatible image/node agent, validate autoscale and quotas, drain running work, then move schedules/jobs to the new pool.'
                    Guardrails  = 'Preserve job scheduling windows, task dependencies, application packages, certificates/identity, networking and pool start-task behavior before deleting the old pool.'
                }) | Out-Null
        }

        foreach ($queueRow in @($previewQueueRows.ToArray() | Sort-Object SortDate, SortType, SortName)) {
            [void]$previewRemediationBuilder.Append("<tr><td><span class='tag tag-learn'>$(ConvertTo-HtmlText $queueRow.Priority)</span></td><td>$($queueRow.Resource)</td><td>$($queueRow.Model)</td><td>$(ConvertTo-HtmlText $queueRow.Pattern)</td><td>$(ConvertTo-HtmlText $queueRow.Guardrails)</td></tr>")
        }

        [void]$previewRemediationBuilder.Append('</tbody></table></div></section>')
        $previewRemediationHtml = $previewRemediationBuilder.ToString()
    }

    $riCutoffPreviewHtml = ''

    if ($riCutoffScanned -gt 0 -or $riCutoffRows.Count -gt 0) {
        $riBuilder = New-Object 'System.Text.StringBuilder'
        [void]$riBuilder.Append("<section class='panel finops-panel'><h2>Reserved Instance Cutoff Planning <span class='tag tag-preview'>Public Preview</span></h2>")
        [void]$riBuilder.Append("<p class='meta'>FinOps sidecar: new purchase and renewal of Reserved VM Instances stops on $(ConvertTo-HtmlText $riCutoffDate) for selected legacy VM families. This is not a VM shutdown signal, is excluded from retirement counts, waves and backlog, and does not prove that this tenant has active RI purchases.</p>")
        [void]$riBuilder.Append("<div class='kpis preview-kpis'><div class='kpi'><div class='kpi-label'>Compute resources scanned</div><div class='kpi-value'>$(ConvertTo-HtmlText $riCutoffScanned)</div></div><div class='kpi'><div class='kpi-label'>Resources in cutoff families</div><div class='kpi-value'>$(ConvertTo-HtmlText $riCutoffRows.Count)</div></div></div>")
        if ($riCutoffRows.Count -gt 0) {
            [void]$riBuilder.Append("<div class='table-wrap'><table><thead><tr><th>VM family</th><th>Resources in scope</th><th>VM sizes seen</th><th>RI purchase/renewal cutoff</th><th>VM retirement signal</th><th>Action</th></tr></thead><tbody>")
            foreach ($familyGroup in @($riCutoffRows | Group-Object -Property Family | Sort-Object -Property Name)) {
                $familyRows = @($familyGroup.Group)
                $resourceTypes = @($familyRows | Where-Object { $_.PSObject.Properties.Match('ResourceType').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$_.ResourceType) } | ForEach-Object { [string]$_.ResourceType } | Select-Object -Unique | Sort-Object)
                $typeSummaryParts = New-Object 'System.Collections.Generic.List[string]'
                foreach ($resourceType in $resourceTypes) {
                    $typeCount = @($familyRows | Where-Object { [string]$_.ResourceType -eq $resourceType }).Count
                    $typeSummaryParts.Add(('{0}: {1}' -f (ConvertTo-HtmlText $resourceType), $typeCount)) | Out-Null
                }
                $typeSummary = if ($typeSummaryParts.Count -gt 0) { $typeSummaryParts -join '<br/>' } else { 'N/A' }
                $sizesSeen = @($familyRows | Where-Object { $_.PSObject.Properties.Match('CurrentSku').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$_.CurrentSku) } | ForEach-Object { [string]$_.CurrentSku } | Select-Object -Unique | Sort-Object)
                $sizesText = if ($sizesSeen.Count -gt 0) { $sizesSeen -join ', ' } else { 'N/A' }
                $cutoffDates = @($familyRows | Where-Object { $_.PSObject.Properties.Match('CutoffDate').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$_.CutoffDate) } | ForEach-Object { [string]$_.CutoffDate } | Select-Object -Unique | Sort-Object)
                $cutoffText = if ($cutoffDates.Count -gt 0) { $cutoffDates -join ', ' } else { $riCutoffDate }
                $retirementDates = @($familyRows | Where-Object { $_.PSObject.Properties.Match('RetirementDate').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$_.RetirementDate) -and [string]$_.RetirementDate -ne 'N/A' } | ForEach-Object { [string]$_.RetirementDate } | Select-Object -Unique | Sort-Object)
                $retirementText = if ($retirementDates.Count -gt 0) { $retirementDates -join ', ' } else { 'No VM-size retirement signal from this cutoff alone' }
                $familyName = if ([string]::IsNullOrWhiteSpace([string]$familyGroup.Name)) { 'N/A' } else { [string]$familyGroup.Name }
                [void]$riBuilder.Append("<tr><td><strong>$(ConvertTo-HtmlText $familyName)</strong></td><td><strong>$(ConvertTo-HtmlText $familyRows.Count)</strong><br/><span class='meta'>$typeSummary</span></td><td>$(ConvertTo-HtmlText $sizesText)</td><td><span class='tag tag-advisor'>$(ConvertTo-HtmlText $cutoffText)</span><br/><span class='meta'>Planning signal only; actual RI inventory is not queried</span></td><td>$(ConvertTo-HtmlText $retirementText)</td><td>FinOps planning: this family summary does not prove an active RI exists. Use Excel/JSON for the resource list only if a reservation review is needed.</td></tr>")
            }
            [void]$riBuilder.Append('</tbody></table></div>')
        }
        else {
            [void]$riBuilder.Append('<p class="meta">No scanned compute resource matched the current Reserved VM Instance cutoff family list.</p>')
        }
        [void]$riBuilder.Append('</section>')
        $riCutoffPreviewHtml = $riBuilder.ToString()
    }

    $html = @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Azure SKU Modernization Report</title>
<style>
* { box-sizing: border-box; }
body { font-family: Segoe UI, Arial, sans-serif; color: #1f2937; margin: 0; background: linear-gradient(180deg, #f8fafc 0%, #ffffff 220px); overflow-x: hidden; }
main { width: 100%; margin: 0; padding: 24px 20px 30px; }
h1 { font-size: 28px; margin: 0 0 4px; }
h2 { font-size: 18px; margin: 18px 0 10px; }
p { line-height: 1.45; margin: 0; }
a { text-decoration: none; color: #464feb; }
.meta { color: #6b7280; font-size: 12px; }
.statusbar { margin: 14px 0 16px; border: 1px solid #dbe4ff; background: #eef2ff; color: #1e3a8a; border-radius: 10px; padding: 10px 12px; font-weight: 600; font-size: 13px; }
.kpis { display: grid; grid-template-columns: repeat(auto-fit, minmax(170px, 1fr)); gap: 12px; margin: 14px 0 16px; }
.kpi { border: 1px solid #e6e6e6; padding: 14px; border-radius: 10px; background: #ffffff; box-shadow: 0 1px 0 rgba(15,23,42,0.04); }
.kpi-label { color: #6b7280; font-size: 12px; }
.kpi-value { font-size: 24px; font-weight: 700; margin-top: 4px; }
.timeline { display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); gap: 8px; margin: 10px 0 14px; }
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
.tag-preview { background: #dcfce7; color: #166534; vertical-align: middle; }
.note { background: #f8fafc; border-left: 4px solid #64748b; padding: 12px 14px; margin: 12px 0; }
.disclaimer { background: #fff7ed; border-left: 4px solid #ea580c; padding: 12px 14px; margin: 16px 0; font-size: 13px; }
.coverage { background: #f0f9ff; border-left: 4px solid #0284c7; padding: 12px 16px; margin: 16px 0; font-size: 13px; }
.coverage ul { margin: 8px 0 0; padding-left: 20px; }
.accordion { border: 1px solid #e6e6e6; border-radius: 10px; background: #ffffff; margin: 12px 0; overflow: hidden; }
.accordion > summary { cursor: pointer; list-style: none; padding: 12px 14px; font-weight: 700; background: #f8fafc; }
.accordion > summary::-webkit-details-marker { display: none; }
.accordion-body { padding: 12px 14px 14px; }
.footer { color: #6b7280; font-size: 12px; margin-top: 32px; border-top: 1px solid #e6e6e6; padding-top: 16px; }
table { width: 100%; min-width: 900px; border-collapse: collapse; font-size: 12px; }
tr th, tr td { border: 1px solid #e6e6e6; vertical-align: top; }
tr th { background-color: #f5f5f5; text-align: left; padding: 8px; }
td { padding: 8px; }
ul { margin-top: 8px; }
.layout { display: grid; grid-template-columns: 240px minmax(0, 1fr); min-height: 100vh; }
.sidebar { position: fixed; inset: 0 auto 0 0; width: 240px; overflow: auto; background: #0f172a; color: #f8fafc; padding: 24px 20px; }
.sidebar h1 { font-size: 21px; line-height: 1.15; margin-bottom: 14px; }
.sidebar .side-muted, .sidebar .side-item span { color: #cbd5e1; }
.sidebar .side-item { border-top: 1px solid rgba(255,255,255,0.12); padding: 12px 0; font-size: 12px; }
.sidebar .side-item strong { display: block; color: #ffffff; font-size: 15px; margin-top: 3px; }
.freshness-badge { display: inline-flex; align-items: center; gap: 6px; border-radius: 999px; padding: 5px 9px; font-weight: 800; font-size: 11px; margin-top: 8px; }
.freshness-ok { background: #dcfce7; color: #166534; }
.freshness-warn { background: #fef3c7; color: #92400e; }
.section-toggle { position: absolute; opacity: 0; pointer-events: none; }
.report-nav { display: grid; gap: 7px; margin: 16px 0 14px; }
.report-nav label { display: grid; grid-template-columns: 1fr auto; gap: 8px; align-items: center; border: 1px solid rgba(255,255,255,0.14); border-radius: 10px; padding: 9px 10px; color: #cbd5e1; background: rgba(255,255,255,0.04); cursor: pointer; font-size: 12px; font-weight: 800; }
.report-nav label span { color: #94a3b8; font-size: 10px; font-weight: 900; letter-spacing: .06em; text-transform: uppercase; }
.report-nav label:hover { background: rgba(255,255,255,0.09); color: #ffffff; }
#view-overview:checked ~ .layout label[for='view-overview'],
#view-engineer:checked ~ .layout label[for='view-engineer'],
#view-project:checked ~ .layout label[for='view-project'],
#view-finops:checked ~ .layout label[for='view-finops'],
#view-coverage:checked ~ .layout label[for='view-coverage'] { background: #eff6ff; border-color: #93c5fd; color: #1e3a8a; }
#view-overview:checked ~ .layout label[for='view-overview'] span,
#view-engineer:checked ~ .layout label[for='view-engineer'] span,
#view-project:checked ~ .layout label[for='view-project'] span,
#view-finops:checked ~ .layout label[for='view-finops'] span,
#view-coverage:checked ~ .layout label[for='view-coverage'] span { color: #2563eb; }
.tab-panel { display: none; }
#view-overview:checked ~ .layout .tab-overview,
#view-engineer:checked ~ .layout .tab-engineer,
#view-project:checked ~ .layout .tab-project,
#view-finops:checked ~ .layout .tab-finops,
#view-coverage:checked ~ .layout .tab-coverage { display: block; }
.tab-heading { margin: 0 0 14px; }
.tab-heading h2 { margin: 0 0 4px; font-size: 22px; }
.tab-heading p { color: #475569; font-size: 13px; }
.dashboard { margin-left: 240px; width: calc(100vw - 240px); padding: 22px clamp(16px, 2vw, 34px) 34px; max-width: none; }
.exec-band { background: #ffffff; border: 1px solid #e2e8f0; border-radius: 12px; padding: 18px; box-shadow: 0 10px 24px rgba(15,23,42,0.06); }
.exec-grid { display: grid; grid-template-columns: minmax(360px, 1fr) minmax(320px, 420px); gap: 16px; align-items: start; }
.exec-grid .kpis { grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); margin: 0; }
.monitoring-panel .kpis { grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); margin: 10px 0; }
.exec-narrative { color: #334155; font-size: 15px; line-height: 1.5; margin: 8px 0 12px; }
.exec-bullets { margin: 10px 0 0; padding-left: 18px; color: #334155; }
.exec-bullets li { margin: 4px 0; }
.info-strip { display: grid; grid-template-columns: repeat(auto-fit, minmax(210px, 1fr)); gap: 10px; margin: 14px 0; }
.info-card { border: 1px solid #e2e8f0; border-radius: 10px; background: #f8fafc; padding: 12px; }
.info-label { color: #64748b; font-size: 11px; font-weight: 800; text-transform: uppercase; letter-spacing: .04em; }
.info-value { font-size: 16px; font-weight: 800; margin-top: 5px; color: #0f172a; }
.story-band { border: 1px solid #dbe4ff; border-radius: 14px; background: linear-gradient(135deg, #eef4ff 0%, #f8fafc 65%, #fff1f2 100%); padding: 18px; margin: 10px 0 16px; }
.story-kicker { font-size: 11px; font-weight: 900; letter-spacing: .09em; text-transform: uppercase; color: #334155; }
.story-title { font-size: 24px; line-height: 1.15; margin: 6px 0 8px; color: #0f172a; }
.story-subtitle { color: #334155; font-size: 14px; margin-bottom: 10px; }
.story-status { display: inline-flex; border: 1px solid #bfdbfe; border-radius: 999px; padding: 5px 10px; background: #eff6ff; color: #1e3a8a; font-weight: 800; font-size: 12px; }
.decision-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(190px, 1fr)); gap: 10px; margin-top: 14px; }
.decision-card { border-radius: 12px; border: 1px solid #e2e8f0; background: #ffffff; padding: 12px; }
.decision-tag { font-size: 10px; font-weight: 900; text-transform: uppercase; letter-spacing: .07em; color: #64748b; }
.decision-value { font-size: 28px; font-weight: 900; margin-top: 5px; color: #0f172a; }
.decision-title { font-size: 14px; font-weight: 800; color: #1e293b; margin-top: 4px; }
.decision-note { font-size: 12px; color: #334155; margin-top: 6px; }
.decision-equation { margin: 10px 0 0; padding: 8px 10px; border-left: 3px solid #60a5fa; background: rgba(255,255,255,.72); color: #334155; font-size: 12px; line-height: 1.45; }
.matrix-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(260px, 1fr)); gap: 10px; }
.matrix-cell { border-radius: 10px; border: 1px solid #e2e8f0; background: #ffffff; padding: 12px; }
.matrix-axis { font-size: 10px; font-weight: 900; text-transform: uppercase; letter-spacing: .08em; color: #64748b; }
.matrix-head { display: flex; justify-content: space-between; align-items: baseline; gap: 8px; margin-top: 5px; }
.matrix-title { font-size: 14px; font-weight: 800; color: #0f172a; }
.matrix-count { font-size: 20px; font-weight: 900; }
.matrix-note { color: #334155; font-size: 12px; margin-top: 7px; }
.cell-high-low { border-left: 5px solid #dc2626; }
.cell-high-high { border-left: 5px solid #ea580c; }
.cell-low-high { border-left: 5px solid #2563eb; }
.cell-low-low { border-left: 5px solid #16a34a; }
.scenario-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 10px; }
.scenario-card { border: 1px solid #e2e8f0; border-radius: 10px; padding: 12px; background: #ffffff; }
.scenario-card h3 { margin: 0; font-size: 14px; }
.scenario-count { font-size: 22px; font-weight: 900; margin-top: 6px; color: #0f172a; }
.scenario-card p { margin-top: 6px; font-size: 12px; color: #334155; }
.countdown-list { margin: 10px 0 0; padding-left: 18px; display: grid; gap: 8px; }
.countdown-list li { display: grid; gap: 3px; }
.deadline-date { display: inline-block; width: fit-content; border-radius: 999px; padding: 2px 8px; background: #fee2e2; color: #991b1b; font-size: 11px; font-weight: 800; }
.confidence-line { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 8px; }
.confidence-chip { border-radius: 999px; border: 1px solid #cbd5e1; padding: 3px 8px; font-size: 11px; font-weight: 800; color: #334155; background: #ffffff; }
.legend-body { padding: 14px; display: grid; gap: 12px; }
.legend-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 12px; }
.legend-box { border: 1px solid #e2e8f0; border-radius: 10px; padding: 12px; background: #ffffff; }
.legend-box h3 { margin: 0 0 7px; font-size: 13px; color: #0f172a; }
.legend-box dl { margin: 0; display: grid; gap: 7px; }
.legend-box dt { font-weight: 900; font-size: 12px; color: #1e293b; }
.legend-box dd { margin: 2px 0 0; color: #475569; font-size: 12px; line-height: 1.35; }
.legend-inline { display: flex; flex-wrap: wrap; gap: 6px; }
.legend-inline span { border-radius: 999px; border: 1px solid #cbd5e1; padding: 3px 8px; font-size: 11px; font-weight: 800; background: #f8fafc; color: #334155; }
.info-dot { display: inline-flex; align-items: center; justify-content: center; width: 17px; height: 17px; margin-left: 6px; border-radius: 999px; border: 1px solid #93c5fd; background: #eff6ff; color: #1d4ed8; font-size: 11px; font-weight: 900; vertical-align: middle; cursor: help; }
.info-dot:hover { background: #dbeafe; border-color: #60a5fa; }
.help-toggle { position: absolute; opacity: 0; pointer-events: none; }
.help-tab { width: fit-content; margin-top: 14px; border-radius: 999px; background: #1d4ed8; color: #ffffff; display: inline-flex; align-items: center; justify-content: center; gap: 7px; padding: 7px 12px; font-size: 12px; font-weight: 900; letter-spacing: .02em; box-shadow: 0 10px 20px rgba(15,23,42,0.22); cursor: pointer; border: 2px solid rgba(255,255,255,0.82); }
.help-tab:before { content: 'i'; display: inline-flex; align-items: center; justify-content: center; width: 17px; height: 17px; border-radius: 999px; background: #eff6ff; color: #1d4ed8; font-size: 11px; font-weight: 900; }
.help-tab:hover { background: #1e40af; }
.help-overlay { display: none; position: fixed; inset: 0; z-index: 120; background: rgba(15,23,42,0.52); padding: 34px; overflow: auto; }
.help-toggle:checked ~ .help-overlay { display: block; }
.help-layer { max-width: 1040px; margin: 0 auto; background: #ffffff; border-radius: 14px; border: 1px solid #dbe4ff; box-shadow: 0 24px 60px rgba(15,23,42,0.28); overflow: hidden; }
.help-layer-head { display: flex; align-items: center; justify-content: space-between; gap: 16px; padding: 16px 18px; background: #f8fafc; border-bottom: 1px solid #e2e8f0; }
.help-layer-head h2 { margin: 0; }
.help-close { display: inline-flex; align-items: center; justify-content: center; min-width: 34px; height: 34px; border-radius: 999px; border: 1px solid #cbd5e1; background: #ffffff; color: #0f172a; cursor: pointer; font-weight: 900; }
.help-close:hover { background: #eff6ff; border-color: #93c5fd; }
.help-layer-body { padding: 16px; }
.content-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(min(100%, 380px), 1fr)); gap: 18px; align-items: start; margin-top: 18px; }
.panel { border: 1px solid #e2e8f0; border-radius: 12px; background: #ffffff; padding: 16px; box-shadow: 0 1px 0 rgba(15,23,42,0.04); }
.preview-panel { border-left: 6px solid #16a34a; background: #fbfffc; }
.finops-panel { border-left: 6px solid #0ea5e9; background: #f0f9ff; }
.release-panel { border-left: 6px solid #6366f1; background: #f8faff; }
.preview-kpis { grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); max-width: none; }
.monitoring-panel { border-left: 6px solid #475569; background: #f8fafc; }
.monitoring-panel h2 { margin-top: 0; }
.outside-count { display: inline-block; border: 1px solid #cbd5e1; background: #ffffff; color: #334155; border-radius: 999px; padding: 4px 9px; font-size: 11px; font-weight: 800; margin: 6px 0 10px; }
.timeline { display: grid; grid-template-columns: repeat(auto-fit, minmax(155px, 1fr)); gap: 10px; margin: 10px 0 14px; }
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
.swatch-grey { background: #6b7280; }
.money-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 8px; }
.money-cell { border: 1px solid #e2e8f0; border-radius: 9px; padding: 10px; background: #ffffff; }
.money-label { color: #64748b; font-size: 11px; font-weight: 800; }
.money-value { font-weight: 900; margin-top: 4px; }
.table-wrap { width: 100%; overflow-x: auto; -webkit-overflow-scrolling: touch; }
.table-wrap table { min-width: 920px; }
.monitor-table { margin-top: 10px; }
@media print { body { background: #ffffff; } .help-tab, .help-overlay, .help-toggle, .section-toggle, .report-nav { display: none !important; } .tab-panel { display: block !important; } .layout { display: block; } .sidebar { position: static; width: auto; color: #0f172a; background: #ffffff; border-bottom: 1px solid #cbd5e1; } .sidebar .side-muted, .sidebar .side-item span { color: #334155; } .sidebar .side-item strong { color: #0f172a; } .dashboard { margin-left: 0; padding: 12px 0; max-width: none; } .exec-grid, .content-grid, .info-strip, .kpis, .timeline, .money-grid, .decision-grid, .matrix-grid, .scenario-grid, .legend-grid { display: block; } .panel, .exec-band, .timeline-card, .kpi, .info-card, .story-band, .tab-panel { break-inside: avoid; box-shadow: none; margin: 8px 0; } details, details:not([open]) > * { display: block !important; } summary { display: block; } }
@media (max-width: 1120px) { .exec-grid { grid-template-columns: 1fr; } }
@media (max-width: 920px) { .sidebar { width: 220px; } .dashboard { margin-left: 220px; width: calc(100vw - 220px); } }
@media (max-width: 760px) { body { overflow-x: auto; } .layout { display: block; } .sidebar { position: static; width: auto; } .report-nav { grid-template-columns: 1fr 1fr; } .dashboard { margin-left: 0; width: 100%; padding: 14px; } .help-overlay { padding: 14px; } .exec-grid, .content-grid, .info-strip, .decision-grid, .matrix-grid, .scenario-grid, .legend-grid { grid-template-columns: 1fr; } .kpis { grid-template-columns: 1fr; } .timeline { grid-template-columns: 1fr; } .wave-item-top { flex-direction: column; align-items: flex-start; } .story-title { font-size: 20px; } table { font-size: 11px; } }
</style>
</head>
<body>
<input class="section-toggle" type="radio" name="report-view" id="view-overview" checked />
<input class="section-toggle" type="radio" name="report-view" id="view-engineer" />
<input class="section-toggle" type="radio" name="report-view" id="view-project" />
<input class="section-toggle" type="radio" name="report-view" id="view-finops" />
<input class="section-toggle" type="radio" name="report-view" id="view-coverage" />
<input class="help-toggle" type="checkbox" id="report-help-toggle" />
<div class="help-overlay">
<div class="help-layer" role="dialog" aria-modal="true" aria-labelledby="report-help-title">
<div class="help-layer-head"><h2 id="report-help-title">Report guide - concepts, fields and sections</h2><label class="help-close" for="report-help-toggle" title="Close report guide" aria-label="Close report guide">X</label></div>
<div class="help-layer-body">
<div class="legend-body">
<div class="legend-grid">
<section class="legend-box">
<h3>Core concepts</h3>
<dl>
<div><dt>Compute retirement path</dt><dd>Standalone VMs plus Public Preview Batch/VMSS sidecars whose VM size has a retirement signal. Remediation waves still cover standalone VMs only.</dd></div>
<div><dt>Advisor-confirmed</dt><dd>Per-resource Advisor signal. It is stronger than a generic family exposure because Azure identified the specific VM.</dd></div>
<div><dt>SKU-family exposure</dt><dd>The current VM size belongs to a retiring SKU family from Microsoft Learn, even when Advisor did not emit a per-resource row.</dd></div>
<div><dt>Monitoring lifecycle</dt><dd>Dependency Agent / VM Insights Map lifecycle findings. These are intentionally separate and never counted as compute SKU retirements.</dd></div>
</dl>
</section>
<section class="legend-box">
<h3>Wave model</h3>
<dl>
<div><dt>W0 Time-critical</dt><dd>Retirement risk is Critical. Calendar pressure wins over all other sequencing rules.</dd></div>
<div><dt>W1 High urgency / governed validation</dt><dd>Retirement risk is High. Advisor and sensitive reason codes are shown on the individual workload badge only when those facts are present.</dd></div>
<div><dt>W2 Sensitive validation</dt><dd>Sensitive workload with same-generation resize. Lower technical change, but still validate workload behavior.</dd></div>
<div><dt>W3 Architecture</dt><dd>Cross-family Gen1&rarr;Gen2 path. Validate image, drivers, boot/runtime assumptions, capacity and performance profile.</dd></div>
<div><dt>W4 Low complexity</dt><dd>Standard same-generation resize lane. Best candidate for runbook-driven batch remediation.</dd></div>
</dl>
</section>
<section class="legend-box">
<h3>Decision sections</h3>
<dl>
<div><dt>Decision Room</dt><dd>Management view: what to act on now, what needs validation, and what can move as quick wins. The 90-day label is a planning frame, not a Microsoft retirement deadline or a promise that every migration completes in 90 days.</dd></div>
<div><dt>Risk vs Effort Matrix</dt><dd>Translates waves into execution lanes so risk and engineering effort are visible at a glance.</dd></div>
<div><dt>Execution Scenarios</dt><dd>Conservative, balanced and accelerated views over the same facts. They do not change counts or recommendations.</dd></div>
<div><dt>If We Do Nothing</dt><dd>Earliest dated retirement rows, useful as the escalation queue for planning.</dd></div>
</dl>
</section>
<section class="legend-box">
<h3>How Decision Room numbers reconcile</h3>
<dl>
<div><dt>Retirement path fraction</dt><dd>The numerator is impacted Compute resources; the denominator is all scanned standalone VMs, VMSS and Batch pools. Monitoring rows are excluded from both.</dd></div>
<div><dt>Standalone VM lanes</dt><dd>This sprint (W0) + Next wave (W1-W3) + Quick wins (W4) equals the standalone VM retirement-path count. Every standalone VM belongs to exactly one wave.</dd></div>
<div><dt>Compute total</dt><dd>Standalone retirement-path VMs + impacted VMSS + impacted Batch pools. Preview sidecars are included here but stay outside standalone VM waves.</dd></div>
<div><dt>RI cutoff and monitoring</dt><dd>Independent, potentially overlapping populations. They are not added to the Compute total: RI cutoff is a commercial planning signal, while monitoring is a separate feature lifecycle.</dd></div>
<div><dt>Advisor-confirmed share</dt><dd>Advisor-confirmed standalone retirement-path VMs divided by all standalone retirement-path VMs. A low value does not invalidate official Learn or Release Communications family evidence.</dd></div>
</dl>
</section>
<section class="legend-box">
<h3>Detail table fields</h3>
<dl>
<div><dt>Recommended SKU</dt><dd>Deterministic candidate target selected by the script; validate compatibility, quota, capacity and business constraints before change.</dd></div>
<div><dt>Retail cost delta / month</dt><dd>PAYG/list-price estimate only. It excludes real negotiated pricing, RI/Savings Plan effects and workload-specific commercial adjustments.</dd></div>
<div><dt>Validation</dt><dd>Checks and caveats that should be reviewed before migration, including generation change, sensitive workload and RI/SP flags.</dd></div>
<div><dt>Next step</dt><dd>Suggested operational action for the row. It is guidance, not an approval to migrate.</dd></div>
</dl>
</section>
</div>
<div class="legend-inline"><span>Data is deterministic</span><span>No AI-generated numbers</span><span>Live-source provenance shown in sidebar</span><span>Costs are indicative only</span><span>Validate in Advisor, Service Health and Retirement Workbook</span></div>
</div>
</div>
</div>
</div>
<div class="layout">
<aside class="sidebar">
<h1>Azure SKU Modernization Report</h1>
<p class="side-muted">Not an official Microsoft tool. Validate all signals in Azure Advisor, Service Health and the Azure Retirement Workbook before migration decisions.</p>
<div class="freshness-badge $(if ($liveSourcesOk) { 'freshness-ok' } else { 'freshness-warn' })">Data Freshness: $(ConvertTo-HtmlText $freshnessText) &middot; Live sources $(ConvertTo-HtmlText $liveSourcesText) &middot; As-of $(ConvertTo-HtmlText $asOfText)</div>
<nav class="report-nav" aria-label="Report sections">
<label for="view-overview">Executive Overview <span>CXO</span></label>
<label for="view-engineer">CSA / Engineer <span>Detail</span></label>
<label for="view-project">Project Plan <span>PM</span></label>
<label for="view-finops">FinOps <span>Cost</span></label>
<label for="view-coverage">Coverage <span>Evidence</span></label>
</nav>
<div class="side-item"><span>Generated (UTC)</span><strong>$(ConvertTo-HtmlText $generatedUtc)</strong></div>
<div class="side-item"><span>Script version</span><strong>v$(ConvertTo-HtmlText $reportVersion)</strong></div>
<div class="side-item"><span>Live sources</span><strong>$(ConvertTo-HtmlText $liveSources)</strong></div>
<div class="side-item"><span>Release Communications API</span><strong>$(ConvertTo-HtmlText $releaseCommunicationStatusText)</strong></div>
<div class="side-item"><span>Tenants / subscriptions</span><strong>$(ConvertTo-HtmlText $tenantCount) / $(ConvertTo-HtmlText $subscriptionCount)</strong></div>
<div class="side-item"><span>As-of</span><strong>$(ConvertTo-HtmlText $asOfText)</strong></div>
<label class="help-tab" for="report-help-toggle" title="Open report guide" aria-label="Open report guide">Legend</label>
</aside>
<main class="dashboard">
<div class="tab-panel tab-overview">
<section class="exec-band">
<div class="exec-grid">
<div>
<h2>Executive Summary<span class="info-dot" title="Fact-derived overview of retirement exposure, source split, generation split and retail delta.">i</span></h2>
$(if (-not [string]::IsNullOrWhiteSpace($ExecutiveNarrativeText)) { "<p class='exec-narrative'>$(ConvertTo-HtmlText $ExecutiveNarrativeText)</p>" } else { '' })
<ul class="exec-bullets">
<li><strong>Compute retirement path:</strong> $(ConvertTo-HtmlText $computeRetirementCount) resource(s) = $(ConvertTo-HtmlText $Facts.RetireCount) standalone VM(s) + $(ConvertTo-HtmlText $vmssPreviewRows.Count) VMSS + $(ConvertTo-HtmlText $batchPreviewRows.Count) Batch pool(s).</li>
<li><strong>Standalone VM source split:</strong> $(ConvertTo-HtmlText $Facts.AdvisorConfirmed) Advisor-confirmed + $(ConvertTo-HtmlText $Facts.SkuFamily) SKU-family exposure; VM remediation waves cover these $(ConvertTo-HtmlText $Facts.RetireCount) VM(s).</li>
<li><strong>Retail delta/month:</strong> $(ConvertTo-HtmlText $costImpact). PAYG/list-price signal only; not a validated saving.</li>
<li><strong>Generation split:</strong> $(ConvertTo-HtmlText $noGenChangeCount) same-generation resize(s) &middot; $(ConvertTo-HtmlText $genChangeCount) Gen1&rarr;Gen2 change(s).</li>
<li><strong>RI cutoff planning:</strong> $(ConvertTo-HtmlText $riCutoffRows.Count) resource(s) in affected families; actual RI inventory is not queried and this is not a shutdown signal.</li>
<li><strong>Monitoring lifecycle:</strong> $(ConvertTo-HtmlText $Facts.MonitoringDistinctVmCount) VM(s) tracked separately, outside compute retirement count.</li>
</ul>
</div>
<div class="kpis">
<div class="kpi"><div class="kpi-label">Compute retirement path<span class="info-dot" title="Standalone VM retirement path plus Public Preview VMSS and Batch sidecar rows. Monitoring lifecycle rows are excluded.">i</span></div><div class="kpi-value">$(ConvertTo-HtmlText $computeRetirementCount)</div></div>
<div class="kpi"><div class="kpi-label">Standalone VMs<span class="info-dot" title="VMs that drive the main detail table, remediation waves and CSV/backlog outputs.">i</span></div><div class="kpi-value">$(ConvertTo-HtmlText $Facts.RetireCount)</div></div>
<div class="kpi"><div class="kpi-label">VMSS / Batch preview<span class="info-dot" title="Public Preview sidecar resources on a VM-size retirement path; not included in VM remediation waves.">i</span></div><div class="kpi-value">$(ConvertTo-HtmlText $vmssPreviewRows.Count) / $(ConvertTo-HtmlText $batchPreviewRows.Count)</div></div>
<div class="kpi"><div class="kpi-label">Retail delta / month<span class="info-dot" title="PAYG/list-price estimate only; not negotiated price, RI/SP impact or validated saving.">i</span></div><div class="kpi-value">$(ConvertTo-HtmlText $costImpact)</div></div>
</div>
</div>
</section>

<section class="info-strip">
<div class="info-card"><div class="info-label">Nearest retirement deadline</div><div class="info-value">$(ConvertTo-HtmlText $deadlineText)</div><div class="meta">$(if ($deadlineVm) { "VM: $(ConvertTo-HtmlText $deadlineVm)" } else { 'No dated retirement row' })</div></div>
<div class="info-card"><div class="info-label">SKU change vs generation change</div><div class="info-value">$(ConvertTo-HtmlText $noGenChangeCount) same-gen &middot; $(ConvertTo-HtmlText $genChangeCount) Gen1&rarr;Gen2</div><div class="meta">Counts read from report facts.</div></div>
<div class="info-card"><div class="info-label">RI / Savings Plan retirement flag</div><div class="info-value">$(ConvertTo-HtmlText $commitmentImpactCount) flagged</div><div class="meta">SKU offer signal only; not actual tenant commitment inventory.</div></div>
<div class="info-card"><div class="info-label">RI cutoff planning</div><div class="info-value">$(ConvertTo-HtmlText $riCutoffRows.Count) in cutoff families</div><div class="meta">No active RI is inferred; verify reservations separately.</div></div>
</section>

<section class="story-band">
<div class="story-kicker">Decision Room<span class="info-dot" title="Management view that groups deterministic standalone-VM waves into immediate action, validation and quick-win lanes; VMSS and Batch remain separate sidecars.">i</span></div>
<div class="story-title">90-day modernization playbook<span class="info-dot" title="Planning horizon only. It is not a Microsoft retirement deadline and does not imply that every migration can complete in 90 days.">i</span></div>
<p class="story-subtitle">Use the deterministic wave output to sequence work. The first three cards partition standalone VMs; add Preview sidecars only when reading the total Compute exposure.</p>
<span class="story-status" title="Impacted Compute resources divided by all scanned standalone VMs, VMSS and Batch pools. Monitoring is excluded.">$(ConvertTo-HtmlText $statusLine)</span>
<p class="decision-equation"><strong>Reconcile the counts:</strong> W0 $(ConvertTo-HtmlText $actNowCount) + W1-W3 $(ConvertTo-HtmlText $planNowCount) + W4 $(ConvertTo-HtmlText $quickWinCount) = $(ConvertTo-HtmlText $Facts.RetireCount) standalone VM(s). Then add $(ConvertTo-HtmlText $sidecarRetirementCount) impacted VMSS/Batch sidecar(s) = $(ConvertTo-HtmlText $computeRetirementCount) Compute resource(s). RI cutoff and monitoring are separate, potentially overlapping signals and are not added.</p>

<div class="decision-grid">
<article class="decision-card">
<div class="decision-tag">This sprint<span class="info-dot" title="Count of standalone retirement-path VMs assigned to W0 because retirement risk is Critical.">i</span></div>
<div class="decision-value">$(ConvertTo-HtmlText $actNowCount)</div>
<div class="decision-title">Act now (W0)</div>
<div class="decision-note">Critical retirement deadlines that should be prioritized in the current sprint.</div>
</article>
<article class="decision-card">
<div class="decision-tag">Next wave<span class="info-dot" title="Count of standalone retirement-path VMs assigned to W1, W2 or W3. This combines urgency, sensitivity and architecture-validation lanes.">i</span></div>
<div class="decision-value">$(ConvertTo-HtmlText $planNowCount)</div>
<div class="decision-title">Plan with validation (W1 + W2 + W3)</div>
<div class="decision-note">High urgency or higher-effort workloads that need planning and validation before cutover; Advisor/sensitive facts are shown per workload.</div>
</article>
<article class="decision-card">
<div class="decision-tag">Quick wins<span class="info-dot" title="Count of standalone retirement-path VMs assigned to W4. Low complexity still requires compatibility, quota, capacity and change validation.">i</span></div>
<div class="decision-value">$(ConvertTo-HtmlText $quickWinCount)</div>
<div class="decision-title">Low-complexity moves (W4)</div>
<div class="decision-note">Candidate moves for accelerated execution batches, often suitable for standard runbooks.</div>
</article>
<article class="decision-card">
<div class="decision-tag">Preview sidecars<span class="info-dot" title="Impacted VM Scale Sets plus Batch pools. Included in Compute total, excluded from standalone VM waves and backlog.">i</span></div>
<div class="decision-value">$(ConvertTo-HtmlText $sidecarRetirementCount)</div>
<div class="decision-title">VMSS + Batch</div>
<div class="decision-note">Separate detail tables below; keep them visible in planning but outside standalone VM wave counts.</div>
</article>
</div>

<div class="confidence-line">
<span class="confidence-chip" title="Denominator: standalone VMs on the retirement path. Numerator: those with a per-resource Azure Advisor retirement signal.">Advisor-confirmed share: $(ConvertTo-HtmlText $advisorConfidencePercent)% of retirement-path VMs</span>
<span class="confidence-chip" title="All standalone retirement findings reconcile to accepted live source gates. This does not mean every finding is Advisor-confirmed.">Live source status: $(ConvertTo-HtmlText $liveCoverage)</span>
<span class="confidence-chip" title="Impacted Compute resources only. Monitoring lifecycle and RI cutoff planning are excluded.">Compute total: $(ConvertTo-HtmlText $computeRetirementCount) = VM $(ConvertTo-HtmlText $Facts.RetireCount) + VMSS $(ConvertTo-HtmlText $vmssPreviewRows.Count) + Batch $(ConvertTo-HtmlText $batchPreviewRows.Count)</span>
<span class="confidence-chip" title="Independent commercial-planning population derived from the official RI cutoff notice. Resources may overlap the Compute retirement path; actual tenant reservations are not queried.">RI cutoff planning: $(ConvertTo-HtmlText $riCutoffRows.Count) resource(s); actual reservations not queried</span>
<span class="confidence-chip" title="Separate Azure Monitor feature-lifecycle population. The same VM may also appear on the Compute retirement path, so this count is not additive.">Monitoring kept separate: $(ConvertTo-HtmlText $Facts.MonitoringDistinctVmCount) VM(s)</span>
</div>
</section>
</div>

<div class="tab-panel tab-project">
<div class="tab-heading"><h2>Project Plan</h2><p>Delivery-oriented sequencing, risk/effort lanes and deadline pressure for standalone VM remediation waves.</p></div>

<section class="panel">
<h2>Summary by Change Type</h2>
<div class="summary-split"><div class="donut" aria-hidden="true"></div><div class="legend"><div class="legend-row"><span class="legend-key"><span class="swatch swatch-blue"></span>Same-generation resize</span><strong>$(ConvertTo-HtmlText $noGenChangeCount)</strong></div><div class="legend-row"><span class="legend-key"><span class="swatch swatch-red"></span>Gen1&rarr;Gen2</span><strong>$(ConvertTo-HtmlText $genChangeCount)</strong></div>$(if ($withheldChangeCount -gt 0) { "<div class='legend-row'><span class='legend-key'><span class='swatch swatch-grey'></span>Unclassified (no catalog target)</span><strong>$(ConvertTo-HtmlText $withheldChangeCount)</strong></div>" })</div></div>
</section>

<div class="content-grid">
<section class="panel">
<h2>Risk vs Effort Matrix<span class="info-dot" title="Maps waves into execution lanes using existing wave counts; it does not recompute or reclassify rows.">i</span></h2>
<div class="matrix-grid">
<article class="matrix-cell cell-high-low">
<div class="matrix-axis">High risk · Lower effort</div>
<div class="matrix-head"><span class="matrix-title">Immediate execution lane</span><span class="matrix-count">$(ConvertTo-HtmlText $w0Count)</span></div>
<p class="matrix-note">W0 workloads: retirement timeline risk dominates, so execution urgency is highest.</p>
</article>
<article class="matrix-cell cell-high-high">
<div class="matrix-axis">High risk · Higher effort</div>
<div class="matrix-head"><span class="matrix-title">Governed execution lane</span><span class="matrix-count">$(ConvertTo-HtmlText ($w1Count + $w3Count))</span></div>
<p class="matrix-note">W1 and W3 workloads: sensitive or cross-family Gen1&rarr;Gen2 changes requiring stronger governance and validation.</p>
</article>
<article class="matrix-cell cell-low-high">
<div class="matrix-axis">Lower risk · Higher effort</div>
<div class="matrix-head"><span class="matrix-title">Engineering validation lane</span><span class="matrix-count">$(ConvertTo-HtmlText $w2Count)</span></div>
<p class="matrix-note">W2 workloads: sensitive but same-generation; schedule non-production validation before scale rollout.</p>
</article>
<article class="matrix-cell cell-low-low">
<div class="matrix-axis">Lower risk · Lower effort</div>
<div class="matrix-head"><span class="matrix-title">Quick-win lane</span><span class="matrix-count">$(ConvertTo-HtmlText $w4Count)</span></div>
<p class="matrix-note">W4 workloads: standard, low-complexity moves suitable for bulk remediation windows.</p>
</article>
</div>
</section>

<section class="panel">
<h2>Execution Scenarios<span class="info-dot" title="Alternative rollout views over the same facts: conservative, balanced and accelerated.">i</span></h2>
<div class="scenario-grid">
<article class="scenario-card">
<h3>Conservative</h3>
<div class="scenario-count">$(ConvertTo-HtmlText $actNowCount)</div>
<p>Focus only on W0 to address critical retirement deadlines first.</p>
</article>
<article class="scenario-card">
<h3>Balanced</h3>
<div class="scenario-count">$(ConvertTo-HtmlText ($actNowCount + $w1Count + $w2Count))</div>
<p>Execute W0 and prepare W1 + W2 in parallel while keeping architecture-heavy W3 work governed separately.</p>
</article>
<article class="scenario-card">
<h3>Accelerated</h3>
<div class="scenario-count">$(ConvertTo-HtmlText $Facts.RetireCount)</div>
<p>Run all waves with strict readiness gates and dedicated architecture validation for W3.</p>
</article>
</div>
</section>
</div>

<section class="panel">
<h2>If We Do Nothing<span class="info-dot" title="Earliest dated retirement rows in scope, useful for escalation and planning.">i</span></h2>
<p class="meta">Top dated retirements in scope; use this list as the minimum escalation queue for operational planning.</p>
$($countdownBuilder.ToString())
</section>

<section class="panel">
<h2>Remediation Plan (waves)</h2>
<div class="timeline">$($timelineBuilder.ToString())</div>
$($waveBuilder.ToString())
</section>
</div>

<div class="tab-panel tab-engineer">
<div class="tab-heading"><h2>CSA / Engineer</h2><p>Implementation detail for standalone VMs plus Public Preview VMSS and Batch sidecars.</p></div>

<section class="panel">
<h2>CSA / Engineer Detail<span class="info-dot" title="Per-VM implementation view: wave, source, OS pricing basis, target SKU, validation caveats and next step.">i</span></h2>
<p class="meta"><strong>Candidate-fit disclaimer:</strong> Recommended SKUs are nearest-fit candidates selected by commercial-family priority, effective vCPU/RAM proximity and validated Retail price; they are not automatically validated 1:1 workload equivalents. Verify family/workload profile, effective vCPU, RAM, temporary/local storage, CPU model and vendor, fixed versus burstable performance, disk and NIC limits, licensing and application behavior before migration.</p>
<div class="table-wrap">
<table>
<thead><tr><th>Wave</th><th>VM</th><th>Current SKU</th><th>OS</th><th>What happens</th><th>Recommended SKU / equivalence</th><th>Validation</th><th>Next step</th></tr></thead>
<tbody>
"@

    $detailRows = @($Facts.Rows | Sort-Object `
            @{ Expression = {
                    $vmName = if ($_.PSObject.Properties.Match('VmName').Count -gt 0) { [string]$_.VmName } else { '' }
                    if ($waveByVm.ContainsKey($vmName)) { [int]$waveByVm[$vmName].Number } else { 99 }
                } },
            @{ Expression = {
                    $dateText = if ($_.PSObject.Properties.Match('RetirementDate').Count -gt 0) { [string]$_.RetirementDate } else { '' }
                    $parsedDate = [datetime]::MaxValue
                    if ([datetime]::TryParse($dateText, [ref]$parsedDate)) { $parsedDate } else { [datetime]::MaxValue }
                } },
            @{ Expression = { if ($_.PSObject.Properties.Match('VmName').Count -gt 0) { [string]$_.VmName } else { '' } } })

    foreach ($row in $detailRows) {
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
        $equivalenceStatus = if ($row.PSObject.Properties.Match('EquivalenceStatus').Count -gt 0 -and $row.EquivalenceStatus) { [string]$row.EquivalenceStatus } else { 'Unknown' }
        $equivalenceLabel = if ($equivalenceStatus -eq 'Equivalent') { 'Equivalent' } elseif ($equivalenceStatus -eq 'NotEquivalent') { 'Not equivalent' } else { $equivalenceStatus }
        $equivalenceClass = if ($equivalenceStatus -eq 'Equivalent') { 'tag-gen' } else { 'tag-osflag' }
        $recommendedCell = "$recommendedCell <span class='tag $equivalenceClass'>$(ConvertTo-HtmlText $equivalenceLabel)</span>"
        $equivalenceDetails = if ($row.PSObject.Properties.Match('EquivalenceDetails').Count -gt 0 -and $row.EquivalenceDetails) { [string]$row.EquivalenceDetails } else { 'Compared-capability details unavailable.' }
        $fitConfidence = if ($equivalenceStatus -eq 'Equivalent') { '100% compared-capability match' } else { 'candidate - verify' }
        $recommendedCell = "$recommendedCell<br/><span class='meta'><strong>Fit confidence:</strong> $(ConvertTo-HtmlText $fitConfidence)<br/><strong>Compared capabilities:</strong> $(ConvertTo-HtmlText $equivalenceDetails)</span>"
        if ($row.PSObject.Properties.Match('SelectionReason').Count -gt 0 -and $row.SelectionReason) {
            $recommendedCell = "$recommendedCell<br/><span class='meta'><strong>Why selected:</strong> $(ConvertTo-HtmlText $row.SelectionReason)</span>"
        }
        if ($row.PSObject.Properties.Match('RecommendedSkuNote').Count -gt 0 -and $row.RecommendedSkuNote) {
            $recommendedCell = "$recommendedCell<br/><span class='meta'>$(ConvertTo-HtmlText $row.RecommendedSkuNote)</span>"
        }
        $html += "<td>$recommendedCell</td>"
        $html += "<td>$(ConvertTo-HtmlText $row.Validation)</td>"
        $html += "<td>$(ConvertTo-HtmlText $row.NextStep)</td>"
        $html += "</tr>"
    }

    $html += @"
</tbody>
</table>
</div>
</section>

$previewCoverageHtml

$previewRemediationHtml

$batchPoolPreviewHtml

$vmssPreviewHtml

<section class="panel monitoring-panel">
<h2>Monitoring Lifecycle</h2>
<span class="outside-count">Separate track &middot; outside compute retirement count</span>
$(if ($monitoringCount -gt 0) { "<p>Dependency Agent / VM Insights Map retirement is tracked separately and does not contribute to the $(ConvertTo-HtmlText $Facts.RetireCount) compute retirement count.</p>" } else { "<p>No Dependency Agent / VM Insights Map action detected in this scope.</p>" })
<div class="kpis">
<div class="kpi"><div class="kpi-label">Confirmed</div><div class="kpi-value">$(ConvertTo-HtmlText $Facts.MonitoringConfirmed)</div></div>
<div class="kpi"><div class="kpi-label">Unconfirmed</div><div class="kpi-value">$(ConvertTo-HtmlText $Facts.MonitoringUnconfirmed)</div></div>
<div class="kpi"><div class="kpi-label">Unknown</div><div class="kpi-value">$(ConvertTo-HtmlText $Facts.MonitoringUnknown)</div></div>
</div>
$monitoringTableHtml
</section>
</div>

<div class="tab-panel tab-finops">
<div class="tab-heading"><h2>FinOps</h2><p>Retail/list-price deltas and Reserved Instance/Savings Plan planning signals.</p></div>

<section class="panel">
<h2>Cost Impact (monthly)</h2>
$(if ($hasCostSplit) { "<div class='money-grid'><div class='money-cell'><div class='money-label'>Total increase</div><div class='money-value'>$(ConvertTo-HtmlText (Format-ReportMoney $increaseValue))</div></div><div class='money-cell'><div class='money-label'>Total decrease</div><div class='money-value'>$(ConvertTo-HtmlText (Format-ReportMoney $decreaseValue))</div></div><div class='money-cell'><div class='money-label'>Net</div><div class='money-value'>$(ConvertTo-HtmlText $costImpact)</div></div></div>" } else { "<div class='money-grid'><div class='money-cell'><div class='money-label'>Net</div><div class='money-value'>$(ConvertTo-HtmlText $costImpact)</div></div></div>" })
<p class="meta">Retail delta coverage: $(ConvertTo-HtmlText $costCoveredCount) of $(ConvertTo-HtmlText $costPopulationCount) retirement-path VM(s). Compare net values across runs only when this coverage denominator is unchanged.</p>
</section>

<section class="panel">
<h2>VM Cost Detail<span class="info-dot" title="Per-VM PAYG/list-price delta for FinOps review. This is not negotiated pricing and does not calculate RI/Savings Plan effective rates.">i</span></h2>
<p class="meta">Standalone VM candidates only. Retail/list-price estimate from cached Azure Retail Prices; validate negotiated pricing, reservations and Savings Plans separately.</p>
<div class="table-wrap">
<table>
<thead><tr><th>VM</th><th>Wave</th><th>Current SKU</th><th>Recommended SKU</th><th>Retail delta / month</th><th>Pricing basis</th><th>FinOps note</th></tr></thead>
<tbody>
"@

    $finOpsRows = @($Facts.Rows | Sort-Object `
            @{ Expression = {
                    $vmName = if ($_.PSObject.Properties.Match('VmName').Count -gt 0) { [string]$_.VmName } else { '' }
                    if ($waveByVm.ContainsKey($vmName)) { [int]$waveByVm[$vmName].Number } else { 99 }
                } },
            @{ Expression = {
                    $dateText = if ($_.PSObject.Properties.Match('RetirementDate').Count -gt 0) { [string]$_.RetirementDate } else { '' }
                    $parsedDate = [datetime]::MaxValue
                    if ([datetime]::TryParse($dateText, [ref]$parsedDate)) { $parsedDate } else { [datetime]::MaxValue }
                } },
            @{ Expression = { if ($_.PSObject.Properties.Match('VmName').Count -gt 0) { [string]$_.VmName } else { '' } } })

    foreach ($row in $finOpsRows) {
        $costText = "$(Format-ReportMoney $row.RetailDeltaMonthly)$(Format-ReportPercent $row.CostDeltaPercent)"
        $waveInfo = if ($waveByVm.ContainsKey([string]$row.VmName)) { $waveByVm[[string]$row.VmName] } else { $null }
        $waveCell = if ($waveInfo) { "<span class='wave-badge $($waveInfo.CssClass)'>$(ConvertTo-HtmlText $waveInfo.ChipLabel)</span>" } else { "<span class='wave-badge'>Not assigned</span>" }
        $priceBasis = if ($row.PSObject.Properties.Match('CurrentPriceOsBasis').Count -gt 0 -and $row.CurrentPriceOsBasis) { [string]$row.CurrentPriceOsBasis } else { 'N/A' }
        $basisLabel = switch ($priceBasis) {
            'Windows'             { 'Windows retail meter' }
            'Linux'               { 'Linux retail meter' }
            'OsAgnosticFallback'  { 'OS-agnostic retail meter fallback' }
            'NoPrice'             { 'No retail price available' }
            default               { $priceBasis }
        }
        $finOpsNote = if ($row.PSObject.Properties.Match('CommitmentImpact').Count -gt 0 -and [bool]$row.CommitmentImpact) {
            'RI/Savings Plan warning present in validation; review effective pricing and commitment coverage before scheduling.'
        }
        elseif ($null -eq $row.RetailDeltaMonthly) {
            'Retail delta unavailable; verify SKU pricing manually.'
        }
        else {
            'PAYG/list-price estimate only; validate Cost Management, negotiated rates, RI and Savings Plan effects.'
        }
        $html += "<tr>"
        $html += "<td><strong>$(ConvertTo-HtmlText $row.VmName)</strong><br/><span class='meta'>$(ConvertTo-HtmlText $row.Region)</span></td>"
        $html += "<td>$waveCell</td>"
        $html += "<td>$(ConvertTo-HtmlText $row.CurrentSku)</td>"
        $html += "<td>$(ConvertTo-HtmlText $row.RecommendedSku)</td>"
        $html += "<td>$(ConvertTo-HtmlText $costText)</td>"
        $html += "<td>$(ConvertTo-HtmlText $basisLabel)</td>"
        $html += "<td>$(ConvertTo-HtmlText $finOpsNote)</td>"
        $html += "</tr>"
    }

    $html += @"
</tbody>
</table>
</div>
</section>

$riCutoffPreviewHtml
</div>

<div class="tab-panel tab-coverage">
<div class="tab-heading"><h2>Coverage and Evidence</h2><p>Scope, source limitations, provenance and report disclaimer for audit and validation.</p></div>

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

$releaseCommunicationHtml
"@

    $html += @"
<div class="footer"><strong>Provenance:</strong> generated at $(ConvertTo-HtmlText $generatedUtc), live sources: $(ConvertTo-HtmlText $liveSources), as-of: $(ConvertTo-HtmlText $asOfText). <strong>Disclaimer:</strong> this script is not an official Microsoft tool; always validate in authoritative sources before decisions.</div>
</div>
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
        [Parameter(Mandatory = $false)][string[]]$ScopeSubscriptionIds = @(),
        [Parameter(Mandatory = $false)][object[]]$MonitoringLifecycle = @(),
        [Parameter(Mandatory = $false)]$BatchPoolPreview,
        [Parameter(Mandatory = $false)]$VmssPreview,
        [Parameter(Mandatory = $false)]$ReservedInstanceCutoffPreview,
        [Parameter(Mandatory = $false)]$ReleaseCommunicationContext
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

    $rowSubscriptionIds = @($Rows | Where-Object { $_.PSObject.Properties.Match('SubscriptionId').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$_.SubscriptionId) } | ForEach-Object { [string]$_.SubscriptionId } | Select-Object -Unique)
    $subscriptionIds = @($ScopeSubscriptionIds | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ } | Select-Object -Unique)
    if ($subscriptionIds.Count -eq 0) {
        $subscriptionIds = $rowSubscriptionIds
        Write-Log "Provenance assembly: subscription scope was not provided; falling back to $($subscriptionIds.Count) subscription(s) observed on report rows." "WARN"
    }
    elseif ($rowSubscriptionIds.Count -gt 0 -and $subscriptionIds.Count -ne $rowSubscriptionIds.Count) {
        Write-Log "Provenance assembly: subscription scope count ($($subscriptionIds.Count)) differs from report-row subscription count ($($rowSubscriptionIds.Count)); sidebar uses scope count." "WARN"
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
        LiveSources           = if ($ReleaseCommunicationContext) { 'Azure Advisor (ARG), Microsoft Learn (Service Retirement Workbook), Microsoft Release Communications API' } else { 'Azure Advisor (ARG), Microsoft Learn (Service Retirement Workbook)' }
        LiveSourcesOk         = ($retirementSourceHealth.Status -eq 'OK')
        AsOf                  = $asOf
        NearestRetirementDate = $nearestRetirementDate
        NearestRetirementVm   = $nearestRetirementVm
    }
    Write-Log "Provenance assembled: tenants=$($tenantIds.Count), subs=$($subscriptionIds.Count), rowSubs=$($rowSubscriptionIds.Count)."

    $batchRetirementCount = if ($BatchPoolPreview -and $BatchPoolPreview.PSObject.Properties.Match('Rows').Count -gt 0) { @($BatchPoolPreview.Rows).Count } else { 0 }
    $vmssRetirementCount = if ($VmssPreview -and $VmssPreview.PSObject.Properties.Match('Rows').Count -gt 0) { @($VmssPreview.Rows).Count } else { 0 }
    $riCutoffCount = if ($ReservedInstanceCutoffPreview -and $ReservedInstanceCutoffPreview.PSObject.Properties.Match('Rows').Count -gt 0) { @($ReservedInstanceCutoffPreview.Rows).Count } else { 0 }
    $computeRetirementCount = [int]$facts.RetireCount + $batchRetirementCount + $vmssRetirementCount
    $executiveNarrativeText = "This run identifies $computeRetirementCount compute resource(s) on a VM-size retirement path: $($facts.RetireCount) standalone VM(s), $vmssRetirementCount VM Scale Set(s), and $batchRetirementCount Batch pool(s). Standalone VM remediation waves cover $($facts.RetireCount) VM(s): $($facts.AdvisorConfirmed) Advisor-confirmed and $($facts.SkuFamily) SKU-family exposure. Monthly retail/list-price delta for standalone VM candidates is $(if ($null -ne $facts.RetailDeltaMonthly) { ('{0}{1:N2}' -f $(if ([double]$facts.RetailDeltaMonthly -gt 0) { '+' } else { '' }), [double]$facts.RetailDeltaMonthly) } else { 'N/A' }); RI cutoff planning flags $riCutoffCount resource(s) in affected families but does not query actual tenant reservations."

    ConvertTo-SimplifiedReportHtml -Facts $facts -Path $Path -RemediationPlan $remediationPlan -Provenance $provenance -BatchPoolPreview $BatchPoolPreview -VmssPreview $VmssPreview -ReservedInstanceCutoffPreview $ReservedInstanceCutoffPreview -ReleaseCommunicationContext $ReleaseCommunicationContext -ExecutiveNarrativeText $executiveNarrativeText
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
    $pageNumber = 0
    do {
        $pageNumber++
        Write-Progress -Id 25 -ParentId 1 -Activity 'Advisor Resource Graph query' -Status "Downloading page $pageNumber" -PercentComplete -1
        $splat = @{ Query = $Query; First = 1000 }
        if ($Subs)        { $splat.Subscription = $Subs }
        elseif ($UseTenantScope) { $splat.UseTenantScope = $true }
        if ($skipToken)   { $splat.SkipToken = $skipToken }

        $resp = Search-AzGraph @splat -ErrorAction Stop
        if ($resp) { $all += $resp }
        $skipToken = $resp.SkipToken
    } while ($skipToken)
    Write-Progress -Id 25 -ParentId 1 -Activity 'Advisor Resource Graph query' -Status "Completed - rows: $($all.Count)" -Completed
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

    New-DirectoryIfMissing -Path $OutputRoot
    New-DirectoryIfMissing -Path $runDir
    New-DirectoryIfMissing -Path $snapshotDir

    $runHeader = "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))][INFO] Run log initialized at '$($script:RunLogPath)'"
    Set-Content -LiteralPath $script:RunLogPath -Value $runHeader -Encoding UTF8

    Write-Log "Starting Azure SKU Modernization Analyst v$script:ReportVersion"
    $stage++
    Set-MainProgress -Stage $stage -TotalStages $totalStages -Activity "Azure SKU Modernization Analyst" -Status "Initializing modules"

    Assert-ModuleInstalled -Name Az.Accounts
    Assert-ModuleInstalled -Name Az.ResourceGraph
    Assert-ModuleInstalled -Name Az.Compute

    if (-not $SkipAdvisor) {
        Assert-ModuleInstalled -Name Az.Advisor
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
    New-DirectoryIfMissing -Path $effectiveCacheRoot

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
    $inventory = @(Get-ResourceGraphVmInventory -Subscriptions $effectiveSubscriptionIds)

    Write-Log "Collecting Azure Batch pool inventory (public preview capability) from Resource Graph and Batch Management REST"
    $batchPoolInventory = @(Get-ResourceGraphBatchPoolInventory -Subscriptions $effectiveSubscriptionIds -BatchApiVersion $BatchManagementApiVersion)

    Write-Log "Collecting VM Scale Set inventory (public preview capability) from Resource Graph"
    $vmssInventory = @(Get-ResourceGraphVmssInventory -Subscriptions $effectiveSubscriptionIds)

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
    Write-Log "Collecting subscription-scoped compute SKU catalogs"
    $catalogBySubscription = Get-ComputeSkuCatalogsBySubscription -SubscriptionIds $effectiveSubscriptionIds -Inventory $inventory -RegionsFilter $Regions -UseRestApi $UseResourceSkusRestApi -ApiVersion $ResourceSkusApiVersion -IncludeExtendedLocations:$IncludeExtendedLocationsInSkuApi -CacheDir $effectiveCacheRoot -UseCache $UsePersistentCache -TtlHours $SkuCacheTtlHours -ForceRefresh $forceSkuCacheRefresh -TenantId $script:EffectiveTenantId

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
    Write-Log "Load-Retirements: Attempting STREAM C (Microsoft Release Communications API)..." "INFO"
    $releaseCommunicationsApiResult = if ($UseReleaseCommunicationsApi) {
        Get-ReleaseCommunicationsApiItems -Url $ReleaseCommunicationsApiUrl -LookbackMonths $ReleaseCommunicationsLookbackMonths -CacheDir $effectiveCacheRoot -UseCache $UsePersistentCache -CacheTtlHours $ReleaseCommunicationsCacheTtlHours -ForceRefresh ([bool]$ForceRefreshCache)
    }
    else {
        [pscustomobject]@{ Ok = $false; Status = 'Disabled'; Url = $ReleaseCommunicationsApiUrl; CheckedAtUtc = (Get-Date).ToUniversalTime().ToString('o'); LookbackMonths = $ReleaseCommunicationsLookbackMonths; Items = @(); Error = 'Disabled by parameter' }
    }
    if ($releaseCommunicationsApiResult.Ok) {
        Write-Log "Load-Retirements: STREAM C API succeeded. Notices=$(@($releaseCommunicationsApiResult.Items).Count); cache mode=$($releaseCommunicationsApiResult.CacheMode); index records=$($releaseCommunicationsApiResult.CachedTotal); detail updates=$($releaseCommunicationsApiResult.DetailUpdates); pages=$($releaseCommunicationsApiResult.PageCount)." "INFO"
    }
    else {
        Write-Log "Load-Retirements: STREAM C API status=$($releaseCommunicationsApiResult.Status). $($releaseCommunicationsApiResult.Error)" "WARN"
    }
    $inventorySkuNames = @($inventory | ForEach-Object { if ($_.PSObject.Properties.Match('VmSize').Count -gt 0) { [string]$_.VmSize } elseif ($_.PSObject.Properties.Match('CurrentSku').Count -gt 0) { [string]$_.CurrentSku } } | Where-Object { $_ } | Sort-Object -Unique)
    $retirements = Get-Retirements -UseOfficialList $UseOfficialRetirementList -UsePortalSource $UsePortalRetirementSource -Subscriptions $effectiveSubscriptionIds -AdvisorRetirementTypeIdBlocklist $AdvisorRetirementTypeIdBlocklist -AdvisorRetirementNameBlockPattern $AdvisorRetirementNameBlockPattern -RequireLiveRetirementSource $RequireLiveRetirementSource -ReleaseCommunicationItems @($releaseCommunicationsApiResult.Items) -InventorySkuNames $inventorySkuNames -ReleaseCommunicationsOk ([bool]$releaseCommunicationsApiResult.Ok)
    $batchPoolPreview = Build-BatchPoolRetirementPreview -BatchPools $batchPoolInventory -Retirements $retirements
    Write-Log "Batch pool public preview: scanned $($batchPoolPreview.TotalBatchPoolsScanned) pool(s), retirement path $($batchPoolPreview.RetirementPathCount)."
    $vmssPreview = Build-VmssRetirementPreview -VmScaleSets $vmssInventory -Retirements $retirements
    Write-Log "VMSS public preview: scanned $($vmssPreview.TotalVmssScanned) scale set(s), retirement path $($vmssPreview.RetirementPathCount)."

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
    $results = Build-RecommendationsBySubscription -Inventory $inventory -CatalogBySubscription $catalogBySubscription -PriceMap $priceMap -CommitmentMap $commitmentMap -FirstSeenMap $firstSeenMap -Retirements $retirements -AdvisorHints $advisorHints -Top $TopCandidates -AllowArchChange:$AllowArchitectureChange -MaxVcpuIncreaseRatio $MaxRecommendedVcpuIncreaseRatio -MaxMemoryIncreaseRatio $MaxRecommendedMemoryIncreaseRatio -MaxCostIncreasePercent $MaxRecommendedCostIncreasePercent -MinPerfRatio $MinRecommendedPerfRatio -EquivalentVcpuTolerancePercent $EquivalentVcpuTolerancePercent -EquivalentMemoryTolerancePercent $EquivalentMemoryTolerancePercent

    $stage++
    Set-MainProgress -Stage $stage -TotalStages $totalStages -Activity "Azure SKU Modernization Analyst" -Status "Generating report output"

    $results = @($results | Sort-Object VmName)
    $reservedInstanceCutoffPreview = Build-ReservedInstanceCutoffPreview -VmRows $results -BatchPools $batchPoolInventory -VmScaleSets $vmssInventory -Retirements $retirements -ReleaseCommunicationItems @($releaseCommunicationsApiResult.Items)
    Write-Log "Reserved Instance cutoff public preview: scanned $($reservedInstanceCutoffPreview.TotalResourcesScanned) compute resource(s), exposure $($reservedInstanceCutoffPreview.ImpactCount)."

    $preReleaseCommunicationsCountSnapshot = Get-ReportCountSnapshot -Rows $results -MonitoringLifecycle $monitoringLifecycle
    $releaseCommunicationContext = Get-ReleaseCommunicationsPreview -Enabled $UseReleaseCommunicationsApi -Url $ReleaseCommunicationsApiUrl -LookbackMonths $ReleaseCommunicationsLookbackMonths -CacheDir $effectiveCacheRoot -UseCache $UsePersistentCache -CacheTtlHours $ReleaseCommunicationsCacheTtlHours -ForceRefresh ([bool]$ForceRefreshCache) -ApiResult $releaseCommunicationsApiResult -Rows $results -BatchPoolPreview $batchPoolPreview -VmssPreview $vmssPreview -ReservedInstanceCutoffPreview $reservedInstanceCutoffPreview
    $postReleaseCommunicationsCountSnapshot = Get-ReportCountSnapshot -Rows $results -MonitoringLifecycle $monitoringLifecycle
    Assert-CountsUnchangedAfterReleaseCommunicationCoverage -Before $preReleaseCommunicationsCountSnapshot -After $postReleaseCommunicationsCountSnapshot
    Write-Log "Release Communications API coverage: status=$($releaseCommunicationContext.Status), relevant=$($releaseCommunicationContext.RelevantCount), corroborated=$($releaseCommunicationContext.CorroboratedCount), FinOps=$($releaseCommunicationContext.FinOpsCount), review-only=$($releaseCommunicationContext.ReviewOnlyCount). Coverage rendering left computed findings unchanged."

    $csvPath = Join-Path $runDir "sku_modernization_report.csv"
    $jsonPath = Join-Path $runDir "sku_modernization_report.json"
    $htmlPath = Join-Path $runDir "sku_modernization_report.html"
    $backlogPath = Join-Path $runDir "migration_backlog_items.csv"
    $advisorPath = Join-Path $runDir "advisor_hints.json"

    $results |
        Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8

    [pscustomobject]@{
        ReportVersion    = $script:ReportVersion
        Items            = $results
        BatchPoolPreview = $batchPoolPreview
        VmssPreview      = $vmssPreview
        ReservedInstanceCutoffPreview = $reservedInstanceCutoffPreview
        ReleaseCommunicationContext   = $releaseCommunicationContext
    } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

    Export-BacklogItems -Rows $results -Path $backlogPath

    ConvertTo-ReportHtml -Rows $results -Path $htmlPath -ScopeSubscriptionIds $effectiveSubscriptionIds -MonitoringLifecycle $monitoringLifecycle -BatchPoolPreview $batchPoolPreview -VmssPreview $vmssPreview -ReservedInstanceCutoffPreview $reservedInstanceCutoffPreview -ReleaseCommunicationContext $releaseCommunicationContext

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




