# Example policies for the fixture's plan (conftest, Rego v1).
package plan

import rego.v1

# Every change the plan makes, excluding reads and no-ops
changes contains rc if {
	some rc in input.resource_changes
	not rc.change.actions == ["no-op"]
	not rc.change.actions == ["read"]
}

deny contains msg if {
	some rc in changes
	"delete" in rc.change.actions
	not "create" in rc.change.actions
	msg := sprintf("%s would be destroyed; destroying resources needs an explicit exception", [rc.address])
}

warn contains msg if {
	some rc in changes
	rc.change.actions == ["delete", "create"]
	msg := {
		"msg": sprintf("%s would be replaced", [rc.address]),
		"severity": "high",
	}
}
