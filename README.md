# LZA Pipeline Trial

Trial repo for validating the redesigned LZA config CI/CD pipeline before applying to `uelz-lza-config`.

## Problem Statement

The current `uelz-lza-config` pipeline has:
1. **Duplicate stages** — lint/scan runs on both PR and push to main (redundant)
2. **Cross-environment blocking** — all app-onboarding dispatches (dev/uat/prd) share one workflow file and concurrency group; a failed dev run blocks uat and prd
3. **No merge queue** — PRs merge in whatever order developers click merge, risking config conflicts

## Redesigned Pipeline

Four workflow files with clear separation of concerns:

| Workflow | Trigger | Purpose | Speed |
|----------|---------|---------|-------|
| `ci-push.yml` | `push` (non-main branches) | Fast lint + scan feedback | < 30s |
| `ci.yml` | `pull_request` + `merge_group` | Full validation + tests | ~3-4 min |
| `lza-deploy.yml` | `push` to `main` | Fetch prd → validate → zip → upload S3 | ~2-3 min |
| `lza-onboard.yml` | `workflow_dispatch` | Per-env dispatch from app-onboarding | ~2-3 min |

## Flow Diagram

```
                    ┌─────────────────────────────────────────────────────┐
                    │              PUSH WORKFLOW (fast)                     │
                    │                                                     │
  git push ───────►│  ci-push.yml (< 30 seconds)                         │
  (any branch)     │  └── lint: yamllint + cfn-lint + cfn-guard + Trivy  │
                    │                                                     │
                    │  Immediate feedback: "is my YAML valid?"            │
                    └─────────────────────────────────────────────────────┘


                    ┌─────────────────────────────────────────────────────┐
                    │                  PR WORKFLOW (full)                   │
                    │                                                     │
  PR opened ──────►│  ci.yml (~3-4 minutes)                              │
                    │  ├── static-analysis (cfn-lint, guard, trivy)       │
                    │  ├── unit-tests (pytest)                            │
                    │  ├── config-validation (fetch DDB + LZA validator)  │
                    │  ├── sonar (code quality)                           │
                    │  └── snyk (security - optional)                     │
                    │                                                     │
                    │  ✅ All pass → ready for review & approval          │
                    └────────────────────────┬────────────────────────────┘
                                             │
                                             ▼
                    ┌─────────────────────────────────────────────────────┐
                    │                MERGE QUEUE                           │
                    │                                                     │
  Approved PR ────►│  merge_group trigger → re-runs ci.yml on combined   │
                    │  changes (PR + everything ahead in queue + main)    │
                    │                                                     │
                    │  ✅ Pass → auto-merge to main                       │
                    └────────────────────────┬────────────────────────────┘
                                             │
                                             ▼
                    ┌─────────────────────────────────────────────────────┐
                    │              DEPLOY WORKFLOW                         │
                    │                                                     │
  push to main ───►│  lza-deploy.yml                                     │
                    │  ├── fetch-config (prd DDB)                         │
                    │  ├── validate-config (LZA validator + zip)          │
                    │  ├── upload-config (zip → S3)                       │
                    │  └── deploy-lambda (path-filtered)                  │
                    │                                                     │
                    │  S3 upload triggers LZA CodePipeline automatically  │
                    └─────────────────────────────────────────────────────┘


                    ┌─────────────────────────────────────────────────────┐
                    │            ONBOARDING WORKFLOW                       │
                    │                                                     │
  App-onboarding   │  lza-onboard.yml                                    │
  Lambda ─────────►│  Concurrency: lza-onboard-{env} (ISOLATED)          │
                    │                                                     │
                    │  dev: fetch dev DDB → validate → done               │
                    │  uat: fetch uat DDB → validate → done               │
                    │  prd: fetch prd DDB → validate → upload S3          │
                    │                                                     │
                    │  ❌ dev failure does NOT block uat or prd            │
                    └─────────────────────────────────────────────────────┘
```

## Composite Actions (DRY)

Common step sequences are extracted into reusable composite actions under `.github/actions/`:

```
.github/actions/
├── fetch-config/action.yml      # OIDC + DDB fetch + upload artifact
├── validate-config/action.yml   # Download artifact + validate + optional zip
└── upload-s3/action.yml         # Download zip + S3 upload
```

Each workflow calls these building blocks rather than duplicating steps:

```yaml
# Example usage in any workflow
- uses: ./.github/actions/fetch-config
  with:
    environment: dev

- uses: ./.github/actions/validate-config
  with:
    environment: dev
    create-zip: "true"

- uses: ./.github/actions/upload-s3
  with:
    environment: prd
```

**Benefit:** Change a step once in the action definition → all workflows pick it up. No multi-file edits for shared logic (OIDC config, artifact naming, validation commands).

## Static Analysis Tools

| Tool | Purpose | When | Blocking? |
|------|---------|------|-----------|
| **yamllint** | Pure YAML syntax (indentation, structure) | Push | No (informational) |
| **cfn-lint** | CFN property validation against resource spec | Push + PR | Yes |
| **cfn-guard** | Policy-as-code (mandatory tags, naming, allowed resources) | Push + PR | Yes |
| **Trivy** | Security misconfigurations (S3 public, no encryption) | Push (info) + PR (blocking) | PR only |
| **SonarQube** | Python code quality (support scripts) | PR | No (quality gate) |
| **Snyk IaC** | Security findings + license compliance | PR | Configurable |
| **LZA Validator** | Full config schema validation (cdk synth equivalent) | PR | Yes |

### cfn-guard Rules

Custom policy rules live in `guard-rules/`:

```
guard-rules/
└── mandatory-tags.guard    # Ensures all resources have RMIT mandatory tags
```

Add new `.guard` files for additional policies (naming conventions, allowed regions, encryption requirements).

## Key Design Decisions

### 1. Static analysis only on PR

CloudFormation templates don't change on dispatch or push — they already passed lint/scan during the PR. No point re-running.

### 2. Per-environment concurrency isolation

```yaml
# lza-onboard.yml
concurrency:
  cancel-in-progress: false
  group: lza-onboard-${{ inputs.environment }}
```

Each environment has its own lane. A dev failure doesn't affect uat or prd.

### 3. Merge queue for sequential deployment

GitHub's native merge queue:
- PRs queue up after approval
- GitHub validates each merge group (combined changes) in sequence
- Failed PRs are ejected without blocking others
- Ensures config changes merge in order — no conflicts

### 4. No redundant validation on deploy

The `lza-deploy.yml` re-fetches from DDB and re-validates because DDB data may have changed since the PR was approved. But it does NOT repeat lint/scan/tests (those check templates, which haven't changed).

## Merge Queue Configuration

To enable on the real repo:

1. **Settings → Rules → Rulesets** (or Branch protection)
2. On `main` branch:
   - Require status checks: `static-analysis`, `config-validation`
   - Require merge queue
   - Merge method: squash (or merge commit)
   - Max queue size: 5
   - Min group size: 1 (sequential — one PR at a time)

## Testing This Repo

### Simulate PR flow
```bash
git checkout -b test/sample-change
# Make a change to cloudformation-templates/sample-template.yml
git add . && git commit -m "test: sample CFN change"
git push -u origin test/sample-change
# Open PR → ci.yml triggers
```

### Simulate app-onboarding dispatch
```
Actions → LZA Onboard → Run workflow → Select environment → Run
```

### Simulate merge to main
```
Merge the PR → lza-deploy.yml triggers
```

## Migration Path to uelz-lza-config

Once the team validates this works:

1. Create `lza-onboard.yml` in `uelz-lza-config` (new file, no conflict)
2. Update `PipelineConfig.GITHUB_WORKFLOW_MAPPING` to point at `lza-onboard.yml`
3. Replace `ci.yml` + `lza-config.yml` with new `ci.yml` + `lza-deploy.yml`
4. Enable merge queue on `main` branch protection
5. Remove old workflow files

## What's Mocked

| Real Step | Mock |
|-----------|------|
| OIDC assume role | Commented out (no AWS creds needed) |
| DDB fetch + Python scripts | `mock-fetch-config.sh` (creates dummy YAML) |
| LZA validator container | `mock-validate-config.sh` (prints success) |
| S3 upload | `mock-upload-s3.sh` (prints mock upload) |
| Lambda deploy | Echo command (path-filtered) |
