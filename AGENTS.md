# AGENTS Rules

## Workflow Rule

- When a `.dart` file is changed in the workspace, restart the Windows Flutter app automatically using `agent.ps1`.

Use this from the repository root:

```powershell
.\agent.ps1 -SkipGet
```

This ensures the app is relaunched with the updated Dart code.
