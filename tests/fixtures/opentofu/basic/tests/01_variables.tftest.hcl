# Unit tests: plan only, with the provider mocked, so they need no network or
# credentials.
mock_provider "random" {}

run "accepts_valid_prefix" {
  command = plan

  variables {
    name_prefix = "app1"
  }

  assert {
    condition     = random_pet.this.prefix == "app1"
    error_message = "The prefix should be passed through to random_pet."
  }
}

run "rejects_invalid_prefix" {
  command = plan

  variables {
    name_prefix = "Not-Valid"
  }

  expect_failures = [var.name_prefix]
}
