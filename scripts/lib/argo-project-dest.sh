#!/usr/bin/env bash
# Semantique des destinations d'un AppProject Argo CD (doc "Projects", negations) :
#   argo_ns_allowed <fichier> <namespace>
# <fichier> : une valeur `destinations[].namespace` par ligne. Une destination est valide si
# une regle d'autorisation (sans `!`) la permet ET qu'aucune regle `!motif` ne la refuse.
# Jokers glob bash (`*`, `pr-*`). `''` ne correspond qu'au namespace vide.
argo_ns_allowed() {
  local file="$1" ns="$2" pat ok=1
  [[ -f $file ]] || return 1
  while IFS= read -r pat; do
    if [[ $pat == '!'* ]]; then
      # shellcheck disable=SC2053
      [[ $ns == ${pat#!} ]] && return 1
    elif [[ -z $pat ]]; then
      [[ -z $ns ]] && ok=0
    else
      # shellcheck disable=SC2053
      [[ $ns == $pat ]] && ok=0
    fi
  done <"$file"
  return $ok
}
