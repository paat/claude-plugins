
## [HUMAN] Require the CI check (branch protection)

Sequencing: do this ONLY after the tech-founder has finalized `check.sh` and the
first CI run on a real PR is green — otherwise you block every PR on a stub.

1. Get the exact check name from the first green PR:
   gh pr checks <pr-number>      (it is `check` or `CI / check` — copy verbatim)
2. Primary path — GitHub UI: Settings → Branches → Add branch protection rule →
   "Require status checks to pass before merging" → select that check.
3. CLI alternative (ONLY for a repo with no existing protection rule — a PUT to
   /protection REPLACES all protection settings; use the UI otherwise):

       BR=$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name)
       CTX="check"   # replace with the exact name from step 1
       gh api -X PUT "repos/{owner}/{repo}/branches/$BR/protection" \
         -H "Accept: application/vnd.github+json" --input - <<JSON
       {
         "required_status_checks": { "strict": true, "contexts": ["$CTX"] },
         "enforce_admins": false,
         "required_pull_request_reviews": null,
         "restrictions": null
       }
       JSON

   Requires repo-admin + a token with the right scope. enforce_admins:false
   lets admins merge a red PR in an emergency — set true to bind admins too.
