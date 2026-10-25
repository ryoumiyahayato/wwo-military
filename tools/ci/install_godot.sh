#!/usr/bin/env bash
# Official standard editor only; keep TLS and release checksum verification enabled.
set -euo pipefail
destination=${1:?Usage: install_godot.sh DESTINATION}
mkdir -p "$destination"
cd "$destination"
archive=Godot_v4.6.3-stable_linux.x86_64.zip
release=https://github.com/godotengine/godot-builds/releases/download/4.6.3-stable
expected=a035258da32b77f966a5376f9fa29c30a6adde826a85ba918e1605bd1fc9823eba7d85f1dd5e748956bd2ba72827c0025ffa11bb82aec91128c407a2e723c99c
curl --fail --location --silent --show-error --retry 3 --max-time 180 --proto '=https' --proto-redir '=https' "$release/SHA512-SUMS.txt" -o SHA512-SUMS.txt
published=$(awk -v file="$archive" '$2 == file {print $1}' SHA512-SUMS.txt)
test "$published" = "$expected"
curl --fail --location --silent --show-error --retry 3 --max-time 180 --proto '=https' --proto-redir '=https' "$release/$archive" -o "$archive"
printf '%s  %s\n' "$expected" "$archive" > engine-sha512.txt
sha512sum --check engine-sha512.txt
unzip -oq "$archive" Godot_v4.6.3-stable_linux.x86_64
chmod +x Godot_v4.6.3-stable_linux.x86_64
version=$(./Godot_v4.6.3-stable_linux.x86_64 --headless --version)
printf '%s\n' "$version" | tee engine-version.txt
test "$version" = '4.6.3.stable.official.7d41c59c4'
printf '%s\n' "$release/$archive" > engine-source-url.txt
