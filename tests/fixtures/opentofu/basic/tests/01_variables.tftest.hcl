# Unit tests: plan only, with the provider mocked, so they need no network or
# credentials.
mock_provider "random" {}

# Required by the backend block. tofu test keeps state in memory, so the
# value is never used, but it must be set.
variables {
  state_path = "test.tfstate"
}

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
