# codex-cli-imagegen

A Codex skill for generating images through Codex CLI's built-in `$imagegen` flow after ChatGPT OAuth login.

This is useful when you want Codex CLI to generate images with its built-in GPT Image 2 path without supplying an OpenAI API key to your own script.

## Install

Copy this repository folder into your Codex skills directory:

```powershell
git clone https://github.com/chdzzz/codex-cli-imagegen.git "$env:USERPROFILE\.codex\skills\codex-cli-imagegen"
```

Restart Codex so the skill metadata is reloaded.

## Prerequisites

- Codex CLI is installed and runnable.
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
.\scripts\invoke-codex-imagegen.ps1 `
  -Prompt "A realistic beach vacation photo with white sand, turquoise water, umbrellas, lounge chairs, and palm trees" `
  -OutDir "D:\codex\1\generated-images" `
  -LoginFirst
```

## Notes

- This skill is for Codex CLI image generation. Direct OpenAI API image generation still requires `OPENAI_API_KEY`.
- In PowerShell, wrap `$imagegen` prompts in single quotes or escape the dollar sign as `` `$imagegen ``.
- If a Windows Store/AppX Codex launcher returns `Access is denied`, install the standalone Codex CLI and use its executable path.
