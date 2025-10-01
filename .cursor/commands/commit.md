### Command: Commit current changes in logical groups (simple)

Do exactly this, non-interactively, from repo root.

1) Ignore when staging:
   - Follow .gitignore strictly. Additionally, ignore: .cursor/** (except this file), .env

2) Define groups and scopes:
   - infra → foundry.toml, foundry.lock, README.md
   - contracts → src/**, src/interfaces/**
   - scripts → script/**
   - tests → test/**
   - deps → lib/**
   - build → out/** (avoid committing; usually ignored)
   - cache → cache/** (avoid committing; usually ignored)

3) For each group that has changes, stage and commit (by intent/responsibility, not only folder):
   - Decide values:
     - ${emoji}:{fix=🐛, feat=✨, docs=📝, style=💄, refactor=♻️, perf=🚀, test=💚, chore=🍱}
     - ${type} in {fix, feat, docs, style, refactor, perf, test, chore}
     - ${scope} = group name (e.g., infra|contracts|scripts|tests|deps|build|cache)
     - ${summary} = 1-line imperative (<=72 chars)
     - ${body} = 1–3 bullets (optional)
   - Commands:
     - git add -A -- -- ${file1} ${file2} ${fileN}
     - git commit --no-verify --no-gpg-sign -m "${emoji} ${type}(${scope}): ${summary}" -m "${body}"

4) Commit order: chore → docs → style → refactor → perf → feat → fix → test

5) Final check:
   - git -c core.pager=cat status --porcelain=v1 | cat

Message template:
  Title: "${emoji} ${type}(${scope}): ${summary}"
  Body:  "- ${changes}\n- ${reasonImpact}"

Example:
  git add -A -- -- src/UnigachaPoint.sol script/DeployUnigacha.s.sol
  git commit --no-verify --no-gpg-sign -m "✨ feat(contracts): UnigachaPointのミント処理を実装" -m "- コアロジック追加\n- デプロイスクリプト更新"
