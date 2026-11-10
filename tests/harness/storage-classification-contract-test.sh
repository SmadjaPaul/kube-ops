#!/usr/bin/env bash
set -euo pipefail

base="${STORAGE_CLASSIFICATION_BASE:-origin/main}"
git rev-parse --verify "$base" >/dev/null 2>&1 || base=HEAD^
files="$(git diff --name-only "$base" -- 'k8s/**/*.yaml' 'k8s/**/*.yml' || true)"

while IFS= read -r file; do
  [[ -n "$file" && -f "$file" ]] || continue
  grep -q '^kind:[[:space:]]*PersistentVolumeClaim[[:space:]]*$' "$file" || continue
  while IFS=$'\t' read -r name data_class contract expires proof review; do
    [[ -n "$name" ]] || continue
    case "$data_class" in
      protected|reconstructible|ephemeral|orphan-confirmed|unknown) : ;;
      *) echo "STORAGE_CLASSIFICATION=FAIL $file/$name: invalid or missing data class" >&2; exit 1 ;;
    esac
    case "$data_class" in
      protected)
        [[ "$contract" =~ ^(velero-kopia|cnpg-barman|longhorn-transitional)$ ]] || {
          echo "STORAGE_CLASSIFICATION=FAIL $file/$name: protected PVC needs a backup contract" >&2
          exit 1
        }
        ;;
      reconstructible)
        [[ "$contract" == exclude ]] || {
          echo "STORAGE_CLASSIFICATION=FAIL $file/$name: reconstructible PVC must be explicitly excluded" >&2
          exit 1
        }
        ;;
      ephemeral)
        [[ -n "$expires" ]] || {
          echo "STORAGE_CLASSIFICATION=FAIL $file/$name: ephemeral PVC needs an expiration" >&2
          exit 1
        }
        ;;
      orphan-confirmed)
        [[ -n "$proof" ]] || {
          echo "STORAGE_CLASSIFICATION=FAIL $file/$name: orphan-confirmed PVC needs owner proof" >&2
          exit 1
        }
        ;;
      unknown)
        [[ -n "$review" ]] || {
          echo "STORAGE_CLASSIFICATION=FAIL $file/$name: unknown PVC needs a review marker" >&2
          exit 1
        }
        ;;
    esac
  done < <(
    yq -r 'select(.kind == "PersistentVolumeClaim") |
      [(.metadata.name // ""),
       (.metadata.labels["storage.smadja.dev/data-class"] // ""),
       (.metadata.labels["storage.smadja.dev/backup-contract"] // ""),
       (.metadata.annotations["storage.smadja.dev/expires-after"] // ""),
       (.metadata.annotations["storage.smadja.dev/owner-proof"] // ""),
       (.metadata.annotations["storage.smadja.dev/review"] // "")] | @tsv' "$file"
  )
done <<< "$files"

echo 'storage classification contract: PASS (changed PVCs classified)'
