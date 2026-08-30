# M1 Fondations — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Livrer le socle de RandomWalk : app Flutter Android avec carte MapLibre, routage Valhalla embarqué A→B (piéton/vélo) sur tuiles téléchargées automatiquement autour de la position, enregistreur de distance primitif et leaderboard global synchronisé via drive.lmqc.fr.

**Architecture:** Les tuiles Valhalla sont construites chaque semaine par GitHub Actions (repo public `randomwalk-tiles`, région Suisse + France frontalière) et publiées en GitHub Releases ; l'app calcule localement les ids de tuiles couvrant sa position (grille Valhalla déterministe) et ne télécharge que celles-là. Le routage tourne dans le process Android via l'AAR précompilé valhalla-mobile, piloté en JSON par MethodChannel derrière une interface Dart `RoutingEngine`. Le VPS n'héberge que la micro-API leaderboard (FastAPI + SQLite en conteneur derrière le Traefik existant).

**Tech Stack:** Flutter (Dart 3, Riverpod), maplibre_gl, geolocator, valhalla-mobile (Kotlin/AAR), Python 3.12 + FastAPI (serveur), GitHub Actions/Releases, Docker + Traefik v3.6 sur Ubuntu.

## Global Constraints

- **Valhalla 3.6.2 partout** : image serveur `ghcr.io/valhalla/valhalla:3.6.2` ↔ app `io.github.rallista:valhalla-mobile:0.6.3`. Ne jamais mélanger des tuiles de deux builds ni de deux versions (limitation Valhalla confirmée, issue valhalla#1913).
- Plugin carte : `maplibre_gl: ^0.27.0`. Style : `https://tiles.openfreemap.org/styles/liberty` (constante `kMapStyleUrl`, prévue pour devenir configurable à distance). Attribution obligatoire : `OpenFreeMap © OpenMapTiles, Data from OpenStreetMap`.
- Android : `applicationId fr.lmqc.randomwalk`, `minSdk 24` (exigence valhalla-mobile), `targetSdk` = défaut Flutter.
- Manifeste des tuiles : URL stable `https://github.com/igapon/randomwalk-tiles/releases/latest/download/manifest.json` ; assets à `https://github.com/igapon/randomwalk-tiles/releases/download/<dataset_version>/<asset>`.
- API leaderboard : base `https://drive.lmqc.fr` (`POST /v1/score`, `GET /v1/leaderboard`).
- Région M1 : **Suisse + France frontalière** — fusion `osmium merge` des extraits Geofabrik `europe/switzerland`, `europe/france/rhone-alpes`, `europe/france/franche-comte`, `europe/france/alsace`, découpée au bbox `4.8,45.0 → 11.0,48.2` (Suisse + ~50 km), puis UN SEUL build Valhalla (jamais de tuiles issues de builds séparés). Nom de région : `ch-fr`.
- Git : identité `iaro <iaro@ik.me>` (déjà configurée), messages Conventional Commits. Dépôt app : `igapon/randomwalk` (privé). Dépôt tuiles : `igapon/randomwalk-tiles` (public — requis pour les téléchargements de Releases sans auth).
- UI en français ; code, commentaires et messages de commit en anglais.
- **Insets Android obligatoires** : tout écran/overlay gère la barre système du bas (SafeArea / MediaQuery.viewPadding) — FAB, bandeaux bas, boutons flottants jamais masqués par la barre de navigation (erreur récurrente signalée par le propriétaire du projet ; vérifier en gestuel et en 3-boutons).
- SSH serveur : `ssh dev.lmqc.fr` (alias configuré → ubuntu@51.77.231.190). Réseau Traefik : `frappe_docker_default`, certresolver `main-resolver`, entrypoint `websecure`.
- TDD : chaque comportement non trivial naît d'un test qui échoue d'abord.

## Structure des fichiers

```
randomwalk/                       (repo privé igapon/randomwalk — ce repo)
  app/                            application Flutter
    lib/main.dart                 shell (BottomNavigationBar 3 onglets)
    lib/map/map_screen.dart       carte + routage UI
    lib/valhalla/grid.dart        maths de grille de tuiles (pur Dart)
    lib/valhalla/models.dart      RouteRequest/RouteResult/polyline6
    lib/valhalla/engine.dart      interface RoutingEngine
    lib/valhalla/engine_channel.dart  impl MethodChannel
    lib/coverage/manifest.dart    modèle TileManifest
    lib/coverage/coverage_repository.dart  téléchargement/LRU
    lib/session/recorder.dart     distance GPS primitive
    lib/session/session_screen.dart
    lib/leaderboard/repository.dart
    lib/leaderboard/leaderboard_screen.dart
    lib/settings/identity.dart    uuid + pseudo (shared_preferences)
    lib/settings/settings_screen.dart
    assets/valhalla_config.json   config acteur (template, tile_dir patché au runtime)
    android/.../ValhallaChannel.kt, MainActivity.kt
    test/…                        tests unitaires par module
    integration_test/routing_test.dart + fixtures/monaco_tiles/ (fixture committée)
    tool/build_fixture_tiles.sh   build fixture Monaco (s'exécute sur le VPS, docker)
  server/leaderboard/
    app.py, test_app.py, requirements.txt, Dockerfile, compose.yaml
  .github/workflows/ci.yml        analyze + tests Dart, pytest
randomwalk-tiles/                 (repo public séparé, dossier frère local)
  make_manifest.py, test_make_manifest.py
  .github/workflows/build-tiles.yml
  README.md                       (attribution ODbL OpenStreetMap)
```

---

### Task 1: Repo `randomwalk-tiles` — manifeste + workflow de build/publication

**Files:**
- Create: `C:\Users\Office365Administrat\randomwalk-tiles\make_manifest.py`
- Create: `C:\Users\Office365Administrat\randomwalk-tiles\test_make_manifest.py`
- Create: `C:\Users\Office365Administrat\randomwalk-tiles\.github\workflows\build-tiles.yml`
- Create: `C:\Users\Office365Administrat\randomwalk-tiles\README.md`

**Interfaces:**
- Produces (contrat consommé par la Task 6 côté app) — `manifest.json` :
  ```json
  {
    "dataset_version": "20260830T020000Z",
    "valhalla_version": "3.6.2",
    "region": "switzerland",
    "tiles": {
      "2/000/756/425.gph": {"asset": "2_000_756_425.gph", "bytes": 12345, "sha256": "<hex>"}
    }
  }
  ```
  Clé = chemin de tuile Valhalla ; `asset` = nom d'asset GitHub (les `/` deviennent `_`). Le tag de la Release EST `dataset_version`.

- [ ] **Step 1: Vérifier les prérequis et créer le repo local**

```bash
docker manifest inspect ghcr.io/valhalla/valhalla:3.6.2 > /dev/null && echo IMAGE-OK
```
(à exécuter via `ssh dev.lmqc.fr` — docker n'est pas installé sur le poste Windows). Si le tag 3.6.2 n'existe pas, lister les tags proches (`skopeo list-tags docker://ghcr.io/valhalla/valhalla` via docker run quay.io/skopeo/stable) et choisir le tag 3.6.x le plus proche ; reporter la version retenue dans TOUTES les occurrences « 3.6.2 » du projet (workflow, app, fixture).

```powershell
mkdir C:\Users\Office365Administrat\randomwalk-tiles; cd C:\Users\Office365Administrat\randomwalk-tiles
git init; git config user.name iaro; git config user.email iaro@ik.me
```

- [ ] **Step 2: Écrire le test du générateur de manifeste**

`test_make_manifest.py` :
```python
import json
from pathlib import Path
from make_manifest import asset_name, build_manifest

def test_asset_name_flattens_path():
    assert asset_name("2/000/756/425.gph") == "2_000_756_425.gph"

def test_build_manifest(tmp_path: Path):
    (tmp_path / "2/000/756").mkdir(parents=True)
    (tmp_path / "2/000/756/425.gph").write_bytes(b"abc")
    (tmp_path / "0/002").mkdir(parents=True)
    (tmp_path / "0/002/906.gph").write_bytes(b"defg")
    m = build_manifest(tmp_path, "20260830T000000Z", "3.6.2", "switzerland")
    assert m["dataset_version"] == "20260830T000000Z"
    assert m["tiles"]["2/000/756/425.gph"]["bytes"] == 3
    assert m["tiles"]["2/000/756/425.gph"]["asset"] == "2_000_756_425.gph"
    assert m["tiles"]["0/002/906.gph"]["sha256"] == (
        "543ec4de44b481b8b6b988b9c0ed3b30bf1c4779fc9b34c8c6b148f4b4a01a63")
    assert json.dumps(m)  # sérialisable
```
(le sha256 attendu est celui de `b"defg"` — le recalculer si le test échoue sur cette valeur : `python -c "import hashlib;print(hashlib.sha256(b'defg').hexdigest())"` et corriger la constante.)

- [ ] **Step 3: Le voir échouer** — `python -m pytest test_make_manifest.py -v` → FAIL (module absent). Si python manque sur le poste, exécuter les tests dans docker sur le VPS : `ssh dev.lmqc.fr "docker run --rm -v /tmp/rwt:/w -w /w python:3.12-slim sh -c 'pip -q install pytest && pytest -v'"` après `scp` des deux fichiers vers `/tmp/rwt`.

- [ ] **Step 4: Implémenter `make_manifest.py`**

```python
#!/usr/bin/env python3
"""Emit manifest.json for a Valhalla tile tree (GitHub-release asset mapping)."""
import hashlib
import json
import sys
from pathlib import Path


def asset_name(rel_path: str) -> str:
    return rel_path.replace("/", "_")


def build_manifest(tile_dir: Path, dataset_version: str,
                   valhalla_version: str, region: str) -> dict:
    tiles = {}
    for p in sorted(tile_dir.rglob("*.gph")):
        rel = p.relative_to(tile_dir).as_posix()
        tiles[rel] = {
            "asset": asset_name(rel),
            "bytes": p.stat().st_size,
            "sha256": hashlib.sha256(p.read_bytes()).hexdigest(),
        }
    return {"dataset_version": dataset_version,
            "valhalla_version": valhalla_version,
            "region": region, "tiles": tiles}


if __name__ == "__main__":
    tile_dir, version, valhalla_version, region = sys.argv[1:5]
    print(json.dumps(build_manifest(Path(tile_dir), version,
                                    valhalla_version, region), indent=1))
```

- [ ] **Step 5: Tests verts** — `python -m pytest test_make_manifest.py -v` → 2 PASS.

- [ ] **Step 6: Écrire le workflow `build-tiles.yml`**

```yaml
name: build-tiles
on:
  schedule:
    - cron: "0 2 * * 1"   # lundi 02:00 UTC
  workflow_dispatch: {}
permissions:
  contents: write
env:
  VALHALLA_IMAGE: ghcr.io/valhalla/valhalla:3.6.2
  VALHALLA_VERSION: "3.6.2"
  REGION: ch-fr
  BBOX: "4.8,45.0,11.0,48.2"   # Suisse + ~50 km de France voisine
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Download and merge OSM extracts
        run: |
          sudo apt-get update -q && sudo apt-get install -y -q osmium-tool
          base=https://download.geofabrik.de/europe
          for e in switzerland france/rhone-alpes france/franche-comte france/alsace; do
            curl -fL --retry 3 -o "$(basename "$e").osm.pbf" "$base/$e-latest.osm.pbf"
          done
          osmium merge ./*.osm.pbf -o merged.osm.pbf
          osmium extract --bbox "$BBOX" --strategy complete_ways \
            --set-bounds --overwrite -o work.osm.pbf merged.osm.pbf
          rm merged.osm.pbf ./switzerland.osm.pbf ./rhone-alpes.osm.pbf \
             ./franche-comte.osm.pbf ./alsace.osm.pbf
          ls -lh work.osm.pbf
      - name: Build valhalla config
        run: |
          mkdir -p work/valhalla_tiles
          docker run --rm -v "$PWD/work:/work" $VALHALLA_IMAGE \
            valhalla_build_config \
              --mjolnir-tile-dir /work/valhalla_tiles \
              --mjolnir-timezone /work/timezone.db \
              --mjolnir-admin /work/admin.db > work/valhalla.json
      - name: Build timezones and admins
        run: |
          docker run --rm -v "$PWD/work:/work" $VALHALLA_IMAGE \
            bash -c "valhalla_build_timezones > /work/timezone.db"
          docker run --rm -v "$PWD/work:/work" -v "$PWD/work.osm.pbf:/work.osm.pbf:ro" \
            $VALHALLA_IMAGE valhalla_build_admins -c /work/valhalla.json /work.osm.pbf
      - name: Build tiles
        run: |
          docker run --rm -v "$PWD/work:/work" -v "$PWD/work.osm.pbf:/work.osm.pbf:ro" \
            $VALHALLA_IMAGE valhalla_build_tiles -c /work/valhalla.json /work.osm.pbf
          sudo chown -R "$(id -u):$(id -g)" work
      - name: Manifest and assets
        run: |
          VERSION=$(date -u +%Y%m%dT%H%M%SZ)
          echo "VERSION=$VERSION" >> "$GITHUB_ENV"
          python3 make_manifest.py work/valhalla_tiles "$VERSION" "$VALHALLA_VERSION" "$REGION" > manifest.json
          mkdir assets && cp manifest.json assets/
          (cd work/valhalla_tiles && find . -name '*.gph' -print0) | \
            while IFS= read -r -d '' f; do
              cp "work/valhalla_tiles/$f" "assets/$(echo "${f#./}" | tr / _)"
            done
          ls assets | wc -l
      - name: Create release
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          gh release create "$VERSION" assets/* \
            --title "$VERSION" --notes "region=$REGION valhalla=$VALHALLA_VERSION"
      - name: Prune old releases (keep 3)
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          gh release list --limit 100 --json tagName -q '.[].tagName' | tail -n +4 | \
            while read -r tag; do gh release delete "$tag" --cleanup-tag --yes; done
```

- [ ] **Step 7: README avec attribution ODbL**

```markdown
# randomwalk-tiles
Weekly Valhalla 3.6.2 routing tiles for the RandomWalk app (region: Switzerland).
Data © OpenStreetMap contributors, ODbL — https://www.openstreetmap.org/copyright
Extracts by Geofabrik — https://download.geofabrik.de
Each release: one asset per Valhalla tile (`/`→`_` in names) + `manifest.json`.
```

- [ ] **Step 8: Créer le repo GitHub public, pousser, lancer le workflow**

```bash
git add -A && git commit -m "feat: valhalla tile build pipeline (weekly release)"
gh repo create igapon/randomwalk-tiles --public --source . --push
gh workflow run build-tiles.yml --repo igapon/randomwalk-tiles
sleep 10
gh run watch --repo igapon/randomwalk-tiles --exit-status \
  "$(gh run list --repo igapon/randomwalk-tiles --workflow=build-tiles.yml -L1 --json databaseId -q '.[0].databaseId')"
```
Attendu : run vert (~20-45 min). Nombre d'assets ≈ 300-400 (Suisse + France frontalière). Si > 950, STOP : regrouper les tuiles L2 par groupe L1 en `.tar` avant upload (adapter manifest + Task 6) — ne pas improviser en silence, le noter.

- [ ] **Step 9: Vérifier le contrat public**

```bash
curl -fsSL https://github.com/igapon/randomwalk-tiles/releases/latest/download/manifest.json | python -c "import json,sys; m=json.load(sys.stdin); print(m['dataset_version'], m['valhalla_version'], len(m['tiles']))"
```
Attendu : version + `3.6.2` + nombre de tuiles > 0. Télécharger une tuile listée et vérifier son sha256.

---

### Task 2: Micro-API leaderboard (FastAPI + SQLite, TDD)

**Files:**
- Create: `server/leaderboard/app.py`
- Create: `server/leaderboard/test_app.py`
- Create: `server/leaderboard/requirements.txt`

**Interfaces:**
- Produces (contrat consommé par la Task 10) :
  - `POST /v1/score` corps `{"user_id": str(8..64), "pseudo": str(1..24), "total_km": float ≥0}` → `200 {"rank": int, "total_km": float}`. Le score ne diminue jamais ; la hausse est plafonnée à 300 km/jour écoulé (anti-triche primitif).
  - `GET /v1/leaderboard?user_id=<id>` → `{"top": [{"pseudo","total_km","rank"}] (≤50), "me": {"pseudo","total_km","rank"} | null}`.

- [ ] **Step 1: Écrire les tests**

`server/leaderboard/test_app.py` :
```python
import importlib
import pytest
from fastapi.testclient import TestClient


@pytest.fixture()
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("LEADERBOARD_DB", str(tmp_path / "lb.sqlite"))
    import app as app_module
    importlib.reload(app_module)
    return TestClient(app_module.app)


def submit(client, uid="user-0001", pseudo="iaro", km=10.0):
    return client.post("/v1/score",
                       json={"user_id": uid, "pseudo": pseudo, "total_km": km})


def test_submit_and_rank(client):
    assert submit(client, "a" * 8, "alice", 5.0).json()["rank"] == 1
    assert submit(client, "b" * 8, "bob", 9.0).json()["rank"] == 1
    r = client.get("/v1/leaderboard", params={"user_id": "a" * 8}).json()
    assert [e["pseudo"] for e in r["top"]] == ["bob", "alice"]
    assert r["me"]["rank"] == 2


def test_score_never_decreases(client):
    submit(client, "c" * 8, "carol", 50.0)
    assert submit(client, "c" * 8, "carol", 10.0).json()["total_km"] == 50.0


def test_daily_increase_is_capped(client):
    submit(client, "d" * 8, "dave", 0.0)
    r = submit(client, "d" * 8, "dave", 10_000.0)
    assert r.json()["total_km"] <= 301.0  # ~300 km max sur la fenêtre minimale


def test_validation(client):
    assert client.post("/v1/score", json={"user_id": "x", "pseudo": "", "total_km": -1}).status_code == 422


def test_me_absent(client):
    assert client.get("/v1/leaderboard").json()["me"] is None
```

- [ ] **Step 2: Le voir échouer** — `python -m pytest server/leaderboard -v` → FAIL (app absent). `requirements.txt` : `fastapi`, `uvicorn`, `httpx`, `pytest` (versions libres, gelées à l'exécution avec `pip freeze` dans le commit).

- [ ] **Step 3: Implémenter `app.py`**

```python
"""RandomWalk primitive leaderboard — anonymous ids, SQLite, plausibility cap."""
import os
import sqlite3
import threading
import time

from fastapi import FastAPI
from pydantic import BaseModel, Field

MAX_KM_PER_DAY = 300.0
MIN_WINDOW_DAYS = 1 / 24  # tolère une petite hausse même juste après un envoi

app = FastAPI()
_lock = threading.Lock()


def _db() -> sqlite3.Connection:
    conn = sqlite3.connect(os.environ.get("LEADERBOARD_DB", "/data/leaderboard.sqlite"))
    conn.execute(
        "CREATE TABLE IF NOT EXISTS scores("
        " user_id TEXT PRIMARY KEY, pseudo TEXT NOT NULL,"
        " total_km REAL NOT NULL, updated_at REAL NOT NULL)")
    return conn


class Score(BaseModel):
    user_id: str = Field(min_length=8, max_length=64)
    pseudo: str = Field(min_length=1, max_length=24)
    total_km: float = Field(ge=0, le=1_000_000)


def _rank(conn: sqlite3.Connection, km: float) -> int:
    return conn.execute(
        "SELECT COUNT(*) + 1 FROM scores WHERE total_km > ?", (km,)).fetchone()[0]


@app.post("/v1/score")
def submit_score(s: Score):
    now = time.time()
    with _lock, _db() as conn:
        row = conn.execute(
            "SELECT total_km, updated_at FROM scores WHERE user_id = ?",
            (s.user_id,)).fetchone()
        km = s.total_km
        if row:
            prev_km, prev_at = row
            window_days = max((now - prev_at) / 86400.0, MIN_WINDOW_DAYS)
            km = min(km, prev_km + MAX_KM_PER_DAY * window_days)
            km = max(km, prev_km)
        conn.execute(
            "INSERT INTO scores(user_id, pseudo, total_km, updated_at)"
            " VALUES(?,?,?,?) ON CONFLICT(user_id) DO UPDATE SET"
            " pseudo = excluded.pseudo, total_km = ?, updated_at = ?",
            (s.user_id, s.pseudo, km, now, km, now))
        return {"rank": _rank(conn, km), "total_km": km}


@app.get("/v1/leaderboard")
def leaderboard(user_id: str | None = None):
    with _db() as conn:
        top = [{"pseudo": p, "total_km": k, "rank": i + 1}
               for i, (p, k) in enumerate(conn.execute(
                   "SELECT pseudo, total_km FROM scores"
                   " ORDER BY total_km DESC, updated_at ASC LIMIT 50"))]
        me = None
        if user_id:
            row = conn.execute(
                "SELECT pseudo, total_km FROM scores WHERE user_id = ?",
                (user_id,)).fetchone()
            if row:
                me = {"pseudo": row[0], "total_km": row[1],
                      "rank": _rank(conn, row[1])}
        return {"top": top, "me": me}
```

- [ ] **Step 4: Tests verts** — `python -m pytest server/leaderboard -v` → 5 PASS.

- [ ] **Step 5: Commit** — `git add server/leaderboard && git commit -m "feat: leaderboard micro-API (FastAPI + SQLite)"`

---

### Task 3: Déploiement leaderboard sur le VPS (drive.lmqc.fr)

**Files:**
- Create: `server/leaderboard/Dockerfile`
- Create: `server/leaderboard/compose.yaml`

**Interfaces:**
- Consumes: `app.py` (Task 2).
- Produces: `https://drive.lmqc.fr/v1/leaderboard` accessible publiquement en TLS.

- [ ] **Step 1: Dockerfile + compose**

`Dockerfile` :
```dockerfile
FROM python:3.12-slim
WORKDIR /srv
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
ENV LEADERBOARD_DB=/data/leaderboard.sqlite
VOLUME /data
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
```

`compose.yaml` :
```yaml
services:
  leaderboard:
    build: .
    container_name: randomwalk-leaderboard
    restart: unless-stopped
    volumes:
      - /srv/randomwalk/leaderboard-data:/data
    networks: [frappe_docker_default]
    labels:
      traefik.enable: "true"
      traefik.http.routers.rwlb.rule: Host(`drive.lmqc.fr`)
      traefik.http.routers.rwlb.entrypoints: websecure
      traefik.http.routers.rwlb.tls.certresolver: main-resolver
      traefik.http.services.rwlb.loadbalancer.server.port: "8000"
networks:
  frappe_docker_default:
    external: true
```

- [ ] **Step 2: Retirer l'ancien conteneur drive (sans le supprimer)**

```bash
ssh dev.lmqc.fr "docker stop lmqc-drive && docker rename lmqc-drive lmqc-drive-retired-20260830"
```
(Réversible : `docker rename` inverse + `docker start`. Ne PAS faire `docker rm`.)

- [ ] **Step 3: Déployer**

```bash
ssh dev.lmqc.fr "mkdir -p /srv/randomwalk/leaderboard /srv/randomwalk/leaderboard-data" 
scp server/leaderboard/{app.py,requirements.txt,Dockerfile,compose.yaml} dev.lmqc.fr:/srv/randomwalk/leaderboard/
ssh dev.lmqc.fr "cd /srv/randomwalk/leaderboard && docker compose up -d --build"
```
(Si `mkdir /srv` échoue en permission : préfixer `sudo` et `sudo chown ubuntu:ubuntu -R /srv/randomwalk`.)

- [ ] **Step 4: Vérifier de l'extérieur**

```bash
curl -fsS https://drive.lmqc.fr/v1/leaderboard
curl -fsS -X POST https://drive.lmqc.fr/v1/score -H "content-type: application/json" -d '{"user_id":"smoke-test-0001","pseudo":"smoke","total_km":1.5}'
curl -fsS "https://drive.lmqc.fr/v1/leaderboard?user_id=smoke-test-0001"
```
Attendu : `{"top":[...]} `, rang 1, `me` renseigné. (Laisser l'entrée smoke — elle sera écrasée par de vrais scores.)

- [ ] **Step 5: Commit** — `git add server/leaderboard && git commit -m "feat: leaderboard deployment (docker + traefik on drive.lmqc.fr)"`

---

### Task 4: Scaffold app Flutter + CI + repo GitHub

**Files:**
- Create: `app/` (via `flutter create`)
- Create: `.github/workflows/ci.yml`
- Modify: `app/pubspec.yaml`, `app/android/app/build.gradle.kts`, `app/android/app/src/main/AndroidManifest.xml`

**Interfaces:**
- Produces: projet compilable `flutter build apk --debug`, CI verte, dépendances pour toutes les tasks B.

- [ ] **Step 1: Vérifier l'outillage** — `flutter --version` et `flutter doctor` (noter si un émulateur/device Android est disponible : la Task 7 en a besoin). Si Flutter manque, l'installer d'abord (winget ou archive officielle) — c'est bloquant pour tout le reste.

- [ ] **Step 2: Créer le projet**

```powershell
cd C:\Users\Office365Administrat\randomwalk
flutter create app --org fr.lmqc --project-name randomwalk --platforms android,ios
```

- [ ] **Step 3: Dépendances** — dans `app/pubspec.yaml` :

```yaml
dependencies:
  flutter: {sdk: flutter}
  flutter_riverpod: ^2.5.0
  maplibre_gl: ^0.27.0
  geolocator: ^14.0.0
  http: ^1.2.0
  shared_preferences: ^2.3.0
  path_provider: ^2.1.0
  crypto: ^3.0.0
  uuid: ^4.4.0
dev_dependencies:
  flutter_test: {sdk: flutter}
  integration_test: {sdk: flutter}
  flutter_lints: ^5.0.0
flutter:
  uses-material-design: true
  assets:
    - assets/valhalla_config.json
```
Puis `flutter pub get` (ajuster les carets si le résolveur exige — noter tout écart).

- [ ] **Step 4: Config Android** — dans `app/android/app/build.gradle.kts` : `minSdk = 24`. Dans `AndroidManifest.xml`, avant `<application>` :

```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
```

- [ ] **Step 5: `main.dart` minimal (shell 3 onglets, écrans placeholder remplacés par les tasks suivantes)**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void main() => runApp(const ProviderScope(child: RandomWalkApp()));

class RandomWalkApp extends StatelessWidget {
  const RandomWalkApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'RandomWalk',
        theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
        home: const HomeShell(),
      );
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;
  static const _screens = <Widget>[
    Center(child: Text('Carte')),      // remplacé Task 5/8
    Center(child: Text('Session')),    // remplacé Task 9
    Center(child: Text('Classement')), // remplacé Task 10
  ];
  @override
  Widget build(BuildContext context) => Scaffold(
        body: _screens[_tab],
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (i) => setState(() => _tab = i),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.map), label: 'Carte'),
            NavigationDestination(icon: Icon(Icons.directions_walk), label: 'Session'),
            NavigationDestination(icon: Icon(Icons.emoji_events), label: 'Classement'),
          ],
        ),
      );
}
```

- [ ] **Step 6: Vérifier** — `flutter analyze` (0 issue) et `flutter build apk --debug` (succès).

- [ ] **Step 7: CI `.github/workflows/ci.yml`**

```yaml
name: ci
on: [push, pull_request]
jobs:
  flutter:
    runs-on: ubuntu-latest
    defaults: {run: {working-directory: app}}
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with: {channel: stable, cache: true}
      - run: flutter pub get
      - run: flutter analyze
      - run: flutter test
  leaderboard:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: {python-version: "3.12"}
      - run: pip install -r server/leaderboard/requirements.txt
      - run: python -m pytest server/leaderboard -v
```

- [ ] **Step 8: Repo GitHub + push**

```bash
git add -A && git commit -m "feat: flutter app scaffold, shell navigation, CI"
gh repo create igapon/randomwalk --private --source . --push
sleep 10
gh run watch --repo igapon/randomwalk --exit-status \
  "$(gh run list --repo igapon/randomwalk --workflow=ci.yml -L1 --json databaseId -q '.[0].databaseId')"
```

---

### Task 5: Carte MapLibre + position

**Files:**
- Create: `app/lib/map/map_screen.dart`
- Modify: `app/lib/main.dart` (onglet 0 → `MapScreen`)

**Interfaces:**
- Consumes: `maplibre_gl` (`MapLibreMap`, `MapLibreMapController`), `geolocator`.
- Produces: `class MapScreen extends ConsumerStatefulWidget` avec un contrôleur exposé en interne ; la Task 8 la modifiera (long-press → routage). Constante `const kMapStyleUrl = 'https://tiles.openfreemap.org/styles/liberty';`.

- [ ] **Step 1: Implémenter `MapScreen`**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

const kMapStyleUrl = 'https://tiles.openfreemap.org/styles/liberty';
const kMapAttribution = 'OpenFreeMap © OpenMapTiles, Data from OpenStreetMap';

class MapScreen extends ConsumerStatefulWidget {
  const MapScreen({super.key});
  @override
  ConsumerState<MapScreen> createState() => MapScreenState();
}

class MapScreenState extends ConsumerState<MapScreen> {
  MapLibreMapController? controller;

  Future<void> _centerOnUser() async {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Localisation refusée — activez-la dans les réglages.')));
      }
      return;
    }
    final pos = await Geolocator.getCurrentPosition();
    await controller?.animateCamera(CameraUpdate.newLatLngZoom(
        LatLng(pos.latitude, pos.longitude), 15));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: MapLibreMap(
          styleString: kMapStyleUrl,
          initialCameraPosition:
              const CameraPosition(target: LatLng(46.52, 6.63), zoom: 11),
          myLocationEnabled: true,
          myLocationTrackingMode: MyLocationTrackingMode.none,
          attributionButtonPosition: AttributionButtonPosition.bottomLeft,
          onMapCreated: (c) => controller = c,
        ),
        floatingActionButton: FloatingActionButton(
          onPressed: _centerOnUser,
          child: const Icon(Icons.my_location),
        ),
      );
}
```
Dans `main.dart`, remplacer le placeholder de l'onglet 0 par `const MapScreen()` (et passer `_screens` non-const).

- [ ] **Step 2: Vérifier sur device/émulateur** — `flutter run` : la carte OpenFreeMap s'affiche, le bouton centre sur la position (accepter la permission). Si aucun device : `flutter build apk --debug` + noter la vérification manuelle en attente.

- [ ] **Step 3: Commit** — `git commit -am "feat: maplibre map screen with user location"`

---

### Task 6: Maths de grille Valhalla (`grid.dart`, TDD pur Dart)

**Files:**
- Create: `app/lib/valhalla/grid.dart`
- Create: `app/test/valhalla/grid_test.dart`

**Interfaces:**
- Produces (consommé par Task 7) :
  - `class TileId { final int level; final int index; String get path; }`
  - `TileId.fromLatLon(int level, double lat, double lon)`
  - `List<TileId> tilesCoveringCircle(int level, double lat, double lon, double radiusKm)`

- [ ] **Step 1: Écrire les tests**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/valhalla/grid.dart';

void main() {
  // Point de référence de la doc Valhalla (« why tiles ») :
  // (41.413203, -73.623787) → tuile niveau 2 id 756425.
  const lat = 41.413203, lon = -73.623787;

  test('level sizes and ids match the valhalla scheme', () {
    expect(TileId.fromLatLon(2, lat, lon).index, 756425);
    expect(TileId.fromLatLon(1, lat, lon).index, 47266);
    expect(TileId.fromLatLon(0, lat, lon).index, 2906);
  });

  test('file paths are zero-padded in groups of three', () {
    expect(TileId.fromLatLon(2, lat, lon).path, '2/000/756/425.gph');
    expect(TileId.fromLatLon(1, lat, lon).path, '1/047/266.gph');
    expect(TileId.fromLatLon(0, lat, lon).path, '0/002/906.gph');
  });

  test('covering circle includes neighbors across tile edges', () {
    // 46.52,6.63 (Lausanne), rayon 45 km → plusieurs tuiles L2, incluant celle du centre
    final tiles = tilesCoveringCircle(2, 46.52, 6.63, 45);
    expect(tiles, contains(TileId.fromLatLon(2, 46.52, 6.63)));
    expect(tiles.length, inInclusiveRange(9, 36));
    // pas de doublons
    expect(tiles.toSet().length, tiles.length);
  });

  test('zero radius yields exactly the containing tile', () {
    expect(tilesCoveringCircle(2, 46.52, 6.63, 0), hasLength(1));
  });
}
```

- [ ] **Step 2: FAIL** — `flutter test test/valhalla/grid_test.dart` → échec (fichier absent).

- [ ] **Step 3: Implémenter `grid.dart`**

```dart
import 'dart:math' as math;

/// Valhalla tile grid: level 0 = 4°, 1 = 1°, 2 = 0.25°.
/// Tiles are row-major from (-90, -180). File paths group the zero-padded
/// id into 3-digit segments, e.g. level 2 id 756425 -> "2/000/756/425.gph".
class TileId {
  final int level;
  final int index;
  const TileId(this.level, this.index);

  static const List<double> sizes = [4.0, 1.0, 0.25];
  static const List<int> pathDigits = [6, 6, 9];

  static int columns(int level) => (360 / sizes[level]).round();

  factory TileId.fromLatLon(int level, double lat, double lon) {
    final size = sizes[level];
    final row = ((lat + 90) / size).floor();
    final col = ((lon + 180) / size).floor();
    return TileId(level, row * columns(level) + col);
  }

  String get path {
    final s = index.toString().padLeft(pathDigits[level], '0');
    final groups = <String>[
      for (var i = 0; i < s.length; i += 3) s.substring(i, i + 3)
    ];
    return '$level/${groups.join('/')}.gph';
  }

  @override
  bool operator ==(Object other) =>
      other is TileId && other.level == level && other.index == index;
  @override
  int get hashCode => Object.hash(level, index);
  @override
  String toString() => 'TileId($level, $index)';
}

const _kmPerDegLat = 111.32;

List<TileId> tilesCoveringCircle(
    int level, double lat, double lon, double radiusKm) {
  final size = TileId.sizes[level];
  final dLat = radiusKm / _kmPerDegLat;
  final cosLat = math.cos(lat * math.pi / 180).abs().clamp(0.01, 1.0);
  final dLon = radiusKm / (_kmPerDegLat * cosLat);
  final rowMin = (((lat - dLat).clamp(-90.0, 89.999) + 90) / size).floor();
  final rowMax = (((lat + dLat).clamp(-90.0, 89.999) + 90) / size).floor();
  final colMin = (((lon - dLon).clamp(-180.0, 179.999) + 180) / size).floor();
  final colMax = (((lon + dLon).clamp(-180.0, 179.999) + 180) / size).floor();
  return [
    for (var r = rowMin; r <= rowMax; r++)
      for (var c = colMin; c <= colMax; c++)
        TileId(level, r * TileId.columns(level) + c)
  ];
}
```

- [ ] **Step 4: PASS** — `flutter test test/valhalla/grid_test.dart` → 4 PASS. ⚠️ Si le test des ids de référence échoue : NE PAS bidouiller les constantes pour faire passer — vérifier la formule contre la doc Valhalla (`docs/tiles.md` du repo valhalla) et contre une tuile réelle du manifeste de la Task 1 (les chemins du manifeste sont la vérité terrain).

- [ ] **Step 5: Commit** — `git commit -am "feat: valhalla tile grid math"`

---

### Task 7: Téléchargement de couverture (`coverage`, TDD)

**Files:**
- Create: `app/lib/coverage/manifest.dart`
- Create: `app/lib/coverage/coverage_repository.dart`
- Create: `app/test/coverage/coverage_repository_test.dart`

**Interfaces:**
- Consumes: `grid.dart` (Task 6), contrat manifeste (Task 1).
- Produces (consommé par Task 8) :
  - `class TileManifest { String datasetVersion; String valhallaVersion; Map<String, TileAsset> tiles; }` / `class TileAsset { String asset; int bytes; String sha256; }`
  - `class CoverageRepository` :
    - `CoverageRepository({required Directory root, required http.Client client})`
    - `Future<CoverageResult> ensureCoverage(double lat, double lon, {void Function(int done, int total)? onProgress})` — télécharge les tuiles manquantes (L2 rayon 45 km, L1 rayon 120 km, L0 rayon 400 km ∩ manifeste), vérifie sha256, écrit atomiquement, purge LRU au-delà de 300 Mo.
    - `CoverageResult { String datasetVersion; String tileDirPath; int downloaded; int total; }` — `tileDirPath` pointe sur `<root>/<datasetVersion>/` (arborescence Valhalla standard).

- [ ] **Step 1: Écrire les tests** (MockClient de `package:http/testing.dart`, `Directory.systemTemp`)

```dart
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:randomwalk/coverage/coverage_repository.dart';
import 'package:randomwalk/valhalla/grid.dart';

void main() {
  const lat = 46.52, lon = 6.63;
  final tileBytes = List<int>.generate(64, (i) => i);
  final tileSha = sha256.convert(tileBytes).toString();

  Map<String, dynamic> manifestFor(Iterable<String> paths) => {
        'dataset_version': 'V1',
        'valhalla_version': '3.6.2',
        'region': 'test',
        'tiles': {
          for (final p in paths)
            p: {
              'asset': p.replaceAll('/', '_'),
              'bytes': tileBytes.length,
              'sha256': tileSha,
            }
        },
      };

  // Manifeste ne contenant QUE les tuiles L2/L1/L0 du point de test :
  final knownPaths = [
    TileId.fromLatLon(2, lat, lon).path,
    TileId.fromLatLon(1, lat, lon).path,
    TileId.fromLatLon(0, lat, lon).path,
  ];

  MockClient client({bool corrupt = false}) => MockClient((req) async {
        if (req.url.path.endsWith('manifest.json')) {
          return http.Response(jsonEncode(manifestFor(knownPaths)), 200);
        }
        if (req.url.path.endsWith('.gph')) {
          return http.Response.bytes(
              corrupt ? [0, 0, 0] : tileBytes, 200);
        }
        return http.Response('not found', 404);
      });

  test('downloads needed tiles present in manifest, verifies sha, reports paths',
      () async {
    final root = await Directory.systemTemp.createTemp('cov');
    final repo = CoverageRepository(root: root, client: client());
    final res = await repo.ensureCoverage(lat, lon);
    expect(res.datasetVersion, 'V1');
    expect(res.downloaded, knownPaths.length);
    for (final p in knownPaths) {
      expect(File('${res.tileDirPath}/$p').existsSync(), isTrue);
    }
  });

  test('second call downloads nothing (idempotent)', () async {
    final root = await Directory.systemTemp.createTemp('cov');
    final repo = CoverageRepository(root: root, client: client());
    await repo.ensureCoverage(lat, lon);
    final res2 = await repo.ensureCoverage(lat, lon);
    expect(res2.downloaded, 0);
  });

  test('rejects corrupted tile (sha mismatch) and leaves no file', () async {
    final root = await Directory.systemTemp.createTemp('cov');
    final repo = CoverageRepository(root: root, client: client(corrupt: true));
    final res = await repo.ensureCoverage(lat, lon);
    expect(res.downloaded, 0);
    expect(res.failed, knownPaths.length);
    for (final p in knownPaths) {
      expect(File('${res.tileDirPath}/$p').existsSync(), isFalse);
    }
  });

  test('new dataset version gets its own directory', () async {
    final root = await Directory.systemTemp.createTemp('cov');
    var version = 'V1';
    final c = MockClient((req) async {
      if (req.url.path.endsWith('manifest.json')) {
        final m = manifestFor(knownPaths)..['dataset_version'] = version;
        return http.Response(jsonEncode(m), 200);
      }
      return http.Response.bytes(tileBytes, 200);
    });
    final repo = CoverageRepository(root: root, client: c);
    final r1 = await repo.ensureCoverage(lat, lon);
    version = 'V2';
    final r2 = await repo.ensureCoverage(lat, lon);
    expect(r1.tileDirPath, isNot(r2.tileDirPath));
  });
}
```

- [ ] **Step 2: FAIL** — `flutter test test/coverage -v`.

- [ ] **Step 3: Implémenter**

`manifest.dart` :
```dart
class TileAsset {
  final String asset;
  final int bytes;
  final String sha256;
  const TileAsset({required this.asset, required this.bytes, required this.sha256});
  factory TileAsset.fromJson(Map<String, dynamic> j) => TileAsset(
      asset: j['asset'] as String,
      bytes: j['bytes'] as int,
      sha256: j['sha256'] as String);
}

class TileManifest {
  final String datasetVersion;
  final String valhallaVersion;
  final Map<String, TileAsset> tiles;
  const TileManifest(
      {required this.datasetVersion,
      required this.valhallaVersion,
      required this.tiles});
  factory TileManifest.fromJson(Map<String, dynamic> j) => TileManifest(
        datasetVersion: j['dataset_version'] as String,
        valhallaVersion: j['valhalla_version'] as String,
        tiles: (j['tiles'] as Map<String, dynamic>).map(
            (k, v) => MapEntry(k, TileAsset.fromJson(v as Map<String, dynamic>))),
      );
}
```

`coverage_repository.dart` :
```dart
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import '../valhalla/grid.dart';
import 'manifest.dart';

class CoverageConfig {
  static const manifestUrl =
      'https://github.com/igapon/randomwalk-tiles/releases/latest/download/manifest.json';
  static String assetUrl(String version, String asset) =>
      'https://github.com/igapon/randomwalk-tiles/releases/download/$version/$asset';
  static const radiiKmByLevel = <int, double>{2: 45, 1: 120, 0: 400};
  static const maxCacheBytes = 300 * 1024 * 1024;
}

class CoverageResult {
  final String datasetVersion;
  final String tileDirPath;
  final int downloaded;
  final int failed;
  final int total;
  const CoverageResult(
      {required this.datasetVersion,
      required this.tileDirPath,
      required this.downloaded,
      required this.failed,
      required this.total});
}

class CoverageRepository {
  final Directory root;
  final http.Client client;
  CoverageRepository({required this.root, required this.client});

  Future<TileManifest> _fetchManifest() async {
    final resp = await client.get(Uri.parse(CoverageConfig.manifestUrl));
    if (resp.statusCode != 200) {
      throw HttpException('manifest: HTTP ${resp.statusCode}');
    }
    return TileManifest.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  List<String> neededPaths(double lat, double lon) => [
        for (final e in CoverageConfig.radiiKmByLevel.entries)
          for (final t in tilesCoveringCircle(e.key, lat, lon, e.value)) t.path
      ];

  Future<CoverageResult> ensureCoverage(double lat, double lon,
      {void Function(int done, int total)? onProgress}) async {
    final manifest = await _fetchManifest();
    final tileDir = Directory('${root.path}/${manifest.datasetVersion}');
    await tileDir.create(recursive: true);
    final wanted = neededPaths(lat, lon)
        .where(manifest.tiles.containsKey)
        .toList();
    var downloaded = 0, failed = 0, done = 0;
    for (final path in wanted) {
      final file = File('${tileDir.path}/$path');
      if (!file.existsSync()) {
        final ok = await _download(manifest, path, file);
        ok ? downloaded++ : failed++;
      }
      onProgress?.call(++done, wanted.length);
      await _touch(tileDir, path);
    }
    await _purgeLru(tileDir);
    return CoverageResult(
        datasetVersion: manifest.datasetVersion,
        tileDirPath: tileDir.path,
        downloaded: downloaded,
        failed: failed,
        total: wanted.length);
  }

  Future<bool> _download(TileManifest m, String path, File dest) async {
    final asset = m.tiles[path]!;
    final url = CoverageConfig.assetUrl(m.datasetVersion, asset.asset);
    final resp = await client.get(Uri.parse(url));
    if (resp.statusCode != 200 ||
        sha256.convert(resp.bodyBytes).toString() != asset.sha256) {
      return false;
    }
    final tmp = File('${dest.path}.part');
    await tmp.create(recursive: true);
    await tmp.writeAsBytes(resp.bodyBytes, flush: true);
    await tmp.rename(dest.path);
    return true;
  }

  /// LRU index: JSON map tile path -> last-used epoch ms, stored next to tiles.
  Future<void> _touch(Directory tileDir, String path) async {
    final f = File('${tileDir.path}/.lru.json');
    final map = f.existsSync()
        ? (jsonDecode(await f.readAsString()) as Map<String, dynamic>)
        : <String, dynamic>{};
    map[path] = DateTime.now().millisecondsSinceEpoch;
    await f.writeAsString(jsonEncode(map), flush: true);
  }

  Future<void> _purgeLru(Directory tileDir) async {
    final files = tileDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.gph'))
        .toList();
    var totalBytes = files.fold<int>(0, (s, f) => s + f.lengthSync());
    if (totalBytes <= CoverageConfig.maxCacheBytes) return;
    final lruFile = File('${tileDir.path}/.lru.json');
    final lru = lruFile.existsSync()
        ? (jsonDecode(await lruFile.readAsString()) as Map<String, dynamic>)
        : <String, dynamic>{};
    int lastUsed(File f) {
      final rel = f.path
          .substring(tileDir.path.length + 1)
          .replaceAll('\\', '/');
      return (lru[rel] as int?) ?? 0;
    }
    files.sort((a, b) => lastUsed(a).compareTo(lastUsed(b)));
    for (final f in files) {
      if (totalBytes <= CoverageConfig.maxCacheBytes) break;
      totalBytes -= f.lengthSync();
      f.deleteSync();
    }
  }
}
```

- [ ] **Step 4: PASS** — `flutter test test/coverage -v` → 4 PASS. Ajuster le test `failed` si l'API `CoverageResult` a évolué — le contrat des Interfaces prime.

- [ ] **Step 5: Commit** — `git commit -am "feat: coverage repository (manifest, sha-verified downloads, LRU)"`

---

### Task 8: Moteur Valhalla embarqué (Kotlin + MethodChannel + modèles Dart)

**Files:**
- Create: `app/android/app/src/main/kotlin/fr/lmqc/randomwalk/ValhallaChannel.kt`
- Modify: `app/android/app/src/main/kotlin/fr/lmqc/randomwalk/MainActivity.kt`
- Modify: `app/android/app/build.gradle.kts` (dépendance AAR)
- Create: `app/lib/valhalla/models.dart`, `app/lib/valhalla/engine.dart`, `app/lib/valhalla/engine_channel.dart`
- Create: `app/assets/valhalla_config.json`
- Create: `app/test/valhalla/models_test.dart`
- Create: `app/tool/build_fixture_tiles.sh`, `app/integration_test/routing_test.dart`, fixture `app/integration_test/fixtures/monaco_tiles/` (arborescence `.gph` committée)

**Interfaces:**
- Consumes: `CoverageResult.tileDirPath` (Task 7).
- Produces (consommé par Task 9) :
  - `enum RoutingProfile { walk, bike }`
  - `class RouteRequest { final double fromLat, fromLon, toLat, toLon; final RoutingProfile profile; }`
  - `class RouteResult { final List<(double, double)> shape; final double distanceKm; final Duration duration; final List<Maneuver> maneuvers; }` / `class Maneuver { final String instruction; final double lengthKm; final int beginShapeIndex; }`
  - `abstract class RoutingEngine { Future<void> init(String tileDirPath); Future<RouteResult> route(RouteRequest request); }` + `class ChannelRoutingEngine implements RoutingEngine`
  - MethodChannel `randomwalk/valhalla`, méthodes `init {configJson}` et `route {request}` (JSON strings).

- [ ] **Step 1: Inspecter l'API réelle de l'AAR (point de vérité)**

```powershell
cd $env:TEMP
curl.exe -fLO https://repo1.maven.org/maven2/io/github/rallista/valhalla-mobile/0.6.3/valhalla-mobile-0.6.3.aar
tar -xf valhalla-mobile-0.6.3.aar classes.jar; tar -tf valhalla-mobile-0.6.3.aar
# lister l'API publique :
& "$env:JAVA_HOME\bin\jar.exe" tf classes.jar | Select-String "class"
```
Noter les noms exacts (classe d'entrée type `com.valhalla.valhalla.Valhalla` / `ValhallaKotlin`, signatures `route(String): String`, mécanisme de config). **Adapter les noms dans le code Kotlin des étapes suivantes** — le squelette ci-dessous suppose `com.valhalla.valhalla.Valhalla(configJson: String)` avec `fun route(request: String): String` ; seul le nom peut changer, le pattern JSON-in/JSON-out est garanti par l'architecture actor de Valhalla.

- [ ] **Step 2: Dépendance Gradle** — `app/android/app/build.gradle.kts` :

```kotlin
dependencies {
    implementation("io.github.rallista:valhalla-mobile:0.6.3")
}
```
(mavenCentral est déjà dans les repos par défaut Flutter ; vérifier `settings.gradle.kts` sinon l'ajouter.) `flutter build apk --debug` doit toujours passer.

- [ ] **Step 3: `ValhallaChannel.kt` + branchement MainActivity**

```kotlin
package fr.lmqc.randomwalk

import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class ValhallaChannel {
    private var actor: com.valhalla.valhalla.Valhalla? = null
    private val executor = Executors.newSingleThreadExecutor()

    fun register(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "randomwalk/valhalla")
            .setMethodCallHandler { call, result ->
                val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
                fun reply(block: () -> String) = executor.execute {
                    try {
                        val out = block()
                        mainHandler.post { result.success(out) }
                    } catch (t: Throwable) {
                        mainHandler.post {
                            result.error("VALHALLA", t.message ?: t.javaClass.name, null)
                        }
                    }
                }
                when (call.method) {
                    "init" -> {
                        val config = call.argument<String>("configJson")!!
                        reply { actor = com.valhalla.valhalla.Valhalla(config); "ok" }
                    }
                    "route" -> {
                        val request = call.argument<String>("request")!!
                        reply {
                            actor?.route(request)
                                ?: throw IllegalStateException("engine not initialized")
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
```

`MainActivity.kt` :
```kotlin
package fr.lmqc.randomwalk

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        ValhallaChannel().register(flutterEngine)
    }
}
```

- [ ] **Step 4: Config runtime `assets/valhalla_config.json`** — extraire le `default.json` de valhalla-mobile (dans l'AAR : `tar -xf valhalla-mobile-0.6.3.aar` puis chercher `default.json` dans les resources du classes.jar) et le committer tel quel comme template ; `mjolnir.tile_dir` sera patché au runtime côté Dart. S'il est introuvable dans l'AAR, générer la config complète avec `docker run --rm ghcr.io/valhalla/valhalla:3.6.2 valhalla_build_config --mjolnir-tile-dir /placeholder` (sur le VPS) et committer la sortie.

- [ ] **Step 5: Tests des modèles Dart (polyline6 + parsing réponse)**

`app/test/valhalla/models_test.dart` :
```dart
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/valhalla/models.dart';

void main() {
  test('decodePolyline6 round-trips a known point pair', () {
    // encodage polyline précision 6 de [(46.52, 6.63), (46.521, 6.631)]
    final pts = decodePolyline6(encodePolyline6ForTest([
      (46.52, 6.63),
      (46.521, 6.631),
    ]));
    expect(pts.length, 2);
    expect(pts[0].$1, closeTo(46.52, 1e-6));
    expect(pts[1].$2, closeTo(6.631, 1e-6));
  });

  test('RouteResult parses a valhalla trip json', () {
    final j = jsonDecode('''
    {"trip":{"summary":{"length":1.234,"time":900},
      "legs":[{"shape":"${encodePolyline6ForTest([(46.52, 6.63), (46.53, 6.64)])}",
        "maneuvers":[{"instruction":"Marchez vers le nord.","length":1.234,"begin_shape_index":0}]}]}}
    ''') as Map<String, dynamic>;
    final r = RouteResult.fromValhallaJson(j);
    expect(r.distanceKm, closeTo(1.234, 1e-9));
    expect(r.duration, const Duration(seconds: 900));
    expect(r.shape.first.$1, closeTo(46.52, 1e-6));
    expect(r.maneuvers.single.instruction, contains('nord'));
  });
}
```

- [ ] **Step 6: FAIL puis implémenter `models.dart`**

```dart
import 'dart:convert' show jsonEncode; // used by RouteRequest.toValhallaJson

enum RoutingProfile { walk, bike }

class RouteRequest {
  final double fromLat, fromLon, toLat, toLon;
  final RoutingProfile profile;
  const RouteRequest(
      {required this.fromLat,
      required this.fromLon,
      required this.toLat,
      required this.toLon,
      required this.profile});

  String toValhallaJson() => jsonEncode({
        'locations': [
          {'lat': fromLat, 'lon': fromLon, 'type': 'break'},
          {'lat': toLat, 'lon': toLon, 'type': 'break'},
        ],
        'costing': profile == RoutingProfile.bike ? 'bicycle' : 'pedestrian',
        'directions_options': {'units': 'kilometers', 'language': 'fr-FR'},
      });
}

class Maneuver {
  final String instruction;
  final double lengthKm;
  final int beginShapeIndex;
  const Maneuver(
      {required this.instruction,
      required this.lengthKm,
      required this.beginShapeIndex});
}

class RouteResult {
  final List<(double, double)> shape; // (lat, lon)
  final double distanceKm;
  final Duration duration;
  final List<Maneuver> maneuvers;
  const RouteResult(
      {required this.shape,
      required this.distanceKm,
      required this.duration,
      required this.maneuvers});

  factory RouteResult.fromValhallaJson(Map<String, dynamic> j) {
    final trip = j['trip'] as Map<String, dynamic>;
    final summary = trip['summary'] as Map<String, dynamic>;
    final legs = trip['legs'] as List<dynamic>;
    final shape = <(double, double)>[];
    final maneuvers = <Maneuver>[];
    for (final legRaw in legs) {
      final leg = legRaw as Map<String, dynamic>;
      final offset = shape.length;
      shape.addAll(decodePolyline6(leg['shape'] as String));
      for (final mRaw in (leg['maneuvers'] as List<dynamic>? ?? [])) {
        final m = mRaw as Map<String, dynamic>;
        maneuvers.add(Maneuver(
            instruction: m['instruction'] as String? ?? '',
            lengthKm: (m['length'] as num).toDouble(),
            beginShapeIndex: offset + (m['begin_shape_index'] as int)));
      }
    }
    return RouteResult(
        shape: shape,
        distanceKm: (summary['length'] as num).toDouble(),
        duration: Duration(seconds: (summary['time'] as num).round()),
        maneuvers: maneuvers);
  }
}

/// Valhalla encodes shapes as Google polylines with 1e-6 precision.
List<(double, double)> decodePolyline6(String encoded) {
  final points = <(double, double)>[];
  var index = 0, lat = 0, lon = 0;
  int nextDelta() {
    var result = 0, shift = 0, b = 0x20;
    while (b >= 0x20) {
      b = encoded.codeUnitAt(index++) - 63;
      result |= (b & 0x1f) << shift;
      shift += 5;
    }
    return (result & 1) != 0 ? ~(result >> 1) : (result >> 1);
  }
  while (index < encoded.length) {
    lat += nextDelta();
    lon += nextDelta();
    points.add((lat / 1e6, lon / 1e6));
  }
  return points;
}

/// Test helper (encoder) — kept here so tests don't duplicate the format.
String encodePolyline6ForTest(List<(double, double)> pts) {
  final sb = StringBuffer();
  var lastLat = 0, lastLon = 0;
  void emit(int v) {
    var value = v < 0 ? ~(v << 1) : (v << 1);
    while (value >= 0x20) {
      sb.writeCharCode((0x20 | (value & 0x1f)) + 63);
      value >>= 5;
    }
    sb.writeCharCode(value + 63);
  }
  for (final (la, lo) in pts) {
    final ila = (la * 1e6).round(), ilo = (lo * 1e6).round();
    emit(ila - lastLat);
    emit(ilo - lastLon);
    lastLat = ila;
    lastLon = ilo;
  }
  return sb.toString();
}
```
`flutter test test/valhalla/models_test.dart` → PASS.

- [ ] **Step 7: `engine.dart` + `engine_channel.dart`**

```dart
// engine.dart
import 'models.dart';

abstract class RoutingEngine {
  Future<void> init(String tileDirPath);
  Future<RouteResult> route(RouteRequest request);
}

class RoutingException implements Exception {
  final String message;
  const RoutingException(this.message);
  @override
  String toString() => 'RoutingException: $message';
}
```

```dart
// engine_channel.dart
import 'dart:convert';
import 'package:flutter/services.dart';
import 'engine.dart';
import 'models.dart';

class ChannelRoutingEngine implements RoutingEngine {
  static const _channel = MethodChannel('randomwalk/valhalla');

  @override
  Future<void> init(String tileDirPath) async {
    final template = await rootBundle.loadString('assets/valhalla_config.json');
    final config = jsonDecode(template) as Map<String, dynamic>;
    (config['mjolnir'] as Map<String, dynamic>)['tile_dir'] = tileDirPath;
    (config['mjolnir'] as Map<String, dynamic>).remove('tile_extract');
    try {
      await _channel.invokeMethod<String>('init', {'configJson': jsonEncode(config)});
    } on PlatformException catch (e) {
      throw RoutingException(e.message ?? 'init failed');
    }
  }

  @override
  Future<RouteResult> route(RouteRequest request) async {
    try {
      final resp = await _channel
          .invokeMethod<String>('route', {'request': request.toValhallaJson()});
      return RouteResult.fromValhallaJson(
          jsonDecode(resp!) as Map<String, dynamic>);
    } on PlatformException catch (e) {
      throw RoutingException(e.message ?? 'route failed');
    }
  }
}
```

- [ ] **Step 8: Fixture Monaco + test d'intégration émulateur**

`app/tool/build_fixture_tiles.sh` (s'exécute sur le VPS : `ssh dev.lmqc.fr bash -s < app/tool/build_fixture_tiles.sh`, puis `scp -r` du résultat vers `app/integration_test/fixtures/monaco_tiles/`) :
```bash
#!/usr/bin/env bash
set -euo pipefail
WORK=/tmp/rw-fixture
mkdir -p "$WORK/valhalla_tiles" && cd "$WORK"
curl -fL -o monaco.osm.pbf https://download.geofabrik.de/europe/monaco-latest.osm.pbf
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
```
Puis déclarer dans `pubspec.yaml` : `- integration_test/fixtures/monaco_tiles/` (un seul dossier plat).

`app/integration_test/routing_test.dart` :
```dart
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:randomwalk/valhalla/engine_channel.dart';
import 'package:randomwalk/valhalla/models.dart';

// La fixture est copiée dans l'app au moment du test via les assets ? Non :
// les .gph sont copiés depuis les assets déclarés ci-dessous vers un dossier
// réel, car valhalla lit le filesystem. Déclarer dans pubspec.yaml :
//   assets:
//     - integration_test/fixtures/monaco_tiles/   (et sous-dossiers .gph)
// puis lister via AssetManifest.

Future<String> materializeFixture() async {
  final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
  final tileAssets = manifest
      .listAssets()
      .where((a) =>
          a.startsWith('integration_test/fixtures/monaco_tiles/') &&
          a.endsWith('.gph'))
      .toList();
  expect(tileAssets, isNotEmpty, reason: 'fixture tiles must be bundled');
  final dir = await getApplicationSupportDirectory();
  final root = Directory('${dir.path}/fixture_tiles');
  for (final a in tileAssets) {
    // Asset names are flattened ("2_000_756_425.gph") -> valhalla tree paths.
    final flat = a.substring('integration_test/fixtures/monaco_tiles/'.length);
    final rel = flat.replaceAll('_', '/');
    final f = File('${root.path}/$rel');
    await f.create(recursive: true);
    final data = await rootBundle.load(a);
    await f.writeAsBytes(data.buffer.asUint8List(), flush: true);
  }
  return root.path;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('pedestrian route across Monaco', (tester) async {
    final engine = ChannelRoutingEngine();
    await engine.init(await materializeFixture());
    final result = await engine.route(const RouteRequest(
        fromLat: 43.7396, fromLon: 7.4263, // gare de Monaco
        toLat: 43.7311, toLon: 7.4197, // vieille ville
        profile: RoutingProfile.walk));
    expect(result.distanceKm, greaterThan(0.3));
    expect(result.distanceKm, lessThan(5));
    expect(result.shape.length, greaterThan(10));
    expect(result.maneuvers, isNotEmpty);
  });
}
```
Exécution : `flutter test integration_test/routing_test.dart -d <device>` (émulateur ou téléphone branché). Attendu : PASS. C'est LE test qui valide toute la chaîne AAR/channel/config — ne pas déclarer la Task 8 finie sans l'avoir vu passer sur un device réel ou émulé.

- [ ] **Step 9: Commit** — `git add -A && git commit -m "feat: embedded valhalla routing engine (valhalla-mobile + method channel)"`

---

### Task 9: UI de routage A→B sur la carte + couverture automatique

**Files:**
- Modify: `app/lib/map/map_screen.dart`
- Create: `app/lib/map/route_controller.dart`
- Create: `app/test/map/route_controller_test.dart`

**Interfaces:**
- Consumes: `RoutingEngine`/`ChannelRoutingEngine`, `RouteRequest/RouteResult` (Task 8), `CoverageRepository` (Task 7), `MapScreenState.controller` (Task 5).
- Produces: `class RouteController extends AsyncNotifier` (Riverpod) orchestrant couverture→init→route ; providers `coverageRepositoryProvider`, `routingEngineProvider`, `routeControllerProvider`.

- [ ] **Step 1: Test du contrôleur (fake engine + fake coverage)**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/map/route_controller.dart';
import 'package:randomwalk/valhalla/engine.dart';
import 'package:randomwalk/valhalla/models.dart';

class FakeEngine implements RoutingEngine {
  String? initializedWith;
  RouteRequest? lastRequest;
  @override
  Future<void> init(String tileDirPath) async => initializedWith = tileDirPath;
  @override
  Future<RouteResult> route(RouteRequest request) async {
    lastRequest = request;
    return const RouteResult(
        shape: [(46.52, 6.63), (46.53, 6.64)],
        distanceKm: 2.5,
        duration: Duration(minutes: 30),
        maneuvers: []);
  }
}

void main() {
  test('plans coverage then route, reinitializes only on version change',
      () async {
    final engine = FakeEngine();
    var version = 'V1';
    final logic = RoutePlanner(
        engine: engine,
        ensureCoverage: (lat, lon) async =>
            (datasetVersion: version, tileDirPath: '/tiles/$version'));
    final r1 = await logic.plan(const RouteRequest(
        fromLat: 46.52, fromLon: 6.63, toLat: 46.53, toLon: 6.64,
        profile: RoutingProfile.walk));
    expect(r1.distanceKm, 2.5);
    expect(engine.initializedWith, '/tiles/V1');
    engine.initializedWith = null;
    await logic.plan(const RouteRequest(
        fromLat: 46.52, fromLon: 6.63, toLat: 46.53, toLon: 6.64,
        profile: RoutingProfile.bike));
    expect(engine.initializedWith, isNull); // même version → pas de re-init
    expect(engine.lastRequest!.profile, RoutingProfile.bike);
  });
}
```

- [ ] **Step 2: FAIL puis implémenter `route_controller.dart`**

```dart
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import '../coverage/coverage_repository.dart';
import '../valhalla/engine.dart';
import '../valhalla/engine_channel.dart';
import '../valhalla/models.dart';

typedef EnsureCoverage = Future<({String datasetVersion, String tileDirPath})>
    Function(double lat, double lon);

/// Pure orchestration, unit-testable: coverage -> (re)init -> route.
class RoutePlanner {
  final RoutingEngine engine;
  final EnsureCoverage ensureCoverage;
  String? _initializedVersion;
  RoutePlanner({required this.engine, required this.ensureCoverage});

  Future<RouteResult> plan(RouteRequest request) async {
    final cov = await ensureCoverage(request.fromLat, request.fromLon);
    if (cov.datasetVersion != _initializedVersion) {
      await engine.init(cov.tileDirPath);
      _initializedVersion = cov.datasetVersion;
    }
    return engine.route(request);
  }
}

final routingEngineProvider =
    Provider<RoutingEngine>((ref) => ChannelRoutingEngine());

final coverageRepositoryProvider = FutureProvider<CoverageRepository>((ref) async {
  final dir = await getApplicationSupportDirectory();
  return CoverageRepository(
      root: Directory('${dir.path}/tiles'), client: http.Client());
});

final routePlannerProvider = FutureProvider<RoutePlanner>((ref) async {
  final coverage = await ref.watch(coverageRepositoryProvider.future);
  return RoutePlanner(
      engine: ref.watch(routingEngineProvider),
      ensureCoverage: (lat, lon) async {
        final res = await coverage.ensureCoverage(lat, lon);
        return (datasetVersion: res.datasetVersion, tileDirPath: res.tileDirPath);
      });
});
```
`flutter test test/map -v` → PASS.

- [ ] **Step 3: Brancher l'UI dans `map_screen.dart`**

Ajouts : état `_from`/`_to` (long-press pose le départ puis l'arrivée, un 3e long-press repart de zéro), `SegmentedButton<RoutingProfile>` en haut, appel `planner.plan(...)` avec spinner, tracé via `controller.addLine(LineOptions(geometry: [...], lineColor: '#0D9488', lineWidth: 5))` (supprimer l'ancienne ligne d'abord : garder la référence `Line?`), bandeau résultat `X,X km · ~YY min`, `SnackBar` sur `RoutingException` (« Itinéraire impossible ici — zone non couverte ? ») et pendant le premier téléchargement de tuiles (progression `onProgress`). Marqueurs A/B via `addSymbol`/`addCircle`.

- [ ] **Step 4: Vérification device** — `flutter run` : long-press A, long-press B en Suisse → tracé + distance plausibles à pied et à vélo, écran avion APRÈS un premier téléchargement → le routage fonctionne encore (offline prouvé). Hors Suisse → message d'erreur propre.

- [ ] **Step 5: Commit** — `git commit -am "feat: A-to-B routing UI with automatic tile coverage"`

---

### Task 10: Enregistreur de session primitif (distance, TDD)

**Files:**
- Create: `app/lib/session/recorder.dart`
- Create: `app/lib/session/session_screen.dart`
- Create: `app/test/session/recorder_test.dart`
- Modify: `app/lib/main.dart` (onglet 1 → `SessionScreen`)

**Interfaces:**
- Consumes: `geolocator` (`Position`).
- Produces (consommé par Task 11) :
  - `class SessionRecorder { void add(GpsSample s); double get distanceKm; Duration elapsed(DateTime now); }`
  - `class GpsSample { final double lat, lon, accuracyM, speedMps; final DateTime time; }`
  - `class TotalDistanceStore { Future<double> addAndGetTotalKm(double km); Future<double> totalKm(); }` (persistance `shared_preferences`, clé `total_km`).

- [ ] **Step 1: Tests**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/session/recorder.dart';

GpsSample s(double lat, double lon,
        {double acc = 5, double speed = 1.4, int t = 0}) =>
    GpsSample(lat: lat, lon: lon, accuracyM: acc, speedMps: speed,
        time: DateTime(2026, 1, 1).add(Duration(seconds: t)));

void main() {
  test('accumulates haversine distance over a straight walk', () {
    final r = SessionRecorder();
    // ~111 m par pas de 0.001° de latitude
    for (var i = 0; i <= 10; i++) {
      r.add(s(46.5 + i * 0.001, 6.6, t: i * 60));
    }
    expect(r.distanceKm, closeTo(1.11, 0.02));
  });

  test('ignores inaccurate fixes', () {
    final r = SessionRecorder();
    r.add(s(46.5, 6.6));
    r.add(s(46.6, 6.6, acc: 80, t: 60)); // 11 km d'un coup, précision 80 m
    expect(r.distanceKm, 0);
  });

  test('ignores implausible jumps (over 90 km/h)', () {
    final r = SessionRecorder();
    r.add(s(46.5, 6.6));
    r.add(s(46.6, 6.6, t: 60)); // 11 km en 1 min = 660 km/h
    expect(r.distanceKm, 0);
  });

  test('ignores sub-3m jitter', () {
    final r = SessionRecorder();
    r.add(s(46.5, 6.6));
    r.add(s(46.500001, 6.6, t: 10));
    expect(r.distanceKm, 0);
  });
}
```

- [ ] **Step 2: FAIL puis implémenter `recorder.dart`**

```dart
import 'dart:math' as math;
import 'package:shared_preferences/shared_preferences.dart';

class GpsSample {
  final double lat, lon, accuracyM, speedMps;
  final DateTime time;
  const GpsSample(
      {required this.lat,
      required this.lon,
      required this.accuracyM,
      required this.speedMps,
      required this.time});
}

double haversineKm(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371.0;
  final dLat = (lat2 - lat1) * math.pi / 180;
  final dLon = (lon2 - lon1) * math.pi / 180;
  final a = math.pow(math.sin(dLat / 2), 2) +
      math.cos(lat1 * math.pi / 180) *
          math.cos(lat2 * math.pi / 180) *
          math.pow(math.sin(dLon / 2), 2);
  return 2 * r * math.asin(math.sqrt(a.toDouble()));
}

class SessionRecorder {
  static const _maxAccuracyM = 25.0;
  static const _minStepM = 3.0;
  static const _maxSpeedKmh = 90.0;

  GpsSample? _last;
  double _distanceKm = 0;
  DateTime? _startedAt;

  double get distanceKm => _distanceKm;
  Duration elapsed(DateTime now) =>
      _startedAt == null ? Duration.zero : now.difference(_startedAt!);

  void add(GpsSample sample) {
    if (sample.accuracyM > _maxAccuracyM) return;
    _startedAt ??= sample.time;
    final last = _last;
    if (last == null) {
      _last = sample;
      return;
    }
    final stepKm = haversineKm(last.lat, last.lon, sample.lat, sample.lon);
    final dtH = sample.time.difference(last.time).inMilliseconds / 3.6e6;
    if (stepKm * 1000 < _minStepM) return; // jitter: keep _last anchored
    if (dtH <= 0 || stepKm / dtH > _maxSpeedKmh) {
      _last = sample; // resync after an implausible jump
      return;
    }
    _distanceKm += stepKm;
    _last = sample;
  }
}

class TotalDistanceStore {
  static const _key = 'total_km';
  Future<double> totalKm() async =>
      (await SharedPreferences.getInstance()).getDouble(_key) ?? 0;
  Future<double> addAndGetTotalKm(double km) async {
    final prefs = await SharedPreferences.getInstance();
    final total = (prefs.getDouble(_key) ?? 0) + km;
    await prefs.setDouble(_key, total);
    return total;
  }
}
```
`flutter test test/session -v` → 4 PASS.

- [ ] **Step 3: `session_screen.dart`** — écran avec gros bouton Démarrer/Terminer, mode Marche/Vélo (`SegmentedButton`, purement informatif en M1), distance et durée en direct. Au démarrage : `Geolocator.getPositionStream(locationSettings: const LocationSettings(accuracy: LocationAccuracy.best, distanceFilter: 3))` → map en `GpsSample` → `recorder.add`. À l'arrêt : `TotalDistanceStore.addAndGetTotalKm(recorder.distanceKm)` puis déclencher la synchro leaderboard (Task 11 branche ce hook — laisser un callback `onSessionEnded(double totalKm)` injecté par le parent, no-op pour l'instant). Écran maintenu allumé pendant la session M1 (l'écran éteint arrive en M2 avec le foreground service) : pas de dépendance supplémentaire, juste documenter la limite dans l'UI (« Gardez l'app ouverte pendant la session (v1) »).

- [ ] **Step 4: Vérification device** — marcher ~200 m réels avec l'app ouverte : distance plausible (±20 %). Brancher l'onglet 1 dans `main.dart`.

- [ ] **Step 5: Commit** — `git commit -am "feat: primitive distance session recorder"`

---

### Task 11: Client leaderboard + écrans Classement et Réglages

**Files:**
- Create: `app/lib/settings/identity.dart`
- Create: `app/lib/leaderboard/repository.dart`
- Create: `app/lib/leaderboard/leaderboard_screen.dart`
- Create: `app/lib/settings/settings_screen.dart`
- Create: `app/test/leaderboard/repository_test.dart`
- Modify: `app/lib/main.dart` (onglet 2 → `LeaderboardScreen`, AppBar action → `SettingsScreen`), `app/lib/session/session_screen.dart` (hook `onSessionEnded` → submit)

**Interfaces:**
- Consumes: API `drive.lmqc.fr` (contrat Task 2), `TotalDistanceStore` (Task 10).
- Produces:
  - `class PlayerIdentity { final String userId; final String pseudo; }` + `class IdentityStore { Future<PlayerIdentity> get(); Future<void> setPseudo(String pseudo); }` (uuid v4 généré au premier accès, pseudo par défaut `Marcheur-XXXX`).
  - `abstract class LeaderboardRepository { Future<SubmitResult> submit(PlayerIdentity id, double totalKm); Future<LeaderboardData> fetch(String userId); }` + impl `HttpLeaderboardRepository(http.Client client, {String base = 'https://drive.lmqc.fr'})`.
  - `class LeaderboardEntry { String pseudo; double totalKm; int rank; }`, `class LeaderboardData { List<LeaderboardEntry> top; LeaderboardEntry? me; }`, `class SubmitResult { int rank; double totalKm; }`.

- [ ] **Step 1: Tests du repository (MockClient)**

```dart
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:randomwalk/leaderboard/repository.dart';
import 'package:randomwalk/settings/identity.dart';

void main() {
  test('submit posts identity and km, parses rank', () async {
    late http.Request captured;
    final client = MockClient((req) async {
      captured = req as http.Request;
      return http.Response(jsonEncode({'rank': 3, 'total_km': 42.0}), 200);
    });
    final repo = HttpLeaderboardRepository(client, base: 'https://x.test');
    final res = await repo.submit(
        const PlayerIdentity(userId: 'u-12345678', pseudo: 'iaro'), 42.0);
    expect(captured.url.toString(), 'https://x.test/v1/score');
    expect(jsonDecode(captured.body)['pseudo'], 'iaro');
    expect(res.rank, 3);
  });

  test('fetch parses top and me', () async {
    final client = MockClient((req) async => http.Response(
        jsonEncode({
          'top': [
            {'pseudo': 'a', 'total_km': 10.0, 'rank': 1}
          ],
          'me': {'pseudo': 'iaro', 'total_km': 5.0, 'rank': 2}
        }),
        200));
    final repo = HttpLeaderboardRepository(client, base: 'https://x.test');
    final data = await repo.fetch('u-12345678');
    expect(data.top.single.pseudo, 'a');
    expect(data.me!.rank, 2);
  });

  test('fetch surfaces http errors as LeaderboardException', () async {
    final repo = HttpLeaderboardRepository(
        MockClient((_) async => http.Response('boom', 500)),
        base: 'https://x.test');
    expect(() => repo.fetch('u-12345678'),
        throwsA(isA<LeaderboardException>()));
  });
}
```

- [ ] **Step 2: FAIL puis implémenter**

`identity.dart` :
```dart
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class PlayerIdentity {
  final String userId;
  final String pseudo;
  const PlayerIdentity({required this.userId, required this.pseudo});
}

class IdentityStore {
  static const _idKey = 'player_id', _pseudoKey = 'player_pseudo';

  Future<PlayerIdentity> get() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_idKey);
    if (id == null) {
      id = const Uuid().v4();
      await prefs.setString(_idKey, id);
    }
    var pseudo = prefs.getString(_pseudoKey);
    if (pseudo == null) {
      pseudo = 'Marcheur-${id.substring(0, 4).toUpperCase()}';
      await prefs.setString(_pseudoKey, pseudo);
    }
    return PlayerIdentity(userId: id, pseudo: pseudo);
  }

  Future<void> setPseudo(String pseudo) async {
    final trimmed = pseudo.trim();
    if (trimmed.isEmpty || trimmed.length > 24) {
      throw ArgumentError('pseudo must be 1-24 chars');
    }
    await (await SharedPreferences.getInstance())
        .setString(_pseudoKey, trimmed);
  }
}
```

`repository.dart` :
```dart
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../settings/identity.dart';

class LeaderboardException implements Exception {
  final String message;
  const LeaderboardException(this.message);
}

class LeaderboardEntry {
  final String pseudo;
  final double totalKm;
  final int rank;
  const LeaderboardEntry(
      {required this.pseudo, required this.totalKm, required this.rank});
  factory LeaderboardEntry.fromJson(Map<String, dynamic> j) => LeaderboardEntry(
      pseudo: j['pseudo'] as String,
      totalKm: (j['total_km'] as num).toDouble(),
      rank: j['rank'] as int);
}

class LeaderboardData {
  final List<LeaderboardEntry> top;
  final LeaderboardEntry? me;
  const LeaderboardData({required this.top, required this.me});
}

class SubmitResult {
  final int rank;
  final double totalKm;
  const SubmitResult({required this.rank, required this.totalKm});
}

abstract class LeaderboardRepository {
  Future<SubmitResult> submit(PlayerIdentity id, double totalKm);
  Future<LeaderboardData> fetch(String userId);
}

class HttpLeaderboardRepository implements LeaderboardRepository {
  final http.Client client;
  final String base;
  HttpLeaderboardRepository(this.client, {this.base = 'https://drive.lmqc.fr'});

  @override
  Future<SubmitResult> submit(PlayerIdentity id, double totalKm) async {
    final resp = await client.post(Uri.parse('$base/v1/score'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode(
            {'user_id': id.userId, 'pseudo': id.pseudo, 'total_km': totalKm}));
    if (resp.statusCode != 200) {
      throw LeaderboardException('submit: HTTP ${resp.statusCode}');
    }
    final j = jsonDecode(resp.body) as Map<String, dynamic>;
    return SubmitResult(
        rank: j['rank'] as int, totalKm: (j['total_km'] as num).toDouble());
  }

  @override
  Future<LeaderboardData> fetch(String userId) async {
    final resp = await client
        .get(Uri.parse('$base/v1/leaderboard?user_id=$userId'));
    if (resp.statusCode != 200) {
      throw LeaderboardException('fetch: HTTP ${resp.statusCode}');
    }
    final j = jsonDecode(resp.body) as Map<String, dynamic>;
    return LeaderboardData(
      top: [
        for (final e in j['top'] as List<dynamic>)
          LeaderboardEntry.fromJson(e as Map<String, dynamic>)
      ],
      me: j['me'] == null
          ? null
          : LeaderboardEntry.fromJson(j['me'] as Map<String, dynamic>),
    );
  }
}
```
`flutter test test/leaderboard -v` → 3 PASS.

- [ ] **Step 3: Écrans** — `leaderboard_screen.dart` : `FutureBuilder` sur `fetch`, liste top 50 (`rank. pseudo — X km`, la ligne `me` mise en évidence + affichée sous la liste si hors top), pull-to-refresh, message d'erreur réseau non bloquant. `settings_screen.dart` : champ pseudo (`TextFormField`, validation 1-24) + affichage du user_id, du total km local et de la version des données de tuiles. Hook de la session : à `onSessionEnded(totalKm)`, `submit` en best-effort (échec réseau → SnackBar discrète, le total local reste la vérité ; re-synchronisé à la prochaine session ou à l'ouverture de l'écran classement).

- [ ] **Step 4: Vérification device + bout en bout** — terminer une petite session réelle → le score apparaît sur `https://drive.lmqc.fr/v1/leaderboard` (curl) et l'écran Classement l'affiche. `flutter analyze` + `flutter test` complets → verts.

- [ ] **Step 5: Commit + push + CI** — `git add -A && git commit -m "feat: leaderboard client, ranking and settings screens"; git push` → CI verte.

---

## Definition of Done (M1)

- [ ] Workflow `randomwalk-tiles` vert, Release avec manifest + tuiles Suisse téléchargeables publiquement.
- [ ] `https://drive.lmqc.fr/v1/leaderboard` répond en TLS.
- [ ] Sur device : carte OpenFreeMap, position, itinéraire A→B piéton ET vélo en Suisse, y compris en mode avion après premier téléchargement.
- [ ] Session de marche réelle → distance plausible → score visible dans le classement.
- [ ] `flutter analyze` 0 issue, tous tests unitaires verts en CI, test d'intégration Monaco passé sur device/émulateur.
- [ ] Hors couverture (ex. point aux USA) : erreur propre, pas de crash.
