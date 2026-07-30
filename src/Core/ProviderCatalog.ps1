$script:DeepSeekPricingCatalog = [pscustomobject]@{
    SchemaVersion = 1
    Currency = 'CNY'
    TokensPerUnit = 1000000.0
    ProModelPattern = '(?i)(v4-pro|opus)'
    Standard = [pscustomobject]@{
        CacheHit = 0.02
        CacheMiss = 1.0
        Output = 2.0
    }
    Pro = [pscustomobject]@{
        CacheHit = 0.025
        CacheMiss = 3.0
        Output = 6.0
    }
}

function Get-DeepSeekPricingCatalog {
    return $script:DeepSeekPricingCatalog
}

function Get-DeepSeekPricingTier {
    param(
        [string]$Model,
        $Catalog = (Get-DeepSeekPricingCatalog)
    )

    if ($Model -match $Catalog.ProModelPattern) {
        return $Catalog.Pro
    }
    return $Catalog.Standard
}
