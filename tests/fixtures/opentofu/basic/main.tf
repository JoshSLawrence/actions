# Needs no cloud account or backend: random_pet and terraform_data only touch
# local state, so CI can plan and apply this fixture on every run.
resource "random_pet" "this" {
  prefix = var.name_prefix
  length = 2
}

# A child module inside this root module: a change under modules/label is a
# change to this module, so it selects every deployment of it.
module "label" {
  source = "./modules/label"

  name = random_pet.this.id
  tags = var.tags
}

resource "terraform_data" "record" {
  input = module.label.label
}
