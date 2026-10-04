# Software Licensing & IP Compliance for SaaS

## License Categories

### Permissive Licenses (Low Risk for SaaS)
| License | Requirements | SaaS Risk |
|---------|-------------|-----------|
| MIT | Include license text | Madal |
| Apache 2.0 | Include license + NOTICE, patent grant | Madal |
| BSD 2-Clause | Include license text | Madal |
| BSD 3-Clause | Include license text, no endorsement | Madal |
| ISC | Include license text | Madal |

### Copyleft Licenses (Context-Dependent for SaaS)
| License | Requirements | SaaS Risk |
|---------|-------------|-----------|
| GPL v2 | Derivative works must be GPL | Madal* |
| GPL v3 | Derivative works must be GPL, anti-tivoization | Madal* |
| LGPL | Dynamic linking allowed, static linking requires LGPL | Madal |
| MPL 2.0 | Modified files must be MPL, can combine with proprietary | Madal |
| AGPL v3 | Network use triggers copyleft — source must be provided | Kõrge |

*GPL is low risk for SaaS ONLY because SaaS is a service, not a distribution. You are not distributing binaries to users. However, AGPL explicitly closes this "SaaS loophole."

### The AGPL Exception (High Risk)

**AGPL v3** (Affero General Public License) is the only common copyleft license that is dangerous for SaaS:
- Triggers copyleft when software is accessed over a network
- If ANY AGPL code is in your SaaS, you must provide the entire source code to users
- This means your proprietary SaaS code must be released under AGPL
- **Common AGPL projects:** MongoDB (pre-SSPL), Grafana, Mastodon, Nextcloud
- **Action:** If found in dependency tree, REMOVE or REPLACE immediately

## SaaS Distribution Exception

Traditional copyleft (GPL/LGPL) triggers when you **distribute** software. SaaS is a **service** — users access it via browser/API, they don't receive a copy of the code. Therefore:

- GPL dependencies in a SaaS backend: **generally safe** (no distribution)
- GPL dependencies in a desktop/mobile app you ship: **copyleft applies**
- AGPL dependencies anywhere: **copyleft applies** (network access = distribution)

**Caution:** If your SaaS also ships a desktop client, mobile app, or on-premises version, GPL/LGPL analysis changes completely.

## Dependency Audit Methodology

### Node.js / npm
```bash
# List all dependencies with licenses
npx license-checker --summary

# Check for problematic licenses
npx license-checker --failOn "AGPL-3.0;GPL-3.0;GPL-2.0" --excludePrivatePackages

# Detailed output
npx license-checker --json --out licenses.json
```

### Python / pip
```bash
# Install audit tool
pip install pip-licenses

# List all licenses
pip-licenses --format=table

# Check for copyleft
pip-licenses --fail-on="GNU Affero General Public License v3 (AGPLv3);GNU General Public License v3 (GPLv3)"

# Export
pip-licenses --format=json --output-file=licenses.json
```

### Go
```bash
# Install audit tool
go install github.com/google/go-licenses@latest

# Check licenses
go-licenses check ./...

# Report
go-licenses report ./... > licenses.csv
```

## IP Ownership

### Employee Code
- In Estonia, employer owns code created during employment (unless contract says otherwise)
- Employment contract should explicitly assign IP
- Include: inventions, discoveries, designs, code, documentation

### Contractor Code
- In Estonia, contractor retains IP unless explicitly assigned
- **CRITICAL:** Service agreement MUST include IP assignment clause
- Without it, the contractor owns the code they write for you

### Open-Source Contributions
- If employees contribute to open-source projects, those contributions follow the project's license
- Consider a Corporate Contributor License Agreement (CLA) policy
- Employee's personal open-source work on personal time: generally theirs

## License Compliance Checklist

1. **Inventory all dependencies** — direct and transitive
2. **Identify AGPL dependencies** — remove or replace immediately
3. **Check GPL dependencies** — safe for SaaS backend only (not for distributed apps)
4. **Verify MIT/Apache/BSD compliance** — include license texts in attribution file
5. **Check for license conflicts** — some licenses are incompatible (e.g., GPL + Apache 2.0 before version 3)
6. **Document in NOTICE/LICENSES file** — attribution for all open-source dependencies
7. **Set up CI check** — automate license scanning in build pipeline
