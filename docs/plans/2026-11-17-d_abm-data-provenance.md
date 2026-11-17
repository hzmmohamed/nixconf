# d_abm: data provenance audit (2026-11-17)

Read-only audit of `~/work/tfc/repos/d_abm` (branch `feat/sampling-sweep`, HEAD `039b423`,
remote `github.com:transportforcairo/eg-abm`). Nothing in the repo or in S3 was modified or downloaded.

**The question:** can a fresh clone get every input it needs, either from git/LFS/DVC or from a fetch or
derive script in the repo?

## Verdict

**No.** A fresh clone has no raw data and nothing in the repo fetches it.

- `.gitignore` ignores every directory named `data` (except `src/data` and `interactive/src/data`), plus
  `tools/` and `output/`. There is no LFS (`.gitattributes` is absent) and no DVC.
- The pipeline's **26 raw catalog inputs** (about **857 MB**) live only in `data/` on this workstation.
- The only fetch path is `ci/run-pipeline.sh`, which syncs `s3://<old-artifacts-bucket>/data`. **That bucket does not
  exist** (NoSuchBucket), so the path is dead.
- The only real fetch script is `scripts/download_overture.py`. It is pinned (release `2026-05-20.0`), but the
  pipeline doesn't consume Overture.
- `README.md` § "Data directory layout" lists the expected files. It names sources for some (Geofabrik, CAPMAS,
  GTFS) but gives no URL, version, checksum, licence or fetch command, and it is out of date: it still lists
  `counts/merged_TC.csv` and `final_Pax_*.csv`, while the catalog now reads `counts/5_Deliverables/*.parquet`.
  It also omits the metro, tawwaly, cedej and metro GTFS inputs.
- The MATSim/pt2matsim jars (`tools/`, gitignored, no download script) and the **matsim-paratransit jar** are
  also required. The jar is built from a sibling repo **that has no git remote**, and pinned copies of it sit in
  gitignored `output/`.
- S3 bucket `<raw-data-bucket>` holds a **2025-09-09** `abm-data.tar.gz` (454 MB). It is undocumented, unversioned,
  not referenced by any script, and older than several current inputs: counts (2026-07), metro (2026-05), tawwaly
  (2026-11), cedej export, `gtfs` 5.0.

What is in good shape:

- Everything downstream of the raw inputs is derived by Kedro.
- The AWS sim path (`infra/aws/bin/sim`) is well provenanced: content-addressed inputs, a jar sha256, and a
  manifest with git SHAs.
- Fetched AWS run outputs referenced by the catalog still exist in `s3://<sim-bucket>/outputs/`.

## Method

- **Free inputs:** loaded the Kedro project with the repo's own dev env and listed the datasets that every
  registered pipeline consumes but no node produces. That gives 86 names.
- **Classification:** resolved each name against `OmegaConfigLoader` and dropped the `@path` aliases of derived
  files (same filepath as a produced twin) and the dataset factories.
- **Other references:** grepped parameters and code for other paths (`data/`, `tools/`, `../`, `s3://`, URLs).
- **Local state:** checked existence, size and mtime of each input, plus `git ls-files`, `git check-ignore` and
  `git status --ignored`.
- **S3:** listed top levels with `aws sts get-caller-identity` (profile from `infra/aws/.env`, account
  `<aws-account>`, eu-central-1): working.

## Inputs

Class key:

- **a:** tracked in git
- **b:** LFS/DVC
- **c:** fetched by a script in the repo
- **d:** derived by the pipeline
- **e:** orphan (local only, no producing script, no or partial docs)
- **f:** referenced but missing

**Documented?** is judged against the repo, including the in-`data/` READMEs, which are themselves gitignored.

### Raw data (catalog free inputs)

| Input (catalog name → path under repo) | Class | Size | Source | Documented? |
|---|---|---|---|---|
| `zone_boundaries_level_{1,2,3}`, `subregion_admin2_names` → `data/eg_admin_boundaries/eg_admin_boundaries.gpkg` | e | 63 MB | Built by `tools/preprocess_admin_boundaries.py` (**gitignored**) from `admin1/*.json`, `admin2/*.json` (not present). Original source unknown | Path only |
| `zone_level_3_pop_density` → `data/capmas/census_2017/admin3_pop_density.geojson` | e | 218 MB | "CAPMAS 2017 shiakha layer, apparently the CEDEJ atlas; licence unknown" (`docs/plans/2026-11-16-population-fixes.md`) | Path only; provenance flagged unknown |
| `osm_raw_pbf` → `data/osm/egypt-latest.osm.pbf` | e | 155 MB | Geofabrik `egypt-latest` (public). Local copy dated 2025-07-28; "latest" is unpinned and Geofabrik keeps no old dated extracts per region | Source named, no URL/date/checksum |
| `census_buildings_metadata`, `census_establishments_metadata` → `data/capmas/census_2017/{buildings,establishments}/metadata.json` + `{cairo,giza,qalyubia}.pdf` | e | 22 MB (6 PDFs) + 2 hand-written JSON | CAPMAS 2017 census publications (public portal). The JSON page ranges are **hand-authored config** | `data/capmas/README.md` (gitignored) has portal links |
| `zone_name_to_code_mapping` → `data/capmas/census_2017/adm2_name_to_code_mapping/all.json` | e | 4 KB | Hand-made mapping | Path only |
| `requested_zone_codes` → `data/requested_zone_codes.json` | e | 4 KB | Hand-made study-area config | Path only |
| `universities_pdf` → `data/capmas/education/universities/capmas-annual_bulletin_…-2019.pdf` | e | 6 MB | CAPMAS catalog/401 (public) | `data/capmas/README.md` (gitignored) |
| `maptis_od_surveys`, `maptis_ti_surveys` → `data/maptis/{od,ti}_surveys/*_cleaned_epsg_4326.geojson` | e | 17 MB | TfC private GitLab `25_maptis/Data_Packaging` (needs GitLab access) | In-folder README (gitignored) has the GitLab path, no commit |
| `raw_vehicle_counts`, `raw_passenger_counts`, `survey_locations` → `data/counts/5_Deliverables/2024_*.{parquet,geojson}` | e | 0.6 MB (+36 MB zip) | TfC 2024 counts release (GeoNode, CC BY-NC 4.0) | `AI-generated_geonode_metadata.md` (gitignored); README lists the old CSVs |
| `station_link_mapping` → `data/counts/station_link_mapping.csv` | **f** | – | "when available" | README mentions it |
| `raw_lfs_individuals` → `data/lfs/lfs-ind.csv` | e | 84 MB | CAPMAS LFS 2018 microdata (**access permit, restricted**). CSV exported by hand in PSPP from `.sav` (`pspp.jnl` journals point at `/home/hfahmi/…/data_cairo/…`) | "requires access permit"; no export script |
| `gtfs_raw_feeds` → `data/gtfs/` (reads `*.zip`: `gcr_feed_lava_5.0.zip`) | e | 5 MB (+34 MB stale `.txt`) | TfC GCR surface GTFS, "lava 5.0" | "GTFS feeds", no source |
| `gtfs_metro_raw_zip` → `data/cairo-metro-gtfs.zip` | e | 48 KB | TfC Cairo Metro GTFS 1.1.1, valid 2024-10-28 to 2025-10-27 | Comment in `catalog_gtfs_metro.yml` |
| `metro_flows` → `data/metro_flows.parquet` | e | 3.4 MB | Metro OD, Dec 2019 to Sep 2020; origin undocumented | Schema only (`docs/plans/2026-06-11-…`) |
| `metro_stops_raw` → `data/metro-stops.csv` | e | 12 KB | Undocumented | No |
| `cedej_qism_population_by_sex` → `data/cedej-capmas/Export_….csv` | e | 2 KB | CEDEJ-CAPMAS portal export (Giza only); "terms of use not confirmed". Scraper is submodule `.repos/scrape-cedej` (private GitLab) but this CSV was a manual export | Partial (node comment) |
| `subregion_tawwaly_sqlite` → `data/tawwaly/…/collector/tawwaly_20261101.sqlite` | e | 220 MB | Collector run on the data-portal EC2 box until 2026-11-05; **non-reproducible capture** (live API) | `data/tawwaly/…/README.md` + `DEPLOY.md` (gitignored) |
| `realtime_cta_{trips,headways,stop_visits,stations}` → `…/tawwaly_records_20261101_csv/*.csv`, `lines_stations.json` | e | 29 MB | Derived from the sqlite by `collector/daily_records.py`, **which lives in gitignored `data/`** | Same gitignored README |

### Tools and code inputs

| Input | Class | Size | Source | Documented? |
|---|---|---|---|---|
| `params:matsim_jar` → `tools/matsim-2026.0/matsim-2026.0.jar` | e | 125 MB unpacked / 108 MB zip | MATSim 2026.0 release (public) | No |
| `params:pt2matsim_jar` → `tools/pt2matsim-26.4-shaded.jar` | e | 85 MB | pt2matsim 26.4 (public) | No |
| `tools/osmosis-0.49.2/` | a (oddly tracked despite `tools` in `.gitignore`) | 14 MB zip + tree | public | – |
| `params:paratransit_jar` / `sim_stage.jar` → `../matsim-paratransit/target/…-SNAPSHOT-shaded.jar` | e | 88 MB | Built from sibling repo `~/work/tfc/repos/matsim-paratransit`, **no git remote** (all worktrees: `-exp`, `-xp`, `-stuck`, `-cordon`) | No |
| `pt_sweep.jar` → `../matsim-paratransit-exp/target/…jar` | e | 87 MB | Same repo, branch `feat/pt-sweep` | No |
| `subregion_cut.paratransit_jar`, `full_region.paratransit_jar` → `output/v0.4/subregion_cut/central/r010/stuck_exp/matsim-paratransit-{xp-4d03fee,giveup-e9dd364}.jar` | e (pinned jars stored in gitignored `output/`) | 88 MB each | Same repo at those commits. Some are in `s3://<sim-bucket>/jars/<sha256>.jar`, which **expires after 90 days** (lifecycle `jars-expire`) | sha in file name only |

### Inputs under `output/` that no node produces

| Input | Class | Size | Source | Documented? |
|---|---|---|---|---|
| `demand_validation_run_{modestats,convergence}` → `output/v0.4/aws_runs/full-r001-20261116T1304-7a319675/output/` | c (`bin/sim fetch`) | 3.4 GB local | `s3://<sim-bucket>/outputs/<run>/`, present. Outputs go to Infrequent Access at 30 d and don't expire | Yes (infra README) |
| `lab_exp*_sim_trips` (10) → `output/v0.4/matsim_lab/*/simulation_output/output_trips.csv.zst` | e | 13 MB | Manual MATSim runs ("populated after running MATSim") | Comment only |
| `paratransit_corridor_validation_b4b`, `…fleet_driven_seed_metrics_b4b` | e | 8 KB | "Frozen copy" of an earlier run's table | Comment only |
| All other `output/…` free inputs (`*@path`, `*_xml_path`, `matsim_output_*`, `subregion_cut_*_in`) | d | – | Path aliases of files written by produced twins | – |

### Derived, and legacy or unused

- **Derived:** everything else in the 557 catalog entries is class d. That includes `gtfs_cleaned`,
  `interactive/public/data/*` (gitignored, 310 MB), and the untracked `interactive/public/bundles/central-*`.
  Tracked fixtures live under `interactive/public/bundles/fixture/` (class a).
- **Overture:** `data/overture/` (53 MB) is class c and pinned, but nothing consumes it.
- **Not referenced by the current pipeline:**
  - `.synpp_cache/` (4.7 GB, legacy synpp; a copy is in `s3://<raw-data-bucket>/synpp_cache_20250929.tar.gz`)
  - `simulation_output/`
  - `data/7_survey_packaged_data.zip`, `data/_61_segment_db_v2_w_matsimid.geojson`
  - `data/adm2_requested_*.csv`, `data/lfs/lfs-hh.csv`, `data/capmas/pre_university_education_stats_2020.pdf`,
    `data/counts/{merged_TC,final_Pax_20241125,od_surveys_deduplicated}.csv`

## S3 (read-only listing)

| Bucket | Contents | Relevance |
|---|---|---|
| `<old-artifacts-bucket>` | **Does not exist** | It's the default of `ci/run-pipeline.sh` (`DATA_S3_PREFIX`), so CI data download is broken |
| `<raw-data-bucket>` | 10 objects, 24.2 GB, all 2025-09: `abm-data.tar.gz` (454 MB), `eg-abm_2025-09-22T225954.tar` (12.4 GB), synpp cache, old sim outputs | Only backup of raw data, but undocumented and **predates** counts/metro/tawwaly/cedej. No versioning, no lifecycle. Contents of the tarballs not verified (no download) |
| `<sim-bucket>` | `inputs/` (blobs + 25 runs), `jars/` (4 jars), `outputs/` (25 runs); 4,405 objects, 72 GB | Staged MATSim inputs and outputs. **`inputs/` and `jars/` expire after 90 days**; outputs go to IA at 30 d. No versioning |
| `tfc-cairo-viz-dev` | Visualizer and run-status page | Derived |

## Orphans, ranked by risk

1. **matsim-paratransit source repo has no remote.** Every simulation needs its jar: sim_stage, subregion_cut,
   full_region, pt_sweep, layer3. If this disk dies, the model code behind every MATSim result is gone. The S3 jar
   copies expire in 90 days.
   **Fix:** push it to TfC GitLab/GitHub today (code, not data, but it is the biggest single loss risk).
2. **Tawwaly real-time capture** (`tawwaly_20261101.sqlite`, 220 MB, plus collector and `daily_records.py`). It
   is a one-off live capture that can't be regenerated (collector stopped 2026-11-05). The processing script sits
   in gitignored `data/`. Copies may exist on the EC2 box or SharePoint, but the repo doesn't say.
   **Fix:** upload to S3 and move `collector.py`/`daily_records.py` into the repo (`scripts/tawwaly/`).
3. **CAPMAS LFS 2018 microdata** (`labor_family_2018.sav`, `Egypt 2018-LFS *.sav`, plus the hand-exported
   `lfs-ind.csv`). It is restricted (access permit), so it can't be re-downloaded, and the `.sav` → CSV step was
   done by hand in PSPP.
   **Fix:** upload to a private S3 prefix and replace the PSPP step with a scripted `pyreadstat` conversion node.
4. **`admin3_pop_density.geojson`** (218 MB) drives the 20.45 M population total. Its origin and licence are
   unknown, and it is not in any newer backup.
   **Fix:** upload and record "origin unknown, CEDEJ atlas?" in the manifest until confirmed.
5. **`eg_admin_boundaries.gpkg`.** The builder script is in gitignored `tools/` and its inputs (`admin1/`,
   `admin2/` JSON) are gone.
   **Fix:** upload the gpkg, move the script into `scripts/`, and record the original source.
6. **Metro OD flows** (`metro_flows.parquet`) and `metro-stops.csv`. Origin is completely undocumented, and this
   is likely third-party, non-public data.
7. **MAPTIS OD/TI surveys** and **2024 counts.** TfC-owned and recoverable from GitLab/GeoNode, but unpinned (no
   commit or release id) and need credentials.
8. **Hand-authored config living in `data/`:** `requested_zone_codes.json`, `census_*/metadata.json` (PDF page
   ranges), `adm2_name_to_code_mapping/*.json`. Tiny, irreplaceable work, and **should be in git** (total < 20 KB).
9. **GTFS feeds** (`gcr_feed_lava_5.0.zip`, `cairo-metro-gtfs.zip`). TfC-produced, small, unpinned in the repo.
10. **Pinned paratransit jars in `output/`** (`xp-4d03fee`, `giveup-e9dd364`) and frozen B4b CSVs. Lost on any
    `output/` cleanup.
11. **OSM extract** (`egypt-latest`, 2025-07-28). Public, but "latest" can't be re-obtained at that date: Geofabrik
    doesn't keep historical dated extracts per region. Upload it.
12. **CAPMAS census PDFs, universities bulletin, CEDEJ CSV, MATSim/pt2matsim jars.** Public, but the portals are
    unstable (capmas.gov.eg URLs are session/page-id based). Upload with checksums. The jars can be fetched with
    pinned URLs and hashes.

## Other reproducibility risks

- **Seeding:** there is a `random_seed: 1` global, but:
  - `np.random.seed()` is set inside individual nodes, while other nodes draw from the global NumPy state with no
    seed: `utils/ipf.py:24`, `locations_pool/nodes.py:169`, `population/nodes.py:486`. Their results depend on
    node execution order, and the parallel runner varies that order.
  - `lfs/nodes.py:40` calls polars `.sample(…)` with **no seed**.
  - `interactive_export/nodes.py:921` uses unseeded `random.sample`.
- **Credentials:**
  - TfC GitLab: MAPTIS data and the `scrape-cedej` submodule.
  - CAPMAS permit: LFS.
  - AWS SSO, account `<aws-account>`, profile in `infra/aws/.env` (gitignored): S3.
  - Overture uses anonymous S3.
- **Absolute and sibling paths:** `../matsim-paratransit*/target/*.jar` in 3 parameter files, and the `pspp.jnl`
  journals use `/home/hfahmi/…/data_cairo/`.
- **CI:** `ci/run-pipeline.sh` skips the download whenever `data/` is non-empty, so a partial `data/` is never
  completed. Its bucket doesn't exist. `.dockerignore` excludes `data` and `tools`, so the image has neither.
- **Stale leftovers:** `data/gtfs/*.txt` (34 MB) sits beside the zip that is actually read, and there are a
  `.zip.part` file and LibreOffice `.~lock` files in `data/counts`, `data/maptis`.

## Recommendations

Keep it simple: **a manifest + one S3 prefix + a fetch script.** DVC is not justified:

- the raw set is under 1 GB and changes a few times a year;
- Kedro already tracks the derivations;
- the AWS sim path already does content addressing.

DVC would add a second cache and state system for one maintainer. Git LFS is a poor fit for restricted data (LFS
on GitHub is shared with everyone who has repo access, and charges for bandwidth).

| # | Change | Size | Effort |
|---|---|---|---|
| 1 | **Push `matsim-paratransit` to a remote** (TfC GitLab/GitHub); record its URL in d_abm's README. Optionally make it a submodule or document the build (`mvn -Pshaded package` at a given SHA) | – | 15 min |
| 2 | **Create a raw-data bucket/prefix**, e.g. `s3://<raw-data-bucket>/raw/v1/…` (reuse the existing bucket), with **versioning on**, no expiry, SSE, private. Separate prefix `raw/restricted/` for LFS microdata and MAPTIS, with a narrower IAM grant | – | 30 min |
| 3 | **Upload the orphans now**, priority order: tawwaly sqlite + records + collector; LFS `.sav` + `lfs-ind.csv`; `admin3_pop_density.geojson`; `eg_admin_boundaries.gpkg`; metro flows/stops; counts deliverables; MAPTIS geojsons; GTFS zips; OSM pbf; census/universities PDFs; cedej CSV; the two pinned paratransit jars + frozen B4b CSVs | ~0.9 GB required; ~1.2 GB with `.sav` originals and the counts zip | 1 h |
| 4 | **`data/manifest.yaml` (tracked)**: one entry per input with `path`, `catalog`, `source` (URL / GitLab path + commit / "TfC internal" / "CAPMAS permit"), `version/date`, `sha256`, `size`, `licence`, `access` (public / tfc / restricted), `s3_key`, `fetch` (s3, http, script). Generate the first version with a one-off `sha256sum` over the current `data/` files | ~26 entries, ~300 lines | 2–3 h (provenance research is the slow part: pop density, metro, boundaries) |
| 5 | **Un-ignore hand-authored config**: move `requested_zone_codes.json`, `census_2017/*/metadata.json`, `adm2_name_to_code_mapping/*.json` to `conf/base/data/` (or add `!` rules) and point the catalog there | < 20 KB | 30 min |
| 6 | **`scripts/fetch-data` (single entrypoint, plus `just fetch-data` / flake app)**: reads the manifest; `aws s3 cp` each S3 entry; `curl` public ones (MATSim, pt2matsim, optionally OSM/Overture) into `data/` and `tools/`; verifies sha256 for each file; skips present, verified files; `--public-only` for people without TfC creds; fails loudly on a missing access level. Replace `download_data()` in `ci/run-pipeline.sh` with it (fixes the dead bucket and the "non-empty dir" skip) | ~150 lines Python (no new deps: boto3 or the aws CLI already in the shell) | 3–4 h |
| 7 | **Move code out of gitignored dirs**: `tools/preprocess_admin_boundaries.py` → `scripts/`; `data/tawwaly/…/{collector.py,daily_records.py,DEPLOY.md,tawwaly_*.py}` → `scripts/tawwaly/`; LFS `.sav` → CSV as a Kedro node or script with `pyreadstat` | ~1 k lines moved | 1–2 h |
| 8 | **README "Data" section**: replace the tree with a pointer to the manifest + `fetch-data`; list the access levels and how to get each credential; mark `station_link_mapping.csv` optional | – | 30 min |
| 9 | **Jars:** fetch MATSim/pt2matsim by pinned URL + sha256 (or a Nix `fetchurl` in the flake, which suits the Nix-first setup). Exempt `jars/` from the 90-day expiry, or copy referenced jars to `raw/jars/`; reference pinned jars by sha256 instead of `output/…` paths | – | 1 h |
| 10 | **Seeds**: replace global `np.random.*` with a per-node `np.random.default_rng(seed)` passed in; seed the polars `.sample(seed=…)` and `random.sample` | ~10 call sites | 1–2 h |
| 11 | **Cleanup (user decision):** document or delete `s3://<raw-data-bucket>` legacy tarballs (24 GB, Standard storage); delete the stale `data/gtfs/*.txt`, `.part` and lock files; decide on `.synpp_cache` (already backed up) | – | 30 min |

Rows 1, 3 and 5 are the urgent ones: they protect data that exists only on this disk. Rows 4 and 6 give
the clone-to-run path. Total about 1.5 days of work.

## Implementation (2026-11-17)

Branch `agentic/data-provenance` (from `agentic/onboarding`, worktree `.agentic-onboarding/d_abm-data`, 7 commits,
not pushed):

- **Done in the repo:** `data/manifest.yaml` (30 datasets, 117 files, sha256 + size + S3 key, class, source, licence),
  `scripts/fetch-data` (S3 or pinned URL, sha256 check, `--dataset`/`--all`/`--public-only`/`--dry-run`/`--check`/
  `--force`/`--root`/`--mirror`), `data/README.md`, README "Data" section; hand-written config tracked under
  `data/` (`.gitignore` negations, `setup-worktree.sh` now links `data/` entries instead of symlinking `data`);
  `ci/run-pipeline.sh` uses `fetch-data` (dead bucket gone); Tawwaly collector/`daily_records.py` and
  `preprocess_admin_boundaries.py` copied to `scripts/data_sources/`; seeds fixed in `utils/ipf.py`/`ipf_engine.py`,
  `lfs`, `locations_pool`, `population`, `interactive_export` (the flaky polars IPF tests now pass deterministically).
- **Not done: the S3 upload.** `<raw-data-bucket>` has Block Public Access **off** and a bucket policy granting anonymous
  `s3:GetObject` on objects tagged `public=yes` (one object is tagged: `simulation_output_full_network_cap_20_iters.tar.gz`,
  3.9 GiB, publicly readable). Per the stop rule nothing was changed or uploaded (versioning also still off). The
  manifest keys point at `raw/v1/…` and `raw/restricted/v1/…`; upload once the bucket is private.
- **matsim-paratransit bundle** (all branches + tags `pinned-jar-<sha>` for the 5 detached jar commits, which are on
  no branch): `~/work/tfc/repos/.agentic-onboarding/backups/matsim-paratransit-2026-11-17.bundle`, not yet in S3.
