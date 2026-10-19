resource "aws_organizations_policy" "deny_root_user" {
  name    = "DenyRootUserActions"
  content = file("${path.module}/policies/deny-root-user.json")
}

resource "aws_organizations_policy" "deny_regions_except_us_east_1" {
  name    = "DenyRegionsExceptUSEast1"
  content = file("${path.module}/policies/deny-regions-except-us-east-1.json")
}

resource "aws_organizations_policy_attachment" "deny_root_user_prod_account" {
  policy_id = aws_organizations_policy.deny_root_user.id
  target_id = aws_organizations_account.prod.id
}

# The region policy attaches to the OU only. The guard must reject it.
resource "aws_organizations_policy_attachment" "deny_regions_except_us_east_1" {
  policy_id = aws_organizations_policy.deny_regions_except_us_east_1.id
  target_id = aws_organizations_organizational_unit.workload.id
}
