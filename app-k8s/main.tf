terraform {
  backend "s3" {
    bucket         = "nexus-devops-tfstate-732169941009"
    key            = "app-k8s/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.2"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

data "aws_eks_cluster" "main" { name = "nexus-k8s-aula" }
data "aws_eks_cluster_auth" "main" { name = "nexus-k8s-aula" }

provider "kubernetes" {
  host                   = data.aws_eks_cluster.main.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.main.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.main.token
}

provider "aws" {
  region = "us-east-1"
}

data "aws_db_instance" "main" {
  db_instance_identifier = "nexus-payment-db"
}

data "aws_secretsmanager_secret_version" "rds_master" {
  secret_id = data.aws_db_instance.main.master_user_secret[0].secret_arn
}

locals {
  rds_username = jsondecode(data.aws_secretsmanager_secret_version.rds_master.secret_string)["username"]
  rds_password = jsondecode(data.aws_secretsmanager_secret_version.rds_master.secret_string)["password"]
}

resource "kubernetes_secret_v1" "payment_db" {
  metadata {
    name = "payment-db-secret"
  }
  data = {
    username = local.rds_username
    password = local.rds_password
  }
  type = "Opaque"
}

resource "kubernetes_secret_v1" "payment_app" {
  metadata {
    name = "payment-app-secret"
  }
  data = {
    authorization-fingerprint-secret = "qualquer-valor-nao-vazio"
    dummypay-key-id                  = "chave-tecnica-dummypay"
    dummypay-key-secret              = "segredo-tecnico-dummypay"
    dummypay-webhook-secret          = "dev-webhook-secret"
  }
  type = "Opaque"
}

resource "kubernetes_deployment_v1" "payment" {
  metadata {
    name   = "payment"
    labels = { app = "payment" }
  }
  spec {
    replicas = 1
    selector {
      match_labels = { app = "payment" }
    }
    template {
      metadata {
        labels = { app = "payment" }
      }
      spec {
        container {
          name  = "payment"
          image = "fabianofsc/nexus-payment-service:v1.0-k8s-payment-dummypay"
          port {
            container_port = 8081
          }
          env {
            name  = "SERVER_PORT"
            value = "8081"
          }
          env {
            name  = "DB_URL"
            value = "jdbc:postgresql://${data.aws_db_instance.main.address}:5432/nexus_payment?sslmode=require"
          }
          env {
            name = "DB_USERNAME"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.payment_db.metadata[0].name
                key  = "username"
              }
            }
          }
          env {
            name = "DB_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.payment_db.metadata[0].name
                key  = "password"
              }
            }
          }
          env {
            name = "NEXUS_PAYMENT_AUTHORIZATION_FINGERPRINT_SECRET"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.payment_app.metadata[0].name
                key  = "authorization-fingerprint-secret"
              }
            }
          }
          env {
            name  = "NEXUS_PAYMENT_DUMMYPAY_BASE_URL"
            value = "http://dummypay:8080"
          }
          env {
            name = "NEXUS_PAYMENT_DUMMYPAY_KEY_ID"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.payment_app.metadata[0].name
                key  = "dummypay-key-id"
              }
            }
          }
          env {
            name = "NEXUS_PAYMENT_DUMMYPAY_KEY_SECRET"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.payment_app.metadata[0].name
                key  = "dummypay-key-secret"
              }
            }
          }
          env {
            name = "NEXUS_PAYMENT_DUMMYPAY_WEBHOOK_SECRET"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.payment_app.metadata[0].name
                key  = "dummypay-webhook-secret"
              }
            }
          }
          readiness_probe {
            http_get {
              path = "/actuator/health"
              port = 8081
            }
            initial_delay_seconds = 10
            period_seconds        = 5
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "payment" {
  metadata {
    name = "payment"
  }
  spec {
    type     = "LoadBalancer"
    selector = { app = "payment" }
    port {
      port        = 8081
      target_port = 8081
    }
  }
}

# dummypay
resource "kubernetes_secret_v1" "dummypay_db" {
  metadata {
    name = "dummypay-db-secret"
  }
  data = {
    username     = local.rds_username
    password     = local.rds_password
    database-url = "postgres://${local.rds_username}:${urlencode(local.rds_password)}@${data.aws_db_instance.main.address}:5432/dummypay?sslmode=require"
  }
  type = "Opaque"
}

resource "kubernetes_secret_v1" "dummypay_app" {
  metadata {
    name = "dummypay-app-secret"
  }
  data = {
    account-key-id         = "chave-tecnica-dummypay"
    account-key-secret     = "segredo-tecnico-dummypay"
    webhook-secret-enc-key = "vP4KI5MTnHpxyZrGxBysI3tddQmgH07ty4bf3T1yiNg=" # chave AES de 32 bytes em base64 — o dummy-pay valida isso no boot, string qualquer crasheia o container
  }
  type = "Opaque"
}

resource "kubernetes_deployment_v1" "dummypay" {
  metadata {
    name   = "dummypay"
    labels = { app = "dummypay" }
  }
  spec {
    replicas = 1
    selector {
      match_labels = { app = "dummypay" }
    }
    template {
      metadata {
        labels = { app = "dummypay" }
      }
      spec {
        container {
          name  = "dummypay"
          image = "fabianofsc/dummy-pay:v1.0-k8s-payment-dummypay"
          port {
            container_port = 8080
          }
          env {
            name  = "DUMMYPAY_HTTP_ADDR"
            value = ":8080"
          }
          env {
            name = "DB_USER"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.dummypay_db.metadata[0].name
                key  = "username"
              }
            }
          }
          env {
            name = "DB_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.dummypay_db.metadata[0].name
                key  = "password"
              }
            }
          }
          env {
            name = "DUMMYPAY_DATABASE_URL"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.dummypay_db.metadata[0].name
                key  = "database-url"
              }
            }
          }
          env {
            name = "DUMMYPAY_ACCOUNT_KEY_ID"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.dummypay_app.metadata[0].name
                key  = "account-key-id"
              }
            }
          }
          env {
            name = "DUMMYPAY_ACCOUNT_KEY_SECRET"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.dummypay_app.metadata[0].name
                key  = "account-key-secret"
              }
            }
          }
          env {
            name = "DUMMYPAY_WEBHOOK_SECRET_ENC_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.dummypay_app.metadata[0].name
                key  = "webhook-secret-enc-key"
              }
            }
          }
          env {
            name  = "DUMMYPAY_PROCESSING_DELAY"
            value = "2s"
          }
          env {
            name  = "DUMMYPAY_WORKER_POLL_INTERVAL"
            value = "250ms"
          }
          readiness_probe {
            http_get {
              path = "/health"
              port = 8080
            }
            initial_delay_seconds = 5
            period_seconds        = 5
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "dummypay" {
  metadata {
    name = "dummypay"
  }
  spec {
    selector = { app = "dummypay" }
    port {
      port        = 8080
      target_port = 8080
    }
  }
}

# notification
resource "kubernetes_secret_v1" "notification_db" {
  metadata {
    name = "notification-db-secret"
  }
  data = {
    database-url = "postgres://${local.rds_username}:${urlencode(local.rds_password)}@${data.aws_db_instance.main.address}:5432/notification_db?sslmode=require"
  }
}

resource "kubernetes_deployment_v1" "notification" {
  metadata {
    name   = "notification"
    labels = { app = "notification" }
  }
  spec {
    replicas = 1
    selector {
      match_labels = { app = "notification" }
    }
    template {
      metadata {
        labels = { app = "notification" }
      }
      spec {
        container {
          name  = "notification"
          image = "fabianofsc/notification-service:v1.0-notification"
          port {
            container_port = 8080
          }
          env {
            name = "DATABASE_URL"
            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.notification_db.metadata[0].name
                key  = "database-url"
              }
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "notification" {
  metadata {
    name = "notification"
  }
  spec {
    selector = { app = "notification" }
    port {
      port        = 8080
      target_port = 8080
    }
  }
}
