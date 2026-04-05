> [!WARNING]  
> **x86_64** only

```sh
# Import and trust the key
sudo pacman-key --recv-keys 06173DBA6E1A22B8D13F1FC3B46745055BE38B78 --keyserver keyserver.ubuntu.com
sudo pacman-key --lsign-key 06173DBA6E1A22B8D13F1FC3B46745055BE38B78

# Add the repo
sudo tee -a /etc/pacman.conf << 'EOF'
[shinkouyo-pkgs]
Server = https://pkgs.0x0f.dev/$arch
EOF

# Refresh package databases
sudo pacman -Sy
```
