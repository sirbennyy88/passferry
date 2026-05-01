# Publishing PassFerry to GitHub

This is a one-time setup. After this, normal `git commit` / `git push` works.

## Prerequisites

1. A GitHub account
2. The `gh` CLI installed and authenticated:
   ```powershell
   # Install (Windows)
   winget install GitHub.cli

   # Authenticate (one-time)
   gh auth login
   ```
3. Git configured with your name and email:
   ```powershell
   git config --global user.name "Your Name"
   git config --global user.email "you@example.com"
   ```

## Step 1 — Decide the repo URL

GitHub repos look like `github.com/<owner>/<repo>`. The owner is either:

- Your personal account (e.g., `github.com/yourusername/passferry`)
- An organization you own or admin (e.g., `github.com/yourorg/passferry`)

For a v0.1 prototype, your personal account is fine. You can transfer to an org later.

## Step 2 — Run this prompt in Claude Code

Open the extracted `passferry/` folder in VS Code. Open the Claude Code panel and paste:

---

> Publish the current project (`passferry/`) to GitHub as a new public repository. Steps:
>
> 1. Initialize git in the current directory if not already a repo: `git init -b main`
> 2. Verify `.gitignore` is in place (already exists, should exclude `*.dll`, `*.pdb`, `*.cer`, `*.pfx`, `state.json`, `config.json`, `logs/`, `*.log`)
> 3. Run `git status` and confirm no DLL files, certs, or PFX files are staged. If any are present, stop and inform me.
> 4. Stage everything else: `git add .`
> 5. Run `git status` again and show me the file list before committing
> 6. Create initial commit:
>    ```
>    git commit -s -m "Initial release v0.1
>
>    PassFerry v0.1 — a focused, open-source replacement for the password-sync
>    portion of ADMT 3.2 on Windows Server 2025.
>
>    Includes: LSA password notification filter DLL, user-mode forwarder,
>    sync broker, user provisioning, pre-flight validation, full documentation,
>    test plan, and hardening guide.
>
>    Concocted with the help of Claude (Anthropic).
>    ```
> 7. Tag the release: `git tag -a v0.1 -m "PassFerry v0.1 — initial public release"`
> 8. Create the GitHub repo using `gh`:
>    ```
>    gh repo create passferry --public --source=. --remote=origin \
>      --description "Real-time AD password sync across forests — open-source ADMT alternative for Windows Server 2025" \
>      --homepage "https://github.com/$(gh api user --jq .login)/passferry"
>    ```
> 9. Push branch and tags:
>    ```
>    git push -u origin main
>    git push origin v0.1
>    ```
> 10. Set repository topics for discoverability:
>     ```
>     gh repo edit --add-topic active-directory --add-topic windows-server-2025 \
>                  --add-topic admt --add-topic admt-alternative \
>                  --add-topic password-sync --add-topic multi-forest \
>                  --add-topic entra-id --add-topic identity-management
>     ```
> 11. Create the v0.1 GitHub release from the tag:
>     ```
>     gh release create v0.1 --title "PassFerry v0.1 — initial release" \
>       --notes-from-tag --verify-tag
>     ```
> 12. Print the final repo URL.
>
> Do NOT upload any DLL, PDB, CER, or PFX files. Do NOT commit any state.json, config.json, or log files. If any of those are in the working directory, leave them out.
>
> If `gh` is not authenticated, stop and tell me to run `gh auth login` first.

---

## Step 3 — Verify the result

Visit the URL Claude Code prints. Check:

- README renders correctly with all the badges
- LICENSE shows MIT
- ROADMAP, CHANGELOG, CONTRIBUTING all visible at root
- `docs/` and `scripts/` and `filter-dll/` folders all present
- **No DLLs, PDBs, or .cer files in the repo** (this is critical — the `.gitignore` prevents this but always verify)
- The "Releases" sidebar on the right shows v0.1
- Topics show on the right (active-directory, windows-server-2025, etc.)
- The Actions tab shows the build workflow ran (or is queued) — when it finishes, you'll have a downloadable signed-source-built DLL for every commit

## Step 4 — Optional polish

Add a repo description, social-preview image, and pinned issues. These are GitHub UI-only:

1. **Description / website**: already set by step 2 above, but you can edit at `Settings → General`
2. **Social preview**: `Settings → General → Social preview` — upload a 1280×640 PNG
3. **Pin an introductory issue**: open issue "PassFerry v0.1 is here — looking for lab testers", pin it via `…` menu

## Step 5 — Tell people

Realistic places to share PassFerry to find lab testers and contributors:

- r/sysadmin and r/activedirectory (post titled something like "Open-sourced an ADMT password-sync replacement for Server 2025")
- LinkedIn (your own network)
- Hacker News (only worth posting if you have a v0.1 demo / blog post to link, otherwise it'll fall flat)
- Microsoft tech community forums (Azure AD / Active Directory section)
- The /r/PowerShell weekly thread

Post the README, the problem statement, and an honest "this is a prototype, looking for real-world test reports" framing. Avoid hype.

## Common issues

**"Permission denied (publickey)" when pushing**: `gh auth setup-git` to fix git+gh auth integration.

**A DLL accidentally got committed**: rewrite history before pushing
```powershell
git rm --cached filter-dll/passferry_filter.dll
git commit --amend
# don't push yet — add to .gitignore first if it's not there
```

**Action fails on first push**: that's normal if you've never used GitHub Actions on this account. The workflow file may need a brief activation. Visit the Actions tab and click "I understand my workflows, enable them".

**Wrong repo visibility**: you can change between public and private at `Settings → General → Danger Zone`. Make a habit of double-checking before posting anywhere.
