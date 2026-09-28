# Needs no cloud account or backend: random_pet and terraform_data only touch
# local state, so CI can plan and apply this fixture on every run.
resource "random_pet" "this" {
  prefix = var.name_prefix
  length = 2
}

resource "terraform_data" "record" {
  input = {
    name = random_pet.this.id
    tags = var.tags
  }
}
