<#
.SYNOPSIS
    Queries actual Azure spend per subscription for a given date range using the
    Cost Management REST API via Invoke-AzRestMethod (no Az.CostManagement module required).

.DESCRIPTION
    Iterates over all subscriptions visible to the authenticated account and pulls
    total cost for the specified billing period. Results are sorted by cost descending
    and can be exported to CSV.

    Note: Only subscriptions where the authenticated principal has Cost Management Reader
    (or higher) at the subscription scope will return cost data. Others will return $0.
    For full coverage, Cost Management Reader at the Management Group or Billing Account
    scope is required.

.PARAMETER StartDate
    Start of the billing period in YYYY-MM-DD format. Defaults to first day of current month.

.PARAMETER EndDate
    End of the billing period in YYYY-MM-DD format. Defaults to today.

.PARAMETER ExportCsv
    Optional. If specified, exports results to a CSV file at this path.

.EXAMPLE
    # Query April 2026 spend and print to console
    .\Get-AzureSubscriptionCosts.ps1 -StartDate "2026-04-01" -EndDate "2026-04-30"

.EXAMPLE
    # Query current month and export to CSV
    .\Get-AzureSubscriptionCosts.ps1 -ExportCsv "C:\FinOps\april-costs.csv"

.NOTES
    Prerequisites:
        - Az PowerShell module installed (Install-Module Az)
        - Authenticated via Connect-AzAccount
        - Cost Management Reader on target subscription(s) or higher scope

    Author: Blake Daniels
#>

[CmdletBinding()]
param (
    [string]$StartDate = (Get-Date -Day 1 -Format "yyyy-MM-dd"),
    [string]$EndDate   = (Get-Date -Format "yyyy-MM-dd"),
    [string]$ExportCsv
)

# ─────────────────────────────────────────────
# Validate date range
# ─────────────────────────────────────────────
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

# ─────────────────────────────────────────────
# Verify Az session
# ─────────────────────────────────────────────
$context = Get-AzContext
if (-not $context) {
    Write-Host "No active Azure session found. Running Connect-AzAccount..." -ForegroundColor Yellow
    Connect-AzAccount
}

Write-Host "`nQuerying Azure subscription costs from $StartDate to $EndDate..." -ForegroundColor Cyan
Write-Host "Authenticated as: $($context.Account.Id)`n"

# ─────────────────────────────────────────────
# Get all subscriptions visible to this principal
# ─────────────────────────────────────────────
$subs = Get-AzSubscription

if (-not $subs) {
    Write-Error "No subscriptions found. Verify account permissions."
    exit 1
}

Write-Host "Found $($subs.Count) subscription(s). Querying Cost Management API..." -ForegroundColor Cyan

# ─────────────────────────────────────────────
# Query Cost Management REST API per subscription
# Uses Invoke-AzRestMethod — no Az.CostManagement module needed
# API Ref: https://learn.microsoft.com/en-us/rest/api/cost-management/query/usage
# ─────────────────────────────────────────────
$results = foreach ($sub in $subs) {

    $body = @{
        type       = "ActualCost"
        timeframe  = "Custom"
        timePeriod = @{
            from = $StartDate
            to   = $EndDate
        }
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

    $uri = "/subscriptions/$($sub.Id)/providers/Microsoft.CostManagement/query?api-version=2023-11-01"

    try {
        $response = Invoke-AzRestMethod -Method POST -Path $uri -Payload $body

        # HTTP 200 = success; anything else means no access or an API error
        if ($response.StatusCode -eq 200) {
            $data = $response.Content | ConvertFrom-Json
            $cost = if ($data.properties.rows.Count -gt 0) {
                [math]::Round($data.properties.rows[0][0], 2)
            } else {
                0.00
            }
            $status = "OK"
        } else {
            $cost   = $null
            $status = "HTTP $($response.StatusCode) - No access or API error"
        }
    } catch {
        $cost   = $null
        $status = "Exception: $_"
    }

    [PSCustomObject]@{
        Subscription   = $sub.Name
        SubscriptionId = $sub.Id
        AprilCost      = $cost
        Status         = $status
    }
}

# ─────────────────────────────────────────────
# Output results
# ─────────────────────────────────────────────

$accessible   = $results | Where-Object { $_.Status -eq "OK" }
$inaccessible = $results | Where-Object { $_.Status -ne "OK" }

Write-Host "`n=== SUBSCRIPTION COSTS (where you have Cost Management access) ===" -ForegroundColor Green
$accessible | Sort-Object AprilCost -Descending | Format-Table Subscription, SubscriptionId, AprilCost -AutoSize

$grandTotal = ($accessible | Measure-Object -Property AprilCost -Sum).Sum
Write-Host "Accessible Subscriptions Total: `$$([math]::Round($grandTotal, 2))" -ForegroundColor Green

if ($inaccessible) {
    Write-Host "`n=== SUBSCRIPTIONS WITH NO COST MANAGEMENT ACCESS ===" -ForegroundColor Yellow
    $inaccessible | Format-Table Subscription, SubscriptionId, Status -AutoSize
    Write-Host "Note: These subscriptions require Cost Management Reader at a higher scope" -ForegroundColor Yellow
    Write-Host "      (Management Group or Billing Account) to retrieve cost data.`n" -ForegroundColor Yellow
}

# ─────────────────────────────────────────────
# Optional CSV export
# ─────────────────────────────────────────────
if ($ExportCsv) {
    try {
        $results | Sort-Object AprilCost -Descending | Export-Csv -Path $ExportCsv -NoTypeInformation
        Write-Host "Results exported to: $ExportCsv" -ForegroundColor Cyan
    } catch {
        Write-Error "Failed to export CSV: $_"
    }
}