package mlisp.slsa

import rego.v1

# Deny release if provenance file is not attached to workflow outputs.
deny contains msg if {
    input.event_name == "release"
    not input.slsa_provenance_attached
    msg := "SLSA: release must have provenance attached before upload"
}

# Deny push to main if provenance workflow was not triggered.
deny contains msg if {
    input.event_name == "push"
    input.ref == "refs/heads/main"
    not input.provenance_workflow_triggered
    msg := "SLSA: push to main must trigger provenance generation workflow"
}

# Deny if slsa-verifier exit code is non-zero (injected by CI verify step).
deny contains msg if {
    input.slsa_verifier_exit_code != 0
    msg := sprintf("SLSA: slsa-verifier failed with exit code %d",
                   [input.slsa_verifier_exit_code])
}
