> [!TIP]  
> Available for **x86_64** only  
> [Package list](https://github.com/shkouyo/shinkouyo-pkgs/tree/main/packages)

```sh
# Import and trust the key
sudo pacman-key \
  --recv-keys 06173DBA6E1A22B8D13F1FC3B46745055BE38B78 \
  --keyserver keyserver.ubuntu.com

sudo pacman-key \
  --lsign-key 06173DBA6E1A22B8D13F1FC3B46745055BE38B78

# Add the repo
sudo tee -a /etc/pacman.conf << 'EOF'
[shinkouyo-pkgs]
SigLevel = Required DatabaseOptional
Server = https://pkgs.0x0f.dev/$arch
EOF

# Refresh package databases
sudo pacman -Sy
```

## Repository layout

- `packages/`: package manifests. Each file describes one package source and build metadata.
- `scripts/`: stable operator entrypoints such as build, update-check, publish, remove, and reconcile.
- `scripts/lib/`: shared shell helpers for repo state, R2 interaction, manifest loading, and environment validation.
- `scripts/ci/`: GitHub Actions helpers for matrix planning, non-root VCS probing, and build-context preparation.
- `.github/workflows/`: operator-facing workflows plus internal reusable workflows prefixed with `_`.
