<!-- BEGIN_TF_DOCS -->
# basic (test fixture)

Root module the CI workflow runs the OpenTofu reusable workflow against. It
needs no cloud account: `random_pet` and `terraform_data` only touch local
state. It exercises every check, the plan summary, the policy check (see
`policy/`), and apply.

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

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [random_pet.this](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/pet) | resource |
| [terraform_data.record](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_name_prefix"></a> [name\_prefix](#input\_name\_prefix) | Prefix for the generated name. Lowercase letters and digits, starting with a letter. | `string` | n/a | yes |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags recorded alongside the generated name. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_name"></a> [name](#output\_name) | The generated name. |
<!-- END_TF_DOCS -->
