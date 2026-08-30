#!/usr/bin/env bash
set -euo pipefail
WORK=/tmp/rw-fixture
mkdir -p "$WORK/valhalla_tiles" && cd "$WORK"
# download.geofabrik.de was returning 502s (squid backend error) at the time this
# fixture was built; download.openstreetmap.fr mirrors the same Geofabrik extracts.
curl -fL -o monaco.osm.pbf https://download.openstreetmap.fr/extracts/europe/monaco-latest.osm.pbf
docker run --rm -v "$WORK:/work" ghcr.io/valhalla/valhalla:3.6.2 \
  valhalla_build_config --mjolnir-tile-dir /work/valhalla_tiles > valhalla.json
docker run --rm -v "$WORK:/work" ghcr.io/valhalla/valhalla:3.6.2 \
  valhalla_build_tiles -c /work/valhalla.json /work/monaco.osm.pbf
sudo chown -R "$(id -u):$(id -g)" valhalla_tiles
# Flatten: Flutter n'inclut que les enfants directs d'un dossier d'assets,
# donc on aplatit les chemins avec le même schéma que les assets GitHub (/ -> _).
mkdir -p flat
(cd valhalla_tiles && find . -name '*.gph' -print0) | while IFS= read -r -d '' f; do
  cp "valhalla_tiles/$f" "flat/$(echo "${f#./}" | tr / _)"
done
du -sh flat && echo "OK: scp -r dev.lmqc.fr:$WORK/flat/* app/integration_test/fixtures/monaco_tiles/"
