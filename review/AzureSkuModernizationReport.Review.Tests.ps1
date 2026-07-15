BeforeAll {
    $script:SourcePath = Join-Path $PSScriptRoot '..\AzureSkuModernizationReport.ps1'
    $tokens = $null
    $parseErrors = $null
    $script:SourceAst = [System.Management.Automation.Language.Parser]::ParseFile(
        $script:SourcePath,
        [ref]$tokens,
        [ref]$parseErrors
    )

    if ($parseErrors.Count -gt 0) {
        throw "Production script has $($parseErrors.Count) parse error(s)."
    }

    $functionDefinitions = $script:SourceAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
    }, $true)

    foreach ($definition in $functionDefinitions) {
        Invoke-Expression $definition.Extent.Text
    }

    $script:RiskCriticalDays = 365
    $script:RiskHighDays = 730
    $script:WaveOrder = [ordered]@{ W0 = 0; W1 = 1; W2 = 2; W3 = 3; W4 = 4 }
    $script:EffectiveTenantId = 'test-tenant'

    function Write-Log {
        param($Message, $Level)
    }

    function Add-ApiCallLog {
        param(
            $Api,
            $Provider,
            $TenantId,
            $SubscriptionId,
            $Request,
            $StartedAt,
            $EndedAt,
            $Success,
            $ErrorMessage,
            $Meta
        )
    }

    function Search-AzGraph {
        throw 'Search-AzGraph test stub was not configured.'
    }

    function New-TestCapabilitySet {
        return @{
            vCPUs                       = '2'
            MemoryGB                    = '8'
            MaxDataDiskCount            = '4'
            MaxNetworkInterfaces        = '2'
            PremiumIO                   = 'True'
            AcceleratedNetworkingEnabled = 'True'
            HyperVGenerations           = 'V1,V2'
            CpuArchitectureType         = 'x64'
            ACUs                        = '100'
        }
    }

    function New-TestCatalogEntry {
        param(
            [string]$Name,
            [string]$Family,
            [object[]]$Restrictions = @()
        )

        return [pscustomobject]@{
            Name         = $Name
            Family       = $Family
            Tier         = 'Standard'
            Size         = ($Name -replace '^Standard_', '')
            Locations    = @('eastus')
            Cap          = New-TestCapabilitySet
            Restrictions = $Restrictions
            LocationInfo = @()
        }
    }

    function New-TestPrice {
        param(
            [string]$Sku,
            [double]$Price
        )

        return [pscustomobject]@{
            ArmSkuName         = $Sku
            Region             = 'eastus'
            CurrencyCode       = 'USD'
            UnitPrice          = $Price
            LinuxUnitPrice     = $Price
            WindowsUnitPrice   = $null
            UnitOfMeasure      = '1 Hour'
            MeterName          = ($Sku -replace '^Standard_', '')
            ProductName        = 'Virtual Machines test series'
            SkuName            = $Sku
            EffectiveStartDate = '2026-01-01'
        }
    }

    function New-TestVm {
        param(
            [string]$Name = 'vm-test',
            [string]$Sku = 'Standard_D2_v2'
        )

        return [pscustomobject]@{
            SubscriptionId = 'sub-a'
            ResourceGroup  = 'rg-test'
            VmName         = $Name
            Location       = 'eastus'
            VmSize         = $Sku
            OsType         = 'Linux'
            VmCreatedDate  = '2024-01-01'
            TagsText       = ''
            ExtensionsText = ''
        }
    }

    function New-EmptyRetirements {
        return [pscustomobject]@{
            Exact          = @{}
            Series         = @()
            ByVmResourceId = @{}
        }
    }
}

Describe 'Microsoft Release Communications API ingestion' {
    It 'derives commercial series <Family> from SKU <Sku> without an affected-family lookup list' -ForEach @(
        @{ Sku = 'Standard_DS2_v3'; Family = 'Dsv3-series' }
        @{ Sku = 'Standard_D2_v3'; Family = 'Dv3-series' }
        @{ Sku = 'Standard_ES2_v3'; Family = 'Esv3-series' }
        @{ Sku = 'Standard_E2_v3'; Family = 'Ev3-series' }
        @{ Sku = 'Standard_DS2_v2'; Family = 'Dsv2-series' }
        @{ Sku = 'Standard_D2_v2'; Family = 'Dv2-series' }
        @{ Sku = 'Standard_L8s_v2'; Family = 'Lsv2-series' }
        @{ Sku = 'Standard_A1_v2'; Family = 'Av2-series' }
        @{ Sku = 'Standard_A2m_v2'; Family = 'Amv2-series' }
        @{ Sku = 'Standard_B4ms'; Family = 'Bv1-series' }
        @{ Sku = 'Standard_F2_v2'; Family = 'Fsv2-series' }
        @{ Sku = 'Standard_GS5'; Family = 'Gs-series' }
    ) {
        Convert-SkuToReservedInstanceCutoffFamily -SkuName $Sku | Should -Be $Family
    }

    It 'uses the official commercial notice for RI cutoff without creating a VM retirement' {
        $notice = [pscustomobject]@{
            Title          = 'Retirement: Azure Reserved Virtual Machines Instances for select VM series'
            Description    = 'Starting July 1, 2026, purchases and renewals will no longer be available for Reserved VM Instances for the Dv2, Dsv2, and Dv3 VM series.'
            Link           = 'https://azure.microsoft.com/updates?id=560948'
            Tags           = @('Retirements', 'Pricing & Offerings')
            Categories     = @('Virtual Machines')
            Availabilities = @([pscustomobject]@{ ring = 'Retirement'; year = 2026; month = 'July' })
        }
        $rows = @(
            [pscustomobject]@{ VmName = 'affected'; CurrentSku = 'Standard_D2_v2'; Region = 'eastus'; RetirementDate = 'N/A' }
            [pscustomobject]@{ VmName = 'unaffected'; CurrentSku = 'Standard_F2'; Region = 'eastus'; RetirementDate = 'N/A' }
        )

        $preview = Build-ReservedInstanceCutoffPreview -VmRows $rows -ReleaseCommunicationItems @($notice)
        $technicalSeries = @(Get-ReleaseCommunicationRetirementSeries -Items @($notice) -SkuNames @('Standard_D2_v2'))

        $preview.CutoffDate | Should -Be '2026-07-01'
        $preview.ImpactCount | Should -Be 1
        $preview.Rows[0].Family | Should -Be 'Dv2-series'
        $preview.Rows[0].Source | Should -Be $notice.Link
        $technicalSeries.Count | Should -Be 0
    }

    It 'does not fabricate RI cutoff exposure when the official notice is unavailable' {
        $row = [pscustomobject]@{ VmName = 'vm'; CurrentSku = 'Standard_D2_v2'; Region = 'eastus'; RetirementDate = 'N/A' }

        $preview = Build-ReservedInstanceCutoffPreview -VmRows @($row) -ReleaseCommunicationItems @()

        $preview.CutoffDate | Should -Be 'N/A'
        $preview.ImpactCount | Should -Be 0
    }

    It 'uses an exact date from official text when it agrees with structured availability' {
        $item = [pscustomobject]@{
            Title          = 'Retirement of NP-series virtual machines'
            Description    = 'NP-series virtual machines will retire on May 31, 2027.'
            Availabilities = @([pscustomobject]@{ ring = 'Retirement'; year = 2027; month = 'May' })
        }

        Get-ReleaseCommunicationRetirementDate -Item $item | Should -Be '2027-05-31'
    }

    It 'falls back to the first day of the structured retirement month' {
        $item = [pscustomobject]@{
            Title          = 'Retirement of NP-series virtual machines'
            Description    = 'Retirement is planned for May 2027.'
            Availabilities = @([pscustomobject]@{ ring = 'Retirement'; year = 2027; month = 'May' })
        }

        Get-ReleaseCommunicationRetirementDate -Item $item | Should -Be '2027-05-01'
    }

    It 'prefers the structured retirement month when a text date conflicts with it' {
        $item = [pscustomobject]@{
            Title          = 'Retirement of NP-series virtual machines'
            Description    = 'NP-series virtual machines will retire on May 31, 2027.'
            Availabilities = @([pscustomobject]@{ ring = 'Retirement'; year = 2027; month = 'June' })
        }

        Get-ReleaseCommunicationRetirementDate -Item $item | Should -Be '2027-06-01'
    }

    It 'rejects false-positive series evidence for <Case>' -ForEach @(
        @{
            Case = 'missing structured availability'
            Item = [pscustomobject]@{
                Title = 'NP-series retirement'; Description = 'NP-series retires May 31, 2027.'
                Link = 'https://azure.microsoft.com/updates?id=no-availability'; Categories = @('Compute')
                Tags = @('Retirements'); Availabilities = @()
            }
        }
        @{
            Case = 'a non-retirement availability ring'
            Item = [pscustomobject]@{
                Title = 'NP-series retirement'; Description = 'NP-series retires May 31, 2027.'
                Link = 'https://azure.microsoft.com/updates?id=wrong-ring'; Categories = @('Compute')
                Tags = @('Retirements'); Availabilities = @([pscustomobject]@{ ring = 'GeneralAvailability'; year = 2027; month = 'May' })
            }
        }
        @{
            Case = 'a series token embedded inside another word'
            Item = [pscustomobject]@{
                Title = 'XNP-seriesX retirement'; Description = 'The XNP-seriesX product retires May 31, 2027.'
                Link = 'https://azure.microsoft.com/updates?id=token-boundary'; Categories = @('Compute')
                Tags = @('Retirements'); Availabilities = @([pscustomobject]@{ ring = 'Retirement'; year = 2027; month = 'May' })
            }
        }
    ) {
        $series = @(Get-ReleaseCommunicationRetirementSeries -Items @($Item) -SkuNames @('Standard_NP10s'))

        $series.Count | Should -Be 0
    }

    It 'creates an official retirement only for a series present in tenant inventory' {
        $item = [pscustomobject]@{
            Title          = 'Retirement of NP-series virtual machines'
            Description    = 'NP-series virtual machines will retire on May 31, 2027.'
            Link           = 'https://azure.microsoft.com/updates?id=548497'
            Categories     = @('Compute', 'Virtual Machines', 'Retirements')
            Availabilities = @([pscustomobject]@{ ring = 'Retirement'; year = 2027; month = 'May' })
        }

        $series = @(Get-ReleaseCommunicationRetirementSeries -Items @($item) -SkuNames @('Standard_NP10s', 'Standard_D2_v2'))

        $series.Count | Should -Be 1
        $series[0].SeriesName | Should -Be 'NP-series'
        $series[0].RetireOn | Should -Be '2027-05-31'
        $series[0].Source | Should -Be 'ReleaseCommunicationsApi'
        $series[0].SourceGate | Should -Be 'ReleaseCommunicationsApi'
        $evidence = Get-RetirementEvidence -RetirementEntry $series[0]
        $evidence.EvidenceType | Should -Be 'PublicOfficialAnnouncement'
        $evidence.Confidence | Should -Be 'High'
    }

    It 'keeps Learn priority and uses Release Communications for an uncovered family' {
        Mock Write-Log {}
        Mock Get-OfficialRetirementsFromLearnMarkdown {
            [pscustomobject]@{
                Ok     = $true
                Series = @([pscustomobject]@{
                    SeriesName = 'Dv2-series'; Status = 'Announced'; RetireOn = '2028-05-01'; Notes = ''
                    Source = 'LiveLearnMarkdown'; MigrationGuide = 'https://learn.microsoft.com/test'
                    Announcement = 'https://azure.microsoft.com/learn-notice'; SourceUrl = 'https://learn.microsoft.com/test'
                    AsOf = '2026-01-01T00:00:00Z'; SourceGate = 'LiveLearnMarkdown'; IsLive = $true
                })
            }
        }
        $items = @(
            [pscustomobject]@{ Title = 'Dv2-series retirement'; Description = 'Retires May 1, 2029.'; Link = 'https://azure.microsoft.com/updates?id=dv2'; Categories = @('Compute'); Availabilities = @([pscustomobject]@{ ring = 'Retirement'; year = 2029; month = 'May' }) },
            [pscustomobject]@{ Title = 'NP-series retirement'; Description = 'Retires May 31, 2027.'; Link = 'https://azure.microsoft.com/updates?id=np'; Categories = @('Compute'); Availabilities = @([pscustomobject]@{ ring = 'Retirement'; year = 2027; month = 'May' }) }
        )

        $retirements = Get-Retirements -UseOfficialList $true -UsePortalSource $false -ReleaseCommunicationItems $items -InventorySkuNames @('Standard_D2_v2', 'Standard_NP10s') -ReleaseCommunicationsOk $true
        $dv2 = Resolve-RetirementForSku -SkuName 'Standard_D2_v2' -Retirements $retirements
        $np = Resolve-RetirementForSku -SkuName 'Standard_NP10s' -Retirements $retirements

        $dv2.Source | Should -Be 'LiveLearnMarkdown'
        $dv2.RetireOn | Should -Be '2028-05-01'
        $np.Source | Should -Be 'ReleaseCommunicationsApi'
        $np.RetireOn | Should -Be '2027-05-31'
        $retirements.StreamCSeriesCount | Should -Be 2
        Assert-MockCalled Write-Log -Times 1 -Exactly -ParameterFilter {
            $Message -eq 'Load-Retirements: STREAM C succeeded. Tenant-matched series=2; added=1; superseded by Learn=1.' -and $Level -eq 'INFO'
        }
    }

    It 'includes full history and does not cap the rendered notices at 30' {
        $indexRecords = @(1..35 | ForEach-Object { @{ id = [string]$_; modified = '2020-01-01T00:00:00Z' } })
        Mock Invoke-WebRequest {
            param($Uri)
            if ([string]$Uri -match '/azure/(\d+)$') {
                $id = $Matches[1]
                $detail = @{ id = $id; title = "Official notice $id"; description = 'No classifier keywords'; status = 'Published'; created = '2020-01-01T00:00:00Z'; modified = '2020-01-01T00:00:00Z'; tags = @('Retirements'); products = @('Virtual Machines'); productCategories = @('Compute'); availabilities = @() }
                return [pscustomobject]@{ Content = ($detail | ConvertTo-Json -Depth 10) }
            }
            [pscustomobject]@{ Content = (@{ value = $indexRecords } | ConvertTo-Json -Depth 10) }
        }

        $result = Get-ReleaseCommunicationsPreview -Url 'https://www.microsoft.com/releasecommunications/api/v2/azure' -LookbackMonths 0

        $result.Ok | Should -BeTrue
        $result.TotalItems | Should -Be 35
        $result.RelevantCount | Should -Be 35
        $result.ReviewOnlyCount | Should -Be 35
    }

    It 'does not duplicate orderby when the configured URL already includes it' {
        $script:ReleaseCommunicationsRequestUri = ''
        Mock Invoke-WebRequest {
            param($Uri)
            $script:ReleaseCommunicationsRequestUri = [string]$Uri
            [pscustomobject]@{ Content = '{"value":[]}' }
        }

        $url = 'https://www.microsoft.com/releasecommunications/api/v2/azure?$filter=tags/any(t:%20t%20eq%20%27Retirements%27)&$orderby=modified%20desc'
        $result = Get-ReleaseCommunicationsApiItems -Url $url

        $result.Ok | Should -BeTrue
        ([regex]::Matches($script:ReleaseCommunicationsRequestUri, '(?i)\$orderby=').Count) | Should -Be 1
    }

    It 'keeps an absent cache array-shaped under strict mode' {
        & {
            Set-StrictMode -Version Latest
            Mock Invoke-WebRequest {
                [pscustomobject]@{ Content = '{"value":[]}' }
            }

            $cacheDir = Join-Path $TestDrive 'release-communications-empty-cache'
            New-Item -ItemType Directory -Path $cacheDir | Out-Null
            $result = Get-ReleaseCommunicationsApiItems -Url 'https://www.microsoft.com/releasecommunications/api/v2/azure' -CacheDir $cacheDir -UseCache $true

            $result.Ok | Should -BeTrue
            $result.CachedTotal | Should -Be 0
            $result.CacheMode | Should -Be 'FullRefresh'
        }
    }

    It 'queries the retirement index and maps the per-ID detail to a report item' {
                $fixture = @'
{
    "@odata.context": "https://example.test/$metadata#Azure",
    "value": [
        {
            "id": "567444",
            "productCategories": ["Compute"],
            "tags": ["Retirements"],
            "products": ["Virtual Machines"],
            "title": "Retirement: test VM series",
            "description": "Test notice",
            "status": null,
            "created": "2026-07-13T17:04:04.0000000Z",
            "modified": "2026-07-13T17:04:04.0000000Z",
            "availabilities": [{ "ring": "Retirement", "year": 2027, "month": "July" }]
        }
    ]
}
'@
                $script:ReleaseCommunicationsRequestUris = @()
                Mock Invoke-WebRequest {
                        param($Uri)
                    $script:ReleaseCommunicationsRequestUris += [string]$Uri
                    if ([string]$Uri -match '/azure/567444$') {
                        $detail = ($fixture | ConvertFrom-Json).value[0]
                        return [pscustomobject]@{ Content = ($detail | ConvertTo-Json -Depth 10) }
                    }
                        [pscustomobject]@{ Content = $fixture }
                }

                $url = 'https://www.microsoft.com/releasecommunications/api/v2/azure?$filter=tags/any(t:%20t%20eq%20%27Retirements%27)'
                $result = Get-ReleaseCommunicationsApiItems -Url $url -LookbackMonths 12

                $result.Ok | Should -BeTrue
                $result.PageCount | Should -Be 1
                @($result.Items).Count | Should -Be 1
                $result.Items[0].Guid | Should -Be '567444'
                $result.Items[0].PublishedDate | Should -Be '2026-07-13'
                $result.Items[0].Link | Should -Be 'https://azure.microsoft.com/updates?id=567444'
                $result.Items[0].Categories | Should -Contain 'Compute'
                $result.Items[0].Categories | Should -Contain 'Virtual Machines'
                $result.Items[0].Categories | Should -Contain 'Retirements'
                @($script:ReleaseCommunicationsRequestUris).Count | Should -Be 2
                $script:ReleaseCommunicationsRequestUris[0] | Should -Match '\$filter=tags/any'
                [uri]::UnescapeDataString($script:ReleaseCommunicationsRequestUris[0]) | Should -Match '\$orderby=modified desc'
                $script:ReleaseCommunicationsRequestUris[1] | Should -Match '/api/v2/azure/567444$'
            }

            It 'reuses a fresh cache and refreshes only changed details after the daily TTL' {
                $script:ReleaseCommunicationsPhase = 'Full'
                $script:ReleaseCommunicationsRequestUris = @()
                Mock Invoke-WebRequest {
                    param($Uri)
                    $script:ReleaseCommunicationsRequestUris += [string]$Uri
                    if ([string]$Uri -match '/azure/567444$') {
                        $modified = if ($script:ReleaseCommunicationsPhase -eq 'Delta') { '2026-07-14T17:04:04.0000000Z' } else { '2026-07-13T17:04:04.0000000Z' }
                        $detail = [pscustomobject]@{ id = '567444'; title = 'Retirement: test VM series'; description = 'Test notice'; created = '2026-07-13T17:04:04.0000000Z'; modified = $modified; tags = @('Retirements') }
                        return [pscustomobject]@{ Content = ($detail | ConvertTo-Json -Depth 10) }
                    }
                    $modified = if ($script:ReleaseCommunicationsPhase -eq 'Delta') { '2026-07-14T17:04:04.0000000Z' } else { '2026-07-13T17:04:04.0000000Z' }
                    [pscustomobject]@{ Content = (@{ value = @(@{ id = '567444'; modified = $modified }) } | ConvertTo-Json -Depth 10) }
                }

                $cacheDir = Join-Path $TestDrive 'release-communications-cache'
                New-Item -ItemType Directory -Path $cacheDir | Out-Null
                $url = 'https://www.microsoft.com/releasecommunications/api/v2/azure?$filter=tags/any(t:%20t%20eq%20%27Retirements%27)'
                $initial = Get-ReleaseCommunicationsApiItems -Url $url -LookbackMonths 12 -CacheDir $cacheDir -UseCache $true -CacheTtlHours 24
                $script:ReleaseCommunicationsRequestUris = @()
                $cached = Get-ReleaseCommunicationsApiItems -Url $url -LookbackMonths 12 -CacheDir $cacheDir -UseCache $true -CacheTtlHours 24

                $initial.CacheMode | Should -Be 'FullRefresh'
                $cached.CacheMode | Should -Be 'CacheHit'
                @($script:ReleaseCommunicationsRequestUris).Count | Should -Be 0

                Get-ChildItem -Path $cacheDir -Filter 'release_communications_retirements_index_*.json' | ForEach-Object { $_.LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddDays(-2) }
                $script:ReleaseCommunicationsPhase = 'Delta'
                $delta = Get-ReleaseCommunicationsApiItems -Url $url -LookbackMonths 12 -CacheDir $cacheDir -UseCache $true -CacheTtlHours 24

                $delta.CacheMode | Should -Be 'DeltaRefresh'
                $delta.DetailUpdates | Should -Be 1
                @($script:ReleaseCommunicationsRequestUris).Count | Should -Be 2
                [uri]::UnescapeDataString($script:ReleaseCommunicationsRequestUris[0]) | Should -Match 'modified gt'
                $script:ReleaseCommunicationsRequestUris[1] | Should -Match '/api/v2/azure/567444$'
        }

        It 'retains cached details when a stale-index delta contains no changes' {
            $script:ReleaseCommunicationsPhase = 'Full'
            $script:ReleaseCommunicationsRequestUris = @()
            Mock Invoke-WebRequest {
                param($Uri)
                $script:ReleaseCommunicationsRequestUris += [string]$Uri
                if ([string]$Uri -match '/azure/567444$') {
                    if ($script:ReleaseCommunicationsPhase -ne 'Full') { throw 'Delta refresh must not redownload unchanged details.' }
                    $detail = [pscustomobject]@{
                        id = '567444'; title = 'Retirement: cached VM series'; description = 'Cached detail'
                        created = '2026-07-13T17:04:04.0000000Z'; modified = '2026-07-13T17:04:04.0000000Z'
                        tags = @('Retirements'); products = @('Virtual Machines'); productCategories = @('Compute')
                        availabilities = @([pscustomobject]@{ ring = 'Retirement'; year = 2027; month = 'July' })
                    }
                    return [pscustomobject]@{ Content = ($detail | ConvertTo-Json -Depth 10) }
                }
                if ($script:ReleaseCommunicationsPhase -eq 'Delta') {
                    return [pscustomobject]@{ Content = '{"value":[]}' }
                }
                [pscustomobject]@{ Content = (@{ value = @(@{ id = '567444'; modified = '2026-07-13T17:04:04.0000000Z' }) } | ConvertTo-Json -Depth 10) }
            }

            $cacheDir = Join-Path $TestDrive 'release-communications-empty-delta'
            New-Item -ItemType Directory -Path $cacheDir | Out-Null
            $url = 'https://www.microsoft.com/releasecommunications/api/v2/azure?$filter=tags/any(t:%20t%20eq%20%27Retirements%27)'
            $initial = Get-ReleaseCommunicationsApiItems -Url $url -CacheDir $cacheDir -UseCache $true -CacheTtlHours 24
            Get-ChildItem -Path $cacheDir -Filter 'release_communications_retirements_index_*.json' | ForEach-Object { $_.LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddDays(-2) }
            $script:ReleaseCommunicationsPhase = 'Delta'
            $script:ReleaseCommunicationsRequestUris = @()

            $delta = Get-ReleaseCommunicationsApiItems -Url $url -CacheDir $cacheDir -UseCache $true -CacheTtlHours 24

            $initial.Items.Count | Should -Be 1
            $delta.CacheMode | Should -Be 'DeltaRefresh'
            $delta.DetailUpdates | Should -Be 0
            $delta.CachedTotal | Should -Be 1
            $delta.Items.Count | Should -Be 1
            $delta.Items[0].Guid | Should -Be '567444'
            @($script:ReleaseCommunicationsRequestUris).Count | Should -Be 1
            [uri]::UnescapeDataString($script:ReleaseCommunicationsRequestUris[0]) | Should -Match 'modified gt'
        }

        It 'forces index and detail refresh even while the cache is fresh' {
            $script:ReleaseCommunicationsPhase = 'Initial'
            $script:ReleaseCommunicationsRequestUris = @()
            Mock Invoke-WebRequest {
                param($Uri)
                $script:ReleaseCommunicationsRequestUris += [string]$Uri
                if ([string]$Uri -match '/azure/567444$') {
                    $detail = [pscustomobject]@{
                        id = '567444'; title = "Retirement: $($script:ReleaseCommunicationsPhase) VM series"; description = 'Test detail'
                        created = '2026-07-13T17:04:04.0000000Z'; modified = '2026-07-13T17:04:04.0000000Z'
                        tags = @('Retirements'); products = @('Virtual Machines'); productCategories = @('Compute'); availabilities = @()
                    }
                    return [pscustomobject]@{ Content = ($detail | ConvertTo-Json -Depth 10) }
                }
                [pscustomobject]@{ Content = (@{ value = @(@{ id = '567444'; modified = '2026-07-13T17:04:04.0000000Z' }) } | ConvertTo-Json -Depth 10) }
            }

            $cacheDir = Join-Path $TestDrive 'release-communications-force-refresh'
            New-Item -ItemType Directory -Path $cacheDir | Out-Null
            $url = 'https://www.microsoft.com/releasecommunications/api/v2/azure'
            $initial = Get-ReleaseCommunicationsApiItems -Url $url -CacheDir $cacheDir -UseCache $true -CacheTtlHours 24
            $script:ReleaseCommunicationsPhase = 'Forced'
            $script:ReleaseCommunicationsRequestUris = @()

            $forced = Get-ReleaseCommunicationsApiItems -Url $url -CacheDir $cacheDir -UseCache $true -CacheTtlHours 24 -ForceRefresh $true

            $initial.CacheMode | Should -Be 'FullRefresh'
            $forced.CacheMode | Should -Be 'FullRefresh'
            $forced.DetailUpdates | Should -Be 1
            $forced.Items[0].Title | Should -Be 'Retirement: Forced VM series'
            @($script:ReleaseCommunicationsRequestUris).Count | Should -Be 2
            $script:ReleaseCommunicationsRequestUris[1] | Should -Match '/api/v2/azure/567444$'
        }
}

Describe 'Microsoft Learn retirement ingestion' {
    It 'parses every retirement table, not only the first table' {
        $fixture = @'
| Series name | Retirement Status | Retirement Announcement | Planned Retirement Date | Migration Guide |
|---|---|---|---|---|
| Dv2-series | **Announced** | notice | 05/01/28 | guide |

## Compute optimized retired sizes

| Series name | Retirement Status | Retirement Announcement | Planned Retirement Date | Migration Guide |
|---|---|---|---|---|
| F-series | **Announced** | notice | 11/15/28 | guide |
'@
        Mock Invoke-WebRequest { [pscustomobject]@{ Content = $fixture } }

        $result = Get-OfficialRetirementsFromLearnMarkdown -Url 'https://example.test/retirements.md'

        $result.Ok | Should -BeTrue
        @($result.Series).SeriesName | Should -Be @('Dv2-series', 'F-series')
    }

    It 'preserves source status and accepts every date format present in the live document' {
        $fixture = @'
| Series name | Retirement Status | Retirement Announcement | Planned Retirement Date | Migration Guide |
|---|---|---|---|---|
| NCv3-Series | **Retired** | - | 30/9/25 | guide |
'@
        Mock Invoke-WebRequest { [pscustomobject]@{ Content = $fixture } }

        $result = Get-OfficialRetirementsFromLearnMarkdown -Url 'https://example.test/retirements.md'

        $result.Ok | Should -BeTrue
        $result.Series[0].Status | Should -Be 'Retired'
        $result.Series[0].RetireOn | Should -Be '2025-09-30'
    }

    It 'preserves announcement URLs and resolves relative migration-guide links' {
        $fixture = @'
| Series name | Retirement Status | Retirement Announcement | Planned Retirement Date | Migration Guide |
|---|---|---|---|---|
| Dv2-series | **Announced** | [03/31/25](https://azure.microsoft.com/updates?id=485569) | 05/01/28 | [Migration Guide](/azure/virtual-machines/migration/sizes/d-ds-dv2-dsv2-ls-series-migration-guide) |
'@
        Mock Invoke-WebRequest { [pscustomobject]@{ Content = $fixture } }

        $result = Get-OfficialRetirementsFromLearnMarkdown -Url 'https://example.test/retirements.md'

        $result.Series[0].Announcement | Should -Be 'https://azure.microsoft.com/updates?id=485569'
        $result.Series[0].MigrationGuide | Should -Be 'https://learn.microsoft.com/azure/virtual-machines/migration/sizes/d-ds-dv2-dsv2-ls-series-migration-guide'
    }

    It 'resolves a normalized SKU through a Learn series key' {
        $retirements = [pscustomobject]@{
            Exact = @{
                'Dv2-series' = [pscustomobject]@{
                    Status     = 'Announced'
                    RetireOn   = '2028-05-01'
                    Source     = 'LiveLearnMarkdown'
                    SeriesName = 'Dv2-series'
                }
            }
            Series = @([pscustomobject]@{
                SeriesName   = 'Dv2-series'
                Status       = 'Announced'
                RetireOn     = '2028-05-01'
                Notes        = ''
                MigrationGuide = 'https://learn.microsoft.com/test'
                Announcement = 'https://azure.microsoft.com/test'
                MatchRegexes = @()
                Source       = 'LiveLearnMarkdown'
            })
        }

        $result = Resolve-RetirementForSku -SkuName 'Standard_D2_v2' -Retirements $retirements

        $result | Should -Not -BeNullOrEmpty
        $result.SeriesName | Should -Be 'Dv2-series'
    }

    It 'maps constrained Dsv2 sizes to the same retiring series' -ForEach @(
        @{ Sku = 'Standard_DS12-1_v2' }
        @{ Sku = 'Standard_DS12-2_v2' }
    ) {
        Convert-SkuToSeriesKey -SkuName $Sku | Should -Be 'Dsv2-series'
    }
}

Describe 'Live-source integrity' {
    It 'preserves the Advisor monitoring retirement date without a hardcoded fallback' {
        $withDate = @(ConvertTo-NormalizedMonitoringLifecycleRows -MonitoringRows @(
            [pscustomobject]@{ ResourceId = '/subscriptions/s/resourceGroups/r/providers/Microsoft.Compute/virtualMachines/dated'; RetireOn = '2029-01-15' }
        ))
        $withoutDate = @(ConvertTo-NormalizedMonitoringLifecycleRows -MonitoringRows @(
            [pscustomobject]@{ ResourceId = '/subscriptions/s/resourceGroups/r/providers/Microsoft.Compute/virtualMachines/undated'; RetireOn = 'N/A' }
        ))
        $duplicate = @(ConvertTo-NormalizedMonitoringLifecycleRows -MonitoringRows @(
            [pscustomobject]@{ ResourceId = '/subscriptions/s/resourceGroups/r/providers/Microsoft.Compute/virtualMachines/duplicate'; RetireOn = 'N/A' }
            [pscustomobject]@{ ResourceId = '/subscriptions/s/resourceGroups/r/providers/Microsoft.Compute/virtualMachines/duplicate'; RetireOn = '2029-02-01' }
        ))

        $withDate[0].RetireOn | Should -Be '2029-01-15'
        $withoutDate[0].RetireOn | Should -Be 'N/A'
        $duplicate.Count | Should -Be 1
        $duplicate[0].RetireOn | Should -Be '2029-02-01'
    }

    It 'accepts Release Communications as the only available official source in strict mode' {
        $item = [pscustomobject]@{
            Title = 'NP-series retirement'; Description = 'Retires May 31, 2027.'
            Link = 'https://azure.microsoft.com/updates?id=np'; Categories = @('Compute')
            Availabilities = @([pscustomobject]@{ ring = 'Retirement'; year = 2027; month = 'May' })
        }

        {
            Get-Retirements -UseOfficialList $false -UsePortalSource $false -RequireLiveRetirementSource $true -ReleaseCommunicationItems @($item) -InventorySkuNames @('Standard_NP10s') -ReleaseCommunicationsOk $true
        } | Should -Not -Throw
    }

    It 'fails closed when strict mode has only a failed Advisor source' {
        Mock Search-AzGraph { throw 'simulated ARG outage' }

        {
            Get-Retirements `
                -UseOfficialList $false `
                -UsePortalSource $true `
                -Subscriptions @('sub-a') `
                -RequireLiveRetirementSource $true
        } | Should -Throw
    }

    It 'allows an Advisor-only partial-source run under the documented default policy' {
        $logPath = Join-Path $TestDrive 'partial-source.log'
        @(
            '[2026-07-13][INFO] STREAM A OK=True'
            '[2026-07-13][WARN] STREAM B failed: simulated outage'
        ) | Set-Content -LiteralPath $logPath

        $facts = [pscustomobject]@{
            Rows                      = @()
            RetailDeltaMonthly        = $null
            AdvisorConfirmed          = 0
            SkuFamily                 = 0
            RetireCount               = 0
            MonitoringDistinctVmCount = 0
            MonitoringRows            = @()
            CommitmentImpactCount     = 0
        }

        {
            Assert-DeliveryReady `
                -Facts $facts `
                -Rows @() `
                -RetirementSourceHealth ([pscustomobject]@{ Status = 'OK' }) `
                -RunLogPath $logPath
        } | Should -Not -Throw
    }
}

Describe 'Recommendation safety' {
    It 'retains an inventory row when the current SKU is missing from the catalog' {
        $catalog = @(
            New-TestCatalogEntry -Name 'Standard_X1_v5' -Family 'standardXFamily'
        )

        $rows = @(Build-Recommendations `
            -Inventory @(New-TestVm -Name 'vm-missing') `
            -Catalog $catalog `
            -PriceMap @{} `
            -CommitmentMap @{} `
            -FirstSeenMap @{} `
            -Retirements (New-EmptyRetirements))

        $rows.Count | Should -Be 1
        $rows[0].VmName | Should -Be 'vm-missing'
    }

    It 'recommends the smallest modern burstable upsize when B1s has no equivalent shape' {
        $current = New-TestCatalogEntry -Name 'Standard_B1s' -Family 'standardBSFamily'
        $current.Cap.vCPUs = '1'
        $current.Cap.MemoryGB = '1'
        $target = New-TestCatalogEntry -Name 'Standard_B2ts_v2' -Family 'standardBsv2Family'
        $target.Cap.vCPUs = '2'
        $target.Cap.MemoryGB = '1'
        $prices = @{
            'Standard_B1s|eastus'     = New-TestPrice -Sku 'Standard_B1s' -Price 0.0104
            'Standard_B2ts_v2|eastus' = New-TestPrice -Sku 'Standard_B2ts_v2' -Price 0.0110
        }

        $row = Build-Recommendations `
            -Inventory @(New-TestVm -Name 'vm-b1s' -Sku 'Standard_B1s') `
            -Catalog @($current, $target) `
            -PriceMap $prices `
            -CommitmentMap @{} `
            -FirstSeenMap @{} `
            -Retirements (New-EmptyRetirements) | Select-Object -First 1

        $row.CandidateTargetSku | Should -Be 'Standard_B2ts_v2'
        $row.RecommendationBasis | Should -Match 'burstable'
    }

    It 'selects the lowest-cost compatible candidate within the same family' {
        $current = New-TestCatalogEntry -Name 'Standard_D2s_v3' -Family 'standardDSFamily'
        $cheaperTarget = New-TestCatalogEntry -Name 'Standard_D2s_v4' -Family 'standardDSFamily'
        $newerTarget = New-TestCatalogEntry -Name 'Standard_D2s_v5' -Family 'standardDSFamily'
        $cheapestCrossFamily = New-TestCatalogEntry -Name 'Standard_B2s_v2' -Family 'standardBSFamily'
        $prices = @{
            'Standard_D2s_v3|eastus' = New-TestPrice -Sku 'Standard_D2s_v3' -Price 1.00
            'Standard_D2s_v4|eastus' = New-TestPrice -Sku 'Standard_D2s_v4' -Price 0.70
            'Standard_D2s_v5|eastus' = New-TestPrice -Sku 'Standard_D2s_v5' -Price 0.80
            'Standard_B2s_v2|eastus' = New-TestPrice -Sku 'Standard_B2s_v2' -Price 0.50
        }

        $row = Build-Recommendations `
            -Inventory @(New-TestVm -Name 'vm-same-family-cost' -Sku 'Standard_D2s_v3') `
            -Catalog @($current, $newerTarget, $cheaperTarget, $cheapestCrossFamily) `
            -PriceMap $prices -CommitmentMap @{} -FirstSeenMap @{} `
            -Retirements (New-EmptyRetirements) | Select-Object -First 1

        $row.CandidateTargetSku | Should -Be 'Standard_D2s_v4'
        $row.RecommendationBasis | Should -Match 'same family'
        $row.CandidateEquivalenceStatus | Should -Be 'Equivalent'
        $row.CandidateEquivalenceDetails | Should -Be '100% match on compared SKU capabilities'
        $row.CandidateSelectionReason | Should -Match 'Same commercial family D; lowest Retail price'
    }

    It 'uses the SKU name as a stable tie-break regardless of catalog order' {
        $current = New-TestCatalogEntry -Name 'Standard_D2s_v3' -Family 'standardDSFamily'
        $targetB = New-TestCatalogEntry -Name 'Standard_D2as_v5' -Family 'standardDSFamily'
        $targetA = New-TestCatalogEntry -Name 'Standard_D2ams_v5' -Family 'standardDSFamily'
        $prices = @{
            'Standard_D2s_v3|eastus'  = New-TestPrice -Sku 'Standard_D2s_v3' -Price 1.00
            'Standard_D2ams_v5|eastus' = New-TestPrice -Sku 'Standard_D2ams_v5' -Price 0.80
            'Standard_D2as_v5|eastus'  = New-TestPrice -Sku 'Standard_D2as_v5' -Price 0.80
        }

        $targets = foreach ($catalog in @(@($current, $targetB, $targetA), @($current, $targetA, $targetB))) {
            Build-Recommendations `
                -Inventory @(New-TestVm -Name 'vm-deterministic' -Sku 'Standard_D2s_v3') `
                -Catalog $catalog -PriceMap $prices -CommitmentMap @{} -FirstSeenMap @{} `
                -Retirements (New-EmptyRetirements) | Select-Object -ExpandProperty CandidateTargetSku -First 1
        }

        @($targets | Select-Object -Unique).Count | Should -Be 1
        $targets[0] | Should -Be 'Standard_D2ams_v5'
    }

    It 'produces byte-identical target mappings when run twice with the same input' {
        $current = New-TestCatalogEntry -Name 'Standard_D2s_v3' -Family 'standardDSFamily'
        $targetA = New-TestCatalogEntry -Name 'Standard_D2ams_v5' -Family 'standardDSFamily'
        $targetB = New-TestCatalogEntry -Name 'Standard_D2as_v5' -Family 'standardDSFamily'
        $inventory = @(
            New-TestVm -Name 'vm-deterministic-1' -Sku 'Standard_D2s_v3'
            New-TestVm -Name 'vm-deterministic-2' -Sku 'Standard_D2s_v3'
        )
        $prices = @{
            'Standard_D2s_v3|eastus'  = New-TestPrice -Sku 'Standard_D2s_v3' -Price 1.00
            'Standard_D2ams_v5|eastus' = New-TestPrice -Sku 'Standard_D2ams_v5' -Price 0.80
            'Standard_D2as_v5|eastus'  = New-TestPrice -Sku 'Standard_D2as_v5' -Price 0.80
        }

        $outputs = 1..2 | ForEach-Object {
            @(Build-Recommendations `
                    -Inventory $inventory -Catalog @($current, $targetB, $targetA) `
                    -PriceMap $prices -CommitmentMap @{} -FirstSeenMap @{} `
                    -Retirements (New-EmptyRetirements) |
                    Sort-Object VmName |
                    Select-Object VmName, CandidateTargetSku |
                    ConvertTo-Json -Compress)
        }

        $outputs[0] | Should -BeExactly $outputs[1]
    }

    It 'prefers B over an exact-shape F target for a retiring basic A-family VM and routes the move to W3' {
        $current = New-TestCatalogEntry -Name 'Standard_A1_v2' -Family 'standardAv2Family'
        $current.Cap.vCPUs = '1'
        $current.Cap.MemoryGB = '2'
        $exactShape = New-TestCatalogEntry -Name 'Standard_F1als_v7' -Family 'standardFalsv7Family'
        $exactShape.Cap.vCPUs = '1'
        $exactShape.Cap.MemoryGB = '2'
        $generalPurposeUpsize = New-TestCatalogEntry -Name 'Standard_B2als_v2' -Family 'standardBalsv2Family'
        $generalPurposeUpsize.Cap.vCPUs = '2'
        $generalPurposeUpsize.Cap.MemoryGB = '4'
        $retirements = New-EmptyRetirements
        $retirements.Exact['standard_a1_v2'] = [pscustomobject]@{
            Status = 'Announced'; RetireOn = '2028-11-15'; Source = 'LiveLearnMarkdown'; SeriesName = 'Av2-series'
        }

        $row = Build-Recommendations `
            -Inventory @(New-TestVm -Name 'vm-shape-first' -Sku 'Standard_A1_v2') `
            -Catalog @($current, $generalPurposeUpsize, $exactShape) `
            -PriceMap @{} -CommitmentMap @{} -FirstSeenMap @{} `
            -Retirements $retirements | Select-Object -First 1

        $row.CandidateTargetSku | Should -Be 'Standard_B2als_v2'
        $row.CandidateSelectionReason | Should -Match 'Basic-family affinity A -> B'
        $row.CandidateEquivalenceDetails | Should -Match 'workload profile: General purpose -> Burstable general purpose'

        $planRow = [pscustomobject]@{
            VmName = $row.VmName; CurrentSku = $row.CurrentSku; CandidateTargetSku = $row.CandidateTargetSku
            Region = $row.Region; RetirementDate = '2028-11-15'; RetirementRiskLevel = 'Medium'
            RetirementSourceGate = 'LiveLearnMarkdown'; EvidenceSource = 'LiveLearnMarkdown'
            SensitiveWorkload = $false; GenerationChange = $true; CommitmentRetirementImpact = $false
        }
        $plan = Build-RemediationPlan -Rows @($planRow)

        @($plan.Waves[3].Items).Count | Should -Be 1
        $plan.Waves[3].Items[0].VmName | Should -Be 'vm-shape-first'
    }

    It 'uses D as the second A-family successor when B fails the cost gate' {
        $current = New-TestCatalogEntry -Name 'Standard_A1_v2' -Family 'standardAv2Family'
        $current.Cap.vCPUs = '1'
        $current.Cap.MemoryGB = '2'
        $bTarget = New-TestCatalogEntry -Name 'Standard_B2als_v2' -Family 'standardBalsv2Family'
        $bTarget.Cap.vCPUs = '2'
        $bTarget.Cap.MemoryGB = '4'
        $dTarget = New-TestCatalogEntry -Name 'Standard_D2ls_v5' -Family 'standardDlsv5Family'
        $dTarget.Cap.vCPUs = '2'
        $dTarget.Cap.MemoryGB = '4'
        $fTarget = New-TestCatalogEntry -Name 'Standard_F1als_v7' -Family 'standardFalsv7Family'
        $fTarget.Cap.vCPUs = '1'
        $fTarget.Cap.MemoryGB = '2'
        $retirements = New-EmptyRetirements
        $retirements.Exact['standard_a1_v2'] = [pscustomobject]@{
            Status = 'Announced'; RetireOn = '2028-11-15'; Source = 'LiveLearnMarkdown'; SeriesName = 'Av2-series'
        }
        $prices = @{
            'Standard_A1_v2|eastus'   = New-TestPrice -Sku 'Standard_A1_v2' -Price 1.00
            'Standard_B2als_v2|eastus' = New-TestPrice -Sku 'Standard_B2als_v2' -Price 1.50
            'Standard_D2ls_v5|eastus'  = New-TestPrice -Sku 'Standard_D2ls_v5' -Price 1.10
            'Standard_F1als_v7|eastus' = New-TestPrice -Sku 'Standard_F1als_v7' -Price 1.05
        }

        $row = Build-Recommendations `
            -Inventory @(New-TestVm -Name 'vm-a-to-d' -Sku 'Standard_A1_v2') `
            -Catalog @($current, $fTarget, $dTarget, $bTarget) `
            -PriceMap $prices -CommitmentMap @{} -FirstSeenMap @{} `
            -Retirements $retirements | Select-Object -First 1

        $row.CandidateTargetSku | Should -Be 'Standard_D2ls_v5'
        $row.CandidateSelectionReason | Should -Match 'Basic-family affinity A -> D'
    }

    It 'uses the generic fallback when both preferred A-family successors fail hard gates' {
        $current = New-TestCatalogEntry -Name 'Standard_A1_v2' -Family 'standardAv2Family'
        $current.Cap.vCPUs = '1'
        $current.Cap.MemoryGB = '2'
        $blockedB = New-TestCatalogEntry -Name 'Standard_B2als_v2' -Family 'standardBalsv2Family' -Restrictions @(
            [pscustomobject]@{ type = 'Location'; values = @('eastus'); reasonCode = 'NotAvailableForSubscription' }
        )
        $blockedB.Cap.vCPUs = '2'
        $blockedB.Cap.MemoryGB = '4'
        $blockedD = New-TestCatalogEntry -Name 'Standard_D2ls_v5' -Family 'standardDlsv5Family' -Restrictions @(
            [pscustomobject]@{ type = 'Location'; values = @('eastus'); reasonCode = 'NotAvailableForSubscription' }
        )
        $blockedD.Cap.vCPUs = '2'
        $blockedD.Cap.MemoryGB = '4'
        $genericTarget = New-TestCatalogEntry -Name 'Standard_F1als_v7' -Family 'standardFalsv7Family'
        $genericTarget.Cap.vCPUs = '1'
        $genericTarget.Cap.MemoryGB = '2'
        $retirements = New-EmptyRetirements
        $retirements.Exact['standard_a1_v2'] = [pscustomobject]@{
            Status = 'Announced'; RetireOn = '2028-11-15'; Source = 'LiveLearnMarkdown'; SeriesName = 'Av2-series'
        }

        $row = Build-Recommendations `
            -Inventory @(New-TestVm -Name 'vm-a-generic-fallback' -Sku 'Standard_A1_v2') `
            -Catalog @($current, $blockedB, $blockedD, $genericTarget) `
            -PriceMap @{} -CommitmentMap @{} -FirstSeenMap @{} `
            -Retirements $retirements -MinPerfRatio 0.95 | Select-Object -First 1

        $row.CandidateTargetSku | Should -Be 'Standard_F1als_v7'
        $row.RecommendationBasis | Should -Match 'cross-family migration'
    }

    It 'prefers an Intel target for an Intel VM when the AMD twin is not cheaper' {
        $current = New-TestCatalogEntry -Name 'Standard_B1s' -Family 'standardBSFamily'
        $current.Cap.vCPUs = '1'
        $current.Cap.MemoryGB = '1'
        $intelTarget = New-TestCatalogEntry -Name 'Standard_B2ts_v2' -Family 'standardBsv2Family'
        $intelTarget.Cap.vCPUs = '2'
        $intelTarget.Cap.MemoryGB = '1'
        $amdTarget = New-TestCatalogEntry -Name 'Standard_B2ats_v2' -Family 'standardBasv2Family'
        $amdTarget.Cap.vCPUs = '2'
        $amdTarget.Cap.MemoryGB = '1'
        $prices = @{
            'Standard_B1s|eastus'      = New-TestPrice -Sku 'Standard_B1s' -Price 0.0100
            'Standard_B2ts_v2|eastus'  = New-TestPrice -Sku 'Standard_B2ts_v2' -Price 0.0110
            'Standard_B2ats_v2|eastus' = New-TestPrice -Sku 'Standard_B2ats_v2' -Price 0.0110
        }

        $row = Build-Recommendations `
            -Inventory @(New-TestVm -Name 'vm-intel' -Sku 'Standard_B1s') `
            -Catalog @($current, $amdTarget, $intelTarget) `
            -PriceMap $prices `
            -CommitmentMap @{} `
            -FirstSeenMap @{} `
            -Retirements (New-EmptyRetirements) | Select-Object -First 1

        $row.CandidateTargetSku | Should -Be 'Standard_B2ts_v2'
        $row.CurrentCpuVendor | Should -Be 'Intel'
        $row.TargetCpuVendor | Should -Be 'Intel'
        $row.CpuVendorChange | Should -BeFalse
    }

    It 'allows a cheaper AMD target and explains the price-driven vendor change' {
        $current = New-TestCatalogEntry -Name 'Standard_B1s' -Family 'standardBSFamily'
        $current.Cap.vCPUs = '1'
        $current.Cap.MemoryGB = '1'
        $intelTarget = New-TestCatalogEntry -Name 'Standard_B2ts_v2' -Family 'standardBsv2Family'
        $intelTarget.Cap.vCPUs = '2'
        $intelTarget.Cap.MemoryGB = '1'
        $amdTarget = New-TestCatalogEntry -Name 'Standard_B2ats_v2' -Family 'standardBasv2Family'
        $amdTarget.Cap.vCPUs = '2'
        $amdTarget.Cap.MemoryGB = '1'
        $prices = @{
            'Standard_B1s|eastus'      = New-TestPrice -Sku 'Standard_B1s' -Price 0.0100
            'Standard_B2ts_v2|eastus'  = New-TestPrice -Sku 'Standard_B2ts_v2' -Price 0.0110
            'Standard_B2ats_v2|eastus' = New-TestPrice -Sku 'Standard_B2ats_v2' -Price 0.0105
        }

        $row = Build-Recommendations `
            -Inventory @(New-TestVm -Name 'vm-price' -Sku 'Standard_B1s') `
            -Catalog @($current, $intelTarget, $amdTarget) `
            -PriceMap $prices `
            -CommitmentMap @{} `
            -FirstSeenMap @{} `
            -Retirements (New-EmptyRetirements) | Select-Object -First 1

        $row.CandidateTargetSku | Should -Be 'Standard_B2ats_v2'
        $row.CurrentCpuVendor | Should -Be 'Intel'
        $row.TargetCpuVendor | Should -Be 'AMD'
        $row.CpuVendorChange | Should -BeTrue
        $row.CpuVendorChangeReason | Should -Be 'LowerRetailPrice'
        $row.Recommendation | Should -Match 'Intel -> AMD.*lower retail price'
    }

    It 'allows an AMD target when no compatible Intel alternative exists' {
        $current = New-TestCatalogEntry -Name 'Standard_B1s' -Family 'standardBSFamily'
        $current.Cap.vCPUs = '1'
        $current.Cap.MemoryGB = '1'
        $amdTarget = New-TestCatalogEntry -Name 'Standard_B2ats_v2' -Family 'standardBasv2Family'
        $amdTarget.Cap.vCPUs = '2'
        $amdTarget.Cap.MemoryGB = '1'

        $row = Build-Recommendations `
            -Inventory @(New-TestVm -Name 'vm-amd-only' -Sku 'Standard_B1s') `
            -Catalog @($current, $amdTarget) `
            -PriceMap @{} `
            -CommitmentMap @{} `
            -FirstSeenMap @{} `
            -Retirements (New-EmptyRetirements) | Select-Object -First 1

        $row.CandidateTargetSku | Should -Be 'Standard_B2ats_v2'
        $row.CpuVendorChangeReason | Should -Be 'NoSameVendorAlternative'
        $row.Recommendation | Should -Match 'no compatible same-vendor alternative'
    }

    It 'handles one same-vendor candidate under strict mode' {
        $current = New-TestCatalogEntry -Name 'Standard_D2_v2' -Family 'standardDv2Family'
        $target = New-TestCatalogEntry -Name 'Standard_D2s_v5' -Family 'standardDsv5Family'

        $row = & {
            Set-StrictMode -Version Latest
            Build-Recommendations `
                -Inventory @(New-TestVm -Name 'vm-single-vendor') `
                -Catalog @($current, $target) `
                -PriceMap @{} `
                -CommitmentMap @{} `
                -FirstSeenMap @{} `
                -Retirements (New-EmptyRetirements) | Select-Object -First 1
        }

        $row.CandidateTargetSku | Should -Be 'Standard_D2s_v5'
        $row.CurrentCpuVendor | Should -Be 'Intel'
        $row.TargetCpuVendor | Should -Be 'Intel'
    }

    It 'never proposes ARM for an x64 VM even when architecture changes are enabled' {
        $current = New-TestCatalogEntry -Name 'Standard_B1s' -Family 'standardBSFamily'
        $current.Cap.vCPUs = '1'
        $current.Cap.MemoryGB = '1'
        $armTarget = New-TestCatalogEntry -Name 'Standard_B2ps_v2' -Family 'standardBpsv2Family'
        $armTarget.Cap.vCPUs = '2'
        $armTarget.Cap.MemoryGB = '1'
        $armTarget.Cap.CpuArchitectureType = 'Arm64'

        $row = Build-Recommendations `
            -Inventory @(New-TestVm -Name 'vm-x64' -Sku 'Standard_B1s') `
            -Catalog @($current, $armTarget) `
            -PriceMap @{} `
            -CommitmentMap @{} `
            -FirstSeenMap @{} `
            -Retirements (New-EmptyRetirements) `
            -AllowArchChange | Select-Object -First 1

        $row.CandidateTargetSku | Should -Be 'N/A'
    }

    It 'applies the configured cost ceiling to fallback candidates' {
        $catalog = @(
            New-TestCatalogEntry -Name 'Standard_D2_v2' -Family 'standardDv2Family'
            New-TestCatalogEntry -Name 'Standard_E2s_v5' -Family 'standardESv5Family'
        )
        $prices = @{
            'Standard_D2_v2|eastus'  = New-TestPrice -Sku 'Standard_D2_v2' -Price 1.0
            'Standard_E2s_v5|eastus' = New-TestPrice -Sku 'Standard_E2s_v5' -Price 2.0
        }

        $row = Build-Recommendations `
            -Inventory @(New-TestVm -Name 'vm-cap') `
            -Catalog $catalog `
            -PriceMap $prices `
            -CommitmentMap @{} `
            -FirstSeenMap @{} `
            -Retirements (New-EmptyRetirements) `
            -MaxCostIncreasePercent 20 | Select-Object -First 1

        $row.CandidateTargetSku | Should -Be 'N/A'
    }

    It 'provides a cross-family AMD upsize when a retiring Intel SKU has no equivalent alternative' {
        $current = New-TestCatalogEntry -Name 'Standard_A1_v2' -Family 'standardAv2Family'
        $current.Cap.vCPUs = '1'
        $current.Cap.MemoryGB = '2'
        $current.Cap.PremiumIO = 'False'
        $current.Cap.AcceleratedNetworkingEnabled = 'False'
        $target = New-TestCatalogEntry -Name 'Standard_D2as_v7' -Family 'standardDasv7Family'
        $target.Cap.Remove('ACUs')
        $retirements = New-EmptyRetirements
        $retirements.Exact['standard_a1_v2'] = [pscustomobject]@{
            Status = 'Announced'; RetireOn = '2028-11-15'; Source = 'LiveLearnMarkdown'; SeriesName = 'Av2-series'
        }

        $row = Build-Recommendations `
            -Inventory @(New-TestVm -Name 'vm-retiring-a1' -Sku 'Standard_A1_v2') `
            -Catalog @($current, $target) `
            -PriceMap @{} `
            -CommitmentMap @{} `
            -FirstSeenMap @{} `
            -Retirements $retirements | Select-Object -First 1

        $row.CandidateTargetSku | Should -Be 'Standard_D2as_v7'
        $row.RecommendationBasis | Should -Match 'Retirement fallback'
        $row.CurrentCpuVendor | Should -Be 'Intel'
        $row.TargetCpuVendor | Should -Be 'AMD'
        $row.CpuVendorChange | Should -BeTrue
    }

    It 'flags an A-to-F candidate as a workload-profile and CPU-vendor change' {
        $current = New-TestCatalogEntry -Name 'Standard_A1_v2' -Family 'standardAv2Family'
        $target = New-TestCatalogEntry -Name 'Standard_F1als_v7' -Family 'standardFalsv7Family'
        $current.Cap.vCPUs = '1'
        $current.Cap.MemoryGB = '2'
        $target.Cap.vCPUs = '1'
        $target.Cap.MemoryGB = '2'

        $result = Get-CandidateEquivalenceResult `
            -CurrentCap $current.Cap -CandidateCap $target.Cap `
            -CurrentSkuName $current.Name -CandidateSkuName $target.Name

        $result.Status | Should -Be 'NotEquivalent'
        $result.Summary | Should -Match 'workload profile: General purpose -> Compute optimized'
        $result.Summary | Should -Match 'CPU vendor: Intel -> AMD'
    }

    It 'reports explicit impossibility when a retiring SKU has no candidate that passes hard safety gates' {
        $current = New-TestCatalogEntry -Name 'Standard_A1_v2' -Family 'standardAv2Family'
        $current.Cap.vCPUs = '1'
        $current.Cap.MemoryGB = '2'
        $armTarget = New-TestCatalogEntry -Name 'Standard_D2ps_v6' -Family 'standardDpsv6Family'
        $armTarget.Cap.CpuArchitectureType = 'Arm64'
        $retirements = New-EmptyRetirements
        $retirements.Exact['standard_a1_v2'] = [pscustomobject]@{
            Status = 'Announced'; RetireOn = '2028-11-15'; Source = 'LiveLearnMarkdown'; SeriesName = 'Av2-series'
        }

        $row = Build-Recommendations `
            -Inventory @(New-TestVm -Name 'vm-impossible-a1' -Sku 'Standard_A1_v2') `
            -Catalog @($current, $armTarget) `
            -PriceMap @{} `
            -CommitmentMap @{} `
            -FirstSeenMap @{} `
            -Retirements $retirements | Select-Object -First 1

        $row.CandidateTargetSku | Should -Be 'N/A'
        $row.RecommendationBasis | Should -Be 'No compatible non-retiring alternative passed hard safety gates'
    }

    It 'does not recommend a target that is itself on a retirement path' {
        $current = New-TestCatalogEntry -Name 'Standard_A1_v2' -Family 'standardAv2Family'
        $current.Cap.vCPUs = '1'
        $current.Cap.MemoryGB = '2'
        $current.Cap.PremiumIO = 'False'
        $current.Cap.AcceleratedNetworkingEnabled = 'False'
        $retiringTarget = New-TestCatalogEntry -Name 'Standard_D2as_v7' -Family 'standardDasv7Family'
        $safeTarget = New-TestCatalogEntry -Name 'Standard_E2as_v7' -Family 'standardEasv7Family'
        $retirements = New-EmptyRetirements
        $retirements.Exact['standard_a1_v2'] = [pscustomobject]@{ Status = 'Announced'; RetireOn = '2028-11-15'; Source = 'LiveLearnMarkdown' }
        $retirements.Exact['standard_d2as_v7'] = [pscustomobject]@{ Status = 'Announced'; RetireOn = '2029-01-01'; Source = 'LiveLearnMarkdown' }

        $row = Build-Recommendations `
            -Inventory @(New-TestVm -Name 'vm-retiring-target' -Sku 'Standard_A1_v2') `
            -Catalog @($current, $retiringTarget, $safeTarget) `
            -PriceMap @{} `
            -CommitmentMap @{} `
            -FirstSeenMap @{} `
            -Retirements $retirements | Select-Object -First 1

        $row.CandidateTargetSku | Should -Be 'Standard_E2as_v7'
    }

    It 'maintains 100 percent recommended-alternative coverage for retiring SKUs when hard-compatible targets exist' {
        $a1 = New-TestCatalogEntry -Name 'Standard_A1_v2' -Family 'standardAv2Family'
        $a1.Cap.vCPUs = '1'
        $a1.Cap.MemoryGB = '2'
        $a1.Cap.PremiumIO = 'False'
        $a1.Cap.AcceleratedNetworkingEnabled = 'False'
        $f2 = New-TestCatalogEntry -Name 'Standard_F2' -Family 'standardFFamily'
        $d2as = New-TestCatalogEntry -Name 'Standard_D2as_v7' -Family 'standardDasv7Family'
        $f2als = New-TestCatalogEntry -Name 'Standard_F2als_v7' -Family 'standardFalsv7Family'
        $retirements = New-EmptyRetirements
        $retirements.Exact['standard_a1_v2'] = [pscustomobject]@{ Status = 'Announced'; RetireOn = '2028-11-15'; Source = 'LiveLearnMarkdown' }
        $retirements.Exact['standard_f2'] = [pscustomobject]@{ Status = 'Announced'; RetireOn = '2028-11-15'; Source = 'LiveLearnMarkdown' }
        $retirements.Series = @(
            [pscustomobject]@{ SeriesName = 'Av2/Amv2-series'; Status = 'Announced'; RetireOn = '2028-11-15'; Source = 'LiveLearnMarkdown'; SourceGate = 'LiveLearnMarkdown'; SourceUrl = 'https://learn.microsoft.com/'; AsOf = '2026-07-15'; MigrationGuide = ''; Announcement = '' }
            [pscustomobject]@{ SeriesName = 'F-series'; Status = 'Announced'; RetireOn = '2028-11-15'; Source = 'LiveLearnMarkdown'; SourceGate = 'LiveLearnMarkdown'; SourceUrl = 'https://learn.microsoft.com/'; AsOf = '2026-07-15'; MigrationGuide = ''; Announcement = '' }
        )

        $rows = @(Build-Recommendations `
            -Inventory @(
                (New-TestVm -Name 'vm-retiring-a1-all' -Sku 'Standard_A1_v2'),
                (New-TestVm -Name 'vm-retiring-f2-all' -Sku 'Standard_F2')
            ) `
            -Catalog @($a1, $f2, $d2as, $f2als) `
            -PriceMap @{} `
            -CommitmentMap @{} `
            -FirstSeenMap @{} `
            -Retirements $retirements)

        $retirementRows = @($rows | Where-Object RetirementSourceGate -in @('LiveLearnMarkdown', 'ReleaseCommunicationsApi', 'LiveAdvisorArg'))
        $recommendedRows = @($retirementRows | Where-Object { $_.CandidateTargetSku -and $_.CandidateTargetSku -ne 'N/A' })
        $coveragePercent = if ($retirementRows.Count -gt 0) {
            [math]::Round(($recommendedRows.Count / $retirementRows.Count) * 100, 2)
        }
        else { 0 }
        $facts = Build-ReportFacts -Rows $rows

        $retirementRows.Count | Should -Be 2
        $coveragePercent | Should -Be 100 -Because 'every retirement-path SKU with a hard-compatible catalog target must receive an alternative'
        $recommendedRows.Count | Should -Be $retirementRows.Count
        $facts.RecommendationWithheldCount | Should -Be 0
        ($facts.SkuChangeWithGenChange + $facts.SkuChangeWithoutGenChange) | Should -Be $facts.RetireCount
        @($rows | Where-Object { $_.CandidateTargetSku -in @('Standard_A1_v2', 'Standard_F2') }).Count | Should -Be 0
    }

    It 'applies the configured performance floor to same-shape fallback candidates' {
        $current = New-TestCatalogEntry -Name 'Standard_D2_v2' -Family 'standardDv2Family'
        $target = New-TestCatalogEntry -Name 'Standard_D2_v5' -Family 'standardDv5Family'
        $current.Cap.ACUs = '100'
        $target.Cap.ACUs = '80'

        $row = Build-Recommendations `
            -Inventory @(New-TestVm -Name 'vm-perf-floor') `
            -Catalog @($current, $target) `
            -PriceMap @{} `
            -CommitmentMap @{} `
            -FirstSeenMap @{} `
            -Retirements (New-EmptyRetirements) `
            -MinPerfRatio 0.95 | Select-Object -First 1

        $row.CandidateTargetSku | Should -Be 'N/A'
    }

    It 'applies the configured performance floor to burstable fallback candidates' {
        $current = New-TestCatalogEntry -Name 'Standard_B1s' -Family 'standardBSFamily'
        $current.Cap.vCPUs = '1'
        $current.Cap.MemoryGB = '1'
        $current.Cap.ACUs = '100'
        $target = New-TestCatalogEntry -Name 'Standard_B2ts_v2' -Family 'standardBsv2Family'
        $target.Cap.vCPUs = '2'
        $target.Cap.MemoryGB = '1'
        $target.Cap.ACUs = '40'

        $row = Build-Recommendations `
            -Inventory @(New-TestVm -Name 'vm-burst-perf-floor' -Sku 'Standard_B1s') `
            -Catalog @($current, $target) `
            -PriceMap @{} `
            -CommitmentMap @{} `
            -FirstSeenMap @{} `
            -Retirements (New-EmptyRetirements) `
            -MinPerfRatio 0.95 | Select-Object -First 1

        $row.CandidateTargetSku | Should -Be 'N/A'
    }

    It 'applies the configured performance floor to cross-family fallback candidates' {
        $current = New-TestCatalogEntry -Name 'Standard_D2_v2' -Family 'standardDv2Family'
        $target = New-TestCatalogEntry -Name 'Standard_E2s_v5' -Family 'standardESv5Family'
        $current.Cap.ACUs = '100'
        $target.Cap.ACUs = '80'

        $row = Build-Recommendations `
            -Inventory @(New-TestVm -Name 'vm-cross-perf-floor') `
            -Catalog @($current, $target) `
            -PriceMap @{} `
            -CommitmentMap @{} `
            -FirstSeenMap @{} `
            -Retirements (New-EmptyRetirements) `
            -MinPerfRatio 0.95 | Select-Object -First 1

        $row.CandidateTargetSku | Should -Be 'N/A'
    }

    It 'compares fallback performance with one model when ACU metadata exists on only one SKU' {
        $current = New-TestCatalogEntry -Name 'Standard_F2' -Family 'standardFFamily'
        $target = New-TestCatalogEntry -Name 'Standard_F2als_v7' -Family 'standardFalsv7Family'
        $current.Cap.ACUs = '100'
        $target.Cap.Remove('ACUs')
        $current.Cap.HyperVGenerations = 'V1,V2'
        $target.Cap.HyperVGenerations = 'V2'

        $row = Build-Recommendations `
            -Inventory @(New-TestVm -Name 'vm-mixed-perf-model' -Sku 'Standard_F2') `
            -Catalog @($current, $target) `
            -PriceMap @{} `
            -CommitmentMap @{} `
            -FirstSeenMap @{} `
            -Retirements (New-EmptyRetirements) `
            -MinPerfRatio 0.95 | Select-Object -First 1

        $row.CandidateTargetSku | Should -Be 'Standard_F2als_v7'
        $row.PerfModelCurrent | Should -Be $row.PerfModelTarget
        $row.PerfDeltaPercent | Should -BeGreaterOrEqual 0
        $row.GenerationChange | Should -BeTrue
    }

    It 'retains the DS2 v2 to D2ads v7 same-family candidate when performance models differ' {
        $current = New-TestCatalogEntry -Name 'Standard_DS2_v2' -Family 'standardDSv2Family'
        $target = New-TestCatalogEntry -Name 'Standard_D2ads_v7' -Family 'standardDadsv7Family'
        $current.Cap.ACUs = '100'
        $target.Cap.Remove('ACUs')
        $current.Cap.HyperVGenerations = 'V1,V2'
        $target.Cap.HyperVGenerations = 'V2'

        $row = Build-Recommendations `
            -Inventory @(New-TestVm -Name 'vm-ds2-regression' -Sku 'Standard_DS2_v2') `
            -Catalog @($current, $target) `
            -PriceMap @{} `
            -CommitmentMap @{} `
            -FirstSeenMap @{} `
            -Retirements (New-EmptyRetirements) `
            -MinPerfRatio 0.95 | Select-Object -First 1

        $row.CandidateTargetSku | Should -Be 'Standard_D2ads_v7'
        $row.RecommendationBasis | Should -Match 'same family'
        $row.PerfModelCurrent | Should -Be $row.PerfModelTarget
        $row.PerfDeltaPercent | Should -BeGreaterOrEqual 0
        $row.GenerationChange | Should -BeTrue
    }

    It 'selects the cheaper candidate when local storage differs and emits a warning' {
        $current = New-TestCatalogEntry -Name 'Standard_DS2_v2' -Family 'standardDSv2Family'
        $current.Cap.MaxResourceVolumeMB = '14336'
        $current.Cap.CachedDiskBytes = '92341796864'
        $current.Cap.MaxDataDiskCount = '8'
        $current.Cap.MaxNetworkInterfaces = '4'
        $noLocalDisk = New-TestCatalogEntry -Name 'Standard_D2as_v7' -Family 'standardDasv7Family'
        $noLocalDisk.Cap.MaxResourceVolumeMB = '0'
        $noLocalDisk.Cap.EphemeralOSDiskSupported = 'False'
        $noLocalDisk.Cap.MaxDataDiskCount = '4'
        $noLocalDisk.Cap.MaxNetworkInterfaces = '2'
        $localNvme = New-TestCatalogEntry -Name 'Standard_D2ads_v7' -Family 'standardDadsv7Family'
        $localNvme.Cap.MaxResourceVolumeMB = '0'
        $localNvme.Cap.NvmeDiskSizeInMiB = '112640'
        $localNvme.Cap.EphemeralOSDiskSupported = 'True'
        $prices = @{
            'Standard_DS2_v2|eastus'  = New-TestPrice -Sku 'Standard_DS2_v2' -Price 1.00
            'Standard_D2as_v7|eastus' = New-TestPrice -Sku 'Standard_D2as_v7' -Price 0.50
            'Standard_D2ads_v7|eastus' = New-TestPrice -Sku 'Standard_D2ads_v7' -Price 0.90
        }

        $row = Build-Recommendations `
            -Inventory @(New-TestVm -Name 'vm-local-storage-parity' -Sku 'Standard_DS2_v2') `
            -Catalog @($current, $noLocalDisk, $localNvme) `
            -PriceMap $prices `
            -CommitmentMap @{} `
            -FirstSeenMap @{} `
            -Retirements (New-EmptyRetirements) | Select-Object -First 1

        $row.CandidateTargetSku | Should -Be 'Standard_D2as_v7'
        $row.RetailDeltaMonthly | Should -Be -365
        $row.CostDeltaPercent | Should -Be -50
        $row.ValidationChecklist | Should -Match 'Warning check: target has no temporary/local disk'
        $row.ValidationChecklist | Should -Match 'maximum data disks decrease from 8 to 4'
        $row.ValidationChecklist | Should -Match 'maximum NICs decrease from 4 to 2'
        $row.MigrationRisksAndBlocks | Should -Match 'Warning check: target has no temporary/local disk'
        $row.CandidateEquivalenceStatus | Should -Be 'NotEquivalent'
        $row.CandidateEquivalenceDetails | Should -Match 'maximum data disks: 8 -> 4'
        $row.CandidateEquivalenceDetails | Should -Match 'maximum NICs: 4 -> 2'
        $row.CandidateEquivalenceDetails | Should -Match 'temporary/local storage: Resource/cache disk -> None'
        $row.CandidateSelectionReason | Should -Match 'Same commercial family D; lowest Retail price'
    }

    It 'publishes a saving with a warning when the only candidate loses local temporary storage' {
        $current = New-TestCatalogEntry -Name 'Standard_DS2_v2' -Family 'standardDSv2Family'
        $current.Cap.MaxResourceVolumeMB = '14336'
        $noLocalDisk = New-TestCatalogEntry -Name 'Standard_D2as_v7' -Family 'standardDasv7Family'
        $noLocalDisk.Cap.MaxResourceVolumeMB = '0'
        $noLocalDisk.Cap.EphemeralOSDiskSupported = 'False'
        $prices = @{
            'Standard_DS2_v2|eastus'  = New-TestPrice -Sku 'Standard_DS2_v2' -Price 1.00
            'Standard_D2as_v7|eastus' = New-TestPrice -Sku 'Standard_D2as_v7' -Price 0.50
        }

        $row = Build-Recommendations `
            -Inventory @(New-TestVm -Name 'vm-local-storage-impossible' -Sku 'Standard_DS2_v2') `
            -Catalog @($current, $noLocalDisk) `
            -PriceMap $prices `
            -CommitmentMap @{} `
            -FirstSeenMap @{} `
            -Retirements (New-EmptyRetirements) | Select-Object -First 1

        $row.CandidateTargetSku | Should -Be 'Standard_D2as_v7'
        $row.RetailDeltaMonthly | Should -Be -365
        $row.CostDeltaPercent | Should -Be -50
        $row.ValidationChecklist | Should -Match 'Warning check: target has no temporary/local disk'
    }

    It 'ranks cross-family cost after CPU and memory proximity' {
        $current = New-TestCatalogEntry -Name 'Standard_B4ms' -Family 'standardBSFamily'
        $current.Cap.vCPUs = '4'
        $current.Cap.MemoryGB = '16'
        $current.Cap.MaxDataDiskCount = '8'
        $current.Cap.MaxNetworkInterfaces = '4'
        $current.Cap.MaxResourceVolumeMB = '32768'
        $minimumVcpuTarget = New-TestCatalogEntry -Name 'Standard_F4amds_v7' -Family 'standardFamdsv7Family'
        $minimumVcpuTarget.Cap.vCPUs = '4'
        $minimumVcpuTarget.Cap.MemoryGB = '32'
        $minimumVcpuTarget.Cap.MaxDataDiskCount = '8'
        $minimumVcpuTarget.Cap.MaxNetworkInterfaces = '4'
        $minimumVcpuTarget.Cap.NvmeDiskSizeInMiB = '225280'
        $oversizedCheaperTarget = New-TestCatalogEntry -Name 'Standard_D8lds_v6' -Family 'standardDldsv6Family'
        $oversizedCheaperTarget.Cap.vCPUs = '8'
        $oversizedCheaperTarget.Cap.MemoryGB = '16'
        $oversizedCheaperTarget.Cap.MaxDataDiskCount = '8'
        $oversizedCheaperTarget.Cap.MaxNetworkInterfaces = '4'
        $oversizedCheaperTarget.Cap.NvmeDiskSizeInMiB = '225280'
        $retirements = New-EmptyRetirements
        $retirements.Exact['standard_b4ms'] = [pscustomobject]@{ Status = 'Announced'; RetireOn = '2028-11-15'; Source = 'LiveLearnMarkdown' }
        $prices = @{
            'Standard_B4ms|eastus' = New-TestPrice -Sku 'Standard_B4ms' -Price 1.00
            'Standard_F4amds_v7|eastus' = New-TestPrice -Sku 'Standard_F4amds_v7' -Price 3.00
            'Standard_D8lds_v6|eastus' = New-TestPrice -Sku 'Standard_D8lds_v6' -Price 0.50
        }

        $row = Build-Recommendations `
            -Inventory @(New-TestVm -Name 'vm-minimum-fallback-shape' -Sku 'Standard_B4ms') `
            -Catalog @($current, $minimumVcpuTarget, $oversizedCheaperTarget) `
            -PriceMap $prices `
            -CommitmentMap @{} `
            -FirstSeenMap @{} `
            -Retirements $retirements | Select-Object -First 1

        $row.CandidateTargetSku | Should -Be 'Standard_D8lds_v6'
        $row.RecommendationBasis | Should -Match 'Retirement fallback'
    }

    It 'excludes constrained CPU variants that reduce available vCPUs' {
        $current = New-TestCatalogEntry -Name 'Standard_B4ms' -Family 'standardBSFamily'
        $current.Cap.vCPUs = '4'
        $current.Cap.vCPUsAvailable = '4'
        $current.Cap.MemoryGB = '16'
        $current.Cap.MaxDataDiskCount = '8'
        $current.Cap.MaxNetworkInterfaces = '4'
        $current.Cap.MaxResourceVolumeMB = '32768'
        $constrainedTarget = New-TestCatalogEntry -Name 'Standard_F4-1amds_v7' -Family 'standardFamdsv7Family'
        $constrainedTarget.Cap.vCPUs = '4'
        $constrainedTarget.Cap.vCPUsAvailable = '1'
        $constrainedTarget.Cap.MemoryGB = '32'
        $constrainedTarget.Cap.MaxDataDiskCount = '8'
        $constrainedTarget.Cap.MaxNetworkInterfaces = '4'
        $constrainedTarget.Cap.NvmeDiskSizeInMiB = '225280'
        $fullCpuTarget = New-TestCatalogEntry -Name 'Standard_F4amds_v7' -Family 'standardFamdsv7Family'
        $fullCpuTarget.Cap.vCPUs = '4'
        $fullCpuTarget.Cap.vCPUsAvailable = '4'
        $fullCpuTarget.Cap.MemoryGB = '32'
        $fullCpuTarget.Cap.MaxDataDiskCount = '8'
        $fullCpuTarget.Cap.MaxNetworkInterfaces = '4'
        $fullCpuTarget.Cap.NvmeDiskSizeInMiB = '225280'
        $retirements = New-EmptyRetirements
        $retirements.Exact['standard_b4ms'] = [pscustomobject]@{ Status = 'Announced'; RetireOn = '2028-11-15'; Source = 'LiveLearnMarkdown' }
        $prices = @{
            'Standard_B4ms|eastus' = New-TestPrice -Sku 'Standard_B4ms' -Price 1.00
            'Standard_F4-1amds_v7|eastus' = New-TestPrice -Sku 'Standard_F4-1amds_v7' -Price 0.50
            'Standard_F4amds_v7|eastus' = New-TestPrice -Sku 'Standard_F4amds_v7' -Price 3.00
        }

        $row = Build-Recommendations `
            -Inventory @(New-TestVm -Name 'vm-constrained-vcpu' -Sku 'Standard_B4ms') `
            -Catalog @($current, $constrainedTarget, $fullCpuTarget) `
            -PriceMap $prices `
            -CommitmentMap @{} `
            -FirstSeenMap @{} `
            -Retirements $retirements | Select-Object -First 1

        $row.CandidateTargetSku | Should -Be 'Standard_F4amds_v7'
        $row.SuggestedSkus | Should -Not -Match 'Standard_F4-1amds_v7'
    }

    It 'does not cross from general-purpose into specialized workload classes' {
        $current = New-TestCatalogEntry -Name 'Standard_B4ms' -Family 'standardBSFamily'
        $current.Cap.vCPUs = '4'
        $current.Cap.MemoryGB = '16'
        $current.Cap.MaxDataDiskCount = '8'
        $current.Cap.MaxNetworkInterfaces = '4'
        $current.Cap.MaxResourceVolumeMB = '32768'
        $confidentialTarget = New-TestCatalogEntry -Name 'Standard_DC4ds_v3' -Family 'standardDCdsv3Family'
        $gpuTarget = New-TestCatalogEntry -Name 'Standard_NC4as_T4_v3' -Family 'standardNCSv3Family'
        $generalTarget = New-TestCatalogEntry -Name 'Standard_D8lds_v6' -Family 'standardDldsv6Family'
        foreach ($target in @($confidentialTarget, $gpuTarget)) {
            $target.Cap.vCPUs = '4'
            $target.Cap.MemoryGB = '32'
            $target.Cap.MaxDataDiskCount = '8'
            $target.Cap.MaxNetworkInterfaces = '4'
            $target.Cap.MaxResourceVolumeMB = '32768'
        }
        $gpuTarget.Cap.GPUs = '1'
        $generalTarget.Cap.vCPUs = '8'
        $generalTarget.Cap.MemoryGB = '16'
        $generalTarget.Cap.MaxDataDiskCount = '8'
        $generalTarget.Cap.MaxNetworkInterfaces = '4'
        $generalTarget.Cap.NvmeDiskSizeInMiB = '225280'
        $retirements = New-EmptyRetirements
        $retirements.Exact['standard_b4ms'] = [pscustomobject]@{ Status = 'Announced'; RetireOn = '2028-11-15'; Source = 'LiveLearnMarkdown' }
        $prices = @{
            'Standard_B4ms|eastus' = New-TestPrice -Sku 'Standard_B4ms' -Price 1.00
            'Standard_DC4ds_v3|eastus' = New-TestPrice -Sku 'Standard_DC4ds_v3' -Price 0.25
            'Standard_NC4as_T4_v3|eastus' = New-TestPrice -Sku 'Standard_NC4as_T4_v3' -Price 0.50
            'Standard_D8lds_v6|eastus' = New-TestPrice -Sku 'Standard_D8lds_v6' -Price 3.00
        }

        $row = Build-Recommendations `
            -Inventory @(New-TestVm -Name 'vm-workload-class' -Sku 'Standard_B4ms') `
            -Catalog @($current, $confidentialTarget, $gpuTarget, $generalTarget) `
            -PriceMap $prices -CommitmentMap @{} -FirstSeenMap @{} -Retirements $retirements |
            Select-Object -First 1

        $row.CandidateTargetSku | Should -Be 'Standard_D8lds_v6'
        $row.SuggestedSkus | Should -Not -Match 'Standard_(DC|NC)'
    }

    It 'ranks minimum combined CPU and memory growth before individual dimensions' {
        $current = New-TestCatalogEntry -Name 'Standard_B4ms' -Family 'standardBSFamily'
        $current.Cap.vCPUs = '4'
        $current.Cap.vCPUsAvailable = '4'
        $current.Cap.MemoryGB = '16'
        $current.Cap.MaxDataDiskCount = '8'
        $current.Cap.MaxNetworkInterfaces = '4'
        $current.Cap.MaxResourceVolumeMB = '32768'
        $memoryOversizedTarget = New-TestCatalogEntry -Name 'Standard_E8-4as_v4' -Family 'standardEASv4Family'
        $memoryOversizedTarget.Cap.vCPUs = '8'
        $memoryOversizedTarget.Cap.vCPUsAvailable = '4'
        $memoryOversizedTarget.Cap.MemoryGB = '64'
        $memoryOversizedTarget.Cap.MaxDataDiskCount = '8'
        $memoryOversizedTarget.Cap.MaxNetworkInterfaces = '4'
        $memoryOversizedTarget.Cap.MaxResourceVolumeMB = '32768'
        $balancedTarget = New-TestCatalogEntry -Name 'Standard_D8lds_v6' -Family 'standardDldsv6Family'
        $balancedTarget.Cap.vCPUs = '8'
        $balancedTarget.Cap.vCPUsAvailable = '8'
        $balancedTarget.Cap.MemoryGB = '16'
        $balancedTarget.Cap.MaxDataDiskCount = '8'
        $balancedTarget.Cap.MaxNetworkInterfaces = '4'
        $balancedTarget.Cap.NvmeDiskSizeInMiB = '225280'
        $retirements = New-EmptyRetirements
        $retirements.Exact['standard_b4ms'] = [pscustomobject]@{ Status = 'Announced'; RetireOn = '2028-11-15'; Source = 'LiveLearnMarkdown' }
        $prices = @{
            'Standard_B4ms|eastus' = New-TestPrice -Sku 'Standard_B4ms' -Price 1.00
            'Standard_E8-4as_v4|eastus' = New-TestPrice -Sku 'Standard_E8-4as_v4' -Price 0.50
            'Standard_D8lds_v6|eastus' = New-TestPrice -Sku 'Standard_D8lds_v6' -Price 3.00
        }

        $row = Build-Recommendations `
            -Inventory @(New-TestVm -Name 'vm-balanced-shape' -Sku 'Standard_B4ms') `
            -Catalog @($current, $memoryOversizedTarget, $balancedTarget) `
            -PriceMap $prices -CommitmentMap @{} -FirstSeenMap @{} -Retirements $retirements |
            Select-Object -First 1

        $row.CandidateTargetSku | Should -Be 'Standard_D8lds_v6'
    }

    It 'does not recommend a SKU restricted for the subscription or location' {
        $restriction = [pscustomobject]@{
            type            = 'Location'
            values          = @('eastus')
            reasonCode      = 'NotAvailableForSubscription'
            restrictionInfo = [pscustomobject]@{ locations = @('eastus'); zones = @() }
        }
        $catalog = @(
            New-TestCatalogEntry -Name 'Standard_D2_v2' -Family 'standardDv2Family'
            New-TestCatalogEntry -Name 'Standard_E2s_v5' -Family 'standardESv5Family' -Restrictions @($restriction)
        )

        $row = Build-Recommendations `
            -Inventory @(New-TestVm -Name 'vm-restricted') `
            -Catalog $catalog `
            -PriceMap @{} `
            -CommitmentMap @{} `
            -FirstSeenMap @{} `
            -Retirements (New-EmptyRetirements) | Select-Object -First 1

        $row.CandidateTargetSku | Should -Be 'N/A'
    }

    It 'computes recommendations with the catalog belonging to each subscription' {
        $vmA = New-TestVm -Name 'vm-sub-a'
        $vmA.SubscriptionId = 'sub-a'
        $vmB = New-TestVm -Name 'vm-sub-b'
        $vmB.SubscriptionId = 'sub-b'
        $currentA = New-TestCatalogEntry -Name 'Standard_D2_v2' -Family 'standardDv2Family'
        $currentB = New-TestCatalogEntry -Name 'Standard_D2_v2' -Family 'standardDv2Family'
        $targetA = New-TestCatalogEntry -Name 'Standard_D2_v5' -Family 'standardDv5Family'
        $targetB = New-TestCatalogEntry -Name 'Standard_E2s_v5' -Family 'standardESv5Family'
        $catalogs = @{
            'sub-a' = @($currentA, $targetA)
            'sub-b' = @($currentB, $targetB)
        }

        $rows = @(Build-RecommendationsBySubscription `
            -Inventory @($vmA, $vmB) `
            -CatalogBySubscription $catalogs `
            -PriceMap @{} `
            -CommitmentMap @{} `
            -FirstSeenMap @{} `
            -Retirements (New-EmptyRetirements))

        ($rows | Where-Object VmName -eq 'vm-sub-a').CandidateTargetSku | Should -Be 'Standard_D2_v5'
        ($rows | Where-Object VmName -eq 'vm-sub-b').CandidateTargetSku | Should -Be 'Standard_E2s_v5'
    }

    It 'retains VM rows for manual review when a subscription catalog is unavailable' {
        $vm = New-TestVm -Name 'vm-no-sub-catalog'
        $vm.SubscriptionId = 'sub-missing'

        $rows = @(Build-RecommendationsBySubscription `
            -Inventory @($vm) `
            -CatalogBySubscription @{} `
            -PriceMap @{} `
            -CommitmentMap @{} `
            -FirstSeenMap @{} `
            -Retirements (New-EmptyRetirements))

        $rows.Count | Should -Be 1
        $rows[0].VmName | Should -Be 'vm-no-sub-catalog'
        $rows[0].CandidateTargetSku | Should -Be 'N/A'
        $rows[0].Confidence | Should -Be 'CatalogUnavailable_NeedsManualReview'
    }
}

Describe 'Risk, cost, and delivery artifacts' {
    It 'treats an imminent per-resource Advisor retirement as urgent' {
        $advisorRetirement = [pscustomobject]@{
            Status   = 'Impacted'
            RetireOn = (Get-Date).AddDays(1).ToString('yyyy-MM-dd')
            Source   = 'LiveAdvisorArg'
        }

        $risk = Get-RetirementRisk `
            -RetirementEntry $advisorRetirement `
            -EvidenceType 'TenantSpecificAdvisorSignal' `
            -CurrentVersion 2

        $risk.Level | Should -Be 'Critical'
    }

    It 'excludes nonpublishable price deltas from report facts' {
        $row = [pscustomobject]@{
            VmName                      = 'vm-cost'
            CurrentSku                  = 'Standard_D2_v2'
            Region                      = 'eastus'
            OsType                      = 'Linux'
            CurrentPriceOsBasis         = 'Linux'
            CurrentWindowsMeterAvailable = $false
            EvidenceSource              = 'LiveLearnMarkdown'
            RetirementSourceGate        = 'LiveLearnMarkdown'
            RetirementDate              = '2028-05-01'
            CandidateTargetSku           = 'Standard_D2s_v5'
            GenerationChange             = $false
            SensitiveWorkload            = $false
            WorkloadRole                 = 'GeneralCompute'
            CommitmentRetirementImpact   = $false
            RetailDeltaMonthly           = 73.00
            CostDeltaReported            = $null
            CostDeltaPercent             = 50.0
            CostDeltaPublishable         = $false
            AdvisorRecommendationId      = 'N/A'
        }

        $facts = Build-ReportFacts -Rows @($row)

        $facts.CostCovered | Should -Be 0
        $facts.CostMissing | Should -Be 1
        $facts.RetailDeltaMonthly | Should -BeNullOrEmpty
        $facts.Rows[0].CostDeltaPercent | Should -BeNullOrEmpty
    }

    It 'surfaces a price-driven CPU vendor change in the recommended SKU note' {
        $row = [pscustomobject]@{
            VmName                       = 'vm-vendor-change'
            CurrentSku                   = 'Standard_B1s'
            Region                       = 'eastus'
            OsType                       = 'Linux'
            CurrentPriceOsBasis          = 'Linux'
            CurrentWindowsMeterAvailable = $false
            EvidenceSource               = 'LiveLearnMarkdown'
            RetirementSourceGate         = 'LiveLearnMarkdown'
            RetirementDate               = '2028-11-15'
            CandidateTargetSku           = 'Standard_B2ats_v2'
            GenerationChange             = $false
            SensitiveWorkload            = $false
            WorkloadRole                  = 'GeneralCompute'
            CpuVendorChange               = $true
            CpuVendorChangeReason         = 'LowerRetailPrice'
            CurrentCpuVendor              = 'Intel'
            TargetCpuVendor               = 'AMD'
            CommitmentRetirementImpact    = $false
            CostDeltaPublishable          = $false
            AdvisorRecommendationId       = 'N/A'
        }

        $facts = Build-ReportFacts -Rows @($row)

        $facts.Rows[0].RecommendedSkuNote | Should -Match 'CPU vendor change \(Intel -> AMD\).*lower.*price'
    }

    It 'propagates target equivalence and selection reason into report facts' {
        $row = [pscustomobject]@{
            VmName                       = 'vm-equivalence'
            CurrentSku                   = 'Standard_B4ms'
            Region                       = 'eastus'
            OsType                       = 'Linux'
            CurrentPriceOsBasis          = 'Linux'
            CurrentWindowsMeterAvailable = $false
            EvidenceSource               = 'LiveLearnMarkdown'
            RetirementSourceGate         = 'LiveLearnMarkdown'
            RetirementDate               = '2028-11-15'
            CandidateTargetSku           = 'Standard_B4as_v2'
            CandidateEquivalenceStatus   = 'NotEquivalent'
            CandidateEquivalenceDetails  = 'maximum NICs: 4 -> 3; temporary/local storage: Resource/cache disk -> None'
            CandidateSelectionReason     = 'Same commercial family B; lowest Retail price among candidates that passed the hard gates.'
            GenerationChange             = $false
            SensitiveWorkload            = $false
            WorkloadRole                 = 'GeneralCompute'
            CommitmentRetirementImpact   = $false
            CostDeltaPublishable          = $false
            AdvisorRecommendationId      = 'N/A'
        }

        $facts = Build-ReportFacts -Rows @($row)

        $facts.Rows[0].EquivalenceStatus | Should -Be 'NotEquivalent'
        $facts.Rows[0].EquivalenceDetails | Should -Match 'maximum NICs: 4 -> 3'
        $facts.Rows[0].SelectionReason | Should -Match 'Same commercial family B'
        $facts.Rows[0].Validation | Should -Match 'Not a validated 1:1 equivalent'
        $facts.Rows[0].Validation | Should -Not -Match 'maximum NICs: 4 -> 3'
        [string]::IsNullOrWhiteSpace($facts.Rows[0].RecommendedSkuNote) | Should -BeTrue
    }

    It 'builds backlog items from retirement urgency rather than generic modernization priority' {
        $path = Join-Path $TestDrive 'backlog.csv'
        $rows = @(
            [pscustomobject]@{
                VmName                 = 'urgent-retiring'
                MigrationPriority      = 'Low'
                MigrationRisk          = 'High'
                CurrentSku             = 'Standard_A1'
                SuggestedPrimarySku    = 'Standard_A2_v2'
                Region                 = 'eastus'
                Recommendation         = 'urgent'
                MigrationRisksAndBlocks = 'deadline'
                RetirementRiskLevel    = 'Critical'
                RetirementSourceGate   = 'LiveLearnMarkdown'
            }
            [pscustomobject]@{
                VmName                 = 'healthy-modernization'
                MigrationPriority      = 'High'
                MigrationRisk          = 'Medium'
                CurrentSku             = 'Standard_D2s_v5'
                SuggestedPrimarySku    = 'Standard_D2s_v6'
                Region                 = 'eastus'
                Recommendation         = 'optional'
                MigrationRisksAndBlocks = 'none'
                RetirementRiskLevel    = 'Low'
                RetirementSourceGate   = 'N/A'
            }
        )

        Export-BacklogItems -Rows $rows -Path $path
        $actual = @(Import-Csv -LiteralPath $path)

        $actual.Count | Should -Be 1
        $actual[0].Title | Should -Match 'urgent-retiring'
    }
}

Describe 'External contract defaults' {
    It 'uses the Resource SKUs operation API version documented for that endpoint' {
        $parameter = $script:SourceAst.ParamBlock.Parameters | Where-Object {
            $_.Name.VariablePath.UserPath -eq 'ResourceSkusApiVersion'
        }

        $parameter.DefaultValue.Value | Should -Be '2026-03-02'
    }

    It 'queries only Reservation records for standalone Retail commitment signals' {
        $script:commitmentRequestUris = New-Object 'System.Collections.Generic.List[string]'

        function Write-Progress {
            param($Id, $ParentId, $Activity, $Status, $PercentComplete, [switch]$Completed)
        }

        function Invoke-RestMethod {
            param($Uri, $Method, $TimeoutSec, $ErrorAction)
            $script:commitmentRequestUris.Add([uri]::UnescapeDataString([string]$Uri)) | Out-Null
            return [pscustomobject]@{
                Items = @(
                    [pscustomobject]@{
                        armSkuName        = 'Standard_D2s_v5'
                        armRegionName     = 'eastus'
                        effectiveStartDate = '2026-01-01'
                    }
                )
                NextPageLink = $null
            }
        }

        $actual = Get-RetailCommitmentSignalsForVirtualMachines -RegionsFilter @('eastus') -MaxRetries 0

        $script:commitmentRequestUris.Count | Should -Be 1
        $script:commitmentRequestUris[0] | Should -Match "priceType eq 'Reservation'"
        $script:commitmentRequestUris[0] | Should -Not -Match 'SavingsPlan'
        $actual['Standard_D2s_v5|eastus'].SupportsReservedInstance | Should -BeTrue
        $actual['Standard_D2s_v5|eastus'].SupportsSavingsPlan | Should -BeFalse
    }

    It 'pins the default Stream C endpoint to the Microsoft HTTPS API' {
        $parameter = $script:SourceAst.ParamBlock.Parameters | Where-Object {
            $_.Name.VariablePath.UserPath -eq 'ReleaseCommunicationsApiUrl'
        }
        $uri = [uri][string]$parameter.DefaultValue.Value

        $uri.Scheme | Should -Be 'https'
        $uri.Host | Should -Be 'www.microsoft.com'
        $uri.AbsolutePath | Should -Be '/releasecommunications/api/v2/azure'
        [uri]::UnescapeDataString($uri.Query) | Should -Match "tags/any\(t:\s*t\s*eq\s*'Retirements'\)"
    }

    It 'assigns low confidence to an unrecognized evidence source' {
        $evidence = Get-RetirementEvidence -RetirementEntry ([pscustomobject]@{ Source = 'UntrustedFixture' })

        $evidence.EvidenceType | Should -Be 'UnknownSource'
        $evidence.Confidence | Should -Be 'Low'
    }
}

Describe 'Compute SKU REST memory bounds' {
    It 'switches subscription context before the non-REST SKU catalog fallback' {
        Mock Get-AzContext { [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = 'sub-a' } } }
        Mock Set-AzContext {}
        Mock Get-AzComputeResourceSku { @() }

        $result = @(Get-ComputeSkuCatalog `
            -RegionsFilter @('eastus') `
            -SubscriptionIdForRest 'sub-b' `
            -UseRestApi $false)

        $result.Count | Should -Be 0
        Assert-MockCalled Set-AzContext -Times 1 -Exactly -ParameterFilter {
            $SubscriptionId -eq 'sub-b'
        }
        Assert-MockCalled Get-AzComputeResourceSku -Times 1 -Exactly
    }

    It 'loads an isolated SKU catalog for each subscription and its inventory regions' {
        $inventory = @(
            [pscustomobject]@{ SubscriptionId = 'sub-a'; Location = 'eastus' }
            [pscustomobject]@{ SubscriptionId = 'sub-a'; Location = 'westus2' }
            [pscustomobject]@{ SubscriptionId = 'sub-b'; Location = 'uksouth' }
        )
        Mock Get-ComputeSkuCatalogCached {
            param($SubscriptionIdForRest, $RegionsFilter)
            @([pscustomobject]@{ Name = "sku-$SubscriptionIdForRest"; Regions = @($RegionsFilter) })
        }

        $catalogs = Get-ComputeSkuCatalogsBySubscription `
            -SubscriptionIds @('sub-a', 'sub-b') `
            -Inventory $inventory `
            -RegionsFilter @('eastus', 'westus2', 'uksouth') `
            -CacheDir $TestDrive `
            -UseCache $false `
            -TtlHours 1 `
            -ForceRefresh $false

        @($catalogs['sub-a']).Count | Should -Be 1
        @($catalogs['sub-a'][0].Regions | Sort-Object) | Should -Be @('eastus', 'westus2')
        @($catalogs['sub-b'][0].Regions) | Should -Be @('uksouth')
        Assert-MockCalled Get-ComputeSkuCatalogCached -Times 1 -Exactly -ParameterFilter {
            $SubscriptionIdForRest -eq 'sub-a' -and @($RegionsFilter).Count -eq 2 -and
            'eastus' -in $RegionsFilter -and 'westus2' -in $RegionsFilter
        }
        Assert-MockCalled Get-ComputeSkuCatalogCached -Times 1 -Exactly -ParameterFilter {
            $SubscriptionIdForRest -eq 'sub-b' -and @($RegionsFilter).Count -eq 1 -and
            'uksouth' -in $RegionsFilter
        }
    }

    It 'queries each requested region separately and compacts paged VM results' {
        $script:requestedSkuUris = New-Object 'System.Collections.Generic.List[string]'

        function Get-AzContext {
            param($ErrorAction)
            return [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = 'sub-test' } }
        }

        function Get-AzAccessToken {
            param($ResourceUrl)
            return [pscustomobject]@{ Token = 'test-token' }
        }

        function Write-Progress {
            param($Id, $ParentId, $Activity, $Status, $PercentComplete, [switch]$Completed)
        }

        function Invoke-RestMethod {
            param($Uri, $Method, $Headers, $ErrorAction)
            $script:requestedSkuUris.Add([string]$Uri) | Out-Null

            $vmSku = {
                param($Name, $Location)
                [pscustomobject]@{
                    name         = $Name
                    resourceType = 'virtualMachines'
                    family       = 'standardDSv5Family'
                    tier         = 'Standard'
                    size         = ($Name -replace '^Standard_', '')
                    locations    = @($Location)
                    capabilities = @([pscustomobject]@{ name = 'vCPUs'; value = '2' })
                    restrictions = @()
                    locationInfo = @()
                    apiVersions  = @('2026-03-02')
                }
            }

            if ($Uri -eq 'https://next.test/eastus/2') {
                return [pscustomobject]@{
                    value    = @(& $vmSku 'Standard_D4s_v5' 'eastus')
                    nextLink = $null
                }
            }

            $decodedUri = [uri]::UnescapeDataString([string]$Uri)
            if ($decodedUri -match "location eq 'eastus'") {
                return [pscustomobject]@{
                    value = @(
                        (& $vmSku 'Standard_D2s_v5' 'eastus'),
                        [pscustomobject]@{ name = 'Standard_LRS'; resourceType = 'disks'; locations = @('eastus') }
                    )
                    nextLink = 'https://next.test/eastus/2'
                }
            }
            if ($decodedUri -match "location eq 'westeurope'") {
                return [pscustomobject]@{
                    value    = @(& $vmSku 'Standard_D2s_v5' 'westeurope')
                    nextLink = $null
                }
            }

            throw "Unexpected URI: $Uri"
        }

        $actual = @(Get-ComputeSkuCatalogFromRest -SubscriptionId 'sub-test' -RegionsFilter @('eastus', 'westeurope') -IncludeExtendedLocations:$true)
        $firstPageUris = @($script:requestedSkuUris | Where-Object { $_ -ne 'https://next.test/eastus/2' })

        $actual.Count | Should -Be 3
        @($actual | Where-Object { $_.Locations -contains 'eastus' }).Count | Should -Be 2
        @($actual | Where-Object { $_.Locations -contains 'westeurope' }).Count | Should -Be 1
        $firstPageUris.Count | Should -Be 2
        ([uri]::UnescapeDataString($firstPageUris[0])) | Should -Match "`\$filter=location eq 'eastus'"
        ([uri]::UnescapeDataString($firstPageUris[1])) | Should -Match "`\$filter=location eq 'westeurope'"
    }
}

Describe 'Known-good control behavior' {
    It 'selects distinct Linux and Windows PAYG meters by VM OS' {
        $entry = [pscustomobject]@{
            UnitPrice        = 0.10
            LinuxUnitPrice   = 0.10
            WindowsUnitPrice = 0.20
        }

        $linux = Resolve-RetailPriceForOs -PriceEntry $entry -OsType 'Linux'
        $windows = Resolve-RetailPriceForOs -PriceEntry $entry -OsType 'Windows'

        $linux.Price | Should -Be 0.10
        $linux.Basis | Should -Be 'Linux'
        $windows.Price | Should -Be 0.20
        $windows.Basis | Should -Be 'Windows'
    }

    It 'excludes Spot and low-priority Retail price records' {
        Test-IsExcludedRetailVmPriceRecord ([pscustomobject]@{
            productName = 'Virtual Machines Dsv5 Series'
            skuName     = 'Standard_D2s_v5 Spot'
            meterName   = 'D2s v5 Spot'
        }) | Should -BeTrue

        Test-IsExcludedRetailVmPriceRecord ([pscustomobject]@{
            productName = 'Virtual Machines Dsv5 Series'
            skuName     = 'Standard_D2s_v5 Low Priority'
            meterName   = 'D2s v5 Low Priority'
        }) | Should -BeTrue

        Test-IsExcludedRetailVmPriceRecord ([pscustomobject]@{
            productName = 'Virtual Machines Dsv5 Series'
            skuName     = 'Standard_D2s_v5'
            meterName   = 'D2s v5'
        }) | Should -BeFalse
    }

    It 'uses first-match wave assignment without double counting' {
        $rows = @(
            [pscustomobject]@{
                VmName                    = 'critical-sensitive'
                CurrentSku                = 'Standard_D2_v2'
                CandidateTargetSku         = 'Standard_E2s_v5'
                Region                    = 'eastus'
                RetirementDate            = '2026-08-01'
                RetirementRiskLevel        = 'Critical'
                RetirementSourceGate       = 'LiveAdvisorArg'
                EvidenceSource             = 'AdvisorSignalOnly'
                SensitiveWorkload          = $true
                GenerationChange           = $true
                RecommendationBasis        = 'test'
                CommitmentRetirementImpact = $false
            }
            [pscustomobject]@{
                VmName                    = 'high-not-critical'
                CurrentSku                = 'Standard_D2_v2'
                CandidateTargetSku         = 'Standard_D2s_v5'
                Region                    = 'eastus'
                RetirementDate            = '2028-05-01'
                RetirementRiskLevel        = 'High'
                RetirementSourceGate       = 'LiveLearnMarkdown'
                EvidenceSource             = 'LiveLearnMarkdown'
                SensitiveWorkload          = $false
                GenerationChange           = $false
                RecommendationBasis        = 'test'
                CommitmentRetirementImpact = $false
            }
            [pscustomobject]@{
                VmName                    = 'routine'
                CurrentSku                = 'Standard_D2_v2'
                CandidateTargetSku         = 'Standard_D2s_v5'
                Region                    = 'eastus'
                RetirementDate            = '2028-05-01'
                RetirementRiskLevel        = 'Medium'
                RetirementSourceGate       = 'LiveLearnMarkdown'
                EvidenceSource             = 'LiveLearnMarkdown'
                SensitiveWorkload          = $false
                GenerationChange           = $false
                RecommendationBasis        = 'test'
                CommitmentRetirementImpact = $false
            }
        )

        $plan = Build-RemediationPlan -Rows $rows

        $plan.TotalVms | Should -Be 3
        @($plan.Waves[0].Items).Count | Should -Be 1
        $plan.Waves[0].Items[0].VmName | Should -Be 'critical-sensitive'
        @($plan.Waves[1].Items).Count | Should -Be 1
        $plan.Waves[1].Items[0].VmName | Should -Be 'high-not-critical'
        @($plan.Waves[4].Items).Count | Should -Be 1
    }

    It 'uses configured risk threshold variables when classifying retirement urgency' {
        $oldCritical = $script:RiskCriticalDays
        $oldHigh = $script:RiskHighDays
        try {
            $script:RiskCriticalDays = 10
            $script:RiskHighDays = 20
            $asOf = [datetime]'2026-01-01'

            Get-RetirementRiskLevel -RetirementDate ([datetime]'2026-01-06') -AsOf $asOf | Should -Be 'Critical'
            Get-RetirementRiskLevel -RetirementDate ([datetime]'2026-01-16') -AsOf $asOf | Should -Be 'High'
            Get-RetirementRiskLevel -RetirementDate ([datetime]'2026-01-26') -AsOf $asOf | Should -Be 'Medium'
        }
        finally {
            $script:RiskCriticalDays = $oldCritical
            $script:RiskHighDays = $oldHigh
        }
    }

    It 'changes risk classification when the configured threshold changes' {
        $oldCritical = $script:RiskCriticalDays
        $oldHigh = $script:RiskHighDays
        try {
            $asOf = [datetime]'2026-01-01'
            $retirementDate = [datetime]'2026-02-15'

            $script:RiskCriticalDays = 30
            $script:RiskHighDays = 90
            Get-RetirementRiskLevel -RetirementDate $retirementDate -AsOf $asOf | Should -Be 'High'

            $script:RiskCriticalDays = 60
            $script:RiskHighDays = 90
            Get-RetirementRiskLevel -RetirementDate $retirementDate -AsOf $asOf | Should -Be 'Critical'
        }
        finally {
            $script:RiskCriticalDays = $oldCritical
            $script:RiskHighDays = $oldHigh
        }
    }

    It 'routes Gen1-to-Gen2 or cross-family work to the architecture lane unless urgency is higher' {
        (Resolve-RemediationWave -RiskLevel Medium -IsSensitiveWorkload $true -SensitiveReason 'Infrastructure-DomainController' -IsGenerationChange $true -IsCrossFamily $false).Wave | Should -Be 'W3'
        (Resolve-RemediationWave -RiskLevel Watch -IsSensitiveWorkload $false -IsGenerationChange $true -IsCrossFamily $false).Wave | Should -Be 'W3'
        (Resolve-RemediationWave -RiskLevel Medium -IsSensitiveWorkload $false -IsGenerationChange $false -IsCrossFamily $true).Wave | Should -Be 'W3'
        (Resolve-RemediationWave -RiskLevel High -IsSensitiveWorkload $false -IsGenerationChange $true -IsCrossFamily $true).Wave | Should -Be 'W1'
        (Resolve-RemediationWave -RiskLevel Critical -IsSensitiveWorkload $true -IsGenerationChange $true -IsCrossFamily $true).Wave | Should -Be 'W0'
    }

    It 'routes sensitive same-generation work to W2 and low-complexity medium work to W4' {
        (Resolve-RemediationWave -RiskLevel Medium -IsSensitiveWorkload $true -SensitiveReason 'Identity-ADFS' -IsGenerationChange $false -IsCrossFamily $false).Wave | Should -Be 'W2'
        (Resolve-RemediationWave -RiskLevel Medium -IsSensitiveWorkload $false -IsGenerationChange $false -IsCrossFamily $false).Wave | Should -Be 'W4'
    }

    It 'exposes urgency and complexity floors for runtime wave invariants' {
        $waveResult = Resolve-RemediationWave -RiskLevel High -IsSensitiveWorkload $false -IsGenerationChange $true -IsCrossFamily $false

        $waveResult.PSObject.Properties.Name | Should -Contain 'UrgencyFloor'
        $waveResult.PSObject.Properties.Name | Should -Contain 'ComplexityFloor'
        $waveResult.UrgencyFloor | Should -Be 'W1'
        $waveResult.ComplexityFloor | Should -Be 'W3'
    }

    It 'normalizes SKU <Sku> to family <Family>' -ForEach @(
        @{ Sku = 'Standard_DS2_v2';    Family = 'D' }
        @{ Sku = 'Standard_D2ads_v7';  Family = 'D' }
        @{ Sku = 'Standard_F2';        Family = 'F' }
        @{ Sku = 'Standard_F2als_v7';  Family = 'F' }
        @{ Sku = 'Standard_GS5';       Family = 'G' }
        @{ Sku = 'Standard_NC6s_v3';   Family = 'NC' }
        @{ Sku = 'Standard_HB120rs_v3'; Family = 'HB' }
    ) {
        Get-SkuFamilyToken $Sku | Should -Be $Family
    }

    It 'classifies equivalent D and F modernization shapes consistently without changing their urgency floors' {
        $rows = @(
            [pscustomobject]@{ VmName = 'd-shape'; CurrentSku = 'Standard_DS2_v2'; CandidateTargetSku = 'Standard_D2ads_v7'; Region = 'italynorth'; RetirementDate = '2028-05-01'; RetirementRiskLevel = 'High'; RetirementSourceGate = 'LiveLearnMarkdown'; EvidenceSource = 'LiveLearnMarkdown'; SensitiveWorkload = $false; GenerationChange = $true; RecommendationBasis = 'Heuristic: cross-family migration (requires architecture validation)'; RetailDeltaMonthly = -1.46; CommitmentRetirementImpact = $false }
            [pscustomobject]@{ VmName = 'f-shape'; CurrentSku = 'Standard_F2'; CandidateTargetSku = 'Standard_F2als_v7'; Region = 'uksouth'; RetirementDate = '2028-11-15'; RetirementRiskLevel = 'Medium'; RetirementSourceGate = 'LiveLearnMarkdown'; EvidenceSource = 'LiveLearnMarkdown'; SensitiveWorkload = $true; GenerationChange = $true; WorkloadRole = 'Infrastructure-DomainController'; RetailDeltaMonthly = 19.71; CommitmentRetirementImpact = $false }
        )

        $plan = Build-RemediationPlan -Rows $rows
        $dItem = $plan.Waves[1].Items | Where-Object VmName -eq 'd-shape'
        $fItem = $plan.Waves[3].Items | Where-Object VmName -eq 'f-shape'

        $dItem.CrossFamily | Should -BeFalse
        $dItem.ChangeClass | Should -Be 'SameFamily'
        $dItem.WaveReasons | Should -Not -Contain 'ComplexityCrossFamily'
        $dItem.Rationale | Should -Match 'compatible same-family modernization'
        $dItem.Rationale | Should -Not -Match 'cross-family migration'
        $dItem.Wave | Should -Be 'W1'
        $fItem.CrossFamily | Should -BeFalse
        $fItem.ChangeClass | Should -Be 'SameFamily'
        $fItem.WaveReasons | Should -Not -Contain 'ComplexityCrossFamily'
        $fItem.Wave | Should -Be 'W3'
        $plan.TotalVms | Should -Be 2
    }

    # Correctness pin for the single source of truth of the two-axis floor rule. Because both the wave
    # assignment (Resolve-RemediationWave) and the Build-RemediationPlan fail-closed guard now call
    # Resolve-RemediationWaveFloor, a bug INSIDE the helper would produce the same wrong floor on both
    # sides and the guard's equality check would stay silent. This table asserts the helper output against
    # HAND-WRITTEN literal floors for the full 4x2x2x2 fact matrix, so any change to the rule is caught
    # here rather than in production. Expected values are NOT computed from the helper.
    It 'resolves floor <Wave> (urgency <Urgency>, complexity <Complexity>) for risk=<Risk> sensitive=<Sensitive> gen=<Gen> cross=<Cross>' -ForEach @(
        @{ Risk = 'Critical'; Sensitive = $false; Gen = $false; Cross = $false; Urgency = 'W0'; Complexity = 'W4'; Wave = 'W0'; Number = 0 }
        @{ Risk = 'Critical'; Sensitive = $false; Gen = $false; Cross = $true;  Urgency = 'W0'; Complexity = 'W3'; Wave = 'W0'; Number = 0 }
        @{ Risk = 'Critical'; Sensitive = $false; Gen = $true;  Cross = $false; Urgency = 'W0'; Complexity = 'W3'; Wave = 'W0'; Number = 0 }
        @{ Risk = 'Critical'; Sensitive = $false; Gen = $true;  Cross = $true;  Urgency = 'W0'; Complexity = 'W3'; Wave = 'W0'; Number = 0 }
        @{ Risk = 'Critical'; Sensitive = $true;  Gen = $false; Cross = $false; Urgency = 'W0'; Complexity = 'W2'; Wave = 'W0'; Number = 0 }
        @{ Risk = 'Critical'; Sensitive = $true;  Gen = $false; Cross = $true;  Urgency = 'W0'; Complexity = 'W3'; Wave = 'W0'; Number = 0 }
        @{ Risk = 'Critical'; Sensitive = $true;  Gen = $true;  Cross = $false; Urgency = 'W0'; Complexity = 'W3'; Wave = 'W0'; Number = 0 }
        @{ Risk = 'Critical'; Sensitive = $true;  Gen = $true;  Cross = $true;  Urgency = 'W0'; Complexity = 'W3'; Wave = 'W0'; Number = 0 }
        @{ Risk = 'High';     Sensitive = $false; Gen = $false; Cross = $false; Urgency = 'W1'; Complexity = 'W4'; Wave = 'W1'; Number = 1 }
        @{ Risk = 'High';     Sensitive = $false; Gen = $false; Cross = $true;  Urgency = 'W1'; Complexity = 'W3'; Wave = 'W1'; Number = 1 }
        @{ Risk = 'High';     Sensitive = $false; Gen = $true;  Cross = $false; Urgency = 'W1'; Complexity = 'W3'; Wave = 'W1'; Number = 1 }
        @{ Risk = 'High';     Sensitive = $false; Gen = $true;  Cross = $true;  Urgency = 'W1'; Complexity = 'W3'; Wave = 'W1'; Number = 1 }
        @{ Risk = 'High';     Sensitive = $true;  Gen = $false; Cross = $false; Urgency = 'W1'; Complexity = 'W2'; Wave = 'W1'; Number = 1 }
        @{ Risk = 'High';     Sensitive = $true;  Gen = $false; Cross = $true;  Urgency = 'W1'; Complexity = 'W3'; Wave = 'W1'; Number = 1 }
        @{ Risk = 'High';     Sensitive = $true;  Gen = $true;  Cross = $false; Urgency = 'W1'; Complexity = 'W3'; Wave = 'W1'; Number = 1 }
        @{ Risk = 'High';     Sensitive = $true;  Gen = $true;  Cross = $true;  Urgency = 'W1'; Complexity = 'W3'; Wave = 'W1'; Number = 1 }
        @{ Risk = 'Medium';   Sensitive = $false; Gen = $false; Cross = $false; Urgency = 'W4'; Complexity = 'W4'; Wave = 'W4'; Number = 4 }
        @{ Risk = 'Medium';   Sensitive = $false; Gen = $false; Cross = $true;  Urgency = 'W4'; Complexity = 'W3'; Wave = 'W3'; Number = 3 }
        @{ Risk = 'Medium';   Sensitive = $false; Gen = $true;  Cross = $false; Urgency = 'W4'; Complexity = 'W3'; Wave = 'W3'; Number = 3 }
        @{ Risk = 'Medium';   Sensitive = $false; Gen = $true;  Cross = $true;  Urgency = 'W4'; Complexity = 'W3'; Wave = 'W3'; Number = 3 }
        @{ Risk = 'Medium';   Sensitive = $true;  Gen = $false; Cross = $false; Urgency = 'W4'; Complexity = 'W2'; Wave = 'W2'; Number = 2 }
        @{ Risk = 'Medium';   Sensitive = $true;  Gen = $false; Cross = $true;  Urgency = 'W4'; Complexity = 'W3'; Wave = 'W3'; Number = 3 }
        @{ Risk = 'Medium';   Sensitive = $true;  Gen = $true;  Cross = $false; Urgency = 'W4'; Complexity = 'W3'; Wave = 'W3'; Number = 3 }
        @{ Risk = 'Medium';   Sensitive = $true;  Gen = $true;  Cross = $true;  Urgency = 'W4'; Complexity = 'W3'; Wave = 'W3'; Number = 3 }
        @{ Risk = 'Watch';    Sensitive = $false; Gen = $false; Cross = $false; Urgency = 'W4'; Complexity = 'W4'; Wave = 'W4'; Number = 4 }
        @{ Risk = 'Watch';    Sensitive = $false; Gen = $false; Cross = $true;  Urgency = 'W4'; Complexity = 'W3'; Wave = 'W3'; Number = 3 }
        @{ Risk = 'Watch';    Sensitive = $false; Gen = $true;  Cross = $false; Urgency = 'W4'; Complexity = 'W3'; Wave = 'W3'; Number = 3 }
        @{ Risk = 'Watch';    Sensitive = $false; Gen = $true;  Cross = $true;  Urgency = 'W4'; Complexity = 'W3'; Wave = 'W3'; Number = 3 }
        @{ Risk = 'Watch';    Sensitive = $true;  Gen = $false; Cross = $false; Urgency = 'W4'; Complexity = 'W2'; Wave = 'W2'; Number = 2 }
        @{ Risk = 'Watch';    Sensitive = $true;  Gen = $false; Cross = $true;  Urgency = 'W4'; Complexity = 'W3'; Wave = 'W3'; Number = 3 }
        @{ Risk = 'Watch';    Sensitive = $true;  Gen = $true;  Cross = $false; Urgency = 'W4'; Complexity = 'W3'; Wave = 'W3'; Number = 3 }
        @{ Risk = 'Watch';    Sensitive = $true;  Gen = $true;  Cross = $true;  Urgency = 'W4'; Complexity = 'W3'; Wave = 'W3'; Number = 3 }
    ) {
        $floor = Resolve-RemediationWaveFloor -RiskLevel $Risk -IsSensitiveWorkload $Sensitive -IsGenerationChange $Gen -IsCrossFamily $Cross

        $floor.UrgencyFloor | Should -Be $Urgency
        $floor.ComplexityFloor | Should -Be $Complexity
        $floor.Wave | Should -Be $Wave
        $floor.WaveNumber | Should -Be $Number
    }

    It 'pins real regression <Scenario> to literal floor <Expected>' -ForEach @(
        @{ Scenario = 'test DS2_v2->D2as_v5'; Risk = 'High'; Sensitive = $false; Gen = $true; Cross = $false; Expected = 'W1' }
        @{ Scenario = 'ric-vm-dc F2->F2als_v7'; Risk = 'Medium'; Sensitive = $true; Gen = $true; Cross = $false; Expected = 'W3' }
        @{ Scenario = 'A1_v2->B2als_v2 cross-family isolation'; Risk = 'Medium'; Sensitive = $false; Gen = $false; Cross = $true; Expected = 'W3' }
    ) {
        $floor = Resolve-RemediationWaveFloor -RiskLevel $Risk -IsSensitiveWorkload $Sensitive -IsGenerationChange $Gen -IsCrossFamily $Cross

        $floor.Wave | Should -Be $Expected
    }

    It 'keeps date thresholds out of the fact-to-floor resolver' {
        (Get-Command Resolve-RemediationWaveFloor).Definition | Should -Not -Match '\b(365|730)\b'
    }

    It 'keeps Resolve-RemediationWave.Wave identical to the floor helper across the full fact matrix' -ForEach @(
        @{ Risk = 'Critical'; Sensitive = $false; Gen = $false; Cross = $false }
        @{ Risk = 'High';     Sensitive = $true;  Gen = $true;  Cross = $false }
        @{ Risk = 'Medium';   Sensitive = $true;  Gen = $false; Cross = $false }
        @{ Risk = 'Medium';   Sensitive = $false; Gen = $true;  Cross = $false }
        @{ Risk = 'Watch';    Sensitive = $false; Gen = $false; Cross = $true }
        @{ Risk = 'Medium';   Sensitive = $false; Gen = $false; Cross = $false }
    ) {
        $floor = Resolve-RemediationWaveFloor -RiskLevel $Risk -IsSensitiveWorkload $Sensitive -IsGenerationChange $Gen -IsCrossFamily $Cross
        $resolved = Resolve-RemediationWave -RiskLevel $Risk -IsSensitiveWorkload $Sensitive -IsGenerationChange $Gen -IsCrossFamily $Cross

        $resolved.Wave | Should -Be $floor.Wave
        $resolved.UrgencyFloor | Should -Be $floor.UrgencyFloor
        $resolved.ComplexityFloor | Should -Be $floor.ComplexityFloor
    }

    It 'fails closed when row facts imply a lower floor than the assigned plan wave' -ForEach @(
        @{ Name = 'drifted-gen'; Risk = 'Medium'; Sensitive = $false; GenerationChange = $true; CurrentSku = 'Standard_F2'; TargetSku = 'Standard_F2als_v7'; Expected = 'W3'; ExpectedFacts = 'generationChange=True' }
        @{ Name = 'drifted-cross'; Risk = 'Medium'; Sensitive = $false; GenerationChange = $false; CurrentSku = 'Standard_D2_v2'; TargetSku = 'Standard_E2s_v5'; Expected = 'W3'; ExpectedFacts = 'crossFamily=True' }
        @{ Name = 'drifted-sensitive'; Risk = 'Medium'; Sensitive = $true; GenerationChange = $false; CurrentSku = 'Standard_D2_v2'; TargetSku = 'Standard_D2s_v5'; Expected = 'W2'; ExpectedFacts = 'sensitive=True' }
        @{ Name = 'drifted-risk'; Risk = 'High'; Sensitive = $false; GenerationChange = $false; CurrentSku = 'Standard_D2_v2'; TargetSku = 'Standard_D2s_v5'; Expected = 'W1'; ExpectedFacts = 'risk=High' }
    ) {
        Mock Resolve-RemediationWave {
            [pscustomobject]@{
                Wave            = 'W4'
                WaveNumber      = 4
                UrgencyFloor    = 'W4'
                ComplexityFloor = 'W4'
                RiskLevel       = $Risk
                ReasonCodes     = @("ForcedW4($Name)")
            }
        }

        $row = [pscustomobject]@{
            VmName                    = $Name
            CurrentSku                = $CurrentSku
            CandidateTargetSku         = $TargetSku
            Region                    = 'eastus'
            RetirementDate            = '2028-05-01'
            RetirementRiskLevel        = $Risk
            RetirementSourceGate       = 'LiveLearnMarkdown'
            EvidenceSource             = 'LiveLearnMarkdown'
            SensitiveWorkload          = $Sensitive
            GenerationChange           = $GenerationChange
            RecommendationBasis        = 'test'
            CommitmentRetirementImpact = $false
        }

        { Build-RemediationPlan -Rows @($row) } | Should -Throw "*$Name*W4 != $Expected*$ExpectedFacts*"
    }

    It 'accepts the current nine-row shape without changing wave membership' {
        $rows = @(
            [pscustomobject]@{ VmName = 'test'; CurrentSku = 'Standard_DS2_v2'; CandidateTargetSku = 'Standard_D2as_v5'; Region = 'italynorth'; RetirementDate = '2028-05-01'; RetirementRiskLevel = 'High'; RetirementSourceGate = 'LiveLearnMarkdown'; EvidenceSource = 'LiveLearnMarkdown'; SensitiveWorkload = $false; GenerationChange = $true; RetailDeltaMonthly = -1.46; CommitmentRetirementImpact = $false }
            [pscustomobject]@{ VmName = 'demo-vm-02'; CurrentSku = 'Standard_B4ms'; CandidateTargetSku = 'Standard_B4as_v2'; Region = 'uksouth'; RetirementDate = '2028-11-15'; RetirementRiskLevel = 'Medium'; RetirementSourceGate = 'LiveLearnMarkdown'; EvidenceSource = 'LiveLearnMarkdown'; SensitiveWorkload = $false; GenerationChange = $false; RetailDeltaMonthly = -12.41; CommitmentRetirementImpact = $false }
            [pscustomobject]@{ VmName = 'ric-vm-0-lan1'; CurrentSku = 'Standard_A1_v2'; CandidateTargetSku = 'Standard_B2als_v2'; Region = 'uksouth'; RetirementDate = '2028-11-15'; RetirementRiskLevel = 'Medium'; RetirementSourceGate = 'LiveLearnMarkdown'; EvidenceSource = 'LiveLearnMarkdown'; SensitiveWorkload = $false; GenerationChange = $true; CommitmentRetirementImpact = $false }
            [pscustomobject]@{ VmName = 'ric-vm-0-lan2'; CurrentSku = 'Standard_A1_v2'; CandidateTargetSku = 'Standard_B2als_v2'; Region = 'uksouth'; RetirementDate = '2028-11-15'; RetirementRiskLevel = 'Medium'; RetirementSourceGate = 'LiveLearnMarkdown'; EvidenceSource = 'LiveLearnMarkdown'; SensitiveWorkload = $false; GenerationChange = $true; CommitmentRetirementImpact = $false }
            [pscustomobject]@{ VmName = 'demo-vm-05'; CurrentSku = 'Standard_B2ms'; CandidateTargetSku = 'Standard_B2as_v2'; Region = 'uksouth'; RetirementDate = '2028-11-15'; RetirementRiskLevel = 'Medium'; RetirementSourceGate = 'LiveLearnMarkdown'; EvidenceSource = 'LiveLearnMarkdown'; SensitiveWorkload = $true; GenerationChange = $false; WorkloadRole = 'Identity-DirectorySync'; RetailDeltaMonthly = -5.09; CommitmentRetirementImpact = $false }
            [pscustomobject]@{ VmName = 'demo-vm-06'; CurrentSku = 'Standard_B4ms'; CandidateTargetSku = 'Standard_B4as_v2'; Region = 'uksouth'; RetirementDate = '2028-11-15'; RetirementRiskLevel = 'Medium'; RetirementSourceGate = 'LiveLearnMarkdown'; EvidenceSource = 'LiveLearnMarkdown'; SensitiveWorkload = $true; GenerationChange = $false; WorkloadRole = 'Identity-ADFS'; RetailDeltaMonthly = -12.41; CommitmentRetirementImpact = $false }
            [pscustomobject]@{ VmName = 'ric-vm-dc'; CurrentSku = 'Standard_F2'; CandidateTargetSku = 'Standard_F2als_v7'; Region = 'uksouth'; RetirementDate = '2028-11-15'; RetirementRiskLevel = 'Medium'; RetirementSourceGate = 'LiveLearnMarkdown'; EvidenceSource = 'LiveLearnMarkdown'; SensitiveWorkload = $true; GenerationChange = $true; WorkloadRole = 'Infrastructure-DomainController'; RetailDeltaMonthly = 19.71; CommitmentRetirementImpact = $false }
            [pscustomobject]@{ VmName = 'ric-vm-1-lan1'; CurrentSku = 'Standard_A1_v2'; CandidateTargetSku = 'Standard_B2als_v2'; Region = 'uksouth'; RetirementDate = '2028-11-15'; RetirementRiskLevel = 'Medium'; RetirementSourceGate = 'LiveLearnMarkdown'; EvidenceSource = 'LiveLearnMarkdown'; SensitiveWorkload = $false; GenerationChange = $true; CommitmentRetirementImpact = $false }
            [pscustomobject]@{ VmName = 'demo-vm-12'; CurrentSku = 'Standard_B4ms'; CandidateTargetSku = 'Standard_B4as_v2'; Region = 'uksouth'; RetirementDate = '2028-11-15'; RetirementRiskLevel = 'Medium'; RetirementSourceGate = 'LiveLearnMarkdown'; EvidenceSource = 'LiveLearnMarkdown'; SensitiveWorkload = $false; GenerationChange = $false; RetailDeltaMonthly = -12.41; CommitmentRetirementImpact = $false }
        )

        $plan = Build-RemediationPlan -Rows $rows

        $plan.TotalVms | Should -Be 9
        @($plan.Waves[0].Items).Count | Should -Be 0
        @($plan.Waves[1].Items).Count | Should -Be 1
        @($plan.Waves[2].Items).Count | Should -Be 2
        @($plan.Waves[3].Items).Count | Should -Be 4
        @($plan.Waves[4].Items).Count | Should -Be 2
        @($plan.Waves[1].Items | Where-Object { $_.VmName -eq 'test' -and $_.TargetSku -eq 'Standard_D2as_v5' }).Count | Should -Be 1
        @($plan.Waves[3].Items | Where-Object TargetSku -eq 'Standard_B2als_v2').Count | Should -Be 3
        @($plan.Waves[3].Items | Where-Object { $_.VmName -eq 'ric-vm-0-lan1' -and $_.TargetSku -eq 'Standard_B2als_v2' }).Count | Should -Be 1
        @($plan.Waves[3].Items | Where-Object { $_.VmName -eq 'ric-vm-dc' -and $_.TargetSku -eq 'Standard_F2als_v7' }).Count | Should -Be 1
    }

    It 'labels High-only W1 rows as high urgency, not Advisor-sensitive' {
        $waveResult = Resolve-RemediationWave -RiskLevel High -IsSensitiveWorkload $false -IsGenerationChange $false -IsCrossFamily $false -AdvisorConfirmed:$false

        Get-WaveChipLabel -WaveResult $waveResult | Should -Be 'W1 · High urgency'
    }

    It 'routes from raw facts rather than Same-shape recommendation text' {
        $row = [pscustomobject]@{
            VmName                    = 'domain-controller'
            CurrentSku                = 'Standard_F2'
            CandidateTargetSku         = 'Standard_F2als_v7'
            Region                    = 'eastus'
            RetirementDate            = '2028-11-15'
            RetirementRiskLevel        = 'Medium'
            RetirementClass            = 'SkuFamily'
            RetirementSourceGate       = 'LiveLearnMarkdown'
            EvidenceSource             = 'LiveLearnMarkdown'
            WorkloadRole               = 'Infrastructure-DomainController'
            SensitiveWorkload          = $true
            GenerationChange           = $true
            RecommendationBasis        = 'Same-shape refresh'
            CommitmentRetirementImpact = $false
        }

        $plan = Build-RemediationPlan -Rows @($row)

        @($plan.Waves[3].Items).Count | Should -Be 1
        $plan.Waves[3].Items[0].VmName | Should -Be 'domain-controller'
        $plan.Waves[3].Items[0].ComplexityFloor | Should -Be 'W3'
        @($plan.Waves[4].Items).Count | Should -Be 0
    }

    It 'keeps commitment retirement impact advisory and outside wave routing when flag=<CommitmentImpact>' -ForEach @(
        @{ CommitmentImpact = $false }
        @{ CommitmentImpact = $true }
    ) {
        $row = [pscustomobject]@{
            VmName                     = "commitment-$CommitmentImpact"
            CurrentSku                 = 'Standard_D2_v2'
            CandidateTargetSku         = 'Standard_D2s_v5'
            Region                     = 'eastus'
            RetirementDate             = '2028-05-01'
            RetirementRiskLevel        = 'High'
            RetirementSourceGate       = 'LiveLearnMarkdown'
            EvidenceSource             = 'LiveLearnMarkdown'
            SensitiveWorkload          = $false
            GenerationChange           = $false
            RecommendationBasis        = 'Same-family modernization'
            CommitmentRetirementImpact = $CommitmentImpact
        }

        $plan = Build-RemediationPlan -Rows @($row)

        @($plan.Waves[1].Items).Count | Should -Be 1
        $plan.Waves[1].Items[0].Wave | Should -Be 'W1'
        $plan.Waves[1].Items[0].UrgencyFloor | Should -Be 'W1'
        $plan.Waves[1].Items[0].ComplexityFloor | Should -Be 'W4'
    }

    It 'labels a W3 card with only same-family Gen1-to-Gen2 items without Cross-family or class change' {
        $header = Get-WaveCardHeader -WaveNumber 3 -Items @(
            [pscustomobject]@{ WaveReasons = @('UrgencyNone(Medium)', 'ComplexityGen1ToGen2', 'Sensitive:Infrastructure-DomainController') }
        ) -DefaultTitle 'Wave 3 - default' -DefaultNote 'default note'

        $header.Title | Should -Be 'Wave 3 - Same-family Gen1->Gen2 (generation boundary)'
        $header.Note | Should -Match 'generation boundary'
        $header.Title | Should -Not -Match 'Cross-family'
        $header.Note | Should -Not -Match 'class change'
    }

    It 'renders a W3 card with only same-family Gen1-to-Gen2 items without Cross-family or class change' {
        $row = [pscustomobject]@{
            VmName                     = 'domain-controller'
            Region                     = 'eastus'
            CurrentSku                 = 'Standard_F2'
            RecommendedSku             = 'Standard_F2als_v7'
            CandidateTargetSku         = 'Standard_F2als_v7'
            OsType                     = 'Windows'
            CurrentPriceOsBasis        = 'Windows'
            WhatHappens                = 'Microsoft Learn SKU-family retirement: verify VM scope in Workbook'
            RetirementSourceLabel      = 'Learn (SKU-family, verify in Workbook)'
            RetirementDate             = '2028-11-15'
            RecommendedSkuNote         = 'Generation change (current SKU allows Gen1, target is Gen2-only): validate before migrating.'
            Validation                 = 'Retail/list price delta calculated from cached Azure Retail Prices (730h/month). Not a validated saving.'
            NextStep                   = 'Validate affected VM in Azure Retirement Workbook, then schedule SKU migration.'
            RetailDeltaMonthly         = 0
            CostDeltaPercent           = 0
            RetirementRiskLevel        = 'Medium'
            RetirementClass            = 'SkuFamily'
            RetirementSourceGate       = 'LiveLearnMarkdown'
            EvidenceSource             = 'LiveLearnMarkdown'
            SourceTag                  = 'Learn (SKU-family, verify in Workbook)'
            WorkloadRole               = 'Infrastructure-DomainController'
            SensitiveWorkload          = $true
            GenerationChange           = $true
            RecommendationBasis        = 'Same-shape refresh: same vCPU/RAM profile'
            EquivalenceStatus          = 'NotEquivalent'
            EquivalenceDetails         = 'temporary/local storage: Resource/cache disk -> None'
            SelectionReason            = 'Same commercial family F; lowest Retail price among candidates that passed the hard gates.'
            CommitmentRetirementImpact = $false
        }
        $facts = [pscustomobject]@{
            ReportVersion               = '0.9'
            RetailDeltaMonthly          = 0
            CostCovered                 = 1
            CostMissing                 = 0
            MonitoringRows              = @()
            SkuChangeWithGenChange      = 1
            SkuChangeWithoutGenChange   = 0
            CommitmentImpactCount       = 0
            RetireCount                 = 1
            TotalVmCount                = 1
            AdvisorConfirmed            = 0
            SkuFamily                   = 1
            GeneratedAtUtc              = '2026-07-13 00:00:00'
            MonitoringDistinctVmCount   = 0
            MonitoringConfirmed         = 0
            MonitoringUnconfirmed       = 0
            MonitoringUnknown           = 0
            Rows                        = @($row)
        }
        $plan = Build-RemediationPlan -Rows @($row)
        $path = Join-Path $TestDrive 'w3-card.html'

        ConvertTo-SimplifiedReportHtml -Facts $facts -Path $path -RemediationPlan $plan
        $html = Get-Content -LiteralPath $path -Raw
        $w3Card = [regex]::Match($html, "(?s)<details class='wave-card w3'.*?</details>").Value

        $w3Card | Should -Match 'Same-family Gen1-&gt;Gen2 \(generation boundary\)'
        $w3Card | Should -Match 'generation boundary'
        $w3Card | Should -Not -Match 'Cross-family'
        $w3Card | Should -Not -Match 'class change'
        $html | Should -Match '<span>Script version</span><strong>v0\.9</strong>'
        $html | Should -Match 'Retail delta coverage: 1 of 1 retirement-path VM\(s\)'
        $html | Should -Match 'Compare net values across runs only when this coverage denominator is unchanged'
        $html | Should -Match '<strong>Candidate-fit disclaimer:</strong> Recommended SKUs are nearest-fit candidates'
        $html | Should -Match '<strong>Fit confidence:</strong> candidate - verify'
        $html | Should -Match '<strong>Compared capabilities:</strong> temporary/local storage: Resource/cache disk -&gt; None'
        $html | Should -Match '<strong>Why selected:</strong> Same commercial family F; lowest Retail price'
    }

    It 'labels a W3 card with cross-family items as Cross-family' {
        $header = Get-WaveCardHeader -WaveNumber 3 -Items @(
            [pscustomobject]@{ WaveReasons = @('UrgencyNone(Medium)', 'ComplexityCrossFamily', 'ComplexityGen1ToGen2') }
        ) -DefaultTitle 'Wave 3 - default' -DefaultNote 'default note'

        $header.Title | Should -Be 'Wave 3 - Cross-family Gen1->Gen2 (architecture validation)'
        $header.Note | Should -Match 'class change'
    }

    It 'labels uniform W4 items specifically as low-complexity same-generation resize' {
        $header = Get-WaveCardHeader -WaveNumber 4 -Items @(
            [pscustomobject]@{ WaveReasons = @('UrgencyNone(Medium)'); TargetSku = 'Standard_D2s_v5'; GenerationChange = $false; CrossFamily = $false }
            [pscustomobject]@{ WaveReasons = @('UrgencyNone(Watch)'); TargetSku = 'Standard_B4as_v2'; GenerationChange = $false; CrossFamily = $false }
        ) -DefaultTitle 'Wave 4 - default' -DefaultNote 'default note'

        $header.Title | Should -Be 'Wave 4 - Low-complexity same-generation resize'
        $header.Note | Should -Match 'Low-complexity quick wins'
    }

    It 'labels mixed W4 items neutrally without claiming a false move nature' {
        $header = Get-WaveCardHeader -WaveNumber 4 -Items @(
            [pscustomobject]@{ WaveReasons = @('UrgencyNone(Medium)'); TargetSku = 'Standard_B4as_v2'; GenerationChange = $false; CrossFamily = $false }
            [pscustomobject]@{ WaveReasons = @('UrgencyNone(Watch)'); TargetSku = 'N/A'; GenerationChange = $false; CrossFamily = $false }
        ) -DefaultTitle 'Wave 4 - default' -DefaultNote 'default note'

        $header.Title | Should -Be 'Wave 4 - Low-complexity moves (mixed)'
        $header.Title | Should -Match 'mixed'
        $header.Title | Should -Not -Match 'Cross-family|same-generation resize'
        $header.Note | Should -Not -Match 'class change'
    }

    It 'derives fixed-wave card headers from aggregated ReasonCodes rather than a static title map' {
        $sameFamilyHeader = Get-WaveCardHeader -WaveNumber 3 -Items @(
            [pscustomobject]@{ WaveReasons = @('UrgencyNone(Medium)', 'ComplexityGen1ToGen2') }
        ) -DefaultTitle 'Wave 3 - static' -DefaultNote 'static note'
        $crossFamilyHeader = Get-WaveCardHeader -WaveNumber 3 -Items @(
            [pscustomobject]@{ WaveReasons = @('UrgencyNone(Medium)', 'ComplexityCrossFamily', 'ComplexityGen1ToGen2') }
        ) -DefaultTitle 'Wave 3 - static' -DefaultNote 'static note'

        $sameFamilyHeader.Title | Should -Not -Be $crossFamilyHeader.Title
        $sameFamilyHeader.Note | Should -Not -Be $crossFamilyHeader.Note
    }

    It 'keeps High risk W1 workloads out of the executive act-now bucket' {
        $row = [pscustomobject]@{
            VmName                     = 'high-not-critical'
            Region                     = 'eastus'
            CurrentSku                 = 'Standard_D2_v2'
            RecommendedSku             = 'Standard_D2s_v5'
            CandidateTargetSku         = 'Standard_D2s_v5'
            OsType                     = 'Linux'
            CurrentPriceOsBasis        = 'Linux'
            WhatHappens                = 'Microsoft Learn SKU-family retirement: verify VM scope in Workbook'
            RetirementSourceLabel      = 'Learn (SKU-family, verify in Workbook)'
            RetirementDate             = '2028-05-01'
            RecommendedSkuNote         = ''
            Validation                 = 'Retail/list price delta calculated from cached Azure Retail Prices (730h/month). Not a validated saving.'
            NextStep                   = 'Validate affected VM in Azure Retirement Workbook, then schedule SKU migration.'
            RetailDeltaMonthly         = 0
            CostDeltaPercent           = 0
            RetirementRiskLevel        = 'High'
            RetirementClass            = 'SkuFamily'
            RetirementSourceGate       = 'LiveLearnMarkdown'
            EvidenceSource             = 'LiveLearnMarkdown'
            SourceTag                  = 'Learn (SKU-family, verify in Workbook)'
            SensitiveWorkload          = $false
            GenerationChange           = $false
            RecommendationBasis        = 'test'
            CommitmentRetirementImpact = $false
        }
        $facts = [pscustomobject]@{
            RetailDeltaMonthly          = 0
            MonitoringRows              = @()
            SkuChangeWithGenChange      = 0
            SkuChangeWithoutGenChange   = 1
            CommitmentImpactCount       = 0
            RetireCount                 = 1
            TotalVmCount                = 1
            AdvisorConfirmed            = 0
            SkuFamily                   = 1
            GeneratedAtUtc              = '2026-07-13 00:00:00'
            MonitoringDistinctVmCount   = 0
            MonitoringConfirmed         = 0
            MonitoringUnconfirmed       = 0
            MonitoringUnknown           = 0
            Rows                        = @($row)
        }
        $plan = Build-RemediationPlan -Rows @($row)
        $path = Join-Path $TestDrive 'decision-room.html'

        ConvertTo-SimplifiedReportHtml -Facts $facts -Path $path -RemediationPlan $plan
        $html = Get-Content -LiteralPath $path -Raw

        $html | Should -Match '<div class="decision-tag">This sprint<span class="info-dot"[^>]*>i</span></div>\s*<div class="decision-value">0</div>\s*<div class="decision-title">Act now \(W0\)</div>'
        $html | Should -Match '<div class="decision-tag">Next wave<span class="info-dot"[^>]*>i</span></div>\s*<div class="decision-value">1</div>\s*<div class="decision-title">Plan with validation \(W1 \+ W2 \+ W3\)</div>'
        $html | Should -Not -Match 'Act now \(W0 \+ W1\)'
    }

    It 'blocks a Windows row priced on Linux when a Windows meter exists' {
        $facts = [pscustomobject]@{
            AdvisorConfirmed         = 0
            SkuFamily                = 0
            RetireCount              = 0
            CostCovered              = 0
            CostMissing              = 0
            SkuChangeWithGenChange   = 0
            SkuChangeWithoutGenChange = 0
            Rows                     = @()
            MonitoringRows           = @()
            MonitoringConfirmed      = 0
            MonitoringUnconfirmed    = 0
            MonitoringUnknown        = 0
            MonitoringDistinctVmCount = 0
        }
        $badPriceRow = [pscustomobject]@{
            VmName                     = 'vm-windows'
            CurrentSku                 = 'Standard_D2s_v5'
            OsType                     = 'Windows'
            CurrentPriceOsBasis        = 'Linux'
            CurrentWindowsMeterAvailable = $true
        }

        {
            Assert-ReportConsistency -Facts $facts -Rows @($badPriceRow)
        } | Should -Throw
    }

    It 'HTML-encodes resource-controlled values in remediation output' {
        $row = [pscustomobject]@{
            VmName                    = '<script>alert(1)</script>'
            CurrentSku                = 'Standard_D2_v2'
            CandidateTargetSku         = 'Standard_D2s_v5'
            Region                    = 'eastus'
            RetirementDate            = '2028-05-01'
            RetirementRiskLevel        = 'Medium'
            RetirementClass            = 'SkuFamily'
            RetirementSourceGate       = 'LiveLearnMarkdown'
            EvidenceSource             = 'LiveLearnMarkdown'
            SensitiveWorkload          = $false
            GenerationChange           = $false
            RecommendationBasis        = 'test'
            CommitmentRetirementImpact = $false
        }
        $plan = Build-RemediationPlan -Rows @($row)

        $html = ConvertTo-RemediationPlanHtml -Plan $plan

        $html | Should -Not -Match '<script>'
        $html | Should -Match '&lt;script&gt;'
    }

    It 'suppresses empty and HTML-only checklist entries in both remediation renderers' {
        $row = [pscustomobject]@{
            VmName                     = 'checklist-filter'
            CurrentSku                 = 'Standard_B4ms'
            RecommendedSku             = 'Standard_B4as_v2'
            CandidateTargetSku         = 'Standard_B4as_v2'
            Region                     = 'uksouth'
            RetirementDate             = '2028-11-15'
            RetirementRiskLevel        = 'Medium'
            RetirementClass            = 'SkuFamily'
            RetirementSourceGate       = 'LiveLearnMarkdown'
            EvidenceSource             = 'LiveLearnMarkdown'
            SourceTag                  = 'Learn (SKU-family, verify in Workbook)'
            WhatHappens                = 'Microsoft Learn SKU-family retirement: verify VM scope in Workbook'
            Validation                 = 'Validate target compatibility and regional availability.'
            NextStep                   = 'Schedule SKU migration.'
            RetailDeltaMonthly         = $null
            CostDeltaPercent           = $null
            SensitiveWorkload          = $false
            GenerationChange           = $false
            RecommendationBasis        = 'Rule-based: burstable continuity (same CPU credit model)'
            CommitmentRetirementImpact = $false
        }
        $plan = Build-RemediationPlan -Rows @($row)
        $item = $plan.Waves[4].Items[0]
        $item.Checklist = @(
            'Verify regional quota / capacity for the target SKU before scheduling.'
            ''
            '   '
            '<br>'
            '<br/>'
            '&nbsp;'
        )
        $facts = [pscustomobject]@{
            RetailDeltaMonthly          = $null
            MonitoringRows              = @()
            SkuChangeWithGenChange      = 0
            SkuChangeWithoutGenChange   = 1
            RecommendationWithheldCount = 0
            CommitmentImpactCount       = 0
            RetireCount                 = 1
            TotalVmCount                = 1
            AdvisorConfirmed            = 0
            SkuFamily                   = 1
            GeneratedAtUtc              = '2026-07-13 00:00:00'
            MonitoringDistinctVmCount   = 0
            MonitoringConfirmed         = 0
            MonitoringUnconfirmed       = 0
            MonitoringUnknown           = 0
            Rows                        = @($row)
        }
        $path = Join-Path $TestDrive 'checklist-filter.html'

        $legacyHtml = ConvertTo-RemediationPlanHtml -Plan $plan
        ConvertTo-SimplifiedReportHtml -Facts $facts -Path $path -RemediationPlan $plan
        $reportHtml = Get-Content -LiteralPath $path -Raw

        @($item.Checklist | Where-Object { Test-MeaningfulChecklistEntry $_ }).Count | Should -Be 1
        $legacyChecklist = [regex]::Matches($legacyHtml, '<ul class="wave-checklist">(?s:.*?)</ul>').Value | Select-Object -First 1
        $reportChecklist = [regex]::Matches($reportHtml, "<details class='mini'><summary>Checklist</summary><ul>(?s:.*?)</ul>").Value | Select-Object -First 1
        $legacyChecklist | Should -Not -Match '<li[^>]*>\s*(?:<br\s*/?>|&nbsp;)?\s*</li>'
        [regex]::Matches($legacyChecklist, '<li>').Count | Should -Be 1
        $reportChecklist | Should -Not -Match '<li[^>]*>\s*(?:<br\s*/?>|&lt;br/?&gt;|&nbsp;)?\s*</li>'
        [regex]::Matches($reportChecklist, '<li>').Count | Should -Be 1
    }

    It 'does not present a cross-family migration rationale for a row with no compatible target' {
        $row = [pscustomobject]@{
            VmName                     = 'no-target'
            CurrentSku                 = 'Standard_A1_v2'
            CandidateTargetSku         = 'N/A'
            Region                     = 'uksouth'
            RetirementDate             = '2028-11-15'
            RetirementRiskLevel        = 'Medium'
            RetirementSourceGate       = 'LiveLearnMarkdown'
            EvidenceSource             = 'LiveLearnMarkdown'
            SensitiveWorkload          = $false
            GenerationChange           = $false
            RecommendationBasis        = 'Heuristic: cross-family migration (requires architecture validation)'
            CommitmentRetirementImpact = $false
        }

        $plan = Build-RemediationPlan -Rows @($row)
        $item = @($plan.Waves[4].Items | Where-Object VmName -eq 'no-target')[0]

        $item | Should -Not -BeNullOrEmpty
        $item.Rationale | Should -Match 'No compatible in-family or same-shape target found'
        $item.Rationale | Should -Not -Match 'cross-family'
        # The exported RecommendationBasis field must stay untouched: the fix is presentation-only and
        # must not rewrite the CSV/JSON row value.
        $row.RecommendationBasis | Should -Be 'Heuristic: cross-family migration (requires architecture validation)'
    }

    It 'keeps a cross-family rationale when the normalized family fact is cross-family' {
        $row = [pscustomobject]@{
            VmName                     = 'cross-family-target'
            CurrentSku                 = 'Standard_A1_v2'
            CandidateTargetSku         = 'Standard_F2als_v7'
            Region                     = 'uksouth'
            RetirementDate             = '2028-11-15'
            RetirementRiskLevel        = 'Medium'
            RetirementSourceGate       = 'LiveLearnMarkdown'
            EvidenceSource             = 'LiveLearnMarkdown'
            SensitiveWorkload          = $false
            GenerationChange           = $true
            RecommendationBasis        = 'Heuristic: cross-family migration (requires architecture validation)'
            CommitmentRetirementImpact = $false
        }

        $plan = Build-RemediationPlan -Rows @($row)
        $item = @($plan.Waves[3].Items | Where-Object VmName -eq 'cross-family-target')[0]

        $item.CrossFamily | Should -BeTrue
        $item.Rationale | Should -Match 'cross-family migration'
    }

    It 'reconciles the change-type summary to the retirement total via an unclassified (no catalog target) bucket' {
        $rows = @(
            [pscustomobject]@{ VmName = 'gen-row'; CurrentSku = 'Standard_F2'; CandidateTargetSku = 'Standard_F2als_v7'; Region = 'uksouth'; RetirementDate = '2028-11-15'; RetirementRiskLevel = 'Medium'; RetirementSourceGate = 'LiveLearnMarkdown'; EvidenceSource = 'LiveLearnMarkdown'; SensitiveWorkload = $false; GenerationChange = $true; RetailDeltaMonthly = 1.0; CommitmentRetirementImpact = $false }
            [pscustomobject]@{ VmName = 'same-row'; CurrentSku = 'Standard_B4ms'; CandidateTargetSku = 'Standard_B4as_v2'; Region = 'uksouth'; RetirementDate = '2028-11-15'; RetirementRiskLevel = 'Medium'; RetirementSourceGate = 'LiveLearnMarkdown'; EvidenceSource = 'LiveLearnMarkdown'; SensitiveWorkload = $false; GenerationChange = $false; RetailDeltaMonthly = -1.0; CommitmentRetirementImpact = $false }
            [pscustomobject]@{ VmName = 'na-row'; CurrentSku = 'Standard_A1_v2'; CandidateTargetSku = 'N/A'; Region = 'uksouth'; RetirementDate = '2028-11-15'; RetirementRiskLevel = 'Medium'; RetirementSourceGate = 'LiveLearnMarkdown'; EvidenceSource = 'LiveLearnMarkdown'; SensitiveWorkload = $false; GenerationChange = $false; CommitmentRetirementImpact = $false }
        )
        $facts = Build-ReportFacts -Rows $rows
        $plan = Build-RemediationPlan -Rows $rows
        $path = Join-Path $TestDrive 'change-type.html'

        ConvertTo-SimplifiedReportHtml -Facts $facts -Path $path -RemediationPlan $plan
        $html = Get-Content -LiteralPath $path -Raw
        $summary = [regex]::Match($html, '(?s)<h2>Summary by Change Type</h2>.*?</section>').Value

        $summary | Should -Match 'Unclassified \(no catalog target\)'
        $facts.RecommendationWithheldCount | Should -Be 1
        ($facts.SkuChangeWithoutGenChange + $facts.SkuChangeWithGenChange + $facts.RecommendationWithheldCount) | Should -Be $facts.RetireCount
    }
}