# codex-cli-imagegen

A Codex skill for generating images through Codex CLI's built-in `$imagegen` flow after ChatGPT OAuth login.

This is useful when you want Codex CLI to generate images with its built-in GPT Image 2 path without supplying an OpenAI API key to your own script.

## Install

Copy this repository folder into your Codex skills directory.

PowerShell:

```powershell
git clone https://github.com/chdzzz/codex-cli-imagegen.git "$env:USERPROFILE\.codex\skills\codex-cli-imagegen"
```

Bash/zsh:

```bash
git clone https://github.com/chdzzz/codex-cli-imagegen.git "$HOME/.codex/skills/codex-cli-imagegen"
```

Restart Codex so the skill metadata is reloaded.

To update an existing install:

```powershell
git -C "$env:USERPROFILE\.codex\skills\codex-cli-imagegen" pull --ff-only
```

```bash
git -C "$HOME/.codex/skills/codex-cli-imagegen" pull --ff-only
```

## Prerequisites

- Codex CLI is installed and runnable. The helper can auto-detect common Windows, macOS, Linux, and standalone Codex CLI install layouts.
- You are logged in with ChatGPT OAuth:

```powershell
codex login
```

Do not paste OAuth callback URLs, auth codes, tokens, or API keys into chat.

## Usage

Invoke the skill in Codex:

```text
Use $codex-cli-imagegen to generate a realistic beach vacation photo and save it under D:\codex\1\generated-images.
```

Or run the helper script directly from this repository:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\invoke-codex-imagegen.ps1 `
  -Prompt "A realistic beach vacation photo with white sand, turquoise water, umbrellas, lounge chairs, and palm trees" `
  -OutDir "D:\codex\1\generated-images" `
  -LoginFirst
```

Check the local environment without generating an image:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\invoke-codex-imagegen.ps1 `
  -Prompt "check only" `
  -CheckOnly
```

Request and verify native 4K landscape output:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\invoke-codex-imagegen.ps1 `
  -Prompt "A cinematic beach vacation photo, no text, no watermark." `
  -OutDir "D:\codex\1\generated-images" `
  -RequestedSize "3840x2160" `
  -RequireExactSize
```

## Notes

- This skill is for Codex CLI image generation. Direct OpenAI API image generation still requires `OPENAI_API_KEY`.
- In PowerShell, wrap `$imagegen` prompts in single quotes or escape the dollar sign as `` `$imagegen ``.
- If a Windows Store/AppX Codex launcher returns `Access is denied`, the helper skips it and tries user-level Codex CLI paths. You can also pass `-CodexCommand "C:\path\to\codex.exe"`.
- The helper passes `--skip-git-repo-check` by default so it can run from ordinary folders; pass `-NoSkipGitRepoCheck` to preserve Codex's trust check.
- The helper defaults to `-Sandbox danger-full-access` because nested Codex CLI image generation can fail in the Windows sandbox with `spawn setup refresh`.
- The helper creates an isolated child `CODEX_HOME` by default and copies `auth.json` into it. This prevents nested Codex CLI runs from loading this same skill and recursively invoking the helper. Pass `-NoIsolatedCodexHome` only for diagnostics.
- The helper passes `--disable plugins` by default to avoid remote plugin sync noise and rate-limit failures during generation. Pass `-DisablePlugins:$false` only when a plugin is explicitly required.
- Codex sometimes writes generated images under `$CODEX_HOME\generated_images` instead of the requested directory. The helper scans that fallback location and copies new image files into `-OutDir`.
- If `codex exec` generates an image but does not exit, the helper polls for new stable image files every 5 seconds by default, stops the process tree once files are detected, and treats those files as the result. Override with `-PollSeconds`, `-StableSeconds`, `-NoEarlyExitOnImage`, or `-TimeoutSeconds`.
- For native 4K requests, use `-RequestedSize "3840x2160" -RequireExactSize`. The helper requests that size through `$imagegen` and validates the saved image metadata. If Codex CLI returns a smaller fixed native size, the helper reports the mismatch instead of silently treating an upscale as native 4K.

Run the mock test suite without calling the real Codex service:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-helper-tests.ps1
```

On macOS/Linux:

```bash
pwsh -File ./tests/run-helper-tests.ps1
```
