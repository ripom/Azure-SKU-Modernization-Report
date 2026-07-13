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
                SeriesName  = 'Dv2-series'
                Status      = 'Announced'
                RetireOn    = '2028-05-01'
                MatchRegexes = @()
                Source      = 'LiveLearnMarkdown'
            })
        }

        $result = Resolve-RetirementForSku -SkuName 'Standard_D2_v2' -Retirements $retirements

        $result | Should -Not -BeNullOrEmpty
        $result.SeriesName | Should -Be 'Dv2-series'
    }
}

Describe 'Live-source integrity' {
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

    It 'does not query Savings Plans as a standalone Retail price type' {
        $function = $script:SourceAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Get-RetailCommitmentSignalsForVirtualMachines'
        }, $true) | Select-Object -First 1

        $function.Extent.Text | Should -Not -Match "PriceType\s*=\s*'SavingsPlan'"
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

    It 'does not hide risk thresholds inside retirement risk classification' {
        (Get-Command Get-RetirementRiskLevel).Definition | Should -Not -Match '\b(365|730)\b'
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
            [pscustomobject]@{ VmName = 'demo-vm-01'; CurrentSku = 'Standard_DS2_v2'; CandidateTargetSku = 'Standard_D2ads_v7'; Region = 'italynorth'; RetirementDate = '2028-05-01'; RetirementRiskLevel = 'High'; RetirementSourceGate = 'LiveLearnMarkdown'; EvidenceSource = 'LiveLearnMarkdown'; SensitiveWorkload = $false; GenerationChange = $true; RetailDeltaMonthly = -1.46; CommitmentRetirementImpact = $false }
            [pscustomobject]@{ VmName = 'demo-vm-02'; CurrentSku = 'Standard_B4ms'; CandidateTargetSku = 'Standard_B4as_v2'; Region = 'uksouth'; RetirementDate = '2028-11-15'; RetirementRiskLevel = 'Medium'; RetirementSourceGate = 'LiveLearnMarkdown'; EvidenceSource = 'LiveLearnMarkdown'; SensitiveWorkload = $false; GenerationChange = $false; RetailDeltaMonthly = -12.41; CommitmentRetirementImpact = $false }
            [pscustomobject]@{ VmName = 'demo-vm-03'; CurrentSku = 'Standard_A1_v2'; CandidateTargetSku = 'N/A'; Region = 'uksouth'; RetirementDate = '2028-11-15'; RetirementRiskLevel = 'Medium'; RetirementSourceGate = 'LiveLearnMarkdown'; EvidenceSource = 'LiveLearnMarkdown'; SensitiveWorkload = $false; GenerationChange = $false; CommitmentRetirementImpact = $false }
            [pscustomobject]@{ VmName = 'demo-vm-04'; CurrentSku = 'Standard_A1_v2'; CandidateTargetSku = 'N/A'; Region = 'uksouth'; RetirementDate = '2028-11-15'; RetirementRiskLevel = 'Medium'; RetirementSourceGate = 'LiveLearnMarkdown'; EvidenceSource = 'LiveLearnMarkdown'; SensitiveWorkload = $false; GenerationChange = $false; CommitmentRetirementImpact = $false }
            [pscustomobject]@{ VmName = 'demo-vm-05'; CurrentSku = 'Standard_B2ms'; CandidateTargetSku = 'Standard_B2as_v2'; Region = 'uksouth'; RetirementDate = '2028-11-15'; RetirementRiskLevel = 'Medium'; RetirementSourceGate = 'LiveLearnMarkdown'; EvidenceSource = 'LiveLearnMarkdown'; SensitiveWorkload = $true; GenerationChange = $false; WorkloadRole = 'Identity-DirectorySync'; RetailDeltaMonthly = -5.09; CommitmentRetirementImpact = $false }
            [pscustomobject]@{ VmName = 'demo-vm-06'; CurrentSku = 'Standard_B4ms'; CandidateTargetSku = 'Standard_B4as_v2'; Region = 'uksouth'; RetirementDate = '2028-11-15'; RetirementRiskLevel = 'Medium'; RetirementSourceGate = 'LiveLearnMarkdown'; EvidenceSource = 'LiveLearnMarkdown'; SensitiveWorkload = $true; GenerationChange = $false; WorkloadRole = 'Identity-ADFS'; RetailDeltaMonthly = -12.41; CommitmentRetirementImpact = $false }
            [pscustomobject]@{ VmName = 'demo-vm-09'; CurrentSku = 'Standard_F2'; CandidateTargetSku = 'Standard_F2als_v7'; Region = 'uksouth'; RetirementDate = '2028-11-15'; RetirementRiskLevel = 'Medium'; RetirementSourceGate = 'LiveLearnMarkdown'; EvidenceSource = 'LiveLearnMarkdown'; SensitiveWorkload = $true; GenerationChange = $true; WorkloadRole = 'Infrastructure-DomainController'; RetailDeltaMonthly = 19.71; CommitmentRetirementImpact = $false }
            [pscustomobject]@{ VmName = 'demo-vm-10'; CurrentSku = 'Standard_A1_v2'; CandidateTargetSku = 'N/A'; Region = 'uksouth'; RetirementDate = '2028-11-15'; RetirementRiskLevel = 'Medium'; RetirementSourceGate = 'LiveLearnMarkdown'; EvidenceSource = 'LiveLearnMarkdown'; SensitiveWorkload = $false; GenerationChange = $false; CommitmentRetirementImpact = $false }
            [pscustomobject]@{ VmName = 'demo-vm-12'; CurrentSku = 'Standard_B4ms'; CandidateTargetSku = 'Standard_B4as_v2'; Region = 'uksouth'; RetirementDate = '2028-11-15'; RetirementRiskLevel = 'Medium'; RetirementSourceGate = 'LiveLearnMarkdown'; EvidenceSource = 'LiveLearnMarkdown'; SensitiveWorkload = $false; GenerationChange = $false; RetailDeltaMonthly = -12.41; CommitmentRetirementImpact = $false }
        )

        $plan = Build-RemediationPlan -Rows $rows

        $plan.TotalVms | Should -Be 9
        @($plan.Waves[0].Items).Count | Should -Be 0
        @($plan.Waves[1].Items).Count | Should -Be 1
        @($plan.Waves[2].Items).Count | Should -Be 2
        @($plan.Waves[3].Items).Count | Should -Be 1
        @($plan.Waves[4].Items).Count | Should -Be 5
        @($plan.Waves[1].Items | Where-Object VmName -eq 'demo-vm-01').Count | Should -Be 1
        @($plan.Waves[3].Items | Where-Object VmName -eq 'demo-vm-09').Count | Should -Be 1
    }

    It 'computes the Build-RemediationPlan invariant from row facts and the assigned plan wave' {
        $definition = (Get-Command Build-RemediationPlan).Definition

        $definition | Should -Match 'Resolve-RemediationWaveFloor -RiskLevel \$riskLevel -IsSensitiveWorkload \$sensitive -IsGenerationChange \$genChange -IsCrossFamily \$crossFamily'
        $definition | Should -Match '\$r\.Wave -ne \$expectedWave\.Wave'
        $definition | Should -Match 'risk=\$riskLevel sensitive=\$sensitive generationChange=\$genChange crossFamily=\$crossFamily'
        $definition | Should -Not -Match '\$waveResult\.Wave -ne \$expectedFloor'
        $definition | Should -Not -Match '\b(365|730)\b'
    }

    It 'keeps remediation wave assignment and the guard on the same floor resolver' {
        $resolveDefinition = (Get-Command Resolve-RemediationWave).Definition
        $buildDefinition = (Get-Command Build-RemediationPlan).Definition

        $resolveDefinition | Should -Match 'Resolve-RemediationWaveFloor'
        $buildDefinition | Should -Match 'Resolve-RemediationWaveFloor'
    }

    It 'does not hide risk thresholds inside remediation wave routing' {
        (Get-Command Resolve-RemediationWave).Definition | Should -Not -Match '\b(365|730)\b'
    }

    It 'labels High-only W1 rows as high urgency, not Advisor-sensitive' {
        $waveResult = Resolve-RemediationWave -RiskLevel High -IsSensitiveWorkload $false -IsGenerationChange $false -IsCrossFamily $false -AdvisorConfirmed:$false

        Get-WaveChipLabel -WaveResult $waveResult | Should -Be 'W1 · High urgency'
    }

    It 'keeps a medium-risk sensitive Gen1-to-Gen2 domain controller out of W4' {
        $row = [pscustomobject]@{
            VmName                    = 'domain-controller'
            CurrentSku                = 'Standard_F2'
            CandidateTargetSku         = 'Standard_F2als_v7'
            Region                    = 'eastus'
            RetirementDate            = '2028-11-15'
            RetirementRiskLevel        = 'Medium'
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
            RetirementSourceGate       = 'LiveLearnMarkdown'
            EvidenceSource             = 'LiveLearnMarkdown'
            WorkloadRole               = 'Infrastructure-DomainController'
            SensitiveWorkload          = $true
            GenerationChange           = $true
            RecommendationBasis        = 'Same-shape refresh: same vCPU/RAM profile'
            CommitmentRetirementImpact = $false
        }
        $facts = [pscustomobject]@{
            RetailDeltaMonthly          = 0
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

    It 'does not hide risk thresholds inside wave card header routing' {
        (Get-Command Get-WaveCardHeader).Definition | Should -Not -Match '\b(365|730)\b'
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
            RetirementSourceGate       = 'LiveLearnMarkdown'
            EvidenceSource             = 'LiveLearnMarkdown'
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
            Rows                        = @($row)
        }
        $plan = Build-RemediationPlan -Rows @($row)
        $path = Join-Path $TestDrive 'decision-room.html'

        ConvertTo-SimplifiedReportHtml -Facts $facts -Path $path -RemediationPlan $plan
        $html = Get-Content -LiteralPath $path -Raw

        $html | Should -Match '<div class="decision-tag">This sprint</div>\s*<div class="decision-value">0</div>\s*<div class="decision-title">Act now \(W0\)</div>'
        $html | Should -Match '<div class="decision-tag">Next wave</div>\s*<div class="decision-value">1</div>\s*<div class="decision-title">Plan with validation \(W1 \+ W2 \+ W3\)</div>'
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
            CandidateTargetSku         = 'Standard_B4as_v2'
            Region                     = 'uksouth'
            RetirementDate             = '2028-11-15'
            RetirementRiskLevel        = 'Medium'
            RetirementSourceGate       = 'LiveLearnMarkdown'
            EvidenceSource             = 'LiveLearnMarkdown'
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