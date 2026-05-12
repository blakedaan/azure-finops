# FinOps

Azure cost management and billing analysis scripts.

-----

## Get-AzureSubscriptionCosts.ps1

Queries actual Azure spend per subscription for a given billing period using the
Cost Management REST API. Built using `Invoke-AzRestMethod` — no `Az.CostManagement`
module required.

### Prerequisites

- [Az PowerShell module](https://learn.microsoft.com/en-us/powershell/azure/install-az-ps)
- Authenticated session via `Connect-AzAccount`
- `Cost Management Reader` on the target subscription(s), or at Management Group /
  Billing Account scope for full coverage

### Usage

```powershell
# Query a specific month
.\Get-AzureSubscriptionCosts.ps1 -StartDate "2026-04-01" -EndDate "2026-04-30"

# Query current month (default)
.\Get-AzureSubscriptionCosts.ps1

# Export results to CSV
.\Get-AzureSubscriptionCosts.ps1 -StartDate "2026-04-01" -EndDate "2026-04-30" -ExportCsv ".\april-costs.csv"
```

### Default Behavior

The script will **run without prompting** for dates — parameters are optional, not mandatory.
If you run it without arguments, it silently defaults to:

- `StartDate` → first day of the current month
- `EndDate` → today

So running `.\Get-AzureSubscriptionCosts.ps1` with no arguments in May 2026 queries
May 1–today, not a full prior month. Always pass explicit dates when validating against
a completed billing period:

```powershell
.\Get-AzureSubscriptionCosts.ps1 -StartDate "2026-04-01" -EndDate "2026-04-30"
```

### Output

Subscriptions are split into two groups:

- **Accessible** — returned real cost data, sorted by spend descending with a grand total
- **No Access** — returned $0 due to insufficient Cost Management RBAC at that scope

### Running in Azure Cloud Shell

Cloud Shell is the easiest way to run this — no local Az module install needed,
and you’re already authenticated.

**Recommended: clone this repo directly in Cloud Shell**

Cloud Shell has persistent storage backed by an Azure File Share, so files survive
between sessions. The cleanest workflow is:

```bash
# First time — clone your repo into Cloud Shell home directory
cd ~
git clone https://github.com/<your-username>/finops.git
cd finops

# Run the script
pwsh Get-AzureSubscriptionCosts.ps1 -StartDate "2026-04-01" -EndDate "2026-04-30"

# Pull updates when you change the script locally
git pull
```

**Alternative: upload the file manually**

In the Cloud Shell toolbar, click the **Upload/Download** button and upload the `.ps1`
directly. Files land in `$HOME` (`/home/<alias>/`). This works but doesn’t persist as
cleanly as a cloned repo — if you update the script you’d need to re-upload.

**Note on shell type**

Cloud Shell defaults to Bash. Either switch to PowerShell mode in the Cloud Shell
toolbar, or invoke the script explicitly with `pwsh` from Bash as shown above.

### Important Notes on Azure Billing vs Resource Tags

Azure has two independent tagging systems that are easy to confuse:

**Resource tags** are applied to individual Azure resources (VMs, storage accounts, etc.)
and are visible in the portal and via Azure Resource Graph. These are managed by anyone
with Contributor access on the resource.

**Billing tags** are applied directly to billing data by a **Billing Administrator** and
operate independently from resource tags. A Billing Admin can tag billing records at the
subscription level without touching the underlying resources. This means:

- A resource can appear untagged in ARG but still be correctly attributed in billing reports
- Billing-level tag inheritance can fill gaps that resource-level tagging misses
- Cost Management exports and pivot reports built by a Billing Admin will reflect billing
  tags, not resource tags — so comparing ARG tag coverage to a billing pivot is not
  an apples-to-apples check

This script queries the Cost Management API at the subscription scope, which reflects
**actual billed costs** but is subject to your RBAC scope. For a complete cross-subscription
view, Cost Management Reader at the Management Group or Billing Account level is required.

### Extending the Script

To group costs by CostCenter tag, uncomment the `grouping` block inside the script:

```powershell
grouping = @(
    @{ type = "TagKey"; name = "CostCenter" }
)
```

-----

## ARG Queries

### Untagged Resources by Subscription

Identifies resources missing a `CostCenter` tag, grouped by resource type and subscription.
Useful for tagging hygiene audits and understanding billing attribution gaps.

```kusto
Resources
| where isempty(tags['CostCenter']) or isnull(tags['CostCenter'])
| summarize count() by type, subscriptionId
| order by count_ desc
```

### Subscription Tag Coverage

Checks whether subscriptions themselves have a `CostCenter` tag, which is the foundation
for billing-level tag inheritance.

```kusto
ResourceContainers
| where type == "microsoft.resources/subscriptions"
| extend CostCenter = tostring(tags['CostCenter'])
| project subscriptionId, name, CostCenter,
    Tagged = iff(isnotempty(CostCenter), "Tagged", "Missing")
| order by Tagged asc
```

### Untagged Resource Count by Subscription (Summary)

Cross-references tagged vs untagged resource counts per subscription so you can
prioritize remediation by exposure.

```kusto
Resources
| extend CostCenter = tostring(tags['CostCenter'])
| summarize
    TotalResources    = count(),
    UntaggedResources = countif(isempty(CostCenter)),
    TaggedResources   = countif(isnotempty(CostCenter))
    by subscriptionId
| extend UntaggedPct = round(todouble(UntaggedResources) / todouble(TotalResources) * 100, 1)
| order by UntaggedResources desc
```