---
name: codex-cli-imagegen
description: Generate images through Codex CLI's built-in GPT Image 2 image generation after Codex CLI OAuth login. Use when the user asks to make images specifically through Codex CLI, ChatGPT/OAuth login, built-in $imagegen, or GPT Image 2 without supplying an OpenAI API key; also use for troubleshooting Codex CLI image generation setup, quoting, login, and output handling.
---

# Codex CLI Imagegen

## Overview

Use Codex CLI's built-in image generation flow for user-facing image creation when the user wants the Codex CLI OAuth path instead of direct OpenAI API key usage. Treat this as a Codex CLI workflow: the CLI owns authentication, generation, and file creation.

## Rules

- Use this only for Codex CLI image generation. For direct API calls with `client.images.generate(model="gpt-image-2", ...)`, require `OPENAI_API_KEY` instead.
- Do not ask the user to paste OAuth callback URLs, auth codes, bearer tokens, session files, or API keys into chat.
- For one-off images, prefer the bundled helper script because it resolves multiple Codex CLI install layouts and copies generated images out of `$CODEX_HOME/generated_images` when Codex ignores the requested output folder.
- If calling `codex exec` directly, put Codex global flags before `exec`, put `--skip-git-repo-check` after `exec`, and quote `$imagegen` with single quotes or escape the dollar sign as `` `$imagegen ``.
- If PATH resolves to a WindowsApps/AppX `codex.exe` that returns "Access is denied", try the user-level Codex CLI under `$env:LOCALAPPDATA\OpenAI\Codex\bin` before asking the user to reinstall.
- For bulk or production image generation, recommend direct OpenAI API usage with an API key. The CLI OAuth path is best for occasional interactive generation.

## Quick Start

1. Run the helper's environment check:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\invoke-codex-imagegen.ps1 `
  -Prompt "check only" `
  -CheckOnly
```

The helper searches these locations before falling back to `codex` on PATH:

- `$env:CODEX_CLI` and `$env:CODEX_COMMAND`
- `$env:LOCALAPPDATA\OpenAI\Codex\bin\codex.exe`
- newest `$env:LOCALAPPDATA\OpenAI\Codex\bin\*\codex.exe`
- `$env:LOCALAPPDATA\Programs\OpenAI\Codex\bin\codex.exe`
- `codex` from PATH

2. If not signed in, start OAuth login with the resolved CLI:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\invoke-codex-imagegen.ps1 `
  -Prompt "check only" `
  -LoginFirst `
  -CheckOnly
```

Let the browser flow complete locally. Never paste the callback URL into the conversation.

3. Generate an image from PowerShell:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\invoke-codex-imagegen.ps1 `
  -Prompt "A glassy blue butterfly app icon on a clean white background. No text, no watermark." `
  -OutDir "D:\codex\1\generated-images"
```

4. Direct `codex exec` fallback when the helper is unavailable:

```powershell
$codex = "$env:LOCALAPPDATA\OpenAI\Codex\bin\codex.exe"
& $codex -a never -s workspace-write exec --skip-git-repo-check '$imagegen Generate a square app icon: a glassy blue butterfly on a clean white background. Save the final image under D:\codex\1\generated-images and print the path.'
```

## Helper Script

Use `scripts/invoke-codex-imagegen.ps1` from this skill directory. It creates the output directory, builds a `$imagegen` prompt, runs `codex exec`, scans both the requested output directory and `$CODEX_HOME/generated_images`, copies fallback images into the requested output directory, and prints created paths.

Important options:

- `-Prompt`: user image prompt.
- `-OutDir`: destination directory for generated images.
- `-LoginFirst`: run `codex login` before generation.
- `-CodexCommand`: alternate executable path or command name.
- `-Interactive`: use `codex "<prompt>"` instead of `codex exec "<prompt>"` for older CLI builds.
- `-CheckOnly`: resolve Codex CLI, print version/login diagnostics, and do not generate an image.
- `-WorkDir`: working directory for `codex exec`.
- `-ApprovalPolicy`: Codex global approval policy; defaults to `never` for non-interactive runs.
- `-Sandbox`: Codex global sandbox mode; defaults to `workspace-write`.
- `-TimeoutSeconds`: maximum wait for non-interactive `codex exec`; defaults to `900`, then scans for generated images and stops the process tree.
- `-NoSkipGitRepoCheck`: do not pass `--skip-git-repo-check`.
- `-NoGeneratedImagesFallback`: do not scan/copy from `$CODEX_HOME/generated_images`.

If PowerShell refuses to run `.ps1` files, invoke the script with `powershell -NoProfile -ExecutionPolicy Bypass -File <script> ...`. This bypass is process-local and does not change the user's machine policy.

If the script reports no new files, inspect the CLI output. Codex may have saved the file elsewhere, the image generation may still be in progress, or the model may need a more explicit save-path instruction.

## Prompt Pattern

Include the deliverable, visual style, format, and save location in the same CLI prompt:

```text
$imagegen
Generate a 1024x1024 PNG image of [subject].
Style: [visual style].
Constraints: [composition, background, text/no text].
Save the final image under [absolute output directory] and print the absolute file path.
```

When the user wants several variants, ask Codex CLI for a small fixed number and explicit filenames. Avoid open-ended generation loops through the CLI.

## Failure Handling

- `codex` not found: run the helper with `-CheckOnly`; if no candidate works, tell the user Codex CLI is not installed or pass `-CodexCommand`.
- `Access is denied` from `C:\Program Files\WindowsApps\...`: use the helper's auto-discovery or pass `-CodexCommand "$env:LOCALAPPDATA\OpenAI\Codex\bin\codex.exe"` / the newest versioned `...\bin\*\codex.exe`.
- PowerShell blocks the helper script: re-run with `powershell -NoProfile -ExecutionPolicy Bypass -File`.
- `Not inside a trusted directory`: use the helper default, which passes `--skip-git-repo-check`; for direct calls, add `--skip-git-repo-check` after `exec`.
- Login requested or expired: run `codex login`; the user completes OAuth in the browser.
- `$imagegen` disappears in PowerShell output: the prompt used double quotes and PowerShell expanded `$imagegen` as a variable. Re-run with single quotes or escape the dollar sign.
- No output image found: make the save directory absolute, scan `$CODEX_HOME/generated_images`, ask Codex CLI to print paths only, and check the CLI transcript.
