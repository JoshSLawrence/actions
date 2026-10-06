<!-- BEGIN_TF_DOCS -->
# basic (test fixture)

A root module the CI workflows run against. It needs no cloud account:
`random_pet` and `terraform_data` only touch local state. It's deployed
three times, once per var file in `deployments/` (`dev.tfvars`,
`prod.tfvars`, `staging-eu.tfvars`), each setting its own state file
through `state_path`, which the backend block reads. It has a child module,
`modules/label`.

## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.9.0 |
| <a name="requirement_random"></a> [random](#requirement\_random) | ~> 3.7 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_random"></a> [random](#provider\_random) | 3.9.1 |
| <a name="provider_terraform"></a> [terraform](#provider\_terraform) | n/a |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_label"></a> [label](#module\_label) | ./modules/label | n/a |

## Resources

| Name | Type |
| ---- | ---- |
| [random_pet.this](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/pet) | resource |
| [terraform_data.record](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_name_prefix"></a> [name\_prefix](#input\_name\_prefix) | Prefix for the generated name. Lowercase letters and digits, starting with a letter. | `string` | n/a | yes |
| <a name="input_state_path"></a> [state\_path](#input\_state\_path) | Local state file for this deployment, set in its .tfvars (e.g. dev.tfstate). | `string` | n/a | yes |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags recorded alongside the generated name. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_name"></a> [name](#output\_name) | The generated name. |
<!-- END_TF_DOCS -->
