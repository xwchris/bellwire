<!-- SPDX-License-Identifier: Apache-2.0 -->

# Install the Bellwire Agent Skill

The Skill contains its own dependency-free CLI. It can target Bellwire Cloud
or a self-hosted API by setting `BELLWIRE_API_URL`.

## Codex

Clone the repository and link the Skill into the personal Codex skills
directory:

```bash
git clone https://github.com/xwchris/bellwire.git
mkdir -p "$HOME/.codex/skills"
ln -s "$(pwd)/bellwire/skills/bellwire" "$HOME/.codex/skills/bellwire"
```

Restart Codex after installing the Skill. Open Bellwire on the iPhone, create a
one-time binding code, then ask Codex to use the Bellwire Skill to connect the
current repository.

If `bellwire` already exists in the skills directory, remove or rename that
specific old link before installing the new one. Do not recursively delete a
shared skills directory.

## Other compatible Agents

Copy or link the complete `skills/bellwire` directory into the Agent's personal
skills directory. The Agent must be able to read `SKILL.md`, `references/`, and
`scripts/` together.

The CLI can also be used directly without installing the Skill:

```bash
node skills/bellwire/scripts/bellwire.mjs --help
```

## Update

Pull the repository with a fast-forward update. A linked installation updates
immediately:

```bash
git -C bellwire pull --ff-only
```

Review the [five-minute quick start](../../docs/quickstart.md) for binding and
the first project/event flow.
