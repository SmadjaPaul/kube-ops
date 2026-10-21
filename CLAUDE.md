# Agent entrypoint (Claude)

Read and follow [AGENTS.md](AGENTS.md) as the **only** Kubernetes operations authority.
Use the relevant `.agents/skills/` entry referenced there and `just inventory` before inspecting other paths.
Do not interpret manifest file presence as deployed desired state; check Argo/Kustomize roots and runtime evidence.
This file intentionally contains no parallel architecture or legacy component list.
