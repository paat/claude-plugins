# Architecture Decision Patterns

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
