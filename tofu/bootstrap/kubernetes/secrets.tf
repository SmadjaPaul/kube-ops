resource "null_resource" "doppler_access_token" {
  depends_on = [null_resource.external_secrets_kustomize]

  triggers = {
    token = var.doppler_token
  }

  provisioner "local-exec" {
    command = <<-EOT
      kubectl create secret generic doppler-access-token \
        --namespace=external-secrets \
        --from-literal=token='${var.doppler_token}' \
        --dry-run=client -o yaml | \
      kubectl apply -f -
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = "kubectl delete secret doppler-access-token -n external-secrets --ignore-not-found=true"
  }
}
