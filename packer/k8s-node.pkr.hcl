packer {
  required_version = ">= 1.11.0"
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = "~> 1.3"
    }
  }
}

variable "region" {
  type    = string
  default = "eu-central-1"
}

variable "kubernetes_minor" {
  description = "Minor release to track, e.g. 1.36. The newest patch of it is installed at build time."
  type        = string
  default     = "1.36"
}

variable "helm_version" {
  type    = string
  default = "3.19.0"
}

variable "instance_type" {
  type    = string
  default = "t3.medium"
}

variable "ami_name_prefix" {
  type    = string
  default = "kube-ec2-node"
}

variable "ami_users" {
  description = "Other account IDs allowed to launch the AMI (multi-account setups)."
  type        = list(string)
  default     = []
}

locals {
  build_time = formatdate("YYYYMMDD-hhmm", timestamp())
}

# Ubuntu 24.04 LTS (Canonical's account). Every build starts from the newest
# base image and runs a full upgrade, which is how the immutable nodes get
# OS security fixes.
source "amazon-ebs" "node" {
  region        = var.region
  instance_type = var.instance_type
  ssh_username  = "ubuntu"

  source_ami_filter {
    owners      = ["099720109477"]
    most_recent = true
    filters = {
      name                = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
  }

  ami_name        = "${var.ami_name_prefix}-k8s-${var.kubernetes_minor}-${local.build_time}"
  ami_description = "Kubernetes ${var.kubernetes_minor} node (kubeadm + k8s-bootstrap), Ubuntu 24.04"
  ami_users       = var.ami_users
  imds_support    = "v2.0"
  encrypt_boot    = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 20
    volume_type           = "gp3"
    delete_on_termination = true
  }

  associate_public_ip_address               = true
  temporary_security_group_source_public_ip = true

  run_tags = {
    Name = "packer-${var.ami_name_prefix}"
  }

  tags = {
    Name            = "${var.ami_name_prefix}-k8s-${var.kubernetes_minor}"
    KubernetesMinor = var.kubernetes_minor
    BaseAMI         = "{{ .SourceAMI }}"
    BaseAMIName     = "{{ .SourceAMIName }}"
    BuildTime       = local.build_time
    ManagedBy       = "packer"
  }
}

build {
  sources = ["source.amazon-ebs.node"]

  provisioner "file" {
    source      = "${path.root}/files/k8s-bootstrap"
    destination = "/tmp/"
  }

  provisioner "shell" {
    execute_command = "sudo -E bash -euo pipefail '{{ .Path }}'"
    environment_vars = [
      "DEBIAN_FRONTEND=noninteractive",
      "KUBERNETES_MINOR=${var.kubernetes_minor}",
      "HELM_VERSION=${var.helm_version}",
    ]
    scripts = [
      "${path.root}/scripts/10-base.sh",
      "${path.root}/scripts/20-hardening.sh",
      "${path.root}/scripts/30-kubernetes.sh",
      "${path.root}/scripts/40-bootstrap-tools.sh",
      "${path.root}/scripts/90-cleanup.sh",
    ]
    expect_disconnect = false
  }

  # The workflow reads the AMI ID and the exact Kubernetes version from here.
  post-processor "manifest" {
    output     = "${path.root}/packer-manifest.json"
    strip_path = true
    custom_data = {
      kubernetes_minor = var.kubernetes_minor
    }
  }
}
