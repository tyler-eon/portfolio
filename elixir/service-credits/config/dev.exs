import Config

config :libcluster,
  topologies: [
    k8s: [
      strategy: Cluster.Strategy.Kubernetes,
      config: [
        mode: :ip,
        kubernetes_ip_lookup_mode: :pods,
        kubernetes_node_basename: "credits",
        kubernetes_selector: "app=credits",
        kubernetes_namespace: "default"
      ]
    ]
  ]
