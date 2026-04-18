> [!TIP]  
> Available for **x86_64** only  
> **Feel free to request new packages via [Issues](https://github.com/shkouyo/shinkouyo-pkgs/issues/new?template=new-package.yml), or to submit them directly via [Pull Requests](https://github.com/shkouyo/shinkouyo-pkgs/compare)**  
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
