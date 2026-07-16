# Architecture Decision Patterns

## Solo-Founder KISS

Ask: **Could one founder still deploy, understand, debug, and recover this alone in six months?** Default to one deployable application, one primary datastore, managed hosting/services, and direct flows.

Unless acceptance criteria or a concrete documented security, legal, reliability, or operability need requires them, do not add microservices or service splits, self-operated brokers, container orchestration, HA/multi-region, SSO/SAML/SCIM, organization or role hierarchies, generic audit/feature-flag/plugin platforms, data warehouses/ETL, dedicated cache/search stores, or heavyweight observability stacks. Measured load and reproduced failures are evidence, not prerequisites for preventive controls.

Production readiness remains non-negotiable: keep required authentication and access control, validation, secrets hygiene, payment and data correctness, backups and recovery, bounded external calls, actionable logs, error capture, critical-workflow alerts, honest loading/error/failure states, and regression gates. A managed background job or queue is appropriate when it is the simplest safe design. A finished product is complete and trustworthy; it does not need enterprise scale.

## Architecture Decision Record (ADR) Template

When making significant technical decisions, document them in `docs/architecture/architecture.md` using this format:

```markdown
### ADR-NNN: [Decision Title]

**Status**: Proposed | Accepted | Deprecated | Superseded
**Date**: YYYY-MM-DD

**Context**: What is the situation that requires a decision?

**Decision**: What did we decide?

**Rationale**: Why this approach over alternatives?

**Alternatives Considered**:
1. [Alternative 1] — rejected because [reason]
2. [Alternative 2] — rejected because [reason]

**Consequences**:
- Positive: [benefits]
- Negative: [trade-offs]
- Neutral: [observations]
```

## Common Architecture Patterns for SaaS

### Monolith First
Always start with a monolith:
- Single codebase, single deployment
- Faster development, simpler debugging
- Extract services later IF needed (usually isn't for a long time)

### API Design
- RESTful for CRUD operations
- Use consistent URL patterns: `/api/v1/resources/:id`
- Always return proper HTTP status codes
- Include pagination for list endpoints
- Use JSON for request/response bodies

### Database Schema Design
- Start simple: normalize later if needed
- Use UUIDs for primary keys (prevents enumeration)
- Always include `created_at` and `updated_at` timestamps
- Soft delete with `deleted_at` when data is important
- Index foreign keys and frequently queried columns

### Authentication
- Session-based for server-rendered apps
- JWT for API-only backends
- Always hash passwords (bcrypt, argon2)
- Implement rate limiting on auth endpoints
- Support password reset via email

### File Structure
```
project/
├── src/
│   ├── app/          # Pages and routes
│   ├── components/   # Reusable UI components
│   ├── lib/          # Utilities, database, auth
│   ├── api/          # API route handlers
│   └── types/        # TypeScript types
├── public/           # Static assets
├── prisma/           # Database schema (if using Prisma)
└── tests/            # Test files
```

## Technology Selection Criteria

### Frontend Framework Decision Tree
```
Need SEO? → Next.js (SSR)
Simple SPA? → React + Vite
Complex forms? → React + React Hook Form
Real-time? → Next.js + WebSockets
Static site? → Astro or Next.js static export
```

### Database Decision Tree
```
Local dev/testing only? → SQLite
Production? → PostgreSQL
Key-value / caching? → Redis
Full-text search? → PostgreSQL (built-in) or Meilisearch
Time-series data? → TimescaleDB (PostgreSQL extension)
```

### Hosting Decision Tree
```
Full-stack Next.js? → Vercel
Docker container? → Railway or Fly.io
Static + API? → Cloudflare Pages + Workers
Self-hosted? → VPS (Hetzner, DigitalOcean)
```
