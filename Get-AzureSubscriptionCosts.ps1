<#
.SYNOPSIS
    Queries both ActualCost and AmortizedCost per subscription for a given date range
    using the Cost Management REST API via Invoke-AzRestMethod (no Az.CostManagement
    module required).

.DESCRIPTION
    Iterates over all subscriptions visible to the authenticated account and pulls
    both cost types for the specified billing period:

    - ActualCost:    Raw spend as charges hit the subscription. Includes full
                     reservation/savings plan purchases in the month they occurred.

    - AmortizedCost: Spreads reservation and savings plan costs evenly across the
                     period they cover. Closer to what appears in invoice-based
                     billing exports.

    The delta between the two reveals how much savings plan/reservation spend is
    affecting any given subscription in the queried period.

    Note: Only subscriptions where the authenticated principal has Cost Management
    Reader (or higher) at the subscription scope will return data. Others return
    HTTP 401. For full coverage, Cost Management Reader at the Management Group or
    Billing Account scope is required.

.PARAMETER StartDate
    Start of the billing period in YYYY-MM-DD format. Defaults to first day of current month.

.PARAMETER EndDate
    End of the billing period in YYYY-MM-DD format. Defaults to today.

.PARAMETER ExportCsv
    Optional. If specified, exports results to a CSV file at this path.

.EXAMPLE
    # Query April 2026 and print to console
    .\Get-AzureSubscriptionCosts.ps1 -StartDate "2026-04-01" -EndDate "2026-04-30"

.EXAMPLE
    # Query current month to date (default - no args needed)
    .\Get-AzureSubscriptionCosts.ps1

.EXAMPLE
    # Query April 2026 and export to CSV
    .\Get-AzureSubscriptionCosts.ps1 -StartDate "2026-04-01" -EndDate "2026-04-30" -ExportCsv ".\april-costs.csv"

.NOTES
    Prerequisites:
        - Az PowerShell module installed (Install-Module Az)
        - Authenticated via Connect-AzAccount
        - Cost Management Reader on target subscription(s) or higher scope

    Author: Blake Daniels
    Repo:   github.com/bdaniel/finops
#>

[CmdletBinding()]
param (
    [string]$StartDate = (Get-Date -Day 1 -Format "yyyy-MM-dd"),
    [string]$EndDate   = (Get-Date -Format "yyyy-MM-dd"),
    [string]$ExportCsv
)

# ---------------------------------------------
# Validate date range
# ---------------------------------------------
try {
    $start = [datetime]::ParseExact($StartDate, "yyyy-MM-dd", $null)
    $end   = [datetime]::ParseExact($EndDate,   "yyyy-MM-dd", $null)
} catch {
    Write-Error "Invalid date format. Use YYYY-MM-DD."
    exit 1
}

if ($end -lt $start) {
    Write-Error "EndDate must be on or after StartDate."
    exit 1
}

# Cost Management API enforces a maximum query window of 366 days
$daySpan = ($end - $start).Days
if ($daySpan -gt 366) {
    Write-Error "Date range is $daySpan days. The Cost Management API maximum is 366 days. Narrow your range and try again."
    exit 1
}

# ---------------------------------------------
# Verify Az session
# ---------------------------------------------
$context = Get-AzContext
if (-not $context) {
    Write-Host "No active Azure session found. Running Connect-AzAccount..." -ForegroundColor Yellow
    Connect-AzAccount
}

Write-Host "`nQuerying Azure subscription costs from $StartDate to $EndDate..." -ForegroundColor Cyan
Write-Host "Authenticated as: $($context.Account.Id)`n"

# ---------------------------------------------
# Get all subscriptions visible to this principal
# ---------------------------------------------
$subs = Get-AzSubscription

if (-not $subs) {
    Write-Error "No subscriptions found. Verify account permissions."
    exit 1
}

Write-Host "Found $($subs.Count) subscription(s). Querying Cost Management API (3 calls per sub)..." -ForegroundColor Cyan

# ---------------------------------------------
# Helper function - queries one cost type for one subscription
# Only requests Cost which is valid at subscription scope.
# API Ref: https://learn.microsoft.com/en-us/rest/api/cost-management/query/usage
# ---------------------------------------------
function Get-SubCost {
    param (
        [string]$SubscriptionId,
        [string]$CostType,       # "ActualCost" or "AmortizedCost"
        [string]$From,
        [string]$To
    )

    # Main cost query - only uses Cost which is valid at subscription scope
    $body = @{
        type       = $CostType
        timeframe  = "Custom"
        timePeriod = @{ from = $From; to = $To }
        dataset    = @{
            granularity = "None"
            aggregation = @{
                totalCost = @{ name = "Cost"; function = "Sum" }
            }
            # Optional: uncomment to also group by CostCenter tag
            # grouping = @(
            #     @{ type = "TagKey"; name = "CostCenter" }
            # )
        }
    } | ConvertTo-Json -Depth 10

    $uri = "/subscriptions/$SubscriptionId/providers/Microsoft.CostManagement/query?api-version=2023-11-01"

    try {
        $response = Invoke-AzRestMethod -Method POST -Path $uri -Payload $body

        if ($response.StatusCode -eq 200) {
            $data    = $response.Content | ConvertFrom-Json
            $columns = $data.properties.columns.name
            $rows    = $data.properties.rows

            $getCol = {
                param($colName)
                $idx = [array]::IndexOf($columns, $colName)
                if ($idx -ge 0 -and $rows.Count -gt 0) {
                    [math]::Round($rows[0][$idx], 2)
                } else { $null }
            }

            $cost = & $getCol "Cost"
            return @{ Cost = $cost; Status = "OK" }
        } else {
            return @{ Cost = $null; Status = "HTTP $($response.StatusCode) - No access or API error" }
        }
    } catch {
        return @{ Cost = $null; Status = "Exception: $_" }
    }
}

# ---------------------------------------------
# Separate tax query - isolated so a 400 here does not affect main results
# Tax and CostWithTax are MCA/EA billing account scope fields only.
# Expected to fail at subscription scope - surfaced clearly in output.
# ---------------------------------------------
function Get-SubTax {
    param (
        [string]$SubscriptionId,
        [string]$From,
        [string]$To
    )

    $body = @{
        type       = "ActualCost"
        timeframe  = "Custom"
        timePeriod = @{ from = $From; to = $To }
        dataset    = @{
            granularity = "None"
            aggregation = @{
                totalCost        = @{ name = "Cost";        function = "Sum" }
                totalTax         = @{ name = "Tax";         function = "Sum" }
                totalCostWithTax = @{ name = "CostWithTax"; function = "Sum" }
            }
        }
    } | ConvertTo-Json -Depth 10

    $uri = "/subscriptions/$SubscriptionId/providers/Microsoft.CostManagement/query?api-version=2023-11-01"

    try {
        $response = Invoke-AzRestMethod -Method POST -Path $uri -Payload $body

        if ($response.StatusCode -eq 200) {
            $data    = $response.Content | ConvertFrom-Json
            $columns = $data.properties.columns.name
            $rows    = $data.properties.rows

            $getCol = {
                param($colName)
                $idx = [array]::IndexOf($columns, $colName)
                if ($idx -ge 0 -and $rows.Count -gt 0) {
                    [math]::Round($rows[0][$idx], 2)
                } else { $null }
            }

            $tax         = & $getCol "Tax"
            $costWithTax = & $getCol "CostWithTax"

            $taxStatus = if ($null -ne $tax -and $tax -gt 0) {
                "Available"
            } elseif ($null -ne $tax) {
                "Returned zero - likely subscription scope limitation"
            } else {
                "Unavailable - requires Billing Account scope"
            }

            return @{ Tax = $tax; CostWithTax = $costWithTax; TaxStatus = $taxStatus }
        } else {
            return @{ Tax = $null; CostWithTax = $null; TaxStatus = "Unavailable - requires Billing Account scope (HTTP $($response.StatusCode))" }
        }
    } catch {
        return @{ Tax = $null; CostWithTax = $null; TaxStatus = "Exception: $_" }
    }
}

# ---------------------------------------------
# Query both cost types per subscription
# ---------------------------------------------
$results = foreach ($sub in $subs) {

    $actual    = Get-SubCost -SubscriptionId $sub.Id -CostType "ActualCost"    -From $StartDate -To $EndDate
    $amortized = Get-SubCost -SubscriptionId $sub.Id -CostType "AmortizedCost" -From $StartDate -To $EndDate

    # Calculate delta only when both calls succeeded
    # Positive delta = amortized > actual (savings plan cost spread into this period)
    # Negative delta = actual > amortized (savings plan purchase spike in actual view)
    $delta = if ($actual.Status -eq "OK" -and $amortized.Status -eq "OK") {
        [math]::Round($amortized.Cost - $actual.Cost, 2)
    } else {
        $null
    }

    # Build a combined status so partial results (one call OK, one failed) are visible
    $combinedStatus = if ($actual.Status -eq "OK" -and $amortized.Status -eq "OK") {
        "OK"
    } elseif ($actual.Status -eq "OK" -and $amortized.Status -ne "OK") {
        "Partial: AmortizedCost failed ($($amortized.Status))"
    } else {
        $actual.Status
    }

    # Tax queried separately so a failure does not affect ActualCost/AmortizedCost
    $taxData = Get-SubTax -SubscriptionId $sub.Id -From $StartDate -To $EndDate

    [PSCustomObject]@{
        Subscription   = $sub.Name
        SubscriptionId = $sub.Id
        # Coerce null to 0.00 so blank cells never appear in output
        ActualCost     = if ($null -ne $actual.Cost)         { $actual.Cost }         else { 0.00 }
        AmortizedCost  = if ($null -ne $amortized.Cost)      { $amortized.Cost }      else { 0.00 }
        Delta          = if ($null -ne $delta)               { $delta }               else { 0.00 }
        Tax            = if ($null -ne $taxData.Tax)         { $taxData.Tax }         else { "N/A" }
        CostWithTax    = if ($null -ne $taxData.CostWithTax) { $taxData.CostWithTax } else { "N/A" }
        TaxStatus      = $taxData.TaxStatus
        Status         = $combinedStatus
    }
}

# ---------------------------------------------
# Output results
# ---------------------------------------------
# Include "Partial" rows in accessible so ActualCost is still reported
$accessible   = $results | Where-Object { $_.Status -eq "OK" -or $_.Status -like "Partial*" }
$inaccessible = $results | Where-Object { $_.Status -ne "OK" }

Write-Host "`n=== SUBSCRIPTION COSTS (where you have Cost Management access) ===" -ForegroundColor Green
$accessible | Sort-Object AmortizedCost -Descending |
    Format-Table Subscription, SubscriptionId, ActualCost, AmortizedCost, Delta, Tax, CostWithTax -AutoSize

$actualTotal    = [math]::Round(($accessible | Measure-Object -Property ActualCost    -Sum).Sum, 2)
$amortizedTotal = [math]::Round(($accessible | Measure-Object -Property AmortizedCost -Sum).Sum, 2)

Write-Host "Accessible Subscriptions -- ActualCost Total:    `$$actualTotal"    -ForegroundColor Green
Write-Host "Accessible Subscriptions -- AmortizedCost Total: `$$amortizedTotal" -ForegroundColor Green

# Report tax data availability - confirms whether Billing Account scope is needed
$taxStatuses = $accessible | Select-Object -ExpandProperty TaxStatus -Unique
Write-Host "`n=== TAX DATA AVAILABILITY ===" -ForegroundColor Cyan
$accessible | Select-Object Subscription, Tax, CostWithTax, TaxStatus | Format-Table -AutoSize
Write-Host "Note: Tax and CostWithTax require Billing Account Reader scope (MCA/EA)." -ForegroundColor Cyan
Write-Host "      If Tax shows zero or unavailable, request Billing Account Reader via PIM.`n" -ForegroundColor Cyan

if ($inaccessible) {
    Write-Host "`n=== SUBSCRIPTIONS WITH NO COST MANAGEMENT ACCESS ===" -ForegroundColor Yellow
    $inaccessible | Format-Table Subscription, SubscriptionId, Status -AutoSize
    Write-Host "Note: These subscriptions require Cost Management Reader at a higher scope" -ForegroundColor Yellow
    Write-Host "      (Management Group or Billing Account) to retrieve cost data.`n"      -ForegroundColor Yellow
}

# ---------------------------------------------
# Optional CSV export
# ---------------------------------------------
if ($ExportCsv) {
    try {
        $results | Sort-Object AmortizedCost -Descending | Export-Csv -Path $ExportCsv -NoTypeInformation
        Write-Host "Results exported to: $ExportCsv" -ForegroundColor Cyan
    } catch {
        Write-Error "Failed to export CSV: $_"
    }
}
