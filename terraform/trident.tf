
resource "helm_release" "trident" {
  provider         = helm.cluster1
  name             = "trident-operator"
  namespace        = "trident"
  create_namespace = true
  description      = null
  chart            = "trident-operator"
  version          = "100.2502.0"
  repository       = "https://netapp.github.io/trident-helm-chart"
  values           = [file("${path.module}/values.yaml")]

  set {
    name  = "nodePrep"
    value = "{iscsi}"
  }

  depends_on = [module.eks]
}

resource "time_sleep" "wait_30_seconds" {
  depends_on = [helm_release.trident]

  create_duration  = "30s"
  destroy_duration = "60s"
}

resource "kubectl_manifest" "trident_backend_config_nas" {
  provider   = kubectl.cluster1
  depends_on = [time_sleep.wait_30_seconds]
  yaml_body = templatefile("${path.module}/../manifests/backendnas.yaml.tpl",
    {
      fs_id      = aws_fsx_ontap_file_system.eksfs.id
      fs_svm     = aws_fsx_ontap_storage_virtual_machine.ekssvm.name
      secret_arn = aws_secretsmanager_secret.fsxn_password_secret.arn
    }
  )
}

resource "kubectl_manifest" "trident_backend_config_san" {
  provider   = kubectl.cluster1
  depends_on = [time_sleep.wait_30_seconds]
  yaml_body = templatefile("${path.module}/../manifests/backendsan.yaml.tpl",
    {
      fs_id      = aws_fsx_ontap_file_system.eksfs.id
      fs_svm     = aws_fsx_ontap_storage_virtual_machine.ekssvm.name
      secret_arn = aws_secretsmanager_secret.fsxn_password_secret.arn
    }
  )
}

resource "kubectl_manifest" "trident_storage_class_nas" {
  provider   = kubectl.cluster1
  depends_on = [kubectl_manifest.trident_backend_config_nas]
  yaml_body  = file("${path.module}/../manifests/storageclass.yaml")
}

resource "kubectl_manifest" "trident_storage_class_san" {
  provider   = kubectl.cluster1
  depends_on = [kubectl_manifest.trident_backend_config_san]
  yaml_body  = file("${path.module}/../manifests/storageclasssan.yaml")
}

resource "kubectl_manifest" "trident_snapshot_class" {
  provider   = kubectl.cluster1
  depends_on = [helm_release.trident]
  yaml_body  = file("${path.module}/../manifests/fsxn-volume-snapshot-class.yaml")
}

resource "kubectl_manifest" "ebs_storage_class" {
  provider   = kubectl.cluster1
  depends_on = [aws_eks_addon.ebs-csi]
  yaml_body  = file("${path.module}/../manifests/ebs-storageclass.yaml")
}


resource "kubectl_manifest" "ebs_snapshot_class" {
  provider   = kubectl.cluster1
  depends_on = [aws_eks_addon.ebs-csi]
  yaml_body  = file("${path.module}/../manifests/ebs-volume-snapshot-class.yaml")
}

resource "kubernetes_namespace_v1" "tenant0" {
  provider = kubernetes.cluster1
  metadata {
    name = "tenant0"
  }

  depends_on = [module.eks]
}

resource "kubernetes_namespace_v1" "tenant1" {
  provider = kubernetes.cluster1
  metadata {
    name = "tenant1"
  }

  depends_on = [module.eks]
}

resource "kubernetes_namespace_v1" "tenant2" {
  provider = kubernetes.cluster1
  metadata {
    name = "tenant2"
  }

  depends_on = [module.eks]
}

data "kubectl_path_documents" "sample_app_tenant0" {
  pattern = "../manifests/sample.yaml"
}

resource "kubectl_manifest" "sample_app_tenant0" {
  provider           = kubectl.cluster1
  override_namespace = "tenant0"
  wait               = true
  depends_on         = [kubectl_manifest.trident_storage_class_san, kubectl_manifest.trident_storage_class_nas, kubernetes_namespace_v1.tenant0, helm_release.trident, kubectl_manifest.ebs_storage_class]
  for_each           = toset(data.kubectl_path_documents.sample_app_tenant0.documents)
  yaml_body          = each.value
}

data "http" "ip" {
  url = "https://api.ipify.org"
}


resource "kubectl_manifest" "sample_ap_svc_tenant0" {
  provider           = kubectl.cluster1
  override_namespace = "tenant0"
  wait               = true
  depends_on         = [kubectl_manifest.sample_app_tenant0 ,helm_release.lb]
  yaml_body = templatefile("${path.module}/../manifests/svc.yaml.tpl",
    {
      loadBalancerSourceRanges = "${data.http.ip.response_body}/32"
    }
  )
}