> [!NOTE]  
> Available for **x86_64** only  
> **Feel free to request new packages via [Issues](https://github.com/shkouyo/shinkouyo-pkgs/issues/new?template=new-package.yml), or to submit them directly via [Pull Requests](https://github.com/shkouyo/shinkouyo-pkgs/compare)**  
> [Package list](https://github.com/shkouyo/shinkouyo-pkgs/tree/main/packages)

```sh
# Import and trust the key
curl -s https://gist.0x0f.dev/ShinKouyo_0xB46745055BE38B78_public.asc | sudo pacman-key --add -
sudo pacman-key --lsign-key 06173DBA6E1A22B8D13F1FC3B46745055BE38B78

# Add the repo
sudo tee -a /etc/pacman.conf << 'EOF'
[shinkouyo-pkgs]
SigLevel = Required DatabaseOptional
Server = https://$arch.shinkouyo-pkgs.top
EOF

# Refresh package databases
sudo pacman -Sy
```

> [!TIP]
> You can choose the preferred server manually:
> ```ini
> # Geo (Auto-redirect based on location)
> Server = https://geo.shinkouyo-pkgs.top/$arch
> ```
> ```ini
> # Cloudflare R2 (Global primary)
> Server = https://r2.shinkouyo-pkgs.top/$arch
> ```
> ```ini
> # Rainyun ROS (Mainland China mirror)
> Server = https://cn.shinkouyo-pkgs.top/$arch
> ```
