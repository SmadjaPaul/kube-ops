#!/usr/bin/env bash
# Controle de l'adresse de l'API OKE (oracle-a1) lue dans la session admin, sans IP codee en dur :
#   oke_api_server_valid <url>   0 si https://<IPv4 privee 10.0.0.0/16>[:port], sinon 1
# L'API d'OKE est privee (subnet du VCN 10.0.0.0/16) ; une autre adresse (publique, autre reseau,
# nom DNS) est refusee pour ne jamais distribuer un jeton agent vers un serveur inattendu.
oke_api_server_valid() {
  local url=${1:-} host octets o
  [[ $url =~ ^https://([0-9]{1,3}(\.[0-9]{1,3}){3})(:[0-9]{1,5})?/?$ ]] || return 1
  host=${BASH_REMATCH[1]}
  IFS=. read -r -a octets <<<"$host"
  for o in "${octets[@]}"; do ((10#$o <= 255)) || return 1; done
  ((10#${octets[0]} == 10 && 10#${octets[1]} == 0)) || return 1
  return 0
}
