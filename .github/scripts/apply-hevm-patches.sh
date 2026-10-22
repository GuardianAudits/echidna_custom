#! /bin/bash

# Point Stack at the same patched hevm Nix builds. Stack extra-deps clone
# upstream hevm with no patches, so fields such as recordingStorageAccesses
# are missing and the Docker image fails to compile.

set -eux

if ! command -v git >/dev/null 2>&1 || ! command -v patch >/dev/null 2>&1; then
  echo "git and patch are required" >&2
  exit 1
fi

cd "$(dirname "$0")/../.."

if [ -f vendor/hevm/hevm.cabal ] && grep -q '^- vendor/hevm$' stack.yaml; then
  exit 0
fi

commit=$(awk '
  index($0, "github.com/argotorg/hevm.git") { found=1; next }
  found && $1 == "commit:" { print $2; exit }
' stack.yaml)
if [ -z "$commit" ]; then
  echo "hevm git commit not found in stack.yaml" >&2
  exit 1
fi

rm -rf vendor/hevm
mkdir -p vendor
git init vendor/hevm
git -C vendor/hevm remote add origin https://github.com/argotorg/hevm.git
git -C vendor/hevm fetch --depth 1 origin "$commit"
git -C vendor/hevm checkout --detach FETCH_HEAD

# Base patch list from flake.nix, the one applied before extraPatches.
patches=$(awk '
  /patches = \[/ { inlist=1; next }
  inlist && /extraPatches/ { exit }
  inlist && /nix\/patches\// {
    line = $0
    sub(/^[^n]*nix\/patches\//, "nix/patches/", line)
    sub(/[[:space:]]+$/, "", line)
    print line
  }
' flake.nix)

if ! printf '%s\n' "$patches" | grep -q 'hevm-storage-recording-and-token-deal.patch'; then
  echo "flake.nix base hevm patch list is missing the storage-recording patch" >&2
  exit 1
fi

while IFS= read -r patch; do
  [ -n "$patch" ] || continue
  [ -f "$patch" ] || { echo "missing $patch" >&2; exit 1; }
  patch -p1 --forward --directory=vendor/hevm --input="$PWD/$patch"
done <<EOF
$patches
EOF

awk '
  index($0, "github.com/argotorg/hevm.git") { print "- vendor/hevm"; skip=1; next }
  skip && $1 == "commit:" { skip=0; next }
  { print }
' stack.yaml > stack.yaml.hevm-patched
mv stack.yaml.hevm-patched stack.yaml
