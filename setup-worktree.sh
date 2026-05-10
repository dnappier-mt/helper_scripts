#!/bin/bash
# Usage: source setup-worktree.sh <branch-name>
#
# One-time setup  — initializes kas submodule, creates kas-container-local
#                   and local.yaml, excludes them from git. Skips steps that
#                   are already done.
#
# Shell setup     — defines kas-container() in the sourcing shell so builds
#                   can be run from any directory.
#
# Source again with a different branch to switch to a different worktree.

if [[ "${BASH_SOURCE[0]:-}" == "$0" ]]; then
    echo "Error: this script must be sourced, not executed."
    echo "Usage: source $(basename "$0") <branch-name>"
    exit 1
fi

_BRANCH="${1:-}"
if [ -z "$_BRANCH" ]; then
    echo "Usage: source setup-worktree.sh <branch-name>"
    return 1 2>/dev/null || exit 1
fi

_REPOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
_FIRMWARE_DIR="$_REPOS_DIR/firmware"
_WORKTREE_DIR="$_REPOS_DIR/firmware-worktrees/$_BRANCH"
_YOCTO_DIR="$_WORKTREE_DIR/yocto-bsp"

if [ ! -d "$_WORKTREE_DIR" ]; then
    echo "Error: worktree not found at $_WORKTREE_DIR"
    echo "Create it first: git -C firmware worktree add ../firmware-worktrees/$_BRANCH $_BRANCH"
    return 1 2>/dev/null || exit 1
fi

# ── One-time setup ──────────────────────────────────────────────────────────

# Init kas submodule if not already done
if [ ! -f "$_YOCTO_DIR/kas/kas-container" ]; then
    echo "Initializing kas submodule..."
    git -C "$_YOCTO_DIR" submodule update --init kas 2>&1 || true
    if [ ! -f "$_YOCTO_DIR/kas/kas-container" ]; then
        _KAS_COMMIT=$(git -C "$_YOCTO_DIR" submodule status kas | awk '{print $1}' | tr -d '+')
        git -C "$_YOCTO_DIR/kas" checkout "$_KAS_COMMIT"
    fi
fi

# Create kas-container-local wrapper if not present or missing worktree-src mount
if [ ! -f "$_YOCTO_DIR/kas-container-local" ] || \
   ! grep -q "worktree-src" "$_YOCTO_DIR/kas-container-local"; then
    echo "Creating kas-container-local..."
    cat > "$_YOCTO_DIR/kas-container-local" << EOF
#!/bin/bash
SCRIPT_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
exec "\$SCRIPT_DIR/kas/kas-container" \\
    --runtime-args "-v /mnt/workspace/mt-connect/yocto-shared:/yocto-shared" \\
    --runtime-args "-v /mnt/workspace/mt-connect/yocto-shared/bin/pzstd:/usr/bin/pzstd:ro" \\
    --runtime-args "-v $_WORKTREE_DIR/imx8-a53:/worktree-src:ro" \\
    "\$@"
EOF
    chmod +x "$_YOCTO_DIR/kas-container-local"
fi

# Create local.yaml overlay if not present
if [ ! -f "$_YOCTO_DIR/local.yaml" ]; then
    echo "Creating local.yaml..."
    cat > "$_YOCTO_DIR/local.yaml" << 'EOF'
header:
  version: 1
local_conf_header:
  shared_cache: |
    DL_DIR = "/yocto-shared/downloads"
    SSTATE_DIR = "/yocto-shared/sstate-cache"
EOF
fi

# Exclude generated files from git (idempotent)
_EXCLUDE="$_FIRMWARE_DIR/.git/worktrees/$_BRANCH/info/exclude"
mkdir -p "$(dirname "$_EXCLUDE")"
grep -qxF "yocto-bsp/kas-container-local" "$_EXCLUDE" 2>/dev/null || echo "yocto-bsp/kas-container-local" >> "$_EXCLUDE"
grep -qxF "yocto-bsp/local.yaml"          "$_EXCLUDE" 2>/dev/null || echo "yocto-bsp/local.yaml"          >> "$_EXCLUDE"

# ── mt-apps devtool workspace setup ─────────────────────────────────────────
# Run once per worktree: creates devtool bbappend with EXTERNALSRC = /worktree-src
# -n skips source extraction; /worktree-src is the container mount of imx8-a53/
if ! ls "$_YOCTO_DIR/build/workspace/appends/mt-apps_"*.bbappend &>/dev/null 2>&1; then
    echo "Setting up mt-apps devtool workspace..."
    (cd "$_YOCTO_DIR" && "$_YOCTO_DIR/kas-container-local" \
        --ssh-agent --ssh-dir "$HOME/.ssh" \
        shell "mt-connect-dev.yaml:local.yaml" \
        -c "devtool modify -n mt-apps /worktree-src") || true
fi

# ── Shell setup ─────────────────────────────────────────────────────────────
# _KAS_WRAPPER and _KAS_YAML persist in the shell so the function can use them.
# Re-sourcing with a different branch updates them, switching the active worktree.

# Start ssh-agent if not already running
if ! ssh-add -l &>/dev/null; then
    eval $(ssh-agent -s) >/dev/null
    ssh-add ~/.ssh/id_ed25519 2>/dev/null
    echo "ssh-agent started."
fi

export _KAS_WRAPPER="$_YOCTO_DIR/kas-container-local"
export _KAS_YOCTO_DIR="$_YOCTO_DIR"

kas-container() {
    if [ $# -eq 0 ]; then
        (cd "$_KAS_YOCTO_DIR" && "$_KAS_WRAPPER" --ssh-agent --ssh-dir "$HOME/.ssh" shell "mt-connect-dev.yaml:local.yaml")
    else
        (cd "$_KAS_YOCTO_DIR" && "$_KAS_WRAPPER" --ssh-agent --ssh-dir "$HOME/.ssh" shell "mt-connect-dev.yaml:local.yaml" -c "$*")
    fi
}

echo "Worktree: $_WORKTREE_DIR"
echo "kas-container() configured — active for this shell."
echo ""
echo "  kas-container                              # dev shell"
echo "  kas-container bitbake multitracks-image-dev  # run build"

# Clean up temp locals — _KAS_WRAPPER and _KAS_YAML intentionally kept
unset _BRANCH _REPOS_DIR _FIRMWARE_DIR _WORKTREE_DIR _YOCTO_DIR _EXCLUDE _KAS_COMMIT _KAS_YAML
