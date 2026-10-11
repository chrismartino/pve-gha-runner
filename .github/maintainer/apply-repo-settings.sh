#!/usr/bin/env bash
#
# Applies the repository settings from the open-sourcing plan with the GitHub
# REST API (via the `gh` CLI). Maintainer tool: not part of the runner scripts.
#
#   .github/maintainer/apply-repo-settings.sh            # dry run: prints each call
#   .github/maintainer/apply-repo-settings.sh --apply    # make the changes
#
# Options:
#   --repo OWNER/REPO   default: chrismartino/pve-gha-runner
#   --apply             actually send the requests (default is a dry run)
#   --skip-pages        don't configure GitHub Pages / the github-pages environment
#
# Requires: gh (authenticated as a repo admin: `gh auth login`), jq.
#
# Safe to re-run: settings are PUT/PATCHed and rulesets are updated by name.
# A call that GitHub rejects (e.g. secret-scanning push protection on a
# private repo without GitHub Advanced Security, or Pages on a private free
# repo) is reported and skipped, so run this again after making the repo
# public. Things the API can't do for you are listed at the end.
set -u

REPO="chrismartino/pve-gha-runner"
APPLY=false
SKIP_PAGES=false

while [ $# -gt 0 ]; do
    case "$1" in
        --repo)
            REPO="${2:?--repo needs OWNER/REPO}"
            shift 2
            ;;
        --apply)
            APPLY=true
            shift
            ;;
        --skip-pages)
            SKIP_PAGES=true
            shift
            ;;
        -h | --help)
            sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "unknown option: $1" >&2
            exit 2
            ;;
    esac
done

for tool in gh jq; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "$tool is required" >&2
        exit 1
    }
done
[[ "$REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || {
    echo "bad --repo: $REPO" >&2
    exit 2
}

# The CI job names that must pass before merging to main (see ci.yml).
REQUIRED_CHECKS='["shellcheck","shfmt","syntax","markdownlint","actionlint","zizmor"]'

FAILED=0

# call METHOD PATH [JSON]: send (or, in a dry run, print) one API request.
call() {
    local method="$1" path="$2" body="${3:-}"
    echo "-> $method /repos/$REPO$path"
    if [ -n "$body" ]; then
        # Validate the payload even in a dry run so typos surface early.
        if ! echo "$body" | jq -e . >/dev/null; then
            echo "   !! invalid JSON payload" >&2
            FAILED=$((FAILED + 1))
            return 1
        fi
        [ "$APPLY" = true ] || echo "$body" | jq -c . | sed 's/^/   /'
    fi
    [ "$APPLY" = true ] || return 0

    local out
    if [ -n "$body" ]; then
        out=$(echo "$body" | gh api -X "$method" "/repos/$REPO$path" --input - 2>&1)
    else
        out=$(gh api -X "$method" "/repos/$REPO$path" 2>&1)
    fi || {
        echo "   !! failed: $(echo "$out" | head -c 300)" >&2
        FAILED=$((FAILED + 1))
        return 1
    }
}

# upsert_ruleset NAME JSON: create the ruleset, or update it if one with that name exists.
upsert_ruleset() {
    local name="$1" body="$2" id=""
    if [ "$APPLY" = true ]; then
        id=$(gh api "/repos/$REPO/rulesets" --jq ".[] | select(.name == \"$name\") | .id" 2>/dev/null | head -1)
    fi
    if [ -n "$id" ]; then
        call PUT "/rulesets/$id" "$body"
    else
        call POST "/rulesets" "$body"
    fi
}

echo "Repository: $REPO"
[ "$APPLY" = true ] && echo "Mode: APPLY" || echo "Mode: dry run (pass --apply to make changes)"
echo

echo "== General: features and merge options"
call PATCH "" '{
  "has_issues": true,
  "has_discussions": true,
  "has_wiki": false,
  "has_projects": false,
  "allow_squash_merge": true,
  "allow_merge_commit": false,
  "allow_rebase_merge": false,
  "allow_auto_merge": false,
  "allow_update_branch": true,
  "delete_branch_on_merge": true,
  "squash_merge_commit_title": "PR_TITLE",
  "squash_merge_commit_message": "PR_BODY"
}'

echo "== Topics"
call PUT "/topics" '{"names":["proxmox","lxc","github-actions","self-hosted-runner","bash","homelab"]}'

echo "== Code security"
call PUT "/vulnerability-alerts"
call PUT "/automated-security-fixes"
call PUT "/private-vulnerability-reporting"
# Secret scanning and push protection are free on public repos; on a private
# repo they need GitHub Advanced Security and this will be reported and skipped.
call PATCH "" '{
  "security_and_analysis": {
    "secret_scanning": {"status": "enabled"},
    "secret_scanning_push_protection": {"status": "enabled"}
  }
}'
# CodeQL "default setup" for the workflow files themselves (Bash isn't supported by CodeQL).
call PATCH "/code-scanning/default-setup" '{"state":"configured","languages":["actions"]}'

echo "== Actions: permissions"
call PUT "/actions/permissions" '{"enabled":true,"allowed_actions":"selected","sha_pinning_required":true}'
# GitHub-owned actions (actions/*) are allowed by github_owned_allowed; the
# rest are an explicit allowlist (see the workflows in .github/workflows).
call PUT "/actions/permissions/selected-actions" '{
  "github_owned_allowed": true,
  "verified_allowed": false,
  "patterns_allowed": [
    "DavidAnson/markdownlint-cli2-action@*",
    "lycheeverse/lychee-action@*",
    "zizmorcore/zizmor-action@*"
  ]
}'
call PUT "/actions/permissions/workflow" '{"default_workflow_permissions":"read","can_approve_pull_request_reviews":false}'
call PUT "/actions/permissions/fork-pr-contributor-approval" '{"approval_policy":"all_external_contributors"}'

echo "== Rulesets"
upsert_ruleset "main" "$(
    jq -n --argjson checks "$REQUIRED_CHECKS" '{
      name: "main",
      target: "branch",
      enforcement: "active",
      conditions: {ref_name: {include: ["~DEFAULT_BRANCH"], exclude: []}},
      # Repository admins may bypass, but only by merging a pull request.
      bypass_actors: [{actor_id: 5, actor_type: "RepositoryRole", bypass_mode: "pull_request"}],
      rules: [
        {type: "deletion"},
        {type: "non_fast_forward"},
        {type: "required_linear_history"},
        {type: "pull_request", parameters: {
          required_approving_review_count: 0,
          dismiss_stale_reviews_on_push: true,
          require_code_owner_review: false,
          require_last_push_approval: false,
          required_review_thread_resolution: true,
          allowed_merge_methods: ["squash"]
        }},
        {type: "required_status_checks", parameters: {
          strict_required_status_checks_policy: true,
          required_status_checks: ($checks | map({context: .}))
        }}
      ]
    }'
)"
upsert_ruleset "release-tags" '{
  "name": "release-tags",
  "target": "tag",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["refs/tags/v*"], "exclude": []}},
  "bypass_actors": [],
  "rules": [{"type": "deletion"}, {"type": "non_fast_forward"}, {"type": "update"}]
}'

if [ "$SKIP_PAGES" = false ]; then
    echo "== Pages (source: GitHub Actions) and the github-pages environment"
    # POST creates the site; if it already exists, PUT updates it.
    if [ "$APPLY" = true ] && gh api "/repos/$REPO/pages" >/dev/null 2>&1; then
        call PUT "/pages" '{"build_type":"workflow"}'
    else
        call POST "/pages" '{"build_type":"workflow"}'
    fi
    call PUT "/environments/github-pages" '{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}'
    call POST "/environments/github-pages/deployment-branch-policies" '{"name":"main","type":"branch"}'
fi

echo
echo "Done. Failed calls: $FAILED"
cat <<'NOTES'

Not settable through this script:
  - Repository visibility (Settings > General > Danger Zone > Change visibility).
  - 2FA / passkey on your GitHub account (Settings > Password and authentication).
  - Homepage URL, description and social preview image (Settings > General); set the
    homepage to https://chrismartino.github.io/pve-gha-runner/ once Pages is live.
  - Requiring approval before running workflows from forks is set above; also review
    Settings > Actions > General once by eye after going public.
NOTES
[ "$FAILED" -eq 0 ]
