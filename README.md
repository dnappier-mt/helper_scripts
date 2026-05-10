# MT-Connect Helper Scripts

## setup-worktree.sh

Configures a firmware git worktree for building `multitracks-image-dev` from any directory.

### The problem

The standard kas build workflow requires you to `cd` into `firmware/yocto-bsp/` before every build. When working across multiple feature branches simultaneously via git worktrees, each worktree has a cold `downloads/` and `sstate-cache/`, making the first build of every worktree take hours.

This script solves both problems:

- **Shared cache** — all worktrees share a single `downloads/` and `sstate-cache/` on disk, so subsequent worktree builds get full sstate hits from prior builds
- **Build from anywhere** — defines a `kas-container()` shell function so you can run builds without `cd`-ing first
- **pzstd fix** — the kas 4.8.2 container image ships a `pzstd` binary linked against a newer `libstdc++` than the image provides (`CXXABI_1.3.15` missing), which breaks sstate archiving. The script mounts a working `zstd`-backed wrapper over the broken binary
- **mt-apps devtool workspace** — runs `devtool modify mt-apps` once and replaces the cloned source with a symlink back to `imx8-a53/` in your worktree, so changes you make in the repo are immediately visible to bitbake builds inside the container

### Prerequisites

**1. Shared cache directory**

Create the shared cache once on your machine:

```bash
mkdir -p /mnt/workspace/mt-connect/yocto-shared/downloads
mkdir -p /mnt/workspace/mt-connect/yocto-shared/sstate-cache
mkdir -p /mnt/workspace/mt-connect/yocto-shared/bin
```

If you have an existing build, move the cache there:

```bash
mv firmware/yocto-bsp/build/downloads/* /mnt/workspace/mt-connect/yocto-shared/downloads/
mv firmware/yocto-bsp/build/sstate-cache/* /mnt/workspace/mt-connect/yocto-shared/sstate-cache/
```

**2. pzstd wrapper**

Create the wrapper once and make it executable:

```bash
cat > /mnt/workspace/mt-connect/yocto-shared/bin/pzstd << 'EOF'
#!/bin/bash
# Translates pzstd -p <threads> to zstd -T<threads>
args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p) n="$2"; [[ "$n" -lt 0 ]] && n=0; args+=("-T$n"); shift 2 ;;
        *) args+=("$1"); shift ;;
    esac
done
exec zstd "${args[@]}"
EOF
chmod +x /mnt/workspace/mt-connect/yocto-shared/bin/pzstd
```

**3. Git worktree**

The script expects the worktree to already exist at `firmware-worktrees/<branch>/`:

```bash
cd /mnt/workspace/mt-connect/repos
git -C firmware worktree add ../firmware-worktrees/MT-XXXXX-my-feature MT-XXXXX-my-feature
```

### Usage

Source the script with your branch name:

```bash
source /mnt/workspace/mt-connect/repos/setup-worktree.sh MT-XXXXX-my-feature
```

On first run it:
1. Initialises the kas submodule (with a fallback for GitHub upload-pack ref rejections)
2. Creates `yocto-bsp/kas-container-local` — a wrapper that mounts the shared cache, pzstd fix, and worktree's `imx8-a53/` into the container
3. Creates `yocto-bsp/local.yaml` — a kas overlay that sets `DL_DIR` and `SSTATE_DIR` to the shared paths
4. Excludes both files from git via `.git/worktrees/<branch>/info/exclude`
5. Runs `devtool modify mt-apps` to create the devtool bbappend, then replaces the cloned source directory with a symlink to `/worktree-src` (the container-internal path for `imx8-a53/`)
6. Starts `ssh-agent` and loads `~/.ssh/id_ed25519` if not already running

On subsequent sources (same or different worktree) it skips setup steps already done and just configures the shell.

After sourcing, use `kas-container` from any directory:

```bash
# Drop into the kas dev shell
kas-container

# Run a build directly
kas-container bitbake multitracks-image-dev

# Switch to a different worktree
source /mnt/workspace/mt-connect/repos/setup-worktree.sh MT-YYYYY-other-feature
kas-container bitbake virtual/kernel
```

### What the script creates per worktree

| File / path | Purpose |
|-------------|---------|
| `yocto-bsp/kas-container-local` | Wrapper that adds shared cache, pzstd, and `imx8-a53/` mounts to every `kas-container` invocation |
| `yocto-bsp/local.yaml` | kas yaml overlay — sets `DL_DIR` and `SSTATE_DIR` to `/yocto-shared/` inside the container |
| `yocto-bsp/build/workspace/appends/mt-apps_*.bbappend` | devtool bbappend — tells bitbake to use `EXTERNALSRC` for mt-apps |
| `yocto-bsp/build/workspace/sources/mt-apps` → `/worktree-src` | Symlink — resolves inside the container to `imx8-a53/` in your worktree |

`kas-container-local` and `local.yaml` are gitignored at the worktree level and never committed.

### How the mt-apps symlink works

Inside the container, `imx8-a53/` from your worktree is mounted at `/worktree-src`. The devtool workspace's `sources/mt-apps` symlink points to `/worktree-src`. BitBake follows the symlink and builds directly from your checkout — no manual file copying needed. Any source edit in your worktree's `imx8-a53/` is immediately visible to the next `devtool build mt-apps` or `bitbake mt-apps`.
