# Review contract
Read-only. Do not modify, stage, or commit.
Review only the named target. Open other files only to verify a candidate finding.
You have no shell: when a diff file is named in the prompt, read it first, then the files it touches. Judge every changed line against the line it replaced — an off-by-one, inverted condition, dropped commit/flush, or widened scope reads fine in isolation and is still a regression. Never dismiss a changed line as pre-existing.
Report real findings only: file:line, severity, reachable failure, concrete fix.
Skip style, naming, and pre-existing issues unrelated to the target.
End with one line: APPROVE or NEEDS_WORK. Use no other verdict word — orchestrators gate on these two.
