#!/bin/bash
# governor.sh — budget policy library sourced by mission-control.sh AFTER its
# helpers are defined; may use cfg/state_get/state_set/now/today/alert and
# the exported MC_CONFIG / MC_STATE_DIR. This is the #198 STUB: permissive,
# stateless. #199 replaces the bodies; the signatures are the contract.

# Atomic check-and-reserve for one pass on this engine's pool. Exit 0 = may
# dispatch (reservation taken), exit 1 = refused. Stub: always allow.
governor_reserve() { # <engine>
  return 0
}

# Print the pass wall-clock envelope in minutes.
governor_envelope() { # <engine> <project>
  echo 90
}

# Post-pass accounting; print the outcome word (ok|rate-limit|timeout|error).
governor_report() { # <engine> <project> <exit_code> <log_path>
  if [ "$3" -eq 0 ]; then echo ok; else echo error; fi
}

# Daily digest/housekeeping; owns its own once-per-day guard. Stub: no-op.
governor_daily() {
  return 0
}
