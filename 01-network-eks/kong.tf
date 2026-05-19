# Kong em modo DB-less com Ingress Controller.
# Expõe via NLB público. Cada microsserviço registra um Ingress próprio
# (no respectivo k8s/ folder) que o Kong roteia.

resource "kubernetes_namespace" "kong" {
  metadata {
    name = "kong"
  }
  depends_on = [aws_eks_cluster.this, aws_eks_node_group.default]
}

resource "helm_release" "kong" {
  name       = "kong"
  repository = "https://charts.konghq.com"
  chart      = "kong"
  namespace  = kubernetes_namespace.kong.metadata[0].name
  version    = "2.38.0"

  values = [
    <<-YAML
    proxy:
      type: LoadBalancer
      annotations:
        service.beta.kubernetes.io/aws-load-balancer-type: nlb
    admin:
      enabled: true
      type: ClusterIP
    env:
      database: "off"
    ingressController:
      enabled: true
      installCRDs: false
    YAML
  ]

  depends_on = [aws_eks_cluster.this, aws_eks_node_group.default]
}

# Namespace onde os microsserviços vão viver.
resource "kubernetes_namespace" "autoflow" {
  metadata {
    name = "autoflow"
  }
  depends_on = [aws_eks_cluster.this, aws_eks_node_group.default]
}
