# Newbie Dev Kit — for Windows

Helps **newbie developers, new hires, and fresh desktops** set up a development environment in one go.
Pick the tools you want in a window and install them with a single click. (Windows only)

> 🌐 한국어: [README.md](README.md)

## How to use

1. Copy this folder to the new PC **as-is** (re-saving in an editor can corrupt the encoding).
2. Double-click **`Run-Setup.bat`** → click **[Yes]** on the UAC prompt.
3. Check the tools you want in the window, then start the install.

That's it. Already-installed tools are skipped automatically, so it's safe to run multiple times.

## What gets installed?

A bundle of common dev tools — Git, Node.js, Python, VS Code, Docker, and more.
Most are installed via **winget**.

## Adding your own tools

Open this repo with an AI coding tool like **Claude Code** or **Codex**, then just say:
> "Add the ○○ package, following the rules in `CLAUDE.md`."

It will add the entry to `Setup-DevEnv.ps1` for you — no need to touch the code yourself.

## License

MIT
