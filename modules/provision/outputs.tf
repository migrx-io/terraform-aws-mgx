output "id" {
  description = "ID of the provisioning resource for this node (ssh transform id, or ssm association id)."
  value = local.is_ssh ? (
    length(terraform_data.node) > 0 ? terraform_data.node[0].id : ""
    ) : (
    length(aws_ssm_association.node) > 0 ? aws_ssm_association.node[0].id : ""
  )
}
