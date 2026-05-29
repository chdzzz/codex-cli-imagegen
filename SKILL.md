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
- For one-off images, prefer `codex exec` with a prompt containing `$imagegen`. In PowerShell, quote `$imagegen` with single quotes or escape the dollar sign as `` `$imagegen ``.
- If the local `codex` executable is unavailable or returns WindowsApps "Access is denied", report that the installed launcher is not executable from the current shell and ask the user to run the command in their interactive terminal or install/fix Codex CLI.
- For bulk or production image generation, recommend direct OpenAI API usage with an API key. The CLI OAuth path is best for occasional interactive generation.

## Quick Start

1. Check that Codex CLI is runnable:

```powershell
$codex = "$env:LOCALAPPDATA\Programs\OpenAI\Codex\bin\codex.exe"
if (-not (Test-Path $codex)) { $codex = "codex" }
& $codex --help
```

2. If not signed in, start OAuth login:

```powershell
& $codex login
```

Let the browser flow complete locally. Never paste the callback URL into the conversation.

3. Generate an image from PowerShell:

```powershell
& $codex exec '$imagegen Generate a square app icon: a glassy blue butterfly on a clean white background. Save the final image under D:\codex\1\generated-images and print the path.'
```

4. Use the helper script when a stable output folder and basic result detection are useful:

```powershell
.\scripts\invoke-codex-imagegen.ps1 -Prompt "A glassy blue butterfly app icon on a clean white background" -OutDir "D:\codex\1\generated-images"
```

## Helper Script

Use `scripts/invoke-codex-imagegen.ps1` from this skill directory. It creates the output directory, builds a `$imagegen` prompt, runs `codex exec`, and prints any new image files it finds in the output directory.

Important options:

- `-Prompt`: user image prompt.
- `-OutDir`: destination directory for generated images.
- `-LoginFirst`: run `codex login` before generation.
- `-CodexCommand`: alternate executable path or command name.
- `-Interactive`: use `codex "<prompt>"` instead of `codex exec "<prompt>"` for older CLI builds.

If the script reports no new files, inspect the CLI output. Codex may have saved the file elsewhere or may need a more explicit save-path instruction.

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

- `codex` not found: tell the user Codex CLI is not installed or not on `PATH`.
- `Access is denied` from `C:\Program Files\WindowsApps\...`: tell the user this Windows packaged launcher cannot be executed from the current shell; use the user's terminal or a non-Store Codex CLI installation.
- Login requested or expired: run `codex login`; the user completes OAuth in the browser.
- `$imagegen` disappears in PowerShell output: the prompt used double quotes and PowerShell expanded `$imagegen` as a variable. Re-run with single quotes or escape the dollar sign.
- No output image found: make the save directory absolute, ask Codex CLI to print paths, and check the CLI transcript.
