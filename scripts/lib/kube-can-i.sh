#!/usr/bin/env bash
# Normalisation de la réponse de `kubectl auth can-i` (PLT-257).
# Le webhook d'autorisation d'OKE ajoute un suffixe : « no - . Opc-Request-Id: <nil> ».
# kube_can_i_answer lit la sortie sur stdin et affiche `yes` ou `no` d'après le
# PREMIER mot de la première ligne non vide ; toute autre valeur (vide, inconnue,
# « maybe », « yesterday », « Yes ») donne une sortie vide, donc un échec côté appelant.
kube_can_i_answer() {
  local line word
  line=$(awk 'NF { print; exit }')
  word=${line%%[[:space:]]*}
  case "$word" in
    yes|no) printf '%s' "$word" ;;
    *) printf '' ;;
  esac
}
