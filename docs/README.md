# Documentation

A CLI-only, Docker-based workspace for running AI coding agents inside an isolated container, with deny-by-default outbound networking and a non-root agent shell.

Start here if you are new: **[Getting started](getting-started.md)**.

The short version: `project-init.sh` once per project, then `runme.sh` from the project every time after that. `build.sh` and `sandbox.sh` are what `runme.sh` calls — you rarely run them yourself.

## Setting up

| Guide | What it answers |
|---|---|
| [Getting started](getting-started.md) | What do I need installed, and how do I set up and launch my first project? |
| [Managing projects](multiple-projects.md) | What `project-init.sh` generates, and how do I keep projects in sync afterwards? |
| [What is in the box](overview.md) | Which file does what, and what is included by default? |
| [Components](components/README.md) | How do I switch a language, CLI or tool on? Every `sandbox.conf` key. |
| [Environment variables](configuration.md) | What can I change at run time without rebuilding? |

## Running day to day

| Guide | What it answers |
|---|---|
| [Container groups](groups.md) | How do I keep one project's credentials and agent config separate from another's? |
| [Repositories, volumes and mounts](repos-and-mounts.md) | How do I get my code, vault, docs and specs into the container — fast? |
| [Agent-tier tools](agent-tools.md) | Where do Claude Code, Copilot and the rest live, and how do I update them? |
| [Resource limits](resources.md) | How much CPU and memory does an agent need, and how do I cap it? |

## When something is wrong

| Guide | What it answers |
|---|---|
| [Security model, allowlists and tokens](security.md) | What is blocked, how do I allow something, and where do my tokens go? |
| [Troubleshooting and host notes](troubleshooting.md) | It is not working — and macOS-specific behaviour. |

## For contributors

`AGENTS.md` in the repository root is the working agreement for anyone — human or agent — changing this repository: the test suite, the mutation and falsify tiers, and the rules a change has to satisfy before it lands.
