/**
  Builds the ext4 filesystem mounted at /nix on a stateless SD card: the
  store at `store/`, the registration manifest at `nix-path-registration`,
  and whatever `populateImageCommands` puts into ./files (boot files,
  persistence skeleton) at the root.

  A variant of nixpkgs' make-ext4-fs.nix, which lays the store out at
  `nix/store/` for a filesystem mounted at `/`. Everything is chowned to
  root inside the same fakeroot session that runs mkfs, so the image does
  not carry the build user's IDs.

  It plugs into `sdImage.rootFilesystemCreator` and takes the same
  arguments as make-ext4-fs.nix.
*/
{
  pkgs,
  lib,
  storePaths,
  compressImage ? false,
  populateImageCommands ? "",
  volumeLabel,
  uuid ? "44444444-4444-4444-8888-888888888888",
  e2fsprogs,
  libfaketime,
  fakeroot,
  zstd,
}:

let
  closure = pkgs.buildPackages.closureInfo { rootPaths = storePaths; };
in
pkgs.stdenv.mkDerivation {
  name = "nix-fs.img${lib.optionalString compressImage ".zst"}";

  nativeBuildInputs = [
    e2fsprogs.bin
    libfaketime
    fakeroot
  ]
  ++ lib.optional compressImage zstd;

  buildCommand = ''
    img=${if compressImage then "temp.img" else "$out"}

    mkdir -p ./files
    (
      ${populateImageCommands}
    )

    mkdir -p ./nixImage/store
    xargs -I % cp -a --reflink=auto % -t ./nixImage/store/ < ${closure}/store-paths
    cp -a --reflink=auto ./files/. ./nixImage/
    cp ${closure}/registration ./nixImage/nix-path-registration

    # Same sizing heuristic as make-ext4-fs.nix; grown to fit the card on
    # first boot anyway.
    numInodes=$(find ./nixImage | wc -l)
    numDataBlocks=$(du -s -c -B 4096 --apparent-size ./nixImage | tail -1 | awk '{ print int($1 * 1.20) }')
    bytes=$((2 * 4096 * numInodes + 4096 * numDataBlocks))
    mebibyte=$((1024 * 1024))
    bytes=$(( (bytes + mebibyte - 1) / mebibyte * mebibyte ))
    echo "creating a $bytes byte ext4 image ($numInodes inodes)"
    truncate -s "$bytes" "$img"

    # Modes (read-only store, 1777 tmp) survive; only ownership is reset.
    faketime -f "1970-01-01 00:00:01" fakeroot sh -c '
      set -e
      chown -R 0:0 ./nixImage
      mkfs.ext4 -L ${volumeLabel} -U ${uuid} -d ./nixImage "'"$img"'"
    '

    export EXT2FS_NO_MTAB_OK=yes
    fsck.ext4 -n -f "$img"
    resize2fs -M "$img"
    # 16 MiB of slack, as make-ext4-fs.nix leaves.
    new_size=$(dumpe2fs -h "$img" | awk -F: \
      '/Block count/{count=$2} /Block size/{size=$2} END{print (count*size+16*2**20)/size}')
    resize2fs "$img" "$new_size"

    ${lib.optionalString compressImage ''
      zstd -T$NIX_BUILD_CORES --no-progress "$img" -o "$out"
    ''}
  '';
}
