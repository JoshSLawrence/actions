# Needs no cloud account or backend: random_pet and terraform_data only touch
# local state, so CI can plan and apply this fixture on every run.
resource "random_pet" "this" {
  prefix = var.name_prefix
  length = 2
}

# A local module outside this root module: discovery follows the source, so a
# change under ../modules/label selects this module too.
module "label" {
  source = "../modules/label"

  name = random_pet.this.id
  tags = var.tags
}

resource "terraform_data" "record" {
  input = module.label.label
}
