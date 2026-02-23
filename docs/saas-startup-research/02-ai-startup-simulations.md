# AI Startup Simulations: Role-Based Agent Teams

## Overview

Multiple frameworks simulate software teams with specialized AI agents. Each assigns roles (PM, architect, engineer, tester) and defines communication protocols between them.

## ChatDev

### Architecture
Virtual software company with LLM-powered agents in organizational roles: CEO, CTO, Programmer, Tester, Reviewer.

### How It Works
- Follows a **waterfall model**: Design → Coding → Testing (+ optional Documentation)
- Uses a **Chat Chain** mechanism: each phase broken into subtasks, each subtask is a multi-turn chat between two role-agents
- Communication via **natural language dialogue** (not structured documents)
- Termination: after 2 unchanged code modifications or 10 communication rounds
- Includes **communicative dehallucination**: agents request detailed information before responding

### Key Pattern
Pair-wise chat chains between roles mirror real-world code review and design review processes.

## MetaGPT

### Architecture
Multi-agent framework built on "Code = SOP(Team)" — encoding Standard Operating Procedures from real software companies into agent workflows. (ICLR 2024)

### How It Works
- Roles: Product Manager → Architect → Engineer → QA Tester
- Communication via **structured outputs** (PRDs, design docs, interface specs, flowcharts)
- Follows waterfall SOP: PM produces PRD with user stories → Architect translates to system design → Engineers implement → QA formulates test cases
- Structured intermediate outputs significantly increase success rate

### Key Differentiator from ChatDev
Structured document-based communication vs. dialogue-based. However, ChatDev outperformed MetaGPT on some quality metrics — richer back-and-forth of natural language enables better consensus.

## CrewAI

### Architecture
Role-based orchestration framework with agents, tasks, and crews. Over 35K GitHub stars, 1.3M+ monthly PyPI installs.

### How It Works
- Define **agents** (roles, goals, backstories), **tasks** (descriptions, expected outputs), and a **crew** (team composition + process type)
- Process types: **sequential** (tasks in order) and **hierarchical** (manager agent delegates and coordinates)
- Each agent has defined responsibilities, framework coordinates execution

### Key Patterns
- Role definition with explicit backstories gives agents personality and domain focus
- Hierarchical mode with manager agent mirrors real team structures
- Task dependencies and expected outputs create clear contracts between agents

## AutoGen (Microsoft)

### Architecture
Multi-agent conversation framework built around the ConversableAgent class. (ICLR 2024)

### How It Works
- Agents converse through message exchange with auto-reply capability
- **GroupChat**: Multiple agents in shared conversation, orchestrated by GroupChatManager
- Four conversation patterns: two-agent chat, sequential chat, group chat, nested chat
- v0.4 includes AgentChat API for rapid prototyping

### Key Differentiator
Excels at conversational interactions but lacks inherent process orchestration. Coordinating agents requires additional programming at scale.

## Cross-Framework Comparison

| Dimension | ChatDev | MetaGPT | CrewAI | AutoGen |
|-----------|---------|---------|--------|---------|
| Communication | Dialogue | Structured docs | Mixed | Conversation |
| Orchestration | Chat Chain | SOP waterfall | Sequential/Hierarchical | Manual/GroupChat |
| Roles | 5 (CEO-Tester) | 4 (PM-QA) | Configurable | Configurable |
| Termination | Round limits | Phase completion | Task completion | Configurable |
| Human-in-loop | Limited | Limited | Manager mode | Explicit support |
| Best for | End-to-end apps | Spec-heavy projects | Flexible workflows | Research/prototyping |

## Lessons Learned for Our Plugin

1. **Structured outputs > dialogue**: MetaGPT's structured handoffs reduce ambiguity. Our plugin uses structured handoff templates for the same reason.

2. **Role specialization prevents confusion**: All frameworks assign distinct roles. Our two-founder model is even simpler — just business + tech, minimizing coordination overhead.

3. **Process orchestration is essential**: Without it (AutoGen's weakness), multi-agent systems become chaotic. Our plugin uses Agent Teams + file-based handoffs for clear orchestration.

4. **Termination conditions are hard**: All frameworks need explicit stopping criteria. Our two-level signoff system (roundtrip + solution) provides clear, human-meaningful completion.

5. **Two agents is the sweet spot for iteration**: All frameworks struggle above 5-7 agents due to quadratic communication overhead. Two agents with structured handoffs is the simplest viable pattern.

6. **Information asymmetry creates accountability**: Our tech founder's lack of web access forces the business founder to be thorough — a unique pattern not seen in other frameworks.

## Sources

- [ChatDev paper (ACL 2024)](https://arxiv.org/html/2307.07924v5)
- [ChatDev GitHub](https://github.com/OpenBMB/ChatDev)
- [MetaGPT paper (ICLR 2024)](https://arxiv.org/abs/2308.00352)
- [MetaGPT GitHub](https://github.com/geekan/MetaGPT)
- [CrewAI GitHub](https://github.com/crewAIInc/crewAI)
- [AutoGen GitHub](https://github.com/microsoft/autogen)
- [AutoGen paper](https://arxiv.org/abs/2308.08155)
