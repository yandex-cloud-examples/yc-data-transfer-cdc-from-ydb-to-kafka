# Infrastructure for the Yandex Database, Yandex Cloud Managed Service for Apache Kafka®, and Data Transfer
#
# RU: https://yandex.cloud/ru/docs/data-transfer/tutorials/cdc-ydb
# EN: https://yandex.cloud/en/docs/data-transfer/tutorials/cdc-ydb

# Set variables
variable "kf_topics_management" {
  description = "If Managed Service for Apache Kafka® topics are controlled by Admin API, enter `true`"
  type        = bool
}

# Configure the parameters of the source and target clusters:

locals {
  # Source Yandex Database settings:
  source_db_name = "" # Set the Yandex Database name

  # Target Managed Service for Apache Kafka® cluster settings:
  target_kf_version    = "" # Apache Kafka® version
  target_user_name     = "" # Username of the Apache Kafka® cluster
  target_user_password = "" # Apache Kafka® user's password

  # Specify these settings ONLY AFTER the YDB database is created. Then run "terraform apply" command again.
  # You should set up the target endpoint using the GUI to obtain its ID
  transfer_enabled = 0 # Value '0' disables the transfer creation before the source endpoint is created manually. After that, set to '1' to enable the transfer.

  # The following settings are predefined. Change them only if necessary.

  # Settings for the Network infrastructure:
  network_name        = "mkf_network"        # Name of the network
  subnet_name         = "mkf_subnet-a"       # Name of the subnet
  security_group_name = "mkf_security_group" # Name of the security group

  # Settings for the Managed Service for Apache Kafka® cluster:
  target_cluster_name = "mkf-cluster-target" # Name of the Apache Kafka® source cluster
  target_topic_name   = "cdc.sensors"        # Name of the Apache Kafka® topic for the target cluster

  # Settings for the Yandex Database:
  sa_name = "ydb-account" # Name of the service account

  # Settings for the Data Transfer
  source_endpoint_name = "ydb-source"               # Source endpoint name
  target_endpoint_name = "kf-target"                # Target endpoint name
  transfer_name        = "transfer-from-ydb-to-mkf" # Name of the Data Transfer
}

# Network infrastructure

resource "yandex_vpc_network" "mkf_network" {
  description = "Network for the Managed Service for Apache Kafka® clusters"
  name        = local.network_name
}

resource "yandex_vpc_subnet" "mkf_subnet-a" {
  description    = "Subnet in the ru-central1-a availability zone for the Managed Service for Apache Kafka® clusters network"
  name           = local.subnet_name
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.mkf_network.id
  v4_cidr_blocks = ["10.129.0.0/24"]
}

resource "yandex_vpc_security_group" "mkf_security_group" {
  description = "Security group for the Managed Service for Apache Kafka® clusters"
  network_id  = yandex_vpc_network.mkf_network.id
  name        = local.security_group_name

  ingress {
    description    = "Allow incoming traffic from the port 9091"
    protocol       = "TCP"
    port           = 9091
    v4_cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description    = "Allow outgoing traffic to the Internet"
    protocol       = "ANY"
    from_port      = 0
    to_port        = 65535
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

# Infrastructure for the Yandex Database

resource "yandex_ydb_database_serverless" "ydb" {
  name        = local.source_db_name
  location_id = "ru-central1"
}

resource "yandex_iam_service_account" "ydb-account" {
  description = "Service account for transfer access to YDB"
  name        = local.sa_name
}

# Grant a role to the service account. The role allows to perform any operations with database.
resource "yandex_ydb_database_iam_binding" "ydb-editor" {
  database_id = yandex_ydb_database_serverless.ydb.id
  role        = "editor"
  members = [
    "serviceAccount:${yandex_iam_service_account.ydb-account.id}"
  ]
}

# Infrastructure for the Managed Service for Apache Kafka® clusters

resource "yandex_mdb_kafka_cluster" "mkf-cluster-target" {
  description        = "Managed Service for Apache Kafka® cluster"
  environment        = "PRODUCTION"
  name               = local.target_cluster_name
  network_id         = yandex_vpc_network.mkf_network.id
  security_group_ids = [yandex_vpc_security_group.mkf_security_group.id]

  config {
    assign_public_ip = true
    brokers_count    = 1
    version          = local.target_kf_version
    kafka {
      resources {
        disk_size          = 10 # GB
        disk_type_id       = "network-ssd"
        resource_preset_id = "s2.micro" # 2 vCPU, 8 GB
      }
    }

    zones = [
      "ru-central1-a"
    ]
  }

  depends_on = [
    yandex_vpc_subnet.mkf_subnet-a
  ]
}

# Topic of the Managed Service for Apache Kafka® target cluster
resource "yandex_mdb_kafka_topic" "sensors-target" {
  cluster_id         = yandex_mdb_kafka_cluster.mkf-cluster-target.id
  name               = local.target_topic_name
  partitions         = 3
  replication_factor = 1
}

# User of the Managed service for the Apache Kafka ® target cluster
resource "yandex_mdb_kafka_user" "mkf-user-target" {
  cluster_id = yandex_mdb_kafka_cluster.mkf-cluster-target.id
  name       = local.target_user_name
  password   = local.target_user_password
  dynamic "permission" {
    for_each = toset(var.kf_topics_management ? ["admin"] : [])
    content {
      topic_name = "*"
      role       = "ACCESS_ROLE_ADMIN"
    }
  }
  permission {
    topic_name = "cdc.*"
    role       = "ACCESS_ROLE_CONSUMER"
  }
  permission {
    topic_name = "cdc.*"
    role       = "ACCESS_ROLE_PRODUCER"
  }
}

# Data Transfer infrastructure

resource "yandex_datatransfer_endpoint" "ydb-source" {
  description = "Source endpoint for the Managed Service for YDB"
  count       = local.transfer_enabled
  name        = local.source_endpoint_name
  settings {
    ydb_source {
      database           = yandex_ydb_database_serverless.ydb.database_path
      service_account_id = yandex_iam_service_account.ydb-account.id
      paths              = ["sensors"]
    }
  }
}

resource "yandex_datatransfer_endpoint" "kf-target" {
  description = "Target endpoint for the Managed Service for Apache Kafka® cluster"
  count       = local.transfer_enabled
  name        = local.target_endpoint_name
  settings {
    kafka_target {
      connection {
        cluster_id = yandex_mdb_kafka_cluster.mkf-cluster-target.id
      }
      auth {
        sasl {
          user = yandex_mdb_kafka_user.mkf-user-target.name
          password {
            raw = local.target_user_password
          }
        }
      }
      topic_settings {
        topic {
          topic_name = "cdc.sensors"
        }
      }
      serializer {
        serializer_auto {}
      }
    }
  }
}

resource "yandex_datatransfer_transfer" "ydb-mkf-transfer" {
  description = "Transfer from the Yandex Database to Managed Service for Apache Kafka® cluster"
  count       = local.transfer_enabled
  name        = local.transfer_name
  source_id   = yandex_datatransfer_endpoint.ydb-source[count.index].id
  target_id   = yandex_datatransfer_endpoint.kf-target[count.index].id
  type        = "INCREMENT_ONLY" # Replicate data from the source Apache Kafka® topics
}
